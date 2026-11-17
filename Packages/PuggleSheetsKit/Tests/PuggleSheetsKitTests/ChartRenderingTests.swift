import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PuggleSheetsKit

/// Drawing charts: PNG, PDF and SVG output, the flipped on-screen context, and speed.
struct ChartRenderingTests {
    static let size = CGSize(width: 600, height: 371)

    /// RGBA pixels of a PNG, top row first.
    static func pixels(_ png: Data) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (width, height, bytes) : nil
    }

    /// How many pixels are close to `color`.
    static func count(_ color: RGBColor, in pixels: (width: Int, height: Int, bytes: [UInt8]), tolerance: Int = 12) -> Int {
        var count = 0
        var index = 0
        while index < pixels.bytes.count {
            if abs(Int(pixels.bytes[index]) - Int(color.red)) <= tolerance, abs(Int(pixels.bytes[index + 1]) - Int(color.green)) <= tolerance,
               abs(Int(pixels.bytes[index + 2]) - Int(color.blue)) <= tolerance { count += 1 }
            index += 4
        }
        return count
    }

    @Test func pngHasTheRightSizeAndShowsTheChart() throws {
        let png = try #require(ChartRenderer.pngData(ChartSpec(kind: .column, ranges: [], title: "Sales"), table: ChartFixtures.sales, size: Self.size))
        let header = try #require(ImageData(data: png))
        #expect(header.format == .png && header.pixelWidth == 1200 && header.pixelHeight == 742)
        let image = try #require(Self.pixels(png))
        let total = image.width * image.height
        let white = Self.count(.white, in: image, tolerance: 2)
        #expect(white < total * 95 / 100 && white > total / 2)
        // The first series in the palette's blue, the second in its red.
        #expect(Self.count(ChartBuilder.palette[0], in: image) > 5000)
        #expect(Self.count(ChartBuilder.palette[1], in: image) > 3000)

        let oneX = try #require(ChartRenderer.pngData(ChartSpec(ranges: []), table: ChartFixtures.sales, size: CGSize(width: 300, height: 200), scale: 1))
        #expect(ImageData(data: oneX).map { ($0.pixelWidth, $0.pixelHeight) } ?? (0, 0) == (300, 200))
        #expect(ChartRenderer.pngData(ChartSpec(ranges: []), table: ChartFixtures.sales, size: .zero) == nil)
    }

    @Test func pdfAndSVG() throws {
        let spec = ChartSpec(kind: .line, ranges: [], title: "Sales & <Costs>", subtitle: "2026")
        let pdf = try #require(ChartRenderer.pdfData(spec, table: ChartFixtures.sales, size: Self.size))
        #expect(pdf.starts(with: Array("%PDF".utf8)))
        #expect(pdf.count > 1000)

        let svg = ChartRenderer.svg(spec, table: ChartFixtures.sales, size: Self.size)
        #expect(svg.contains("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"600\" height=\"371\""))
        #expect(svg.hasSuffix("</svg>\n"))
        #expect(svg.contains("Sales &amp; &lt;Costs&gt;"))
        #expect(svg.contains("font-family=\"Roboto, Arial, Helvetica, sans-serif\""))
        #expect(svg.contains("stroke=\"#4285F4\""))
        #expect(svg.contains(">Jan</text>") && svg.contains(">Profit</text>"))
        // A chosen font comes first; the background fills the canvas.
        let styled = ChartRenderer.svg(ChartSpec(ranges: [], backgroundColor: RGBColor(hex: "FFF8E1"), fontFamily: "Times New Roman"),
                                       table: ChartFixtures.sales, size: Self.size)
        #expect(styled.contains("font-family=\"'Times New Roman', Roboto, Arial, Helvetica, sans-serif\""))
        #expect(styled.contains("fill=\"#FFF8E1\""))
    }

    @Test func everyKindDraws() throws {
        let table = ChartFixtures.wave(40)
        for kind in ChartSpec.Kind.allCases {
            let spec = ChartSpec(kind: kind, ranges: [], title: kind.rawValue, showsDataLabels: true)
            let svg = ChartRenderer.svg(spec, table: table, size: Self.size)
            #expect(svg.contains("<path"), "\(kind)")
            #expect(!svg.contains("No data"), "\(kind)")
            let png = try #require(ChartRenderer.pngData(spec, table: table, size: Self.size, scale: 1))
            let image = try #require(Self.pixels(png))
            #expect(Self.count(ChartBuilder.palette[0], in: image) > 300, "\(kind)")
        }
    }

    @Test func emptyChartsSayNoData() {
        let unresolved = ChartBuilder.table(for: ChartSpec(ranges: ["#REF!"]), sheetIndex: 0, workbook: Workbook())
        for (kind, table) in [(ChartSpec.Kind.column, ChartTable()), (.pie, unresolved),
                              (.line, ChartTable(labels: ["a"], series: [ChartTable.Series(name: "x", values: [nil])])),
                              (.donut, ChartTable(labels: ["a", "b"], series: [ChartTable.Series(name: "x", values: [0, -3])]))] {
            let svg = ChartRenderer.svg(ChartSpec(kind: kind, ranges: [], title: "Empty"), table: table, size: Self.size)
            #expect(svg.contains(">No data</text>") && svg.contains(">Empty</text>"), "\(kind)")
            #expect(svg.contains("fill=\"#757575\""), "\(kind)")
        }
    }

    @Test func awkwardDataDraws() {
        let tables: [ChartTable] = [
            ChartTable(labels: ["only"], series: [ChartTable.Series(name: "One", values: [42])]),
            ChartTable(labels: ["a", "b", "c"], series: [ChartTable.Series(name: "Zero", values: [0, 0, 0])]),
            ChartTable(labels: ["a", "b", "c"], series: [ChartTable.Series(name: "Negative", values: [-5, -20, -1])]),
            ChartTable(labels: ["a", "b", "c"], series: [ChartTable.Series(name: "Huge", values: [1e300, -1e300, .infinity])]),
            ChartTable(labels: ["a", "b", "c", "d"], series: [ChartTable.Series(name: "Gaps", values: [1, nil, 3, nil])]),
            ChartFixtures.wave(3000, numeric: true),
        ]
        for table in tables {
            for kind in ChartSpec.Kind.allCases {
                for logScale in [false, true] {
                    let spec = ChartSpec(kind: kind, ranges: [], title: "t", logScale: logScale, showsDataLabels: true)
                    #expect(ChartRenderer.svg(spec, table: table, size: Self.size).hasSuffix("</svg>\n"))
                }
            }
        }
        // Tiny and odd sizes.
        for size in [CGSize(width: 1, height: 1), CGSize(width: 40, height: 30), CGSize(width: 2000, height: 90)] {
            #expect(ChartRenderer.svg(ChartSpec(ranges: [], title: "Small"), table: ChartFixtures.sales, size: size).contains("<svg"))
        }
    }

    @Test func optionsChangeTheChart() {
        let base = ChartSpec(kind: .combo, ranges: [], title: "Combo")
        let plain = ChartRenderer.svg(base, table: ChartFixtures.sales, size: Self.size)
        // Three series: the legend sits at the right by default.
        #expect(plain.contains(">Sales</text>"))
        var noLegend = base
        noLegend.legend = .none
        #expect(!ChartRenderer.svg(noLegend, table: ChartFixtures.sales, size: Self.size).contains(">Sales</text>"))
        var styled = base
        styled.series = [ChartSeriesStyle(color: RGBColor(hex: "123456"), type: .area),
                         ChartSeriesStyle(lineWidth: 6, pointSize: 9, showsDataLabels: true, usesRightAxis: true)]
        styled.showsGridlines = false
        styled.horizontalAxisTitle = "Month"
        styled.verticalAxisTitle = "Amount"
        let svg = ChartRenderer.svg(styled, table: ChartFixtures.sales, size: Self.size)
        #expect(svg.contains("fill=\"#123456\" fill-opacity=\"0.3\""))
        #expect(svg.contains("stroke-width=\"6\""))
        #expect(svg.contains("<circle") && svg.contains(">128</text>"))
        #expect(svg.contains(">Amount</text>") && svg.contains("rotate(-90"))
        #expect(!svg.contains("fill=\"#CCCCCC\""))
        // A pie labels slices with their share.
        let pie = ChartRenderer.svg(ChartSpec(kind: .pie, ranges: []), table: ChartFixtures.sales, size: Self.size)
        #expect(pie.contains(">10.8%</text>") && pie.contains(">Dec</text>"))
        // Single series: no legend; the title and axis name it.
        let single = ChartTable(labels: ["a", "b"], series: [ChartTable.Series(name: "Lonely", values: [1, 2])])
        #expect(!ChartRenderer.svg(ChartSpec(ranges: []), table: single, size: Self.size).contains(">Lonely</text>"))
    }

    @Test func drawsUprightInAFlippedContext() throws {
        // A title "T" over an empty chart: upright, the T's bar is its widest row and comes first.
        let context = ChartFixtures.flippedContext()
        ChartRenderer.draw(ChartSpec(ranges: [], title: "T"), table: ChartTable(), in: CGRect(origin: .zero, size: Self.size), context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var rows: [(row: Int, dark: Int)] = []
        for row in 0..<120 {
            var dark = 0
            for column in 0..<200 where bytes[(row * context.bytesPerRow) + column * 4] < 100 { dark += 1 }
            if dark > 0 { rows.append((row, dark)) }
        }
        let first = try #require(rows.first), last = try #require(rows.last)
        #expect(first.row >= 20 && last.row < 90)
        #expect(first.dark > last.dark * 3)

        // Drawing into part of a context leaves the rest alone.
        let offset = ChartFixtures.flippedContext()
        offset.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        offset.fill(CGRect(origin: .zero, size: Self.size))
        ChartRenderer.draw(ChartSpec(ranges: []), table: ChartFixtures.sales, in: CGRect(x: 300, y: 0, width: 300, height: 371), context: offset)
        let pixels = try #require(offset.data).assumingMemoryBound(to: UInt8.self)
        #expect(pixels[100 * offset.bytesPerRow + 100 * 4] == 255 && pixels[100 * offset.bytesPerRow + 100 * 4 + 1] == 0)
        #expect(pixels[100 * offset.bytesPerRow + 1190 * 4 + 1] == 255)
    }

    @Test func drawingIsSafeFromManyThreads() async {
        let total = await withTaskGroup(of: Int.self) { group in
            for task in 0..<8 {
                group.addTask {
                    var length = 0
                    for index in 0..<20 {
                        let kind = ChartSpec.Kind.allCases[(index + task) % ChartSpec.Kind.allCases.count]
                        let table = ChartFixtures.wave(30 + index + task)
                        length += ChartRenderer.svg(ChartSpec(kind: kind, ranges: [], title: "Task \(task)"), table: table, size: Self.size).count
                        let context = ChartFixtures.flippedContext(CGSize(width: 200, height: 120))
                        ChartRenderer.draw(ChartSpec(kind: kind, ranges: []), table: table, in: CGRect(x: 0, y: 0, width: 200, height: 120), context: context)
                    }
                    return length
                }
            }
            var sum = 0
            for await length in group { sum += length }
            return sum
        }
        #expect(total > 0)
    }

    // MARK: Speed

    /// The grid redraws charts while scrolling. Limits are generous (twice the targets: 2 ms for a
    /// typical chart, 15 ms for 10,000 points); debug builds get more. Each check takes the fastest
    /// of several runs, so tests running in parallel can't make it fail.
    #if DEBUG
    // Unoptimized builds run the drawing code many times slower; their numbers only catch disasters.
    static let allowance = 10.0
    #else
    static let allowance = 1.0
    #endif

    func fastestMilliseconds(_ runs: Int = 7, _ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        var best = Double.infinity
        for _ in 0..<runs {
            let elapsed = clock.measure(body)
            best = min(best, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        return best
    }

    @Test func drawingIsQuick() {
        let context = ChartFixtures.flippedContext()
        let rect = CGRect(origin: .zero, size: Self.size)
        // About 100 points: 50 rows of two series (a 50-slice pie).
        let typical = ChartFixtures.wave(50)
        for kind in ChartSpec.Kind.allCases {
            let spec = ChartSpec(kind: kind, ranges: [], title: "Typical")
            let milliseconds = fastestMilliseconds { ChartRenderer.draw(spec, table: typical, in: rect, context: context) }
            #expect(milliseconds < 4 * Self.allowance, "\(kind): \(milliseconds) ms")
        }
        var thousands = ChartFixtures.wave(10_000)
        thousands.series.removeLast()
        for kind in [ChartSpec.Kind.column, .line, .area, .scatter, .bar] {
            var table = thousands
            if kind == .scatter { table = ChartFixtures.wave(10_000, numeric: true); table.series.removeLast() }
            let spec = ChartSpec(kind: kind, ranges: [], title: "10,000 points")
            let milliseconds = fastestMilliseconds(4) { ChartRenderer.draw(spec, table: table, in: rect, context: context) }
            #expect(milliseconds < 30 * Self.allowance, "\(kind): \(milliseconds) ms")
        }
    }
}
