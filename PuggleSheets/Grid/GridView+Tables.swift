import AppKit
import PuggleSheetsKit

/// Tables in the grid: a colored header row, banded rows, an outline, filter buttons on the headers and
/// the table's name in a chip above it while a cell of it is selected.
extension GridView {
    /// A light tint of a table's color for its banded rows.
    static func tint(_ color: RGBColor, amount: Double = 0.12) -> RGBColor {
        func mix(_ channel: UInt8) -> UInt8 { UInt8(255 - (255 - Double(channel)) * amount) }
        return RGBColor(red: mix(color.red), green: mix(color.green), blue: mix(color.blue))
    }

    /// Header cells are bold and white on the table's color; every other data row is tinted.
    func applyTableStyle(at address: CellAddress, in sheet: Sheet, to format: inout CellFormat) {
        guard let table = sheet.table(containing: address) else { return }
        if address.row == table.headerRow {
            format.bold = true
            if format.fillColor == nil { format.fillColor = table.color }
            if format.textColor == nil { format.textColor = .white }
        } else if (address.row - table.headerRow) % 2 == 0, format.fillColor == nil {
            format.fillColor = Self.tint(table.color)
        }
    }

    /// The filter button in a table header cell.
    func tableFilterButtonRect(_ table: SheetTable, column: Int) -> CGRect? {
        guard table.range.columns.contains(column), !columns.isHidden(column), !rows.isHidden(table.headerRow) else { return nil }
        let header = rect(for: CellRange(CellAddress(row: table.headerRow, column: column)))
        let size = min(18 * zoom, header.height - 2)
        return CGRect(x: header.maxX - size - 3 * zoom, y: header.midY - size / 2, width: size, height: size)
    }

    /// The table the active cell is in, whose name chip shows.
    var selectedTable: SheetTable? {
        guard printSettings == nil, controller.selectedObjectID == nil else { return nil }
        return sheet.table(containing: controller.selection.active)
    }

