import Foundation

/// Builds one pivot table: reads and filters the source records, groups them into a tree of labels per
/// axis, sorts the groups, lays out the cells and computes the summaries.
///
/// Every record belongs to one node per depth of the row tree (the root holds all records) and likewise
/// of the column tree, so each (row node, column node) pair — a data cell, subtotal or grand total — has
/// its own list of records, gathered with one counting sort.
final class PivotBuilder {
    typealias Role = PivotOutput.Role

    private let pivot: PivotTable
    private let source: PivotEngine.Source
    private let evaluator: Evaluator
    private let now: Date
    private let sheet: Sheet
    private let rowGroups: [PivotGroup]
    private let columnGroups: [PivotGroup]
    private let values: [PivotValue]
    /// Several values stacked in rows, or side by side in columns.
    private let valuesInRows: Bool
    private let valuesInColumns: Bool

    private var data = PivotEngine.SourceData(headings: [], recordRows: [], columns: [:])
    private var recordCount = 0
    private var valueColumns: [[CellValue]] = []
    private var rowTrie = Trie()
    private var columnTrie = Trie()
    private var starts: [Int32] = []
    private var entries: [Int32] = []
    private var memo: [Int: CellValue] = [:]

    init(pivot: PivotTable, source: PivotEngine.Source, evaluator: Evaluator, now: Date) {
        self.pivot = pivot
        self.source = source
        self.evaluator = evaluator
        self.now = now
        sheet = evaluator.workbook.sheets[source.sheet]
        rowGroups = pivot.rows
        columnGroups = pivot.columns
        values = pivot.values
        valuesInRows = pivot.valuesInRows && pivot.values.count >= 2
        valuesInColumns = !pivot.valuesInRows && pivot.values.count >= 2
    }

    // MARK: Building

