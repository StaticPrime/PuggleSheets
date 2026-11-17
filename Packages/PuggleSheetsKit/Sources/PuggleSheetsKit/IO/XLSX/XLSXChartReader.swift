import Foundation

/// DrawingML colors (srgbClr, schemeClr with luminance changes, sysClr, prstClr) as sRGB.
enum XLSXDrawingColor {
    /// The color held by a fill or color element's first color child; nil when there's none.
    static func color(_ node: XNode?, theme: XLSXTheme) -> RGBColor? {
        guard let node else { return nil }
        for child in node.children {
            let base: RGBColor?
            switch child.name {
            case "srgbClr": base = RGBColor(hex: child["val"] ?? "")
            case "schemeClr": base = scheme(child["val"], theme: theme)
            case "sysClr": base = RGBColor(hex: child["lastClr"] ?? "") ?? (child["val"] == "window" ? .white : .black)
            case "prstClr": base = preset(child["val"])
            case "scrgbClr":
                func channel(_ name: String) -> UInt8 {
                    UInt8(min(max((XLSXValue.double(child[name]) ?? 0) / 100_000, 0), 1) * 255)
                }
                base = RGBColor(red: channel("r"), green: channel("g"), blue: channel("b"))
            default: continue
            }
            guard let base else { return nil }
            return modified(base, by: child.children)
        }
        return nil
    }

    private static func scheme(_ name: String?, theme: XLSXTheme) -> RGBColor? {
        let index: Int? = switch name {
        case "bg1", "lt1": 0
        case "tx1", "dk1": 1
        case "bg2", "lt2": 2
        case "tx2", "dk2": 3
        case "accent1": 4
        case "accent2": 5
        case "accent3": 6
        case "accent4": 7
        case "accent5": 8
        case "accent6": 9
        case "hlink": 10
        case "folHlink": 11
        default: nil
        }
        guard let index, theme.colors.indices.contains(index) else { return nil }
        return theme.colors[index]
    }

    private static func preset(_ name: String?) -> RGBColor? {
        switch name?.lowercased() {
        case "black": .black
        case "white": .white
        case "red": RGBColor(hex: "FF0000")
        case "green": RGBColor(hex: "008000")
        case "blue": RGBColor(hex: "0000FF")
        case "yellow": RGBColor(hex: "FFFF00")
        case "gray", "grey": RGBColor(hex: "808080")
        default: nil
        }
    }

    /// Applies tint, shade and luminance changes (values in thousandths of a percent).
    private static func modified(_ color: RGBColor, by changes: [XNode]) -> RGBColor {
        var red = Double(color.red) / 255, green = Double(color.green) / 255, blue = Double(color.blue) / 255
        for change in changes {
            guard let value = XLSXValue.double(change["val"]).map({ $0 / 100_000 }) else { continue }
            switch change.name {
            case "tint":
                red = red * value + (1 - value)
                green = green * value + (1 - value)
                blue = blue * value + (1 - value)
            case "shade":
                red *= value
                green *= value
                blue *= value
            case "lumMod", "lumOff":
                var (hue, saturation, lightness) = hsl(red, green, blue)
                lightness = change.name == "lumMod" ? lightness * value : lightness + value
                (red, green, blue) = rgb(hue, saturation, min(max(lightness, 0), 1))
            default:
                continue
            }
        }
        func byte(_ channel: Double) -> UInt8 { UInt8((min(max(channel, 0), 1) * 255).rounded()) }
        return RGBColor(red: byte(red), green: byte(green), blue: byte(blue))
    }

    private static func hsl(_ red: Double, _ green: Double, _ blue: Double) -> (Double, Double, Double) {
        let high = max(red, green, blue), low = min(red, green, blue)
        let lightness = (high + low) / 2
        guard high != low else { return (0, 0, lightness) }
        let delta = high - low
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        var hue: Double
        if high == red {
            hue = (green - blue) / delta + (green < blue ? 6 : 0)
        } else if high == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue /= 6
        return (hue, saturation, lightness)
    }

    private static func rgb(_ hue: Double, _ saturation: Double, _ lightness: Double) -> (Double, Double, Double) {
        guard saturation > 0 else { return (lightness, lightness, lightness) }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(hue + 1.0 / 3), channel(hue), channel(hue - 1.0 / 3))
    }
}

/// Reads DrawingML chart parts (xl/charts/chartN.xml) into chart specs.
enum XLSXChartReader {
    struct Context {
        let sheetIndex: Int
        let sheets: [Sheet]
        /// Lowercased sheet names as the file writes them → index into `sheets`.
        let sheetIndexes: [String: Int]
        let theme: XLSXTheme
    }

    enum Family: Equatable {
        case column, bar, line, area, pie, doughnut, scatter
    }

