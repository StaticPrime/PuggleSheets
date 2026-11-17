import Foundation

/// Charts as embedded OpenDocument chart objects ("Object 1/content.xml"), laid out as LibreOffice
/// writes them: the series read their values from the sheet's cells (`xlink:href=".."`), and a local
/// table holds a copy of the values for other readers.
struct ODSChartWriter {
    /// The default series colors, used for series without a color of their own.
    static let palette: [RGBColor] = ["4285F4", "EA4335", "FBBC04", "34A853", "FF6D01", "46BDC6",
                                      "7BAAF7", "F07B72", "FCD04F", "71C287", "FF994D", "7ED1D7"].compactMap(RGBColor.init(hex:))
    /// The default line thickness and scatter point size, in pixels.
    static let defaultLineWidth = 2.0
    static let defaultPointSize = 7.0
    static let gridColor = "#cccccc"
    static let axisColor = "#b3b3b3"

    static let namespaces = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" "
        + "xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" "
        + "xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" "
        + "xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" "
        + "xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" "
        + "xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" "
        + "xmlns:xlink=\"http://www.w3.org/1999/xlink\" "
        + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
        + "xmlns:meta=\"urn:oasis:names:tc:opendocument:xmlns:meta:1.0\" "
        + "xmlns:number=\"urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0\" "
        + "xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\" "
        + "xmlns:chart=\"urn:oasis:names:tc:opendocument:xmlns:chart:1.0\" "
        + "xmlns:dr3d=\"urn:oasis:names:tc:opendocument:xmlns:dr3d:1.0\" "
        + "xmlns:loext=\"urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0\""

    let spec: ChartSpec
    let layout: ODSChartLayout?
    let workbook: Workbook
    /// The sheet names as written.
    let names: [String]
    let width: Double
    let height: Double

    // MARK: - Addresses

    static func address(_ range: ODSSheetRange, names: [String]) -> String {
        let sheet = ODSFormula.quotedSheet(names[range.sheet])
        return "\(sheet).\(range.range.start.a1):\(sheet).\(range.range.end.a1)"
    }

    private func addresses(_ ranges: [ODSSheetRange]) -> String {
        ranges.map { ODSChartWriter.address($0, names: names) }.joined(separator: " ")
    }

    /// Every range the chart reads, for `draw:notify-on-update-of-ranges`.
    var notifiedRanges: String { addresses(layout?.sources ?? []) }

    // MARK: - Kinds

    var isPie: Bool { spec.kind == .pie || spec.kind == .donut }
    var isBar: Bool { [.bar, .stackedBar, .percentBar].contains(spec.kind) }

    static func chartClass(_ kind: ChartSpec.Kind) -> String {
        switch kind {
        case .column, .stackedColumn, .percentColumn, .bar, .stackedBar, .percentBar, .combo: "chart:bar"
        case .line, .smoothLine: "chart:line"
        case .area, .stackedArea, .percentArea: "chart:area"
        case .pie: "chart:circle"
        case .donut: "chart:ring"
        case .scatter: "chart:scatter"
        }
    }

    /// The type a combo chart's series is drawn as: its own, or columns first and lines after.
    static func comboType(_ style: ChartSeriesStyle, index: Int) -> ChartSeriesStyle.SeriesType {
        style.type ?? (index == 0 ? .column : .line)
    }

    private func seriesClass(_ index: Int) -> String {
        switch spec.kind {
        case .combo:
            switch ODSChartWriter.comboType(spec.style(ofSeries: index), index: index) {
            case .column: return "chart:bar"
            case .line: return "chart:line"
            case .area: return "chart:area"
            }
        // LibreOffice's ring charts are pie charts whose series are rings.
        case .donut: return "chart:circle"
        default: return ODSChartWriter.chartClass(spec.kind)
        }
    }

    /// What a series is drawn as, for its style.
    private enum Mark { case bar, line, area, point, slice }

