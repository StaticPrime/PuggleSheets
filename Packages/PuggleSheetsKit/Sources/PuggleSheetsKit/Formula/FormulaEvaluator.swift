import Foundation

/// The values of a block: its non-empty entries in row-major order, or the dense matrix, each derived
/// from the other on demand.
final class RangeData {
    let rows: Int
    let columns: Int
    private var storedEntries: [(index: Int, value: CellValue)]?
    private var storedMatrix: ValueMatrix?

    init(rows: Int, columns: Int, entries: [(index: Int, value: CellValue)]) {
        self.rows = rows
        self.columns = columns
        storedEntries = entries
    }

    init(matrix: ValueMatrix) {
        rows = matrix.rows
        columns = matrix.columns
        storedMatrix = matrix
    }

    var count: Int { rows * columns }

    /// Non-empty values with their row-major index.
    var entries: [(index: Int, value: CellValue)] {
        if let storedEntries { return storedEntries }
        var result: [(index: Int, value: CellValue)] = []
        for (index, value) in (storedMatrix?.values ?? []).enumerated() {
            if case .empty = value { continue }
            result.append((index, value))
        }
        storedEntries = result
        return result
    }

    var matrix: ValueMatrix {
        if let storedMatrix { return storedMatrix }
        var values = [CellValue](repeating: .empty, count: rows * columns)
        for entry in storedEntries ?? [] { values[entry.index] = entry.value }
        let matrix = ValueMatrix(rows: rows, columns: columns, values: values)
        storedMatrix = matrix
        return matrix
    }

    /// The value at a row-major index; answered from the sparse entries unless the matrix exists.
    func value(at index: Int) -> CellValue {
        if let storedMatrix { return storedMatrix.values[index] }
        let entries = self.entries
        var low = 0, high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].index < index { low = middle + 1 } else { high = middle }
        }
        return low < entries.count && entries[low].index == index ? entries[low].value : .empty
    }

    func value(row: Int, column: Int) -> CellValue { value(at: row * columns + column) }

    private var columnCache: [Int: [CellValue]] = [:]
    private var rowCache: [Int: [CellValue]] = [:]
    private var indexCache: [Int: LookupIndex] = [:]

    func column(_ index: Int) -> [CellValue] {
        if let cached = columnCache[index] { return cached }
        var values: [CellValue]
        if let storedMatrix {
            values = storedMatrix.column(index)
        } else {
            values = Array(repeating: .empty, count: rows)
            for entry in entries where entry.index % columns == index { values[entry.index / columns] = entry.value }
        }
        columnCache[index] = values
        return values
    }

    func row(_ index: Int) -> [CellValue] {
        if let cached = rowCache[index] { return cached }
        let values = storedMatrix?.row(index) ?? (0..<columns).map { value(row: index, column: $0) }
        rowCache[index] = values
        return values
    }

    /// An index for exact lookups in a column (`vertical`) or row.
    func lookupIndex(_ index: Int, vertical: Bool) -> LookupIndex {
        let key = vertical ? index : -1 - index
        if let cached = indexCache[key] { return cached }
        let lookup = LookupIndex(vertical ? column(index) : row(index))
        indexCache[key] = lookup
        return lookup
    }
}

/// First positions of each value in a list, for exact matching (text ignores case).
final class LookupIndex {
    private var numbers: [Double: Int] = [:]
    private var texts: [String: Int] = [:]
    private var booleans: [Bool: Int] = [:]

    init(_ values: [CellValue]) {
        for (position, value) in values.enumerated() {
            switch value {
            case .number(let number): if numbers[number] == nil { numbers[number] = position }
            case .text(let text):
                let key = text.lowercased()
                if texts[key] == nil { texts[key] = position }
            case .boolean(let boolean): if booleans[boolean] == nil { booleans[boolean] = position }
            default: break
            }
        }
    }