    func build(limit: (rows: Int, columns: Int)?) -> PivotEngine.Evaluation {
        data = PivotEngine.read(source, columns: pivot.usedSourceColumns, evaluator: evaluator)
        recordCount = data.recordRows.count
        let valueFormats = values.map(format(of:))
        applyFilters()
        valueColumns = values.map { column($0.sourceColumn) }

        let rowLabels = rowGroups.map { labelSet(column: $0.sourceColumn) }
        let columnLabels = columnGroups.map { labelSet(column: $0.sourceColumn) }
        let rowPaths = buildTrie(&rowTrie, rowLabels)
        let columnPaths = buildTrie(&columnTrie, columnLabels)

        // The output's size, before computing anything for its cells.
        let rowsPerNode = rowGroups.isEmpty && values.isEmpty ? 0 : (valuesInRows ? values.count : 1)
        let columnsPerNode = valuesInColumns ? values.count : (values.isEmpty && columnGroups.isEmpty ? 0 : 1)
        let headerRows = columnGroups.isEmpty ? 1 : columnGroups.count + 1 + (valuesInColumns ? 1 : 0)
        let rowLevels = rowGroups.count + (valuesInRows ? 1 : 0)
        let left = rowLevels > 0 ? rowLevels : (columnGroups.isEmpty ? 0 : 1)
        let nameColumns = columnGroups.isEmpty ? 0 : columnGroups.count + (valuesInColumns ? 1 : 0)
        let height = headerRows + entryCount(rowTrie, rowGroups, perNode: rowsPerNode)
        let width = left + max(entryCount(columnTrie, columnGroups, perNode: columnsPerNode), nameColumns)
        let combinations = (rowGroups.count + 1) * (columnGroups.count + 1)
        let tooLarge = limit.map { height > $0.rows || width > $0.columns } ?? (height * width > PivotEngine.maximumCells)
        guard !tooLarge, recordCount * combinations < Int(Int32.max), rowTrie.count * columnTrie.count < Int(Int32.max) else {
            return PivotEngine.Evaluation(rowCount: height, columnCount: width)
        }

        gatherRecords(rowPaths: rowPaths, columnPaths: columnPaths)
        let rowOrder = sortedChildren(rowTrie, rowGroups, rowLabels, isRows: true)
        let columnOrder = sortedChildren(columnTrie, columnGroups, columnLabels, isRows: false)
        let rowAxis = layout(rowTrie, rowOrder, rowGroups, rowLabels, perNode: rowsPerNode, valuesHere: valuesInRows,
                             offset: 0, labelRole: .rowLabel)
        let columnAxis = layout(columnTrie, columnOrder, columnGroups, columnLabels, perNode: columnsPerNode,
                                valuesHere: valuesInColumns, offset: columnGroups.isEmpty ? 0 : 1, labelRole: .header)

        // Header band.
        var cells = [CellValue](repeating: .empty, count: height * width)
        var roles = [Role](repeating: .empty, count: height * width)
        var formats = [String?](repeating: nil, count: height * width)
        func put(_ row: Int, _ column: Int, _ value: CellValue, _ role: Role, _ format: String? = nil) {
            let index = row * width + column
            cells[index] = value
            roles[index] = role
            formats[index] = format
        }
        for index in 0..<(headerRows * width) { roles[index] = .header }
        for (offset, entry) in columnAxis.entries.enumerated() {
            let column = left + offset
            switch entry.kind {
            case .leaf: break
            case .subtotal: for row in entry.depth..<headerRows { roles[row * width + column] = .total }
            case .grandTotal: for row in 1..<headerRows { roles[row * width + column] = .grandTotal }
            }
        }
        if !columnGroups.isEmpty {
            if values.count == 1 { put(0, 0, .text(valueHeading(0)), .header) }
            for (index, group) in columnGroups.enumerated() { put(0, left + index, .text(heading(group.sourceColumn)), .header) }
            if valuesInColumns { put(0, left + columnGroups.count, .text("Values"), .header) }
        } else if values.count == 1, !columnAxis.entries.isEmpty {
            put(0, left, .text(valueHeading(0)), .header)
        }
        for (index, group) in rowGroups.enumerated() { put(headerRows - 1, index, .text(heading(group.sourceColumn)), .header) }
        if valuesInRows { put(headerRows - 1, rowGroups.count, .text("Values"), .header) }
        for label in columnAxis.labels { put(label.position, left + label.entry, label.value, label.role, label.format) }

        // Data rows.
        for (offset, rowEntry) in rowAxis.entries.enumerated() {
            let row = headerRows + offset
            let labelRole: Role = rowEntry.kind == .leaf ? .rowLabel : (rowEntry.kind == .subtotal ? .total : .grandTotal)
            for column in 0..<left { roles[row * width + column] = labelRole }
            for (columnOffset, columnEntry) in columnAxis.entries.enumerated() {
                let index = row * width + left + columnOffset
                let valueIndex = rowEntry.value >= 0 ? rowEntry.value : columnEntry.value
                guard valueIndex >= 0 else { continue }
                roles[index] = Self.role(rowEntry.kind, columnEntry.kind)
                formats[index] = valueFormats[valueIndex]
                if let raw = summary(valueIndex, row: rowEntry.node, column: columnEntry.node) {
                    cells[index] = shown(valueIndex, raw, row: rowEntry.node, column: columnEntry.node)
                }
            }
        }
        for label in rowAxis.labels { put(headerRows + label.entry, label.position, label.value, label.role, label.format) }

        var output = PivotOutput()
        output.values.reserveCapacity(height)
        output.roles.reserveCapacity(height)
        output.numberFormats.reserveCapacity(height)
        for row in 0..<height {
            let range = (row * width)..<((row + 1) * width)
            output.values.append(Array(cells[range]))
            output.roles.append(Array(roles[range]))
            output.numberFormats.append(Array(formats[range]))
        }
        func path(_ trie: Trie, _ sets: [LabelSet], _ node: Int32) -> [CellValue] {
            var labels: [CellValue] = []
            var current = Int(node)
            while current > 0 {
                labels.append(sets[trie.depth[current] - 1].values[Int(trie.label[current])])
                current = Int(trie.parent[current])
            }
            return labels.reversed()
        }
        let axes = PivotEngine.Axes(headerRows: headerRows, labelColumns: left,
                                    rows: rowAxis.entries.map { .init(path: path(rowTrie, rowLabels, $0.node), value: $0.value) },
                                    columns: columnAxis.entries.map { .init(path: path(columnTrie, columnLabels, $0.node), value: $0.value) },
                                    rowGroups: rowGroups.map { heading($0.sourceColumn) },
                                    columnGroups: columnGroups.map { heading($0.sourceColumn) },
                                    valueColumns: values.map { heading($0.sourceColumn) }, valueNames: values.indices.map(valueHeading))
        return PivotEngine.Evaluation(output: output, axes: axes, values: ValueMatrix(rows: height, columns: width, values: cells),
                                      rowCount: height, columnCount: width)
    }

