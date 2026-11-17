import CoreGraphics
import Foundation

/// The table as charts read it: every series as long as the labels, labels and names on one line,
/// only finite numbers.
struct ChartData {
    let count: Int
    let labels: [String]
    let labelValues: [Double?]
    let labelFormat: String?
    let labelHeading: String
    let series: [ChartTable.Series]

    init(_ table: ChartTable) {
        let count = table.rowCount
        self.count = count
        var labels = table.labels.count == count ? table.labels : Array(table.labels.prefix(count))
        if labels.contains(where: ChartData.hasLineBreak) { labels = labels.map(ChartData.oneLine) }
        if labels.count < count { labels += (labels.count..<count).map { String($0 + 1) } }
        self.labels = labels
        var labelValues = table.labelValues.count == count ? table.labelValues : Array(table.labelValues.prefix(count))
        if labelValues.contains(where: { $0.map { !$0.isFinite } ?? false }) { labelValues = labelValues.map { $0.flatMap { $0.isFinite ? $0 : nil } } }
        if labelValues.count < count {
            labelValues += (labelValues.count..<count).map { $0 >= table.labels.count ? Double($0 + 1) : nil }
        }
        self.labelValues = labelValues
        labelFormat = table.labelFormat
        labelHeading = ChartData.oneLine(table.labelHeading)
        series = table.series.map { series in
            var copy = series
            copy.name = ChartData.oneLine(series.name)
            if copy.values.count < count { copy.values += [Double?](repeating: nil, count: count - copy.values.count) }
            if copy.values.contains(where: { $0.map { !$0.isFinite } ?? false }) { copy.values = copy.values.map { $0.flatMap { $0.isFinite ? $0 : nil } } }
            return copy
        }
    }

    var isEmpty: Bool { count == 0 || series.allSatisfy { $0.values.allSatisfy { $0 == nil } } }

    static func hasLineBreak(_ text: String) -> Bool { text.utf8.contains { $0 == 10 || $0 == 13 } }