    func firstPosition(of value: CellValue) -> Int? {
        switch value {
        case .number(let number): numbers[number]
        case .text(let text): texts[text.lowercased()]
        case .boolean(let boolean): booleans[boolean]
        default: nil
        }
    }
}

/// What a formula leaves: one value, or an array that spills over neighboring cells.
enum FormulaResult: Equatable {
    case value(CellValue)
    case array(ValueMatrix)
}

/// Evaluates expressions for one workbook snapshot. During a recalculation `pass` supplies the fresh
/// values of formula cells and spilled cells; otherwise they come from the workbook.
final class Evaluator {
    let workbook: Workbook
    let now: Date
    var sheetIndex: Int
    var address: CellAddress
    var pass: RecalcPass?
    /// Moves relative references by this many rows and columns, as if the formula had been copied there
    /// (rule formulas count from the top-left cell of their range).
    var shift = (rows: 0, columns: 0)
    /// A value standing in for one cell's (data validation checks input before it's committed).
    var override: (sheet: Int, address: CellAddress, value: CellValue)?
    /// Bumped whenever a read runs into a cell that is still being computed (a cycle).
    var cycleHits = 0
    /// The decoration of the value `evaluate` returned last, when that value is a HYPERLINK or SPARKLINE
    /// result passed on unchanged (through IF, IFERROR, CHOOSE, LET…); nil otherwise.
    var currentDecoration: CellDecoration?
    /// Set by HYPERLINK's and SPARKLINE's implementations for `call` to pick up.
    var pendingDecoration: CellDecoration?
    /// LET and LAMBDA names in effect.
    var scope: Scope?
    /// LAMBDA calls in progress.
    var lambdaDepth = 0
    private var rangeCache: [SheetReference: (data: RangeData, generation: Int)] = [:]
    /// Bumped per sheet whenever spilled values there change; cached ranges from an older generation are stale.
    private var spillGenerations: [Int: Int] = [:]
    private var sheetLookup: [String: Int] = [:]
    private var nameCache: [String: FormulaValue] = [:]
    var regexCache: [String: NSRegularExpression] = [:]

    init(workbook: Workbook, sheetIndex: Int, address: CellAddress, now: Date) {
        self.workbook = workbook
        self.sheetIndex = sheetIndex
        self.address = address
        self.now = now
    }

    /// The value a formula leaves in its cell: the top-left element of arrays and ranges.
    func evaluateFormula(_ formula: ParsedFormula) -> CellValue {
        Self.finite(scalar(evaluate(formula.expression)))
    }

    /// The value or array a formula produces.
    func evaluateFormulaResult(_ formula: ParsedFormula) -> FormulaResult {
        evaluateFormulaResultAndDecoration(formula).result
    }

    /// The value or array a formula produces, and the link or sparkline its cell shows when that value came
    /// from HYPERLINK or SPARKLINE.
    func evaluateFormulaResultAndDecoration(_ formula: ParsedFormula) -> (result: FormulaResult, decoration: CellDecoration?) {
        let value = evaluate(formula.expression)
        let decoration = currentDecoration
        let result = formulaResult(value)
        guard let decoration, case .value(let shown) = result, shown.errorValue == nil else { return (result, nil) }
        return (result, decoration)
    }

    private func formulaResult(_ value: FormulaValue) -> FormulaResult {
        switch value {
        case .value(let value):
            return .value(Self.finite(value))
        case .array(let matrix):
            return matrix.isSingle ? .value(Self.finite(matrix.values[0])) : .array(matrix.map(Self.finite))
        case .reference(let reference):
            if reference.range.isSingleCell {
                return .value(Self.finite(cellValue(sheet: reference.sheet, address: reference.range.start)))
            }
            return .array(rangeData(reference).matrix)
        case .lambda(let lambda):
            return .value(.error(lambda.uncalledError))
        }
    }

    /// NaN and infinities become #NUM!.
    static func finite(_ value: CellValue) -> CellValue {
        if case .number(let number) = value, !number.isFinite { return .error(FormulaErrors.notFinite) }
        return value
    }

