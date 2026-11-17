import Foundation

extension FunctionTable {
    mutating func addQueryFunctions() {
        // QUERY(data, query, [headers])
        add("QUERY", 2, 3) { a in
            let data = try a.matrix(0)
            let text = try a.text(1)
            var headers: Int?
            if a.has(2), case .value(let value) = a.values[2], value != .empty {
                let count = try a.integer(2)
                guard count >= -1 else { throw CellError(.value, "Function QUERY parameter 3 value is \(count). It should be greater than or equal to -1.") }
                if count >= 0 { headers = count }
            }
            let ids: [String]
            if let reference = a.reference(0) {
                ids = reference.range.columns.map { CellAddress.columnName($0) }
            } else {
                ids = (1...max(1, data.columns)).map { "Col\($0)" }
            }
            switch QueryRun.run(text, data: data, ids: ids, headers: headers, now: a.evaluator.now) {
            case .success(let value): return value
            case .failure(let error):
                throw CellError(.value, "Unable to parse query string for Function QUERY parameter 2: \(error.detail)")
            }
        }
    }
}

/// Runs QUERY's query over a block of data.
///
/// Each column takes the type most of its values have (number, text or boolean); values of other types
/// count as null. Dates are numbers. Text compares with case. Groups (GROUP BY) and
/// pivot columns (PIVOT) come out sorted ascending; nulls sort first. FORMAT turns the formatted values
/// into text, since spilled values carry no number format.
struct QueryRun {
    private enum ColumnType { case number, text, boolean }

    private var columns: [[CellValue]] = []
    private var types: [ColumnType] = []
    private var labels: [String] = []
    private var rowCount = 0
    private let now: Date

    private init(now: Date) {
        self.now = now
    }

    static func run(_ text: String, data: ValueMatrix, ids: [String], headers: Int?, now: Date) -> Result<FormulaValue, QueryError> {
        switch QueryParser.parse(text) {
        case .failure(let error): return .failure(error)
        case .success(let statement):
            var run = QueryRun(now: now)
            do {
                return .success(try run.execute(statement, data: data, ids: ids, headers: headers ?? guessHeaders(data)))
            } catch let error as QueryError {
                return .failure(error)
            } catch {
                return .failure(QueryError("INTERNAL"))
            }
        }
    }

    // MARK: Data

    /// A guess at the header rows: the first row is a header when, in some column, it holds
    /// text over values that are mostly numbers or booleans.
    static func guessHeaders(_ data: ValueMatrix) -> Int {
        guard data.rows > 1 else { return 0 }
        for column in 0..<data.columns {
            guard case .text(let text) = data[0, column], !text.isEmpty else { continue }
            var textCount = 0, otherCount = 0
            for row in 1..<data.rows {
                switch data[row, column] {
                case .text(let value) where !value.isEmpty: textCount += 1
                case .number, .boolean: otherCount += 1
                default: break
                }
            }
            if otherCount > textCount { return 1 }
        }
        return 0
    }

