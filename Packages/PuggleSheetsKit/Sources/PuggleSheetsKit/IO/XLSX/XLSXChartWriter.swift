import Foundation

/// Writes a chart as a DrawingML chart part (xl/charts/chartN.xml): series as references to the
/// cells, with caches of their current values so other apps show the chart before recalculating.
enum XLSXChartWriter {
    /// The default series colors, in order. Series without a color of their own get these, so Excel
    /// shows the colors PuggleSheets does.
    static let palette: [RGBColor] = ["4285F4", "EA4335", "FBBC04", "34A853", "FF6D01", "46BDC6",
                                      "7BAAF7", "F07B72", "FCD04F", "71C287", "FF994D", "7ED1D7"].compactMap(RGBColor.init(hex:))

    static func paletteColor(_ index: Int) -> RGBColor { palette[index % palette.count] }

    /// The chart groups of a plot area: series drawn the same way against the same axes.
    enum GroupType: Equatable {
        case bar, line, area, pie, doughnut, scatter
    }

    struct Context {
        let workbook: Workbook
        let sheetIndex: Int
        /// Sheet names as the workbook part writes them.
        let sheetNames: [String]
    }

    static let primaryAxes = (category: 1001, value: 1002)
    static let secondaryAxes = (category: 1003, value: 1004)

    static func chartPart(_ spec: ChartSpec, context: Context) -> Data {
        let layout = XLSXChartLayout.layout(for: spec, sheetIndex: context.sheetIndex, workbook: context.workbook)
        var xml = XMLWriter(reservingCapacity: 4096 + layout.series.count * 2048)
        xml.raw("<c:chartSpace xmlns:c=\"\(XLSXNamespace.chart)\" xmlns:a=\"\(XLSXNamespace.drawingMain)\" "
            + "xmlns:r=\"\(XLSXNamespace.relationships)\">")
        xml.raw("<c:date1904 val=\"0\"/><c:roundedCorners val=\"0\"/>")
        xml.raw("<c:chart>")
        if spec.title.isEmpty && spec.subtitle.isEmpty {
            xml.raw("<c:autoTitleDeleted val=\"1\"/>")
        } else {
            writeTitle([spec.title, spec.subtitle].filter { !$0.isEmpty }.count == 2 ? [spec.title, spec.subtitle]
                : spec.subtitle.isEmpty ? [spec.title] : ["", spec.subtitle], sizes: [1400, 1100], into: &xml)
            xml.raw("<c:autoTitleDeleted val=\"0\"/>")
        }
        xml.raw("<c:plotArea><c:layout/>")
        let groups = self.groups(for: spec, seriesCount: layout.series.count)
        for group in groups {
            writeGroup(group, spec: spec, layout: layout, context: context, into: &xml)
        }
        writeAxes(spec: spec, groups: groups, into: &xml)
        xml.raw("</c:plotArea>")
        writeLegend(spec.legend, into: &xml)
        xml.raw("<c:plotVisOnly val=\"1\"/><c:dispBlanksAs val=\"gap\"/>")
        xml.raw("</c:chart>")
        let background = spec.backgroundColor ?? .white
        xml.raw("<c:spPr><a:solidFill><a:srgbClr val=\"\(background.hex)\"/></a:solidFill><a:ln><a:noFill/></a:ln></c:spPr>")
        if let font = spec.fontFamily, !font.isEmpty {
            xml.raw("<c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr><a:latin")
            xml.attribute("typeface", font)
            xml.raw("/></a:defRPr></a:pPr><a:endParaRPr lang=\"en-US\"/></a:p></c:txPr>")
        }
        xml.raw("</c:chartSpace>")
        return xml.data
    }

    // MARK: - Groups

    struct Group {
        var type: GroupType
        var secondary: Bool
        /// Indexes into the layout's series.
        var series: [Int]
    }

