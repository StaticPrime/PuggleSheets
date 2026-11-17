import Foundation

/// One recalculation: evaluates dirty formula nodes after their inputs (Tarjan's algorithm finds the order
/// and the static cycles), and on demand when a dynamic reference (INDIRECT, OFFSET) or a spilled cell
/// reaches a pending formula.
///
/// Array results spill into neighboring cells unless data, an earlier formula's spill (in reading order) or
/// the grid's edge is in the way. Who reads a spilled cell can only be known once its formula has run, so
/// the pass works in rounds: when a spill changes after a reader ran, the reader and its dependents run
/// again. A dynamic read that runs into a formula still being computed reveals a cycle; the pass then finds
/// every formula on such cycles (strongly connected components over static and recorded dynamic edges) and
/// evaluates again.
///
/// Cycles through spills or dynamic references can have no consistent answer (a cycle that exists only
/// while a spill does), so their outcome may depend on what ran first. The pass reports such outcomes as
/// unsettled and remembers the formulas involved as unstable; the engine then settles them with a full
/// recalculation, which always runs the same way.
final class RecalcPass {
    private enum Status: UInt8 { case clean, pending, onStack, evaluating, done }

    private let graph: DependencyGraph
    private var worklist: [Int]
    private var status: [Status]
    private var results: [CellValue]
    /// The link or sparkline each formula's cell shows (its result came from HYPERLINK or SPARKLINE).
    private var decorations: [CellDecoration?]
    private var circular: [Bool]
    /// Formulas found on cycles through dynamic references or spills; they stay circular for the pass.
    private var permanentCircular = Set<Int>()
    private var order: [Int32]
    private var lowLink: [Int32]
    private var tarjanStack: [Int] = []
    private var counter: Int32 = 0
    private var evaluating: [Int] = []
    private var nodesInRange: [SheetReference: [Int]] = [:]
    /// Reads of other formulas made while evaluating a node outside its static references.
    private var dynamicEdges: [Int: [Int]] = [:]
    private var foundDynamicCycle = false
    /// The pass ran into cycles through dynamic references or spills, whose outcome can depend on the
    /// order of evaluation: an incremental recalculation should give way to a full one.
    private(set) var isUnsettled = false
    private var hitRoundLimit = false
    /// How deeply dynamic references may nest evaluations before the pass gives up (see `overflowed`).
    private let nestingLimit: Int
    /// The pass stopped because dynamic references nested too deeply for the current thread's stack.
    private(set) var overflowed = false
    /// When each node's latest evaluation started, on a logical clock.
    private var started: [Int]
    private var clock = 1
    /// Spilled areas whose values changed this round, with the clock reading at the change.
    private var spillChanges: [(sheet: Int, area: CellRange, stamp: Int)] = []
    /// Formulas that must run again next round (spills pushed aside, or blocked spills whose cells freed up).
    private var forcedStale = Set<Int>()
    private var reported: [Bool]
    /// Whether a node's latest result came from a cycle.
    private var cycleFinish: [Bool]
    private(set) var evaluated: [Int] = []

    init(graph: DependencyGraph, dirty: [Int], nestingLimit: Int) {
        self.graph = graph
        self.nestingLimit = nestingLimit
        // In reading order: earlier formulas claim spill cells first, and chains of dynamic references to
        // earlier rows (OFFSET(A2,-1,0)) find their inputs ready.
        worklist = graph.readingOrder(dirty)
        let count = graph.nodes.count
        status = Array(repeating: .clean, count: count)
        results = Array(repeating: .empty, count: count)
        decorations = Array(repeating: nil, count: count)
        circular = Array(repeating: false, count: count)
        order = Array(repeating: 0, count: count)
        lowLink = Array(repeating: 0, count: count)
        started = Array(repeating: 0, count: count)
        reported = Array(repeating: false, count: count)
        cycleFinish = Array(repeating: false, count: count)
        for id in worklist { status[id] = .pending }
        evaluated.reserveCapacity(worklist.count)
    }