    private static func role(_ row: EntryKind, _ column: EntryKind) -> Role {
        if row == .grandTotal || column == .grandTotal { return .grandTotal }
        if row == .subtotal || column == .subtotal { return .total }
        return .value
    }

    // MARK: Source values

    /// A source column's values per record; columns outside the source read as empty.
    private func column(_ index: Int) -> [CellValue] {
        data.columns[index] ?? [CellValue](repeating: .empty, count: recordCount)
    }

    /// A source cell's number format.
    private func numberFormat(row: Int, column: Int) -> String? {
        sheet.cells[CellAddress(row: row, column: source.range.start.column + column)]?.format.numberFormat
    }

    /// A source column's heading ("Column C" when empty).
    private func heading(_ column: Int) -> String {
        let sheetColumn = source.range.start.column + column
        guard data.headings.indices.contains(column) else { return "Column \(CellAddress.columnName(sheetColumn))" }
        return PivotEngine.heading(data.headings[column], format: numberFormat(row: source.range.start.row, column: column),
                                   column: sheetColumn)
    }

    /// "SUM of Sales", or the value's own name.
    private func valueHeading(_ index: Int) -> String {
        let value = values[index]
        if let name = value.name, !name.isEmpty { return name }
        return "\(value.summary.rawValue) of \(heading(value.sourceColumn))"
    }

    /// Value cells' number format: percentages for "% of" values, the source column's (its first number's)
    /// for sums, averages, extremes, medians and products, automatic for counts and spreads.
    private func format(of value: PivotValue) -> String? {
        guard value.showAs == .default else { return "0.00%" }
        switch value.summary {
        case .sum, .average, .max, .min, .median, .product:
            guard let values = data.columns[value.sourceColumn],
                  let first = values.firstIndex(where: { $0.numberValue != nil }) else { return nil }
            return numberFormat(row: data.recordRows[first], column: value.sourceColumn)
        default:
            return nil
        }
    }

    /// Leaves out the records that a filter's hidden values or condition reject, as a sheet filter would
    /// hide their rows (conditions count relative references from the first data row).
    private func applyFilters() {
        let filters = pivot.filters.filter { !$0.criterion.isEmpty && (0..<source.range.columnCount).contains($0.sourceColumn) }
        guard !filters.isEmpty, recordCount > 0 else { return }
        let context = RuleContext(evaluator: evaluator, sheetIndex: source.sheet, now: now)
        var shown = PivotEngine.ShownText(sheet: sheet)
        var keep = [Bool](repeating: true, count: recordCount)
        for filter in filters {
            let values = column(filter.sourceColumn)
            let sheetColumn = source.range.start.column + filter.sourceColumn
            let origin = CellAddress(row: source.range.start.row + 1, column: sheetColumn)
            for record in 0..<recordCount where keep[record] {
                let address = CellAddress(row: data.recordRows[record], column: sheetColumn)
                if !filter.criterion.hiddenValues.isEmpty, filter.criterion.hiddenValues.contains(shown.text(values[record], at: address)) {
                    keep[record] = false
                } else if let condition = filter.criterion.condition,
                          !context.test(condition, at: address, origin: origin, value: values[record]) {
                    keep[record] = false
                }
            }
        }
        guard keep.contains(false) else { return }
        let kept = keep.indices.filter { keep[$0] }
        data.recordRows = kept.map { data.recordRows[$0] }
        for (column, values) in data.columns { data.columns[column] = kept.map { values[$0] } }
        recordCount = kept.count
    }

