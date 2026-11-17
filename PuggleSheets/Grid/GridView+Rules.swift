import AppKit
import PuggleSheetsKit

/// How the grid shows rules: conditional formatting, alternating colors, data validation (checkboxes,
/// dropdowns and invalid values) and spilled array results.
extension GridView {
    /// Forgets cached rule results; called after every edit.
    func invalidateRuleCaches() {
        ruleCache = []
    }

    /// Conditional formatting and invalid cells for `range`, computed for a margin around it so that
    /// scrolling a little reuses the result.
    func ruleResults(for range: CellRange) -> RuleCacheEntry {
        if let entry = ruleCache.first(where: { $0.range.contains(range) }) { return entry }
        let sheet = self.sheet
        guard !sheet.conditionalFormats.isEmpty || !sheet.validations.isEmpty else {
            return RuleCacheEntry(range: range, formats: [:], invalid: [])
        }
        let expanded = CellRange(rows: max(0, range.start.row - 60)...min(sheet.rowCount - 1, range.end.row + 60),
                                 columns: max(0, range.start.column - 10)...min(sheet.columnCount - 1, range.end.column + 10))
        let workbook = controller.workbook
        let sheetIndex = drawnSheetIndex
        let now = Date()
        let formats = sheet.conditionalFormats.isEmpty ? [:]
            : RuleEvaluator.conditionalFormats(in: expanded, sheetIndex: sheetIndex, workbook: workbook, now: now)
        var invalid = Set<CellAddress>()
        for rule in sheet.validations where !rule.rejectsInvalid {
            if case .checkbox = rule.criterion { continue }
            for ruleRange in rule.ranges {
                guard let visible = ruleRange.intersection(expanded) else { continue }
                for (address, cell) in sheet.cells(in: visible) where cell.hasContent && sheet.validation(at: address)?.id == rule.id {
                    if !RuleEvaluator.isValid(cell.value, for: rule, at: address, sheetIndex: sheetIndex, workbook: workbook, now: now) {
                        invalid.insert(address)
                    }
                }
            }
        }
        let entry = RuleCacheEntry(range: expanded, formats: formats, invalid: invalid)
        if ruleCache.count > 8 { ruleCache.removeFirst() }
        ruleCache.append(entry)
        return entry
    }

    /// What a cell shows: its own content, or a value spilled into it, with conditional formatting
    /// laid over its format. nil when there's nothing to show.
    func displayCell(at address: CellAddress, in sheet: Sheet, rules: RuleCacheEntry) -> Cell? {
        let stored = sheet.cells[address]
        var cell = stored ?? Cell()
        if !(stored?.hasContent ?? false), let spilled = sheet.spilledValues[address] { cell.value = spilled }
        if showsFormulas, let formula = stored?.formula {
            // View ▸ Show ▸ Formulas: the formula itself, left aligned and unformatted.
            cell.value = .text(formula)
            cell.format.numberFormat = nil
            cell.format.horizontalAlignment = .left
            return cell
        }
        if !sheet.pivotTables.isEmpty, let style = pivotStyle(at: address, in: sheet) { applyPivotStyle(style, to: &cell.format) }
        if !sheet.tables.isEmpty { applyTableStyle(at: address, in: sheet, to: &cell.format) }
        if let override = rules.formats[address] { cell.format = override.applied(to: cell.format) }
        if showsLink(at: address, stored: stored, value: cell.value, in: sheet) {
            if cell.format.textColor == nil { cell.format.textColor = Self.linkColor }
            cell.format.underline = true
        }
        return cell.hasContent || !cell.format.isDefault ? cell : nil
    }

    /// The alternating color for a cell, if it's in a banded range.
    func bandingColor(at address: CellAddress, in sheet: Sheet) -> RGBColor? {
        for banding in sheet.bandings where banding.range.contains(address) {
            return banding.color(forRow: address.row)
        }
        return nil
    }

    /// How data validation changes the way a cell is drawn.
    enum ValidationLook {
        case none
        case checkbox(checked: Bool)
        case dropdown
    }

    func validationLook(at address: CellAddress, value: CellValue, in sheet: Sheet) -> ValidationLook {
        guard let rule = sheet.validation(at: address) else { return .none }
        switch rule.criterion {
        case .checkbox(let checked, _):
            return .checkbox(checked: Self.isChecked(value, checkedValue: checked))
        case .list, .listFromRange:
            return rule.showsDropdown ? .dropdown : .none
        case .condition:
            return .none
        }
    }

    /// TRUE (or the rule's custom checked value) ticks a checkbox.
    static func isChecked(_ value: CellValue, checkedValue: String?) -> Bool {
        guard let checkedValue else { return value == .boolean(true) }
        let text = CellDisplay.text(for: value, pattern: nil).text
        return text.caseInsensitiveCompare(checkedValue) == .orderedSame
    }