    func run(evaluator: Evaluator) {
        // Dirty formulas start without spills, as in a full recalculation, so results don't depend on history.
        for id in worklist where graph.spills[id] != nil { store(id, nil, evaluator) }
        rounds(evaluator)
        guard !overflowed else { return }
        if hitRoundLimit {
            // Still changing after many rounds: the outcome isn't settled.
            isUnsettled = true
            graph.unstableNodes.formUnion(evaluated)
            return
        }
        let cyclic = evaluated.filter { cycleFinish[$0] }
        guard !cyclic.isEmpty || !graph.unstableNodes.isEmpty else { return }
        let staticCycles = staticallyCircular(cyclic)
        for id in evaluated {
            if cycleFinish[id], !staticCycles.contains(id) {
                graph.unstableNodes.insert(id)
                isUnsettled = true
            } else {
                graph.unstableNodes.remove(id)
            }
        }
    }

    /// The nodes of `ids` on cycles made of static references alone.
    private func staticallyCircular(_ ids: [Int]) -> Set<Int> {
        guard !ids.isEmpty else { return [] }
        let members = Set(ids)
        var index = [Int: Int](), low = [Int: Int]()
        var onStack = Set<Int>()
        var stack: [Int] = []
        var next = 0
        var result = Set<Int>()
        for root in ids where index[root] == nil {
            var frames: [(node: Int, successors: [Int], next: Int)] = []
            func push(_ id: Int) {
                index[id] = next
                low[id] = next
                next += 1
                stack.append(id)
                onStack.insert(id)
                frames.append((id, graph.staticSuccessors(of: id).filter(members.contains), 0))
            }
            push(root)
            while let frame = frames.last {
                let id = frame.node
                if frame.next < frame.successors.count {
                    let successor = frame.successors[frame.next]
                    frames[frames.count - 1].next += 1
                    if successor == id {
                        result.insert(id)
                    } else if index[successor] == nil {
                        push(successor)
                    } else if onStack.contains(successor) {
                        low[id] = min(low[id]!, index[successor]!)
                    }
                    continue
                }
                frames.removeLast()
                if let parent = frames.last { low[parent.node] = min(low[parent.node]!, low[id]!) }
                guard low[id] == index[id] else { continue }
                var component: [Int] = []
                while let member = stack.popLast() {
                    onStack.remove(member)
                    component.append(member)
                    if member == id { break }
                }
                if component.count > 1 { result.formUnion(component) }
            }
        }
        return result
    }

    private func rounds(_ evaluator: Evaluator) {
        var rounds = 0
        while true {
            foundDynamicCycle = false
            var index = 0
            while index < worklist.count {
                let id = worklist[index]
                index += 1
                guard status[id] == .pending else { continue }
                ensureEvaluated(id, evaluator)
                if overflowed { return }
            }
            rounds += 1
            if rounds >= 12 {
                hitRoundLimit = true
                return
            }
            let stale = staleNodes()
            if foundDynamicCycle { isUnsettled = true }
            guard foundDynamicCycle || !stale.isEmpty else { return }
            // After a cycle through a formula still in progress, everything runs again: those results are
            // unreliable. Otherwise the stale formulas run again with their dependents, and so do volatile
            // formulas, whose dynamic references may have read the stale values.
            let seeds = stale.isEmpty ? [] : stale + graph.volatileNodes.filter { status[$0] != .clean }
            restart((foundDynamicCycle ? worklist : []) + graph.dependentClosure(of: seeds), evaluator)
            // Look for the cycles once every formula involved is back in the pass. Spills that keep changing
            // feed back into themselves, so after a few rounds look for those cycles too.
            if foundDynamicCycle || rounds >= 4 { permanentCircular.formUnion(cyclicNodes()) }
        }
    }

    func result(_ id: Int) -> CellValue { results[id] }

    func decoration(_ id: Int) -> CellDecoration? { decorations[id] }