    // MARK: Groups

    /// One group level's distinct labels.
    private struct LabelSet {
        /// Each record's label.
        var ids: [Int32] = []
        /// Each label's value, as first seen (blanks as `.empty`).
        var values: [CellValue] = []
        var firstRecord: [Int] = []
        /// Each label's position in ascending order.
        var rank: [Int32] = []
        /// The number format of each number label's first cell.
        var formats: [String?] = []
    }

    /// Labels are equal when their values are: case matters for text, blanks are one label, errors match by kind.
    private enum LabelKey: Hashable {
        case blank
        case number(Double)
        case text(String)
        case boolean(Bool)
        case error(CellError.Kind)

        init(_ value: CellValue) {
            switch value {
            case .empty: self = .blank
            case .number(let number): self = .number(number)
            case .text(let text): self = text.isEmpty ? .blank : .text(text)
            case .boolean(let boolean): self = .boolean(boolean)
            case .error(let error): self = .error(error.kind)
            }
        }
    }

    private func labelSet(column sourceColumn: Int) -> LabelSet {
        let values = column(sourceColumn)
        var set = LabelSet()
        set.ids.reserveCapacity(recordCount)
        var index: [LabelKey: Int32] = [:]
        var lastKey: LabelKey?, lastID: Int32 = 0
        for (record, value) in values.enumerated() {
            let key = LabelKey(value)
            if key == lastKey {
                set.ids.append(lastID)
                continue
            }
            let id: Int32
            if let existing = index[key] {
                id = existing
            } else {
                id = Int32(set.values.count)
                index[key] = id
                set.values.append(key == .blank ? .empty : value)
                set.firstRecord.append(record)
            }
            set.ids.append(id)
            lastKey = key
            lastID = id
        }
        let order = set.values.indices.sorted { Self.compareLabels(set.values[$0], set.values[$1]) < 0 }
        set.rank = [Int32](repeating: 0, count: order.count)
        for (position, id) in order.enumerated() { set.rank[id] = Int32(position) }
        set.formats = set.values.indices.map { id in
            guard case .number = set.values[id] else { return nil }
            return numberFormat(row: data.recordRows[set.firstRecord[id]], column: sourceColumn)
        }
        return set
    }

    /// The ascending order for labels: blank, numbers, text (ignoring case), FALSE, TRUE, errors.
    /// Labels that tie (text differing in case) are ordered by their exact value.
    static func compareLabels(_ a: CellValue, _ b: CellValue) -> Int {
        let blankA = RuleContext.isBlank(a), blankB = RuleContext.isBlank(b)
        if blankA || blankB { return blankA == blankB ? 0 : (blankA ? -1 : 1) }
        let order = Coercion.compare(a, b)
        if order != 0 { return order }
        switch (a, b) {
        case (.number(let x), .number(let y)): return x < y ? -1 : (x > y ? 1 : 0)
        case (.text(let x), .text(let y)): return x < y ? -1 : (x > y ? 1 : 0)
        case (.error(let x), .error(let y)):
            let i = CellError.Kind.allCases.firstIndex(of: x.kind) ?? 0, j = CellError.Kind.allCases.firstIndex(of: y.kind) ?? 0
            return i < j ? -1 : (i > j ? 1 : 0)
        default: return 0
        }
    }

    /// The tree of one axis's groups: node 0 is the root, each node's children are the labels of the next
    /// group found among its records.
    private struct Trie {
        var parent: [Int32] = [-1]
        var label: [Int32] = [-1]
        var depth: [Int] = [0]
        var children: [[Int32]] = [[]]
        private var index: [Int64: Int32] = [:]

        var count: Int { parent.count }

        mutating func child(of node: Int32, label: Int32) -> Int32 {
            let key = Int64(node) << 32 | Int64(label)
            if let existing = index[key] { return existing }
            let id = Int32(parent.count)
            parent.append(node)
            self.label.append(label)
            depth.append(depth[Int(node)] + 1)
            children.append([])
            children[Int(node)].append(id)
            index[key] = id
            return id
        }
    }

