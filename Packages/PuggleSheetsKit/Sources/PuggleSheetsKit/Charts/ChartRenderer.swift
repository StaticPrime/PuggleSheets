import CoreGraphics
import Foundation
import ImageIO

/// Draws charts. Every output comes from the same layout, so the screen,
/// PNG, PDF and SVG versions of a chart look the same.
public enum ChartRenderer {
    /// Draws the chart into `rect` of a context whose y axis points down (like a flipped AppKit view).
    public static func draw(_ spec: ChartSpec, table: ChartTable, in rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite else { return }
        let scene = ChartComposer.scene(for: spec, table: table, size: rect.size)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        scene.render(in: context)
        context.restoreGState()
    }

    /// The chart as a PNG image of `size` points at `scale` pixels per point.
    public static func pngData(_ spec: ChartSpec, table: ChartTable, size: CGSize, scale: CGFloat = 2) -> Data? {
        guard scale > 0, scale.isFinite, size.width > 0, size.height > 0 else { return nil }
        let pixelWidth = Int((size.width * scale).rounded()), pixelHeight = Int((size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth <= 32768, pixelHeight <= 32768,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Points, with the y axis pointing down.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        draw(spec, table: table, in: CGRect(origin: .zero, size: size), context: context)
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        let properties = [kCGImagePropertyDPIWidth as String: 72 * Double(scale), kCGImagePropertyDPIHeight as String: 72 * Double(scale)] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The chart as a one-page PDF of `size` points.
    public static func pdfData(_ spec: ChartSpec, table: ChartTable, size: CGSize) -> Data? {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(spec, table: table, in: mediaBox, context: context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// The chart as an SVG document of `size` points.
    public static func svg(_ spec: ChartSpec, table: ChartTable, size: CGSize) -> String {
        let width = size.width.isFinite ? Swift.max(0, size.width) : 0
        let height = size.height.isFinite ? Swift.max(0, size.height) : 0
        return ChartComposer.scene(for: spec, table: table, size: CGSize(width: width, height: height)).svgDocument()
    }
}
