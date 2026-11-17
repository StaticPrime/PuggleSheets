import CoreGraphics
import Foundation
@testable import PuggleSheetsKit

/// Workbooks and tables for the chart tests.
enum ChartFixtures {
    /// A sheet holding `cells` ("A1": value), with number formats from `formats`.
    static func sheet(_ name: String = "Sheet1", _ cells: [String: CellValue], formats: [String: String] = [:]) -> Sheet {
        var sheet = Sheet(name: name)
        for (a1, value) in cells { sheet[CellAddress(a1: a1)!] = Cell(value: value) }
        for (a1, pattern) in formats {
            let address = CellAddress(a1: a1)!
            var cell = sheet[address]
            cell.format.numberFormat = pattern
            sheet[address] = cell
        }
        return sheet
    }

    static func book(_ cells: [String: CellValue], formats: [String: String] = [:]) -> Workbook {
        Workbook(sheets: [sheet("Sheet1", cells, formats: formats)])
    }

    /// Month | Sales | Costs | Profit for a year: a typical chart table.
    static var sales: ChartTable {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return ChartTable(labels: months, labelValues: months.map { _ in nil }, labelFormat: nil, labelHeading: "Month", series: [
            ChartTable.Series(name: "Sales", values: [120, 135, 160, 150, 180, 210, 230, 220, 190, 170, 160, 200]),
            ChartTable.Series(name: "Costs", values: [80, 90, 95, 100, 110, 120, 130, 128, 115, 105, 100, 120]),
            ChartTable.Series(name: "Profit", values: [40, 45, 65, 50, 70, 90, 100, 92, 75, 65, 60, 80]),
        ])
    }

    /// `count` rows of two wavy series, labeled "Item 1", "Item 2", … (or numbered when `numeric`).
    static func wave(_ count: Int, numeric: Bool = false) -> ChartTable {
        ChartTable(labels: (0..<count).map { numeric ? String($0 + 1) : "Item \($0 + 1)" },
                   labelValues: (0..<count).map { numeric ? Double($0 + 1) : nil }, labelFormat: nil, labelHeading: "Item",
                   series: (0..<2).map { series in
                       ChartTable.Series(name: "Series \(series + 1)", values: (0..<count).map { (index: Int) -> Double? in
                           let wave: Double = 50 * sin(Double(index + series * 7) / 9)
                           let jitter: Double = Double((index * 31) % 17)
                           return 100 + wave + jitter
                       })
                   })
    }

    /// A bitmap context of `size` points at 2 pixels per point, with the y axis pointing down like a
    /// flipped AppKit view.
    static func flippedContext(_ size: CGSize = CGSize(width: 600, height: 371)) -> CGContext {
        let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: size.height * 2)
        context.scaleBy(x: 2, y: -2)
        return context
    }
}