    /// Forgets cached range values (they may hold results that are about to be recomputed).
    func clearCaches() {
        rangeCache.removeAll()
    }

    /// Forgets cached ranges of a sheet whose spilled values changed in `area`.
    func invalidateRanges(sheet: Int, intersecting area: CellRange) {
        guard !rangeCache.isEmpty else { return }
        spillGenerations[sheet, default: 0] += 1
    }

    // MARK: Cells and ranges

    func lookupSheet(_ name: String) -> Int? {
        if let index = sheetLookup[name] { return index >= 0 ? index : nil }
        let index = workbook.sheetIndex(named: name) ?? -1
        sheetLookup[name] = index
        return index >= 0 ? index : nil
    }

    /// What a cell holds: its value, its formula's fresh result, or a value spilled into it.
    func cellValue(sheet: Int, address: CellAddress) -> CellValue {
        if let override, override.sheet == sheet, override.address == address { return override.value }
        if let cell = workbook.sheets[sheet].cells[address], cell.hasContent {
            guard cell.formula != nil, let pass else { return cell.value }
            return pass.value(sheet: sheet, address: address, stored: cell.value, evaluator: self)
        }
        return spilledValue(sheet: sheet, address: address) ?? .empty
    }

    /// The value an array formula spilled into a cell without content, if any.
    func spilledValue(sheet: Int, address: CellAddress) -> CellValue? {
        if let pass { return pass.spilledValue(sheet: sheet, address: address, evaluator: self) }
        let spilled = workbook.sheets[sheet].spilledValues
        return spilled.isEmpty ? nil : spilled[address]
    }

    /// The values spilled into the cells of a block.
    func spilledEntries(sheet: Int, in range: CellRange) -> [(address: CellAddress, value: CellValue)] {
        if let pass { return pass.spilledEntries(sheet: sheet, in: range, evaluator: self) }
        let spillSheet = workbook.sheets[sheet]
        guard !spillSheet.spillRanges.isEmpty else { return [] }
        var result: [(address: CellAddress, value: CellValue)] = []
        // A formula's own cell holds no spilled value; a pivot table's anchor does.
        for area in spillSheet.spillRanges.values {
            guard let overlap = area.intersection(range) else { continue }
            for row in overlap.rows {
                for column in overlap.columns {
                    let address = CellAddress(row: row, column: column)
                    if let value = spillSheet.spilledValues[address] { result.append((address, value)) }
                }
            }
        }
        return result
    }

    func rangeData(_ reference: SheetReference) -> RangeData {
        let generation = spillGenerations[reference.sheet] ?? 0
        if let cached = rangeCache[reference], cached.generation == generation { return cached.data }
        let hits = cycleHits
        let data = loadRange(reference)
        if hits == cycleHits { rangeCache[reference] = (data, spillGenerations[reference.sheet] ?? 0) }
        return data
    }

    private func loadRange(_ reference: SheetReference) -> RangeData {
        let cells = workbook.sheets[reference.sheet].cells
        let range = reference.range
        let top = range.start.row, left = range.start.column, columns = range.columnCount
        var entries: [(index: Int, value: CellValue)] = []

        func add(_ address: CellAddress, _ cell: Cell) {
            var value = cell.value
            if cell.formula != nil, let pass {
                value = pass.value(sheet: reference.sheet, address: address, stored: cell.value, evaluator: self)
            }
            if case .empty = value { return }
            entries.append(((address.row - top) * columns + (address.column - left), value))
        }

        var sorted = true
        // Looking cells up hops around memory; walking the whole dictionary is several times cheaper per
        // cell, so it wins unless the block is a small part of the sheet.
        if range.cellCount * 4 <= cells.count {
            for row in range.rows {
                for column in range.columns {
                    let address = CellAddress(row: row, column: column)
                    if let cell = cells[address] { add(address, cell) }
                }
            }
        } else {
            for (address, cell) in cells where range.contains(address) { add(address, cell) }
            sorted = false
        }
        for (address, value) in spilledEntries(sheet: reference.sheet, in: range) where cells[address]?.hasContent != true {
            if case .empty = value { continue }
            entries.append(((address.row - top) * columns + (address.column - left), value))
            sorted = false
        }
        if let override, override.sheet == reference.sheet, range.contains(override.address) {
            let index = (override.address.row - top) * columns + (override.address.column - left)
            entries.removeAll { $0.index == index }
            if override.value != .empty { entries.append((index, override.value)) }
            sorted = false
        }
        if !sorted {
            // A mostly filled block is cheaper to lay out densely than to sort.
            if entries.count * 8 >= range.cellCount {
                var values = [CellValue](repeating: .empty, count: range.cellCount)
                for entry in entries { values[entry.index] = entry.value }
                return RangeData(matrix: ValueMatrix(rows: range.rowCount, columns: columns, values: values))
            }
            entries.sort { $0.index < $1.index }
        }
        return RangeData(rows: range.rowCount, columns: columns, entries: entries)
    }

