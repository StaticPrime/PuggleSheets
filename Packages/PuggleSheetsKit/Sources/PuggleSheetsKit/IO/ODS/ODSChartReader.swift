import Foundation

/// Reads an embedded OpenDocument chart (LibreOffice's or ours) into a chart spec. The spec's ranges,
/// header and label flags are rebuilt so the chart module's layout rules give the file's series.
struct ODSChartReader {
    struct Result {
        var spec: ChartSpec
        var warnings: Set<ImportWarning>
    }

    /// A series as the file describes it.
    struct FileSeries {
        var node: XNode
        var values: [ODSSheetRange]
        var label: ODSSheetCell?
        var chartClass: String
        var secondaryAxis: Bool
        var domain: [ODSSheetRange]
    }

    private let root: XNode
    private let sheetIndex: Int
    private let workbook: Workbook
    private let fileNames: [String]
    private var styles: [String: XNode] = [:]
    private var fontFaces: [String: String] = [:]
    private var warnings = Set<ImportWarning>()

    /// The chart in a chart object's content.xml; nil when it can't be represented (its data isn't in
    /// the sheets, or none of its ranges can be found).
    static func read(_ root: XNode, sheetIndex: Int, workbook: Workbook, fileNames: [String], extras: ODSChartExtras?) -> Result? {
        var reader = ODSChartReader(root: root, sheetIndex: sheetIndex, workbook: workbook, fileNames: fileNames)
        return reader.read(extras: extras)
    }

    private init(root: XNode, sheetIndex: Int, workbook: Workbook, fileNames: [String]) {
        self.root = root
        self.sheetIndex = sheetIndex
        self.workbook = workbook
        self.fileNames = fileNames
        for style in root.child("automatic-styles")?.children("style") ?? [] {
            if let name = style["name"] { styles[name] = style }
        }
        for face in root.child("font-face-decls")?.children("font-face") ?? [] {
            if let name = face["name"] { fontFaces[name] = ODSStyleSheet.family(face["font-family"] ?? name) }
        }
    }

    // MARK: - Helpers

    private func property(_ styleName: String?, _ element: String, _ attribute: String) -> String? {
        guard let styleName, let style = styles[styleName] else { return nil }
        return style.child(element)?[attribute]
    }

    private func chartProperty(_ node: XNode?, _ attribute: String) -> String? {
        property(node?["style-name"], "chart-properties", attribute)
    }

    private func graphicProperty(_ node: XNode?, _ attribute: String) -> String? {
        property(node?["style-name"], "graphic-properties", attribute)
    }

    private static func localName(_ qualified: String?) -> String {
        guard let qualified else { return "" }
        return XMLParsing.localName(qualified)
    }

