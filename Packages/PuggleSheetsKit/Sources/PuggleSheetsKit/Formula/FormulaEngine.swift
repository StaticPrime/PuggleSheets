import Foundation

/// A cell in a particular sheet.
public struct SheetCell: Hashable, Sendable {
    public var sheet: UUID
    public var address: CellAddress

    public init(sheet: UUID, address: CellAddress) {
        self.sheet = sheet
        self.address = address
    }
}

/// Evaluates formulas and keeps every formula cell's value up to date. One engine belongs to one
/// workbook; it keeps a dependency graph between calls.
public final class FormulaEngine {
    private var graph: DependencyGraph?

    public init() {}

    /// Recomputes every formula and pivot table and stores the results in the cells' values. Array results
    /// and pivot tables spill into the sheets' `spilledValues` and `spillRanges`, and HYPERLINK results set
    /// `formulaLinks`; all three are rebuilt from scratch. Call after loading a file, inserting or deleting
    /// rows, columns, cells or sheets, renaming sheets, editing named ranges, or any bulk change.
    public func recalculateAll(_ workbook: inout Workbook, now: Date = Date()) {
        let graph = DependencyGraph(workbook: workbook, previousParses: self.graph?.parseCache ?? [:])
        self.graph = graph
        let outcome = Self.evaluate(graph, dirty: graph.liveNodes, workbook: workbook, now: now)
        for index in workbook.sheets.indices {
            if !workbook.sheets[index].formulaLinks.isEmpty { workbook.sheets[index].formulaLinks = [:] }
            if !workbook.sheets[index].sparklines.isEmpty { workbook.sheets[index].sparklines = [:] }
        }
        Self.store(outcome.results, of: graph, in: &workbook)
        Self.rebuildSpills(graph, in: &workbook)
    }

    /// Recomputes the formulas affected by `changed`: cells whose value or formula was set, cleared
    /// or restored (including the changed formula cells themselves), plus volatile formulas, and keeps
    /// the spill maps and formula links current. Pivot tables added to, changed in or removed from the
    /// sheets' `pivotTables` since the last call are noticed too (pass `changed: []` after editing them),
    /// and so are edits in their source data. The results always equal those of `recalculateAll`; while
    /// the workbook has cycles through spills or dynamic references, it runs a full recalculation to
    /// guarantee that.
    public func recalculate(_ workbook: inout Workbook, changed: some Collection<SheetCell>, now: Date = Date()) {
        // Cycles through dynamic references or spills can come out differently depending on what ran
        // first; while the workbook has any, a full recalculation settles them the same way every time.
        guard let graph, graph.matches(workbook), graph.unstableNodes.isEmpty else {
            recalculateAll(&workbook, now: now)
            return
        }
        var cells: [(sheet: Int, address: CellAddress)] = []
        cells.reserveCapacity(changed.count)
        for cell in changed {
            guard let sheet = graph.sheetIndexByID[cell.sheet] else { continue }
            graph.update(sheet: sheet, address: cell.address, workbook: workbook)
            cells.append((sheet, cell.address))
            if workbook.sheets[sheet].cells[cell.address]?.formula == nil {
                if workbook.sheets[sheet].formulaLinks[cell.address] != nil { workbook.sheets[sheet].formulaLinks[cell.address] = nil }
                if workbook.sheets[sheet].sparklines[cell.address] != nil { workbook.sheets[sheet].sparklines[cell.address] = nil }
            }
        }
        // Pivot tables that came, went or moved also change which cells their anchors block.
        let pivots = graph.syncPivots(workbook)
        cells += pivots.anchors
        let dirty = graph.affectedNodes(changed: cells, areas: graph.takeVacatedAreas(), seeds: pivots.nodes)
        guard !dirty.isEmpty else {
            Self.syncSpills(graph, in: &workbook)
            return
        }
        let outcome = Self.evaluate(graph, dirty: dirty, workbook: workbook, now: now)
        guard !outcome.isUnsettled else {
            recalculateAll(&workbook, now: now)
            return
        }
        Self.store(outcome.results, of: graph, in: &workbook)
        Self.syncSpills(graph, in: &workbook)
    }