    private func mark(ofSeries index: Int) -> Mark {
        switch spec.kind {
        case .column, .stackedColumn, .percentColumn, .bar, .stackedBar, .percentBar: return .bar
        case .line, .smoothLine: return .line
        case .area, .stackedArea, .percentArea: return .area
        case .pie, .donut: return .slice
        case .scatter: return .point
        case .combo:
            switch ODSChartWriter.comboType(spec.style(ofSeries: index), index: index) {
            case .column: return .bar
            case .line: return .line
            case .area: return .area
            }
        }
    }

    static func color(_ style: ChartSeriesStyle, index: Int) -> RGBColor {
        style.color ?? palette[index % palette.count]
    }

    private static func hex(_ color: RGBColor) -> String { "#" + color.hex.lowercased() }

    // MARK: - Styles

    private struct Style {
        var chart = ""
        var graphic = ""
        var text = ""
    }

    private final class Styles {
        var items: [(name: String, style: Style)] = []

        /// The style's name; nil for a style without properties, which isn't written.
        func add(_ style: Style) -> String? {
            guard !style.chart.isEmpty || !style.graphic.isEmpty || !style.text.isEmpty else { return nil }
            let name = "ch\(items.count + 1)"
            items.append((name, style))
            return name
        }
    }

    /// ` chart:style-name="…"`, or nothing.
    private static func styleAttribute(_ name: String?) -> String {
        name.map { " chart:style-name=\"\($0)\"" } ?? ""
    }

    private func textProperties() -> String {
        guard let family = spec.fontFamily, !family.isEmpty else { return "" }
        var writer = XMLWriter(fragmentCapacity: 64)
        writer.attribute("fo:font-family", family.contains(" ") ? "'\(family)'" : family)
        return String(decoding: writer.bytes, as: UTF8.self)
    }

    // MARK: - Content

    func content() -> Data {
        let styles = Styles()
        var body = XMLWriter(fragmentCapacity: 4096)
        let text = textProperties()

        let background = " draw:stroke=\"none\" draw:fill=\"solid\" draw:fill-color=\"\(ODSChartWriter.hex(spec.backgroundColor ?? .white))\""
        let chartStyle = styles.add(Style(graphic: background))
        body.raw("<chart:chart svg:width=\"\(ODSLength.drawing(pixels: width))\" svg:height=\"\(ODSLength.drawing(pixels: height))\" "
            + "xlink:href=\"..\" xlink:type=\"simple\" chart:class=\"\(ODSChartWriter.chartClass(spec.kind))\"\(ODSChartWriter.styleAttribute(chartStyle))>")

        writeTitle("chart:title", spec.title, style: styles.add(Style(chart: " chart:auto-position=\"true\"", text: text)), into: &body)
        writeTitle("chart:subtitle", spec.subtitle, style: styles.add(Style(chart: " chart:auto-position=\"true\"", text: text)), into: &body)
        writeLegend(styles: styles, text: text, into: &body)
        writePlotArea(styles: styles, text: text, into: &body)
        writeLocalTable(into: &body)
        body.raw("</chart:chart>")

        var xml = XMLWriter(reservingCapacity: body.bytes.count + 4096)
        xml.raw("<office:document-content \(ODSChartWriter.namespaces) office:version=\"1.3\">")
        xml.raw("<office:automatic-styles>")
        for (name, style) in styles.items {
            xml.raw("<style:style style:name=\"\(name)\" style:family=\"chart\">")
            if !style.chart.isEmpty { xml.raw("<style:chart-properties\(style.chart)/>") }
            if !style.graphic.isEmpty { xml.raw("<style:graphic-properties\(style.graphic)/>") }
            if !style.text.isEmpty { xml.raw("<style:text-properties\(style.text)/>") }
            xml.raw("</style:style>")
        }
        xml.raw("</office:automatic-styles>")
        xml.raw("<office:body><office:chart>")
        xml.append(body)
        xml.raw("</office:chart></office:body></office:document-content>")
        return xml.data
    }