    /// The block a reference names, relative parts moved by `shift`; unqualified references point to
    /// the current sheet.
    func resolve(_ reference: ReferenceSyntax) -> FormulaValue {
        guard shift.rows != 0 || shift.columns != 0 else { return resolve(reference, defaultSheet: sheetIndex) }
        guard let moved = Self.shifted(reference, rows: shift.rows, columns: shift.columns) else {
            return .error(FormulaErrors.outOfGrid)
        }
        return resolve(moved, defaultSheet: sheetIndex)
    }

    func resolve(_ reference: ReferenceSyntax, defaultSheet: Int) -> FormulaValue {
        var sheet = defaultSheet
        if let name = reference.sheet {
            guard let index = lookupSheet(name) else { return .error(FormulaErrors.unresolvedSheet(name)) }
            sheet = index
        }
        guard workbook.sheets.indices.contains(sheet),
              let range = reference.range(rowCount: workbook.sheets[sheet].rowCount,
                                          columnCount: workbook.sheets[sheet].columnCount) else {
            return .error(FormulaErrors.outOfGrid)
        }
        return .reference(SheetReference(sheet: sheet, range: range))
    }

    /// A reference with its relative parts moved, or nil when that leaves the grid's top or left edge.
    static func shifted(_ reference: ReferenceSyntax, rows: Int, columns: Int) -> ReferenceSyntax? {
        var result = reference
        func move(_ part: inout ReferencePart) -> Bool {
            if let row = part.row, !part.rowAbsolute { part.row = row + rows }
            if let column = part.column, !part.columnAbsolute { part.column = column + columns }
            return (part.row ?? 0) >= 0 && (part.column ?? 0) >= 0
        }
        guard move(&result.first) else { return nil }
        if result.second != nil, !move(&result.second!) { return nil }
        return result
    }

    /// The block a named range covers (unqualified references in it point to the first sheet), or a whole
    /// table named so.
    func resolveName(_ name: String) -> FormulaValue {
        if let cached = nameCache[name] { return cached }
        let value: FormulaValue
        if let named = workbook.namedRange(name) {
            if let syntax = NamedRanges.syntax(of: named) {
                value = resolve(syntax, defaultSheet: 0)
            } else {
                value = .error(.reference, "Named range '\(named.name)' doesn't refer to a range.")
            }
        } else if let (sheet, table) = workbook.table(named: name) {
            value = .reference(SheetReference(sheet: sheet, range: table.range))
        } else {
            value = .error(FormulaErrors.unknownName(name))
        }
        nameCache[name] = value
        return value
    }