    /// Fills `trie` and returns each record's node at every depth (root first), `sets.count + 1` per record.
    private func buildTrie(_ trie: inout Trie, _ sets: [LabelSet]) -> [Int32] {
        let levels = sets.count, stride = levels + 1
        var paths = [Int32](repeating: 0, count: recordCount * stride)
        guard levels > 0 else { return paths }
        let ids = sets.map(\.ids)
        // Neighboring records often share their labels: reuse the previous record's nodes while they match.
        var lastLabels = [Int32](repeating: -1, count: levels)
        var lastNodes = [Int32](repeating: 0, count: levels)
        for record in 0..<recordCount {
            var node: Int32 = 0
            var same = true
            for level in 0..<levels {
                let label = ids[level][record]
                if same, lastLabels[level] == label {
                    node = lastNodes[level]
                } else {
                    same = false
                    node = trie.child(of: node, label: label)
                    lastLabels[level] = label
                    lastNodes[level] = node
                }
                paths[record * stride + level + 1] = node
            }
        }
        return paths
    }

    /// How many rows or columns an axis takes: every leaf, every subtotal and the grand total, times
    /// `perNode` (one per value when the values sit on this axis).
    private func entryCount(_ trie: Trie, _ groups: [PivotGroup], perNode: Int) -> Int {
        guard perNode > 0 else { return 0 }
        var count = 0
        for node in 0..<trie.count {
            let depth = trie.depth[node]
            if depth == groups.count {
                count += 1
            } else if depth >= 1, groups[depth - 1].showsTotals {
                count += 1
            }
        }
        if let first = groups.first, first.showsTotals { count += 1 }
        return count * perNode
    }

    // MARK: Records and summaries

    /// Lists every (row node, column node) pair's records, in source order.
    private func gatherRecords(rowPaths: [Int32], columnPaths: [Int32]) {
        let rowStride = rowGroups.count + 1, columnStride = columnGroups.count + 1
        let columnNodes = columnTrie.count
        let cellCount = rowTrie.count * columnNodes
        var starts = [Int32](repeating: 0, count: cellCount + 1)
        for record in 0..<recordCount {
            for rowDepth in 0..<rowStride {
                let base = Int(rowPaths[record * rowStride + rowDepth]) * columnNodes + 1
                for columnDepth in 0..<columnStride { starts[base + Int(columnPaths[record * columnStride + columnDepth])] += 1 }
            }
        }
        for cell in 0..<cellCount { starts[cell + 1] += starts[cell] }
        var next = starts
        var entries = [Int32](repeating: 0, count: Int(starts[cellCount]))
        for record in 0..<recordCount {
            for rowDepth in 0..<rowStride {
                let base = Int(rowPaths[record * rowStride + rowDepth]) * columnNodes
                for columnDepth in 0..<columnStride {
                    let cell = base + Int(columnPaths[record * columnStride + columnDepth])
                    entries[Int(next[cell])] = Int32(record)
                    next[cell] += 1
                }
            }
        }
        self.starts = starts
        self.entries = entries
    }

    /// The summary of value `index` over the records of a row node and a column node; nil without records.
    private func summary(_ index: Int, row: Int32, column: Int32) -> CellValue? {
        let cell = Int(row) * columnTrie.count + Int(column)
        let start = Int(starts[cell]), end = Int(starts[cell + 1])
        guard start < end else { return nil }
        return Self.summarize(values[index].summary, entries[start..<end], valueColumns[index])
    }

    /// `summary`, remembered (totals serve as denominators and sort keys many times).
    private func memoSummary(_ index: Int, row: Int32, column: Int32) -> CellValue? {
        let key = (Int(row) * columnTrie.count + Int(column)) * values.count + index
        if let cached = memo[key] { return cached }
        guard let value = summary(index, row: row, column: column) else { return nil }
        memo[key] = value
        return value
    }