    /// Series grouped by how they're drawn: one group for most charts, one per series type for combo
    /// charts, and separate groups for series on the right axis.
    static func groups(for spec: ChartSpec, seriesCount: Int) -> [Group] {
        func type(ofSeries index: Int) -> GroupType {
            switch spec.kind {
            case .column, .stackedColumn, .percentColumn, .bar, .stackedBar, .percentBar: return .bar
            case .line, .smoothLine: return .line
            case .area, .stackedArea, .percentArea: return .area
            case .pie: return .pie
            case .donut: return .doughnut
            case .scatter: return .scatter
            case .combo:
                switch spec.style(ofSeries: index).type ?? (index == 0 ? .column : .line) {
                case .column: return .bar
                case .line: return .line
                case .area: return .area
                }
            }
        }
        let isRound = spec.kind == .pie || spec.kind == .donut
        var groups: [Group] = []
        for index in 0..<seriesCount {
            // Pie charts show the first series only, as Excel's do with the others kept; a doughnut would
            // draw the others as rings, so they're left out.
            if spec.kind == .donut && index > 0 { break }
            let secondary = !isRound && spec.style(ofSeries: index).usesRightAxis
            let kind = type(ofSeries: index)
            if let existing = groups.firstIndex(where: { $0.type == kind && $0.secondary == secondary }) {
                groups[existing].series.append(index)
            } else {
                groups.append(Group(type: kind, secondary: secondary, series: [index]))
            }
        }
        if groups.isEmpty { groups.append(Group(type: type(ofSeries: 0), secondary: false, series: [])) }
        // Bars behind areas behind lines, primary axes before secondary ones.
        func rank(_ type: GroupType) -> Int {
            switch type {
            case .bar: 0
            case .area: 1
            case .line: 2
            case .scatter: 3
            case .pie, .doughnut: 4
            }
        }
        // A secondary group needs a primary one for its axes to cross; the first group is promoted.
        if !groups.contains(where: { !$0.secondary }) { groups[0].secondary = false }
        return groups.sorted { (rank($0.type), $0.secondary ? 1 : 0) < (rank($1.type), $1.secondary ? 1 : 0) }
    }

    private static func writeGroup(_ group: Group, spec: ChartSpec, layout: XLSXChartLayout.Layout, context: Context,
                                   into xml: inout XMLWriter) {
        let axes = group.secondary ? secondaryAxes : primaryAxes
        let isBarDirection = [.bar, .stackedBar, .percentBar].contains(spec.kind)
        let grouping: String = switch spec.kind {
        case .stackedColumn, .stackedBar, .stackedArea: "stacked"
        case .percentColumn, .percentBar, .percentArea: "percentStacked"
        default: group.type == .bar ? "clustered" : "standard"
        }
        switch group.type {
        case .bar:
            xml.raw("<c:barChart><c:barDir val=\"\(isBarDirection ? "bar" : "col")\"/><c:grouping val=\"\(grouping)\"/><c:varyColors val=\"0\"/>")
        case .line:
            xml.raw("<c:lineChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>")
        case .area:
            xml.raw("<c:areaChart><c:grouping val=\"\(grouping)\"/><c:varyColors val=\"0\"/>")
        case .pie:
            xml.raw("<c:pieChart><c:varyColors val=\"1\"/>")
        case .doughnut:
            xml.raw("<c:doughnutChart><c:varyColors val=\"1\"/>")
        case .scatter:
            xml.raw("<c:scatterChart><c:scatterStyle val=\"lineMarker\"/><c:varyColors val=\"0\"/>")
        }
        for index in group.series {
            writeSeries(index, type: group.type, spec: spec, layout: layout, context: context, into: &xml)
        }
        switch group.type {
        case .pie, .doughnut:
            writePieLabels(spec.pieSliceLabel, into: &xml)
            xml.raw("<c:firstSliceAng val=\"0\"/>")
            if group.type == .doughnut {
                let hole = Int((spec.pieHole * 100).rounded())
                xml.raw("<c:holeSize val=\"\(min(max(hole, 10), 90))\"/>")
            }
            xml.raw(group.type == .pie ? "</c:pieChart>" : "</c:doughnutChart>")
            return
        default:
            break
        }
        if spec.showsDataLabels { writeDataLabels(shown: true, into: &xml) }
        switch group.type {
        case .bar:
            xml.raw("<c:gapWidth val=\"150\"/>")
            if grouping != "clustered" { xml.raw("<c:overlap val=\"100\"/>") }
        case .line:
            xml.raw("<c:marker val=\"1\"/>")
        default:
            break
        }
        xml.raw("<c:axId val=\"\(axes.category)\"/><c:axId val=\"\(axes.value)\"/>")
        switch group.type {
        case .bar: xml.raw("</c:barChart>")
        case .line: xml.raw("</c:lineChart>")
        case .area: xml.raw("</c:areaChart>")
        case .scatter: xml.raw("</c:scatterChart>")
        case .pie, .doughnut: break
        }
    }

