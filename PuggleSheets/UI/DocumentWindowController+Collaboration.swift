import AppKit
import PuggleSheetsKit
import SwiftUI
import UniformTypeIdentifiers

/// Notes, comments, protected ranges, groups, rotation and Phase 4's data tools: commands, overlays and dialogs.
extension DocumentWindowController {
    // MARK: Notes

    func psInsertNote(_ sender: Any?) {
        finishEditing()
        showNoteEditor(at: controller.selection.active)
    }

    func psClearNotes(_ sender: Any?) { finishEditing(); controller.clearNotes() }

    func showNoteEditor(at address: CellAddress) {
        notePopup?.isHidden = true
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        let view = NoteEditorView(text: controller.sheet[address].note ?? "") { [weak self] text in
            self?.controller.setNote(text, at: address)
        }
        popover.contentViewController = NSHostingController(rootView: view)
        grid.scrollToVisible(address)
        popover.show(relativeTo: grid.cellRect(address), of: grid, preferredEdge: .maxX)
    }

    /// Shows the note of the cell under the mouse, beside the cell.
    func updateNotePopup() {
        guard let contentView = window?.contentView, grid.editor == nil, let address = grid.hoveredAddress,
              let note = controller.sheet.cells[address]?.note else {
            notePopup?.isHidden = true
            return
        }
        let popup: NSHostingView<NotePopupView>
        if let existing = notePopup {
            existing.rootView = NotePopupView(text: note)
            popup = existing
        } else {
            popup = NSHostingView(rootView: NotePopupView(text: note))
            popup.sizingOptions = [.intrinsicContentSize]
            contentView.addSubview(popup, positioned: .above, relativeTo: nil)
            notePopup = popup
        }
        popup.isHidden = false
        place(popup, besideCell: address, in: contentView)
    }

    /// Puts an overlay to the right of a cell, top-aligned, keeping it inside the window.
    private func place(_ overlay: NSView, besideCell address: CellAddress, in contentView: NSView) {
        let size = overlay.fittingSize
        let cell = contentView.convert(grid.cellRect(address), from: grid)
        var frame = NSRect(x: cell.maxX - 2, y: 0, width: size.width, height: size.height)
        frame.origin.y = contentView.isFlipped ? cell.minY - 6 : cell.maxY - size.height + 6
        if frame.maxX > contentView.bounds.maxX { frame.origin.x = max(0, cell.minX - size.width + 2) }
        frame.origin.y = max(0, min(frame.origin.y, contentView.bounds.maxY - size.height))
        overlay.frame = frame
    }

    // MARK: Comments

    func psInsertComment(_ sender: Any?) {
        finishEditing()
        composingComment = controller.selection.active
        updateCommentCard()
    }

    func psShowComments(_ sender: Any?) { showComments() }

    func showComments() {
        finishEditing()
        showSidebar(.comments)
    }

    /// The thread of the active cell beside it (or the composer for a new comment).
    func updateCommentCard() {
        let address = controller.selection.active
        if let composing = composingComment, composing != address { composingComment = nil }
        guard let contentView = window?.contentView, grid.editor == nil, controller.selectedObjectID == nil,
              controller.selection.ranges.count == 1 else {
            commentCard?.isHidden = true
            return
        }
        let thread = controller.sheet.cells[address]?.comment
        let showsThread = thread.map { !$0.isResolved } ?? false
        guard showsThread || composingComment == address else {
            commentCard?.isHidden = true
            return
        }
        let view = CommentCardView(thread: showsThread ? thread : nil, author: controller.commentAuthor,
                                   post: { [weak self] text in
                                       self?.composingComment = nil
                                       self?.controller.addComment(text, at: address)
                                   },
                                   edit: { [weak self] id, text in self?.controller.editComment(id, text: text, at: address) },
                                   delete: { [weak self] id in self?.controller.deleteComment(id, at: address) },
                                   resolve: { [weak self] in self?.controller.setCommentResolved(true, at: address) },
                                   close: { [weak self] in
                                       self?.composingComment = nil
                                       self?.updateCommentCard()
                                       self?.focusGrid()
                                   })
        let card: NSHostingView<CommentCardView>
        if let existing = commentCard {
            existing.rootView = view
            card = existing
        } else {
            card = NSHostingView(rootView: view)
            card.sizingOptions = [.intrinsicContentSize]
            contentView.addSubview(card, positioned: .above, relativeTo: nil)
            commentCard = card
        }
        card.isHidden = !grid.gridBounds.intersects(grid.cellRect(address))
        place(card, besideCell: address, in: contentView)
    }

