import AppKit
import PuggleSheetsKit
import SwiftUI
import UniformTypeIdentifiers

extension DocumentWindowController: SheetCommands, NSMenuItemValidation {
    // MARK: Clipboard

    @objc func copy(_ sender: Any?) {
        finishEditing()
        if let id = controller.selectedObjectID { return copyObject(id: id, cut: false) }
        guard controller.selection.ranges.count == 1 else { return beepMultipleSelection() }
        controller.copySelection()
    }

    @objc func cut(_ sender: Any?) {
        finishEditing()
        if let id = controller.selectedObjectID { return copyObject(id: id, cut: true) }
        guard controller.selection.ranges.count == 1 else { return beepMultipleSelection() }
        controller.copySelection(cut: true)
    }

    @objc func paste(_ sender: Any?) {
        finishEditing()
        if pasteObjectOrImage() { return }
        controller.paste(.normal)
    }

    @objc func delete(_ sender: Any?) {
        finishEditing()
        if let id = controller.selectedObjectID { return controller.removeObject(id: id) }
        controller.clearContents()
    }

    private func beepMultipleSelection() {
        let alert = NSAlert()
        alert.messageText = "This action won’t work on multiple selections."
        alert.beginSheetModal(for: window!)
    }

    func psPasteValues(_ sender: Any?) { finishEditing(); controller.paste(.valuesOnly) }
    func psPasteFormat(_ sender: Any?) { finishEditing(); controller.paste(.formatOnly) }
    func psDeleteValues(_ sender: Any?) {
        finishEditing()
        if let id = controller.selectedObjectID { return controller.removeObject(id: id) }
        controller.clearContents()
    }
    func psInsertCellsShiftRight(_ sender: Any?) { finishEditing(); controller.insertCells(shiftDown: false) }
    func psInsertCellsShiftDown(_ sender: Any?) { finishEditing(); controller.insertCells(shiftDown: true) }
    func psDeleteCellsShiftLeft(_ sender: Any?) { finishEditing(); controller.deleteCells(shiftUp: false) }
    func psDeleteCellsShiftUp(_ sender: Any?) { finishEditing(); controller.deleteCells(shiftUp: true) }

    func psSplitTextToColumns(_ sender: Any?) {
        finishEditing()
        if let problem = controller.splitProblem { return showProblem(problem) }
        let range = controller.selection.current
        guard let used = controller.splitTextToColumns(separator: nil) else {
            return showProblem("There’s no text with a comma, semicolon or space to split in \(range.a1).")
        }
        // The separator chip, under the split cells.
        let below = CellRange(CellAddress(row: min(range.end.row + 1, controller.sheet.rowCount - 1), column: range.start.column))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        let detected = SpreadsheetController.splitSeparators.firstIndex { $0.separator == used } ?? 0
        popover.contentViewController = NSHostingController(rootView: SplitSeparatorView(choice: detected == 0 ? 0 : detected) { [weak self] separator in
            guard let self else { return }
            self.controller.undoManager?.undo()
            self.controller.selection = GridSelection(range: range, active: range.start)
            self.controller.splitTextToColumns(separator: separator)
        })
        grid.scrollToVisible(below.start)
        popover.show(relativeTo: grid.rect(for: below), of: grid, preferredEdge: .maxY)
    }

    func psRemoveDuplicates(_ sender: Any?) {
        finishEditing()
        let range = controller.selection.current.isSingleCell ? controller.dataRegion(around: controller.selection.active) : controller.selection.current
        var headers: [Int: String] = [:]
        for column in range.columns {
            let value = controller.sheet.value(at: CellAddress(row: range.start.row, column: column))
            headers[column] = CellDisplay.text(for: value, pattern: nil).text
        }
        controller.selection = GridSelection(range: range, active: range.start)
        presentSheet { [weak self] dismiss in
            RemoveDuplicatesView(range: range, headers: headers, remove: { columns, hasHeader in
                guard let self else { return }
                let result = self.controller.removeDuplicates(in: range, columns: columns, hasHeader: hasHeader)
                DispatchQueue.main.async {
                    self.showMessage(result.removed == 0 ? "No duplicate rows found."
                                     : "\(result.removed) duplicate \(result.removed == 1 ? "row" : "rows") found and removed.",
                                     detail: "\(result.remaining) unique \(result.remaining == 1 ? "row remains" : "rows remain").")
                }
            }, dismiss: dismiss)
        }
    }

