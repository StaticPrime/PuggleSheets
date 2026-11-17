import AppKit
import PuggleSheetsKit

/// What a protected range says about an edit: go ahead, or don't.
enum ProtectionAnswer {
    case proceed
    /// Go ahead, and don't warn again for five minutes (the dialog's checkbox).
    case proceedQuietly
    case cancel
}

/// Phase 4's edits: notes, comments, protected ranges, row and column groups, rotation, and a few data tools.
extension SpreadsheetController {
    // MARK: Notes

    /// Insert ▸ Note: sets or (with empty text) removes a cell's note.
    func setNote(_ note: String?, at address: CellAddress) {
        var cell = sheet[address]
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = (trimmed?.isEmpty ?? true) ? nil : note
        guard cell.note != new else { return }
        cell.note = new
        perform([.cells(sheet: activeSheetID, [address: cell])], actionName: new == nil ? "Clear Note" : "Note")
    }

    /// Removes the notes in the selected cells.
    func clearNotes() {
        var updates: [CellAddress: Cell] = [:]
        for range in selection.ranges {
            for (address, cell) in sheet.cells(in: range) where cell.note != nil {
                var copy = cell
                copy.note = nil
                updates[address] = copy
            }
        }
        guard !updates.isEmpty else { return }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Clear Notes")
    }

    // MARK: Comments

    /// The name comments are signed with: the Mac user's full name.
    var commentAuthor: String {
        let name = NSFullUserName()
        return name.isEmpty ? NSUserName() : name
    }