    private func writeTitle(_ element: String, _ title: String, style: String?, into xml: inout XMLWriter) {
        guard !title.isEmpty else { return }
        xml.raw("<\(element)\(ODSChartWriter.styleAttribute(style))>")
        for line in title.components(separatedBy: "\n") {
            xml.raw("<text:p>")
            xml.text(line)
            xml.raw("</text:p>")
        }
        xml.raw("</\(element)>")
    }

    private func writeLegend(styles: Styles, text: String, into xml: inout XMLWriter) {
        let position: String
        var overlay = false
        switch spec.legend {
        case .none: return
        case .auto, .right: position = "end"
        case .left: position = "start"
        case .top: position = "top"
        case .bottom: position = "bottom"
        case .inside:
            position = "end"
            overlay = true
        }
        let style = styles.add(Style(chart: " chart:auto-position=\"true\"", graphic: " draw:stroke=\"none\" draw:fill=\"none\"", text: text))
        xml.raw("<chart:legend chart:legend-position=\"\(position)\"")
        if overlay { xml.raw(" loext:overlay=\"true\"") }
        xml.raw(" style:legend-expansion=\"high\"\(ODSChartWriter.styleAttribute(style))/>")
    }

    /// `chart:data-source-has-labels`: whether the first sheet row or column holds labels.
    private var hasLabels: String? {
        // Scatter charts' first column holds x values, not labels.
        let labels = spec.firstColumnIsLabels && spec.kind != .scatter
        let firstRow = spec.switchRowsAndColumns ? labels : spec.firstRowIsHeader
        let firstColumn = spec.switchRowsAndColumns ? spec.firstRowIsHeader : labels
        switch (firstRow, firstColumn) {
        case (true, true): return "both"
        case (true, false): return "row"
        case (false, true): return "column"
        case (false, false): return nil
        }
    }

    private var usesRightAxis: Bool {
        !isPie && spec.series.prefix(layout?.series.count ?? 0).contains { $0.usesRightAxis }
    }