    /// The block a structured reference covers: Table1[#ALL], Table1[Sales], Table1[[#HEADERS],[Q1]:[Q4]].
    func resolveTable(_ reference: TableReferenceSyntax) -> FormulaValue {
        guard let (sheet, table) = workbook.table(named: reference.table) else {
            return .error(FormulaErrors.unknownName(reference.table))
        }
        var rows = table.range.rows
        switch reference.area {
        case .all: break
        case .data: rows = (table.dataRange ?? table.range).rows
        case .headers: rows = table.headerRow...table.headerRow
        }
        var columns = table.range.columns
        if let first = reference.firstColumn, let last = reference.lastColumn {
            guard let start = tableColumn(first, of: table, sheet: sheet) else { return .error(Self.missingColumn(first, table)) }
            guard let end = tableColumn(last, of: table, sheet: sheet) else { return .error(Self.missingColumn(last, table)) }
            columns = min(start, end)...max(start, end)
        }
        return .reference(SheetReference(sheet: sheet, range: CellRange(rows: rows, columns: columns)))
    }

    /// The sheet column whose header shows `name` (ignoring case).
    func tableColumn(_ name: String, of table: SheetTable, sheet: Int) -> Int? {
        for column in table.range.columns {
            let header = cellValue(sheet: sheet, address: CellAddress(row: table.headerRow, column: column))
            if CellDisplay.text(for: header, pattern: nil).text.caseInsensitiveCompare(name) == .orderedSame { return column }
        }
        return nil
    }

    private static func missingColumn(_ name: String, _ table: SheetTable) -> CellError {
        CellError(.reference, "Column '\(name)' doesn't exist in table '\(table.name)'.")
    }

    /// The pivot table showing in a cell: its output and layout (from the recalculation when there is one).
    func pivot(sheet: Int, address: CellAddress) -> (output: PivotOutput, axes: PivotEngine.Axes)? {
        if let pass { return pass.pivot(sheet: sheet, address: address, evaluator: self) }
        guard workbook.sheets.indices.contains(sheet), let pivot = workbook.sheets[sheet].pivotTable(covering: address),
              (workbook.sheets[sheet].spillRanges[pivot.anchor]?.cellCount ?? 0) > 1 else { return nil }
        let evaluator = Evaluator(workbook: workbook, sheetIndex: sheet, address: pivot.anchor, now: now)
        let evaluation = PivotEngine.evaluate(PivotEngine.effective(pivot, sheetIndex: sheet, workbook: workbook), sheetIndex: sheet,
                                              evaluator: evaluator, now: now, limit: nil)
        guard let output = evaluation.output, let axes = evaluation.axes else { return nil }
        return (output, axes)
    }

    // MARK: LAMBDA

    /// A LET or LAMBDA name's value, or the named range or table it names.
    @inline(never)
    private func boundValue(_ name: String) -> FormulaValue {
        switch scope?.lookup(name) {
        case .value(let bound)?: return bound
        case .omitted?: return .value(.empty)
        case nil: return resolveName(name)
        }
    }

    /// A call of a LET or LAMBDA name holding a LAMBDA, or of what an expression produces (sets the decoration).
    @inline(never)
    private func evaluateCall(_ expression: Expr) -> FormulaValue {
        switch expression {
        case .unknownFunction(let name, let arguments):
            if case .value(.lambda(let lambda))? = scope?.lookup(name) { return invoke(lambda, arguments) }
            currentDecoration = nil
            return .error(FormulaErrors.unknownFunction(name))
        case .invoke(let callee, let arguments):
            let target = evaluate(callee)
            if case .lambda(let lambda) = target { return invoke(lambda, arguments) }
            currentDecoration = nil
            return .error(target.errorValue ?? CellError(.value, "The value called isn't a LAMBDA."))
        default:
            return evaluate(expression)
        }
    }

    /// Calls a LAMBDA with argument expressions, evaluated here; empty ones are omitted arguments.
    func invoke(_ lambda: Lambda, _ arguments: [Expr]) -> FormulaValue {
        var values: [Scope.Binding] = []
        values.reserveCapacity(arguments.count)
        for argument in arguments {
            if case .missing = argument {
                values.append(.omitted)
            } else {
                values.append(.value(evaluate(argument)))
            }
        }
        return invoke(lambda, values)
    }

