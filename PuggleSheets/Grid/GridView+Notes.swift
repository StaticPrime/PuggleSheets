import AppKit
import PuggleSheetsKit

/// Notes, comments, protected ranges and rotated text in the grid.
extension GridView {
    static let commentColor = GridColors.rgb(0xF9AB00)

    /// Corner marks: black for a note, amber for an open comment thread.
    func drawCellMarkers(in pane: Pane) {
        guard printSettings == nil else { return }
        let visible = CellRange(rows: pane.rows, columns: pane.columns)
        for (address, cell) in sheet.cells(in: visible) where cell.note != nil || (cell.comment.map { !$0.isResolved } ?? false) {
            guard !rows.isHidden(address.row), !columns.isHidden(address.column) else { continue }
            let rect = self.rect(for: controller.mergedRange(at: address), xMode: pane.xMode, yMode: pane.yMode)
            let size = 6 * zoom
            let triangle = NSBezierPath()
            triangle.move(to: CGPoint(x: rect.maxX - 1 - size, y: rect.minY))
            triangle.line(to: CGPoint(x: rect.maxX - 1, y: rect.minY))
            triangle.line(to: CGPoint(x: rect.maxX - 1, y: rect.minY + size))
            triangle.close()
            let hasComment = cell.comment.map { !$0.isResolved } ?? false
            (hasComment ? Self.commentColor : NSColor.black).setFill()
            triangle.fill()
        }
    }

    /// View ▸ Show ▸ Protected ranges: gray stripes over protected cells.
    func drawProtectedStripes(in pane: Pane) {
        guard printSettings == nil, showsProtectedRanges, !sheet.protections.isEmpty else { return }
        let visible = CellRange(rows: pane.rows, columns: pane.columns)
        for protection in sheet.protections {
            let area = NSBezierPath()
            area.windingRule = .evenOdd
            switch protection.scope {
            case .range(let range):
                guard let shown = range.intersection(visible) else { continue }
                area.appendRect(rect(for: shown, xMode: pane.xMode, yMode: pane.yMode))
            case .sheet(let except):
                area.appendRect(pane.rect)
                for range in except {
                    if let shown = range.intersection(visible) { area.appendRect(rect(for: shown, xMode: pane.xMode, yMode: pane.yMode)) }
                }
            }
            NSGraphicsContext.saveGraphicsState()
            area.addClip()
            let bounds = area.bounds.intersection(pane.rect)
            let stripes = NSBezierPath()
            let step = 6 * zoom
            var x = bounds.minX - bounds.height
            while x < bounds.maxX {
                stripes.move(to: CGPoint(x: x, y: bounds.maxY))
                stripes.line(to: CGPoint(x: x + bounds.height, y: bounds.minY))
                x += step
            }
            stripes.lineWidth = 1
            GridColors.rgb(0x9AA0A6, 0.35).setStroke()
            stripes.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Text turned by an angle, or stacked one character per line, placed by the cell's alignment.
    func drawRotatedText(_ text: String, rotation: TextRotation, cell: Cell, alignment: HorizontalAlignment, color: RGBColor?, in rect: CGRect) {
        let attributes = renderer.attributes(for: cell.format, color: color, zoom: zoom)
        let font = renderer.font(for: cell.format, zoom: zoom)
        let padding = CellRenderer.horizontalPadding * zoom, paddingY = CellRenderer.verticalPadding * zoom
        let vertical = cell.format.resolvedVerticalAlignment
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        switch rotation {
        case .stacked:
            let characters = text.map(String.init)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            let total = lineHeight * CGFloat(characters.count)
            var y: CGFloat = switch vertical {
            case .top: rect.minY + paddingY
            case .middle: rect.midY - total / 2
            case .bottom: rect.maxY - paddingY - total
            }
            let widest = characters.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
            let columnCenter: CGFloat = switch alignment {
            case .left: rect.minX + padding + widest / 2
            case .center: rect.midX
            case .right: rect.maxX - padding - widest / 2
            }
            for character in characters {
                let width = (character as NSString).size(withAttributes: attributes).width
                (character as NSString).draw(at: CGPoint(x: columnCenter - width / 2, y: y), withAttributes: attributes)
                y += lineHeight
            }
        case .angle(let degrees):
            let size = (text as NSString).size(withAttributes: attributes)
            let radians = CGFloat(degrees) * .pi / 180
            let boxWidth = abs(size.width * cos(radians)) + abs(size.height * sin(radians))
            let boxHeight = abs(size.width * sin(radians)) + abs(size.height * cos(radians))
            let boxX: CGFloat = switch alignment {
            case .left: rect.minX + padding
            case .center: rect.midX - boxWidth / 2
            case .right: rect.maxX - padding - boxWidth
            }
            let boxY: CGFloat = switch vertical {
            case .top: rect.minY + paddingY
            case .middle: rect.midY - boxHeight / 2
            case .bottom: rect.maxY - paddingY - boxHeight
            }
            let transform = NSAffineTransform()
            transform.translateX(by: boxX + boxWidth / 2, yBy: boxY + boxHeight / 2)
            // The view is flipped, so turning the text up (counterclockwise) is a negative angle here.
            transform.rotate(byRadians: -radians)
            transform.concat()
            (text as NSString).draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The cell under the mouse, for note pop-ups; nil outside the cells.
    func hoveredCell(at point: CGPoint) -> CellAddress? {
        guard case .cell(let address) = location(at: point), objectHit(at: point) == nil else { return nil }
        return controller.mergedRange(at: address).start
    }
}