    static func oneLine(_ text: String) -> String {
        guard hasLineBreak(text) else { return text }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// A rectangle being divided up: the space left for the plot as titles, legends and labels take theirs.
struct ChartFrame {
    var left: Double
    var top: Double
    var right: Double
    var bottom: Double

    var width: Double { Swift.max(0, right - left) }
    var height: Double { Swift.max(0, bottom - top) }
    var midX: Double { (left + right) / 2 }
    var midY: Double { (top + bottom) / 2 }
}

/// The title and subtitle at the top left, measured before the rest is laid out.
struct ChartTitleBlock {
    var title = ""
    var subtitle = ""
    var titleBaseline = 0.0
    var subtitleBaseline = 0.0
    /// Where the content below may start.
    var bottom = 0.0
    var isEmpty: Bool { title.isEmpty && subtitle.isEmpty }
}

struct ChartLegendEntry {
    var text: String
    var color: ChartColor
}

enum ChartLegendPlacement {
    case none, top, bottom, left, right, inside
}

/// Legend entries placed in rows: one entry per row at the left or right, rows of entries above,
/// below or inside the plot.
struct ChartLegendLayout {
    struct Item {
        var text: String
        var color: ChartColor
        var x: Double
        var row: Int
        var marker: Bool
    }

    var placement: ChartLegendPlacement
    var items: [Item] = []
    var rowWidths: [Double] = []
    var width = 0.0
    var height = 0.0
    var rowPitch = 0.0
    /// Where the legend's box starts, when the frame decided it (left legends' x, top and bottom legends' y).
    var originX = 0.0
    var originY = 0.0
}

/// Turns a spec and its table into a scene: the layout and the marks, before any drawing.
struct ChartComposer {
    let spec: ChartSpec
    let data: ChartData
    let style: ChartStyle
    let width: Double
    let height: Double
    let engine = ChartTextEngine.shared
    var scene: ChartScene

    static func scene(for spec: ChartSpec, table: ChartTable, size: CGSize) -> ChartScene {
        var composer = ChartComposer(spec: spec, table: table, size: size)
        composer.compose()
        return composer.scene
    }

    init(spec: ChartSpec, table: ChartTable, size: CGSize) {
        self.spec = spec
        data = ChartData(table)
        style = ChartStyle(spec: spec, size: size)
        width = Double(size.width)
        height = Double(size.height)
        scene = ChartScene(size: size, background: style.background, svgFontFamily: style.svgFontFamily)
    }

    mutating func compose() {
        guard width >= 4, height >= 4 else { return }
        let titles = titleBlock()
        switch spec.kind {
        case .pie, .donut:
            composePie(titles)
        default:
            if data.isEmpty {
                emitEmpty(titles)
            } else {
                composeCartesian(titles)
            }
        }
    }

    // MARK: Titles

    func titleBlock() -> ChartTitleBlock {
        var block = ChartTitleBlock()
        block.title = ChartData.oneLine(spec.title.trimmingCharacters(in: .whitespacesAndNewlines))
        block.subtitle = ChartData.oneLine(spec.subtitle.trimmingCharacters(in: .whitespacesAndNewlines))
        var y = style.padding
        if !block.title.isEmpty {
            let metrics = engine.metrics(style.titleFont)
            block.titleBaseline = y + metrics.ascent
            y += metrics.height
        }
        if !block.subtitle.isEmpty {
            if !block.title.isEmpty { y += 3 * style.scale }
            let metrics = engine.metrics(style.subtitleFont)
            block.subtitleBaseline = y + metrics.ascent
            y += metrics.height
        }
        block.bottom = block.isEmpty ? style.padding : y + style.titleGap
        return block
    }

    /// Draws the titles starting at `x` (the plot's left edge), moved left when they'd run off the chart.
    mutating func emitTitles(_ block: ChartTitleBlock, x preferredX: Double) {
        guard !block.isEmpty else { return }
        let widest = Swift.max(engine.width(block.title, style.titleFont), engine.width(block.subtitle, style.subtitleFont))
        let x = Swift.max(style.padding, Swift.min(preferredX, width - style.padding - widest))
        let available = width - style.padding - x
        if !block.title.isEmpty {
            scene.text(ChartText(string: engine.truncated(block.title, style.titleFont, maxWidth: available), font: style.titleFont,
                                 color: style.titleColor, x: x, y: block.titleBaseline))
        }
        if !block.subtitle.isEmpty {
            scene.text(ChartText(string: engine.truncated(block.subtitle, style.subtitleFont, maxWidth: available), font: style.subtitleFont,
                                 color: style.subtitleColor, x: x, y: block.subtitleBaseline))
        }
    }

    // MARK: Empty charts

    /// An empty chart: the titles, and a short gray message in the middle.
    mutating func emitEmpty(_ titles: ChartTitleBlock) {
        emitTitles(titles, x: style.padding)
        let metrics = engine.metrics(style.messageFont)
        let middle = (titles.bottom + height - style.padding) / 2
        scene.text(ChartText(string: "No data", font: style.messageFont, color: style.messageColor,
                             x: width / 2, y: middle + metrics.middle, anchor: .middle))
    }

    // MARK: Legends

    /// Where the legend goes. Auto: at the right for pie charts and for charts with several series,
    /// none for a single series (the title and axis titles name it). Charts narrower than 360 pixels
    /// put it on top instead (below for pie charts), as the right side has no room.
    func legendPlacement(entryCount: Int, pie: Bool) -> ChartLegendPlacement {
        guard entryCount > 0 else { return .none }
        switch spec.legend {
        case .none: return .none
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .left
        case .right: return .right
        case .inside: return .inside
        case .auto:
            if !pie, entryCount < 2 { return .none }
            if width < 360 { return pie ? .bottom : .top }
            return .right
        }
    }

    /// Lays out the legend and takes its space from `frame`.
    mutating func reserveLegend(_ entries: [ChartLegendEntry], placement: ChartLegendPlacement, frame: inout ChartFrame) -> ChartLegendLayout? {
        guard !entries.isEmpty else { return nil }
        let gap = 16 * style.scale
        switch placement {
        case .none:
            return nil
        case .right, .left:
            let maxWidth = Swift.min(Swift.max(90, width * 0.3), frame.width * 0.45)
            var layout = verticalLegend(entries, maxWidth: maxWidth, maxHeight: frame.height)
            layout.placement = placement
            if placement == .right {
                frame.right -= layout.width + gap
                layout.originX = frame.right + gap
            } else {
                layout.originX = frame.left
                frame.left += layout.width + gap
            }
            return layout
        case .top:
            var layout = horizontalLegend(entries, maxWidth: frame.width, maxRows: 2)
            layout.placement = .top
            layout.originY = frame.top
            frame.top += layout.height + 12 * style.scale
            return layout
        case .bottom:
            var layout = horizontalLegend(entries, maxWidth: frame.width, maxRows: 2)
            layout.placement = .bottom
            frame.bottom -= layout.height
            layout.originY = frame.bottom
            frame.bottom -= 12 * style.scale
            return layout
        case .inside:
            var layout = horizontalLegend(entries, maxWidth: Swift.max(40, frame.width * 0.9 - 16), maxRows: 3)
            layout.placement = .inside
            return layout
        }
    }

    var markerSpace: Double { style.markerSize + 6 * style.scale }

    func verticalLegend(_ entries: [ChartLegendEntry], maxWidth: Double, maxHeight: Double) -> ChartLegendLayout {
        let font = style.legendFont
        let metrics = engine.metrics(font)
        let pitch = metrics.height + 8 * style.scale
        let fit = Swift.max(1, Int((maxHeight - metrics.height) / pitch) + 1)
        let overflow = entries.count > fit
        let shown = overflow ? Array(entries.prefix(Swift.max(0, fit - 1))) : entries
        var layout = ChartLegendLayout(placement: .right)
        layout.rowPitch = pitch
        var widest = 0.0
        for (row, entry) in shown.enumerated() {
            let text = engine.truncated(entry.text, font, maxWidth: Swift.max(0, maxWidth - markerSpace))
            widest = Swift.max(widest, engine.width(text, font))
            layout.items.append(.init(text: text, color: entry.color, x: 0, row: row, marker: true))
        }
        if overflow {
            layout.items.append(.init(text: "…", color: style.legendColor, x: markerSpace, row: shown.count, marker: false))
        }
        layout.width = markerSpace + widest
        layout.height = layout.items.isEmpty ? 0 : Double(layout.items.count - 1) * pitch + metrics.height
        layout.rowWidths = layout.items.map { _ in layout.width }
        return layout
    }

    func horizontalLegend(_ entries: [ChartLegendEntry], maxWidth: Double, maxRows: Int) -> ChartLegendLayout {
        let font = style.legendFont
        let metrics = engine.metrics(font)
        let pitch = metrics.height + 6 * style.scale
        let spacing = 16 * style.scale
        var layout = ChartLegendLayout(placement: .top)
        layout.rowPitch = pitch
        var x = 0.0, row = 0
        var rowWidths: [Double] = [0]
        for (index, entry) in entries.enumerated() {
            var text = entry.text
            var itemWidth = markerSpace + engine.width(text, font)
            if itemWidth > maxWidth {
                text = engine.truncated(text, font, maxWidth: Swift.max(0, maxWidth - markerSpace))
                itemWidth = markerSpace + engine.width(text, font)
            }
            if x > 0, x + itemWidth > maxWidth {
                if row + 1 >= maxRows {
                    // No more rows: end the last one with an ellipsis.
                    let ellipsisWidth = engine.width("…", font)
                    if x + ellipsisWidth > maxWidth, !layout.items.isEmpty, index > 0 {
                        layout.items.removeLast()
                        x = layout.items.last(where: { $0.row == row }).map { $0.x + markerSpace + engine.width($0.text, font) + spacing } ?? 0
                    }
                    layout.items.append(.init(text: "…", color: style.legendColor, x: x, row: row, marker: false))
                    rowWidths[row] = x + ellipsisWidth
                    break
                }
                row += 1
                x = 0
                rowWidths.append(0)
            }
            layout.items.append(.init(text: text, color: entry.color, x: x, row: row, marker: true))
            rowWidths[row] = x + itemWidth
            x += itemWidth + spacing
        }
        layout.rowWidths = rowWidths
        layout.width = rowWidths.max() ?? 0
        layout.height = Double(rowWidths.count - 1) * pitch + metrics.height
        return layout
    }

    /// Draws a legend with its box's top-left corner at (`x`, `y`); with `centerWidth`, each row is
    /// centered in that width instead.
    mutating func emitLegend(_ layout: ChartLegendLayout, x: Double, y: Double, centerWidth: Double? = nil) {
        let font = style.legendFont
        let metrics = engine.metrics(font)
        let radius = style.markerSize / 2
        for item in layout.items {
            var left = x + item.x
            if let centerWidth, item.row < layout.rowWidths.count {
                left += Swift.max(0, (centerWidth - layout.rowWidths[item.row]) / 2)
            }
            let baseline = y + Double(item.row) * layout.rowPitch + metrics.ascent
            if item.marker {
                let middle = baseline - metrics.middle
                scene.fill(CGPath(ellipseIn: CGRect(x: left, y: middle - radius, width: 2 * radius, height: 2 * radius), transform: nil), item.color)
                scene.text(ChartText(string: item.text, font: font, color: style.legendColor, x: left + markerSpace, y: baseline))
            } else {
                scene.text(ChartText(string: item.text, font: font, color: style.legendColor, x: left, y: baseline))
            }
        }
    }

    /// Draws a reserved legend next to `plot` (the plot area, or the pie's bounds).
    mutating func emitLegend(_ layout: ChartLegendLayout, plot: CGRect, centered: Bool) {
        switch layout.placement {
        case .none:
            break
        case .right, .left:
            emitLegend(layout, x: layout.originX, y: Double(plot.minY))
        case .top, .bottom:
            if centered {
                emitLegend(layout, x: Double(plot.minX), y: layout.originY, centerWidth: Double(plot.width))
            } else {
                let x = Swift.min(Double(plot.minX), Swift.max(style.padding, width - style.padding - layout.width))
                emitLegend(layout, x: x, y: layout.originY)
            }
        case .inside:
            emitLegend(layout, x: Double(plot.minX) + 8 * style.scale, y: Double(plot.minY) + 8 * style.scale)
        }
    }
}