    /// Starts a thread on the cell, or replies to its thread.
    func addComment(_ text: String, at address: CellAddress) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var cell = sheet[address]
        let comment = Comment(author: commentAuthor, text: trimmed)
        if var thread = cell.comment {
            thread.comments.append(comment)
            thread.isResolved = false
            cell.comment = thread
        } else {
            cell.comment = CommentThread(comments: [comment])
        }
        perform([.cells(sheet: activeSheetID, [address: cell])], actionName: "Comment")
    }

    func editComment(_ id: UUID, text: String, at address: CellAddress) {
        var cell = sheet[address]
        guard var thread = cell.comment, let index = thread.comments.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != thread.comments[index].text else { return }
        thread.comments[index].text = trimmed
        thread.comments[index].editedDate = Date()
        cell.comment = thread
        perform([.cells(sheet: activeSheetID, [address: cell])], actionName: "Edit Comment")
    }

    /// Deletes a reply, or the whole thread when it's the first comment.
    func deleteComment(_ id: UUID, at address: CellAddress) {
        var cell = sheet[address]
        guard var thread = cell.comment else { return }
        if thread.comments.first?.id == id {
            cell.comment = nil
        } else {
            thread.comments.removeAll { $0.id == id }
            cell.comment = thread
        }
        perform([.cells(sheet: activeSheetID, [address: cell])], actionName: "Delete Comment")
    }

    func setCommentResolved(_ resolved: Bool, at address: CellAddress) {
        var cell = sheet[address]
        guard var thread = cell.comment, thread.isResolved != resolved else { return }
        thread.isResolved = resolved
        cell.comment = thread
        perform([.cells(sheet: activeSheetID, [address: cell])], actionName: resolved ? "Resolve Comment" : "Reopen Comment")
    }

    /// Every comment thread in the workbook, sheet by sheet in row order.
    func commentThreads() -> [(sheetIndex: Int, address: CellAddress, thread: CommentThread)] {
        workbook.sheets.enumerated().flatMap { index, sheet in
            sheet.cells.compactMap { address, cell in cell.comment.map { (index, address, $0) } }
                .sorted { $0.1 < $1.1 }
        }
    }

    // MARK: Protected sheets and ranges

    /// Adds or replaces a protection.
    func setProtection(_ protection: ProtectedRange) {
        performLayoutEdit(actionName: "Protect Range") { layout in
            if let index = layout.protections.firstIndex(where: { $0.id == protection.id }) {
                layout.protections[index] = protection
            } else {
                layout.protections.append(protection)
            }
        }
    }

    func removeProtection(id: UUID) {
        performLayoutEdit(actionName: "Remove Protection") { $0.protections.removeAll { $0.id == id } }
    }

    /// Whether an edit to these cells may go ahead: restricting protections refuse it, warning ones
    /// ask first (unless warnings were turned off for five minutes).
    func protectionAllows(_ touched: [(sheetID: UUID, addresses: [CellAddress])]) -> Bool {
        var warning: ProtectedRange?
        for (sheetID, addresses) in touched {
            guard let index = workbook.sheetIndex(id: sheetID), !workbook.sheets[index].protections.isEmpty else { continue }
            let sheet = workbook.sheets[index]
            for address in addresses {
                guard let protection = sheet.protection(covering: address) else { continue }
                if !protection.warningOnly {
                    _ = onProtectedEdit?(protection)
                    return false
                }
                if warning == nil { warning = protection }
            }
        }
        guard let warning else { return true }
        if let until = protectionWarningsSilencedUntil, until > Date() { return true }
        switch onProtectedEdit?(warning) ?? .proceed {
        case .proceed: return true
        case .proceedQuietly:
            protectionWarningsSilencedUntil = Date().addingTimeInterval(5 * 60)
            return true
        case .cancel: return false
        }
    }

    /// Whether a structural edit (inserting or deleting rows, columns or cells) may change `range`.
    func protectionAllows(range: CellRange) -> Bool {
        guard !sheet.protections.isEmpty else { return true }
        let hits = sheet.protections.filter { $0.covers(anyOf: range) }
        guard !hits.isEmpty else { return true }
        let sample = hits.contains { !$0.warningOnly } ? [hits.first { !$0.warningOnly }!] : hits
        // Check one protected cell of the range against the usual rules.
        let address: CellAddress = {
            switch sample[0].scope {
            case .range(let protected): return protected.intersection(range)?.start ?? range.start
            case .sheet: return range.start
            }
        }()
        return protectionAllows([(activeSheetID, [address])])
    }

    // MARK: Row and column groups

    /// Data ▸ Group rows (⌥⇧→): groups the selected rows, inside any group that holds them.
    func groupRows() { group(rows: true) }
    func groupColumns() { group(rows: false) }

    private func group(rows: Bool) {
        let indexes = rows ? selectedRows : selectedColumns
        guard let first = indexes.first, let last = indexes.last else { return }
        let range = first...last
        performLayoutEdit(actionName: rows ? "Group Rows" : "Group Columns") { layout in
            var groups = rows ? layout.rowGroups : layout.columnGroups
            guard !groups.contains(where: { $0.range == range }) else { return }
            groups.append(OutlineGroup(range: range))
            groups.sort { ($0.range.lowerBound, -$0.range.count) < ($1.range.lowerBound, -$1.range.count) }
            if rows { layout.rowGroups = groups } else { layout.columnGroups = groups }
        }
    }

    /// Data ▸ Ungroup rows (⌥⇧←): removes groups inside the selection, or the innermost one around it.
    func ungroupRows() { ungroup(rows: true) }
    func ungroupColumns() { ungroup(rows: false) }

    private func ungroup(rows: Bool) {
        let indexes = rows ? selectedRows : selectedColumns
        guard let first = indexes.first, let last = indexes.last else { return }
        performLayoutEdit(actionName: rows ? "Ungroup Rows" : "Ungroup Columns") { layout in
            var groups = rows ? layout.rowGroups : layout.columnGroups
            let inside = groups.filter { $0.range.lowerBound >= first && $0.range.upperBound <= last }
            if !inside.isEmpty {
                groups.removeAll { inside.contains($0) }
            } else if let innermost = groups.filter({ $0.range.lowerBound <= first && $0.range.upperBound >= last })
                .min(by: { $0.range.count < $1.range.count }) {
                groups.removeAll { $0 == innermost }
            }
            if rows { layout.rowGroups = groups } else { layout.columnGroups = groups }
        }
    }

    /// The + / − buttons: collapses or expands one group.
    func toggleGroup(_ group: OutlineGroup, rows: Bool) {
        performLayoutEdit(actionName: group.isCollapsed ? "Expand Group" : "Collapse Group") { layout in
            var groups = rows ? layout.rowGroups : layout.columnGroups
            guard let index = groups.firstIndex(of: group) else { return }
            groups[index].isCollapsed.toggle()
            if rows { layout.rowGroups = groups } else { layout.columnGroups = groups }
        }
    }

    /// Expands or collapses every group on an axis.
    func setAllGroupsCollapsed(_ collapsed: Bool, rows: Bool) {
        performLayoutEdit(actionName: collapsed ? "Collapse All Groups" : "Expand All Groups") { layout in
            if rows {
                layout.rowGroups = layout.rowGroups.map { OutlineGroup(range: $0.range, isCollapsed: collapsed) }
            } else {
                layout.columnGroups = layout.columnGroups.map { OutlineGroup(range: $0.range, isCollapsed: collapsed) }
            }
        }
    }

    // MARK: Text rotation

    /// Format ▸ Rotation.
    func setTextRotation(_ rotation: TextRotation?) {
        updateFormat(actionName: "Text Rotation") { $0.textRotation = rotation }
    }

    // MARK: Data tools

    /// Data ▸ Randomize range: shuffles the selected rows.
    func randomizeRange() {
        let range = selection.current
        guard range.rowCount > 1 else { return }
        let sheet = self.sheet
        var order = Array(range.rows)
        order.shuffle()
        var updates: [CellAddress: Cell] = [:]
        for (offset, sourceRow) in order.enumerated() {
            let targetRow = range.start.row + offset
            for column in range.columns {
                updates[CellAddress(row: targetRow, column: column)] = sheet[CellAddress(row: sourceRow, column: column)]
            }
        }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Randomize Range")
    }

    /// Paste special ▸ Transposed: rows become columns. Formulas shift as if each cell moved to its new place.
    func pasteTransposed(_ cells: [[Cell]], source: CellRange) {
        guard let width = cells.first?.count, width > 0 else { return }
        let origin = selection.current.start
        var updates: [CellAddress: Cell] = [:]
        for (rowOffset, row) in cells.enumerated() {
            for (columnOffset, copied) in row.enumerated() {
                let target = origin.offsetBy(rows: columnOffset, columns: rowOffset)
                let from = source.start.offsetBy(rows: rowOffset, columns: columnOffset)
                updates[target] = translated(copied, rows: target.row - from.row, columns: target.column - from.column)
            }
        }
        var changes: [WorkbookChange] = []
        var layout = SheetLayout(sheet)
        layout.rowCount = max(layout.rowCount, origin.row + width)
        layout.columnCount = max(layout.columnCount, origin.column + cells.count)
        if layout != SheetLayout(sheet) { changes.append(.layout(sheet: activeSheetID, layout)) }
        changes.append(.cells(sheet: activeSheetID, updates))
        let pasted = CellRange(origin, origin.offsetBy(rows: width - 1, columns: cells.count - 1))
        perform(changes, actionName: "Paste Transposed", selection: GridSelection(range: pasted, active: origin))
    }
}