    private struct ReadSeries {
        var order = 0
        var position = 0
        var excel = XLSXChartLayout.ExcelSeries()
        var style = ChartSeriesStyle()
        var family = Family.column
        var smooth = false
    }

    /// The chart's spec, or nil when it can't be kept (no series referencing cells, unknown kinds).
    /// `unsupported` reports features left behind.
    static func read(_ data: Data, context: Context) -> (spec: ChartSpec?, unsupported: Bool) {
        guard let root = try? XMLTree.parse(data), root.name == "chartSpace", let chart = root.child("chart"),
              let plotArea = chart.child("plotArea") else { return (nil, true) }
        var unsupported = false
        var axes: [String: XNode] = [:]
        for node in plotArea.children where ["catAx", "valAx", "dateAx", "serAx"].contains(node.name) {
            if let id = node.child("axId")?["val"] { axes[id] = node }
        }

        var series: [ReadSeries] = []
        var primaryAxisIDs: [String]?
        var primaryFamily: Family?
        var grouping = "standard"
        var holeSize: Double?
        var pieLabels = ChartSpec.PieLabel.none
        var showsLabels = false
        for group in plotArea.children {
            let family: Family
            switch group.name {
            case "barChart", "bar3DChart":
                family = group.child("barDir")?["val"] == "bar" ? .bar : .column
                if group.name == "bar3DChart" { unsupported = true }
            case "lineChart", "line3DChart", "stockChart", "radarChart":
                family = .line
                if group.name != "lineChart" { unsupported = true }
                if let value = group.child("grouping")?["val"], value != "standard" { unsupported = true }
            case "areaChart", "area3DChart":
                family = .area
                if group.name == "area3DChart" { unsupported = true }
            case "pieChart", "pie3DChart", "ofPieChart":
                family = .pie
                if group.name != "pieChart" { unsupported = true }
            case "doughnutChart":
                family = .doughnut
            case "scatterChart", "bubbleChart":
                family = .scatter
                if group.name == "bubbleChart" { unsupported = true }
            case "surfaceChart", "surface3DChart":
                unsupported = true
                continue
            default:
                continue
            }
            let axisIDs = group.children("axId").compactMap { $0["val"] }
            let isPrimary = primaryFamily == nil
            if isPrimary {
                primaryAxisIDs = axisIDs
                primaryFamily = family
                grouping = group.child("grouping")?["val"] ?? (family == .column || family == .bar ? "clustered" : "standard")
                if family != .pie && family != .doughnut, labelsShown(group.child("dLbls")) == true { showsLabels = true }
            }
            let secondary = !isPrimary && !axisIDs.isEmpty && axisIDs != primaryAxisIDs
            if family == .doughnut, let hole = XLSXValue.double(group.child("holeSize")?["val"]) { holeSize = hole }
            if family == .pie || family == .doughnut { pieLabels = pieLabel(group.child("dLbls")) }
            for node in group.children("ser") {
                var item = readSeries(node, family: family, context: context, unsupported: &unsupported)
                item.order = XLSXValue.int(node.child("order")?["val"]) ?? XLSXValue.int(node.child("idx")?["val"]) ?? series.count
                item.position = series.count
                item.style.usesRightAxis = secondary
                series.append(item)
            }
        }
        guard let mainFamily = primaryFamily else { return (nil, true) }
        series.sort { ($0.order, $0.position) < ($1.order, $1.position) }

        // The kind: one family, or columns, lines and areas together as a combo chart.
        let families = Set(series.map { $0.family == .bar ? Family.column : $0.family }.map { "\($0)" })
        var kind = self.kind(mainFamily, grouping: grouping, smooth: !series.isEmpty && series.allSatisfy(\.smooth))
        var isCombo = false
        if families.count > 1 {
            if series.allSatisfy({ [.column, .bar, .line, .area].contains($0.family) }) {
                kind = .combo
                isCombo = true
                if series.contains(where: { $0.family == .bar }) { unsupported = true }
            } else {
                unsupported = true
                series = series.filter { $0.family == mainFamily }
            }
        }

        guard let inferred = XLSXChartLayout.infer(series.map(\.excel), chartSheet: context.sheetIndex, sheets: context.sheets,
                                                   sheetNames: context.sheets.map(\.name)) else { return (nil, true) }
        if inferred.isApproximate { unsupported = true }
        var spec = ChartSpec(kind: kind, ranges: inferred.ranges, firstRowIsHeader: inferred.firstRowIsHeader,
                             firstColumnIsLabels: inferred.firstColumnIsLabels, switchRowsAndColumns: inferred.switchRowsAndColumns)

        // Styles by series position; colors that are just the palette's stay automatic.
        var styles: [ChartSeriesStyle] = []
        for (index, item) in series.enumerated() {
            guard let position = inferred.seriesPositions[index] else { continue }
            var style = item.style
            if isCombo {
                let type: ChartSeriesStyle.SeriesType = item.family == .line ? .line : item.family == .area ? .area : .column
                style.type = type == (position == 0 ? .column : .line) ? nil : type
            }
            if style.color == XLSXChartWriter.paletteColor(position) { style.color = nil }
            while styles.count <= position { styles.append(ChartSeriesStyle()) }
            styles[position] = style
        }
        while let last = styles.last, last == ChartSeriesStyle() { styles.removeLast() }
        spec.series = styles

        let titleLines = chart.child("title").map(texts) ?? []
        spec.title = titleLines.first ?? ""
        spec.subtitle = titleLines.dropFirst().joined(separator: " ")
        spec.legend = legend(chart.child("legend"))

        // Axes: the primary group's. Bar charts lay categories vertically; scatter charts have two value axes.
        let primaryAxes = (primaryAxisIDs ?? []).compactMap { axes[$0] }
        let categoryAxis = primaryAxes.first { $0.name == "catAx" || $0.name == "dateAx" }
        let valueAxes = primaryAxes.filter { $0.name == "valAx" }
        var valueAxis: XNode?, horizontal: XNode?, vertical: XNode?
        switch mainFamily {
        case .scatter:
            horizontal = valueAxes.first { ["b", "t"].contains($0.child("axPos")?["val"] ?? "") } ?? valueAxes.first
            vertical = valueAxes.first { $0 !== horizontal }
            valueAxis = vertical
        case .bar:
            valueAxis = valueAxes.first
            horizontal = valueAxis
            vertical = categoryAxis
        default:
            valueAxis = valueAxes.first
            horizontal = categoryAxis
            vertical = valueAxis
        }
        spec.horizontalAxisTitle = horizontal.flatMap { $0.child("title") }.map(texts)?.first ?? ""
        spec.verticalAxisTitle = vertical.flatMap { $0.child("title") }.map(texts)?.first ?? ""
        if let axis = valueAxis {
            let scaling = axis.child("scaling")
            spec.verticalMinimum = XLSXValue.double(scaling?.child("min")?["val"])
            spec.verticalMaximum = XLSXValue.double(scaling?.child("max")?["val"])
            spec.logScale = scaling?.child("logBase") != nil
            spec.showsGridlines = axis.child("majorGridlines") != nil
        }
        spec.showsDataLabels = showsLabels
        if kind == .pie || kind == .donut { spec.pieSliceLabel = pieLabels }
        if kind == .donut { spec.pieHole = min(max((holeSize ?? 50) / 100, 0.1), 0.9) }

        if let background = XLSXDrawingColor.color(root.child("spPr")?.child("solidFill"), theme: context.theme), background != .white {
            spec.backgroundColor = background
        }
        if let font = root.child("txPr")?.firstDescendant("latin")?["typeface"], !font.isEmpty, !font.hasPrefix("+") {
            spec.fontFamily = font
        }
        return (spec, unsupported)
    }