    /// The chip with the table's name, just above its top-left corner.
    func tableChipRect(_ table: SheetTable) -> CGRect {
        let header = rect(for: CellRange(CellAddress(row: table.headerRow, column: table.range.start.column)))
        let width = (table.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11 * zoom, weight: .semibold)]).width + 30 * zoom
        let height = 20 * zoom
        var chip = CGRect(x: header.minX, y: header.minY - height - 2 * zoom, width: width, height: height)
        // Without room above the table, the chip sits over the column letters, keeping the data visible.
        if chip.minY < headerHeight { chip.origin.y = max(columnOutlineHeight, header.minY - height) }
        return chip
    }

    func drawTableDecorations(in pane: Pane) {
        guard !sheet.tables.isEmpty else { return }
        let visible = CellRange(rows: pane.rows, columns: pane.columns)
        for table in sheet.tables where table.range.intersects(visible) {
            let outline = NSBezierPath(rect: rect(for: table.range, xMode: pane.xMode, yMode: pane.yMode).offsetBy(dx: -0.5, dy: -0.5))
            outline.lineWidth = 1
            table.color.nsColor.setStroke()
            outline.stroke()
            guard printSettings == nil, pane.rows.contains(table.headerRow) else { continue }
            for column in table.range.columns where pane.columns.contains(column) {
                guard let button = tableFilterButtonRect(table, column: column) else { continue }
                drawFilterButton(button, active: table.criteria[column]?.isEmpty == false, onColor: true)
            }
        }
    }

    func drawTableChip() {
        guard let table = selectedTable else { return }
        let chip = tableChipRect(table)
        guard chip.intersects(gridBounds), chip.minY >= columnOutlineHeight else { return }
        table.color.nsColor.setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4 * zoom, yRadius: 4 * zoom).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11 * zoom, weight: .semibold), .foregroundColor: NSColor.white]
        (table.name as NSString).draw(at: CGPoint(x: chip.minX + 8 * zoom, y: chip.midY - 7 * zoom), withAttributes: attributes)
        let chevron = NSBezierPath()
        let center = CGPoint(x: chip.maxX - 10 * zoom, y: chip.midY)
        chevron.move(to: CGPoint(x: center.x - 3.5 * zoom, y: center.y - 1.5 * zoom))
        chevron.line(to: CGPoint(x: center.x, y: center.y + 2 * zoom))
        chevron.line(to: CGPoint(x: center.x + 3.5 * zoom, y: center.y - 1.5 * zoom))
        chevron.lineWidth = 1.4 * zoom
        NSColor.white.setStroke()
        chevron.stroke()
    }

    /// A table filter button or the table chip under `point`.
    func tableControl(at point: CGPoint) -> (table: SheetTable, column: Int?, rect: CGRect)? {
        guard printSettings == nil else { return nil }
        if let table = selectedTable, tableChipRect(table).contains(point) { return (table, nil, tableChipRect(table)) }
        for table in sheet.tables {
            for column in table.range.columns {
                if let button = tableFilterButtonRect(table, column: column), button.contains(point) { return (table, column, button) }
            }
        }
        return nil
    }

    // MARK: Sparklines

    func drawSparklines(in pane: Pane) {
        guard !sheet.sparklines.isEmpty else { return }
        for (address, spec) in sheet.sparklines where pane.rows.contains(address.row) && pane.columns.contains(address.column) {
            guard !rows.isHidden(address.row), !columns.isHidden(address.column) else { continue }
            let cell = rect(for: controller.mergedRange(at: address), xMode: pane.xMode, yMode: pane.yMode)
            drawSparkline(spec, in: cell.insetBy(dx: 3 * zoom, dy: 3 * zoom))
        }
    }

    /// A sparkline color option: a hex value or a color name, else `fallback`.
    static func sparklineColor(_ name: String?, default fallback: NSColor) -> NSColor {
        guard let raw = name?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return fallback }
        if let rgb = RGBColor(hex: raw) { return rgb.nsColor }
        let named: [String: UInt32] = ["black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF,
                                       "yellow": 0xFFFF00, "orange": 0xFFA500, "purple": 0x800080, "gray": 0x808080, "grey": 0x808080,
                                       "pink": 0xFFC0CB, "brown": 0xA52A2A, "cyan": 0x00FFFF, "magenta": 0xFF00FF, "lime": 0x00FF00,
                                       "navy": 0x000080, "teal": 0x008080, "maroon": 0x800000, "olive": 0x808000, "silver": 0xC0C0C0]
        return named[raw].map { GridColors.rgb($0) } ?? fallback
    }

    func drawSparkline(_ spec: SparklineSpec, in rect: CGRect) {
        guard rect.width > 2, rect.height > 2 else { return }
        let options = spec.options
        var values = spec.values
        if options["rtl"] == "true" { values.reverse() }
        let numbers = values.compactMap { $0 }
        guard !numbers.isEmpty else { return }
        let blue = GridColors.rgb(0x4285F4)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2)).addClip()
        switch spec.kind {
        case .line:
            let low = Double(options["ymin"] ?? "") ?? numbers.min()!
            let high = Double(options["ymax"] ?? "") ?? numbers.max()!
            let span = high - low == 0 ? 1 : high - low
            let path = NSBezierPath()
            var started = false
            let step = values.count > 1 ? rect.width / CGFloat(values.count - 1) : 0
            for (index, value) in values.enumerated() {
                guard let value else {
                    if options["empty"] != "zero" { started = false }
                    continue
                }
                let point = CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - CGFloat((value - low) / span) * rect.height)
                if started { path.line(to: point) } else { path.move(to: point); started = true }
            }
            path.lineWidth = CGFloat(Double(options["linewidth"] ?? "") ?? 1) * zoom
            path.lineJoinStyle = .round
            Self.sparklineColor(options["color"], default: blue).setStroke()
            path.stroke()
        case .column, .winloss:
            let winloss = spec.kind == .winloss
            let low = min(0, Double(options["ymin"] ?? "") ?? numbers.min()!)
            let high = max(0, Double(options["ymax"] ?? "") ?? numbers.max()!)
            let span = high - low == 0 ? 1 : high - low
            let slot = rect.width / CGFloat(max(1, values.count))
            let zeroY = winloss ? rect.midY : rect.maxY - CGFloat((0 - low) / span) * rect.height
            let maxValue = numbers.max(), minValue = numbers.min()
            for (index, value) in values.enumerated() {
                guard let value, value != 0 || !winloss else { continue }
                var color = Self.sparklineColor(options["color"], default: blue)
                if value < 0 { color = Self.sparklineColor(options["negcolor"], default: winloss ? GridColors.rgb(0xEA4335) : color) }
                if index == 0, options["firstcolor"] != nil { color = Self.sparklineColor(options["firstcolor"], default: color) }
                if index == values.count - 1, options["lastcolor"] != nil { color = Self.sparklineColor(options["lastcolor"], default: color) }
                if value == maxValue, options["highcolor"] != nil { color = Self.sparklineColor(options["highcolor"], default: color) }
                if value == minValue, options["lowcolor"] != nil { color = Self.sparklineColor(options["lowcolor"], default: color) }
                let top = winloss ? (value > 0 ? rect.minY : zeroY) : min(zeroY, rect.maxY - CGFloat((value - low) / span) * rect.height)
                let height = winloss ? rect.height / 2 : abs(CGFloat(value / span) * rect.height)
                color.setFill()
                CGRect(x: rect.minX + CGFloat(index) * slot + slot * 0.1, y: top, width: slot * 0.8, height: max(1, height)).fill()
            }
            if options["axis"] == "true" {
                Self.sparklineColor(options["axiscolor"], default: .black).setFill()
                CGRect(x: rect.minX, y: zeroY - 0.5, width: rect.width, height: 1).fill()
            }
        case .bar:
            let total = Double(options["max"] ?? "") ?? numbers.reduce(0, +)
            guard total > 0 else { break }
            var x = rect.minX
            for (index, value) in numbers.prefix(2).enumerated() where value > 0 {
                let width = CGFloat(value / total) * rect.width
                Self.sparklineColor(options[index == 0 ? "color1" : "color2"], default: index == 0 ? blue : GridColors.rgb(0xEA4335)).setFill()
                CGRect(x: x, y: rect.minY, width: min(width, rect.maxX - x), height: rect.height).fill()
                x += width
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