    private func sheetIndex(named name: String?) -> Int? {
        guard let name else { return sheetIndex }
        if let index = fileNames.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return index }
        return workbook.sheetIndex(named: name)
    }

    /// A list of addresses as sheet ranges; nil when one of them can't be found.
    private func ranges(_ text: String?) -> [ODSSheetRange]? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return [] }
        let parsed = ODSFormula.parseAddressList(text)
        guard !parsed.isEmpty else { return nil }
        var result: [ODSSheetRange] = []
        for item in parsed {
            guard let index = sheetIndex(named: item.sheet), workbook.sheets.indices.contains(index) else { return nil }
            result.append(ODSSheetRange(sheet: index, range: item.range))
        }
        return result
    }

    private static func paragraphs(_ node: XNode?) -> String {
        guard let node else { return "" }
        return node.children("p").map { ODSDrawingReader.text($0) }.joined(separator: "\n")
    }

    private static func color(_ text: String?) -> RGBColor? {
        text.flatMap(ODSStyleSheet.color)
    }

    private func pixels(_ text: String?) -> Double? {
        ODSLength.pixels(text).map { ($0 * 2).rounded() / 2 }
    }

    // MARK: - Reading

    private mutating func read(extras: ODSChartExtras?) -> Result? {
        guard let chart = root.child("body")?.child("chart")?.child("chart") else { return nil }
        // Charts with their own data ("." or no ranges) don't read from the sheets.
        if chart["href"] == "." { return nil }
        guard let plotArea = chart.child("plot-area") else { return nil }
        let plotStyle = plotArea["style-name"]
        func plot(_ attribute: String) -> String? { property(plotStyle, "chart-properties", attribute) }

        // Series.
        var series: [FileSeries] = []
        let axes = plotArea.children("axis")
        let secondaryNames = Set(axes.filter { $0["dimension"] == "y" && ($0["name"] ?? "").hasPrefix("secondary") }.compactMap { $0["name"] })
        let chartClass = Self.localName(chart["class"])
        for node in plotArea.children("series") {
            guard let values = ranges(node["values-cell-range-address"]) else {
                warnings.insert(.charts)
                continue
            }
            let label = ranges(node["label-cell-address"])?.first.map { ODSSheetCell(sheet: $0.sheet, address: $0.range.start) }
            if node["label-string"] != nil, label == nil { warnings.insert(.charts) }
            var domain: [ODSSheetRange] = []
            for item in node.children("domain") {
                if let parsed = ranges(item["cell-range-address"]) {
                    if domain.isEmpty { domain = parsed }
                } else {
                    warnings.insert(.charts)
                }
            }
            for child in node.children where ["regression-curve", "error-indicator", "mean-value", "property-mapping"].contains(child.name) {
                warnings.insert(.charts)
            }
            let seriesClass = node["class"].map { Self.localName($0) } ?? chartClass
            series.append(FileSeries(node: node, values: values, label: label, chartClass: seriesClass,
                                     secondaryAxis: node["attached-axis"].map { secondaryNames.contains($0) || $0.hasPrefix("secondary") } ?? false,
                                     domain: domain))
        }
        if plotArea.children.contains(where: { ["stock-gain-marker", "stock-loss-marker", "stock-range-line"].contains($0.name) }) {
            warnings.insert(.charts)
        }
        if plot("three-dimensional") == "true" { warnings.insert(.charts) }

        let xAxis = axes.first { $0["dimension"] == "x" && ($0["name"] ?? "primary-x") != "secondary-x" }
        let yAxis = axes.first { $0["dimension"] == "y" && !($0["name"] ?? "").hasPrefix("secondary") }
        if axes.contains(where: { $0["dimension"] == "z" }) || axes.contains(where: { $0["name"] == "secondary-x" }) { warnings.insert(.charts) }

        // The kind.
        let stacked = plot("stacked") == "true", percent = plot("percentage") == "true", vertical = plot("vertical") == "true"
        var spec = ChartSpec(ranges: [])
        spec.kind = kind(chartClass: chartClass, stacked: stacked, percent: percent, vertical: vertical,
                         interpolation: plot("interpolation"), seriesClasses: series.map(\.chartClass))
        if spec.kind == .donut, let hole = plot("hole-size"), hole.hasSuffix("%"), let value = Double(hole.dropLast()), value.isFinite {
            spec.pieHole = min(max(value / 100, 0), 0.95)
        }

        // Ranges, header and labels.
        let categories: [ODSSheetRange]
        if spec.kind == .scatter {
            categories = series.first?.domain ?? []
        } else {
            let text = xAxis?.child("categories")?["cell-range-address"]
            categories = ranges(text) ?? []
            if ranges(text) == nil { warnings.insert(.charts) }
        }
        let plotRanges = ranges(plotArea["cell-range-address"]) ?? []
        let labelsInfo = plotArea["data-source-has-labels"] ?? "none"
        let seriesSource = plot("series-source")
        // What OpenDocument can't hold, kept by PuggleSheets for the chart as it was written.
        let kept = extras.flatMap { $0.fingerprint == ODSChartExtras.fingerprint(series: series, kind: spec.kind, categories: categories) ? $0 : nil }
        let source = dataSource(series: series, categories: categories, plotRanges: plotRanges, hasLabels: labelsInfo,
                                seriesSource: seriesSource, kind: spec.kind)
        // A chart without data in the sheets is left out, unless PuggleSheets wrote it (its ranges name nothing now).
        guard source != nil || kept != nil else { return nil }
        if let source {
            spec.ranges = source.ranges
            spec.firstRowIsHeader = source.header
            spec.firstColumnIsLabels = source.labels
            spec.switchRowsAndColumns = source.switched
        }

        // Titles and legend.
        spec.title = Self.paragraphs(chart.child("title"))
        spec.subtitle = Self.paragraphs(chart.child("subtitle"))
        let isBar = [.bar, .stackedBar, .percentBar].contains(spec.kind)
        let xTitle = Self.paragraphs(xAxis?.child("title")), yTitle = Self.paragraphs(yAxis?.child("title"))
        spec.horizontalAxisTitle = isBar ? yTitle : xTitle
        spec.verticalAxisTitle = isBar ? xTitle : yTitle
        if let legend = chart.child("legend") {
            let position = legend["legend-position"] ?? "end"
            if XLSXValue.isTrue(legend["overlay"]) {
                spec.legend = .inside
            } else if position.hasPrefix("top") {
                spec.legend = .top
            } else if position.hasPrefix("bottom") {
                spec.legend = .bottom
            } else {
                spec.legend = position == "start" ? .left : .auto
            }
        } else {
            spec.legend = .none
        }

        // Look.
        if graphicProperty(chart, "fill") != "none", let fill = Self.color(graphicProperty(chart, "fill-color")), fill != .white {
            spec.backgroundColor = fill
        }
        for node in [chart.child("title"), chart.child("legend"), xAxis, yAxis, chart.child("subtitle")] + series.map({ Optional($0.node) }) {
            if let family = fontFamily(node) {
                spec.fontFamily = family
                break
            }
        }
        if let yAxis {
            spec.verticalMinimum = XLSXValue.double(chartProperty(yAxis, "minimum"))
            spec.verticalMaximum = XLSXValue.double(chartProperty(yAxis, "maximum"))
            spec.logScale = chartProperty(yAxis, "logarithmic") == "true"
            spec.showsGridlines = yAxis.children("grid").contains { ($0["class"] ?? "major") == "major" }
        } else {
            spec.showsGridlines = false
        }
        if spec.kind == .pie || spec.kind == .donut { spec.logScale = false }
        readSeriesStyles(series, defaultSymbol: plot("symbol-type"), into: &spec)

        kept?.apply(to: &spec)
        return Result(spec: spec, warnings: warnings)
    }

    private mutating func kind(chartClass: String, stacked: Bool, percent: Bool, vertical: Bool, interpolation: String?,
                               seriesClasses: [String]) -> ChartSpec.Kind {
        let mixable: Set<String> = ["bar", "line", "area"]
        if mixable.contains(chartClass), seriesClasses.contains(where: { $0 != chartClass && mixable.contains($0) }) {
            if vertical || stacked || percent { warnings.insert(.charts) }
            return .combo
        }
        switch chartClass {
        case "bar":
            if vertical { return percent ? .percentBar : stacked ? .stackedBar : .bar }
            return percent ? .percentColumn : stacked ? .stackedColumn : .column
        case "line":
            if stacked || percent { warnings.insert(.charts) }
            switch interpolation {
            case "cubic-spline", "b-spline": return .smoothLine
            case nil, "none": return .line
            default:
                warnings.insert(.charts)
                return .line
            }
        case "area":
            return percent ? .percentArea : stacked ? .stackedArea : .area
        case "circle": return .pie
        case "ring": return .donut
        case "scatter": return .scatter
        case "bubble":
            warnings.insert(.charts)
            return .scatter
        case "radar":
            warnings.insert(.charts)
            return .line
        case "filled-radar":
            warnings.insert(.charts)
            return .area
        case "stock":
            warnings.insert(.charts)
            return .line
        default:
            warnings.insert(.charts)
            return .column
        }
    }

    private func fontFamily(_ node: XNode?) -> String? {
        guard let name = node?["style-name"], let text = styles[name]?.child("text-properties") else { return nil }
        if let face = text["font-name"] { return fontFaces[face] ?? face }
        return text["font-family"].map(ODSStyleSheet.family).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Data source

    private struct DataSource {
        var ranges: [String]
        var header: Bool
        var labels: Bool
        var switched: Bool
    }

    /// A range as a reference from the chart's sheet: "A1:C10", or "'Other sheet'!A1:C10".
    private func reference(_ range: ODSSheetRange) -> String {
        range.sheet == sheetIndex ? range.range.a1 : SheetNames.quoted(workbook.sheets[range.sheet].name) + "!" + range.range.a1
    }

    /// Whether `spec` lays out the file's series (the first only for pie charts) and labels.
    private func matches(_ spec: ChartSpec, series: [FileSeries], categories: [ODSSheetRange]) -> Bool {
        guard let layout = ODSChartLayout(spec: spec, sheetIndex: sheetIndex, workbook: workbook) else { return false }
        let isPie = spec.kind == .pie || spec.kind == .donut
        if isPie {
            guard let first = series.first, let expected = layout.series.first else { return false }
            guard expected.name == first.label, ODSChartLayout.visibleCells(first.values, in: workbook) == expected.cells else { return false }
        } else {
            guard layout.series.count == series.count else { return false }
            for (expected, actual) in zip(layout.series, series) {
                guard expected.name == actual.label, ODSChartLayout.visibleCells(actual.values, in: workbook) == expected.cells else { return false }
            }
        }
        return ODSChartLayout.visibleCells(categories, in: workbook) == layout.labelCells
    }

    private mutating func dataSource(series: [FileSeries], categories: [ODSSheetRange], plotRanges: [ODSSheetRange], hasLabels: String,
                                     seriesSource: String?, kind: ChartSpec.Kind) -> DataSource? {
        // The orientation: series down columns, or across rows.
        var switched = seriesSource == "rows"
        if seriesSource == nil, let first = series.first?.values.first {
            switched = first.range.rowCount == 1 && first.range.columnCount > 1
        }
        func spec(_ ranges: [String], header: Bool, labels: Bool, switched: Bool) -> ChartSpec {
            ChartSpec(kind: kind, ranges: ranges, firstRowIsHeader: header, firstColumnIsLabels: labels, switchRowsAndColumns: switched)
        }

        // 1. The plot area's ranges, as LibreOffice writes them for a chart of a selection.
        if !plotRanges.isEmpty {
            let firstRow = hasLabels == "row" || hasLabels == "both", firstColumn = hasLabels == "column" || hasLabels == "both"
            var header = switched ? firstColumn : firstRow
            var labels = switched ? firstRow : firstColumn
            if kind == .scatter { labels = !categories.isEmpty }
            if series.allSatisfy({ $0.label == nil }) { header = false }
            let ranges = plotRanges.map(reference)
            for candidate in [(header, labels), (!header, labels), (header, !labels)] {
                if matches(spec(ranges, header: candidate.0, labels: candidate.1, switched: switched), series: series, categories: categories) {
                    return DataSource(ranges: ranges, header: candidate.0, labels: candidate.1, switched: switched)
                }
            }
        }

        // 2. Ranges rebuilt from the series.
        if let rebuilt = rebuild(series: series, categories: categories, switched: switched, kind: kind),
           matches(spec(rebuilt.ranges, header: rebuilt.header, labels: rebuilt.labels, switched: rebuilt.switched), series: series, categories: categories) {
            return rebuilt
        }

        // 3. The closest: the plot area, or the series' own cells.
        let blocks = categories + series.flatMap(\.values)
        guard !plotRanges.isEmpty || !blocks.isEmpty else { return nil }
        warnings.insert(.charts)
        if !plotRanges.isEmpty {
            let firstRow = hasLabels == "row" || hasLabels == "both", firstColumn = hasLabels == "column" || hasLabels == "both"
            return DataSource(ranges: plotRanges.map(reference), header: switched ? firstColumn : firstRow,
                              labels: kind == .scatter ? !categories.isEmpty : (switched ? firstRow : firstColumn), switched: switched)
        }
        return DataSource(ranges: blocks.map(reference), header: false, labels: !categories.isEmpty, switched: switched)
    }

    /// Ranges for series that each take one line (column, or row when switched) of one sheet, spanning
    /// the same cells, with their names just before them and the labels in a line of their own.
    private func rebuild(series: [FileSeries], categories: [ODSSheetRange], switched: Bool, kind: ChartSpec.Kind) -> DataSource? {
        guard !series.isEmpty, series.allSatisfy({ $0.values.count == 1 }), categories.count <= 1 else { return nil }
        let blocks = series.map { $0.values[0] }
        let sheet = blocks[0].sheet
        guard blocks.allSatisfy({ $0.sheet == sheet }), categories.allSatisfy({ $0.sheet == sheet }) else { return nil }
        // Lines and spans in the orientation's terms.
        func line(_ range: CellRange) -> (index: Int, span: ClosedRange<Int>)? {
            if switched {
                guard range.rowCount == 1 else { return nil }
                return (range.start.row, range.columns)
            }
            guard range.columnCount == 1 else { return nil }
            return (range.start.column, range.rows)
        }
        let lines = blocks.compactMap { line($0.range) }
        guard lines.count == blocks.count, let span = lines.first?.span, lines.allSatisfy({ $0.span == span }) else { return nil }
        // Names just before each series.
        let named = series.compactMap(\.label)
        let header: Bool
        if named.isEmpty {
            header = false
        } else {
            guard named.count == series.count, span.lowerBound > 0 else { return nil }
            for (label, item) in zip(named, lines) {
                let expected = switched ? CellAddress(row: item.index, column: span.lowerBound - 1)
                    : CellAddress(row: span.lowerBound - 1, column: item.index)
                guard label.sheet == sheet, label.address == expected else { return nil }
            }
            header = true
        }
        var allLines = lines.map(\.index)
        var labels = false
        if let category = categories.first {
            guard let categoryLine = line(category.range), categoryLine.span == span else { return nil }
            allLines.insert(categoryLine.index, at: 0)
            labels = true
        }
        let start = header ? span.lowerBound - 1 : span.lowerBound
        var ranges: [ODSSheetRange] = []
        if switched {
            // Rows are joined side by side by column, so the lines must follow each other.
            guard zip(allLines, allLines.dropFirst()).allSatisfy({ $1 == $0 + 1 }) else { return nil }
            ranges = [ODSSheetRange(sheet: sheet, range: CellRange(rows: allLines[0]...allLines[allLines.count - 1], columns: start...span.upperBound))]
        } else {
            var runStart = allLines[0], previous = allLines[0]
            for index in allLines.dropFirst() + [Int.min] {
                if index == previous + 1 {
                    previous = index
                    continue
                }
                ranges.append(ODSSheetRange(sheet: sheet, range: CellRange(rows: start...span.upperBound, columns: runStart...previous)))
                runStart = index
                previous = index
            }
        }
        return DataSource(ranges: ranges.map(reference), header: header, labels: labels, switched: switched)
    }

    // MARK: - Series styles

    /// Series styles: colors that differ from the default palette, line widths and point sizes that
    /// differ from its defaults, data labels, axes and combo types. `defaultSymbol` is the plot area's
    /// symbol type, which series without their own inherit.
    private mutating func readSeriesStyles(_ series: [FileSeries], defaultSymbol: String?, into spec: inout ChartSpec) {
        let palette = ODSChartWriter.palette
        if spec.kind == .pie || spec.kind == .donut {
            guard let first = series.first else { return }
            // Slice colors come from the data points.
            var styles: [ChartSeriesStyle] = []
            var index = 0
            for point in first.node.children("data-point") {
                let repeated = min(max(Int(point["repeated"] ?? "1") ?? 1, 1), 10_000)
                let color = Self.color(graphicProperty(point, "fill-color"))
                for _ in 0..<repeated {
                    var style = ChartSeriesStyle()
                    if let color, color != palette[index % palette.count] { style.color = color }
                    styles.append(style)
                    index += 1
                }
            }
            while let last = styles.last, last == ChartSeriesStyle() { styles.removeLast() }
            spec.series = styles
            let number = chartProperty(first.node, "data-label-number") ?? chartProperty(first.node.child("data-label"), "data-label-number")
            let text = chartProperty(first.node, "data-label-text") ?? chartProperty(first.node.child("data-label"), "data-label-text")
            switch number {
            case "percentage", "value-and-percentage": spec.pieSliceLabel = .percentage
            case "value": spec.pieSliceLabel = .value
            default: spec.pieSliceLabel = text == "true" ? .label : .none
            }
            return
        }

        var styles: [ChartSeriesStyle] = []
        var labels: [Bool] = []
        for (index, item) in series.enumerated() {
            var style = ChartSeriesStyle()
            let node = item.node
            let type: ChartSeriesStyle.SeriesType
            switch item.chartClass {
            case "line": type = .line
            case "area": type = .area
            default: type = .column
            }
            let isLine: Bool
            switch spec.kind {
            case .combo: isLine = type == .line
            case .line, .smoothLine: isLine = true
            default: isLine = false
            }
            let color: RGBColor?
            if isLine {
                color = Self.color(graphicProperty(node, "stroke-color")) ?? Self.color(graphicProperty(node, "fill-color"))
            } else {
                color = Self.color(graphicProperty(node, "fill-color")) ?? Self.color(graphicProperty(node, "stroke-color"))
            }
            if let color, color != palette[index % palette.count] { style.color = color }
            if isLine || type == .area && (spec.kind == .combo || [.area, .stackedArea, .percentArea].contains(spec.kind)) {
                if let width = pixels(graphicProperty(node, "stroke-width")), width != ODSChartWriter.defaultLineWidth { style.lineWidth = width }
            }
            let symbol = chartProperty(node, "symbol-type") ?? defaultSymbol
            if spec.kind == .scatter {
                if symbol == "none" {
                    style.pointSize = 0
                } else if let size = pixels(chartProperty(node, "symbol-width")), size != ODSChartWriter.defaultPointSize {
                    style.pointSize = size
                }
            } else if isLine, let symbol, symbol != "none" {
                // LibreOffice's automatic symbols are 0.25 cm.
                style.pointSize = pixels(chartProperty(node, "symbol-width")) ?? pixels("0.25cm")
            }
            if spec.kind == .combo, type != ODSChartWriter.comboType(ChartSeriesStyle(), index: index) { style.type = type }
            style.usesRightAxis = item.secondaryAxis
            let number = chartProperty(node, "data-label-number") ?? chartProperty(node.child("data-label"), "data-label-number")
            let text = chartProperty(node, "data-label-text") ?? chartProperty(node.child("data-label"), "data-label-text")
            labels.append(number == "value" || number == "value-and-percentage" || number == "percentage" || text == "true")
            styles.append(style)
        }
        let allLabeled = !labels.isEmpty && labels.allSatisfy { $0 }
        spec.showsDataLabels = allLabeled
        if !allLabeled {
            for (index, shows) in labels.enumerated() where shows { styles[index].showsDataLabels = true }
        }
        while let last = styles.last, last == ChartSeriesStyle() { styles.removeLast() }
        spec.series = styles
    }
}
