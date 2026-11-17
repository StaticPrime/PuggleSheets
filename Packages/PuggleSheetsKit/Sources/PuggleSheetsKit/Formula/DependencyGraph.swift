import Foundation

/// The identity and size of a sheet when the graph was built; any change means a rebuild.
struct SheetSignature: Equatable {
    let id: UUID
    let name: String
    let rowCount: Int
    let columnCount: Int

    init(_ sheet: Sheet) {
        id = sheet.id
        name = sheet.name
        rowCount = sheet.rowCount
        columnCount = sheet.columnCount
    }
}

/// A static input of a formula, resolved to a sheet index.
enum Precedent: Hashable {
    case cell(Int, CellAddress)
    case range(Int, CellRange)
}

/// A cell of a sheet, by sheet index.
struct SheetCellKey: Hashable {
    var sheet: Int
    var address: CellAddress
}

/// Finds the ranges that contain a cell or meet a block without scanning them all: small ranges sit in
/// buckets of (column, block of 128 rows), tall narrow ones in per-column lists, the rest in one list.
struct RangeIndex {
    private struct Bucket: Hashable {
        var column: Int
        var block: Int
    }

    private struct Entry {
        var range: CellRange
        var dependents: [Int]
    }

    private static let blockShift = 7
    private var entries: [Entry?] = []
    private var freeEntries: [Int] = []
    private var entryByRange: [CellRange: Int] = [:]
    private var buckets: [Bucket: [Int]] = [:]
    private var columnLists: [Int: [Int]] = [:]
    private var wideList: [Int] = []

    private enum Placement { case buckets, columns, wide }

    private static func placement(of range: CellRange) -> Placement {
        let blocks = (range.end.row >> blockShift) - (range.start.row >> blockShift) + 1
        if blocks * range.columnCount <= 64 { return .buckets }
        if range.columnCount <= 16 { return .columns }
        return .wide
    }

    var isEmpty: Bool { entryByRange.isEmpty }

    mutating func add(_ range: CellRange, dependent: Int) {
        if let id = entryByRange[range] {
            entries[id]!.dependents.append(dependent)
            return
        }
        let id: Int
        if let free = freeEntries.popLast() {
            id = free
            entries[id] = Entry(range: range, dependents: [dependent])
        } else {
            id = entries.count
            entries.append(Entry(range: range, dependents: [dependent]))
        }
        entryByRange[range] = id
        switch Self.placement(of: range) {
        case .buckets:
            for column in range.columns {
                for block in (range.start.row >> Self.blockShift)...(range.end.row >> Self.blockShift) {
                    buckets[Bucket(column: column, block: block), default: []].append(id)
                }
            }
        case .columns:
            for column in range.columns { columnLists[column, default: []].append(id) }
        case .wide:
            wideList.append(id)
        }
    }

    mutating func remove(_ range: CellRange, dependent: Int) {
        guard let id = entryByRange[range], var entry = entries[id] else { return }
        if let position = entry.dependents.firstIndex(of: dependent) { entry.dependents.remove(at: position) }
        guard entry.dependents.isEmpty else {
            entries[id] = entry
            return
        }
        entries[id] = nil
        entryByRange[range] = nil
        freeEntries.append(id)
        func drop(_ list: inout [Int]?) {
            list?.removeAll { $0 == id }
            if list?.isEmpty == true { list = nil }
        }
        switch Self.placement(of: range) {
        case .buckets:
            for column in range.columns {
                for block in (range.start.row >> Self.blockShift)...(range.end.row >> Self.blockShift) {
                    drop(&buckets[Bucket(column: column, block: block)])
                }
            }
        case .columns:
            for column in range.columns { drop(&columnLists[column]) }
        case .wide:
            wideList.removeAll { $0 == id }
        }
    }

