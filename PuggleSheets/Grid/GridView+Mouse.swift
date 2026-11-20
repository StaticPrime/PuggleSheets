import AppKit
import PuggleSheetsKit

extension GridView {
    /// Whether the grid's own controls that change the spreadsheet work: resizing columns and rows, the freeze bars,
    /// the fill handle, moving and resizing objects. They don't while it can't be changed, such as a shared spreadsheet
    /// while iCloud can't be reached.
    var canChange: Bool { controller.state.isEditable }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredAddress != nil {
            hoveredAddress = nil
            onHoverCell?(nil)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateCursor(at: point)
        let hovered = hoveredCell(at: point)
        if hovered != hoveredAddress {
            hoveredAddress = hovered
            onHoverCell?(hovered)
        }
        // Hovering an error explains it.
        var tip: String?
        if case .cell(let location) = location(at: point) {
            let address = controller.mergedRange(at: location).start
            if case .error(let error) = sheet.value(at: address) {
                tip = error.message.map { "Error\n\($0)" } ?? error.code
            } else if let rule = sheet.validation(at: address) {
                let invalid = ruleCache.contains { $0.invalid.contains(address) }
                tip = invalid ? "Invalid:\n\(RuleEvaluator.invalidMessage(for: rule))" : rule.helpText
            }
        }
        if toolTip != tip { toolTip = tip }
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at point: CGPoint) {
        if let cursor = objectCursor(at: point) { cursor.set(); return }
        if case .freezing = drag { NSCursor.closedHand.set(); return }
        if canChange, freezeBar(at: point) != nil { NSCursor.openHand.set(); return }
        if case .resizingColumn = drag { NSCursor.resizeLeftRight.set(); return }
        if case .resizingRow = drag { NSCursor.resizeUpDown.set(); return }
        if canChange, columnBoundary(at: point) != nil {
            NSCursor.resizeLeftRight.set()
        } else if canChange, rowBoundary(at: point) != nil {
            NSCursor.resizeUpDown.set()
        } else if canChange, editor == nil, fillHandleRect.contains(point) {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// The freeze bar under `point`, in the headers: true for the bar under the frozen rows, false for
    /// the one right of the frozen columns. With nothing frozen, the bars sit at the corner's edges.
    func freezeBar(at point: CGPoint) -> Bool? {
        let rowBar = frozenRowCount > 0 ? scrollOrigin.y : headerHeight - 2
        if point.x < headerWidth, abs(point.y - rowBar) <= 3 { return true }
        let columnBar = frozenColumnCount > 0 ? scrollOrigin.x : headerWidth - 2
        if point.y < headerHeight, abs(point.x - columnBar) <= 3 { return false }
        return nil
    }

    /// How many rows (or columns) a freeze bar dropped at `position` freezes: the nearest boundary.
    func freezeTarget(rows: Bool, at position: CGFloat) -> Int {
        if rows {
            guard position > headerHeight + 2 else { return 0 }
            guard let row = rowIndex(atViewY: position) else { return sheet.rowCount - 1 }
            let mode = self.mode(forRow: row)
            let top = rowY(row, mode: mode), bottom = rowY(row + 1, mode: mode)
            return min(sheet.rowCount - 1, position - top > bottom - position ? row + 1 : row)
        }
        guard position > headerWidth + 2 else { return 0 }
        let column = columnIndex(atViewX: position)
        let mode = self.mode(forColumn: column)
        let left = columnX(column, mode: mode), right = columnX(column + 1, mode: mode)
        return min(sheet.columnCount - 1, position - left > right - position ? column + 1 : column)
    }

    /// The column whose right edge is under `point` in the column header.
    func columnBoundary(at point: CGPoint) -> Int? {
        guard point.y < headerHeight, point.y >= columnOutlineHeight, point.x > headerWidth + 2 else { return nil }
        let column = columnIndex(atViewX: point.x)
        let mode = self.mode(forColumn: column)
        if abs(point.x - columnX(column + 1, mode: mode)) <= 4 { return column }
        if abs(point.x - columnX(column, mode: mode)) <= 4, column > 0 {
            var previous = column - 1
            while previous > 0, columns.isHidden(previous) { previous -= 1 }
            return previous
        }
        return nil
    }

    /// The row whose bottom edge is under `point` in the row header.
    func rowBoundary(at point: CGPoint) -> Int? {
        guard point.x < headerWidth, point.x >= rowOutlineWidth, point.y > headerHeight + 2, let row = rowIndex(atViewY: point.y) else { return nil }
        let mode = self.mode(forRow: row)
        if abs(point.y - rowY(row + 1, mode: mode)) <= 3 { return row }
        if abs(point.y - rowY(row, mode: mode)) <= 3, row > 0 {
            var previous = row - 1
            while previous > 0, rows.isHidden(previous) { previous -= 1 }
            return previous
        }
        return nil
    }

    // MARK: Clicks and drags

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Typing a formula, clicking a cell inserts its reference instead of ending the entry.
        if let editor, canPoint(in: editor), case .cell(let address) = location(at: point) {
            pointingAnchor = address
            insertPointedReference(controller.mergedRange(at: address), in: editor)
            drag = .pointing
            lastDragEvent = event
            window?.makeFirstResponder(editor)
            return
        }
        if editor != nil { commitEditing() }
        window?.makeFirstResponder(self)
        lastDragEvent = event
        tabStartColumn = nil
        if handleObjectMouseDown(at: point, event: event) { return }
        if let (group, rows) = outlineButton(at: point) {
            controller.toggleGroup(group, rows: rows)
            return
        }
        if isInOutlineBand(point) { return }
        if let control = tableControl(at: point) {
            onTableControl?(control.table.id, control.column, control.rect)
            return
        }
        if let pivot = selectedPivotTable, pivotEditButtonRect(for: pivot).contains(point) {
            onEditPivot?(pivot.id)
            return
        }
        if controller.selectedObjectID != nil { controller.selectedObjectID = nil }
        if let button = footerButtonRect, button.contains(point) {
            controller.addRowsAtBottom(1000)
            return
        }
        if let filter = displayedFilter, case .cell(let address) = location(at: point), address.row == filter.range.start.row,
           let button = filterButtonRect(column: address.column), button.contains(point) {
            onFilterButton?(address.column, button)
            return
        }
        for vertical in [true, false] where scrollTrack(vertical: vertical).contains(point) {
            if let thumb = scrollThumb(vertical: vertical), thumb.contains(point) {
                drag = .scrolling(vertical: vertical, grab: vertical ? point.y - thumb.minY : point.x - thumb.minX)
                needsDisplay = true
            } else {
                pageScroll(vertical: vertical, toward: point)
            }
            return
        }
        if canChange, let rowsBar = freezeBar(at: point) {
            drag = .freezing(rows: rowsBar)
            freezeDragPosition = rowsBar ? point.y : point.x
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }
        let wholeColumns = controller.selection.selectsWholeColumns(rowCount: sheet.rowCount)
        let wholeRows = controller.selection.selectsWholeRows(columnCount: sheet.columnCount)
        if canChange, let column = columnBoundary(at: point) {
            let affected = wholeColumns && controller.selectedColumns.contains(column) ? controller.selectedColumns : [column]
            if event.clickCount == 2 {
                autoFitColumns(affected)
            } else {
                drag = .resizingColumn(column, startX: point.x, startWidth: columns.size(column), columns: affected)
            }
            return
        }
        if canChange, let row = rowBoundary(at: point) {
            let affected = wholeRows && controller.selectedRows.contains(row) ? controller.selectedRows : [row]
            if event.clickCount == 2 {
                autoFitRows(affected)
            } else {
                drag = .resizingRow(row, startY: point.y, startHeight: rows.size(row), rows: affected)
            }
            return
        }
        if canChange, fillHandleRect.contains(point) {
            drag = .filling(source: controller.selection.current, target: controller.selection.current)
            return
        }
        let shift = event.modifierFlags.contains(.shift), command = event.modifierFlags.contains(.command)
        switch location(at: point) {
        case .corner:
            selectAll(nil)
        case .columnHeader(let column):
            let anchor = shift ? controller.selection.anchor.column : column
            selectColumns(from: anchor, to: column, adding: command && !shift)
            drag = .selectingColumns(anchor: anchor)
        case .rowHeader(let row):
            let anchor = shift ? controller.selection.anchor.row : row
            selectRows(from: anchor, to: row, adding: command && !shift)
            drag = .selectingRows(anchor: anchor)
        case .cell(let address):
            if !shift, !command, handleValidationClick(at: address, point: point) { return }
            if event.clickCount == 2, !shift, !command {
                controller.selection = GridSelection(controller.mergedRange(at: address).start)
                beginEditing(entry: .edit)
                return
            }
            var selection = controller.selection
            if shift {
                selection.ranges[selection.ranges.count - 1] = CellRange(selection.anchor, address)
            } else if command {
                selection.ranges.append(CellRange(address))
                selection.active = address
                selection.anchor = address
            } else {
                selection = GridSelection(controller.mergedRange(at: address).start)
                selection.anchor = address
            }
            controller.selection = selection
            drag = .selecting(extendRanges: command)
        case .footer, .outside:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        lastDragEvent = event
        let point = convert(event.locationInWindow, from: nil)
        if case .scrolling(let vertical, let grab) = drag {
            scroll(thumbTo: (vertical ? point.y : point.x) - grab, vertical: vertical)
            return
        }
        if case .pointing = drag, let editor, let anchor = pointingAnchor {
            let range = GridSelection.expanding(CellRange(anchor, clampedAddress(at: point)), toInclude: sheet.merges)
            insertPointedReference(range, in: editor)
            updateAutoscroll(for: point)
            return
        }
        if case .freezing = drag {
            handleDrag(at: point)
            return
        }
        switch drag {
        case .movingObject, .resizingObject:
            handleObjectDrag(to: point)
            return
        default:
            break
        }
        handleDrag(at: point)
        updateAutoscroll(for: point)
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        guard let finished = drag else { return }
        if case .movingObject = finished { finishObjectDrag() }
        if case .resizingObject = finished { finishObjectDrag() }
        drag = nil
        switch finished {
        case .resizingColumn(_, _, _, let affected):
            let size = liveSize?.size
            liveSize = nil
            if let size { controller.setColumnWidths(Dictionary(uniqueKeysWithValues: affected.map { ($0, size) })) } else { reloadLayout() }
        case .resizingRow(_, _, _, let affected):
            let size = liveSize?.size
            liveSize = nil
            if let size { controller.setRowHeights(Dictionary(uniqueKeysWithValues: affected.map { ($0, size) })) } else { reloadLayout() }
        case .filling(let source, let target):
            needsDisplay = true
            controller.autoFill(from: source, to: target)
        case .selecting, .selectingColumns, .selectingRows:
            if let formats = paintFormats {
                controller.paste(formats: formats)
                if !paintFormatSticky {
                    paintFormats = nil
                    controller.state.isPaintFormatActive = false
                }
            }
        case .scrolling:
            break
        case .pointing:
            if let editor { window?.makeFirstResponder(editor) }
        case .freezing(let rowsBar):
            let position = freezeDragPosition ?? 0
            freezeDragPosition = nil
            let count = freezeTarget(rows: rowsBar, at: position)
            if count != (rowsBar ? sheet.frozenRows : sheet.frozenColumns) {
                controller.freeze(rows: rowsBar ? count : nil, columns: rowsBar ? nil : count)
            }
        case .movingObject, .resizingObject:
            break
        }
        needsDisplay = true
    }

    func handleDrag(at point: CGPoint) {
        guard let drag else { return }
        switch drag {
        case .selecting:
            let address = clampedAddress(at: point)
            var selection = controller.selection
            selection.ranges[selection.ranges.count - 1] = CellRange(selection.anchor, address)
            controller.selection = selection
        case .selectingColumns(let anchor):
            selectColumns(from: anchor, to: columnIndex(atViewX: min(max(point.x, headerWidth + 1), gridBounds.maxX - 1)), adding: false)
        case .selectingRows(let anchor):
            selectRows(from: anchor, to: clampedAddress(at: point).row, adding: false)
        case .resizingColumn(let column, let startX, let startWidth, _):
            liveSize = (true, column, max(2, startWidth + Double((point.x - startX) / zoom)))
            reloadLayout()
        case .resizingRow(let row, let startY, let startHeight, _):
            liveSize = (false, row, max(2, startHeight + Double((point.y - startY) / zoom)))
            reloadLayout()
        case .filling(let source, _):
            self.drag = .filling(source: source, target: fillTarget(source: source, to: clampedAddress(at: point)))
            needsDisplay = true
        case .scrolling:
            break
        case .pointing:
            if let editor, let anchor = pointingAnchor {
                insertPointedReference(GridSelection.expanding(CellRange(anchor, clampedAddress(at: point)), toInclude: sheet.merges), in: editor)
            }
        case .freezing(let rowsBar):
            freezeDragPosition = rowsBar ? min(max(point.y, headerHeight), gridBounds.maxY - 2)
                : min(max(point.x, headerWidth), gridBounds.maxX - 2)
            needsDisplay = true
        case .movingObject, .resizingObject:
            handleObjectDrag(to: point)
        }
    }

    /// The fill handle extends the selection along whichever axis the mouse has moved further on.
    func fillTarget(source: CellRange, to address: CellAddress) -> CellRange {
        let below = address.row - source.end.row, above = source.start.row - address.row
        let right = address.column - source.end.column, left = source.start.column - address.column
        let vertical = max(below, above), horizontal = max(right, left)
        guard vertical > 0 || horizontal > 0 else { return source }
        if vertical >= horizontal {
            return below > 0 ? CellRange(source.start, CellAddress(row: address.row, column: source.end.column))
                : CellRange(CellAddress(row: address.row, column: source.start.column), source.end)
        }
        return right > 0 ? CellRange(source.start, CellAddress(row: source.end.row, column: address.column))
            : CellRange(CellAddress(row: source.start.row, column: address.column), source.end)
    }

    func clampedAddress(at point: CGPoint) -> CellAddress {
        let x = min(max(point.x, headerWidth + 1), gridBounds.maxX - 1)
        let y = min(max(point.y, headerHeight + 1), gridBounds.maxY - 1)
        let row = rowIndex(atViewY: y) ?? rows.firstVisible(from: sheet.rowCount - 1)
        return CellAddress(row: row, column: columnIndex(atViewX: x))
    }

    func selectColumns(from anchor: Int, to column: Int, adding: Bool) {
        let range = CellRange(rows: 0...(sheet.rowCount - 1), columns: min(anchor, column)...max(anchor, column))
        var selection = controller.selection
        if adding {
            selection.ranges.append(range)
        } else {
            selection = GridSelection(range: range)
        }
        selection.active = CellAddress(row: adding ? 0 : max(0, rows.firstVisible(from: 0)), column: anchor)
        selection.anchor = CellAddress(row: 0, column: anchor)
        controller.selection = selection
    }

    func selectRows(from anchor: Int, to row: Int, adding: Bool) {
        let range = CellRange(rows: min(anchor, row)...max(anchor, row), columns: 0...(sheet.columnCount - 1))
        var selection = controller.selection
        if adding {
            selection.ranges.append(range)
        } else {
            selection = GridSelection(range: range)
        }
        selection.active = CellAddress(row: anchor, column: columns.firstVisible(from: 0))
        selection.anchor = CellAddress(row: anchor, column: 0)
        controller.selection = selection
    }

    /// Clicking a checkbox ticks it; clicking a dropdown cell's chip or arrow opens its list.
    private func handleValidationClick(at address: CellAddress, point: CGPoint) -> Bool {
        let rect = cellRect(address)
        if controller.checkboxRule(at: address) != nil {
            guard checkboxRect(in: rect).contains(point) else { return false }
            controller.selection = GridSelection(address)
            controller.toggleCheckboxes(at: [address])
            return true
        }
        guard let items = controller.dropdownItems(at: address), let rule = sheet.validation(at: address), rule.showsDropdown else { return false }
        let hasValue = sheet.value(at: address) != .empty
        let arrowArea = CGRect(x: rect.maxX - 22 * zoom, y: rect.minY, width: 22 * zoom, height: rect.height)
        guard hasValue || arrowArea.contains(point) else { return false }
        controller.selection = GridSelection(address)
        // Its list only enters a value, so it doesn't open while the spreadsheet can't be changed.
        guard controller.state.isEditable else {
            controller.refuseChange()
            return true
        }
        showDropdown(items: items, at: address)
        return true
    }

    /// The dropdown list under a cell; choosing an item enters it.
    func showDropdown(items: [String], at address: CellAddress) {
        let menu = NSMenu()
        let current = CellDisplay.text(for: sheet.value(at: address), pattern: nil).text
        for item in items {
            let menuItem = NSMenuItem(title: item, action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
            let handler = MenuAction { [weak self] in self?.controller.commitInput(item, at: address) }
            menuItem.target = handler
            menuItem.representedObject = handler
            menuItem.state = item.caseInsensitiveCompare(current) == .orderedSame ? .on : .off
            menu.addItem(menuItem)
        }
        if items.isEmpty { menu.addItem(NSMenuItem(title: "No items", action: nil, keyEquivalent: "")) }
        let rect = cellRect(address)
        menu.popUp(positioning: nil, at: CGPoint(x: rect.minX, y: rect.maxY + 2), in: self)
    }

    // MARK: Autoscroll

    private var scrollingArea: CGRect {
        CGRect(x: scrollOrigin.x, y: scrollOrigin.y, width: max(0, gridBounds.maxX - scrollOrigin.x),
               height: max(0, gridBounds.maxY - scrollOrigin.y))
    }

    func updateAutoscroll(for point: CGPoint) {
        let area = scrollingArea
        let outside = point.x > area.maxX || point.y > area.maxY || (point.x < area.minX && scrollOffset.x > 0)
            || (point.y < area.minY && scrollOffset.y > 0)
        if outside, autoscrollTimer == nil {
            autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoscrollTick() }
            }
        } else if !outside {
            stopAutoscroll()
        }
    }

    private func autoscrollTick() {
        guard let event = lastDragEvent, drag != nil else {
            stopAutoscroll()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let area = scrollingArea
        var dx: CGFloat = 0, dy: CGFloat = 0
        if point.x > area.maxX { dx = min(80, point.x - area.maxX + 10) } else if point.x < area.minX { dx = -min(80, area.minX - point.x + 10) }
        if point.y > area.maxY { dy = min(80, point.y - area.maxY + 10) } else if point.y < area.minY { dy = -min(80, area.minY - point.y + 10) }
        switch drag {
        case .selectingColumns, .resizingColumn: dy = 0
        case .selectingRows, .resizingRow: dx = 0
        default: break
        }
        setScrollOffset(CGPoint(x: scrollOffset.x + dx / zoom, y: scrollOffset.y + dy / zoom))
        handleDrag(at: point)
    }

    func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    // MARK: Context menus

    override func menu(for event: NSEvent) -> NSMenu? {
        if editor != nil { commitEditing() }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = objectHit(at: point) {
            let id: UUID = switch hit {
            case .body(let id), .menu(let id), .handle(let id, _): id
            }
            controller.selectedObjectID = id
            return objectMenuProvider?(id)
        }
        if controller.selectedObjectID != nil { controller.selectedObjectID = nil }
        let location = location(at: point)
        let selection = controller.selection
        switch location {
        case .cell(let address):
            if !selection.contains(address) { controller.selection = GridSelection(controller.mergedRange(at: address).start) }
        case .columnHeader(let column):
            if !(selection.selectsWholeColumns(rowCount: sheet.rowCount) && controller.selectedColumns.contains(column)) {
                selectColumns(from: column, to: column, adding: false)
            }
        case .rowHeader(let row):
            if !(selection.selectsWholeRows(columnCount: sheet.columnCount) && controller.selectedRows.contains(row)) {
                selectRows(from: row, to: row, adding: false)
            }
        default:
            return nil
        }
        return menuProvider?(location)
    }

    // MARK: Fitting to data

    /// Double-clicking a column edge: as wide as the widest entry (or the default when empty).
    func autoFitColumns(_ indexes: [Int]) {
        var widths: [Int: Double] = [:]
        for column in indexes {
            var widest: CGFloat = 0
            let range = CellRange(rows: 0...(sheet.rowCount - 1), columns: column...column)
            for (address, cell) in sheet.cells(in: range) where cell.hasContent && sheet.merge(containing: address) == nil {
                widest = max(widest, textWidth(cell) / zoom)
            }
            widths[column] = widest > 0 ? Double(ceil(widest + 2 * CellRenderer.horizontalPadding + 3)) : sheet.defaultColumnWidth
        }
        controller.setColumnWidths(widths)
    }

    /// Double-clicking a row edge: tall enough for the tallest entry (never below the default).
    func autoFitRows(_ indexes: [Int]) {
        var heights: [Int: Double] = [:]
        for row in indexes {
            var tallest = CGFloat(sheet.defaultRowHeight)
            let range = CellRange(rows: row...row, columns: 0...(sheet.columnCount - 1))
            for (address, cell) in sheet.cells(in: range) where cell.hasContent && sheet.merge(containing: address) == nil {
                tallest = max(tallest, neededHeight(cell, width: CGFloat(sheet.columnWidth(address.column))))
            }
            heights[row] = Double(ceil(tallest))
        }
        controller.setRowHeights(heights)
    }

    func neededHeight(_ cell: Cell, width: CGFloat) -> CGFloat {
        CellRenderer.neededHeight(cell, width: width)
    }
}