    /// Selects a comment's cell (from the comments panel).
    func openComment(sheetIndex: Int, address: CellAddress) {
        controller.showSheet(id: controller.workbook.sheets[sheetIndex].id)
        controller.selection = GridSelection(address)
        grid.scrollToVisible(address)
    }

    // MARK: Protected sheets and ranges

    func psProtect(_ sender: Any?) { finishEditing(); showSidebar(.protections) }

    /// The dialogs for protected cells: a warning that can be dismissed, or a refusal.
    func askAboutProtectedEdit(_ protection: ProtectedRange) -> ProtectionAnswer {
        let alert = NSAlert()
        let name = protection.description.isEmpty ? "" : " (“\(protection.description)”)"
        if protection.warningOnly {
            alert.messageText = "Heads up!"
            alert.informativeText = "You’re trying to edit part of this sheet that shouldn’t be changed accidentally\(name). Edit anyway?"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don’t show this again for 5 minutes"
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return .cancel }
            return alert.suppressionButton?.state == .on ? .proceedQuietly : .proceed
        }
        alert.messageText = "This range is protected"
        alert.informativeText = "You’re trying to edit a protected cell or object\(name). Remove its protection in Data ▸ Protect sheets and ranges to edit it."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return .cancel
    }

    func psToggleShowProtectedRanges(_ sender: Any?) {
        grid.showsProtectedRanges.toggle()
    }

    // MARK: View ▸ Show ▸ Formulas

    func psToggleShowFormulas(_ sender: Any?) {
        finishEditing()
        grid.showsFormulas.toggle()
    }

    // MARK: Groups

    /// ⌥⇧→: groups the selected rows, or columns when whole columns are selected.
    func psGroup(_ sender: Any?) {
        finishEditing()
        if controller.selection.selectsWholeColumns(rowCount: controller.sheet.rowCount) { controller.groupColumns() } else { controller.groupRows() }
    }

    /// ⌥⇧←.
    func psUngroup(_ sender: Any?) {
        finishEditing()
        if controller.selection.selectsWholeColumns(rowCount: controller.sheet.rowCount) { controller.ungroupColumns() } else { controller.ungroupRows() }
    }

    func psGroupRows(_ sender: Any?) { finishEditing(); controller.groupRows() }
    func psUngroupRows(_ sender: Any?) { finishEditing(); controller.ungroupRows() }
    func psGroupColumns(_ sender: Any?) { finishEditing(); controller.groupColumns() }
    func psUngroupColumns(_ sender: Any?) { finishEditing(); controller.ungroupColumns() }
    func psExpandAllGroups(_ sender: Any?) { controller.setAllGroupsCollapsed(false, rows: true); controller.setAllGroupsCollapsed(false, rows: false) }
    func psCollapseAllGroups(_ sender: Any?) { controller.setAllGroupsCollapsed(true, rows: true); controller.setAllGroupsCollapsed(true, rows: false) }

    // MARK: Rotation

    /// Format ▸ Rotation: the tag is the angle, 1000 for stacked, 0 for none and 2000 for a custom angle.
    func psRotation(_ sender: Any?) {
        finishEditing()
        guard let tag = (sender as? NSMenuItem)?.tag else { return }
        switch tag {
        case 0: controller.setTextRotation(nil)
        case 1000: controller.setTextRotation(.stacked)
        case 2000: askForRotationAngle()
        default: controller.setTextRotation(.angle(min(90, max(-90, tag))))
        }
    }

    private func askForRotationAngle() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Custom angle"
        alert.informativeText = "Enter an angle from -90° to 90°. Positive angles tilt the text up."
        var current = 0
        if case .angle(let degrees)? = state.summary.format.textRotation { current = degrees }
        let field = NSTextField(string: String(current))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let degrees = Int(field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "°", with: "")) else { return }
            self?.controller.setTextRotation(degrees == 0 ? nil : .angle(min(90, max(-90, degrees))))
        }
    }

    // MARK: Data tools

    func psRandomizeRange(_ sender: Any?) { finishEditing(); controller.randomizeRange() }
    func psColumnStats(_ sender: Any?) { finishEditing(); showSidebar(.columnStats) }
    func psPasteTransposed(_ sender: Any?) { finishEditing(); controller.paste(.transposed) }

    // MARK: Import

    func psImport(_ sender: Any?) {
        finishEditing()
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SpreadsheetFileFormat.allCases.compactMap { UTType($0.typeIdentifier) }
        panel.message = "Choose a spreadsheet, CSV or TSV file to import"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            let format = SpreadsheetFileFormat(typeName: url.pathExtension.lowercased()) ?? .csv
            let delimited = format == .csv || format == .tsv
            DispatchQueue.main.async {
                self.presentSheet { dismiss in
                    ImportView(fileName: url.lastPathComponent, delimited: delimited) { location, tabs in
                        dismiss()
                        guard let location else { return }
                        self.importFile(data, format: format, tabs: tabs, name: url.deletingPathExtension().lastPathComponent, location: location)
                    }
                }
            }
        }
    }

    private func importFile(_ data: Data, format: SpreadsheetFileFormat, tabs: Bool?, name: String, location: ImportLocation) {
        var readFormat = format
        if format == .csv || format == .tsv {
            if let tabs {
                readFormat = tabs ? .tsv : .csv
            } else {
                // Detect: more tabs than commas in the first line means tab-separated.
                let firstLine = String(decoding: data.prefix(4096), as: UTF8.self).split(separator: "\n").first ?? ""
                readFormat = firstLine.filter { $0 == "\t" }.count > firstLine.filter { $0 == "," }.count ? .tsv : .csv
            }
        }
        let file: SpreadsheetFile
        do {
            file = try SpreadsheetIO.read(data, format: readFormat)
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
            return
        }
        if location == .newSpreadsheet {
            guard let document = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(false) as? SpreadsheetDocument else { return }
            document.workbook = file.workbook
            document.makeWindowControllers()
            document.showWindows()
            (document.windowControllers.first as? DocumentWindowController)?.controller.reloadFromDocument()
            return
        }
        controller.importWorkbook(file.workbook, name: name, location: location)
    }
}