    /// Calls a LAMBDA: its body runs with its parameters bound to `arguments`, in the scope it was made in.
    func invoke(_ lambda: Lambda, _ arguments: [Scope.Binding]) -> FormulaValue {
        guard arguments.count == lambda.parameters.count else {
            currentDecoration = nil
            return .error(FormulaErrors.lambdaArguments(expected: lambda.parameters.count, got: arguments.count))
        }
        // Calls nest on the stack (a LAMBDA can be handed itself): past what a small stack holds, a
        // recalculation starts over on a big one; beyond that, it's an error.
        guard lambdaDepth < (pass?.lambdaDepthLimit ?? 24) else {
            pass?.needsBigStack()
            currentDecoration = nil
            return .error(FormulaErrors.lambdaDepth)
        }
        lambdaDepth += 1
        let saved = scope
        scope = Scope(Dictionary(zip(lambda.parameters, arguments), uniquingKeysWith: { first, _ in first }), parent: lambda.scope)
        defer {
            scope = saved
            lambdaDepth -= 1
        }
        return evaluate(lambda.body)
    }

    /// Calls a LAMBDA with values (for MAP, REDUCE and the like).
    func call(_ lambda: Lambda, _ arguments: [FormulaValue]) -> FormulaValue {
        invoke(lambda, arguments.map { .value($0) })
    }

    // MARK: Value shapes

    /// A single value: the top-left element of arrays and ranges.
    func scalar(_ value: FormulaValue) -> CellValue {
        switch value {
        case .value(let value): value
        case .array(let matrix): matrix.values[0]
        case .reference(let reference): cellValue(sheet: reference.sheet, address: reference.range.start)
        case .lambda(let lambda): .error(lambda.uncalledError)
        }
    }

    /// Single cells become values and blocks become arrays, ready for element-wise operations.
    func operand(_ value: FormulaValue) -> FormulaValue {
        switch value {
        case .value: value
        case .array(let matrix): matrix.isSingle ? .value(matrix.values[0]) : value
        case .reference(let reference):
            reference.range.isSingleCell
                ? .value(cellValue(sheet: reference.sheet, address: reference.range.start))
                : .array(rangeData(reference).matrix)
        case .lambda(let lambda): .value(.error(lambda.uncalledError))
        }
    }

    func matrix(_ value: FormulaValue) -> ValueMatrix {
        switch value {
        case .value(let value): ValueMatrix(value)
        case .array(let matrix): matrix
        case .reference(let reference):
            reference.range.isSingleCell
                ? ValueMatrix(cellValue(sheet: reference.sheet, address: reference.range.start))
                : rangeData(reference).matrix
        case .lambda(let lambda): ValueMatrix(.error(lambda.uncalledError))
        }
    }

    func data(_ value: FormulaValue) -> RangeData {
        switch value {
        case .reference(let reference) where !reference.range.isSingleCell: rangeData(reference)
        default: RangeData(matrix: matrix(value))
        }
    }

    // MARK: Expressions

    func evaluate(_ expression: Expr) -> FormulaValue {
        // One frame per nesting level: deep formulas and chains of dynamic references recurse through here.
        let value: FormulaValue
        switch expression {
        case .call(let function, let arguments):
            return call(function, arguments)
        case .literal(let literal):
            value = .value(literal)
        case .missing:
            value = .value(.empty)
        case .reference(let reference):
            value = resolve(reference)
        case .name(let name):
            value = scope == nil ? resolveName(name) : boundValue(name)
        case .array(let rows):
            value = arrayLiteral(rows)
        case .negate(let operand):
            value = unary(evaluate(operand), function: "UMINUS") { -$0 }
        case .plus(let operand):
            value = self.operand(evaluate(operand))
        case .percent(let operand):
            value = unary(evaluate(operand), function: "UNARY_PERCENT") { $0 / 100 }
        case .binary(let op, let lhs, let rhs):
            let left = evaluate(lhs)
            value = binary(op, left, evaluate(rhs))
        case .range(let lhs, let rhs):
            let left = evaluate(lhs)
            value = rangeOperator(left, evaluate(rhs))
        case .unknownFunction, .invoke:
            return evaluateCall(expression)
        case .tableReference(let reference):
            value = resolveTable(reference)
        }
        currentDecoration = nil
        return value
    }