    func psTrimWhitespace(_ sender: Any?) {
        finishEditing()
        let count = controller.trimWhitespace()
        showMessage(count == 0 ? "No whitespace to trim." : "Trimmed whitespace from \(count) \(count == 1 ? "cell" : "cells").", detail: nil)
    }

    /// An alert sheet for a problem with an edit.
    func showProblem(_ message: String) {
        showMessage("There was a problem", detail: message)
    }

    func showMessage(_ message: String, detail: String?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        if let detail { alert.informativeText = detail }
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
    func psDeleteRows(_ sender: Any?) { finishEditing(); controller.deleteSelectedRows() }
    func psDeleteColumns(_ sender: Any?) { finishEditing(); controller.deleteSelectedColumns() }
    func psFillDown(_ sender: Any?) { finishEditing(); controller.fillDown() }
    func psFind(_ sender: Any?) { finishEditing(); find.show() }
    func psFindNext(_ sender: Any?) { finishEditing(); find.next() }
    func psFindPrevious(_ sender: Any?) { finishEditing(); find.previous() }
    func psFindReplace(_ sender: Any?) { showFindReplace() }
    func psFillRight(_ sender: Any?) { finishEditing(); controller.fillRight() }

    // MARK: File

    func psRename(_ sender: Any?) { state.renameRequest += 1 }

    func psDownload(_ sender: Any?) {
        finishEditing()
        guard let item = sender as? NSMenuItem, SpreadsheetFileFormat.allCases.indices.contains(item.tag) else { return }
        let format = SpreadsheetFileFormat.allCases[item.tag]
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(format.typeIdentifier) ?? .data]
        var name = state.title
        if !format.keepsEverything, controller.workbook.sheets.count > 1 { name += " - \(controller.sheet.name)" }
        panel.nameFieldStringValue = name + "." + format.fileExtension
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let data = try SpreadsheetIO.write(self.controller.workbook, activeSheet: self.controller.activeSheetIndex, format: format)
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: self.window!)
            }
        }
    }

    // MARK: Printing

    func psPrint(_ sender: Any?) { showPrintSettings(export: false) }
    func psDownloadPDF(_ sender: Any?) { showPrintSettings(export: true) }

    /// The print settings, then the print dialog (Next) or a PDF file (Export).
    func showPrintSettings(export: Bool) {
        finishEditing()
        let controller = self.controller
        let title = state.title
        presentSheet { [weak self] dismiss in
            PrintSettingsView(settings: self?.printSettings ?? PrintSettings(),
                              makeView: { PrintPagesView(controller: controller, settings: $0, title: title) },
                              actionTitle: export ? "Export" : "Next") { settings in
                dismiss()
                guard let self, let settings else { return }
                self.printSettings = settings
                DispatchQueue.main.async {
                    if export { self.exportPDF(settings) } else { self.runPrint(settings) }
                }
            }
        }
    }

    private func runPrint(_ settings: PrintSettings) {
        guard let window else { return }
        let view = PrintPagesView(controller: controller, settings: settings, title: state.title)
        let operation = NSPrintOperation(view: view, printInfo: view.printInfo())
        operation.jobTitle = state.title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func exportPDF(_ settings: PrintSettings) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = state.title + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let view = PrintPagesView(controller: self.controller, settings: settings, title: self.state.title)
            do {
                try view.pdfData().write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    // MARK: View

    func psToggleGridlines(_ sender: Any?) { controller.toggleGridlines() }

    func psToggleFormulaBar(_ sender: Any?) {
        let show = formulaBar.isHidden
        formulaBar.isHidden = !show
        formulaBarHeight.constant = show ? FormulaBar.height : 0
        UserDefaults.standard.set(show, forKey: "PSShowFormulaBar")
    }

    func psFreezeRows(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        controller.freeze(rows: item.tag < 0 ? controller.selection.active.row + 1 : item.tag, columns: nil)
    }

    func psFreezeColumns(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        controller.freeze(rows: nil, columns: item.tag < 0 ? controller.selection.active.column + 1 : item.tag)
    }

    func psSetZoom(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        setZoom(CGFloat(item.tag) / 100)
    }

    func psZoomIn(_ sender: Any?) {
        setZoom(Theme.zoomLevels.first { $0 > state.zoom + 0.001 } ?? Theme.zoomLevels.last!)
    }

    func psZoomOut(_ sender: Any?) {
        setZoom(Theme.zoomLevels.last { $0 < state.zoom - 0.001 } ?? Theme.zoomLevels.first!)
    }

    func psActualSize(_ sender: Any?) { setZoom(1) }

    // MARK: Insert

    func psInsertRowsAbove(_ sender: Any?) { finishEditing(); controller.insertRows(above: true) }
    func psInsertRowsBelow(_ sender: Any?) { finishEditing(); controller.insertRows(above: false) }
    func psInsertColumnsLeft(_ sender: Any?) { finishEditing(); controller.insertColumns(left: true) }
    func psInsertColumnsRight(_ sender: Any?) { finishEditing(); controller.insertColumns(left: false) }
    func psInsertSheet(_ sender: Any?) { addSheet() }

    /// The Σ menu: starts a formula with the function, "=SUM(" with the selection
    /// filled in when several cells are selected.
    func psInsertFunction(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        finishEditing()
        let selection = controller.selection
        let argument = selection.isSingleCell ? "" : selection.current.a1
        grid.beginEditing(replacingWith: "=\(name)(\(argument)", entry: .edit)
    }

    func psInsertDate(_ sender: Any?) { finishEditing(); controller.insertNow(date: true, time: false) }
    func psInsertTime(_ sender: Any?) { finishEditing(); controller.insertNow(date: false, time: true) }
    func psInsertDateTime(_ sender: Any?) { finishEditing(); controller.insertNow(date: true, time: true) }

    // MARK: Format

    func psNumberFormat(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, NumberFormatPresets.all.indices.contains(item.tag) else { return }
        finishEditing()
        controller.setNumberFormat(NumberFormatPresets.all[item.tag].pattern)
    }

    /// The custom number format dialog: any pattern, starting from the cell's.
    func psCustomNumberFormat(_ sender: Any?) {
        finishEditing()
        let alert = NSAlert()
        alert.messageText = "Custom number format"
        alert.informativeText = "Type a format such as #,##0.00, 0.0%, \"$\"#,##0 or yyyy-mm-dd."
        let field = NSTextField(string: state.summary.format.numberFormat ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let pattern = field.stringValue.trimmingCharacters(in: .whitespaces)
            self?.controller.setNumberFormat(pattern.isEmpty ? nil : pattern)
        }
    }

    func psToggleBold(_ sender: Any?) { finishEditing(); controller.toggleBold() }
    func psToggleItalic(_ sender: Any?) { finishEditing(); controller.toggleItalic() }
    func psToggleUnderline(_ sender: Any?) { finishEditing(); controller.toggleUnderline() }
    func psToggleStrikethrough(_ sender: Any?) { finishEditing(); controller.toggleStrikethrough() }

    func psAlignHorizontal(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        finishEditing()
        controller.setHorizontalAlignment([HorizontalAlignment.left, .center, .right][min(max(item.tag, 0), 2)])
    }

    func psAlignVertical(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        finishEditing()
        controller.setVerticalAlignment([VerticalAlignment.top, .middle, .bottom][min(max(item.tag, 0), 2)])
    }

    func psWrap(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        finishEditing()
        controller.setWrap([WrapStrategy.overflow, .wrap, .clip][min(max(item.tag, 0), 2)])
    }

    func psIncreaseFontSize(_ sender: Any?) { finishEditing(); controller.stepFontSize(by: 1) }
    func psDecreaseFontSize(_ sender: Any?) { finishEditing(); controller.stepFontSize(by: -1) }

    func psSetFont(_ sender: Any?) {
        guard let family = (sender as? NSMenuItem)?.representedObject as? String else { return }
        finishEditing()
        controller.setFontFamily(family)
    }

    func psMoreFonts(_ sender: Any?) {
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(fontPanelChanged(_:))
        manager.setSelectedFont(CellRenderer.makeFont(family: state.summary.fontFamily, size: 14, bold: false, italic: false), isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    @objc private func fontPanelChanged(_ sender: NSFontManager) {
        let font = sender.convert(NSFont.systemFont(ofSize: 14))
        if let family = font.familyName { controller.setFontFamily(family) }
    }

    func psMerge(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let kind = MergeKind(rawValue: item.tag) else { return }
        finishEditing()
        guard controller.mergeDiscardsValues(kind) else {
            controller.merge(kind)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Merging cells only keeps the top-left value"
        alert.informativeText = "The other values in the merged cells will be removed."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.controller.merge(kind) }
        }
    }

    func psClearFormatting(_ sender: Any?) { finishEditing(); controller.clearFormatting() }

    // MARK: Data

    func psSortSheet(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let range = controller.sheetSortRange else { return }
        finishEditing()
        sort(range, ascending: item.tag == 0)
    }

    func psSortRange(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        finishEditing()
        sort(controller.selection.current, ascending: item.tag == 0)
    }

    private func sort(_ range: CellRange, ascending: Bool) {
        if let problem = controller.sortProblem(range) {
            let alert = NSAlert()
            alert.messageText = problem
            alert.beginSheetModal(for: window!)
            return
        }
        controller.sort(range, by: controller.selection.active.column, ascending: ascending)
    }

    // MARK: Rows and columns

    func psHideRows(_ sender: Any?) { finishEditing(); controller.hideRows(controller.selectedRows) }
    func psHideColumns(_ sender: Any?) { finishEditing(); controller.hideColumns(controller.selectedColumns) }
    func psUnhideRows(_ sender: Any?) { controller.unhideRows() }
    func psUnhideColumns(_ sender: Any?) { controller.unhideColumns() }

    func psResizeColumns(_ sender: Any?) { askForSize(columns: true) }
    func psResizeRows(_ sender: Any?) { askForSize(columns: false) }

    /// The "Resize column" dialog: a size in pixels, or fit to data.
    private func askForSize(columns: Bool) {
        let indexes = columns ? controller.selectedColumns : controller.selectedRows
        guard let first = indexes.first else { return }
        let alert = NSAlert()
        let names = columns ? indexes.map(CellAddress.columnName) : indexes.map { String($0 + 1) }
        alert.messageText = "Resize \(columns ? "column" : "row")\(indexes.count == 1 ? "" : "s") \(names.count == 1 ? names[0] : "\(names[0]) – \(names[names.count - 1])")"
        alert.informativeText = "Enter a new \(columns ? "width" : "height") in pixels (default: \(Int(columns ? controller.sheet.defaultColumnWidth : controller.sheet.defaultRowHeight)))."
        let field = NSTextField(string: String(Int(columns ? controller.sheet.columnWidth(first) : controller.sheet.rowHeight(first))))
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Fit to data")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                guard let size = Double(field.stringValue.trimmingCharacters(in: .whitespaces)), size > 0 else { return NSSound.beep() }
                let sizes = Dictionary(uniqueKeysWithValues: indexes.map { ($0, size) })
                if columns { self.controller.setColumnWidths(sizes) } else { self.controller.setRowHeights(sizes) }
            case .alertSecondButtonReturn:
                if columns { self.grid.autoFitColumns(indexes) } else { self.grid.autoFitRows(indexes) }
            default:
                break
            }
        }
    }

    // MARK: Sheets

    func psDuplicateSheet(_ sender: Any?) { finishEditing(); controller.duplicateSheet(id: controller.activeSheetID) }
    func psDeleteSheet(_ sender: Any?) { finishEditing(); deleteSheet(controller.activeSheetID) }
    func psRenameSheet(_ sender: Any?) { state.renameSheetRequest += 1 }
    func psNextSheet(_ sender: Any?) { finishEditing(); grid.switchSheet(by: 1) }
    func psPreviousSheet(_ sender: Any?) { finishEditing(); grid.switchSheet(by: -1) }

    func psConditionalFormatting(_ sender: Any?) { showSidebar(.conditionalFormatting) }
    func psAlternatingColors(_ sender: Any?) { showSidebar(.alternatingColors) }
    func psDataValidation(_ sender: Any?) { showSidebar(.dataValidation) }
    func psNamedRanges(_ sender: Any?) { showSidebar(.namedRanges) }

    func psInsertCheckbox(_ sender: Any?) {
        finishEditing()
        controller.insertCheckboxes()
    }

    /// Insert ▸ Dropdown: the data validation panel, straight on a new dropdown for the selection.
    func psInsertDropdown(_ sender: Any?) {
        state.pendingValidationKind = .dropdown
        if state.sidebar == .dataValidation { state.sidebar = nil }
        showSidebar(.dataValidation)
    }

    func psToggleFilter(_ sender: Any?) {
        finishEditing()
        if controller.sheet.filter == nil { controller.createFilter() } else { controller.removeFilter() }
    }

    func psShowShortcuts(_ sender: Any?) {
        presentSheet { dismiss in ShortcutsView(dismiss: dismiss) }
    }

    func presentSheet<Content: View>(_ content: (_ dismiss: @escaping () -> Void) -> Content) {
        guard let window else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let dismiss = { [weak window, weak sheet] in
            guard let window, let sheet else { return }
            window.endSheet(sheet)
        }
        let host = NSHostingController(rootView: content(dismiss))
        sheet.contentViewController = host
        let ideal = host.view.intrinsicContentSize
        if ideal.width > 0, ideal.height > 0, ideal.width < 2_000, ideal.height < 2_000 { sheet.setContentSize(ideal) }
        sheet.appearance = NSAppearance(named: .aqua)
        window.beginSheet(sheet) { [weak self] _ in self?.focusGrid() }
    }

    // MARK: Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Sharing decides what can change here.
        if let action = menuItem.action {
            switch action {
            case #selector(SheetCommands.psCollaborate(_:)):
                // Only a spreadsheet's owner shares it, and changes who it's shared with.
                menuItem.isHidden = !state.showsCollaborateButton
                menuItem.title = state.collaboration.isShared ? "Collaborators…" : "Collaborate…"
                return state.showsCollaborateButton && (state.access != .locked || state.collaboration.isShared)
            case #selector(SheetCommands.psLeaveShared(_:)):
                menuItem.isHidden = state.showsCollaborateButton
                return spreadsheet?.collaboration?.isOwner == false
            case #selector(SheetCommands.psInsertComment(_:)):
                if !state.canComment { return false }
            case #selector(SheetCommands.psRename(_:)):
                if spreadsheet?.sharedCopy != nil { return false }
            default:
                if !state.isEditable, !Self.commandsThatChangeNothing.contains(action) { return false }
            }
        }
        let selection = controller.selection
        let sheet = controller.sheet
        let rows = controller.selectedRows, columns = controller.selectedColumns
        func span(_ names: [String], _ noun: String) -> String {
            names.count == 1 ? "\(noun) \(names[0])" : "\(noun)s \(names[0]) – \(names[names.count - 1])"
        }
        switch menuItem.action {
        case #selector(SheetCommands.psToggleShowFormulas(_:)):
            menuItem.state = grid.showsFormulas ? .on : .off
        case #selector(SheetCommands.psToggleShowProtectedRanges(_:)):
            menuItem.state = grid.showsProtectedRanges ? .on : .off
        case #selector(SheetCommands.psInsertRowsAbove(_:)), #selector(SheetCommands.psInsertRowsBelow(_:)):
            let count = selection.current.rowCount
            let place = menuItem.action == #selector(SheetCommands.psInsertRowsAbove(_:)) ? "above" : "below"
            menuItem.title = "Insert \(count) row\(count == 1 ? "" : "s") \(place)"
        case #selector(SheetCommands.psInsertColumnsLeft(_:)), #selector(SheetCommands.psInsertColumnsRight(_:)):
            let count = selection.current.columnCount
            let place = menuItem.action == #selector(SheetCommands.psInsertColumnsLeft(_:)) ? "left" : "right"
            menuItem.title = "Insert \(count) column\(count == 1 ? "" : "s") \(place)"
        case #selector(SheetCommands.psDeleteRows(_:)):
            menuItem.title = "Delete " + span(rows.map { String($0 + 1) }, "row")
            return controller.canDeleteRows
        case #selector(SheetCommands.psDeleteColumns(_:)):
            menuItem.title = "Delete " + span(columns.map(CellAddress.columnName), "column")
            return controller.canDeleteColumns
        case #selector(SheetCommands.psHideRows(_:)):
            menuItem.title = "Hide " + span(rows.map { String($0 + 1) }, "row")
            return rows.count < sheet.rowCount - sheet.hiddenRows.count
        case #selector(SheetCommands.psHideColumns(_:)):
            menuItem.title = "Hide " + span(columns.map(CellAddress.columnName), "column")
            return columns.count < sheet.columnCount - sheet.hiddenColumns.count
        case #selector(SheetCommands.psUnhideRows(_:)):
            return controller.selectionTouchesHiddenRows
        case #selector(SheetCommands.psUnhideColumns(_:)):
            return controller.selectionTouchesHiddenColumns
        case #selector(SheetCommands.psFreezeRows(_:)):
            if menuItem.tag < 0 {
                menuItem.title = "Up to row \(selection.active.row + 1)"
                menuItem.state = sheet.frozenRows == selection.active.row + 1 && sheet.frozenRows > 2 ? .on : .off
            } else {
                menuItem.state = sheet.frozenRows == menuItem.tag ? .on : .off
            }
        case #selector(SheetCommands.psFreezeColumns(_:)):
            if menuItem.tag < 0 {
                menuItem.title = "Up to column \(CellAddress.columnName(selection.active.column))"
                menuItem.state = sheet.frozenColumns == selection.active.column + 1 && sheet.frozenColumns > 2 ? .on : .off
            } else {
                menuItem.state = sheet.frozenColumns == menuItem.tag ? .on : .off
            }
        case #selector(SheetCommands.psToggleGridlines(_:)):
            menuItem.state = sheet.showsGridlines ? .on : .off
        case #selector(SheetCommands.psToggleFormulaBar(_:)):
            menuItem.state = formulaBar.isHidden ? .off : .on
        case #selector(SheetCommands.psSetZoom(_:)):
            menuItem.state = abs(state.zoom * 100 - CGFloat(menuItem.tag)) < 0.5 ? .on : .off
        case #selector(SheetCommands.psMerge(_:)):
            return MergeKind(rawValue: menuItem.tag).map(controller.canMerge) ?? false
        case #selector(SheetCommands.psSortSheet(_:)):
            let column = CellAddress.columnName(selection.active.column)
            menuItem.title = "Sort sheet by column \(column) (\(menuItem.tag == 0 ? "A to Z" : "Z to A"))"
            return controller.sheetSortRange != nil
        case #selector(SheetCommands.psSortRange(_:)):
            let column = CellAddress.columnName(selection.active.column)
            menuItem.title = "Sort range by column \(column) (\(menuItem.tag == 0 ? "A to Z" : "Z to A"))"
            return selection.current.rowCount > 1
        case #selector(SheetCommands.psDeleteSheet(_:)):
            return controller.workbook.sheets.count > 1
        case #selector(SheetCommands.psToggleFilter(_:)):
            menuItem.title = controller.sheet.filter == nil ? "Create a filter" : "Remove filter"
        case #selector(SheetCommands.psNumberFormat(_:)):
            if NumberFormatPresets.all.indices.contains(menuItem.tag) {
                menuItem.state = NumberFormatPresets.all[menuItem.tag].pattern == state.summary.format.numberFormat ? .on : .off
            }
        case #selector(SheetCommands.psToggleBold(_:)):
            menuItem.state = state.summary.format.bold ? .on : .off
        case #selector(SheetCommands.psToggleItalic(_:)):
            menuItem.state = state.summary.format.italic ? .on : .off
        case #selector(SheetCommands.psToggleUnderline(_:)):
            menuItem.state = state.summary.format.underline ? .on : .off
        case #selector(SheetCommands.psToggleStrikethrough(_:)):
            menuItem.state = state.summary.format.strikethrough ? .on : .off
        default:
            break
        }
        return true
    }

    // MARK: Context menus

    func contextMenu(for location: GridView.GridLocation) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = true
        func add(_ item: NSMenuItem) {
            if item.action != nil && item.target == nil { item.target = self }
            menu.addItem(item)
        }
        add(MenuBuilder.item("Cut", #selector(NSText.cut(_:)), "x", symbol: "scissors"))
        add(MenuBuilder.item("Copy", #selector(NSText.copy(_:)), "c", symbol: "doc.on.doc"))
        add(MenuBuilder.item("Paste", #selector(NSText.paste(_:)), "v", symbol: "doc.on.clipboard"))
        let special = MenuBuilder.submenu("Paste special", [
            MenuBuilder.item("Values only", #selector(SheetCommands.psPasteValues(_:)), "v", [.command, .shift]),
            MenuBuilder.item("Format only", #selector(SheetCommands.psPasteFormat(_:)), "v", [.command, .option]),
            MenuBuilder.item("Transposed", #selector(SheetCommands.psPasteTransposed(_:))),
        ])
        special.submenu?.items.forEach { $0.target = self }
        menu.addItem(special)
        menu.addItem(.separator())
        switch location {
        case .columnHeader:
            add(MenuBuilder.item("Insert columns left", #selector(SheetCommands.psInsertColumnsLeft(_:)), symbol: "arrow.left.to.line"))
            add(MenuBuilder.item("Insert columns right", #selector(SheetCommands.psInsertColumnsRight(_:)), symbol: "arrow.right.to.line"))
            add(MenuBuilder.item("Delete column", #selector(SheetCommands.psDeleteColumns(_:)), symbol: "trash"))
            add(MenuBuilder.item("Clear", #selector(SheetCommands.psDeleteValues(_:)), symbol: "xmark"))
            add(MenuBuilder.item("Hide column", #selector(SheetCommands.psHideColumns(_:)), symbol: "eye.slash"))
            if controller.selectionTouchesHiddenColumns { add(MenuBuilder.item("Unhide columns", #selector(SheetCommands.psUnhideColumns(_:)), symbol: "eye")) }
            add(MenuBuilder.item("Resize column…", #selector(SheetCommands.psResizeColumns(_:)), symbol: "arrow.left.and.right"))
            add(MenuBuilder.item("Group columns", #selector(SheetCommands.psGroupColumns(_:)), symbol: "rectangle.3.group"))
            if !controller.sheet.columnGroups.isEmpty { add(MenuBuilder.item("Ungroup columns", #selector(SheetCommands.psUngroupColumns(_:)))) }
            menu.addItem(.separator())
            add(MenuBuilder.item("Sort sheet A to Z", #selector(SheetCommands.psSortSheet(_:)), tag: 0, symbol: "arrow.up"))
            add(MenuBuilder.item("Sort sheet Z to A", #selector(SheetCommands.psSortSheet(_:)), tag: 1, symbol: "arrow.down"))
        case .rowHeader:
            add(MenuBuilder.item("Insert rows above", #selector(SheetCommands.psInsertRowsAbove(_:)), symbol: "arrow.up.to.line"))
            add(MenuBuilder.item("Insert rows below", #selector(SheetCommands.psInsertRowsBelow(_:)), symbol: "arrow.down.to.line"))
            add(MenuBuilder.item("Delete row", #selector(SheetCommands.psDeleteRows(_:)), symbol: "trash"))
            add(MenuBuilder.item("Clear", #selector(SheetCommands.psDeleteValues(_:)), symbol: "xmark"))
            add(MenuBuilder.item("Hide row", #selector(SheetCommands.psHideRows(_:)), symbol: "eye.slash"))
            if controller.selectionTouchesHiddenRows { add(MenuBuilder.item("Unhide rows", #selector(SheetCommands.psUnhideRows(_:)), symbol: "eye")) }
            add(MenuBuilder.item("Resize row…", #selector(SheetCommands.psResizeRows(_:)), symbol: "arrow.up.and.down"))
            add(MenuBuilder.item("Group rows", #selector(SheetCommands.psGroupRows(_:)), symbol: "rectangle.3.group"))
            if !controller.sheet.rowGroups.isEmpty { add(MenuBuilder.item("Ungroup rows", #selector(SheetCommands.psUngroupRows(_:)))) }
        default:
            add(MenuBuilder.item("Insert rows above", #selector(SheetCommands.psInsertRowsAbove(_:)), symbol: "arrow.up.to.line"))
            add(MenuBuilder.item("Insert columns left", #selector(SheetCommands.psInsertColumnsLeft(_:)), symbol: "arrow.left.to.line"))
            let insertCells = MenuBuilder.submenu("Insert cells", symbol: "square.grid.3x3.topleft.filled", [
                MenuBuilder.item("Insert cells and shift right", #selector(SheetCommands.psInsertCellsShiftRight(_:))),
                MenuBuilder.item("Insert cells and shift down", #selector(SheetCommands.psInsertCellsShiftDown(_:))),
            ])
            insertCells.submenu?.items.forEach { $0.target = self }
            menu.addItem(insertCells)
            menu.addItem(.separator())
            add(MenuBuilder.item("Delete row", #selector(SheetCommands.psDeleteRows(_:)), symbol: "trash"))
            add(MenuBuilder.item("Delete column", #selector(SheetCommands.psDeleteColumns(_:))))
            let deleteCells = MenuBuilder.submenu("Delete cells", [
                MenuBuilder.item("Delete cells and shift left", #selector(SheetCommands.psDeleteCellsShiftLeft(_:))),
                MenuBuilder.item("Delete cells and shift up", #selector(SheetCommands.psDeleteCellsShiftUp(_:))),
            ])
            deleteCells.submenu?.items.forEach { $0.target = self }
            menu.addItem(deleteCells)
            menu.addItem(.separator())
            add(MenuBuilder.item("Sort range A to Z", #selector(SheetCommands.psSortRange(_:)), tag: 0, symbol: "arrow.up"))
            add(MenuBuilder.item("Sort range Z to A", #selector(SheetCommands.psSortRange(_:)), tag: 1, symbol: "arrow.down"))
            menu.addItem(.separator())
            add(MenuBuilder.item("Insert link", #selector(SheetCommands.psInsertLink(_:)), symbol: "link"))
            add(MenuBuilder.item("Comment", #selector(SheetCommands.psInsertComment(_:)), symbol: "text.bubble"))
            add(MenuBuilder.item("Insert note", #selector(SheetCommands.psInsertNote(_:)), symbol: "note.text"))
            if controller.sheet.cells[controller.selection.active]?.note != nil {
                add(MenuBuilder.item("Clear notes", #selector(SheetCommands.psClearNotes(_:))))
            }
            if let pivot = controller.sheet.pivotTable(covering: controller.selection.active) {
                // Without an action it shows disabled while the spreadsheet can't be changed.
                let edit = NSMenuItem(title: "Edit pivot table", action: state.isEditable ? #selector(MenuAction.perform(_:)) : nil, keyEquivalent: "")
                let handler = MenuAction { [weak self] in self?.showPivotEditor(pivot.id) }
                edit.target = handler
                edit.representedObject = handler
                edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
                menu.addItem(edit)
            }
        }
        return menu
    }
}