    /// A checkbox: an outlined square, filled with a tick when checked, in the text color.
    func drawCheckbox(in rect: CGRect, checked: Bool, color: NSColor) {
        let size = min(14 * zoom, rect.height - 4, rect.width - 4)
        guard size > 4 else { return }
        let box = CGRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
        let radius = 2 * zoom
        if checked {
            color.setFill()
            NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: box.minX + size * 0.22, y: box.minY + size * 0.52))
            tick.line(to: CGPoint(x: box.minX + size * 0.42, y: box.minY + size * 0.72))
            tick.line(to: CGPoint(x: box.minX + size * 0.78, y: box.minY + size * 0.3))
            tick.lineWidth = max(1.5, 1.8 * zoom)
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.75 * zoom, dy: 0.75 * zoom), xRadius: radius, yRadius: radius)
            outline.lineWidth = 1.5 * zoom
            color.setStroke()
            outline.stroke()
        }
    }

    /// Where a checkbox sits in its cell, for clicks.
    func checkboxRect(in rect: CGRect) -> CGRect {
        let size = min(14 * zoom, rect.height - 4, rect.width - 4)
        return CGRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size).insetBy(dx: -3, dy: -3)
    }

    /// A dropdown cell: a gray chip around the value with a chevron, or just the chevron when empty.
    /// Returns the rectangle the text should use.
    func drawDropdownChip(in rect: CGRect, hasValue: Bool) -> CGRect {
        let chevronWidth = 14 * zoom
        let inset = 3 * zoom
        let chevron = CGRect(x: rect.maxX - inset - chevronWidth, y: rect.minY, width: chevronWidth, height: rect.height)
        if hasValue {
            let chip = rect.insetBy(dx: inset, dy: max(2, (rect.height - 17 * zoom) / 2))
            let path = NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2)
            GridColors.rgb(0xE8EAED).setFill()
            path.fill()
        }
        let arrow = NSBezierPath()
        let size = 3.5 * zoom
        arrow.move(to: CGPoint(x: chevron.midX - size, y: chevron.midY - size / 2))
        arrow.line(to: CGPoint(x: chevron.midX, y: chevron.midY + size / 2))
        arrow.line(to: CGPoint(x: chevron.midX + size, y: chevron.midY - size / 2))
        arrow.lineWidth = 1.5 * zoom
        arrow.lineCapStyle = .round
        GridColors.rgb(0x5F6368).setStroke()
        arrow.stroke()
        return CGRect(x: rect.minX + inset + 4 * zoom, y: rect.minY, width: max(0, chevron.minX - rect.minX - inset - 4 * zoom), height: rect.height)
    }

    /// The filter button in a header cell of the filter range, in view coordinates.
    func filterButtonRect(column: Int) -> CGRect? {
        guard let filter = displayedFilter, filter.range.columns.contains(column), !columns.isHidden(column) else { return nil }
        let header = rect(for: CellRange(CellAddress(row: filter.range.start.row, column: column)))
        let size = min(18 * zoom, header.height - 2)
        return CGRect(x: header.maxX - size - 3 * zoom, y: header.midY - size / 2, width: size, height: size)
    }

    /// Filter buttons (green funnels for columns that hide something) and the filter range's outline.
    func drawFilterDecorations(in pane: Pane) {
        guard let filter = displayedFilter else { return }
        let outline = NSBezierPath(rect: rect(for: filter.range, xMode: pane.xMode, yMode: pane.yMode).offsetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        GridColors.filterGreen.setStroke()
        outline.stroke()
        guard pane.rows.contains(filter.range.start.row) else { return }
        for column in filter.range.columns where pane.columns.contains(column) {
            guard let button = filterButtonRect(column: column) else { continue }
            drawFilterButton(button, active: filter.criteria[column]?.isEmpty == false)
        }
    }

    /// A filter button: three lines, or a funnel when its column hides something. On a colored header
    /// (tables) it sits on a white disc.
    func drawFilterButton(_ button: CGRect, active: Bool, onColor: Bool = false) {
        NSColor.white.withAlphaComponent(onColor ? 1 : 0.9).setFill()
        NSBezierPath(roundedRect: button, xRadius: 3, yRadius: 3).fill()
        let color = active ? GridColors.filterGreen : GridColors.rgb(0x5F6368)
        color.setFill()
        color.setStroke()
        if active {
            // A funnel.
            let funnel = NSBezierPath()
            funnel.move(to: CGPoint(x: button.minX + button.width * 0.2, y: button.minY + button.height * 0.25))
            funnel.line(to: CGPoint(x: button.maxX - button.width * 0.2, y: button.minY + button.height * 0.25))
            funnel.line(to: CGPoint(x: button.midX + button.width * 0.08, y: button.midY + button.height * 0.05))
            funnel.line(to: CGPoint(x: button.midX + button.width * 0.08, y: button.maxY - button.height * 0.2))
            funnel.line(to: CGPoint(x: button.midX - button.width * 0.08, y: button.maxY - button.height * 0.28))
            funnel.line(to: CGPoint(x: button.midX - button.width * 0.08, y: button.midY + button.height * 0.05))
            funnel.close()
            funnel.fill()
        } else {
            // Three lines, shorter each time (a filter icon).
            for (index, fraction) in [0.62, 0.42, 0.22].enumerated() {
                let width = button.width * fraction
                let y = button.minY + button.height * (0.32 + 0.18 * CGFloat(index))
                let line = NSBezierPath()
                line.move(to: CGPoint(x: button.midX - width / 2, y: y))
                line.line(to: CGPoint(x: button.midX + width / 2, y: y))
                line.lineWidth = max(1, 1.5 * zoom)
                line.lineCapStyle = .round
                line.stroke()
            }
        }
    }

    /// The red corner marking errors and invalid values.
    func drawErrorCorner(in rect: CGRect) {
        let size = 6 * zoom
        let corner = NSBezierPath()
        corner.move(to: CGPoint(x: rect.maxX - 1 - size, y: rect.minY))
        corner.line(to: CGPoint(x: rect.maxX - 1, y: rect.minY))
        corner.line(to: CGPoint(x: rect.maxX - 1, y: rect.minY + size))
        corner.close()
        GridColors.error.setFill()
        corner.fill()
    }
}
