import Foundation

/// Data ▸ Add a slicer: a control over the grid that filters a range by one of its columns. Rows its
/// criterion hides are hidden like a filter's, so charts that use the range follow, and pivot tables
/// whose source is the same range apply it too when `appliesToPivotTables` is on.
public struct SlicerSpec: Hashable, Sendable {
    /// The data, header row first: a reference like a chart's ("A1:D20", "Sheet2!A1:D20", "Table1").
    public var range: String
    /// The filtered column, as an index into the range's columns (0 is its first column).
    public var column: Int
    /// Empty: the column's header.
    public var title: String
    public var criterion: FilterCriterion
    public var appliesToPivotTables: Bool
    /// nil: white.
    public var backgroundColor: RGBColor?

    public init(range: String, column: Int = 0, title: String = "", criterion: FilterCriterion = FilterCriterion(),
                appliesToPivotTables: Bool = true, backgroundColor: RGBColor? = nil) {
        self.range = range
        self.column = column
        self.title = title
        self.criterion = criterion
        self.appliesToPivotTables = appliesToPivotTables
        self.backgroundColor = backgroundColor
    }
}

/// A SPARKLINE formula's little chart, drawn in its cell. The formula engine keeps these up to date.
public struct SparklineSpec: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case line, bar, column, winloss
    }

    public var kind: Kind
    /// The data, in order; nil for gaps (empty cells or text).
    public var values: [Double?]
    /// SPARKLINE's options by lowercased name, values as written: "color" → "red", "max" → "100",
    /// "linewidth" → "2", "rtl" → "true".
    public var options: [String: String]

    public init(kind: Kind = .line, values: [Double?], options: [String: String] = [:]) {
        self.kind = kind
        self.values = values
        self.options = options
    }
}