    private func arrayLiteral(_ rows: [[Expr]]) -> FormulaValue {
        var blocks: [ValueMatrix] = []
        for row in rows {
            var pieces: [ValueMatrix] = []
            for element in row { pieces.append(matrix(evaluate(element))) }
            let height = pieces[0].rows
            guard pieces.allSatisfy({ $0.rows == height }) else {
                return .error(.value, "Function ARRAY_ROW parameter 2 has mismatched row size. Expected: \(height).")
            }
            var values: [CellValue] = []
            for r in 0..<height {
                for piece in pieces { values += piece.row(r) }
            }
            blocks.append(ValueMatrix(rows: height, columns: values.count / height, values: values))
        }
        let width = blocks[0].columns
        guard blocks.allSatisfy({ $0.columns == width }) else {
            return .error(.value, "In ARRAY_LITERAL, an Array Literal was missing values for one or more rows.")
        }
        let values = blocks.flatMap(\.values)
        let matrix = ValueMatrix(rows: values.count / width, columns: width, values: values)
        return matrix.isSingle ? .value(matrix.values[0]) : .array(matrix)
    }

    private func unary(_ value: FormulaValue, function: String, _ transform: (Double) -> Double) -> FormulaValue {
        func apply(_ value: CellValue) -> CellValue {
            do {
                let result = transform(try Coercion.number(value, function: function, parameter: 1))
                return result.isFinite ? .number(result == 0 ? 0 : result) : .error(FormulaErrors.notFinite)
            } catch {
                return .error(error as? CellError ?? CellError(.value))
            }
        }
        switch operand(value) {
        case .value(let value): return .value(apply(value))
        case .array(let matrix): return .array(matrix.map(apply))
        case .reference, .lambda: return .error(.value)
        }
    }