    private mutating func load(_ data: ValueMatrix, headers: Int) {
        let width = data.columns
        let headerRows = min(headers, data.rows)
        rowCount = data.rows - headerRows
        labels = (0..<width).map { column in
            (0..<headerRows).map { row -> String in
                let value = data[row, column]
                if case .empty = value { return "" }
                return (try? Coercion.text(value)) ?? CellDisplay.text(for: value, pattern: nil).text
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        }
        columns = []
        types = []
        columns.reserveCapacity(width)
        for column in 0..<width {
            var values = [CellValue](repeating: .empty, count: rowCount)
            var numbers = 0, texts = 0, booleans = 0
            for row in 0..<rowCount {
                let value = data.values[(headerRows + row) * width + column]
                switch value {
                case .number: numbers += 1
                case .text(let text): if text.isEmpty { continue } else { texts += 1 }
                case .boolean: booleans += 1
                default: continue
                }
                values[row] = value
            }
            // The type most values have; the others are null.
            let type: ColumnType = numbers >= texts && numbers >= booleans && numbers > 0 ? .number
                : (booleans > texts ? .boolean : .text)
            for row in 0..<rowCount {
                switch (values[row], type) {
                case (.number, .number), (.text, .text), (.boolean, .boolean), (.empty, _): continue
                default: values[row] = .empty
                }
            }
            columns.append(values)
            types.append(type)
        }
    }

    // MARK: Running

    private mutating func execute(_ statement: QueryStatement, data: ValueMatrix, ids: [String], headers: Int) throws -> FormulaValue {
        load(data, headers: headers)
        var lookup: [String: Int] = [:]
        for (index, id) in ids.prefix(columns.count).enumerated() { lookup[id.uppercased()] = index }
        func resolve(_ node: QueryNode) throws -> QueryNode {
            switch node.resolved({ lookup[$0.uppercased()] }) {
            case .success(let resolved): return resolved
            case .failure(let error): throw error
            }
        }
        let select = try (statement.select ?? ids.prefix(columns.count).map { .column($0, index: nil) }).map(resolve)
        let filter = try statement.filter.map(resolve)
        let groupBy = try statement.groupBy.map(resolve)
        let pivot = try statement.pivot.map(resolve)
        let orderBy = try statement.orderBy.map { (node: try resolve($0.node), ascending: $0.ascending) }
        if let filter, filter.containsAggregate { throw QueryError("CANNOT_USE_AGGREGATION_IN_WHERE") }
        for node in groupBy + pivot where node.containsAggregate { throw QueryError("CANNOT_GROUP_BY_AGGREGATION") }
        for node in select + orderBy.map(\.node) { try checkAggregates(node) }

        var rows: [Int] = []
        rows.reserveCapacity(rowCount)
        for row in 0..<rowCount where filter.map({ truth(value($0, row: row)) }) ?? true { rows.append(row) }

        let grouped = !groupBy.isEmpty || !pivot.isEmpty || select.contains { $0.containsAggregate }
        var output: [[CellValue]]
        var outputLabels: [String]
        var outputNodes: [QueryNode]
        if grouped {
            // Columns used outside aggregates must be grouped.
            let groupTexts = Set(groupBy.map(\.text))
            for node in select where !groupTexts.contains(node.text) {
                var missing: String?
                node.columnsOutsideAggregates { id in
                    if missing == nil, !groupBy.contains(where: { if case .column(let other, _) = $0 { return other.uppercased() == id.uppercased() }; return false }) {
                        missing = id
                    }
                }
                if let missing { throw QueryError("ADD_COL_TO_GROUP_BY_OR_AGG: \(missing)") }
            }
            (output, outputLabels, outputNodes) = try runGrouped(select: select, groupBy: groupBy, pivot: pivot, orderBy: orderBy, rows: rows)
        } else {
            outputNodes = select
            outputLabels = select.map(label)
            var keyed: [(values: [CellValue], keys: [CellValue])] = rows.map { row in
                (select.map { value($0, row: row) }, orderBy.map { value($0.node, row: row) })
            }
            if !orderBy.isEmpty { Self.sort(&keyed, orderBy.map(\.ascending)) }
            output = keyed.map(\.values)
        }

        // OFFSET and LIMIT.
        if statement.offset > 0 { output = Array(output.dropFirst(statement.offset)) }
        if let limit = statement.limit { output = Array(output.prefix(limit)) }
        // LABEL and FORMAT apply to selected columns, matched by their text.
        for (node, label) in statement.labels {
            let text = try resolve(node).text
            if let column = outputNodes.firstIndex(where: { $0.text == text }) { outputLabels[column] = label }
        }
        for (node, pattern) in statement.formats {
            let text = try resolve(node).text
            guard let column = outputNodes.firstIndex(where: { $0.text == text }) else { continue }
            for row in output.indices where output[row][column] != .empty {
                output[row][column] = .text(CellDisplay.text(for: output[row][column], pattern: pattern).text)
            }
        }

        let width = outputLabels.count
        let showsHeader = headers > 0 || outputLabels.contains { !$0.isEmpty }
        guard !output.isEmpty || showsHeader, width > 0 else {
            return .error(.notAvailable, "Query completed with an empty output.")
        }
        var values: [CellValue] = []
        values.reserveCapacity((output.count + 1) * width)
        if showsHeader { values += outputLabels.map { CellValue.text($0) } }
        for row in output { values += row }
        let matrix = ValueMatrix(rows: values.count / width, columns: width, values: values)
        return matrix.isSingle ? .value(matrix.values[0]) : .array(matrix)
    }

    /// SUM and AVG need numbers.
    private func checkAggregates(_ node: QueryNode) throws {
        switch node {
        case .aggregate(let name, let argument):
            if argument.containsAggregate { throw QueryError("CANNOT_NEST_AGGREGATIONS") }
            if name == "sum" || name == "avg", case .column(_, let index?) = argument, types[index] != .number {
                throw QueryError("AVG_SUM_ONLY_NUMERIC")
            }
        case .arithmetic(_, let a, let b), .compare(_, let a, let b), .and(let a, let b), .or(let a, let b), .textTest(_, let a, let b):
            try checkAggregates(a)
            try checkAggregates(b)
        case .negate(let a), .not(let a), .isNull(let a, _): try checkAggregates(a)
        case .function(_, let arguments): try arguments.forEach(checkAggregates)
        case .column, .literal: break
        }
    }

    /// The column heading a selected expression gets: the column's header, "sum Amount" for
    /// aggregates, or the expression.
    private func label(_ node: QueryNode) -> String {
        switch node {
        case .column(_, let index?): return labels[index]
        case .aggregate(let name, .column(let id, let index?)): return "\(name) \(labels[index].isEmpty ? id : labels[index])"
        default: return node.text
        }
    }

    private mutating func runGrouped(select: [QueryNode], groupBy: [QueryNode], pivot: [QueryNode],
                                     orderBy: [(node: QueryNode, ascending: Bool)],
                                     rows: [Int]) throws -> ([[CellValue]], [String], [QueryNode]) {
        // Groups by their keys, sorted; without GROUP BY, one group of every row.
        var groups: [(key: [CellValue], rows: [Int])] = []
        if groupBy.isEmpty {
            groups = [([], rows)]
        } else {
            var index: [[CellValue]: Int] = [:]
            for row in rows {
                let key = groupBy.map { value($0, row: row) }
                if let existing = index[key] {
                    groups[existing].rows.append(row)
                } else {
                    index[key] = groups.count
                    groups.append((key, [row]))
                }
            }
            groups.sort { Self.compareKeys($0.key, $1.key) < 0 }
        }
        let plain = select.filter { !$0.containsAggregate }
        let aggregated = select.filter(\.containsAggregate)
        var output: [[CellValue]] = []
        var labels: [String]
        var nodes: [QueryNode]
        var orderKeys: [[CellValue]] = []
        if pivot.isEmpty {
            nodes = select
            labels = select.map(label)
            for group in groups {
                output.append(select.map { groupValue($0, rows: group.rows) })
                orderKeys.append(orderBy.map { groupValue($0.node, rows: group.rows) })
            }
        } else {
            // One column per pivot value (and per aggregate when there are several), after the grouped columns.
            var pivotIndex: [[CellValue]: Int] = [:]
            var pivotKeys: [[CellValue]] = []
            for row in rows {
                let key = pivot.map { value($0, row: row) }
                if pivotIndex[key] == nil {
                    pivotIndex[key] = pivotKeys.count
                    pivotKeys.append(key)
                }
            }
            let sortedKeys = pivotKeys.sorted { Self.compareKeys($0, $1) < 0 }
            let position = Dictionary(uniqueKeysWithValues: sortedKeys.enumerated().map { ($1, $0) })
            nodes = plain
            labels = plain.map(label)
            for key in sortedKeys {
                let keyText = key.map(Self.text).joined(separator: ", ")
                for node in aggregated {
                    nodes.append(node)
                    labels.append(aggregated.count == 1 ? keyText : "\(keyText) \(label(node))")
                }
            }
            for group in groups {
                var cells = [[Int]](repeating: [], count: sortedKeys.count)
                for row in group.rows { cells[position[pivot.map { value($0, row: row) }]!].append(row) }
                var line = plain.map { groupValue($0, rows: group.rows) }
                for cellRows in cells {
                    for node in aggregated { line.append(cellRows.isEmpty ? .empty : groupValue(node, rows: cellRows)) }
                }
                output.append(line)
                orderKeys.append(orderBy.map { groupValue($0.node, rows: group.rows) })
            }
        }
        if !orderBy.isEmpty {
            var keyed = Array(zip(output, orderKeys)).map { (values: $0.0, keys: $0.1) }
            Self.sort(&keyed, orderBy.map(\.ascending))
            output = keyed.map(\.values)
        }
        return (output, labels, nodes)
    }

    // MARK: Values

    private func value(_ node: QueryNode, row: Int) -> CellValue {
        switch node {
        case .column(_, let index?): return columns[index][row]
        case .column: return .empty
        case .literal(let value): return value
        case .arithmetic(let op, let a, let b): return Self.arithmetic(op, value(a, row: row), value(b, row: row))
        case .negate(let a): return Self.negate(value(a, row: row))
        case .compare(let op, let a, let b): return .boolean(Self.compare(op, value(a, row: row), value(b, row: row)))
        case .and(let a, let b): return .boolean(truth(value(a, row: row)) && truth(value(b, row: row)))
        case .or(let a, let b): return .boolean(truth(value(a, row: row)) || truth(value(b, row: row)))
        case .not(let a): return .boolean(!truth(value(a, row: row)))
        case .isNull(let a, let negated): return .boolean((value(a, row: row) == .empty) != negated)
        case .textTest(let op, let a, let b): return .boolean(Self.textTest(op, value(a, row: row), value(b, row: row)))
        case .function(let name, let arguments): return function(name, arguments.map { value($0, row: row) })
        case .aggregate: return .empty
        }
    }

    /// A value for a group: aggregates over its rows, other columns from its first row (they're grouped).
    private func groupValue(_ node: QueryNode, rows: [Int]) -> CellValue {
        switch node {
        case .aggregate(let name, let argument): return aggregate(name, rows.map { value(argument, row: $0) })
        case .column, .literal: return rows.first.map { value(node, row: $0) } ?? .empty
        case .arithmetic(let op, let a, let b): return Self.arithmetic(op, groupValue(a, rows: rows), groupValue(b, rows: rows))
        case .negate(let a): return Self.negate(groupValue(a, rows: rows))
        case .compare(let op, let a, let b): return .boolean(Self.compare(op, groupValue(a, rows: rows), groupValue(b, rows: rows)))
        case .and(let a, let b): return .boolean(truth(groupValue(a, rows: rows)) && truth(groupValue(b, rows: rows)))
        case .or(let a, let b): return .boolean(truth(groupValue(a, rows: rows)) || truth(groupValue(b, rows: rows)))
        case .not(let a): return .boolean(!truth(groupValue(a, rows: rows)))
        case .isNull(let a, let negated): return .boolean((groupValue(a, rows: rows) == .empty) != negated)
        case .textTest(let op, let a, let b): return .boolean(Self.textTest(op, groupValue(a, rows: rows), groupValue(b, rows: rows)))
        case .function(let name, let arguments): return function(name, arguments.map { groupValue($0, rows: rows) })
        }
    }

    private func aggregate(_ name: String, _ values: [CellValue]) -> CellValue {
        switch name {
        case "count":
            return .number(Double(values.filter { $0 != .empty }.count))
        case "sum", "avg":
            var total = 0.0, count = 0
            for case .number(let number) in values {
                total += number
                count += 1
            }
            guard count > 0 else { return name == "sum" ? .number(0) : .empty }
            return .number(name == "sum" ? total : total / Double(count))
        default:
            var best: CellValue?
            for value in values where value != .empty {
                guard let current = best else {
                    best = value
                    continue
                }
                let order = Self.order(value, current)
                if name == "max" ? order > 0 : order < 0 { best = value }
            }
            return best ?? .empty
        }
    }

    private func truth(_ value: CellValue) -> Bool {
        if case .boolean(let flag) = value { return flag }
        return false
    }

    private static func arithmetic(_ op: Character, _ a: CellValue, _ b: CellValue) -> CellValue {
        guard case .number(let x) = a, case .number(let y) = b else { return .empty }
        let result: Double
        switch op {
        case "+": result = x + y
        case "-": result = x - y
        case "*": result = x * y
        default:
            guard y != 0 else { return .empty }
            result = x / y
        }
        return result.isFinite ? .number(result) : .empty
    }

    private static func negate(_ value: CellValue) -> CellValue {
        guard case .number(let x) = value else { return .empty }
        return .number(-x)
    }

    /// Comparisons with null are false; values of different types are never equal.
    private static func compare(_ op: String, _ a: CellValue, _ b: CellValue) -> Bool {
        if a == .empty || b == .empty { return false }
        let sameType: Bool
        switch (a, b) {
        case (.number, .number), (.text, .text), (.boolean, .boolean): sameType = true
        default: sameType = false
        }
        let order = order(a, b)
        switch op {
        case "=": return sameType && order == 0
        case "!=": return !sameType || order != 0
        case "<": return order < 0
        case ">": return order > 0
        case "<=": return order <= 0
        default: return order >= 0
        }
    }

    /// Ascending order: null, numbers, text (with case), booleans.
    static func order(_ a: CellValue, _ b: CellValue) -> Int {
        func rank(_ value: CellValue) -> Int {
            switch value {
            case .empty: 0
            case .number: 1
            case .text: 2
            case .boolean: 3
            case .error: 4
            }
        }
        switch (a, b) {
        case (.number(let x), .number(let y)): return x < y ? -1 : (x > y ? 1 : 0)
        case (.text(let x), .text(let y)): return x < y ? -1 : (x > y ? 1 : 0)
        case (.boolean(let x), .boolean(let y)): return x == y ? 0 : (x ? 1 : -1)
        default:
            let (x, y) = (rank(a), rank(b))
            return x < y ? -1 : (x > y ? 1 : 0)
        }
    }

    private static func compareKeys(_ a: [CellValue], _ b: [CellValue]) -> Int {
        for (x, y) in zip(a, b) {
            let order = order(x, y)
            if order != 0 { return order }
        }
        return 0
    }

    private static func sort(_ rows: inout [(values: [CellValue], keys: [CellValue])], _ ascending: [Bool]) {
        // Stable: ties keep their order.
        let indexed = rows.enumerated().map { ($0.offset, $0.element) }
        rows = indexed.sorted { lhs, rhs in
            for (index, up) in ascending.enumerated() {
                let order = order(lhs.1.keys[index], rhs.1.keys[index])
                if order != 0 { return up ? order < 0 : order > 0 }
            }
            return lhs.0 < rhs.0
        }.map(\.1)
    }

    /// contains, starts with, ends with, matches (a regular expression for the whole text) and like (% and _ wildcards).
    private static func textTest(_ op: String, _ a: CellValue, _ b: CellValue) -> Bool {
        guard case .text(let text) = a, case .text(let pattern) = b else { return false }
        switch op {
        case "contains": return pattern.isEmpty || text.contains(pattern)
        case "starts with": return text.hasPrefix(pattern)
        case "ends with": return text.hasSuffix(pattern)
        case "matches":
            guard let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$", options: [.dotMatchesLineSeparators]) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        default:
            var expression = "^"
            for character in pattern {
                switch character {
                case "%": expression += ".*"
                case "_": expression += "."
                default: expression += NSRegularExpression.escapedPattern(for: String(character))
                }
            }
            guard let regex = try? NSRegularExpression(pattern: expression + "$", options: [.dotMatchesLineSeparators]) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    /// Scalar functions; dates are serial numbers. month() counts from 0, as the query language defines it.
    private func function(_ name: String, _ arguments: [CellValue]) -> CellValue {
        func number(_ index: Int) -> Double? { index < arguments.count ? arguments[index].numberValue : nil }
        switch name {
        case "now": return .number(DateSerial.serial(from: now))
        case "upper", "lower":
            guard case .text(let text)? = arguments.first else { return .empty }
            return .text(name == "upper" ? text.uppercased() : text.lowercased())
        case "todate":
            guard let serial = number(0) else { return .empty }
            return .number(serial.rounded(.down))
        case "datediff":
            guard let a = number(0), let b = number(1) else { return .empty }
            return .number(a.rounded(.down) - b.rounded(.down))
        default:
            guard let serial = number(0) else { return .empty }
            let parts = DateSerial.parts(of: serial)
            switch name {
            case "year": return .number(Double(parts.year))
            case "month": return .number(Double(parts.month - 1))
            case "day": return .number(Double(parts.day))
            case "hour": return .number(Double(parts.hour))
            case "minute": return .number(Double(parts.minute))
            case "second": return .number(Double(parts.second))
            case "millisecond": return .number(Double(parts.millisecond))
            case "quarter": return .number(Double((parts.month - 1) / 3 + 1))
            default: return .number(Double(DateSerial.weekday(of: serial)))
            }
        }
    }

    static func text(_ value: CellValue) -> String {
        switch value {
        case .empty: ""
        case .number(let number): NumberText.general(number)
        case .text(let text): text
        case .boolean(let boolean): boolean ? "TRUE" : "FALSE"
        case .error(let error): error.code
        }
    }
}