    // MARK: - Series

    private static func writeSeries(_ index: Int, type: GroupType, spec: ChartSpec, layout: XLSXChartLayout.Layout, context: Context,
                                    into xml: inout XMLWriter) {
        let series = layout.series[index]
        let style = spec.style(ofSeries: index)
        let color = style.color ?? paletteColor(index)
        xml.raw("<c:ser><c:idx val=\"\(index)\"/><c:order val=\"\(index)\"/>")
        if let name = series.name, !name.isEmpty {
            xml.raw("<c:tx>")
            writeStringReference(name, context: context, into: &xml)
            xml.raw("</c:tx>")
        }
        let lineWidth = XLSXEMU.from(pixels: style.lineWidth ?? 2)
        switch type {
        case .bar, .area:
            xml.raw("<c:spPr><a:solidFill><a:srgbClr val=\"\(color.hex)\"/></a:solidFill>")
            if let width = style.lineWidth, type == .area {
                xml.raw("<a:ln w=\"\(XLSXEMU.from(pixels: width))\"><a:solidFill><a:srgbClr val=\"\(color.hex)\"/></a:solidFill></a:ln>")
            }
            xml.raw("</c:spPr>")
            if type == .bar { xml.raw("<c:invertIfNegative val=\"0\"/>") }
        case .line:
            xml.raw("<c:spPr><a:ln w=\"\(lineWidth)\" cap=\"rnd\"><a:solidFill><a:srgbClr val=\"\(color.hex)\"/></a:solidFill>"
                + "<a:round/></a:ln></c:spPr>")
            writeMarker(size: style.pointSize, hiddenByDefault: true, color: color, into: &xml)
        case .scatter:
            xml.raw("<c:spPr><a:ln w=\"\(lineWidth)\" cap=\"rnd\"><a:noFill/><a:round/></a:ln></c:spPr>")
            writeMarker(size: style.pointSize, hiddenByDefault: false, color: color, into: &xml)
        case .pie, .doughnut:
            // Each slice its own color, as PuggleSheets draws pies.
            let count = series.values.cells.count
            for slice in 0..<min(count, 256) {
                xml.raw("<c:dPt><c:idx val=\"\(slice)\"/><c:bubble3D val=\"0\"/><c:spPr><a:solidFill>"
                    + "<a:srgbClr val=\"\(paletteColor(slice).hex)\"/></a:solidFill><a:ln w=\"12700\"><a:solidFill>"
                    + "<a:srgbClr val=\"FFFFFF\"/></a:solidFill></a:ln></c:spPr></c:dPt>")
            }
        }
        if let shown = style.showsDataLabels, type != .pie, type != .doughnut { writeDataLabels(shown: shown, into: &xml) }
        if let labels = layout.labels, !labels.isEmpty {
            xml.raw(type == .scatter ? "<c:xVal>" : "<c:cat>")
            writeLabels(labels, context: context, into: &xml)
            xml.raw(type == .scatter ? "</c:xVal>" : "</c:cat>")
        }
        xml.raw(type == .scatter ? "<c:yVal>" : "<c:val>")
        writeNumberReference(series.values, context: context, into: &xml)
        xml.raw(type == .scatter ? "</c:yVal>" : "</c:val>")
        if type == .line || type == .scatter {
            xml.raw("<c:smooth val=\"\(spec.kind == .smoothLine ? 1 : 0)\"/>")
        }
        xml.raw("</c:ser>")
    }

