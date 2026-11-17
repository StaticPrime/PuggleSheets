import CoreGraphics
import Foundation

/// The chart look for one chart: Roboto (else Arial, else Helvetica), a 16 px title at
/// the top left, 12 px gray axis labels, light gray gridlines with a darker zero line, 12 px legend
/// text with round color markers, and its spacing. Sizes are for the default chart size
/// (600 × 371) and shrink for small charts; they don't grow for big ones.
struct ChartStyle {
    /// The installed family that measures and draws text.
    let family: String
    /// The CSS font stack SVG output names.
    let svgFontFamily: String
    /// 1 at the default chart size, down to 0.6 for thumbnails.
    let scale: Double
    let background: ChartColor
    let dark: Bool

    let titleFont: ChartFont
    let subtitleFont: ChartFont
    let labelFont: ChartFont
    let axisTitleFont: ChartFont
    let legendFont: ChartFont
    let dataLabelFont: ChartFont
    let sliceFont: ChartFont
    let messageFont: ChartFont

    let titleColor: ChartColor
    let subtitleColor: ChartColor
    let verticalLabelColor: ChartColor
    let horizontalLabelColor: ChartColor
    let axisTitleColor: ChartColor
    let legendColor: ChartColor
    let gridlineColor: ChartColor
    let baselineColor: ChartColor
    let dataLabelColor: ChartColor
    let messageColor: ChartColor
    let sliceTextColor: ChartColor

    /// Space between the chart's edge and its content.
    let padding: Double
    /// Space between axis labels and the plot.
    let labelGap: Double
    /// Space between the titles and what's below them.
    let titleGap: Double
    /// Diameter of the legend's color circles.
    let markerSize: Double

    /// The opacity of area fills.
    static let areaOpacity = 0.3
    /// The share of a category's slot its columns fill (a golden-ratio group width).
    static let groupWidth = 0.618

    init(spec: ChartSpec, size: CGSize) {
        let engine = ChartTextEngine.shared
        let family = engine.family(for: spec.fontFamily)
        self.family = family
        var stack: [String] = []
        if let requested = spec.fontFamily?.trimmingCharacters(in: .whitespaces), !requested.isEmpty { stack.append(requested) }
        for fallback in ChartTextEngine.fallbackFamilies where !stack.contains(where: { $0.caseInsensitiveCompare(fallback) == .orderedSame }) {
            stack.append(fallback)
        }
        svgFontFamily = (stack.map { $0.contains(" ") ? "'\($0)'" : $0 } + ["sans-serif"]).joined(separator: ", ")

        let width = Double(size.width), height = Double(size.height)
        let scale = Swift.min(1, Swift.max(0.6, Swift.min(width / 480, height / 300)))
        self.scale = scale
        let background = spec.backgroundColor.map { ChartColor($0) } ?? .white
        self.background = background
        let dark = background.luminance < 0.45
        self.dark = dark

        func font(_ size: Double, bold: Bool = false) -> ChartFont {
            ChartFont(family: family, size: (size * scale * 2).rounded() / 2, bold: bold)
        }
        titleFont = font(16)
        subtitleFont = font(12)
        labelFont = font(12)
        axisTitleFont = font(12)
        legendFont = font(12)
        dataLabelFont = font(11)
        sliceFont = font(12)
        messageFont = font(13)

        if dark {
            titleColor = ChartColor(hex: 0xFFFFFF)
            subtitleColor = ChartColor(hex: 0xBDBDBD)
            verticalLabelColor = ChartColor(hex: 0xD0D0D0)
            horizontalLabelColor = ChartColor(hex: 0xE0E0E0)
            axisTitleColor = ChartColor(hex: 0xE0E0E0)
            legendColor = ChartColor(hex: 0xE0E0E0)
            gridlineColor = ChartColor(hex: 0xFFFFFF, alpha: 0.25)
            baselineColor = ChartColor(hex: 0xFFFFFF, alpha: 0.7)
            dataLabelColor = ChartColor(hex: 0xE0E0E0)
            messageColor = ChartColor(hex: 0xBDBDBD)
        } else {
            titleColor = ChartColor(hex: 0x000000)
            subtitleColor = ChartColor(hex: 0x757575)
            verticalLabelColor = ChartColor(hex: 0x444444)
            horizontalLabelColor = ChartColor(hex: 0x222222)
            axisTitleColor = ChartColor(hex: 0x222222)
            legendColor = ChartColor(hex: 0x222222)
            gridlineColor = ChartColor(hex: 0xCCCCCC)
            baselineColor = ChartColor(hex: 0x333333)
            dataLabelColor = ChartColor(hex: 0x444444)
            messageColor = ChartColor(hex: 0x757575)
        }
        sliceTextColor = .white

        padding = (16 * scale).rounded()
        labelGap = (8 * scale).rounded()
        titleGap = (16 * scale).rounded()
        markerSize = 9 * scale
    }
}
