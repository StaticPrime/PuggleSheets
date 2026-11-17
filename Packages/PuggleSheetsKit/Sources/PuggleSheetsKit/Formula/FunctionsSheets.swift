import Foundation

/// SPARKLINE, SORTN and GETPIVOTDATA.
extension FunctionTable {
    mutating func addSheetsFunctions() {
        // SPARKLINE(data, [options]): the cell shows nothing itself; the engine records the chart in the
        // sheet's `sparklines` for the app to draw.
        add("SPARKLINE", 1, 2) { a in
            var values: [Double?] = []
            for value in try a.matrix(0).values {
                switch value {
                case .number(let number): values.append(number)
                case .error(let error): throw error
                default: values.append(nil)
                }
            }
            var options: [String: String] = [:]
            if a.has(1), case .value(let first) = a.values[1], first == .empty {
                // SPARKLINE(data, ) has no options.
            } else if a.has(1) {
                let table = try a.matrix(1)
                guard table.columns == 2 else {
                    throw CellError(.value, "Function SPARKLINE parameter 2 should be a range or array with two columns.")
                }
                for row in 0..<table.rows {
                    let key = try Coercion.text(table[row, 0]).trimmingCharacters(in: .whitespaces).lowercased()
                    guard !key.isEmpty else { continue }
                    switch table[row, 1] {
                    case .error(let error): throw error
                    case .boolean(let flag): options[key] = flag ? "true" : "false"
                    case let value: options[key] = try Coercion.text(value)
                    }
                }
            }
            var kind = SparklineSpec.Kind.line
            if let type = options["charttype"] {
                guard let chosen = SparklineSpec.Kind(rawValue: type.trimmingCharacters(in: .whitespaces).lowercased()) else {
                    throw CellError(.value, "Function SPARKLINE parameter 2 has an invalid charttype '\(type)'.")
                }
                kind = chosen
            }
            // A bar shows one or two values, stacked.
            if kind == .bar { values = Array(values.prefix(2)) }
            a.evaluator.pendingDecoration = .sparkline(SparklineSpec(kind: kind, values: values, options: options))
            return .value(.empty)
        }

        // SORTN(range, [n], [display_ties_mode], [sort_column, is_ascending]…)
        add("SORTN", 1, .max) { a in
            let data = try a.matrix(0)
            func given(_ index: Int) -> Bool {
                guard a.has(index) else { return false }
                if case .value(.empty) = a.values[index] { return false }
                return true
            }
            let count = given(1) ? try a.integer(1) : 1
            guard count >= 0 else { throw CellError(.value, "Function SORTN parameter 2 value is \(count). It should be greater than or equal to 0.") }
            let mode = given(2) ? try a.integer(2) : 0
            guard (0...3).contains(mode) else {
                throw CellError(.value, "Function SORTN parameter 3 value is \(mode). Valid values are between 0 and 3 inclusive.")
            }
            var keys: [(values: [CellValue], ascending: Bool)] = []
            var index = 3
            while index < a.count {
                let ascending = index + 1 < a.count ? try a.boolean(index + 1) : true
                if case .array(let column) = a.evaluator.operand(a.values[index]) {
                    guard column.columns == 1, column.rows == data.rows else {
                        throw FormulaErrors.value("Function SORTN parameter \(index + 1) has mismatched row size.")
                    }
                    keys.append((column.values, ascending))
                } else {
                    let column = try a.integer(index)
                    guard column >= 1, column <= data.columns else {
                        throw FormulaErrors.value("Function SORTN parameter \(index + 1) value is \(column). Valid values are between 1 and \(data.columns) inclusive.")
                    }
                    keys.append((data.column(column - 1), ascending))
                }
                index += 2
            }
            if keys.isEmpty { keys = [(data.column(0), true)] }
            func compare(_ first: Int, _ second: Int, _ key: (values: [CellValue], ascending: Bool)) -> Int {
                let x = key.values[first], y = key.values[second]
                if x == .empty || y == .empty { return x == .empty ? (y == .empty ? 0 : 1) : -1 }
                let order = Coercion.compare(x, y)
                return key.ascending ? order : -order
            }
            func tied(_ first: Int, _ second: Int) -> Bool { keys.allSatisfy { compare(first, second, $0) == 0 } }
            let order = (0..<data.rows).sorted { first, second in
                for key in keys {
                    let order = compare(first, second, key)
                    if order != 0 { return order < 0 }
                }
                return first < second
            }
            // Ties are rows whose sort columns hold equal values.
            var chosen: [Int] = []
            switch mode {
            case 0:
                chosen = Array(order.prefix(count))
            case 1:
                chosen = Array(order.prefix(count))
                if let last = chosen.last {
                    for row in order.dropFirst(count) where tied(row, last) { chosen.append(row) }
                }
            case 2:
                for row in order where chosen.count < count && !chosen.contains(where: { tied($0, row) }) { chosen.append(row) }
            default:
                var distinct: [Int] = []
                for row in order {
                    if distinct.contains(where: { tied($0, row) }) {
                        chosen.append(row)
                    } else if distinct.count < count {
                        distinct.append(row)
                        chosen.append(row)
                    }
                }
            }
            guard !chosen.isEmpty else { throw CellError(.notAvailable, "No matches are found in SORTN evaluation.") }
            return Self.array(chosen.flatMap { data.row($0) }, rows: chosen.count, columns: data.columns)
        }

        // GETPIVOTDATA(value_name, any_pivot_table_cell, [original_column, pivot_item]…)
        add("GETPIVOTDATA", 2, .max) { a in
            guard a.count % 2 == 0 else {
                throw CellError(.notAvailable, "Wrong number of arguments to GETPIVOTDATA. Expected an even number of arguments, but got \(a.count) arguments.")
            }
            let name = try a.text(0)
            guard let reference = a.reference(1) else {
                throw CellError(.reference, "Function GETPIVOTDATA parameter 2 must be a cell in a pivot table.")
            }
            guard let (output, axes) = a.evaluator.pivot(sheet: reference.sheet, address: reference.range.start) else {
                throw CellError(.reference, "Function GETPIVOTDATA parameter 2 must be a cell in a pivot table.")
            }
            func matching(_ names: [String], _ text: String) -> [Int] {
                names.indices.filter { names[$0].caseInsensitiveCompare(text) == .orderedSame }
            }
            var valueIndex = matching(axes.valueNames, name).first
            if valueIndex == nil, case let candidates = matching(axes.valueColumns, name), candidates.count == 1 { valueIndex = candidates[0] }
            guard let valueIndex else { throw CellError(.reference, "GETPIVOTDATA couldn't find the value '\(name)' in the pivot table.") }
            // Items by group level, on the row axis and the column axis.
            var rowItems: [Int: CellValue] = [:], columnItems: [Int: CellValue] = [:]
            for pair in stride(from: 2, to: a.count, by: 2) {
                let field = try a.text(pair)
                let item = try a.scalar(pair + 1)
                if let level = matching(axes.rowGroups, field).first {
                    rowItems[level] = item
                } else if let level = matching(axes.columnGroups, field).first {
                    columnItems[level] = item
                } else {
                    throw CellError(.reference, "GETPIVOTDATA couldn't find the field '\(field)' in the pivot table.")
                }
            }
            func same(_ label: CellValue, _ item: CellValue) -> Bool {
                switch (label, item) {
                case (.number(let x), .number(let y)): return x == y
                case (.empty, .empty): return true
                case (.empty, .text(let text)), (.text(let text), .empty): return text.isEmpty
                default:
                    guard let x = try? Coercion.text(label), let y = try? Coercion.text(item) else { return false }
                    return x.caseInsensitiveCompare(y) == .orderedSame
                }
            }
            // The one row (column) whose labels match: as many levels as the deepest item named, so groups left
            // out are totals.
            func line(_ lines: [PivotEngine.Axes.Line], _ items: [Int: CellValue]) -> Int? {
                let depth = (items.keys.max() ?? -1) + 1
                let found = lines.indices.filter { index in
                    let line = lines[index]
                    return line.path.count == depth && (line.value < 0 || line.value == valueIndex)
                        && items.allSatisfy { same(line.path[$0.key], $0.value) }
                }
                return found.count == 1 ? found[0] : nil
            }
            guard let row = line(axes.rows, rowItems), let column = line(axes.columns, columnItems),
                  axes.headerRows + row < output.rowCount, axes.labelColumns + column < output.columnCount else {
                throw CellError(.reference, "GETPIVOTDATA couldn't find that combination of items in the pivot table.")
            }
            return .value(output.values[axes.headerRows + row][axes.labelColumns + column])
        }
    }
}