    /// How deeply LAMBDA calls may nest: few on the small stack of the first attempt, many on the big one.
    var lambdaDepthLimit: Int { nestingLimit == .max ? 4096 : 24 }

    /// LAMBDA calls nested too deeply for the current stack: stop, so the engine redoes the pass on a big one.
    func needsBigStack() {
        if nestingLimit != .max { overflowed = true }
    }

    /// Makes `ids` pending again for another round.
    private func restart(_ ids: [Int], _ evaluator: Evaluator) {
        var added = false
        for id in ids {
            if status[id] == .clean {
                worklist.append(id)
                added = true
            }
            status[id] = .pending
            circular[id] = false
        }
        if added { worklist = graph.readingOrder(worklist) }
        tarjanStack.removeAll()
        evaluating.removeAll()
        counter = 0
        nodesInRange.removeAll()
        spillChanges.removeAll()
        forcedStale.removeAll()
        evaluator.clearCaches()
    }

    /// Formulas that read spilled values before those changed, and formulas forced to run again.
    private func staleNodes() -> [Int] {
        var stale = forcedStale
        if let latest = spillChanges.map(\.stamp).max() {
            for change in spillChanges {
                graph.forEachReader(sheet: change.sheet, area: change.area) { reader in
                    if status[reader] == .clean || started[reader] < change.stamp { stale.insert(reader) }
                }
            }
            // Dynamic references may have read the changed cells too.
            for id in graph.volatileNodes where status[id] != .clean && started[id] < latest { stale.insert(id) }
        }
        spillChanges.removeAll()
        forcedStale.removeAll()
        return Array(stale)
    }

    // MARK: Reads

    /// The current value of formula cell `address`, computing it first if it is pending.
    func value(sheet: Int, address: CellAddress, stored: CellValue, evaluator: Evaluator) -> CellValue {
        guard let id = graph.nodeAt[sheet][address] else { return stored }
        switch status[id] {
        case .clean: return stored
        case .done: return results[id]
        default: break
        }
        guard settle(id, evaluator) else { return .error(FormulaErrors.circular) }
        return results[id]
    }

    /// The pivot table showing in a cell (computed first if pending): its output and layout.
    func pivot(sheet: Int, address: CellAddress, evaluator: Evaluator) -> (output: PivotOutput, axes: PivotEngine.Axes)? {
        guard let owner = graph.spillOwner[sheet][address], graph.nodes[owner]?.pivot != nil,
              settle(owner, evaluator, record: true), graph.spills[owner]?.isActive == true,
              let output = graph.pivotOutputs[owner], let axes = graph.pivotAxes[owner] else { return nil }
        return (output, axes)
    }

    /// The value spilled into a cell without content, if any.
    func spilledValue(sheet: Int, address: CellAddress, evaluator: Evaluator) -> CellValue? {
        guard !graph.spillOwner[sheet].isEmpty, let owner = graph.spillOwner[sheet][address] else { return nil }
        guard settle(owner, evaluator, record: true) else { return .error(FormulaErrors.circular) }
        guard let current = graph.spillOwner[sheet][address], let record = graph.spills[current],
              let origin = graph.nodes[current]?.address else { return nil }
        return record.values[address.row - origin.row, address.column - origin.column]
    }

    /// The values spilled into the cells of a block (formula cells themselves excluded, pivot table anchors included).
    func spilledEntries(sheet: Int, in range: CellRange, evaluator: Evaluator) -> [(address: CellAddress, value: CellValue)] {
        guard !graph.spillOwner[sheet].isEmpty else { return [] }
        var owners: [Int] = []
        graph.activeSpills[sheet].forEachDependent(intersecting: range) { owners.append($0) }
        var failed = Set<Int>()
        for owner in owners where !settle(owner, evaluator, record: true) { failed.insert(owner) }
        var result: [(address: CellAddress, value: CellValue)] = []
        graph.activeSpills[sheet].forEachDependent(intersecting: range) { owner in
            guard let record = graph.spills[owner], let node = graph.nodes[owner],
                  let overlap = record.shownArea?.intersection(range) else { return }
            let origin = node.address, includesOrigin = node.pivot != nil
            for row in overlap.rows {
                for column in overlap.columns {
                    let address = CellAddress(row: row, column: column)
                    guard includesOrigin || address != origin else { continue }
                    let value = failed.contains(owner) ? CellValue.error(FormulaErrors.circular)
                        : record.values[row - origin.row, column - origin.column]
                    result.append((address, value))
                }
            }
        }
        return result
    }