    private func writePlotArea(styles: Styles, text: String, into xml: inout XMLWriter) {
        var properties = " chart:include-hidden-cells=\"false\" chart:auto-position=\"true\" chart:auto-size=\"true\""
            + " chart:treat-empty-cells=\"leave-gap\" chart:series-source=\"\(spec.switchRowsAndColumns ? "rows" : "columns")\""
            + " chart:right-angled-axes=\"true\""
        switch spec.kind {
        case .stackedColumn, .stackedBar, .stackedArea: properties += " chart:stacked=\"true\""
        case .percentColumn, .percentBar, .percentArea: properties += " chart:percentage=\"true\""
        case .smoothLine: properties += " chart:interpolation=\"cubic-spline\""
        case .scatter: properties += " chart:symbol-type=\"automatic\" chart:lines=\"false\""
        case .donut:
            let hole = min(max(spec.pieHole, 0), 0.95)
            properties += " chart:hole-size=\"\(XLSXValue.string((hole * 100).rounded()))%\""
        default: break
        }
        if isBar { properties += " chart:vertical=\"true\"" }
        let plotStyle = styles.add(Style(chart: properties))
        xml.raw("<chart:plot-area\(ODSChartWriter.styleAttribute(plotStyle))")
        if let layout, !layout.sources.isEmpty {
            xml.attribute("table:cell-range-address", addresses(layout.sources))
            if let hasLabels { xml.raw(" chart:data-source-has-labels=\"\(hasLabels)\"") }
        }
        xml.raw(">")

        // Axes. Horizontal bars put the categories (x) up the side and the values (y) along the bottom.
        let categoryTitle = isPie ? "" : (isBar ? spec.verticalAxisTitle : spec.horizontalAxisTitle)
        let valueTitle = isPie ? "" : (isBar ? spec.horizontalAxisTitle : spec.verticalAxisTitle)
        let axisGraphic = " svg:stroke-color=\"\(ODSChartWriter.axisColor)\""
        let xStyle = styles.add(Style(chart: " chart:display-label=\"true\"", graphic: axisGraphic, text: text))
        xml.raw("<chart:axis chart:dimension=\"x\" chart:name=\"primary-x\"\(ODSChartWriter.styleAttribute(xStyle))>")
        writeTitle("chart:title", categoryTitle, style: styles.add(Style(text: text)), into: &xml)
        if spec.kind != .scatter, let labels = layout?.labelBlocks, !labels.isEmpty {
            xml.raw("<chart:categories")
            xml.attribute("table:cell-range-address", addresses(labels))
            xml.raw("/>")
        }
        xml.raw("</chart:axis>")

        var yProperties = " chart:display-label=\"true\" chart:logarithmic=\"\(spec.logScale && !isPie ? "true" : "false")\""
        if !isPie {
            if let minimum = spec.verticalMinimum, minimum.isFinite { yProperties += " chart:minimum=\"\(XLSXValue.string(minimum))\"" }
            if let maximum = spec.verticalMaximum, maximum.isFinite { yProperties += " chart:maximum=\"\(XLSXValue.string(maximum))\"" }
        }
        let yStyle = styles.add(Style(chart: yProperties, graphic: axisGraphic, text: text))
        xml.raw("<chart:axis chart:dimension=\"y\" chart:name=\"primary-y\"\(ODSChartWriter.styleAttribute(yStyle))>")
        writeTitle("chart:title", valueTitle, style: styles.add(Style(text: text)), into: &xml)
        // LibreOffice's pie charts keep the grid of their (hidden) axes too.
        if spec.showsGridlines {
            let gridStyle = styles.add(Style(graphic: " svg:stroke-color=\"\(ODSChartWriter.gridColor)\""))
            xml.raw("<chart:grid\(ODSChartWriter.styleAttribute(gridStyle)) chart:class=\"major\"/>")
        }
        xml.raw("</chart:axis>")
        let secondary = usesRightAxis
        if secondary {
            let style = styles.add(Style(chart: " chart:display-label=\"true\" chart:logarithmic=\"false\"", graphic: axisGraphic, text: text))
            xml.raw("<chart:axis chart:dimension=\"y\" chart:name=\"secondary-y\"\(ODSChartWriter.styleAttribute(style))/>")
        }

        // Series. Pie and donut charts show their first series only.
        let series = layout?.series ?? []
        for (index, item) in series.enumerated() {
            if isPie, index > 0 { break }
            writeSeries(item, index: index, secondaryAxis: secondary, styles: styles, text: text, into: &xml)
        }

        let wallStyle = styles.add(Style(graphic: " draw:stroke=\"none\" draw:fill=\"none\""))
        xml.raw("<chart:wall\(ODSChartWriter.styleAttribute(wallStyle))/>")
        xml.raw("</chart:plot-area>")
    }

    private func dataLabelProperties(seriesIndex: Int) -> String {
        if isPie {
            switch spec.pieSliceLabel {
            case .none: return ""
            case .percentage: return " chart:data-label-number=\"percentage\""
            case .value: return " chart:data-label-number=\"value\""
            case .label: return " chart:data-label-number=\"none\" chart:data-label-text=\"true\""
            }
        }
        let shows = spec.style(ofSeries: seriesIndex).showsDataLabels ?? spec.showsDataLabels
        return shows ? " chart:data-label-number=\"value\"" : ""
    }