    /// Evaluates `formula` as if it were in `address` of sheet `sheetIndex`, without storing anything.
    public static func evaluate(_ formula: String, inSheet sheetIndex: Int, at address: CellAddress,
                                workbook: Workbook, now: Date = Date()) -> CellValue {
        guard workbook.sheets.indices.contains(sheetIndex) else { return .error(FormulaErrors.outOfGrid) }
        let evaluator = Evaluator(workbook: workbook, sheetIndex: sheetIndex, address: address, now: now)
        return evaluator.evaluateFormula(ParsedFormula(formula))
    }

    /// Names of the supported functions, sorted.
    public static var functionNames: [String] { FunctionLibrary.names }

    /// Whether the last recalculated workbook has formulas that change on every recalculation (NOW, TODAY,
    /// RAND, INDIRECT, OFFSET…), so the app can refresh them periodically with `recalculate(_:changed: [])`.
    /// Pivot tables whose filters use formulas or dates relative to today count too.
    public var hasVolatileFormulas: Bool { !(graph?.volatileNodes.isEmpty ?? true) }

    /// The cells of the pivot table with this id as the last recalculation laid them out, with their roles
    /// and number formats for drawing; nil unless the pivot table shows in full (not blocked, not empty).
    public func pivotOutput(for pivotID: UUID) -> PivotOutput? {
        guard let graph, let id = graph.pivotNode(id: pivotID), graph.spills[id]?.isActive == true else { return nil }
        return graph.pivotOutputs[id]
    }

    // MARK: Running a pass

    /// What a pass computed: formula results with their links and sparklines.
    private struct Outcome {
        var results: [(id: Int, value: CellValue, decoration: CellDecoration?)] = []
        var isUnsettled = false
    }

    /// Writes formula results into their cells, HYPERLINK links into the sheets' `formulaLinks` and SPARKLINE
    /// charts into their `sparklines`. The evaluator's snapshot is gone by now, so these writes don't copy the sheets.
    private static func store(_ results: [(id: Int, value: CellValue, decoration: CellDecoration?)], of graph: DependencyGraph,
                              in workbook: inout Workbook) {
        for (id, value, decoration) in results {
            guard let node = graph.nodes[id], node.pivot == nil, let cell = workbook.sheets[node.sheet].cells[node.address],
                  cell.formula != nil else { continue }
            if !isIdentical(cell.value, value) { workbook.sheets[node.sheet][node.address].value = value }
            var link: String?, sparkline: SparklineSpec?
            switch decoration {
            case .link(let url)?: link = url
            case .sparkline(let spec)?: sparkline = spec
            case nil: break
            }
            if workbook.sheets[node.sheet].formulaLinks[node.address] != link { workbook.sheets[node.sheet].formulaLinks[node.address] = link }
            if workbook.sheets[node.sheet].sparklines[node.address] != sparkline { workbook.sheets[node.sheet].sparklines[node.address] = sparkline }
        }
    }