    /// Calls `body` with the dependents of every range containing `address`.
    func forEachDependent(of address: CellAddress, _ body: (Int) -> Void) {
        func visit(_ ids: [Int]) {
            for id in ids {
                guard let entry = entries[id], entry.range.contains(address) else { continue }
                for dependent in entry.dependents { body(dependent) }
            }
        }
        if let ids = buckets[Bucket(column: address.column, block: address.row >> Self.blockShift)] { visit(ids) }
        if let ids = columnLists[address.column] { visit(ids) }
        if !wideList.isEmpty { visit(wideList) }
    }

    /// Calls `body` with the dependents of every range meeting `area` (once per range).
    func forEachDependent(intersecting area: CellRange, _ body: (Int) -> Void) {
        guard !entryByRange.isEmpty else { return }
        if area.isSingleCell {
            forEachDependent(of: area.start, body)
            return
        }
        let firstBlock = area.start.row >> Self.blockShift, lastBlock = area.end.row >> Self.blockShift
        if (lastBlock - firstBlock + 1) * area.columnCount > entries.count {
            for case let entry? in entries where entry.range.intersects(area) {
                for dependent in entry.dependents { body(dependent) }
            }
            return
        }
        // An entry sits in every bucket (or column list) its range covers; report it only from the first
        // one the query probes.
        for column in area.columns {
            for block in firstBlock...lastBlock {
                guard let ids = buckets[Bucket(column: column, block: block)] else { continue }
                for id in ids {
                    guard let entry = entries[id], entry.range.intersects(area),
                          column == max(entry.range.start.column, area.start.column),
                          block == max(entry.range.start.row >> Self.blockShift, firstBlock) else { continue }
                    for dependent in entry.dependents { body(dependent) }
                }
            }
            if let ids = columnLists[column] {
                for id in ids {
                    guard let entry = entries[id], entry.range.intersects(area),
                          column == max(entry.range.start.column, area.start.column) else { continue }
                    for dependent in entry.dependents { body(dependent) }
                }
            }
        }
        for id in wideList {
            guard let entry = entries[id], entry.range.intersects(area) else { continue }
            for dependent in entry.dependents { body(dependent) }
        }
    }
}

/// An array formula's or pivot table's result and where it goes.
struct SpillRecord: Equatable {
    var values: ValueMatrix
    /// The block the result covers, with the formula's cell (or pivot table's anchor) at its top-left; it
    /// may run past the grid.
    var area: CellRange
    /// Spilled, or blocked by data, an earlier formula's spill or the grid's edge.
    var isActive: Bool
    /// A blocked pivot table shows its error (`values[0, 0]`) in its anchor cell.
    var showsErrorInOrigin = false

    /// The cells showing this result: the whole area while active (a formula's own cell holds the formula
    /// instead), a blocked pivot table's anchor, or none.
    var shownArea: CellRange? {
        if isActive { return area }
        return showsErrorInOrigin ? CellRange(area.start) : nil
    }

    /// Equal, error messages included.
    static func isIdentical(_ a: SpillRecord?, _ b: SpillRecord?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        guard a == b else { return false }
        return zip(a.values.values, b.values.values).allSatisfy { x, y in
            if case .error(let first) = x, case .error(let second) = y { return first.message == second.message }
            return true
        }
    }
}

/// Formula cells of a workbook, what they read, and where their array results spill.
final class DependencyGraph {
    struct Node {
        var sheet: Int
        var address: CellAddress
        var formula: String
        var parsed: ParsedFormula
        var precedents: [Precedent]
        /// For a pivot table's node: its definition (`address` is its anchor; there's no formula).
        var pivot: PivotTable?
        /// Orders nodes of the same cell: formulas 0, pivot tables 1 + their index in the sheet's list.
        var rank = 0
    }

    /// Where a node's spill showed in the workbook when it last saw it (`area` nil: nowhere).
    struct ShownSpill {
        var sheet: Int
        var origin: CellAddress
        var area: CellRange?
        /// The origin cell shows a value too (pivot tables).
        var includesOrigin: Bool
    }

    /// Pivot table nodes have no formula of their own.
    private static let pivotPlaceholder = ParsedFormula("")

