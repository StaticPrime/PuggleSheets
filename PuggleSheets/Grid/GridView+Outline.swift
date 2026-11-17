import AppKit
import PuggleSheetsKit

/// Row and column groups: brackets with + and − buttons in a band beside the row numbers and above
/// the column letters.
extension GridView {
    static let outlineLevelWidth: CGFloat = 14
    static let outlineMargin: CGFloat = 6

    /// The band left of the row numbers (zero without row groups).
    var rowOutlineWidth: CGFloat {
        rowOutlineLevels > 0 ? (CGFloat(rowOutlineLevels) * Self.outlineLevelWidth + Self.outlineMargin) * zoom : 0
    }

    /// The band above the column letters (zero without column groups).
    var columnOutlineHeight: CGFloat {
        columnOutlineLevels > 0 ? (CGFloat(columnOutlineLevels) * Self.outlineLevelWidth + Self.outlineMargin) * zoom : 0
    }

    /// Where a group's line runs and where its button sits, in view coordinates.
    private func outlineGeometry(_ group: OutlineGroup, rows: Bool) -> (lineStart: CGFloat, lineEnd: CGFloat, center: CGFloat, button: CGRect) {
        let groups = rows ? sheet.rowGroups : sheet.columnGroups
        let depth = groups.depth(of: group)
        let center = (Self.outlineMargin / 2 + CGFloat(depth) * Self.outlineLevelWidth + Self.outlineLevelWidth / 2) * zoom
        let start = rows ? rowY(group.range.lowerBound) : columnX(group.range.lowerBound)
        let end = rows ? rowY(group.range.upperBound + 1) : columnX(group.range.upperBound + 1)
        let size = 11 * zoom
        let button = rows ? CGRect(x: center - size / 2, y: end - size / 2, width: size, height: size)
            : CGRect(x: end - size / 2, y: center - size / 2, width: size, height: size)
        return (start, end, center, button)
    }

    func drawOutlines() {
        guard printSettings == nil else { return }
        let grid = gridBounds
        if rowOutlineWidth > 0 {
            let band = CGRect(x: 0, y: headerHeight, width: rowOutlineWidth, height: max(0, grid.maxY - headerHeight))
            headerFillColor.setFill()
            band.fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: band).addClip()
            for group in sheet.rowGroups { drawOutline(group, rows: true) }
            NSGraphicsContext.restoreGraphicsState()
        }
        if columnOutlineHeight > 0 {
            let band = CGRect(x: headerWidth, y: 0, width: max(0, grid.maxX - headerWidth), height: columnOutlineHeight)
            headerFillColor.setFill()
            band.fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: band).addClip()
            for group in sheet.columnGroups { drawOutline(group, rows: false) }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawOutline(_ group: OutlineGroup, rows: Bool) {
        let geometry = outlineGeometry(group, rows: rows)
        let color = GridColors.rgb(0x5F6368)
        if !group.isCollapsed, geometry.lineEnd - geometry.lineStart > 4 {
            // The bracket: a short tick at the start and a line along the group to its button.
            let line = NSBezierPath()
            line.lineWidth = 1
            let tick = 4 * zoom
            if rows {
                line.move(to: CGPoint(x: geometry.center + tick, y: geometry.lineStart + 2))
                line.line(to: CGPoint(x: geometry.center, y: geometry.lineStart + 2))
                line.line(to: CGPoint(x: geometry.center, y: geometry.button.minY))
            } else {
                line.move(to: CGPoint(x: geometry.lineStart + 2, y: geometry.center + tick))
                line.line(to: CGPoint(x: geometry.lineStart + 2, y: geometry.center))
                line.line(to: CGPoint(x: geometry.button.minX, y: geometry.center))
            }
            color.setStroke()
            line.stroke()
        }
        let button = geometry.button
        NSColor.white.setFill()
        button.fill()
        color.setStroke()
        let border = NSBezierPath(rect: button.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        let sign = NSBezierPath()
        sign.lineWidth = max(1, 1.2 * zoom)
        let inset = 3 * zoom
        sign.move(to: CGPoint(x: button.minX + inset, y: button.midY))
        sign.line(to: CGPoint(x: button.maxX - inset, y: button.midY))
        if group.isCollapsed {
            sign.move(to: CGPoint(x: button.midX, y: button.minY + inset))
            sign.line(to: CGPoint(x: button.midX, y: button.maxY - inset))
        }
        sign.stroke()
    }

    /// The group whose + or − button is under `point`.
    func outlineButton(at point: CGPoint) -> (group: OutlineGroup, rows: Bool)? {
        guard printSettings == nil else { return nil }
        if point.x < rowOutlineWidth, point.y > headerHeight {
            for group in sheet.rowGroups where outlineGeometry(group, rows: true).button.insetBy(dx: -3, dy: -3).contains(point) {
                return (group, true)
            }
        }
        if point.y < columnOutlineHeight, point.x > headerWidth {
            for group in sheet.columnGroups where outlineGeometry(group, rows: false).button.insetBy(dx: -3, dy: -3).contains(point) {
                return (group, false)
            }
        }
        return nil
    }

    /// Whether `point` is in an outline band (clicks there don't select).
    func isInOutlineBand(_ point: CGPoint) -> Bool {
        (point.x < rowOutlineWidth && point.y > headerHeight) || (point.y < columnOutlineHeight && point.x > headerWidth)
    }
}