    /// A summary as the function of the same name computes it over the records' values.
    static func summarize(_ summary: PivotValue.Summary, _ records: ArraySlice<Int32>, _ column: [CellValue]) -> CellValue {
        switch summary {
        case .countA:
            var count = 0
            for record in records {
                if case .empty = column[Int(record)] { continue }
                count += 1
            }
            return .number(Double(count))
        case .count:
            var count = 0
            for record in records {
                if case .number = column[Int(record)] { count += 1 }
            }
            return .number(Double(count))
        case .countUnique:
            var seen = Set<CellValue>()
            for record in records {
                let value = column[Int(record)]
                switch value {
                case .empty: continue
                case .error: return value
                default: seen.insert(value)
                }
            }
            return .number(Double(seen.count))
        case .sum, .average, .max, .min, .product:
            var total = 0.0, product = 1.0, count = 0
            var largest = -Double.infinity, smallest = Double.infinity
            for record in records {
                switch column[Int(record)] {
                case .number(let number):
                    total += number
                    product *= number
                    largest = Swift.max(largest, number)
                    smallest = Swift.min(smallest, number)
                    count += 1
                case .error(let error):
                    return .error(error)
                default:
                    continue
                }
            }
            switch summary {
            case .sum: return number(total)
            case .average: return count > 0 ? number(total / Double(count)) : .error(FormulaErrors.divideByZero("AVERAGE"))
            case .max: return number(count > 0 ? largest : 0)
            case .min: return number(count > 0 ? smallest : 0)
            default: return number(count > 0 ? product : 0)
            }
        case .median, .stdev, .stdevp, .variance, .variancep:
            var numbers: [Double] = []
            numbers.reserveCapacity(records.count)
            for record in records {
                switch column[Int(record)] {
                case .number(let number): numbers.append(number)
                case .error(let error): return .error(error)
                default: continue
                }
            }
            if summary == .median {
                guard !numbers.isEmpty else { return .error(FormulaErrors.number("MEDIAN has no valid input data.")) }
                numbers.sort()
                let middle = numbers.count / 2
                return number(numbers.count % 2 == 1 ? numbers[middle] : (numbers[middle - 1] + numbers[middle]) / 2)
            }
            let sample = summary == .stdev || summary == .variance
            guard numbers.count >= (sample ? 2 : 1) else { return .error(FormulaErrors.divideByZero(summary.rawValue)) }
            let variance = FunctionTable.sumOfSquares(numbers) / Double(sample ? numbers.count - 1 : numbers.count)
            return number(summary == .stdev || summary == .stdevp ? variance.squareRoot() : variance)
        }
    }

    private static func number(_ number: Double) -> CellValue {
        number.isFinite ? .number(number == 0 ? 0 : number) : .error(FormulaErrors.notFinite)
    }

    /// A value cell as shown: the summary, or its fraction of the row's, column's or grand total.
    private func shown(_ index: Int, _ raw: CellValue, row: Int32, column: Int32) -> CellValue {
        let total: CellValue?
        switch values[index].showAs {
        case .default: return raw
        case .percentOfRow: total = memoSummary(index, row: row, column: 0)
        case .percentOfColumn: total = memoSummary(index, row: 0, column: column)
        case .percentOfGrandTotal: total = memoSummary(index, row: 0, column: 0)
        }
        if case .error = raw { return raw }
        guard let total else { return .empty }
        if case .error = total { return total }
        guard case .number(let part) = raw, case .number(let whole) = total else { return raw }
        guard whole != 0 else { return .error(FormulaErrors.divideByZero) }
        return Self.number(part / whole)
    }