    let signature: [SheetSignature]
    let namedRanges: [NamedRange]
    /// Each sheet's tables as formulas see them: name and block. Any change means a rebuild.
    let tableSignature: [[TableSignature]]

    struct TableSignature: Equatable {
        let name: String
        let range: CellRange

        init(_ table: SheetTable) {
            name = table.name.uppercased()
            range = table.range
        }
    }
    let sheetIndexByID: [UUID: Int]
    private(set) var nodes: [Node?] = []
    private var freeNodes: [Int] = []
    /// Node of each formula cell, per sheet.
    private(set) var nodeAt: [[CellAddress: Int]]
    /// Formula rows (sorted) with their nodes, per sheet and column.
    private var formulaRows: [[Int: [(row: Int, node: Int)]]]
    private var cellDependents: [[CellAddress: [Int]]]
    private var rangeIndexes: [RangeIndex]
    private(set) var volatileNodes = Set<Int>()
    /// Formulas left circular by a cycle through dynamic references or spills. Such a cycle can vanish
    /// without any of their inputs changing (a spill it ran through goes away), so they recompute in every
    /// recalculation, like volatile formulas, until they come out clean.
    var unstableNodes = Set<Int>()
    private(set) var parseCache: [String: ParsedFormula]
    private let previousParses: [String: ParsedFormula]

    /// Array results by node.
    private(set) var spills: [Int: SpillRecord] = [:]
    /// Cells covered by active spills (not the formulas' own cells) → the spilling node, per sheet.
    private(set) var spillOwner: [[CellAddress: Int]]
    /// Active spill areas → their nodes, per sheet.
    private(set) var activeSpills: [RangeIndex]
    /// Every spill area, active or blocked → its node, per sheet.
    private(set) var spillAreas: [RangeIndex]
    /// Spills changed since the workbook last showed them, by node.
    private(set) var unsyncedSpills: [Int: ShownSpill] = [:]
    /// Spilled areas whose formulas went away, for the next recalculation's dirty marking.
    private var vacatedAreas: [(sheet: Int, area: CellRange)] = []

    /// Each sheet's pivot tables as the graph last saw them, and their nodes (in the same order).
    private var pivotDefinitions: [[PivotTable]]
    private var pivotNodeIDs: [[Int]]
    /// Pivot table anchors → their nodes, first listed first, per sheet. An anchor blocks other spills like data.
    private var pivotAnchors: [[CellAddress: [Int]]]
    /// The latest output computed for each pivot table node, and its layout.
    var pivotOutputs: [Int: PivotOutput] = [:]
    var pivotAxes: [Int: PivotEngine.Axes] = [:]