    /// Makes sure node `id` is computed before a read of it, evaluating it now if pending. False when the
    /// read runs into the node still being computed: a cycle.
    private func settle(_ id: Int, _ evaluator: Evaluator, record: Bool = false) -> Bool {
        switch status[id] {
        case .clean, .done:
            if record, let current = evaluating.last { addDynamicEdge(current, id) }
            return true
        case .pending:
            if evaluating.count >= nestingLimit || overflowed {
                overflowed = true
                return false
            }
            if let current = evaluating.last { addDynamicEdge(current, id) }
            if evaluator.scope != nil || evaluator.override != nil || evaluator.shift != (0, 0) {
                ensureEvaluatedApart(id, evaluator)
            } else {
                ensureEvaluated(id, evaluator)
            }
            if status[id] == .done { return true }
            if overflowed { return false }
        case .onStack, .evaluating:
            if let current = evaluating.last { addDynamicEdge(current, id) }
        }
        foundDynamicCycle = true
        circular[id] = true
        if let current = evaluating.last { circular[current] = true }
        evaluator.cycleHits += 1
        return false
    }

    /// Evaluates a formula reached from inside a LET or LAMBDA, a rule formula (shifted references) or an
    /// override: none of those apply to it.
    @inline(never)
    private func ensureEvaluatedApart(_ id: Int, _ evaluator: Evaluator) {
        let scope = evaluator.scope, override = evaluator.override, shift = evaluator.shift
        evaluator.scope = nil
        evaluator.override = nil
        evaluator.shift = (0, 0)
        ensureEvaluated(id, evaluator)
        evaluator.scope = scope
        evaluator.override = override
        evaluator.shift = shift
    }

    private func addDynamicEdge(_ from: Int, _ to: Int) {
        if dynamicEdges[from]?.last != to { dynamicEdges[from, default: []].append(to) }
    }

    // MARK: Order and cycles

    private func successors(of id: Int) -> [Int] {
        guard let node = graph.nodes[id] else { return [] }
        var result: [Int] = []
        for precedent in node.precedents {
            switch precedent {
            case .cell(let sheet, let address):
                if let target = graph.nodeAt[sheet][address] {
                    if status[target] != .clean { result.append(target) }
                } else if let owner = graph.spillOwner[sheet][address], status[owner] != .clean {
                    result.append(owner)
                }
            case .range(let sheet, let range):
                let reference = SheetReference(sheet: sheet, range: range)
                if let cached = nodesInRange[reference] {
                    result += cached
                } else {
                    var inside: [Int] = []
                    graph.forEachNode(in: reference) { if status[$0] != .clean { inside.append($0) } }
                    nodesInRange[reference] = inside
                    result += inside
                }
                // Formulas spilling into the range run first.
                if !graph.spillOwner[sheet].isEmpty {
                    var owners: [Int] = []
                    graph.activeSpills[sheet].forEachDependent(intersecting: range) { owner in
                        if status[owner] != .clean { owners.append(owner) }
                    }
                    result += graph.readingOrder(owners)
                }
            }
        }
        if let dynamic = dynamicEdges[id] { result += dynamic }
        return result
    }