    private func writeSeries(_ series: ODSChartLayout.Series, index: Int, secondaryAxis: Bool, styles: Styles, text: String,
                             into xml: inout XMLWriter) {
        let style = spec.style(ofSeries: index)
        let color = ODSChartWriter.hex(ODSChartWriter.color(style, index: index))
        let lineWidth = ODSLength.drawing(pixels: max(style.lineWidth ?? ODSChartWriter.defaultLineWidth, 0))
        var chart = ""
        var graphic = ""
        switch mark(ofSeries: index) {
        case .bar:
            graphic = " draw:stroke=\"none\" draw:fill=\"solid\" draw:fill-color=\"\(color)\""
        case .area:
            graphic = " draw:stroke=\"solid\" svg:stroke-width=\"\(lineWidth)\" svg:stroke-color=\"\(color)\" draw:fill=\"solid\""
                + " draw:fill-color=\"\(color)\" draw:opacity=\"30%\""
        case .line:
            graphic = " draw:stroke=\"solid\" svg:stroke-width=\"\(lineWidth)\" svg:stroke-color=\"\(color)\" draw:fill-color=\"\(color)\""
            if let size = style.pointSize, size > 0 {
                let length = ODSLength.drawing(pixels: size)
                chart += " chart:symbol-type=\"named-symbol\" chart:symbol-name=\"circle\" chart:symbol-width=\"\(length)\" chart:symbol-height=\"\(length)\""
            } else {
                chart += " chart:symbol-type=\"none\""
            }
        case .point:
            graphic = " draw:stroke=\"none\" svg:stroke-color=\"\(color)\" draw:fill=\"solid\" draw:fill-color=\"\(color)\""
            let length = ODSLength.drawing(pixels: max(style.pointSize ?? ODSChartWriter.defaultPointSize, 0))
            chart += " chart:symbol-type=\"named-symbol\" chart:symbol-name=\"circle\" chart:symbol-width=\"\(length)\" chart:symbol-height=\"\(length)\""
        case .slice:
            graphic = " draw:stroke=\"solid\" svg:stroke-color=\"#ffffff\" draw:fill=\"solid\" draw:fill-color=\"\(color)\""
        }
        chart += dataLabelProperties(seriesIndex: index)
        let styleName = styles.add(Style(chart: chart, graphic: graphic, text: text))

        xml.raw("<chart:series\(ODSChartWriter.styleAttribute(styleName))")
        xml.attribute("chart:values-cell-range-address", addresses(series.blocks))
        if let name = series.name {
            xml.attribute("chart:label-cell-address", ODSChartWriter.address(ODSSheetRange(sheet: name.sheet, range: CellRange(name.address)), names: names))
        }
        xml.raw(" chart:class=\"\(seriesClass(index))\"")
        if secondaryAxis { xml.raw(" chart:attached-axis=\"\(style.usesRightAxis ? "secondary-y" : "primary-y")\"") }
        xml.raw(">")
        // Scatter charts take their x values from the labels column; later series share the first's.
        if spec.kind == .scatter, index == 0, let labels = layout?.labelBlocks, !labels.isEmpty {
            xml.raw("<chart:domain")
            xml.attribute("table:cell-range-address", addresses(labels))
            xml.raw("/>")
        }
        // Each slice of a pie has its own color.
        if mark(ofSeries: index) == .slice {
            for point in 0..<series.cells.count {
                let pointStyle = styles.add(Style(graphic: " draw:fill-color=\"\(ODSChartWriter.hex(ODSChartWriter.color(spec.style(ofSeries: point), index: point)))\""))
                xml.raw("<chart:data-point\(ODSChartWriter.styleAttribute(pointStyle))/>")
            }
        }
        xml.raw("</chart:series>")
    }

    // MARK: - Local table

    private func number(_ cell: ODSSheetCell) -> Double {
        guard workbook.sheets.indices.contains(cell.sheet), let value = workbook.sheets[cell.sheet].value(at: cell.address).numberValue,
              value.isFinite else { return .nan }
        return value
    }

    private func label(_ cell: ODSSheetCell?) -> String {
        guard let cell, workbook.sheets.indices.contains(cell.sheet) else { return "" }
        let sheet = workbook.sheets[cell.sheet]
        return CellDisplay.text(for: sheet.value(at: cell.address), pattern: sheet.cells[cell.address]?.format.numberFormat).text
    }

