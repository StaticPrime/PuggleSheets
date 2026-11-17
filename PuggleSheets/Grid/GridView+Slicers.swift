import AppKit
import PuggleSheetsKit

/// Slicers over the grid: a card with the filtered column's name and a status line that opens the filter.
extension GridView {
    /// The column a slicer filters, and its heading.
    func slicerHeading(_ spec: SlicerSpec) -> String {
        if !spec.title.isEmpty { return spec.title }
        guard let target = controller.workbook.resolve(spec.range, onSheet: drawnSheetIndex) else { return "Slicer" }
        let column = target.range.start.column + spec.column
        let value = controller.workbook.sheets[target.sheet].value(at: CellAddress(row: target.range.start.row, column: column))
        let text = CellDisplay.text(for: value, pattern: nil).text
        return text.isEmpty ? "Column \(CellAddress.columnName(column))" : text
    }

    /// A slicer's status: "Showing all items", "2 items hidden" or the condition.
    static func slicerStatus(_ spec: SlicerSpec) -> String {
        if let condition = spec.criterion.condition { return condition.summary }
        let hidden = spec.criterion.hiddenValues.count
        return hidden == 0 ? "Showing all items" : (hidden == 1 ? "1 item hidden" : "\(hidden) items hidden")
    }

    /// The status line, which opens the slicer's filter when clicked.
    func slicerStatusRect(in rect: CGRect) -> CGRect {
        let padding = 8 * zoom
        let height = min(26 * zoom, rect.height / 2)
        return CGRect(x: rect.minX + padding, y: rect.maxY - padding - height, width: max(0, rect.width - 2 * padding), height: height)
    }

    func drawSlicer(_ spec: SlicerSpec, in rect: CGRect) {
        let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6 * zoom, yRadius: 6 * zoom)
        (spec.backgroundColor?.nsColor ?? .white).setFill()
        card.fill()
        GridColors.rgb(0xDADCE0).setStroke()
        card.lineWidth = 1
        card.stroke()
        let padding = 8 * zoom
        let active = spec.criterion.condition != nil || !spec.criterion.hiddenValues.isEmpty
        // A funnel, green while the slicer hides something (as filter buttons are).
        let funnel = NSBezierPath()
        let size = 12 * zoom, origin = CGPoint(x: rect.minX + padding, y: rect.minY + padding + 2 * zoom)
        funnel.move(to: origin)
        funnel.line(to: CGPoint(x: origin.x + size, y: origin.y))
        funnel.line(to: CGPoint(x: origin.x + size * 0.6, y: origin.y + size * 0.5))
        funnel.line(to: CGPoint(x: origin.x + size * 0.6, y: origin.y + size))
        funnel.line(to: CGPoint(x: origin.x + size * 0.4, y: origin.y + size * 0.85))
        funnel.line(to: CGPoint(x: origin.x + size * 0.4, y: origin.y + size * 0.5))
        funnel.close()
        (active ? GridColors.filterGreen : GridColors.rgb(0x5F6368)).setFill()
        funnel.fill()
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5 * zoom, weight: .semibold),
                                                              .foregroundColor: GridColors.rgb(0x202124)]
        let title = slicerHeading(spec) as NSString
        title.draw(with: CGRect(x: origin.x + size + 6 * zoom, y: rect.minY + padding, width: max(0, rect.width - 3 * padding - size), height: 18 * zoom),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttributes, context: nil)
        let status = slicerStatusRect(in: rect)
        guard status.height > 8 else { return }
        let box = NSBezierPath(roundedRect: status, xRadius: 4 * zoom, yRadius: 4 * zoom)
        GridColors.rgb(0xF1F3F4).setFill()
        box.fill()
        let statusAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5 * zoom),
                                                               .foregroundColor: GridColors.rgb(0x3C4043)]
        (Self.slicerStatus(spec) as NSString).draw(with: CGRect(x: status.minX + 8 * zoom, y: status.midY - 7 * zoom,
                                                                width: max(0, status.width - 28 * zoom), height: 16 * zoom),
                                                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                   attributes: statusAttributes, context: nil)
        let chevron = NSBezierPath()
        let center = CGPoint(x: status.maxX - 12 * zoom, y: status.midY)
        chevron.move(to: CGPoint(x: center.x - 4 * zoom, y: center.y - 2 * zoom))
        chevron.line(to: CGPoint(x: center.x, y: center.y + 2 * zoom))
        chevron.line(to: CGPoint(x: center.x + 4 * zoom, y: center.y - 2 * zoom))
        chevron.lineWidth = 1.5 * zoom
        GridColors.rgb(0x5F6368).setStroke()
        chevron.stroke()
    }
}