    private func ensureEvaluated(_ root: Int, _ evaluator: Evaluator) {
        guard status[root] == .pending else { return }
        var frames: [(node: Int, successors: [Int], next: Int)] = []
        func push(_ id: Int) {
            status[id] = .onStack
            order[id] = counter
            lowLink[id] = counter
            counter += 1
            tarjanStack.append(id)
            frames.append((id, successors(of: id), 0))
        }
        push(root)
        while let frame = frames.last, !overflowed {
            let id = frame.node
            if frame.next < frame.successors.count {
                let successor = frame.successors[frame.next]
                frames[frames.count - 1].next += 1
                if successor == id {
                    circular[id] = true
                    if graph.staticSuccessors(of: id).contains(id) {
                        permanentCircular.insert(id)
                    } else {
                        // Reading its own spill: check again once the spill is gone.
                        forcedStale.insert(id)
                    }
                    continue
                }
                switch status[successor] {
                case .pending: push(successor)
                case .onStack: lowLink[id] = min(lowLink[id], order[successor])
                case .evaluating:
                    foundDynamicCycle = true
                    circular[id] = true
                    circular[successor] = true
                case .clean, .done: break
                }
                continue
            }
            frames.removeLast()
            if let parent = frames.last { lowLink[parent.node] = min(lowLink[parent.node], lowLink[id]) }
            guard lowLink[id] == order[id] else { continue }
            var members: [Int] = []
            while let member = tarjanStack.popLast() {
                members.append(member)
                if member == id { break }
            }
            if members.count > 1 {
                // A cycle that runs through a spill may vanish with it: check those members again next round.
                let staticMembers = staticallyCircular(members)
                for member in graph.readingOrder(members) {
                    cycleFinish[member] = true
                    finish(member, .value(.error(FormulaErrors.circular)), evaluator)
                    if !staticMembers.contains(member), !permanentCircular.contains(member) { forcedStale.insert(member) }
                }
            } else {
                evaluate(id, evaluator)
            }
        }
    }

    /// Nodes on cycles of static and recorded dynamic edges.
    private func cyclicNodes() -> [Int] {
        var index = [Int: Int](), low = [Int: Int]()
        var onStack = Set<Int>()
        var stack: [Int] = []
        var next = 0
        var result: [Int] = []
        for root in worklist where index[root] == nil {
            var frames: [(node: Int, successors: [Int], next: Int)] = []
            func push(_ id: Int) {
                index[id] = next
                low[id] = next
                next += 1
                stack.append(id)
                onStack.insert(id)
                frames.append((id, successors(of: id), 0))
            }
            push(root)
            while let frame = frames.last {
                let id = frame.node
                if frame.next < frame.successors.count {
                    let successor = frame.successors[frame.next]
                    frames[frames.count - 1].next += 1
                    if successor == id {
                        result.append(id)
                    } else if index[successor] == nil {
                        push(successor)
                    } else if onStack.contains(successor) {
                        low[id] = min(low[id]!, index[successor]!)
                    }
                    continue
                }
                frames.removeLast()
                if let parent = frames.last { low[parent.node] = min(low[parent.node]!, low[id]!) }
                guard low[id] == index[id] else { continue }
                var members: [Int] = []
                while let member = stack.popLast() {
                    onStack.remove(member)
                    members.append(member)
                    if member == id { break }
                }
                if members.count > 1 { result += members }
            }
        }
        return Array(Set(result))
    }

    // MARK: Evaluating and spilling

    private func evaluate(_ id: Int, _ evaluator: Evaluator) {
        guard !circular[id], !permanentCircular.contains(id), let node = graph.nodes[id] else {
            cycleFinish[id] = true
            finish(id, .value(.error(FormulaErrors.circular)), evaluator)
            return
        }
        if let pivot = node.pivot {
            evaluatePivotNode(id, pivot, node: node, evaluator)
            return
        }
        status[id] = .evaluating
        started[id] = clock
        clock += 1
        evaluating.append(id)
        // Chains of dynamic references nest here once per formula: keep this frame small.
        let savedSheet = evaluator.sheetIndex, savedAddress = evaluator.address
        evaluator.sheetIndex = node.sheet
        evaluator.address = node.address
        let evaluated = evaluator.evaluateFormulaResultAndDecoration(node.parsed)
        evaluator.sheetIndex = savedSheet
        evaluator.address = savedAddress
        evaluating.removeLast()
        cycleFinish[id] = circular[id]
        if circular[id] {
            finish(id, .value(.error(FormulaErrors.circular)), evaluator)
        } else {
            finish(id, evaluated.result, evaluator, decoration: evaluated.decoration)
        }
    }