    private static func evaluate(_ graph: DependencyGraph, dirty: [Int], workbook: Workbook, now: Date) -> Outcome {
        // Nested evaluations take about 13 KB of stack each in debug builds; 24 fit comfortably in the
        // 512 KB stacks of secondary threads.
        if let outcome = attempt(graph, dirty: dirty, workbook: workbook, now: now, nestingLimit: 24) { return outcome }
        // Long chains of dynamic references (INDIRECT, OFFSET) nest evaluations deeply: redo the pass on a
        // thread with a big stack.
        let job = DeepEvaluation(graph: graph, dirty: dirty, workbook: workbook, now: now)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            job.outcome = attempt(job.graph, dirty: job.dirty, workbook: job.workbook, now: job.now, nestingLimit: .max) ?? Outcome()
            finished.signal()
        }
        thread.stackSize = 1 << 28
        thread.start()
        finished.wait()
        return job.outcome
    }

    /// One pass; nil when dynamic references nested deeper than `nestingLimit`.
    private static func attempt(_ graph: DependencyGraph, dirty: [Int], workbook: Workbook, now: Date,
                                nestingLimit: Int) -> Outcome? {
        let pass = RecalcPass(graph: graph, dirty: dirty, nestingLimit: nestingLimit)
        let evaluator = Evaluator(workbook: workbook, sheetIndex: 0, address: CellAddress(row: 0, column: 0), now: now)
        evaluator.pass = pass
        pass.run(evaluator: evaluator)
        evaluator.pass = nil
        guard !pass.overflowed else { return nil }
        let results = pass.evaluated.compactMap { id in graph.nodes[id]?.pivot == nil ? (id, pass.result(id), pass.decoration(id)) : nil }
        return Outcome(results: results, isUnsettled: pass.isUnsettled)
    }

    // MARK: Spilled values in the workbook

    /// Writes every shown spill into the sheets' `spilledValues` and `spillRanges`, from scratch.
    private static func rebuildSpills(_ graph: DependencyGraph, in workbook: inout Workbook) {
        for index in workbook.sheets.indices {
            if !workbook.sheets[index].spilledValues.isEmpty { workbook.sheets[index].spilledValues = [:] }
            if !workbook.sheets[index].spillRanges.isEmpty { workbook.sheets[index].spillRanges = [:] }
        }
        for (id, record) in graph.spills {
            guard let area = record.shownArea, let node = graph.nodes[id] else { continue }
            show(record, in: area, of: node, in: &workbook)
        }
        _ = graph.takeUnsyncedSpills()
    }

    /// Brings the sheets' spill maps up to date with the spills that changed since the last write: first
    /// clears where they showed, then shows them where they are now.
    private static func syncSpills(_ graph: DependencyGraph, in workbook: inout Workbook) {
        let unsynced = graph.takeUnsyncedSpills()
        guard !unsynced.isEmpty else { return }
        for shown in unsynced.values {
            guard let area = shown.area, workbook.sheets.indices.contains(shown.sheet) else { continue }
            for row in area.rows {
                for column in area.columns {
                    let address = CellAddress(row: row, column: column)
                    if shown.includesOrigin || address != shown.origin { workbook.sheets[shown.sheet].spilledValues[address] = nil }
                }
            }
            workbook.sheets[shown.sheet].spillRanges[shown.origin] = nil
        }
        for id in unsynced.keys {
            guard let node = graph.nodes[id], let record = graph.spills[id], let area = record.shownArea else { continue }
            show(record, in: area, of: node, in: &workbook)
        }
    }

    /// Writes a spill's values over `area` (a formula's own cell excepted) and its range.
    private static func show(_ record: SpillRecord, in area: CellRange, of node: DependencyGraph.Node, in workbook: inout Workbook) {
        guard workbook.sheets.indices.contains(node.sheet) else { return }
        let includesOrigin = node.pivot != nil
        for row in area.rows {
            for column in area.columns {
                let address = CellAddress(row: row, column: column)
                guard includesOrigin || address != node.address else { continue }
                workbook.sheets[node.sheet].spilledValues[address] = record.values[row - area.start.row, column - area.start.column]
            }
        }
        workbook.sheets[node.sheet].spillRanges[node.address] = area
    }

    /// The state handed to the big-stack thread; only one thread touches it at a time.
    private final class DeepEvaluation: @unchecked Sendable {
        let graph: DependencyGraph
        let dirty: [Int]
        let workbook: Workbook
        let now: Date
        var outcome = Outcome()

        init(graph: DependencyGraph, dirty: [Int], workbook: Workbook, now: Date) {
            self.graph = graph
            self.dirty = dirty
            self.workbook = workbook
            self.now = now
        }
    }

    /// Equal values, including error messages.
    private static func isIdentical(_ a: CellValue, _ b: CellValue) -> Bool {
        if case .error(let x) = a, case .error(let y) = b { return x.kind == y.kind && x.message == y.message }
        return a == b
    }
}