    /// Each node's children in display order: by label, or by a value's summary (ties by label).
    private func sortedChildren(_ trie: Trie, _ groups: [PivotGroup], _ sets: [LabelSet], isRows: Bool) -> [[Int32]] {
        var order = trie.children
        for node in 0..<trie.count {
            let depth = trie.depth[node]
            guard depth < groups.count, order[node].count > 1 else { continue }
            let group = groups[depth], set = sets[depth]
            if let valueIndex = group.sortByValue, values.indices.contains(valueIndex) {
                let keyed = order[node].map { child -> (node: Int32, key: CellValue, rank: Int32) in
                    let key = (isRows ? memoSummary(valueIndex, row: child, column: 0) : memoSummary(valueIndex, row: 0, column: child)) ?? .empty
                    return (child, key, set.rank[Int(trie.label[Int(child)])])
                }
                order[node] = keyed.sorted { a, b in
                    var comparison = Coercion.compare(a.key, b.key)
                    if comparison == 0 { comparison = a.rank < b.rank ? -1 : (a.rank > b.rank ? 1 : 0) }
                    return group.ascending ? comparison < 0 : comparison > 0
                }.map(\.node)
            } else {
                order[node].sort { a, b in
                    let x = set.rank[Int(trie.label[Int(a)])], y = set.rank[Int(trie.label[Int(b)])]
                    return group.ascending ? x < y : x > y
                }
            }
        }
        return order
    }

    // MARK: Layout

    private enum EntryKind { case leaf, subtotal, grandTotal }

    /// A row or column of the output's data area: a leaf group, a subtotal or the grand total, and the
    /// value it shows when the values sit on this axis.
    private struct Entry {
        var node: Int32
        var kind: EntryKind
        /// Index into `values`, or -1 when the other axis decides (or there are no values).
        var value: Int
        /// The node's depth (subtotals put their label at it).
        var depth: Int
    }

    /// A label cell: `position` is a column of the row labels, or a header row for column labels.
    private struct Label {
        var entry: Int
        var position: Int
        var value: CellValue
        var format: String?
        var role: Role
    }

    private struct Axis {
        var entries: [Entry] = []
        var labels: [Label] = []
    }

    /// Walks an axis's tree in display order: each group's members, then its subtotal; the grand total last.
    /// A group's label goes beside (or above) its first member.
    private func layout(_ trie: Trie, _ order: [[Int32]], _ groups: [PivotGroup], _ sets: [LabelSet], perNode: Int,
                        valuesHere: Bool, offset: Int, labelRole: Role) -> Axis {
        var axis = Axis()
        guard perNode > 0 else { return axis }
        var pending: [Label] = []
        func emit(_ node: Int32, _ kind: EntryKind, depth: Int, label: Label?) {
            let role: Role = kind == .leaf ? labelRole : (kind == .subtotal ? .total : .grandTotal)
            for index in 0..<perNode {
                let entry = axis.entries.count
                axis.entries.append(Entry(node: node, kind: kind, value: valuesHere ? index : (values.count == 1 ? 0 : -1), depth: depth))
                if index == 0 {
                    for var waiting in pending {
                        waiting.entry = entry
                        axis.labels.append(waiting)
                    }
                    pending.removeAll()
                    if var label {
                        label.entry = entry
                        axis.labels.append(label)
                    }
                }
                if valuesHere {
                    axis.labels.append(Label(entry: entry, position: groups.count + offset, value: .text(valueHeading(index)),
                                             format: nil, role: role))
                }
            }
        }
        func visit(_ node: Int32, depth: Int) {
            guard depth < groups.count else {
                emit(node, .leaf, depth: depth, label: nil)
                return
            }
            for child in order[Int(node)] {
                let id = Int(trie.label[Int(child)])
                pending.append(Label(entry: -1, position: depth + offset, value: sets[depth].values[id],
                                     format: sets[depth].formats[id], role: labelRole))
                visit(child, depth: depth + 1)
            }
            if depth >= 1, groups[depth - 1].showsTotals {
                let id = Int(trie.label[Int(node)])
                let label = sets[depth - 1].values[id]
                let text = RuleContext.isBlank(label) ? "Total"
                    : CellDisplay.text(for: label, pattern: sets[depth - 1].formats[id]).text + " Total"
                emit(node, .subtotal, depth: depth, label: Label(entry: -1, position: depth - 1 + offset, value: .text(text),
                                                                format: nil, role: .total))
            }
        }
        visit(0, depth: 0)
        if let first = groups.first, first.showsTotals {
            emit(0, .grandTotal, depth: 0, label: Label(entry: -1, position: offset, value: .text("Grand Total"), format: nil,
                                                        role: .grandTotal))
        }
        return axis
    }
}