    /// Evaluates a pivot table node: rule formulas in its filters move the evaluator's cell and shift,
    /// so those are restored afterwards.
    @inline(never)
    private func evaluatePivotNode(_ id: Int, _ pivot: PivotTable, node: DependencyGraph.Node, _ evaluator: Evaluator) {
        status[id] = .evaluating
        started[id] = clock
        clock += 1
        evaluating.append(id)
        let savedSheet = evaluator.sheetIndex, savedAddress = evaluator.address
        let savedShift = evaluator.shift, savedOverride = evaluator.override
        evaluator.sheetIndex = node.sheet
        evaluator.address = node.address
        evaluator.shift = (0, 0)
        evaluator.override = nil
        let result = evaluatePivot(id, pivot, node: node, evaluator)
        evaluator.sheetIndex = savedSheet
        evaluator.address = savedAddress
        evaluator.shift = savedShift
        evaluator.override = savedOverride
        evaluating.removeLast()
        cycleFinish[id] = circular[id]
        if circular[id] {
            finish(id, .value(.error(FormulaErrors.circular)), evaluator)
        } else {
            finishPivot(id, result, evaluator)
        }
    }

    private func finish(_ id: Int, _ result: FormulaResult, _ evaluator: Evaluator, decoration: CellDecoration? = nil) {
        if graph.nodes[id]?.pivot != nil {
            // A pivot table on a cycle shows the error in its anchor.
            switch result {
            case .value(let value): finishPivot(id, value == .empty ? .nothing : .cells(ValueMatrix(value)), evaluator)
            case .array(let values): finishPivot(id, .cells(values), evaluator)
            }
            return
        }
        if status[id] != .evaluating {
            started[id] = clock
            clock += 1
        }
        decorations[id] = decoration
        switch result {
        case .value(let value):
            results[id] = value
            placeSpill(id, nil, evaluator)
        case .array(let values):
            results[id] = placeSpill(id, values, evaluator) ?? values[0, 0]
        }
        done(id)
    }

    private func done(_ id: Int) {
        status[id] = .done
        if !reported[id] {
            reported[id] = true
            evaluated.append(id)
        }
    }

    // MARK: Pivot tables

    /// What a pivot table computed: nothing to show, its cells, or a size too big for the grid.
    private enum PivotResult {
        case nothing
        case cells(ValueMatrix)
        case oversized(rows: Int, columns: Int)
    }

    /// Computes a pivot table from its source's current values (formulas there run first).
    private func evaluatePivot(_ id: Int, _ pivot: PivotTable, node: DependencyGraph.Node, _ evaluator: Evaluator) -> PivotResult {
        let sheet = evaluator.workbook.sheets[node.sheet]
        let limit = (rows: max(0, sheet.rowCount - node.address.row), columns: max(0, sheet.columnCount - node.address.column))
        let evaluation = PivotEngine.evaluate(pivot, sheetIndex: node.sheet, evaluator: evaluator, now: evaluator.now, limit: limit)
        graph.pivotOutputs[id] = evaluation.output
        graph.pivotAxes[id] = evaluation.axes
        if let error = evaluation.error { return .cells(ValueMatrix(.error(error))) }
        if let values = evaluation.values { return .cells(values) }
        if evaluation.rowCount > 0, evaluation.columnCount > 0 {
            return .oversized(rows: evaluation.rowCount, columns: evaluation.columnCount)
        }
        return .nothing
    }

