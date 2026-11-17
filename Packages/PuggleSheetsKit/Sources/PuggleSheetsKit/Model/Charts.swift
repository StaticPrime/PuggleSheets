import Foundation

/// Insert ▸ Chart: what a chart shows and how, as the chart editor sets it up.
public struct ChartSpec: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case column, stackedColumn, percentColumn
        case bar, stackedBar, percentBar
        case line, smoothLine
        case area, stackedArea, percentArea
        case pie, donut
        case scatter
        /// Columns and lines together; each series' `type` chooses (the first series defaults to
        /// columns, the others to lines).
        case combo
    }

    public enum LegendPosition: String, CaseIterable, Sendable {
        /// `auto` puts the legend on the right for most charts.
        case auto, top, bottom, left, right, inside, none
    }

    /// "Aggregate": how repeated labels are combined.
    public enum Aggregation: String, CaseIterable, Sendable {
        case sum, average, count, max, min, median
    }

    /// What pie slices are labeled with.
    public enum PieLabel: String, CaseIterable, Sendable {
        case none, percentage, value, label
    }

    public var kind: Kind
    /// The data, as references: "A1:C10" on the chart's own sheet, "Sheet2!A1:C10", or a named range.
    /// Several ranges are placed side by side.
    public var ranges: [String]
    /// "Use row 1 as headers": the first row names the series.
    public var firstRowIsHeader: Bool
    /// "Use column A as labels": the first column holds the labels (the x-axis, or the pie slices).
    public var firstColumnIsLabels: Bool
    /// "Switch rows / columns": series run along rows instead of columns.
    public var switchRowsAndColumns: Bool
    /// "Aggregate": combines rows with the same label; nil when off.
    public var aggregation: Aggregation?
    /// Empty strings mean "no title".
    public var title: String
    public var subtitle: String
    public var horizontalAxisTitle: String
    public var verticalAxisTitle: String
    public var legend: LegendPosition
    /// Per-series styles, in series order; missing entries use the defaults.
    public var series: [ChartSeriesStyle]
    /// nil: white.
    public var backgroundColor: RGBColor?
    /// nil: the default chart font.
    public var fontFamily: String?
    /// The vertical (value) axis range; nil means automatic.
    public var verticalMinimum: Double?
    public var verticalMaximum: Double?
    public var logScale: Bool
    public var showsGridlines: Bool
    /// Data labels for every series (a series' own setting wins).
    public var showsDataLabels: Bool
    /// The donut hole, as a fraction of the radius (donut charts).
    public var pieHole: Double
    public var pieSliceLabel: PieLabel

    public init(kind: Kind = .column, ranges: [String], firstRowIsHeader: Bool = true, firstColumnIsLabels: Bool = true,
                switchRowsAndColumns: Bool = false, aggregation: Aggregation? = nil, title: String = "", subtitle: String = "",
                horizontalAxisTitle: String = "", verticalAxisTitle: String = "", legend: LegendPosition = .auto,
                series: [ChartSeriesStyle] = [], backgroundColor: RGBColor? = nil, fontFamily: String? = nil,
                verticalMinimum: Double? = nil, verticalMaximum: Double? = nil, logScale: Bool = false,
                showsGridlines: Bool = true, showsDataLabels: Bool = false, pieHole: Double = 0.5,
                pieSliceLabel: PieLabel = .percentage) {
        self.kind = kind
        self.ranges = ranges
        self.firstRowIsHeader = firstRowIsHeader
        self.firstColumnIsLabels = firstColumnIsLabels
        self.switchRowsAndColumns = switchRowsAndColumns
        self.aggregation = aggregation
        self.title = title
        self.subtitle = subtitle
        self.horizontalAxisTitle = horizontalAxisTitle
        self.verticalAxisTitle = verticalAxisTitle
        self.legend = legend
        self.series = series
        self.backgroundColor = backgroundColor
        self.fontFamily = fontFamily
        self.verticalMinimum = verticalMinimum
        self.verticalMaximum = verticalMaximum
        self.logScale = logScale
        self.showsGridlines = showsGridlines
        self.showsDataLabels = showsDataLabels
        self.pieHole = pieHole
        self.pieSliceLabel = pieSliceLabel
    }

    /// The style of series `index`, with defaults for anything unset.
    public func style(ofSeries index: Int) -> ChartSeriesStyle {
        index < series.count ? series[index] : ChartSeriesStyle()
    }
}

/// How one series is drawn.
public struct ChartSeriesStyle: Hashable, Sendable {
    public enum SeriesType: String, CaseIterable, Sendable {
        case column, line, area
    }

    /// nil: the next color of the default palette.
    public var color: RGBColor?
    /// For combo charts.
    public var type: SeriesType?
    /// Line thickness in pixels (lines and areas).
    public var lineWidth: Double?
    /// Point size in pixels; 0 hides points on lines.
    public var pointSize: Double?
    /// Overrides the chart's data label setting.
    public var showsDataLabels: Bool?
    /// Plots the series against a second axis on the right.
    public var usesRightAxis: Bool

    public init(color: RGBColor? = nil, type: SeriesType? = nil, lineWidth: Double? = nil, pointSize: Double? = nil,
                showsDataLabels: Bool? = nil, usesRightAxis: Bool = false) {
        self.color = color
        self.type = type
        self.lineWidth = lineWidth
        self.pointSize = pointSize
        self.showsDataLabels = showsDataLabels
        self.usesRightAxis = usesRightAxis
    }
}