    init(workbook: Workbook, previousParses: [String: ParsedFormula]) {
        signature = workbook.sheets.map(SheetSignature.init)
        namedRanges = workbook.namedRanges
        tableSignature = workbook.sheets.map { $0.tables.map(TableSignature.init) }
        sheetIndexByID = Dictionary(workbook.sheets.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let count = workbook.sheets.count
        nodeAt = Array(repeating: [:], count: count)
        formulaRows = Array(repeating: [:], count: count)
        cellDependents = Array(repeating: [:], count: count)
        rangeIndexes = Array(repeating: RangeIndex(), count: count)
        spillOwner = Array(repeating: [:], count: count)
        activeSpills = Array(repeating: RangeIndex(), count: count)
        spillAreas = Array(repeating: RangeIndex(), count: count)
        parseCache = [:]
        self.previousParses = previousParses
        pivotDefinitions = workbook.sheets.indices.map { Self.effectivePivots(sheet: $0, workbook) }
        pivotNodeIDs = Array(repeating: [], count: count)
        pivotAnchors = Array(repeating: [:], count: count)
        for (sheetIndex, sheet) in workbook.sheets.enumerated() {
            for (address, cell) in sheet.cells {
                if let formula = cell.formula { addNode(sheet: sheetIndex, address: address, formula: formula, workbook: workbook, sorted: false) }
            }
            for (index, pivot) in pivotDefinitions[sheetIndex].enumerated() {
                pivotNodeIDs[sheetIndex].append(addPivotNode(sheet: sheetIndex, pivot: pivot, rank: index + 1, workbook: workbook))
            }
            indexPivotAnchors(sheet: sheetIndex)
        }
        for sheet in formulaRows.indices {
            for column in formulaRows[sheet].keys { formulaRows[sheet][column]!.sort { $0.row < $1.row } }
        }
    }

    func matches(_ workbook: Workbook) -> Bool {
        guard workbook.sheets.count == signature.count, workbook.namedRanges == namedRanges else { return false }
        for (index, (sheet, expected)) in zip(workbook.sheets, signature).enumerated() {
            guard sheet.id == expected.id, sheet.name == expected.name, sheet.rowCount == expected.rowCount,
                  sheet.columnCount == expected.columnCount else { return false }
            let tables = tableSignature[index]
            guard sheet.tables.count == tables.count,
                  zip(sheet.tables, tables).allSatisfy({ TableSignature($0) == $1 }) else { return false }
        }
        return true
    }

    var liveNodes: [Int] { nodes.indices.filter { nodes[$0] != nil } }

    private func parse(_ formula: String) -> ParsedFormula {
        if let parsed = parseCache[formula] { return parsed }
        let parsed = previousParses[formula] ?? ParsedFormula(formula)
        parseCache[formula] = parsed
        return parsed
    }

    /// Follows a cell whose value or formula changed.
    func update(sheet: Int, address: CellAddress, workbook: Workbook) {
        let formula = workbook.sheets[sheet].cells[address]?.formula
        if let id = nodeAt[sheet][address] {
            if nodes[id]?.formula == formula { return }
            removeNode(id)
        }
        if let formula { addNode(sheet: sheet, address: address, formula: formula, workbook: workbook, sorted: true) }
    }

    private func addNode(sheet: Int, address: CellAddress, formula: String, workbook: Workbook, sorted: Bool) {
        let parsed = parse(formula)
        var precedents: [Precedent] = []
        precedents.reserveCapacity(parsed.dependencies.count + parsed.names.count)
        var seen = Set<Precedent>()
        let manyReferences = parsed.dependencies.count > 16
        func resolve(_ reference: ReferenceSyntax, defaultSheet: Int) -> (sheet: Int, range: CellRange)? {
            var target = defaultSheet
            if let name = reference.sheet {
                guard let index = workbook.sheetIndex(named: name) else { return nil }
                target = index
            }
            guard let range = reference.range(rowCount: workbook.sheets[target].rowCount,
                                              columnCount: workbook.sheets[target].columnCount) else { return nil }
            return (target, range)
        }
        func add(_ target: Int, _ range: CellRange) {
            let precedent: Precedent = range.isSingleCell ? .cell(target, range.start) : .range(target, range)
            let isNew = manyReferences ? seen.insert(precedent).inserted : !precedents.contains(precedent)
            if isNew { precedents.append(precedent) }
        }
        for dependency in parsed.dependencies {
            guard let (target, resolved) = resolve(dependency.reference, defaultSheet: sheet) else { continue }
            var range = resolved
            if let shape = dependency.shapedLike.flatMap({ resolve($0, defaultSheet: sheet) }) {
                let end = CellAddress(row: min(range.start.row + shape.range.rowCount, workbook.sheets[target].rowCount) - 1,
                                      column: min(range.start.column + shape.range.columnCount,
                                                  workbook.sheets[target].columnCount) - 1)
                range = range.union(CellRange(range.start, end))
            }
            add(target, range)
        }
        for name in parsed.names {
            if let named = workbook.namedRange(name) {
                if let reference = NamedRanges.reference(of: named, in: workbook) { add(reference.sheet, reference.range) }
            } else if let (target, table) = workbook.table(named: name) {
                add(target, table.range)
            }
        }
        // A structured reference reads its table's cells and finds columns by their headers: it depends on
        // the whole table.
        for name in parsed.tables {
            if let (target, table) = workbook.table(named: name) { add(target, table.range) }
        }
        let node = Node(sheet: sheet, address: address, formula: formula, parsed: parsed, precedents: precedents)
        let id = insert(node)
        nodeAt[sheet][address] = id
        if sorted {
            let index = Self.lowerBound(formulaRows[sheet][address.column] ?? [], address.row)
            formulaRows[sheet][address.column, default: []].insert((address.row, id), at: index)
        } else {
            formulaRows[sheet][address.column, default: []].append((address.row, id))
        }
        if parsed.isVolatile { volatileNodes.insert(id) }
    }

    /// Stores a node and registers it as a reader of its precedents.
    private func insert(_ node: Node) -> Int {
        let id: Int
        if let free = freeNodes.popLast() {
            id = free
            nodes[id] = node
        } else {
            id = nodes.count
            nodes.append(node)
        }
        for precedent in node.precedents {
            switch precedent {
            case .cell(let target, let cell): cellDependents[target][cell, default: []].append(id)
            case .range(let target, let range): rangeIndexes[target].add(range, dependent: id)
            }
        }
        return id
    }

    /// A pivot table as a node at its anchor that reads its whole source block.
    private func addPivotNode(sheet: Int, pivot: PivotTable, rank: Int, workbook: Workbook) -> Int {
        var precedents: [Precedent] = []
        if let source = workbook.resolve(pivot.source, onSheet: sheet) {
            precedents.append(source.range.isSingleCell ? .cell(source.sheet, source.range.start) : .range(source.sheet, source.range))
        }
        let id = insert(Node(sheet: sheet, address: pivot.anchor, formula: "", parsed: Self.pivotPlaceholder,
                             precedents: precedents, pivot: pivot, rank: rank))
        if Self.isVolatile(pivot) { volatileNodes.insert(id) }
        return id
    }

    /// Pivot tables whose filters use formulas or dates relative to today recompute every time, like NOW().
    private static func isVolatile(_ pivot: PivotTable) -> Bool {
        let relativeDays: Set<String> = ["today", "tomorrow", "yesterday", "past week", "past month", "past year"]
        return pivot.filters.contains { filter in
            guard let condition = filter.criterion.condition else { return false }
            return condition.kind == .customFormula || condition.values.contains { value in
                value.hasPrefix("=") || relativeDays.contains(value.trimmingCharacters(in: .whitespaces).lowercased())
            }
        }
    }

    private func indexPivotAnchors(sheet: Int) {
        var anchors: [CellAddress: [Int]] = [:]
        for id in pivotNodeIDs[sheet] {
            guard let node = nodes[id] else { continue }
            anchors[node.address, default: []].append(id)
        }
        pivotAnchors[sheet] = anchors
    }

    /// Follows edits to the sheets' pivot tables since the graph last saw them: unchanged definitions keep
    /// their nodes. Returns the nodes of new or changed pivot tables (and of those whose position in the
    /// list changed) and the anchors of every pivot table that came, went or moved.
    func syncPivots(_ workbook: Workbook) -> (nodes: [Int], anchors: [(sheet: Int, address: CellAddress)]) {
        var changed: [Int] = []
        var anchors: [(sheet: Int, address: CellAddress)] = []
        for sheet in workbook.sheets.indices {
            let current = Self.effectivePivots(sheet: sheet, workbook)
            guard current != pivotDefinitions[sheet] else { continue }
            var available: [PivotTable: [Int]] = [:]
            for (index, pivot) in pivotDefinitions[sheet].enumerated() { available[pivot, default: []].append(pivotNodeIDs[sheet][index]) }
            var ids = [Int](repeating: -1, count: current.count)
            var kept = Set<Int>()
            for (index, pivot) in current.enumerated() {
                guard var candidates = available[pivot], !candidates.isEmpty else { continue }
                let id = candidates.removeFirst()
                available[pivot] = candidates
                kept.insert(id)
                ids[index] = id
                if nodes[id]?.rank != index + 1 {
                    // The first pivot table listed wins an anchor shared with others.
                    nodes[id]?.rank = index + 1
                    changed.append(id)
                    anchors.append((sheet, pivot.anchor))
                }
            }
            for id in pivotNodeIDs[sheet] where !kept.contains(id) {
                if let anchor = nodes[id]?.address { anchors.append((sheet, anchor)) }
                removeNode(id)
            }
            for (index, pivot) in current.enumerated() where ids[index] < 0 {
                ids[index] = addPivotNode(sheet: sheet, pivot: pivot, rank: index + 1, workbook: workbook)
                changed.append(ids[index])
                anchors.append((sheet, pivot.anchor))
            }
            pivotDefinitions[sheet] = current
            pivotNodeIDs[sheet] = ids
            indexPivotAnchors(sheet: sheet)
        }
        return (changed, anchors)
    }

    /// A sheet's pivot tables with the filters of the slicers that apply to them (so editing a slicer
    /// counts as editing those pivot tables).
    private static func effectivePivots(sheet: Int, _ workbook: Workbook) -> [PivotTable] {
        workbook.sheets[sheet].pivotTables.map { PivotEngine.effective($0, sheetIndex: sheet, workbook: workbook) }
    }

    /// The pivot table that owns an anchor cell: the first listed of those anchored there.
    func pivotAnchorOwner(sheet: Int, at address: CellAddress) -> Int? {
        pivotAnchors[sheet][address]?.first
    }

    /// The first pivot table anchor inside `area` in reading order, other than `excluded`.
    func firstPivotAnchor(sheet: Int, in area: CellRange, excluding excluded: CellAddress) -> CellAddress? {
        var first: CellAddress?
        for anchor in pivotAnchors[sheet].keys where anchor != excluded && area.contains(anchor) {
            if first.map({ anchor < $0 }) ?? true { first = anchor }
        }
        return first
    }

    /// The node of the pivot table with this id, if the graph knows it.
    func pivotNode(id: UUID) -> Int? {
        for (sheet, definitions) in pivotDefinitions.enumerated() {
            if let index = definitions.firstIndex(where: { $0.id == id }) { return pivotNodeIDs[sheet][index] }
        }
        return nil
    }

    private func removeNode(_ id: Int) {
        guard let node = nodes[id] else { return }
        if let spill = spills[id] {
            if let shown = spill.shownArea { vacatedAreas.append((node.sheet, shown)) }
            setSpill(id, nil)
        }
        if node.pivot != nil {
            pivotOutputs[id] = nil
            pivotAxes[id] = nil
        } else {
            nodeAt[node.sheet][node.address] = nil
            formulaRows[node.sheet][node.address.column]?.removeAll { $0.node == id }
            if formulaRows[node.sheet][node.address.column]?.isEmpty == true { formulaRows[node.sheet][node.address.column] = nil }
        }
        for precedent in node.precedents {
            switch precedent {
            case .cell(let target, let cell):
                cellDependents[target][cell]?.removeAll { $0 == id }
                if cellDependents[target][cell]?.isEmpty == true { cellDependents[target][cell] = nil }
            case .range(let target, let range):
                rangeIndexes[target].remove(range, dependent: id)
            }
        }
        volatileNodes.remove(id)
        unstableNodes.remove(id)
        nodes[id] = nil
        freeNodes.append(id)
    }

    private static func lowerBound(_ rows: [(row: Int, node: Int)], _ row: Int) -> Int {
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].row < row { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Nodes sorted by sheet, then row, then column (formulas before pivot tables of the same cell).
    func readingOrder(_ ids: [Int]) -> [Int] {
        var keyed: [(sheet: Int, row: Int, column: Int, rank: Int, id: Int)] = []
        keyed.reserveCapacity(ids.count)
        for id in ids {
            guard let node = nodes[id] else { continue }
            keyed.append((node.sheet, node.address.row, node.address.column, node.rank, id))
        }
        keyed.sort { ($0.sheet, $0.row, $0.column, $0.rank) < ($1.sheet, $1.row, $1.column, $1.rank) }
        return keyed.map(\.id)
    }

    /// Reading order of two nodes (an earlier formula's or pivot table's spill wins over a later one's).
    func isBefore(_ a: Int, _ b: Int) -> Bool {
        guard let x = nodes[a], let y = nodes[b] else { return a < b }
        if x.sheet != y.sheet { return x.sheet < y.sheet }
        return x.address != y.address ? x.address < y.address : x.rank < y.rank
    }

    /// Calls `body` with the formula nodes inside a block.
    func forEachNode(in reference: SheetReference, _ body: (Int) -> Void) {
        let columns = formulaRows[reference.sheet]
        let range = reference.range
        func scan(_ rows: [(row: Int, node: Int)]) {
            var index = Self.lowerBound(rows, range.start.row)
            while index < rows.count, rows[index].row <= range.end.row {
                body(rows[index].node)
                index += 1
            }
        }
        if range.columnCount <= columns.count {
            for column in range.columns {
                if let rows = columns[column] { scan(rows) }
            }
        } else {
            for column in columns.keys.sorted() where range.columns.contains(column) { scan(columns[column]!) }
        }
    }

    /// The formula nodes a node reads through its static references (not spills or dynamic references).
    func staticSuccessors(of id: Int) -> [Int] {
        guard let node = nodes[id] else { return [] }
        var result: [Int] = []
        for precedent in node.precedents {
            switch precedent {
            case .cell(let sheet, let address):
                if let target = nodeAt[sheet][address] { result.append(target) }
            case .range(let sheet, let range):
                forEachNode(in: SheetReference(sheet: sheet, range: range)) { result.append($0) }
            }
        }
        return result
    }

    /// Calls `body` with every formula that reads a cell of `area` through a static reference.
    func forEachReader(sheet: Int, area: CellRange, _ body: (Int) -> Void) {
        let dependents = cellDependents[sheet]
        if !dependents.isEmpty {
            if area.cellCount <= dependents.count {
                for row in area.rows {
                    for column in area.columns {
                        dependents[CellAddress(row: row, column: column)]?.forEach(body)
                    }
                }
            } else {
                for (address, ids) in dependents where area.contains(address) { ids.forEach(body) }
            }
        }
        rangeIndexes[sheet].forEachDependent(intersecting: area, body)
    }

    /// The nodes to recompute after `changed` cells changed (and `areas` lost spilled values): the changed
    /// formulas, spills whose cells were typed over or freed, everything that depends on a changed cell
    /// directly or through other formulas, volatile formulas, and `seeds` (new pivot tables), with their
    /// dependents.
    func affectedNodes(changed: [(sheet: Int, address: CellAddress)], areas: [(sheet: Int, area: CellRange)],
                       seeds: [Int] = []) -> [Int] {
        propagate { mark, queue in
            seeds.forEach(mark)
            for cell in changed {
                if let id = nodeAt[cell.sheet][cell.address] { mark(id) }
                spillAreas[cell.sheet].forEachDependent(of: cell.address, mark)
                queue((cell.sheet, CellRange(cell.address)))
            }
            for item in areas {
                spillAreas[item.sheet].forEachDependent(intersecting: item.area, mark)
                queue(item)
            }
            for id in volatileNodes { mark(id) }
            for id in unstableNodes { mark(id) }
        }
    }

    /// `seeds` and everything that depends on them.
    func dependentClosure(of seeds: [Int]) -> [Int] {
        propagate { mark, _ in seeds.forEach(mark) }
    }

    /// Marks nodes and, transitively, the readers of their cells and of their spilled areas.
    private func propagate(_ seed: (_ mark: (Int) -> Void, _ queue: ((sheet: Int, area: CellRange)) -> Void) -> Void) -> [Int] {
        var marked = [Bool](repeating: false, count: nodes.count)
        var result: [Int] = []
        var pending: [(sheet: Int, area: CellRange)] = []
        func mark(_ id: Int) {
            guard !marked[id], let node = nodes[id] else { return }
            marked[id] = true
            result.append(id)
            pending.append((node.sheet, CellRange(node.address)))
            if let shown = spills[id]?.shownArea { pending.append((node.sheet, shown)) }
        }
        seed(mark) { pending.append($0) }
        while let item = pending.popLast() { forEachReader(sheet: item.sheet, area: item.area, mark) }
        return result
    }

    // MARK: Spills

    /// Replaces a node's spill record and keeps the indexes current. Returns the areas whose spilled values
    /// changed and the area that stopped being spilled into (if any).
    @discardableResult
    func setSpill(_ id: Int, _ record: SpillRecord?) -> (changed: [CellRange], freed: CellRange?) {
        guard let node = nodes[id] else { return ([], nil) }
        let old = spills[id]
        guard !SpillRecord.isIdentical(old, record) else { return ([], nil) }
        // A pivot table's anchor shows its values; a formula's cell shows the formula's own value.
        let includesOrigin = node.pivot != nil
        if unsyncedSpills[id] == nil {
            unsyncedSpills[id] = ShownSpill(sheet: node.sheet, origin: node.address, area: old?.shownArea, includesOrigin: includesOrigin)
        }
        var changed: [CellRange] = []
        var freed: CellRange?
        if let old {
            spillAreas[node.sheet].remove(old.area, dependent: id)
            if let shown = old.shownArea {
                for row in shown.rows {
                    for column in shown.columns {
                        let address = CellAddress(row: row, column: column)
                        if includesOrigin || address != node.address, spillOwner[node.sheet][address] == id {
                            spillOwner[node.sheet][address] = nil
                        }
                    }
                }
                activeSpills[node.sheet].remove(shown, dependent: id)
                changed.append(shown)
                if record?.shownArea != shown { freed = shown }
            }
        }
        spills[id] = record
        if let record {
            spillAreas[node.sheet].add(record.area, dependent: id)
            if let shown = record.shownArea {
                for row in shown.rows {
                    for column in shown.columns {
                        let address = CellAddress(row: row, column: column)
                        if includesOrigin || address != node.address { spillOwner[node.sheet][address] = id }
                    }
                }
                activeSpills[node.sheet].add(shown, dependent: id)
                if !changed.contains(shown) { changed.append(shown) }
            }
        }
        return (changed, freed)
    }

    /// Spills changed since the workbook last showed them; forgets them.
    func takeUnsyncedSpills() -> [Int: ShownSpill] {
        defer { unsyncedSpills = [:] }
        return unsyncedSpills
    }

    /// Spilled areas whose formulas went away since the last call.
    func takeVacatedAreas() -> [(sheet: Int, area: CellRange)] {
        defer { vacatedAreas = [] }
        return vacatedAreas
    }
}

/// Named ranges as references.
enum NamedRanges {
    /// The reference a named range stands for, parsed.
    static func syntax(of named: NamedRange) -> ReferenceSyntax? {
        var text = named.reference.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("=") { text.removeFirst() }
        return Evaluator.referenceSyntax(text)
    }

    /// The block a named range covers; a reference without a sheet points to the first sheet.
    static func reference(of named: NamedRange, in workbook: Workbook) -> SheetReference? {
        guard let syntax = syntax(of: named) else { return nil }
        var sheet = 0
        if let name = syntax.sheet {
            guard let index = workbook.sheetIndex(named: name) else { return nil }
            sheet = index
        }
        guard workbook.sheets.indices.contains(sheet),
              let range = syntax.range(rowCount: workbook.sheets[sheet].rowCount,
                                       columnCount: workbook.sheets[sheet].columnCount) else { return nil }
        return SheetReference(sheet: sheet, range: range)
    }
}