    private func finishPivot(_ id: Int, _ result: PivotResult, _ evaluator: Evaluator) {
        if status[id] != .evaluating {
            started[id] = clock
            clock += 1
        }
        switch result {
        case .nothing:
            if graph.spills[id] != nil { store(id, nil, evaluator) }
        case .cells(let values):
            placePivot(id, rows: values.rows, columns: values.columns, values: values, evaluator)
        case .oversized(let rows, let columns):
            placePivot(id, rows: rows, columns: columns, values: nil, evaluator)
        }
        results[id] = .empty
        done(id)
    }

    /// Places a pivot table's cells from its anchor down and right, every cell (the anchor included) in the
    /// spilled values. Data in the anchor (or an earlier-listed pivot table anchored there) leaves nothing
    /// shown; data, another pivot table's anchor or an earlier spill in the way, or the grid's edge, leaves
    /// the error in the anchor.
    private func placePivot(_ id: Int, rows: Int, columns: Int, values: ValueMatrix?, _ evaluator: Evaluator) {
        guard let node = graph.nodes[id] else { return }
        let origin = node.address
        let area = CellRange(rows: origin.row...(origin.row + rows - 1), columns: origin.column...(origin.column + columns - 1))
        let sheet = evaluator.workbook.sheets[node.sheet]
        func blocked(_ error: CellError) {
            store(id, SpillRecord(values: ValueMatrix(.error(error)), area: area, isActive: false, showsErrorInOrigin: true), evaluator)
        }
        guard origin.row < sheet.rowCount, origin.column < sheet.columnCount else {
            if graph.spills[id] != nil { store(id, nil, evaluator) }
            return
        }
        if sheet.cells[origin]?.hasContent == true || graph.pivotAnchorOwner(sheet: node.sheet, at: origin) != id {
            store(id, SpillRecord(values: ValueMatrix(.empty), area: area, isActive: false), evaluator)
            return
        }
        if area.end.row >= sheet.rowCount {
            blocked(CellError(.reference, "Result was not automatically expanded, please insert more rows (\(area.end.row - sheet.rowCount + 1))."))
            return
        }
        if area.end.column >= sheet.columnCount {
            blocked(CellError(.reference, "Result was not automatically expanded, please insert more columns (\(area.end.column - sheet.columnCount + 1))."))
            return
        }
        guard let values else {
            blocked(CellError(.reference, "Result was not automatically expanded, please insert more rows (1)."))
            return
        }
        let (first, displaced) = obstacles(for: id, sheet: node.sheet, area: area, origin: origin, cells: sheet.cells)
        if let first {
            blocked(CellError(.reference, "Array result was not expanded because it would overwrite data in \(first.a1)."))
            return
        }
        displace(displaced, evaluator)
        store(id, SpillRecord(values: values, area: area, isActive: true), evaluator)
    }

    /// What stands in the way of a spill over `area`: the first cell (reading order) holding data, a pivot
    /// table's anchor or an earlier spill, and the later spills it would push aside.
    private func obstacles(for id: Int, sheet: Int, area: CellRange, origin: CellAddress,
                           cells: [CellAddress: Cell]) -> (first: CellAddress?, displaced: [Int]) {
        var first = Self.firstContent(in: area, excluding: origin, cells: cells)
        if let anchor = graph.firstPivotAnchor(sheet: sheet, in: area, excluding: origin), first.map({ anchor < $0 }) ?? true {
            first = anchor
        }
        var displaced: [Int] = []
        graph.activeSpills[sheet].forEachDependent(intersecting: area) { other in
            guard other != id, let overlap = graph.spills[other]?.shownArea?.intersection(area) else { return }
            if graph.isBefore(other, id) {
                if first.map({ overlap.start < $0 }) ?? true { first = overlap.start }
            } else {
                displaced.append(other)
            }
        }
        return (first, displaced)
    }

