import Foundation

/// Format ▸ Convert to table: a named block of data with a header row, column types, colors and its
/// own filter. Formulas refer to it as Table1[Column], Table1[#ALL] and so on.
public struct SheetTable: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Unique in the workbook (among tables and named ranges), like a named range's name.
    public var name: String
    /// The header row first, then the data rows.
    public var range: CellRange
    /// Column types by sheet column; columns without one are automatic.
    public var columnTypes: [Int: TableColumnType]
    /// The table's color: the header row is filled with it and the rows alternate with a light tint.
    public var color: RGBColor
    /// The table's filter, by sheet column.
    public var criteria: [Int: FilterCriterion]

    public init(id: UUID = UUID(), name: String, range: CellRange, columnTypes: [Int: TableColumnType] = [:],
                color: RGBColor = SheetTable.colors[0], criteria: [Int: FilterCriterion] = [:]) {
        self.id = id
        self.name = name
        self.range = range
        self.columnTypes = columnTypes
        self.color = color
        self.criteria = criteria
    }

    /// The colors the table menu offers.
    public static let colors: [RGBColor] = ["0B8043", "1A73E8", "5F6368", "A142F4", "D93025", "E37400", "129EAF", "C5221F"]
        .compactMap(RGBColor.init(hex:))

    public var headerRow: Int { range.start.row }

    /// The data rows (none when the table is only a header).
    public var dataRange: CellRange? {
        range.rowCount > 1 ? CellRange(rows: (range.start.row + 1)...range.end.row, columns: range.columns) : nil
    }

    /// The table's filter as a sheet filter, for evaluating which rows it hides.
    public var asFilter: SheetFilter { SheetFilter(range: range, criteria: criteria) }
}

/// A table column's type: it sets the number format of the column's cells, or makes them checkboxes or a dropdown.
public enum TableColumnType: Hashable, Sendable {
    case text, number, percent, currency, date, time, dateTime, checkbox
    case dropdown([String])

    /// The number format the type gives its cells, if any.
    public var numberFormat: String? {
        switch self {
        case .text: "@"
        case .number: "#,##0.00"
        case .percent: "0.00%"
        case .currency: "\"$\"#,##0.00"
        case .date: "M/d/yyyy"
        case .time: "h:mm:ss AM/PM"
        case .dateTime: "M/d/yyyy H:mm:ss"
        case .checkbox, .dropdown: nil
        }
    }
}
