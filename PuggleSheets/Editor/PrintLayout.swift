import AppKit
import PuggleSheetsKit

/// File ▸ Print's settings, with their choices and defaults.
struct PrintSettings: Equatable {
    enum Scope: String, CaseIterable, Identifiable {
        case currentSheet = "Current sheet", workbook = "Workbook", selection = "Selected cells"
        var id: Self { self }
    }

    enum Paper: String, CaseIterable, Identifiable {
        case letter = "Letter (8.5\" x 11\")", legal = "Legal (8.5\" x 14\")", tabloid = "Tabloid (11\" x 17\")"
        case a3 = "A3 (29.7 cm x 42 cm)", a4 = "A4 (21 cm x 29.7 cm)", a5 = "A5 (14.8 cm x 21 cm)"
        var id: Self { self }

        /// Portrait size in points.
        var size: CGSize {
            switch self {
            case .letter: CGSize(width: 612, height: 792)
            case .legal: CGSize(width: 612, height: 1008)
            case .tabloid: CGSize(width: 792, height: 1224)
            case .a3: CGSize(width: 842, height: 1191)
            case .a4: CGSize(width: 595, height: 842)
            case .a5: CGSize(width: 420, height: 595)
            }
        }
    }

    enum Scale: String, CaseIterable, Identifiable {
        case normal = "Normal (100%)", fitWidth = "Fit to width", fitHeight = "Fit to height", fitPage = "Fit to page", custom = "Custom number"
        var id: Self { self }
    }

    enum Margins: String, CaseIterable, Identifiable {
        case normal = "Normal", narrow = "Narrow", wide = "Wide"
        var id: Self { self }

        /// Top, left, bottom and right, in points.
        var insets: NSEdgeInsets {
            switch self {
            case .normal: NSEdgeInsets(top: 54, left: 50.4, bottom: 54, right: 50.4)
            case .narrow: NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
            case .wide: NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
            }
        }
    }

    enum Alignment: String, CaseIterable, Identifiable {
        case start = "Left", center = "Center", end = "Right"
        var id: Self { self }
    }

    enum VerticalAlignment: String, CaseIterable, Identifiable {
        case top = "Top", middle = "Middle", bottom = "Bottom"
        var id: Self { self }
    }

    var scope = Scope.currentSheet
    var paper = Paper.letter
    var landscape = false
    var scale = Scale.normal
    /// Percent, for the custom scale.
    var customScale = 100.0
    var margins = Margins.normal
    var gridlines = true
    var downThenOver = false
    var alignment = Alignment.start
    var verticalAlignment = VerticalAlignment.top
    var pageNumbers = false
    var workbookTitle = false
    var sheetName = false
    var currentDate = false
    var currentTime = false

    var paperSize: CGSize {
        let size = paper.size
        return landscape ? CGSize(width: size.height, height: size.width) : size
    }

    /// The area cells are printed in, in points from the page's top-left corner.
    var contentRect: CGRect {
        let size = paperSize
        let insets = margins.insets
        return CGRect(x: insets.left, y: insets.top, width: size.width - insets.left - insets.right,
                      height: size.height - insets.top - insets.bottom)
    }

    var hasHeadersOrFooters: Bool { pageNumbers || workbookTitle || sheetName || currentDate || currentTime }
}

/// One printed page: a block of a sheet's rows and columns, and the scale it prints at (points per sheet pixel).
struct PrintPage: Equatable {
    var sheetIndex: Int
    var rows: ClosedRange<Int>
    var columns: ClosedRange<Int>
    var scale: CGFloat
    /// The page's size in sheet pixels.
    var size: CGSize
}

enum PrintLayout {
    /// A sheet pixel is 1/96 inch: three quarters of a point.
    static let pointsPerPixel: CGFloat = 0.75

    /// The pages to print: each sheet's used area (or the selection), split into pages in the chosen order.
    static func pages(for settings: PrintSettings, workbook: Workbook, activeSheet: Int, selection: CellRange) -> [PrintPage] {
        var targets: [(Int, CellRange)] = []
        switch settings.scope {
        case .currentSheet:
            if let used = usedRange(workbook.sheets[activeSheet]) { targets = [(activeSheet, used)] }
        case .workbook:
            targets = workbook.sheets.indices.compactMap { index in usedRange(workbook.sheets[index]).map { (index, $0) } }
        case .selection:
            targets = [(activeSheet, selection)]
        }
        return targets.flatMap { pages(sheet: workbook.sheets[$0.0], index: $0.0, range: $0.1, settings: settings) }
    }

    /// From A1 to the last cell with something in it.
    static func usedRange(_ sheet: Sheet) -> CellRange? {
        guard let content = sheet.contentRange else { return nil }
        var end = content.end
        for merge in sheet.merges { end = CellAddress(row: max(end.row, merge.end.row), column: max(end.column, merge.end.column)) }
        return CellRange(CellAddress(row: 0, column: 0), end)
    }

    static func pages(sheet: Sheet, index: Int, range: CellRange, settings: PrintSettings) -> [PrintPage] {
        let widths = range.columns.map { sheet.hiddenColumns.contains($0) ? 0 : CGFloat(sheet.columnWidth($0)) }
        let heights = range.rows.map { sheet.isRowHidden($0) ? 0 : CGFloat(sheet.rowHeight($0)) }
        let totalWidth = widths.reduce(0, +), totalHeight = heights.reduce(0, +)
        guard totalWidth > 0, totalHeight > 0 else { return [] }
        let content = settings.contentRect
        var scale = pointsPerPixel
        switch settings.scale {
        case .normal: break
        case .custom: scale *= CGFloat(min(max(settings.customScale, 10), 400)) / 100
        case .fitWidth: scale = min(scale, content.width / totalWidth)
        case .fitHeight: scale = min(scale, content.height / totalHeight)
        case .fitPage: scale = min(scale, content.width / totalWidth, content.height / totalHeight)
        }
        let columnRuns = breaks(widths, limit: content.width / scale).map {
            (range.start.column + $0.lowerBound)...(range.start.column + $0.upperBound)
        }
        let rowRuns = breaks(heights, limit: content.height / scale).map {
            (range.start.row + $0.lowerBound)...(range.start.row + $0.upperBound)
        }
        func page(_ rows: ClosedRange<Int>, _ columns: ClosedRange<Int>) -> PrintPage {
            let width = columns.map { widths[$0 - range.start.column] }.reduce(0, +)
            let height = rows.map { heights[$0 - range.start.row] }.reduce(0, +)
            return PrintPage(sheetIndex: index, rows: rows, columns: columns, scale: scale, size: CGSize(width: width, height: height))
        }
        if settings.downThenOver {
            return columnRuns.flatMap { columns in rowRuns.map { page($0, columns) } }
        }
        return rowRuns.flatMap { rows in columnRuns.map { page(rows, $0) } }
    }

    /// Splits sizes into runs that fit in `limit` (a run always takes at least one item).
    static func breaks(_ sizes: [CGFloat], limit: CGFloat) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start = 0, used: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if index > start, used + size > limit + 0.01 {
                runs.append(start...(index - 1))
                start = index
                used = 0
            }
            used += size
        }
        if start < sizes.count { runs.append(start...(sizes.count - 1)) }
        return runs
    }
}