    /// Later spills give way: they stop showing and run again next round.
    private func displace(_ displaced: [Int], _ evaluator: Evaluator) {
        for other in graph.readingOrder(displaced) {
            guard var record = graph.spills[other], record.isActive else { continue }
            record.isActive = false
            record.showsErrorInOrigin = false
            store(other, record, evaluator)
            forcedStale.insert(other)
        }
    }

    /// Places an array result: spills it when its cells are free, otherwise returns the error the formula
    /// shows. Returns the formula cell's value (nil for single values, which leave no spill).
    @discardableResult
    private func placeSpill(_ id: Int, _ values: ValueMatrix?, _ evaluator: Evaluator) -> CellValue? {
        guard let values else {
            if graph.spills[id] != nil { store(id, nil, evaluator) }
            return nil
        }
        guard let node = graph.nodes[id] else { return nil }
        let origin = node.address
        let area = CellRange(rows: origin.row...(origin.row + values.rows - 1),
                             columns: origin.column...(origin.column + values.columns - 1))
        let sheet = evaluator.workbook.sheets[node.sheet]
        var blocker: CellError?
        var displaced: [Int] = []
        if area.end.row >= sheet.rowCount {
            blocker = CellError(.reference, "Result was not automatically expanded, please insert more rows (\(area.end.row - sheet.rowCount + 1)).")
        } else if area.end.column >= sheet.columnCount {
            blocker = CellError(.reference, "Result was not automatically expanded, please insert more columns (\(area.end.column - sheet.columnCount + 1)).")
        } else {
            let found = obstacles(for: id, sheet: node.sheet, area: area, origin: origin, cells: sheet.cells)
            displaced = found.displaced
            if let first = found.first {
                blocker = CellError(.reference, "Array result was not expanded because it would overwrite data in \(first.a1).")
            }
        }
        // A later formula's spill gives way.
        if blocker == nil { displace(displaced, evaluator) }
        store(id, SpillRecord(values: values, area: area, isActive: blocker == nil), evaluator)
        return blocker.map(CellValue.error) ?? values[0, 0]
    }

    /// Saves a spill record, noting the areas whose spilled values changed (their readers may need to run
    /// again) and waking blocked spills that overlap freed cells.
    private func store(_ id: Int, _ record: SpillRecord?, _ evaluator: Evaluator) {
        guard let sheet = graph.nodes[id]?.sheet else { return }
        let shownBefore = graph.spills[id]?.shownArea
        let change = graph.setSpill(id, record)
        for area in change.changed {
            spillChanges.append((sheet, area, clock))
            evaluator.invalidateRanges(sheet: sheet, intersecting: area)
        }
        if let freed = change.freed {
            graph.spillAreas[sheet].forEachDependent(intersecting: freed) { other in
                if other != id, graph.spills[other]?.isActive == false { forcedStale.insert(other) }
            }
        }
        // Later spills already blocked where this one now shows run again, so that their error names the
        // first cell in the way whatever order the formulas ran in.
        if let shown = record?.shownArea, shown != shownBefore {
            graph.spillAreas[sheet].forEachDependent(intersecting: shown) { other in
                if other != id, graph.spills[other]?.isActive == false, graph.isBefore(id, other) { forcedStale.insert(other) }
            }
        }
    }

    /// The first cell of `area` in reading order (other than `origin`) holding a value or formula.
    private static func firstContent(in area: CellRange, excluding origin: CellAddress, cells: [CellAddress: Cell]) -> CellAddress? {
        if area.cellCount <= cells.count {
            for row in area.rows {
                for column in area.columns {
                    let address = CellAddress(row: row, column: column)
                    if address != origin, cells[address]?.hasContent == true { return address }
                }
            }
            return nil
        }
        var first: CellAddress?
        for (address, cell) in cells where address != origin && cell.hasContent && area.contains(address) {
            if first.map({ address < $0 }) ?? true { first = address }
        }
        return first
    }
}
