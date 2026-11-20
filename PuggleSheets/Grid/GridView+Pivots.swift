import AppKit
import PuggleSheetsKit

/// How pivot tables, links and images in cells look in the grid.
extension GridView {
    /// The link color.
    static let linkColor = RGBColor(hex: "1155CC")!
    static let pivotShade = RGBColor(hex: "F3F3F3")!

    /// What a pivot table shows: the formula engine's latest result, or computed once per edit.
    func pivotOutput(for pivot: PivotTable) -> PivotOutput {
        if let output = controller.engine.pivotOutput(for: pivot.id) { return output }
        if let cached = pivotOutputCache[pivot.id], cached.generation == controller.editGeneration, cached.pivot == pivot {
            return cached.output
        }
        let output = PivotEngine.output(for: pivot, sheetIndex: drawnSheetIndex, workbook: controller.workbook)
        pivotOutputCache[pivot.id] = (controller.editGeneration, pivot, output)
        return output
    }

    /// The role and number format of a cell inside a pivot table's results.
    func pivotStyle(at address: CellAddress, in sheet: Sheet) -> (role: PivotOutput.Role, numberFormat: String?)? {
        for pivot in sheet.pivotTables {
            guard let range = sheet.spillRanges[pivot.anchor], range.contains(address) else { continue }
            if case .error? = sheet.spilledValues[pivot.anchor] { return nil }
            let output = pivotOutput(for: pivot)
            let row = address.row - pivot.anchor.row, column = address.column - pivot.anchor.column
            guard row >= 0, column >= 0, row < output.rowCount, column < output.columnCount else { return nil }
            return (output.roles[row][column], output.numberFormats[row][column])
        }
        return nil
    }

    /// The pivot table style: bold headings and totals with a light shade.
    func applyPivotStyle(_ style: (role: PivotOutput.Role, numberFormat: String?), to format: inout CellFormat) {
        if format.numberFormat == nil, let pattern = style.numberFormat { format.numberFormat = pattern }
        switch style.role {
        case .header, .grandTotal:
            format.bold = true
            if format.fillColor == nil { format.fillColor = Self.pivotShade }
        case .total:
            format.bold = true
        case .rowLabel, .value, .empty:
            break
        }
    }

    /// Whether a cell shows a link: its own, a HYPERLINK formula's, or text that is a web address.
    func showsLink(at address: CellAddress, stored: Cell?, value: CellValue, in sheet: Sheet) -> Bool {
        if let stored, stored.link != nil { return true }
        if let stored, stored.formula != nil { return sheet.formulaLinks[address] != nil }
        guard case .text(let text) = value, let first = text.utf8.first,
              [0x68, 0x48, 0x77, 0x57, 0x6D, 0x4D, 0x66, 0x46].contains(first) else { return false }
        return LinkTarget.detectedURL(in: text) != nil
    }

    /// An image in a cell: fitted inside it, keeping its shape.
    func drawCellImage(_ image: CellImage, in cellRect: CGRect) {
        let box = cellRect.insetBy(dx: 2 * zoom, dy: 2 * zoom)
        guard box.width > 2, box.height > 2, image.image.pixelWidth > 0, image.image.pixelHeight > 0,
              let picture = nsImage(for: image.image) else { return }
        let scale = min(box.width / CGFloat(image.image.pixelWidth), box.height / CGFloat(image.image.pixelHeight))
        let size = CGSize(width: CGFloat(image.image.pixelWidth) * scale, height: CGFloat(image.image.pixelHeight) * scale)
        let rect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    // MARK: The Edit button

    /// The pivot table the active cell is in, if any.
    var selectedPivotTable: PivotTable? {
        guard canChange, printSettings == nil, controller.selectedObjectID == nil else { return nil }
        return sheet.pivotTable(covering: controller.selection.active)
    }

    /// The "Edit" button, just below the pivot table's bottom-left corner.
    func pivotEditButtonRect(for pivot: PivotTable) -> CGRect {
        let range = sheet.spillRanges[pivot.anchor] ?? CellRange(pivot.anchor)
        let rect = rect(for: range)
        var button = CGRect(x: rect.minX, y: rect.maxY + 6, width: 64, height: 26)
        if button.maxY > gridBounds.maxY - 4 { button.origin.y = max(headerHeight + 4, rect.minY - 32) }
        return button
    }

    func drawPivotEditButton() {
        guard let pivot = selectedPivotTable else { return }
        let button = pivotEditButtonRect(for: pivot)
        guard button.intersects(gridBounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: button, xRadius: 13, yRadius: 13).fill()
        NSGraphicsContext.restoreGraphicsState()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                         .foregroundColor: GridColors.rgb(0x0B57D0)]
        if let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) {
            let tinted = NSImage(size: pencil.size, flipped: false) { rect in
                pencil.draw(in: rect)
                GridColors.rgb(0x0B57D0).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: CGRect(x: button.minX + 11, y: button.midY - pencil.size.height / 2, width: pencil.size.width, height: pencil.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        ("Edit" as NSString).draw(at: CGPoint(x: button.minX + 29, y: button.midY - 8), withAttributes: attributes)
    }
}