    /// Points: none, or circles of `size` pixels (Excel measures in points).
    private static func writeMarker(size: Double?, hiddenByDefault: Bool, color: RGBColor, into xml: inout XMLWriter) {
        guard let size else {
            if hiddenByDefault {
                xml.raw("<c:marker><c:symbol val=\"none\"/></c:marker>")
            } else {
                xml.raw("<c:marker><c:symbol val=\"circle\"/>")
                writeMarkerFill(color, into: &xml)
                xml.raw("</c:marker>")
            }
            return
        }
        guard size > 0 else {
            xml.raw("<c:marker><c:symbol val=\"none\"/></c:marker>")
            return
        }
        let points = min(max(Int((size * 0.75).rounded()), 2), 72)
        xml.raw("<c:marker><c:symbol val=\"circle\"/><c:size val=\"\(points)\"/>")
        writeMarkerFill(color, into: &xml)
        xml.raw("</c:marker>")
    }

    private static func writeMarkerFill(_ color: RGBColor, into xml: inout XMLWriter) {
        xml.raw("<c:spPr><a:solidFill><a:srgbClr val=\"\(color.hex)\"/></a:solidFill><a:ln w=\"9525\"><a:solidFill>"
            + "<a:srgbClr val=\"\(color.hex)\"/></a:solidFill></a:ln></c:spPr>")
    }

    private static func writeDataLabels(shown: Bool, into xml: inout XMLWriter) {
        guard shown else {
            xml.raw("<c:dLbls><c:delete val=\"1\"/></c:dLbls>")
            return
        }
        xml.raw("<c:dLbls><c:showLegendKey val=\"0\"/><c:showVal val=\"1\"/><c:showCatName val=\"0\"/><c:showSerName val=\"0\"/>"
            + "<c:showPercent val=\"0\"/><c:showBubbleSize val=\"0\"/></c:dLbls>")
    }

    private static func writePieLabels(_ label: ChartSpec.PieLabel, into xml: inout XMLWriter) {
        guard label != .none else { return }
        let value = label == .value ? 1 : 0, category = label == .label ? 1 : 0, percent = label == .percentage ? 1 : 0
        xml.raw("<c:dLbls><c:showLegendKey val=\"0\"/><c:showVal val=\"\(value)\"/><c:showCatName val=\"\(category)\"/>"
            + "<c:showSerName val=\"0\"/><c:showPercent val=\"\(percent)\"/><c:showBubbleSize val=\"0\"/>"
            + "<c:showLeaderLines val=\"1\"/></c:dLbls>")
    }

    // MARK: - References and caches

    private static func cellValue(_ sheet: Int, _ address: CellAddress, context: Context) -> (value: CellValue, pattern: String?) {
        let sheet = context.workbook.sheets[sheet]
        return (sheet.value(at: address), sheet.cells[address]?.format.numberFormat)
    }

    private static func writeStringReference(_ line: XLSXChartLayout.Line, context: Context, into xml: inout XMLWriter) {
        let cells = line.cells
        xml.raw("<c:strRef><c:f>")
        xml.text(XLSXChartLayout.reference(line, sheetNames: context.sheetNames))
        xml.raw("</c:f><c:strCache><c:ptCount val=\"\(cells.count)\"/>")
        for (index, address) in cells.enumerated() {
            let (value, pattern) = cellValue(line.sheet, address, context: context)
            guard value != .empty else { continue }
            xml.raw("<c:pt idx=\"\(index)\"><c:v>")
            xml.text(CellDisplay.text(for: value, pattern: pattern).text)
            xml.raw("</c:v></c:pt>")
        }
        xml.raw("</c:strCache></c:strRef>")
    }