    private static func kind(_ family: Family, grouping: String, smooth: Bool) -> ChartSpec.Kind {
        switch family {
        case .column: grouping == "stacked" ? .stackedColumn : grouping == "percentStacked" ? .percentColumn : .column
        case .bar: grouping == "stacked" ? .stackedBar : grouping == "percentStacked" ? .percentBar : .bar
        case .line: smooth ? .smoothLine : .line
        case .area: grouping == "stacked" ? .stackedArea : grouping == "percentStacked" ? .percentArea : .area
        case .pie: .pie
        case .doughnut: .donut
        case .scatter: .scatter
        }
    }

    // MARK: - Series

    private static func readSeries(_ node: XNode, family: Family, context: Context, unsupported: inout Bool) -> ReadSeries {
        var item = ReadSeries()
        item.family = family
        if let tx = node.child("tx") {
            if let formula = tx.child("strRef")?.child("f")?.text, let reference = reference(formula, context: context),
               reference.range.isSingleCell {
                item.excel.name = (reference.sheet, reference.range.start)
                if !reference.isExact { unsupported = true }
            } else {
                item.excel.hasLiteralName = true
            }
        }
        if let categories = node.child("cat") ?? node.child("xVal") {
            if let formula = (categories.child("numRef") ?? categories.child("strRef"))?.child("f")?.text,
               let reference = reference(formula, context: context) {
                item.excel.categories = (reference.sheet, reference.range)
                if !reference.isExact { unsupported = true }
            } else {
                // Several levels of labels, or labels typed into the chart.
                unsupported = true
            }
        }
        if let values = node.child("val") ?? node.child("yVal"), let formula = values.child("numRef")?.child("f")?.text,
           let reference = reference(formula, context: context) {
            item.excel.values = (reference.sheet, reference.range)
            if !reference.isExact { unsupported = true }
        } else {
            unsupported = true
        }

        let shape = node.child("spPr")
        switch family {
        case .column, .bar, .pie, .doughnut:
            item.style.color = XLSXDrawingColor.color(shape?.child("solidFill"), theme: context.theme)
        case .area:
            item.style.color = XLSXDrawingColor.color(shape?.child("solidFill"), theme: context.theme)
            if let line = shape?.child("ln"), line.child("noFill") == nil, let width = XLSXValue.double(line["w"]) {
                item.style.lineWidth = rounded(XLSXEMU.pixels(width))
            }
        case .line:
            let line = shape?.child("ln")
            item.style.color = XLSXDrawingColor.color(line?.child("solidFill"), theme: context.theme)
            if let width = XLSXValue.double(line?["w"]) {
                let pixels = rounded(XLSXEMU.pixels(width))
                // Two pixels is the default.
                item.style.lineWidth = pixels == 2 ? nil : pixels
            }
            item.style.pointSize = pointSize(node.child("marker"), family: family)
        case .scatter:
            item.style.color = XLSXDrawingColor.color(node.child("marker")?.child("spPr")?.child("solidFill"), theme: context.theme)
                ?? XLSXDrawingColor.color(shape?.child("ln")?.child("solidFill"), theme: context.theme)
            item.style.pointSize = pointSize(node.child("marker"), family: family)
        }
        if family != .pie && family != .doughnut { item.style.showsDataLabels = labelsShown(node.child("dLbls")) }
        item.smooth = flag(node.child("smooth")) == true
        return item
    }

