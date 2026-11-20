import AppKit
import PuggleSheetsKit

/// The grid's colors.
enum GridColors {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let canvas = rgb(0xF9FBFD)
    static let gridline = rgb(0xE2E3E3)
    static let headerFill = rgb(0xF8F9FA)
    static let headerText = rgb(0x444746)
    static let headerLine = rgb(0xC4C7C5)
    static let headerSelected = rgb(0xD3E3FD)
    static let headerSelectedText = rgb(0x041E49)
    static let headerFullySelected = rgb(0x0B57D0)
    static let selection = rgb(0x1A73E8)
    static let selectionFill = rgb(0x0E65EB, 0.10)
    static let freezeBar = rgb(0xC4C7C5)
    static let error = rgb(0xEA4335)
    static let fillPreview = rgb(0x5F6368)
    static let findMatch = rgb(0xA8DAB5, 0.55)
    static let filterGreen = rgb(0x188038)
    /// The tick box color when the cell has no text color of its own.
    static let checkboxDefault = RGBColor(red: 0x5F, green: 0x63, blue: 0x68)
}

extension GridView {
    /// How far (in columns) text may spill from cells outside the visible area.
    private static let overflowReach = 24

    override func draw(_ dirtyRect: NSRect) {
        GridColors.canvas.setFill()
        bounds.fill()
        for pane in panes {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: pane.rect).addClip()
            drawCells(in: pane)
            drawFilterDecorations(in: pane)
            drawTableDecorations(in: pane)
            drawSelection(in: pane)
            drawReferenceHighlights(in: pane)
            NSGraphicsContext.restoreGraphicsState()
        }
        drawObjects()
        drawPivotEditButton()
        drawFooter()
        drawColumnHeaders()
        drawRowHeaders()
        drawOutlines()
        drawCorner()
        drawFreezeBars()
        // The table's name chip can sit over the column letters, so it comes after them.
        drawTableChip()
        drawScrollbars()
    }

    private func drawScrollbars() {
        for vertical in [true, false] {
            let track = scrollTrack(vertical: vertical)
            GridColors.headerFill.setFill()
            track.fill()
            GridColors.gridline.setFill()
            (vertical ? CGRect(x: track.minX, y: track.minY, width: 1, height: track.height)
                : CGRect(x: track.minX, y: track.minY, width: track.width, height: 1)).fill()
            guard let thumb = scrollThumb(vertical: vertical) else { continue }
            let dragging: Bool = if case .scrolling(let isVertical, _) = drag { isVertical == vertical } else { false }
            (dragging ? GridColors.rgb(0x80868B) : GridColors.rgb(0xBDC1C6)).setFill()
            let radius = min(thumb.width, thumb.height) / 2
            NSBezierPath(roundedRect: thumb, xRadius: radius, yRadius: radius).fill()
        }
    }

    // MARK: Cells

    private struct TextRun {
        var rect: CGRect
        var cellRect: CGRect
        var cell: Cell
        var alignment: HorizontalAlignment
        var look: ValidationLook = .none
        var invalid = false
    }

    /// Draws the cells of one printed page at the origin (print grids only), with an outline when
    /// gridlines are on.
    func drawPrintPage(rows pageRows: ClosedRange<Int>, columns pageColumns: ClosedRange<Int>) {
        setPrintOrigin(CGPoint(x: columns.offset(pageColumns.lowerBound), y: rows.offset(pageRows.lowerBound)))
        let width = CGFloat(columns.offset(pageColumns.upperBound + 1) - columns.offset(pageColumns.lowerBound))
        let height = CGFloat(rows.offset(pageRows.upperBound + 1) - rows.offset(pageRows.lowerBound))
        let pane = Pane(rect: CGRect(x: 0, y: 0, width: width, height: height), rows: pageRows, columns: pageColumns,
                        xMode: .scrolling, yMode: .scrolling)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: pane.rect).addClip()
        drawCells(in: pane)
        if printSettings?.gridlines == true {
            GridColors.gridline.setFill()
            CGRect(x: 0, y: 0, width: width, height: 1).fill()
            CGRect(x: 0, y: 0, width: 1, height: height).fill()
        }
        drawObjects()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCells(in pane: Pane) {
        let sheet = self.sheet
        let left = viewX(columns.offset(pane.columns.lowerBound), mode: pane.xMode)
        let right = viewX(columns.offset(pane.columns.upperBound + 1), mode: pane.xMode)
        let top = viewY(rows.offset(pane.rows.lowerBound), mode: pane.yMode)
        let bottom = viewY(rows.offset(pane.rows.upperBound + 1), mode: pane.yMode)
        NSColor.white.setFill()
        CGRect(x: left, y: top, width: right - left, height: bottom - top).intersection(pane.rect).fill()

        let xs = (pane.columns.lowerBound...(pane.columns.upperBound + 1)).map { viewX(columns.offset($0), mode: pane.xMode) }
        let ys = (pane.rows.lowerBound...(pane.rows.upperBound + 1)).map { viewY(rows.offset($0), mode: pane.yMode) }
        func x(_ column: Int) -> CGFloat {
            pane.columns.contains(column) || column == pane.columns.upperBound + 1
                ? xs[column - pane.columns.lowerBound] : viewX(columns.offset(column), mode: pane.xMode)
        }
        func y(_ row: Int) -> CGFloat { ys[row - pane.rows.lowerBound] }
        let rules = ruleResults(for: CellRange(rows: pane.rows, columns: pane.columns))
        // What each visible cell shows: content or spilled values, with conditional formatting applied.
        var shown: [CellAddress: Cell] = [:]
        for row in pane.rows where !rows.isHidden(row) {
            for column in pane.columns {
                let address = CellAddress(row: row, column: column)
                if let cell = displayCell(at: address, in: sheet, rules: rules) { shown[address] = cell }
            }
        }
        func shownCell(_ address: CellAddress) -> Cell? {
            pane.rows.contains(address.row) && pane.columns.contains(address.column) ? shown[address]
                : displayCell(at: address, in: sheet, rules: rules)
        }

        // Merged blocks that show in this pane, and which visible cells they cover.
        let merges = sheet.merges.filter {
            $0.rows.overlaps(pane.rows) && $0.columns.overlaps(pane.columns)
        }
        var mergeAt: [CellAddress: CellRange] = [:]
        for merge in merges {
            for row in max(merge.start.row, pane.rows.lowerBound)...min(merge.end.row, pane.rows.upperBound) {
                for column in max(merge.start.column, pane.columns.lowerBound)...min(merge.end.column, pane.columns.upperBound) {
                    mergeAt[CellAddress(row: row, column: column)] = merge
                }
            }
        }

        // Lay out text first: overflowing text hides the gridlines it crosses.
        let regionStart = pane.xMode == .frozen ? 0 : sheet.frozenColumns
        let regionEnd = pane.xMode == .frozen ? sheet.frozenColumns - 1 : sheet.columnCount - 1
        var runs: [TextRun] = []
        var hiddenLines = Set<CellAddress>()
        for row in pane.rows where !rows.isHidden(row) {
            let scanStart = max(regionStart, pane.columns.lowerBound - Self.overflowReach)
            let scanEnd = min(regionEnd, pane.columns.upperBound + Self.overflowReach)
            guard scanStart <= scanEnd else { continue }
            var content: [Int: Cell] = [:]
            for column in scanStart...scanEnd {
                if let cell = shownCell(CellAddress(row: row, column: column)), cell.hasContent { content[column] = cell }
            }
            func isFree(_ column: Int) -> Bool {
                column >= regionStart && column <= regionEnd && content[column] == nil
                    && sheet.merge(containing: CellAddress(row: row, column: column)) == nil
            }
            for (column, cell) in content.sorted(by: { $0.key < $1.key }) where !columns.isHidden(column) {
                let address = CellAddress(row: row, column: column)
                if mergeAt[address] != nil || sheet.merges.contains(where: { $0.contains(address) }) { continue }
                let cellRect = CGRect(x: x(column), y: y(row), width: x(column + 1) - x(column), height: y(row + 1) - y(row))
                let alignment = cell.format.horizontalAlignment ?? CellRenderer.automaticAlignment(for: cell.value)
                let look = validationLook(at: address, value: cell.value, in: sheet)
                var rect = cellRect
                let overflows: Bool = if case .none = look { true } else { false }
                if overflows, case .text(let text) = cell.value, cell.format.resolvedWrap == .overflow, !text.contains("\n") {
                    let needed = textWidth(cell) + 2 * CellRenderer.horizontalPadding * zoom
                    if needed > cellRect.width {
                        let extra = needed - cellRect.width
                        var next = column + 1, previous = column - 1
                        let growRight = alignment != .right, growLeft = alignment != .left
                        let share = alignment == .center ? extra / 2 : extra
                        var rightExtra: CGFloat = 0, leftExtra: CGFloat = 0
                        while growRight, rightExtra < share, isFree(next) {
                            rightExtra += x(next + 1) - x(next)
                            hiddenLines.insert(CellAddress(row: row, column: next - 1))
                            next += 1
                        }
                        while growLeft, leftExtra < share, isFree(previous) {
                            leftExtra += x(previous + 1) - x(previous)
                            hiddenLines.insert(CellAddress(row: row, column: previous))
                            previous -= 1
                        }
                        rect = CGRect(x: cellRect.minX - leftExtra, y: cellRect.minY, width: cellRect.width + leftExtra + rightExtra,
                                      height: cellRect.height)
                    }
                }
                runs.append(TextRun(rect: rect, cellRect: cellRect, cell: cell, alignment: alignment, look: look,
                                    invalid: rules.invalid.contains(address)))
            }
        }
        for merge in merges {
            let cell = displayCell(at: merge.start, in: sheet, rules: rules) ?? Cell()
            let rect = self.rect(for: merge, xMode: pane.xMode, yMode: pane.yMode)
            runs.append(TextRun(rect: rect, cellRect: rect, cell: cell,
                                alignment: cell.format.horizontalAlignment ?? CellRenderer.automaticAlignment(for: cell.value),
                                look: validationLook(at: merge.start, value: cell.value, in: sheet), invalid: rules.invalid.contains(merge.start)))
        }

        // Fills: the cell's own (or a conditional one), else its alternating color.
        func fill(_ address: CellAddress) -> RGBColor? {
            shownCell(address)?.format.fillColor ?? (sheet.bandings.isEmpty ? nil : bandingColor(at: address, in: sheet))
        }
        var filled = Set<CellAddress>()
        for row in pane.rows where !rows.isHidden(row) {
            for column in pane.columns where !columns.isHidden(column) {
                let address = CellAddress(row: row, column: column)
                guard mergeAt[address] == nil, let color = fill(address) else { continue }
                filled.insert(address)
                color.nsColor.setFill()
                CGRect(x: x(column), y: y(row), width: x(column + 1) - x(column), height: y(row + 1) - y(row)).fill()
            }
        }
        for merge in merges {
            if let color = fill(merge.start) {
                color.nsColor.setFill()
                rect(for: merge, xMode: pane.xMode, yMode: pane.yMode).fill()
            }
        }
        if !findMatches.isEmpty {
            GridColors.findMatch.setFill()
            for row in pane.rows where !rows.isHidden(row) {
                for column in pane.columns where findMatches.contains(CellAddress(row: row, column: column)) {
                    rect(for: controller.mergedRange(at: CellAddress(row: row, column: column)), xMode: pane.xMode, yMode: pane.yMode).fill()
                }
            }
        }

        // Gridlines, skipping merged blocks, filled cells and overflowing text.
        if printSettings?.gridlines ?? sheet.showsGridlines {
            let path = NSBezierPath()
            path.lineWidth = 1
            for row in pane.rows where !rows.isHidden(row) {
                for column in pane.columns where !columns.isHidden(column) {
                    let address = CellAddress(row: row, column: column)
                    if filled.contains(address) { continue }
                    let merge = mergeAt[address]
                    let right = x(column + 1), lower = y(row + 1)
                    if !hiddenLines.contains(address), merge == nil || merge!.end.column == column {
                        path.move(to: CGPoint(x: right - 0.5, y: y(row)))
                        path.line(to: CGPoint(x: right - 0.5, y: lower))
                    }
                    if merge == nil || merge!.end.row == row {
                        path.move(to: CGPoint(x: x(column), y: lower - 0.5))
                        path.line(to: CGPoint(x: right, y: lower - 0.5))
                    }
                }
            }
            GridColors.gridline.setStroke()
            path.stroke()
        }

        drawProtectedStripes(in: pane)
        for run in runs { drawText(run) }
        drawEmptyValidatedCells(in: pane, sheet: sheet, shown: shown, mergeAt: mergeAt, x: x, y: y)
        drawBorders(in: pane, x: x, y: y)
        drawSparklines(in: pane)
        drawCellMarkers(in: pane)
    }

    /// Empty checkbox cells show an unticked box and empty dropdown cells their arrow.
    private func drawEmptyValidatedCells(in pane: Pane, sheet: Sheet, shown: [CellAddress: Cell], mergeAt: [CellAddress: CellRange],
                                         x: (Int) -> CGFloat, y: (Int) -> CGFloat) {
        let visible = CellRange(rows: pane.rows, columns: pane.columns)
        for rule in sheet.validations {
            let checkbox: Bool
            switch rule.criterion {
            case .checkbox: checkbox = true
            case .list, .listFromRange: checkbox = false
            case .condition: continue
            }
            if !checkbox && !rule.showsDropdown { continue }
            for range in rule.ranges {
                guard let area = range.intersection(visible) else { continue }
                for row in area.rows where !rows.isHidden(row) {
                    for column in area.columns where !columns.isHidden(column) {
                        let address = CellAddress(row: row, column: column)
                        guard shown[address]?.hasContent != true, mergeAt[address] == nil,
                              sheet.validation(at: address)?.id == rule.id else { continue }
                        let rect = CGRect(x: x(column), y: y(row), width: x(column + 1) - x(column), height: y(row + 1) - y(row))
                        if checkbox {
                            drawCheckbox(in: rect, checked: false, color: (shown[address]?.format.textColor ?? GridColors.checkboxDefault).nsColor)
                        } else {
                            _ = drawDropdownChip(in: rect, hasValue: false)
                        }
                    }
                }
            }
        }
    }

    func textWidth(_ cell: Cell) -> CGFloat {
        let display = CellDisplay.text(for: cell.value, pattern: cell.format.numberFormat)
        return renderer.line(display.text, format: cell.format, color: nil, zoom: zoom).width
    }

    private func drawText(_ run: TextRun) {
        let cell = run.cell
        guard cell.hasContent, run.cellRect.width > 1, run.cellRect.height > 1 else { return }
        if let image = cell.image {
            drawCellImage(image, in: run.cellRect)
            return
        }
        if case .checkbox(let checked) = run.look {
            drawCheckbox(in: run.cellRect, checked: checked, color: (cell.format.textColor ?? GridColors.checkboxDefault).nsColor)
            if run.invalid, printSettings == nil { drawErrorCorner(in: run.cellRect) }
            return
        }
        var run = run
        if case .dropdown = run.look {
            let textRect = drawDropdownChip(in: run.cellRect, hasValue: true)
            run.rect = textRect.insetBy(dx: -CellRenderer.horizontalPadding * zoom, dy: 0)
            run.alignment = .left
        }
        var display = CellDisplay.text(for: cell.value, pattern: cell.format.numberFormat)
        if let rotation = cell.format.textRotation, !display.text.isEmpty {
            drawRotatedText(display.text, rotation: rotation, cell: cell, alignment: run.alignment, color: display.color, in: run.cellRect)
            if printSettings == nil, case .error = cell.value { drawErrorCorner(in: run.cellRect) }
            return
        }
        let wraps = cell.format.resolvedWrap == .wrap || display.text.contains("\n")
        let padding = CellRenderer.horizontalPadding * zoom
        let font = renderer.font(for: cell.format, zoom: zoom)
        let available = run.rect.width - 2 * padding
        var attributes = renderer.attributes(for: cell.format, color: display.color, zoom: zoom)
        // Plain single lines (the vast majority) come from the renderer's cache of laid-out lines.
        let plain = !wraps && display.fill == nil && !cell.format.underline && !cell.format.strikethrough
        func measure(_ text: String) -> CGFloat {
            plain ? renderer.line(text, format: cell.format, color: display.color, zoom: zoom).width
                : (text as NSString).size(withAttributes: attributes).width
        }
        var width = wraps ? 0 : measure(display.text)
        if case .number(let number) = cell.value, !wraps, width > available, display.fill == nil {
            let digits = max(1, Int(available / renderer.digitWidth(font)))
            display.text = cell.format.numberFormat == nil
                ? CellDisplay.automaticNumberText(number, maxLength: digits) : String(repeating: "#", count: digits)
            width = measure(display.text)
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: run.rect).addClip()
        let vertical = cell.format.resolvedVerticalAlignment
        let paddingY = CellRenderer.verticalPadding * zoom
        if wraps {
            let alignment: NSTextAlignment = run.alignment == .center ? .center : (run.alignment == .right ? .right : .left)
            attributes = renderer.attributes(for: cell.format, color: display.color, zoom: zoom, alignment: alignment,
                                             wraps: cell.format.resolvedWrap == .wrap)
            let box = run.rect.insetBy(dx: padding, dy: paddingY)
            let text = NSAttributedString(string: display.text, attributes: attributes)
            let height = min(box.height, ceil(text.boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                                                                options: [.usesLineFragmentOrigin], context: nil).height))
            let originY: CGFloat = switch vertical {
            case .top: box.minY
            case .middle: box.midY - height / 2
            case .bottom: box.maxY - height
            }
            text.draw(with: CGRect(x: box.minX, y: originY, width: box.width, height: box.maxY - originY),
                      options: [.usesLineFragmentOrigin], context: nil)
        } else {
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            let originY: CGFloat = switch vertical {
            case .top: run.rect.minY + paddingY
            case .middle: run.rect.midY - lineHeight / 2
            case .bottom: run.rect.maxY - paddingY - lineHeight
            }
            if let fill = display.fill {
                // Formats with a repeat fill ("* " in Accounting, "*-"…) push their two parts to the edges.
                (fill.before as NSString).draw(at: CGPoint(x: run.rect.minX + padding, y: originY), withAttributes: attributes)
                let beforeWidth = (fill.before as NSString).size(withAttributes: attributes).width
                let afterWidth = (fill.after as NSString).size(withAttributes: attributes).width
                (fill.after as NSString).draw(at: CGPoint(x: run.rect.maxX - padding - afterWidth, y: originY), withAttributes: attributes)
                if fill.character != " " {
                    let repeated = String(fill.character)
                    let gap = run.rect.width - 2 * padding - beforeWidth - afterWidth
                    let count = Int(gap / max(1, (repeated as NSString).size(withAttributes: attributes).width))
                    if count > 0 {
                        (String(repeating: repeated, count: count) as NSString)
                            .draw(at: CGPoint(x: run.rect.minX + padding + beforeWidth, y: originY), withAttributes: attributes)
                    }
                }
            } else {
                let originX: CGFloat = switch run.alignment {
                case .left: run.rect.minX + padding
                case .center: run.cellRect.midX - width / 2
                case .right: run.rect.maxX - padding - width
                }
                if plain, let context = NSGraphicsContext.current?.cgContext {
                    let line = renderer.line(display.text, format: cell.format, color: display.color, zoom: zoom).line
                    // The view is flipped, so the glyphs are flipped back upright around the baseline.
                    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                    context.textPosition = CGPoint(x: originX, y: originY + font.ascender)
                    CTLineDraw(line, context)
                } else {
                    (display.text as NSString).draw(at: CGPoint(x: originX, y: originY), withAttributes: attributes)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        // Errors and invalid values get a red corner; hovering explains them.
        // Printed pages leave the marks out.
        if printSettings != nil {
            return
        } else if case .error = cell.value {
            drawErrorCorner(in: run.cellRect)
        } else if run.invalid {
            drawErrorCorner(in: run.cellRect)
        }
    }

    private func drawBorders(in pane: Pane, x: (Int) -> CGFloat, y: (Int) -> CGFloat) {
        let sheet = self.sheet
        // One extra row and column around the pane: their facing sides can show here too.
        let rowRange = max(0, pane.rows.lowerBound - 1)...min(sheet.rowCount - 1, pane.rows.upperBound + 1)
        let columnRange = max(0, pane.columns.lowerBound - 1)...min(sheet.columnCount - 1, pane.columns.upperBound + 1)
        let region = CellRange(rows: rowRange, columns: columnRange)
        for (address, cell) in sheet.cells(in: region) where !cell.format.borders.isEmpty {
            let left = viewX(columns.offset(address.column), mode: pane.xMode)
            let right = viewX(columns.offset(address.column + 1), mode: pane.xMode)
            let top = viewY(rows.offset(address.row), mode: pane.yMode)
            let bottom = viewY(rows.offset(address.row + 1), mode: pane.yMode)
            let borders = cell.format.borders
            if let line = borders.top { strokeBorder(line, from: CGPoint(x: left - 0.5, y: top - 0.5), to: CGPoint(x: right - 0.5, y: top - 0.5)) }
            if let line = borders.bottom { strokeBorder(line, from: CGPoint(x: left - 0.5, y: bottom - 0.5), to: CGPoint(x: right - 0.5, y: bottom - 0.5)) }
            if let line = borders.left { strokeBorder(line, from: CGPoint(x: left - 0.5, y: top - 0.5), to: CGPoint(x: left - 0.5, y: bottom - 0.5)) }
            if let line = borders.right { strokeBorder(line, from: CGPoint(x: right - 0.5, y: top - 0.5), to: CGPoint(x: right - 0.5, y: bottom - 0.5)) }
        }
    }

    private func strokeBorder(_ line: BorderLine, from start: CGPoint, to end: CGPoint) {
        line.color.nsColor.setStroke()
        let horizontal = start.y == end.y
        func stroke(offset: CGFloat, width: CGFloat, dash: [CGFloat]?) {
            let path = NSBezierPath()
            path.lineWidth = width
            path.move(to: horizontal ? CGPoint(x: start.x, y: start.y + offset) : CGPoint(x: start.x + offset, y: start.y))
            path.line(to: horizontal ? CGPoint(x: end.x, y: end.y + offset) : CGPoint(x: end.x + offset, y: end.y))
            if let dash { path.setLineDash(dash, count: dash.count, phase: 0) }
            path.stroke()
        }
        switch line.style {
        case .thin: stroke(offset: 0, width: 1, dash: nil)
        case .medium: stroke(offset: 0, width: 2, dash: nil)
        case .thick: stroke(offset: 0, width: 3, dash: nil)
        case .dashed: stroke(offset: 0, width: 1, dash: [4, 2])
        case .dotted: stroke(offset: 0, width: 1, dash: [1, 1])
        case .double:
            stroke(offset: -1, width: 1, dash: nil)
            stroke(offset: 1, width: 1, dash: nil)
        }
    }

    // MARK: Selection

    private func drawSelection(in pane: Pane) {
        let selection = controller.selection
        let isActiveWindow = window?.isKeyWindow ?? false
        let color = GridColors.selection
        for (index, range) in selection.ranges.enumerated() {
            let rangeRect = rect(for: range, xMode: pane.xMode, yMode: pane.yMode)
            guard rangeRect.intersects(pane.rect), !(range.isSingleCell && selection.ranges.count == 1) else { continue }
            let path = NSBezierPath(rect: rangeRect)
            if index == selection.ranges.count - 1 {
                path.append(NSBezierPath(rect: rect(for: controller.mergedRange(at: selection.active), xMode: pane.xMode, yMode: pane.yMode)))
                path.windingRule = .evenOdd
            }
            GridColors.selectionFill.setFill()
            path.fill()
            color.setStroke()
            // On the same pixel line as the gridlines, which sit just inside each cell's right and bottom edge.
            let outline = NSBezierPath(rect: rangeRect.offsetBy(dx: -0.5, dy: -0.5))
            outline.lineWidth = 1
            outline.stroke()
        }

        let activeRect = rect(for: controller.mergedRange(at: selection.active), xMode: pane.xMode, yMode: pane.yMode)
        if let text = mirroredEditText, editor == nil {
            NSColor.white.setFill()
            activeRect.fill()
            let format = sheet[selection.active].format
            let font = renderer.font(for: format, zoom: zoom)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: activeRect).addClip()
            let origin = CGPoint(x: activeRect.minX + CellRenderer.horizontalPadding * zoom,
                                 y: activeRect.maxY - CellRenderer.verticalPadding * zoom - ceil(font.ascender - font.descender))
            (text as NSString).draw(at: origin, withAttributes: renderer.attributes(for: format, color: nil, zoom: zoom))
            NSGraphicsContext.restoreGraphicsState()
        }

        // Two points wide, straddling the cell's edges (or the editor's, which may be wider).
        let border = NSBezierPath(rect: editor.map(editorBorderRect) ?? activeRect)
        border.lineWidth = 2
        (isActiveWindow || editor != nil ? color : color.withAlphaComponent(0.6)).setStroke()
        border.stroke()

        if case .filling(_, let target) = drag {
            let preview = NSBezierPath(rect: rect(for: target, xMode: pane.xMode, yMode: pane.yMode).offsetBy(dx: -0.5, dy: -0.5))
            preview.setLineDash([3, 2], count: 2, phase: 0)
            preview.lineWidth = 1
            GridColors.fillPreview.setStroke()
            preview.stroke()
        } else if editor == nil, canChange {
            let current = rect(for: selection.current, xMode: pane.xMode, yMode: pane.yMode)
            let handle = CGRect(x: current.maxX - 3.5, y: current.maxY - 3.5, width: 6, height: 6)
            NSColor.white.setFill()
            handle.insetBy(dx: -1, dy: -1).fill()
            color.setFill()
            handle.fill()
        }

        if let cut = controller.cutRange, cut.sheetID == controller.activeSheetID {
            let outline = NSBezierPath(rect: rect(for: cut.range, xMode: pane.xMode, yMode: pane.yMode).insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 2
            outline.setLineDash([5, 3], count: 2, phase: 0)
            color.setStroke()
            outline.stroke()
        }
    }

    /// Where the fill handle is, in view coordinates.
    var fillHandleRect: CGRect {
        let current = rect(for: controller.selection.current)
        return CGRect(x: current.maxX - 6, y: current.maxY - 6, width: 11, height: 11)
    }

    // MARK: Headers

    private func headerFont() -> NSFont { NSFont.systemFont(ofSize: 10.5 * zoom) }

    private func drawColumnHeaders() {
        let grid = gridBounds
        let top = columnOutlineHeight
        let band = CGRect(x: headerWidth, y: top, width: max(0, grid.maxX - headerWidth), height: headerHeight - top)
        headerFillColor.setFill()
        band.fill()
        let selection = controller.selection
        let sheet = self.sheet
        let font = headerFont()
        var spans: [(ClosedRange<Int>, AxisMode, CGRect)] = []
        if sheet.frozenColumns > 0 {
            spans.append((0...(sheet.frozenColumns - 1), .frozen, CGRect(x: headerWidth, y: 0, width: scrollOrigin.x - headerWidth, height: headerHeight)))
        }
        if let visible = visibleScrollingColumns {
            spans.append((visible, .scrolling, CGRect(x: scrollOrigin.x, y: 0, width: max(0, grid.maxX - scrollOrigin.x), height: headerHeight)))
        }
        for (range, mode, clip) in spans {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clip).addClip()
            for column in range where !columns.isHidden(column) {
                let left = columnX(column, mode: mode), right = columnX(column + 1, mode: mode)
                let rect = CGRect(x: left, y: top, width: right - left, height: headerHeight - top)
                let full = selection.ranges.contains { $0.columns.contains(column) && $0.start.row == 0 && $0.end.row >= sheet.rowCount - 1 }
                let partial = full || selection.ranges.contains { $0.columns.contains(column) }
                if full || partial {
                    (full ? GridColors.headerFullySelected : GridColors.headerSelected).setFill()
                    rect.fill()
                }
                drawCentered(CellAddress.columnName(column), in: rect, font: font,
                             color: full ? .white : (partial ? GridColors.headerSelectedText : headerTextColor))
                GridColors.headerLine.setFill()
                CGRect(x: right - 1, y: top, width: 1, height: headerHeight - top).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        GridColors.headerLine.setFill()
        CGRect(x: 0, y: headerHeight - 1, width: grid.maxX, height: 1).fill()
    }

    private func drawRowHeaders() {
        let grid = gridBounds
        let left = rowOutlineWidth
        let band = CGRect(x: left, y: headerHeight, width: headerWidth - left, height: max(0, grid.maxY - headerHeight))
        headerFillColor.setFill()
        band.fill()
        let selection = controller.selection
        let sheet = self.sheet
        let font = headerFont()
        var spans: [(ClosedRange<Int>, AxisMode, CGRect)] = []
        if sheet.frozenRows > 0 {
            spans.append((0...(sheet.frozenRows - 1), .frozen, CGRect(x: 0, y: headerHeight, width: headerWidth, height: scrollOrigin.y - headerHeight)))
        }
        if let visible = visibleScrollingRows {
            spans.append((visible, .scrolling, CGRect(x: 0, y: scrollOrigin.y, width: headerWidth, height: max(0, grid.maxY - scrollOrigin.y))))
        }
        for (range, mode, clip) in spans {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clip).addClip()
            for row in range where !rows.isHidden(row) {
                let top = rowY(row, mode: mode), bottom = rowY(row + 1, mode: mode)
                let rect = CGRect(x: left, y: top, width: headerWidth - left, height: bottom - top)
                let full = selection.ranges.contains { $0.rows.contains(row) && $0.start.column == 0 && $0.end.column >= sheet.columnCount - 1 }
                let partial = full || selection.ranges.contains { $0.rows.contains(row) }
                if full || partial {
                    (full ? GridColors.headerFullySelected : GridColors.headerSelected).setFill()
                    rect.fill()
                }
                drawCentered(String(row + 1), in: rect, font: font,
                             color: full ? .white : (partial ? GridColors.headerSelectedText : headerTextColor))
                GridColors.headerLine.setFill()
                CGRect(x: left, y: bottom - 1, width: headerWidth - left, height: 1).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        GridColors.headerLine.setFill()
        CGRect(x: headerWidth - 1, y: 0, width: 1, height: grid.maxY).fill()
    }

    private func drawCorner() {
        let corner = CGRect(x: 0, y: 0, width: headerWidth, height: headerHeight)
        headerFillColor.setFill()
        corner.fill()
        GridColors.headerLine.setFill()
        CGRect(x: 0, y: headerHeight - 1, width: headerWidth, height: 1).fill()
        CGRect(x: headerWidth - 1, y: 0, width: 1, height: headerHeight).fill()
    }

    private func drawCentered(_ text: String, in rect: CGRect, font: NSFont, color: NSColor) {
        guard rect.width > 4, rect.height > 4 else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    private func drawFreezeBars() {
        let grid = gridBounds
        GridColors.freezeBar.setFill()
        if sheet.frozenRows > 0 {
            CGRect(x: 0, y: scrollOrigin.y - 2, width: grid.maxX, height: 4).fill()
        } else {
            // With nothing frozen, the bars wait at the corner's edges to be dragged.
            CGRect(x: 0, y: headerHeight - 4, width: headerWidth, height: 4).fill()
        }
        if sheet.frozenColumns > 0 {
            CGRect(x: scrollOrigin.x - 2, y: 0, width: 4, height: grid.maxY).fill()
        } else {
            CGRect(x: headerWidth - 4, y: 0, width: 4, height: headerHeight).fill()
        }
        guard case .freezing(let rowsBar)? = drag, let position = freezeDragPosition else { return }
        // Where the bar will land, and the bar itself following the mouse.
        let target = freezeTarget(rows: rowsBar, at: position)
        GridColors.freezeBar.withAlphaComponent(0.6).setFill()
        if rowsBar {
            let y = target == 0 ? headerHeight : rowY(target, mode: mode(forRow: target - 1))
            CGRect(x: 0, y: y - 2, width: grid.maxX, height: 4).fill()
            GridColors.rgb(0x9AA0A6).setFill()
            CGRect(x: 0, y: position - 2, width: grid.maxX, height: 4).fill()
        } else {
            let x = target == 0 ? headerWidth : columnX(target, mode: mode(forColumn: target - 1))
            CGRect(x: x - 2, y: 0, width: 4, height: grid.maxY).fill()
            GridColors.rgb(0x9AA0A6).setFill()
            CGRect(x: position - 2, y: 0, width: 4, height: grid.maxY).fill()
        }
    }

    // MARK: Footer

    /// The "Add 1000 more rows at the bottom" button, when the last row is in view.
    var footerButtonRect: CGRect? {
        guard canChange, let footer = footerRect else { return nil }
        let font = NSFont.systemFont(ofSize: 13)
        let width = (Self.footerTitle as NSString).size(withAttributes: [.font: font]).width + 28
        return CGRect(x: headerWidth + 12, y: footer.minY + 16, width: width, height: 32)
    }

    static let footerTitle = "Add 1,000 more rows at the bottom"

    private func drawFooter() {
        guard let button = footerButtonRect else { return }
        let path = NSBezierPath(roundedRect: button, xRadius: 6, yRadius: 6)
        NSColor.white.setFill()
        path.fill()
        GridColors.headerLine.setStroke()
        path.lineWidth = 1
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                         .foregroundColor: GridColors.headerFullySelected]
        let size = (Self.footerTitle as NSString).size(withAttributes: attributes)
        (Self.footerTitle as NSString).draw(at: CGPoint(x: button.midX - size.width / 2, y: button.midY - size.height / 2),
                                           withAttributes: attributes)
    }
}