    private static func writeNumberReference(_ line: XLSXChartLayout.Line, context: Context, into xml: inout XMLWriter) {
        let cells = line.cells
        xml.raw("<c:numRef><c:f>")
        xml.text(line.isEmpty ? "" : XLSXChartLayout.reference(line, sheetNames: context.sheetNames))
        xml.raw("</c:f><c:numCache>")
        var points = XMLWriter(fragmentCapacity: cells.count * 32)
        var format: String?
        for (index, address) in cells.enumerated() {
            let (value, pattern) = cellValue(line.sheet, address, context: context)
            let number: Double? = switch value {
            case .number(let number): number.isFinite ? number : nil
            case .boolean(let flag): flag ? 1 : 0
            default: nil
            }
            guard let number else { continue }
            if format == nil { format = pattern }
            points.raw("<c:pt idx=\"\(index)\"><c:v>\(XLSXValue.string(number))</c:v></c:pt>")
        }
        xml.raw("<c:formatCode>")
        xml.text(format ?? "General")
        xml.raw("</c:formatCode><c:ptCount val=\"\(cells.count)\"/>")
        xml.append(points)
        xml.raw("</c:numCache></c:numRef>")
    }

    /// Labels: numbers (and dates) as a number reference, so Excel can use a date or value axis;
    /// anything else as text.
    private static func writeLabels(_ line: XLSXChartLayout.Line, context: Context, into xml: inout XMLWriter) {
        let numeric = line.cells.allSatisfy { address in
            switch cellValue(line.sheet, address, context: context).value {
            case .number, .empty: true
            default: false
            }
        } && line.cells.contains { cellValue(line.sheet, $0, context: context).value != .empty }
        if numeric {
            writeNumberReference(line, context: context, into: &xml)
        } else {
            writeStringReference(line, context: context, into: &xml)
        }
    }

    // MARK: - Titles, axes, legend

    /// A rich-text title of one or more lines.
    static func writeTitle(_ lines: [String], sizes: [Int] = [], rotated: Bool = false, into xml: inout XMLWriter) {
        xml.raw("<c:title><c:tx><c:rich>")
        xml.raw(rotated ? "<a:bodyPr rot=\"-5400000\" vert=\"horz\"/>" : "<a:bodyPr/>")
        xml.raw("<a:lstStyle/>")
        for (index, line) in lines.enumerated() {
            let size = index < sizes.count ? " sz=\"\(sizes[index])\"" : ""
            xml.raw("<a:p><a:pPr><a:defRPr\(size) b=\"0\"/></a:pPr>")
            if line.isEmpty {
                xml.raw("<a:endParaRPr lang=\"en-US\"\(size) b=\"0\"/>")
            } else {
                xml.raw("<a:r><a:rPr lang=\"en-US\"\(size) b=\"0\"/><a:t>")
                xml.text(line)
                xml.raw("</a:t></a:r>")
            }
            xml.raw("</a:p>")
        }
        xml.raw("</c:rich></c:tx><c:overlay val=\"0\"/></c:title>")
    }

    private static func writeAxes(spec: ChartSpec, groups: [Group], into xml: inout XMLWriter) {
        guard let primary = groups.first(where: { !$0.secondary }), primary.type != .pie, primary.type != .doughnut else { return }
        let isBarDirection = [.bar, .stackedBar, .percentBar].contains(spec.kind)
        let isPercent = [.percentColumn, .percentBar, .percentArea].contains(spec.kind)
        let categoryTitle = isBarDirection ? spec.verticalAxisTitle : spec.horizontalAxisTitle
        let valueTitle = isBarDirection ? spec.horizontalAxisTitle : spec.verticalAxisTitle
        let categoryPosition = isBarDirection ? "l" : "b", valuePosition = isBarDirection ? "b" : "l"
        if primary.type == .scatter {
            writeValueAxis(id: primaryAxes.category, cross: primaryAxes.value, position: "b", title: spec.horizontalAxisTitle,
                           rotated: false, spec: nil, gridlines: false, percent: false, between: "midCat", into: &xml)
        } else {
            writeCategoryAxis(id: primaryAxes.category, cross: primaryAxes.value, position: categoryPosition, title: categoryTitle,
                              rotated: isBarDirection, deleted: false, into: &xml)
        }
        writeValueAxis(id: primaryAxes.value, cross: primaryAxes.category, position: valuePosition, title: valueTitle,
                       rotated: !isBarDirection, spec: spec, gridlines: spec.showsGridlines, percent: isPercent,
                       between: primary.type == .scatter ? "midCat" : "between", into: &xml)
        guard let secondary = groups.first(where: { $0.secondary }) else { return }
        if secondary.type == .scatter {
            writeValueAxis(id: secondaryAxes.category, cross: secondaryAxes.value, position: "b", title: "", rotated: false, spec: nil,
                           gridlines: false, percent: false, between: "midCat", deleted: true, into: &xml)
        } else {
            writeCategoryAxis(id: secondaryAxes.category, cross: secondaryAxes.value, position: categoryPosition, title: "",
                              rotated: false, deleted: true, into: &xml)
        }
        writeValueAxis(id: secondaryAxes.value, cross: secondaryAxes.category, position: isBarDirection ? "t" : "r", title: "",
                       rotated: false, spec: nil, gridlines: false, percent: isPercent,
                       between: secondary.type == .scatter ? "midCat" : "between", crossesAtMaximum: true, into: &xml)
    }

