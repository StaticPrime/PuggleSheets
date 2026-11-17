import AppKit
import PuggleSheetsKit

extension GridView {
    override func keyDown(with event: NSEvent) {
        if controller.selectedObjectID != nil, handleObjectKey(event) { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .option, let key = event.specialKey, key == .downArrow || key == .upArrow {
            switchSheet(by: key == .downArrow ? 1 : -1)
            return
        }
        if event.charactersIgnoringModifiers == " " {
            if flags == .shift { selectWholeRows(); return }
            if flags == .control { selectWholeColumns(); return }
            // Space ticks the selected checkboxes.
            if flags.isEmpty, controller.checkboxRule(at: controller.selection.active) != nil {
                controller.toggleCheckboxes(at: controller.selection.ranges.flatMap(\.addresses))
                return
            }
        }
        if flags.contains(.command), let key = event.specialKey {
            if key == .home { go(to: CellAddress(row: 0, column: 0), extend: flags.contains(.shift)); return }
            if key == .end { go(to: lastDataCell, extend: flags.contains(.shift)); return }
        }
        if event.specialKey == .f2 {
            beginEditing(entry: .edit)
            return
        }
        if startsTyping(event, flags: flags) {
            beginEditing(replacingWith: "", entry: .replace)
            editor?.keyDown(with: event)
            return
        }
        interpretKeyEvents([event])
    }

    /// Whether a key produces text (and so starts an entry), as opposed to moving or commanding.
    private func startsTyping(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard !flags.contains(.command), !flags.contains(.control), event.specialKey == nil,
              let scalar = event.characters?.unicodeScalars.first else { return false }
        return scalar.value >= 0x20 && scalar.value != 0x7F
    }

    // MARK: Moving

    private var activeSheet: Sheet { controller.sheet }

    /// One step from `address`, past merged blocks and hidden rows and columns.
    func step(from address: CellAddress, rows dr: Int, columns dc: Int) -> CellAddress {
        let merged = controller.mergedRange(at: address)
        var next = address
        // At the sheet's edge `step` returns its starting point, which means "don't move".
        if dr != 0 {
            let edge = dr > 0 ? merged.end.row : merged.start.row
            let row = rows.step(from: edge, by: dr > 0 ? 1 : -1)
            if row != edge { next.row = row }
        }
        if dc != 0 {
            let edge = dc > 0 ? merged.end.column : merged.start.column
            let column = columns.step(from: edge, by: dc > 0 ? 1 : -1)
            if column != edge { next.column = column }
        }
        return next
    }

    /// ⌘arrow: to the edge of the block of data, or to the next filled cell.
    func dataEdge(from address: CellAddress, rows dr: Int, columns dc: Int) -> CellAddress {
        func filled(_ address: CellAddress) -> Bool {
            activeSheet.cells[address]?.hasContent ?? false || activeSheet.spilledValues[address] != nil
        }
        var probe = step(from: address, rows: dr, columns: dc)
        guard probe != address else { return address }
        if filled(address) && filled(probe) {
            while true {
                let after = step(from: probe, rows: dr, columns: dc)
                if after == probe || !filled(after) { return probe }
                probe = after
            }
        }
        while !filled(probe) {
            let after = step(from: probe, rows: dr, columns: dc)
            if after == probe { return probe }
            probe = after
        }
        return probe
    }

    /// Moves the active cell, or with `extend` grows the current range's far corner.
    func move(rows dr: Int, columns dc: Int, extend: Bool, toEdge: Bool = false) {
        tabStartColumn = nil
        var selection = controller.selection
        if extend {
            let range = selection.current
            let corner = CellAddress(row: range.start.row == selection.anchor.row ? range.end.row : range.start.row,
                                     column: range.start.column == selection.anchor.column ? range.end.column : range.start.column)
            let target = toEdge ? dataEdge(from: corner, rows: dr, columns: dc) : extendedCorner(corner, rows: dr, columns: dc)
            selection.ranges[selection.ranges.count - 1] = CellRange(selection.anchor, target)
            controller.selection = selection
            scrollToVisible(target)
        } else {
            let target = toEdge ? dataEdge(from: selection.active, rows: dr, columns: dc) : step(from: selection.active, rows: dr, columns: dc)
            go(to: target, extend: false)
        }
    }

    private func extendedCorner(_ corner: CellAddress, rows dr: Int, columns dc: Int) -> CellAddress {
        var next = corner
        if dr != 0 { next.row = rows.step(from: corner.row, by: dr) }
        if dc != 0 { next.column = columns.step(from: corner.column, by: dc) }
        return next
    }

    /// Selects one cell (or extends to it) and scrolls it into view.
    func go(to address: CellAddress, extend: Bool) {
        if extend {
            var selection = controller.selection
            selection.ranges[selection.ranges.count - 1] = CellRange(selection.anchor, address)
            controller.selection = selection
        } else {
            let start = controller.mergedRange(at: address).start
            controller.selection = GridSelection(start)
        }
        scrollToVisible(address)
    }

    /// The last row and column with data (⌘End).
    var lastDataCell: CellAddress {
        activeSheet.contentRange?.end ?? CellAddress(row: 0, column: 0)
    }

    override func moveUp(_ sender: Any?) { move(rows: -1, columns: 0, extend: false) }
    override func moveDown(_ sender: Any?) { move(rows: 1, columns: 0, extend: false) }
    override func moveLeft(_ sender: Any?) { move(rows: 0, columns: -1, extend: false) }
    override func moveRight(_ sender: Any?) { move(rows: 0, columns: 1, extend: false) }
    override func moveUpAndModifySelection(_ sender: Any?) { move(rows: -1, columns: 0, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { move(rows: 1, columns: 0, extend: true) }
    override func moveLeftAndModifySelection(_ sender: Any?) { move(rows: 0, columns: -1, extend: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { move(rows: 0, columns: 1, extend: true) }

    override func moveToBeginningOfDocument(_ sender: Any?) { move(rows: -1, columns: 0, extend: false, toEdge: true) }
    override func moveToEndOfDocument(_ sender: Any?) { move(rows: 1, columns: 0, extend: false, toEdge: true) }
    override func moveToBeginningOfLine(_ sender: Any?) { move(rows: 0, columns: -1, extend: false, toEdge: true) }
    override func moveToEndOfLine(_ sender: Any?) { move(rows: 0, columns: 1, extend: false, toEdge: true) }
    override func moveToLeftEndOfLine(_ sender: Any?) { moveToBeginningOfLine(sender) }
    override func moveToRightEndOfLine(_ sender: Any?) { moveToEndOfLine(sender) }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { move(rows: -1, columns: 0, extend: true, toEdge: true) }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { move(rows: 1, columns: 0, extend: true, toEdge: true) }
    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { move(rows: 0, columns: -1, extend: true, toEdge: true) }
    override func moveToEndOfLineAndModifySelection(_ sender: Any?) { move(rows: 0, columns: 1, extend: true, toEdge: true) }
    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { moveToBeginningOfLineAndModifySelection(sender) }
    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { moveToEndOfLineAndModifySelection(sender) }

    override func pageDown(_ sender: Any?) { page(by: 1) }
    override func pageUp(_ sender: Any?) { page(by: -1) }
    override func scrollPageDown(_ sender: Any?) { page(by: 1) }
    override func scrollPageUp(_ sender: Any?) { page(by: -1) }

    private func page(by direction: Int) {
        let count = rowsPerPage
        let active = controller.selection.active
        let row = min(max(active.row + direction * count, 0), activeSheet.rowCount - 1)
        setScrollOffset(CGPoint(x: scrollOffset.x, y: scrollOffset.y + CGFloat(direction * count) * CGFloat(activeSheet.defaultRowHeight)))
        go(to: CellAddress(row: rows.firstVisible(from: row), column: active.column), extend: false)
    }

    /// Home and End: the start of the row and its last filled cell.
    override func scrollToBeginningOfDocument(_ sender: Any?) {
        go(to: CellAddress(row: controller.selection.active.row, column: columns.firstVisible(from: 0)), extend: false)
    }

    override func scrollToEndOfDocument(_ sender: Any?) {
        let row = controller.selection.active.row
        let last = activeSheet.cells(in: CellRange(rows: row...row, columns: 0...(activeSheet.columnCount - 1)))
            .filter { $0.cell.hasContent }.map(\.address.column).max() ?? 0
        go(to: CellAddress(row: row, column: last), extend: false)
    }

    // MARK: Entering

    /// Return on a selected cell edits it; Shift-Return moves up.
    override func insertNewline(_ sender: Any?) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            controller.selection = selection(after: .up, from: controller.selection.active)
        } else {
            beginEditing(entry: .edit)
        }
    }

    override func insertTab(_ sender: Any?) {
        controller.selection = selection(after: .right, from: controller.selection.active)
        scrollToVisible(controller.selection.active)
    }

    override func insertBacktab(_ sender: Any?) {
        controller.selection = selection(after: .left, from: controller.selection.active)
        scrollToVisible(controller.selection.active)
    }

    override func deleteBackward(_ sender: Any?) { controller.clearContents() }
    override func deleteForward(_ sender: Any?) { controller.clearContents() }

    /// Esc: forget the cut and stop painting formats.
    override func cancelOperation(_ sender: Any?) {
        controller.cutRange = nil
        paintFormats = nil
        controller.state.isPaintFormatActive = false
    }

    override func insertText(_ insertString: Any) {
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        guard !text.isEmpty else { return }
        beginEditing(replacingWith: text, entry: .replace)
    }

    @objc override func selectAll(_ sender: Any?) {
        let sheet = activeSheet
        var selection = GridSelection(range: CellRange(rows: 0...(sheet.rowCount - 1), columns: 0...(sheet.columnCount - 1)),
                                      active: controller.selection.active)
        selection.anchor = CellAddress(row: 0, column: 0)
        controller.selection = selection
    }

    func selectWholeRows() {
        let range = controller.selection.current
        var selection = GridSelection(range: CellRange(rows: range.rows, columns: 0...(activeSheet.columnCount - 1)),
                                      active: controller.selection.active)
        selection.anchor = CellAddress(row: range.start.row, column: 0)
        controller.selection = selection
    }

    func selectWholeColumns() {
        let range = controller.selection.current
        var selection = GridSelection(range: CellRange(rows: 0...(activeSheet.rowCount - 1), columns: range.columns),
                                      active: controller.selection.active)
        selection.anchor = CellAddress(row: 0, column: range.start.column)
        controller.selection = selection
    }

    func switchSheet(by offset: Int) {
        let sheets = controller.workbook.sheets
        let index = controller.activeSheetIndex + offset
        guard index >= 0, index < sheets.count else { return }
        controller.showSheet(id: sheets[index].id)
    }
}
