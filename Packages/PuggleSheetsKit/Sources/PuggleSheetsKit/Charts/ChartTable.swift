import Foundation

/// The labels and series a chart shows, read from its ranges by `ChartBuilder.table(for:sheetIndex:workbook:)`.
///
/// Every series has one value per label. Tables built by hand may be ragged; the renderer pads short
/// series with gaps and missing labels with 1, 2, 3, …
public struct ChartTable: Hashable, Sendable {
    public struct Series: Hashable, Sendable {
        /// The header, or a default name.
        public var name: String
        /// One value per label; nil where the cell is empty or not a number.
        public var values: [Double?]
        /// The number format of the series' cells, for axis and data labels.
        public var numberFormat: String?

        public init(name: String, values: [Double?], numberFormat: String? = nil) {
            self.name = name
            self.values = values
            self.numberFormat = numberFormat
        }
    }

    /// The labels along the horizontal axis (or the pie slices), as shown.
    public var labels: [String]
    /// The labels as numbers when they are numbers or dates (scatter charts and numeric axes).
    public var labelValues: [Double?]
    /// The number format of the label cells.
    public var labelFormat: String?
    public var series: [Series]
    /// The labels' heading ("Month"): the first cell of the header row when the first column holds
    /// labels. Empty otherwise.
    public var labelHeading: String

    public init(labels: [String] = [], labelValues: [Double?] = [], labelFormat: String? = nil, series: [Series] = []) {
        self.init(labels: labels, labelValues: labelValues, labelFormat: labelFormat, labelHeading: "", series: series)
    }

    public init(labels: [String], labelValues: [Double?], labelFormat: String?, labelHeading: String, series: [Series]) {
        self.labels = labels
        self.labelValues = labelValues
        self.labelFormat = labelFormat
        self.labelHeading = labelHeading
        self.series = series
    }

    public var isEmpty: Bool { series.isEmpty || series.allSatisfy { $0.values.allSatisfy { $0 == nil } } }

    /// The number of rows: labels, or values of the longest series.
    public var rowCount: Int { max(labels.count, series.lazy.map(\.values.count).max() ?? 0) }
}