    private static func writeCategoryAxis(id: Int, cross: Int, position: String, title: String, rotated: Bool, deleted: Bool,
                                          into xml: inout XMLWriter) {
        xml.raw("<c:catAx><c:axId val=\"\(id)\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling>")
        xml.raw("<c:delete val=\"\(deleted ? 1 : 0)\"/><c:axPos val=\"\(position)\"/>")
        if !title.isEmpty { writeTitle([title], rotated: rotated, into: &xml) }
        xml.raw("<c:numFmt formatCode=\"General\" sourceLinked=\"1\"/><c:majorTickMark val=\"out\"/><c:minorTickMark val=\"none\"/>")
        xml.raw("<c:tickLblPos val=\"nextTo\"/><c:crossAx val=\"\(cross)\"/><c:crosses val=\"autoZero\"/>")
        xml.raw("<c:auto val=\"1\"/><c:lblAlgn val=\"ctr\"/><c:lblOffset val=\"100\"/><c:noMultiLvlLbl val=\"0\"/></c:catAx>")
    }

    /// `spec` carries the range, scale and gridlines of the main value axis (nil for the others).
    private static func writeValueAxis(id: Int, cross: Int, position: String, title: String, rotated: Bool, spec: ChartSpec?,
                                       gridlines: Bool, percent: Bool, between: String, deleted: Bool = false,
                                       crossesAtMaximum: Bool = false, into xml: inout XMLWriter) {
        xml.raw("<c:valAx><c:axId val=\"\(id)\"/><c:scaling>")
        if spec?.logScale == true { xml.raw("<c:logBase val=\"10\"/>") }
        xml.raw("<c:orientation val=\"minMax\"/>")
        if let maximum = spec?.verticalMaximum, maximum.isFinite { xml.raw("<c:max val=\"\(XLSXValue.string(maximum))\"/>") }
        if let minimum = spec?.verticalMinimum, minimum.isFinite { xml.raw("<c:min val=\"\(XLSXValue.string(minimum))\"/>") }
        xml.raw("</c:scaling><c:delete val=\"\(deleted ? 1 : 0)\"/><c:axPos val=\"\(position)\"/>")
        if gridlines { xml.raw("<c:majorGridlines/>") }
        if !title.isEmpty { writeTitle([title], rotated: rotated, into: &xml) }
        xml.raw(percent ? "<c:numFmt formatCode=\"0%\" sourceLinked=\"0\"/>" : "<c:numFmt formatCode=\"General\" sourceLinked=\"1\"/>")
        xml.raw("<c:majorTickMark val=\"out\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"nextTo\"/>")
        xml.raw("<c:crossAx val=\"\(cross)\"/><c:crosses val=\"\(crossesAtMaximum ? "max" : "autoZero")\"/>")
        xml.raw("<c:crossBetween val=\"\(between)\"/></c:valAx>")
    }

    private static func writeLegend(_ position: ChartSpec.LegendPosition, into xml: inout XMLWriter) {
        let code: String
        var overlay = false
        switch position {
        case .none: return
        case .auto, .right: code = "r"
        case .top: code = "t"
        case .bottom: code = "b"
        case .left: code = "l"
        case .inside:
            code = "r"
            overlay = true
        }
        xml.raw("<c:legend><c:legendPos val=\"\(code)\"/><c:overlay val=\"\(overlay ? 1 : 0)\"/></c:legend>")
    }
}