    /// A series reference resolved to one of the workbook's sheets.
    private static func reference(_ formula: String, context: Context) -> (sheet: Int, range: CellRange, isExact: Bool)? {
        guard let parsed = XLSXChartLayout.parseReference(formula) else { return nil }
        let sheet: Int
        if let name = parsed.sheet {
            guard let index = context.sheetIndexes[name.lowercased()] else { return nil }
            sheet = index
        } else {
            sheet = context.sheetIndex
        }
        guard let area = XLSXChartLayout.singleArea(parsed.areas) else { return nil }
        return (sheet, area.range, area.isExact)
    }

    /// Points in pixels from a marker: none hides them (and is the default for lines).
    private static func pointSize(_ marker: XNode?, family: Family) -> Double? {
        guard let marker else { return nil }
        if marker.child("symbol")?["val"] == "none" { return family == .scatter ? 0 : nil }
        guard let size = XLSXValue.double(marker.child("size")?["val"]) else { return nil }
        return (size / 0.75).rounded()
    }

    private static func rounded(_ pixels: Double) -> Double { (pixels * 1000).rounded() / 1000 }

    /// A CT_Boolean element: absent is nil, `val` defaults to true.
    private static func flag(_ node: XNode?) -> Bool? {
        node.map { XLSXValue.isOn($0["val"]) }
    }

    static func labelsShown(_ node: XNode?) -> Bool? {
        guard let node else { return nil }
        if flag(node.child("delete")) == true { return false }
        return flag(node.child("showVal")) == true || flag(node.child("showPercent")) == true || flag(node.child("showCatName")) == true
    }

    private static func pieLabel(_ node: XNode?) -> ChartSpec.PieLabel {
        guard let node, flag(node.child("delete")) != true else { return .none }
        if flag(node.child("showPercent")) == true { return .percentage }
        if flag(node.child("showVal")) == true { return .value }
        if flag(node.child("showCatName")) == true { return .label }
        return .none
    }

    private static func legend(_ node: XNode?) -> ChartSpec.LegendPosition {
        guard let node else { return .none }
        switch node.child("legendPos")?["val"] ?? "r" {
        case "t": return .top
        case "b": return .bottom
        case "l": return .left
        default: return flag(node.child("overlay")) == true ? .inside : .auto
        }
    }

    /// The lines of a title: rich text paragraphs, or the cached text of a title taken from a cell.
    private static func texts(_ title: XNode) -> [String] {
        guard let text = title.child("tx") else { return [] }
        if let rich = text.child("rich") {
            return rich.children("p").map { paragraph in
                paragraph.children.map { run -> String in
                    switch run.name {
                    case "r", "fld": run.child("t")?.text ?? ""
                    case "br": " "
                    default: ""
                    }
                }.joined()
            }
        }
        if let cached = text.child("strRef")?.child("strCache")?.child("pt")?.child("v")?.text { return [cached] }
        return []
    }
}