    func binary(_ op: FormulaOperator, _ lhs: FormulaValue, _ rhs: FormulaValue) -> FormulaValue {
        let a = operand(lhs), b = operand(rhs)
        if case .value(let x) = a, case .value(let y) = b { return .value(Self.apply(op, x, y)) }
        let left = matrix(a), right = matrix(b)
        let rows = max(left.rows, right.rows), columns = max(left.columns, right.columns)
        var values: [CellValue] = []
        values.reserveCapacity(rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                values.append(Self.apply(op, left.broadcastValue(row: row, column: column),
                                         right.broadcastValue(row: row, column: column)))
            }
        }
        return .array(ValueMatrix(rows: rows, columns: columns, values: values))
    }

    /// An operator applied to two single values.
    static func apply(_ op: FormulaOperator, _ a: CellValue, _ b: CellValue) -> CellValue {
        if case .error = a { return a }
        if case .error = b { return b }
        switch op {
        case .concatenate:
            return .text(((try? Coercion.text(a)) ?? "") + ((try? Coercion.text(b)) ?? ""))
        case .equal: return .boolean(Coercion.equals(a, b))
        case .notEqual: return .boolean(!Coercion.equals(a, b))
        case .less: return .boolean(Coercion.compare(a, b) < 0)
        case .greater: return .boolean(Coercion.compare(a, b) > 0)
        case .lessOrEqual: return .boolean(Coercion.compare(a, b) <= 0)
        case .greaterOrEqual: return .boolean(Coercion.compare(a, b) >= 0)
        default:
            break
        }
        let x: Double, y: Double
        do {
            x = try Coercion.number(a, function: op.functionName, parameter: 1)
            y = try Coercion.number(b, function: op.functionName, parameter: 2)
        } catch {
            return .error(error as? CellError ?? CellError(.value))
        }
        let result: Double
        switch op {
        case .add: result = x + y
        case .subtract: result = x - y
        case .multiply: result = x * y
        case .divide:
            guard y != 0 else { return .error(FormulaErrors.divideByZero) }
            result = x / y
        case .power:
            if x == 0, y < 0 {
                return .error(CellError(.divideByZero, "Function POW parameter 2 cannot be negative when parameter 1 is zero."))
            }
            result = Foundation.pow(x, y)
        default:
            return .error(CellError(.value))
        }
        guard result.isFinite else { return .error(FormulaErrors.notFinite) }
        return .number(result == 0 ? 0 : result)
    }

    private func rangeOperator(_ lhs: FormulaValue, _ rhs: FormulaValue) -> FormulaValue {
        if let error = lhs.errorValue { return .error(error) }
        if let error = rhs.errorValue { return .error(error) }
        guard case .reference(let a) = lhs, case .reference(let b) = rhs, a.sheet == b.sheet else {
            return .error(.value, "Range operator ':' expects cell references.")
        }
        return .reference(SheetReference(sheet: a.sheet, range: a.range.union(b.range)))
    }

    // MARK: Functions

    /// Calls a function and sets `currentDecoration`: HYPERLINK's link or SPARKLINE's chart, the passed-on
    /// argument's for lazy functions that return an argument unchanged, nil otherwise.
    func call(_ function: FunctionDef, _ arguments: [Expr]) -> FormulaValue {
        guard arguments.count >= function.minArguments, arguments.count <= function.maxArguments else {
            currentDecoration = nil
            return .error(FormulaErrors.argumentCount(function.name, min: function.minArguments,
                                                      max: function.maxArguments, got: arguments.count))
        }
        switch function.body {
        case .lazy(let body):
            let passed = LinkPassing()
            let result = body(LazyArguments(function: function, expressions: arguments, evaluator: self, passed: passed))
            currentDecoration = passed.decoration
            return result
        case .eager(let body):
            var values: [FormulaValue] = []
            values.reserveCapacity(arguments.count)
            for argument in arguments { values.append(evaluate(argument)) }
            if function.liftMask != 0, let lifted = lift(function, body, values) {
                pendingDecoration = nil
                currentDecoration = nil
                return lifted
            }
            pendingDecoration = nil
            let result = invoke(function, body, values)
            currentDecoration = pendingDecoration
            pendingDecoration = nil
            return result
        }
    }

    func invoke(_ function: FunctionDef, _ body: FunctionDef.EagerBody, _ values: [FormulaValue]) -> FormulaValue {
        do {
            return try body(Arguments(function: function, values: values, evaluator: self))
        } catch {
            return .error(error as? CellError ?? CellError(.value))
        }
    }

    /// Calls a function once per element when arrays are passed where it expects single values.
    private func lift(_ function: FunctionDef, _ body: FunctionDef.EagerBody, _ values: [FormulaValue]) -> FormulaValue? {
        var lifted: [(index: Int, matrix: ValueMatrix)] = []
        for (index, value) in values.enumerated() where function.lifts(index) {
            switch value {
            case .array(let matrix) where !matrix.isSingle:
                lifted.append((index, matrix))
            case .reference(let reference) where !reference.range.isSingleCell:
                lifted.append((index, rangeData(reference).matrix))
            default:
                continue
            }
        }
        guard !lifted.isEmpty else { return nil }
        let rows = lifted.map(\.matrix.rows).max()!, columns = lifted.map(\.matrix.columns).max()!
        var results: [CellValue] = []
        results.reserveCapacity(rows * columns)
        var elementValues = values
        for row in 0..<rows {
            for column in 0..<columns {
                for (index, matrix) in lifted {
                    elementValues[index] = .value(matrix.broadcastValue(row: row, column: column))
                }
                results.append(scalar(invoke(function, body, elementValues)))
            }
        }
        return .array(ValueMatrix(rows: rows, columns: columns, values: results))
    }
}