extension SpreadsheetController {
    /// File ▸ Import: puts an imported workbook (or its first sheet) where the person chose.
    func importWorkbook(_ imported: Workbook, name: String, location: ImportLocation) {
        let index = activeSheetIndex
        switch location {
        case .newSpreadsheet:
            return
        case .insertSheets:
            // Imported sheets keep their names unless they clash; renaming through the workbook keeps
            // their formulas pointing at each other.
            var book = imported
            var taken = Set(workbook.sheets.map { $0.name.lowercased() })
            for sheetIndex in book.sheets.indices {
                let original = book.sheets[sheetIndex].name
                let base = book.sheets.count == 1 && original.hasPrefix("Sheet") ? name : original
                var candidate = base
                var number = 2
                while taken.contains(candidate.lowercased()) {
                    candidate = "\(base) (\(number))"
                    number += 1
                }
                taken.insert(candidate.lowercased())
                if candidate != original { book.renameSheet(at: sheetIndex, to: candidate) }
            }
            let sheets = book.sheets
            performWorkbookEdit(actionName: "Import", showing: sheets.first?.id) { workbook in
                workbook.sheets.insert(contentsOf: sheets, at: index + 1)
                workbook.namedRanges += book.namedRanges.filter { workbook.namedRange($0.name) == nil }
            }
        case .replaceSpreadsheet:
            let first = imported.sheets.first?.id
            performWorkbookEdit(actionName: "Import", selection: GridSelection(CellAddress(row: 0, column: 0)), showing: first) { workbook in
                workbook = imported
            }
        case .replaceSheet, .appendToSheet, .replaceAtSelection:
            guard let source = imported.sheets.first else { return }
            let current = sheet
            let origin: CellAddress = switch location {
            case .appendToSheet: CellAddress(row: (current.contentRange?.end.row ?? -1) + 1, column: 0)
            case .replaceAtSelection: selection.active
            default: CellAddress(row: 0, column: 0)
            }
            performWorkbookEdit(actionName: "Import", selection: GridSelection(origin)) { workbook in
                var target = workbook.sheets[index]
                if location == .replaceSheet {
                    for (address, _) in target.cells { target[address] = Cell() }
                }
                var updates: [CellAddress: Cell] = [:]
                var lastRow = 0, lastColumn = 0
                for (address, cell) in source.cells {
                    let moved = address.offsetBy(rows: origin.row, columns: origin.column)
                    updates[moved] = cell
                    lastRow = max(lastRow, moved.row)
                    lastColumn = max(lastColumn, moved.column)
                }
                target.rowCount = max(target.rowCount, lastRow + 1)
                target.columnCount = max(target.columnCount, lastColumn + 1)
                target.setCells(updates)
                workbook.sheets[index] = target
            }
        }
    }
}