    /// The chart's data copied into `table:table name="local-table"`, as LibreOffice includes it:
    /// series in columns (or in rows when switched), the labels down the first column.
    private func writeLocalTable(into xml: inout XMLWriter) {
        var series = layout?.series ?? []
        if isPie { series = Array(series.prefix(1)) }
        let labels = layout?.labelCells ?? []
        var columns: [(name: String, values: [Double])] = []
        if spec.kind == .scatter, !labels.isEmpty { columns.append(("", labels.map(number))) }
        for (index, item) in series.enumerated() {
            let name = item.name.map { label($0) } ?? "Series \(index + 1)"
            columns.append((name, item.cells.map(number)))
        }
        var count = max(columns.map(\.values.count).max() ?? 0, spec.kind == .scatter ? 0 : labels.count)
        // Trailing rows without data are left out.
        while count > 0, columns.allSatisfy({ count - 1 >= $0.values.count || $0.values[count - 1].isNaN }),
              spec.kind == .scatter || count - 1 >= labels.count || label(labels[count - 1]).isEmpty {
            count -= 1
        }
        let categories: [String] = (0..<count).map { row in
            spec.kind != .scatter && row < labels.count ? label(labels[row]) : String(row + 1)
        }
        func stringCell(_ text: String, into xml: inout XMLWriter) {
            xml.raw("<table:table-cell office:value-type=\"string\"><text:p>")
            xml.text(text)
            xml.raw("</text:p></table:table-cell>")
        }
        func numberCell(_ value: Double, into xml: inout XMLWriter) {
            let text = value.isNaN ? "NaN" : XLSXValue.string(value)
            xml.raw("<table:table-cell office:value-type=\"float\" office:value=\"\(text)\"><text:p>\(text)</text:p></table:table-cell>")
        }
        let inRows = spec.switchRowsAndColumns
        let headers = inRows ? categories : columns.map(\.name)
        xml.raw("<table:table table:name=\"local-table\">")
        xml.raw("<table:table-header-columns><table:table-column/></table:table-header-columns>")
        xml.raw("<table:table-columns><table:table-column table:number-columns-repeated=\"\(max(headers.count, 1))\"/></table:table-columns>")
        xml.raw("<table:table-header-rows><table:table-row><table:table-cell><text:p/></table:table-cell>")
        for header in headers { stringCell(header, into: &xml) }
        xml.raw("</table:table-row></table:table-header-rows><table:table-rows>")
        if inRows {
            for column in columns {
                xml.raw("<table:table-row>")
                stringCell(column.name, into: &xml)
                for row in 0..<count { numberCell(row < column.values.count ? column.values[row] : .nan, into: &xml) }
                xml.raw("</table:table-row>")
            }
        } else {
            for row in 0..<count {
                xml.raw("<table:table-row>")
                stringCell(categories[row], into: &xml)
                for column in columns { numberCell(row < column.values.count ? column.values[row] : .nan, into: &xml) }
                xml.raw("</table:table-row>")
            }
        }
        // A table has at least one row.
        if (inRows ? columns.count : count) == 0 { xml.raw("<table:table-row><table:table-cell><text:p/></table:table-cell></table:table-row>") }
        xml.raw("</table:table-rows></table:table>")
    }

    // MARK: - Other parts

    static var stylesPart: Data {
        var xml = XMLWriter()
        xml.raw("<office:document-styles \(namespaces) office:version=\"1.3\"><office:styles/></office:document-styles>")
        return xml.data
    }

    static var metaPart: Data {
        var xml = XMLWriter()
        xml.raw("<office:document-meta \(namespaces) office:version=\"1.3\"><office:meta><meta:generator>PuggleSheets</meta:generator></office:meta></office:document-meta>")
        return xml.data
    }
}
