import AppKit
import PuggleSheetsKit
import SwiftUI
import UniformTypeIdentifiers

/// The field editor for this window's text fields. Its typing undo stays local, so editing the
/// title or the formula bar never lands in the spreadsheet's undo history.
final class LocalUndoFieldEditor: NSTextView {
    private let localUndoManager = UndoManager()
    override var undoManager: UndoManager? { localUndoManager }
}

/// A spreadsheet's window. While its shared spreadsheet can't save to iCloud it has no undo manager, so Undo and Redo do
/// nothing and the spreadsheet's own steps wait, untouched, until iCloud's back.
final class DocumentWindow: NSWindow {
    var pausesUndo: () -> Bool = { false }

    override var undoManager: UndoManager? { pausesUndo() ? nil : super.undoManager }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if pausesUndo(), item.action == Selector(("undo:")) || item.action == Selector(("redo:")) { return false }
        return super.validateUserInterfaceItem(item)
    }
}

final class DocumentWindowController: NSWindowController, NSWindowDelegate, ChromeActions, SheetBarActions, SidebarActions {
    let state = EditorState()
    let controller: SpreadsheetController
    let grid: GridView
    let formulaBar = FormulaBar()
    let find: FindController
    let findReplace: FindReplaceController
    private var findReplacePanel: NSPanel?
    private var findReplaceObserver: PanelCloseObserver?
    private var formulaAssistant: FormulaAssistant!
    /// The last print settings used in this window.
    var printSettings = PrintSettings()
    /// The card under a linked cell.
    var linkCard: NSHostingView<LinkCardView>?
    /// The filter view bar's height: 40 while a filter view is open, 0 otherwise.
    var filterViewBarHeight: NSLayoutConstraint!
    /// The note of the cell under the mouse.
    var notePopup: NSHostingView<NotePopupView>?
    /// The comment thread (or new comment) beside the active cell.
    var commentCard: NSHostingView<CommentCardView>?
    /// Insert ▸ Comment: the cell a new comment is being written for.
    var composingComment: CellAddress?
    private var chromeHost: NSHostingView<ChromeView>!
    private var sheetBarHost: NSHostingView<SheetBar>!
    var formulaBarHeight: NSLayoutConstraint!
    private var sidebarWidth: NSLayoutConstraint!
    private var colorPanelTargetsFill = false
    private var currentSheetID: UUID
    private var refreshScheduled = false
    /// The cell being edited in the formula bar.
    private var formulaEdit: (sheet: UUID, address: CellAddress)?
    private lazy var fieldEditor: LocalUndoFieldEditor = {
        let editor = LocalUndoFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    var spreadsheet: SpreadsheetDocument? { document as? SpreadsheetDocument }

    init(document: SpreadsheetDocument) {
        controller = SpreadsheetController(document: document, state: state)
        grid = GridView(controller: controller)
        find = FindController(controller: controller, grid: grid)
        findReplace = FindReplaceController(controller: controller, grid: grid)
        currentSheetID = controller.activeSheetID
        let window = DocumentWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        window.pausesUndo = { [weak state] in state?.access == .offline }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.canvas
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 720, height: 420)
        window.isRestorable = true
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        buildContent()
        wireUp(document)

        if !document.importWarnings.isEmpty, let name = document.importedFileName {
            let list = document.importWarnings.map(\.userDescription).sorted().joined(separator: ", ")
            state.banner = "This is a copy of “\(name)”. PuggleSheets can’t keep \(list) yet, so your original file was left untouched. Saving creates a new file."
        } else if let format = document.format, !format.keepsEverything, document.fileURL != nil {
            state.banner = "\(format == .csv ? "CSV" : "TSV") files keep only the values of the current sheet. To keep formulas, formatting and other sheets, use File ▸ Download ▸ Microsoft Excel (.xlsx)."
        }
        refreshSheetTabs()
        refreshState()
        updateStatus()
        window.setContentSize(NSSize(width: 1280, height: 860))
        window.center()
        updateTitlebarMetrics()
        DispatchQueue.main.async { [weak self] in self?.updateTitlebarMetrics() }
        window.makeFirstResponder(grid)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.canvas.cgColor
        window.contentView = content

        chromeHost = NSHostingView(rootView: ChromeView(state: state, actions: self))
        chromeHost.sizingOptions = [.intrinsicContentSize]
        // The header sits in the title bar band, so the title bar must not count as a safe-area inset.
        chromeHost.safeAreaRegions = []
        chromeHost.setContentHuggingPriority(.required, for: .vertical)
        chromeHost.setContentCompressionResistancePriority(.required, for: .vertical)
        sheetBarHost = NSHostingView(rootView: SheetBar(state: state, actions: self))
        sheetBarHost.sizingOptions = []
        sheetBarHost.safeAreaRegions = []
        for view in [chromeHost!, formulaBar, grid, sheetBarHost!] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let sidebar = NSHostingView(rootView: SidebarView(state: state, actions: self))
        sidebar.sizingOptions = []
        sidebar.safeAreaRegions = []
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 0)
        let filterViewBar = NSHostingView(rootView: FilterViewBar(state: state, controller: controller) { [weak self] in
            self?.controller.openFilterView(nil)
        })
        filterViewBar.sizingOptions = []
        filterViewBar.safeAreaRegions = []
        filterViewBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(filterViewBar)
        filterViewBarHeight = filterViewBar.heightAnchor.constraint(equalToConstant: 0)
        let findBar = NSHostingView(rootView: FindBarView(state: find.state, controller: find))
        findBar.sizingOptions = [.intrinsicContentSize]
        findBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(findBar)
        let showsFormulaBar = UserDefaults.standard.object(forKey: "PSShowFormulaBar") as? Bool ?? true
        formulaBarHeight = formulaBar.heightAnchor.constraint(equalToConstant: showsFormulaBar ? FormulaBar.height : 0)
        formulaBar.isHidden = !showsFormulaBar
        NSLayoutConstraint.activate([
            chromeHost.topAnchor.constraint(equalTo: content.topAnchor),
            chromeHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chromeHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            formulaBar.topAnchor.constraint(equalTo: chromeHost.bottomAnchor),
            formulaBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            formulaBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            formulaBarHeight,
            filterViewBar.topAnchor.constraint(equalTo: formulaBar.bottomAnchor),
            filterViewBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            filterViewBar.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            filterViewBarHeight,
            grid.topAnchor.constraint(equalTo: filterViewBar.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: formulaBar.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: sheetBarHost.topAnchor),
            sidebar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sidebarWidth,
            grid.bottomAnchor.constraint(equalTo: sheetBarHost.topAnchor),
            sheetBarHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sheetBarHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sheetBarHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sheetBarHost.heightAnchor.constraint(equalToConstant: 40),
            findBar.trailingAnchor.constraint(equalTo: grid.trailingAnchor, constant: -24),
            findBar.topAnchor.constraint(equalTo: grid.topAnchor, constant: 26),
        ])
    }

    private func wireUp(_ document: SpreadsheetDocument) {
        controller.onUpdate = { [weak self] update in self?.handle(update) }
        controller.onRejectedInput = { [weak self] message in self?.showRejectedInput(message) }
        controller.onProblem = { [weak self] message in self?.showProblem(message) }
        document.onStatusChange = { [weak self] in self?.updateStatus() }
        document.onReload = { [weak self] in
            guard let self else { return }
            // A shared spreadsheet's file read again (another app changed it) goes back to its shared copy.
            if let collaboration = self.controller.collaboration, collaboration.isLive {
                collaboration.restoreFromLog()
            } else {
                self.controller.reloadFromDocument()
            }
        }

        grid.menuProvider = { [weak self] location in self?.contextMenu(for: location) }
        grid.onFilterButton = { [weak self] column, rect in self?.showFilterPopover(column: column, at: rect) }
        grid.onObjectMenu = { [weak self] id, rect in self?.showObjectMenu(id, at: rect) }
        grid.objectMenuProvider = { [weak self] id in self?.objectMenu(for: id) }
        grid.onObjectDoubleClick = { [weak self] id in
            guard let self, let object = self.controller.object(id: id), object.chart != nil || object.slicer != nil,
                  self.allowsChanges() else { return }
            if object.chart != nil { self.showChartEditor(id) }
            if object.slicer != nil { self.showSlicerEditor(id) }
        }
        grid.onEditPivot = { [weak self] id in if self?.allowsChanges() == true { self?.showPivotEditor(id) } }
        grid.onTableControl = { [weak self] id, column, rect in self?.handleTableControl(id, column: column, rect: rect) }
        grid.onSlicerDropdown = { [weak self] id, rect in self?.showSlicerFilter(id, at: rect) }
        grid.onViewportChange = { [weak self] in
            self?.updateLinkCard()
            self?.updateCommentCard()
            self?.updateNotePopup()
        }
        grid.onHoverCell = { [weak self] _ in self?.updateNotePopup() }
        controller.onProtectedEdit = { [weak self] protection in self?.askAboutProtectedEdit(protection) ?? .cancel }
        grid.onBeginEditing = { [weak self] editor in self?.formulaBar.mirror(editor.string) }
        grid.onEditorTextChange = { [weak self] text in self?.formulaBar.mirror(text) }
        grid.onEndEditing = { [weak self] in self?.scheduleStateRefresh() }
        grid.onZoomGesture = { [weak self] delta in
            guard let self else { return }
            self.setZoom(self.state.zoom * (1 + delta), snap: false)
        }

        formulaAssistant = FormulaAssistant(window: window!)
        formulaAssistant.namedRanges = { [weak self] in self?.controller.workbook.namedRanges ?? [] }
        formulaAssistant.tableNames = { [weak self] in self?.controller.workbook.sheets.flatMap { $0.tables.map(\.name) } ?? [] }
        grid.formulaAssistant = formulaAssistant
        formulaBar.onBeginEditing = { [weak self] in self?.beginFormulaBarEditing() }
        formulaBar.onTextChange = { [weak self] text in
            guard let self else { return }
            self.grid.mirroredEditText = text
            self.grid.updateReferenceHighlights(text: text, in: nil)
            self.formulaAssistant.update(for: self.fieldEditor)
        }
        formulaBar.onCommit = { [weak self] text, move in
            self?.formulaAssistant.hide()
            self?.commitFormulaBar(text, move: move)
        }
        formulaBar.onCancel = { [weak self] in
            self?.formulaAssistant.hide()
            self?.cancelFormulaBar()
        }
        formulaBar.onCommand = { [weak self] selector, textView in
            self?.formulaAssistant.handle(selector, in: textView) ?? false
        }
        formulaBar.onNameBoxCommit = { [weak self] text in self?.goToReference(text) }

        let center = NotificationCenter.default
        center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: fieldEditor, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.formulaBar.isEditing, self.fieldEditor.delegate === self.formulaBar.field else { return }
                self.formulaAssistant.update(for: self.fieldEditor)
            }
        }
        for name in [NSNotification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            center.addObserver(forName: name, object: document.undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleStateRefresh() }
            }
        }
    }

    /// The dialog for input that data validation refuses.
    private func showRejectedInput(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "There was a problem"
        alert.informativeText = "This cell has data validation rules that limit what can go in it.\n\n\(message)"
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window!)
    }

    // MARK: Updates

    private func handle(_ update: SpreadsheetUpdate) {
        if update.contains(.activeSheet), currentSheetID != controller.activeSheetID {
            grid.cancelEditing()
            grid.sheetWillChange(from: currentSheetID)
            currentSheetID = controller.activeSheetID
            grid.sheetDidChange()
        } else if update.contains(.layout) {
            grid.reloadLayout()
        }
        if !update.isDisjoint(with: [.cells, .layout, .activeSheet]) { grid.invalidateRuleCaches() }
        if !update.isDisjoint(with: [.cells, .layout, .sheets, .activeSheet]) { state.ruleRevision += 1 }
        if !update.isDisjoint(with: [.cells, .selection]) { grid.needsDisplay = true }
        if !update.isDisjoint(with: [.sheets, .activeSheet]) { refreshSheetTabs() }
        if !update.isDisjoint(with: [.cells, .activeSheet]) { find.scheduleRefresh() }
        if !update.isDisjoint(with: [.layout, .activeSheet, .sheets]) { updateFilterViewBar() }
        // The open editors follow the selection to another chart or pivot table.
        if state.sidebar == .chartEditor, let id = controller.selectedObjectID, controller.object(id: id)?.chart != nil, state.editingObjectID != id {
            state.editingObjectID = id
        }
        if state.sidebar == .pivotEditor, let pivot = controller.sheet.pivotTable(covering: controller.selection.active), state.editingPivotID != pivot.id {
            state.editingPivotID = pivot.id
        }
        if state.sidebar == .table, let table = controller.sheet.table(containing: controller.selection.active), state.editingTableID != table.id {
            state.editingTableID = table.id
        }
        if state.sidebar == .slicer, let id = controller.selectedObjectID, controller.object(id: id)?.slicer != nil, state.editingObjectID != id {
            state.editingObjectID = id
        }
        scheduleStateRefresh()
    }

    func scheduleStateRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refreshState()
        }
    }

    /// Updates the toolbar, the formula bar and the selection statistics.
    func refreshState() {
        let selection = controller.selection
        let sheet = controller.sheet
        let summary = FormatSummary(format: sheet[selection.active].format, isMerged: sheet.merge(containing: selection.active) != nil)
        if state.summary != summary { state.summary = summary }
        let statistics = controller.selectionStatistics()
        if state.statistics != statistics { state.statistics = statistics }
        let statisticsFormat = sheet[selection.active].format.numberFormat
        if state.statisticsFormat != statisticsFormat { state.statisticsFormat = statisticsFormat }
        let reference = selection.current.a1
        if state.selectionReference != reference { state.selectionReference = reference }
        // While a shared spreadsheet can't save to iCloud, nothing in it changes, undo included.
        let undoes = state.access != .offline
        state.canUndo = undoes && (controller.undoManager?.canUndo ?? false)
        state.canRedo = undoes && (controller.undoManager?.canRedo ?? false)
        if grid.editor == nil {
            let address = selection.active
            if sheet.cells[address]?.hasContent != true, sheet.pivotTable(covering: address) != nil {
                // Pivot table results show as values.
                formulaBar.show(reference: referenceText(selection), text: CellDisplay.text(for: sheet.value(at: address), pattern: nil).text)
            } else {
                formulaBar.show(reference: referenceText(selection), text: controller.editText(at: address),
                                spillingFormula: controller.spillingFormula(at: address))
            }
        } else {
            formulaBar.show(reference: referenceText(selection), text: formulaBar.field.stringValue)
        }
        updateLinkCard()
        updateCommentCard()
    }

    private func referenceText(_ selection: GridSelection) -> String {
        let range = selection.current
        if range == controller.mergedRange(at: selection.active) { return selection.active.a1 }
        return range.a1
    }

    func refreshSheetTabs() {
        let tabs = controller.workbook.sheets.map { sheet in
            SheetTab(id: sheet.id, name: sheet.name, color: sheet.tabColor,
                     isProtected: sheet.protections.contains { if case .sheet = $0.scope { true } else { false } })
        }
        if state.sheets != tabs { state.sheets = tabs }
        if state.activeSheetID != controller.activeSheetID { state.activeSheetID = controller.activeSheetID }
    }

    // MARK: Status and title

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        updateStatus()
        // A shared spreadsheet of this person's that moved or was renamed is still found by its new name, and everyone
        // it's shared with sees the new name.
        if let document = spreadsheet, let collaboration = document.collaboration, collaboration.isOwner, let url = document.fileURL {
            CollaborationController.shared?.link(collaboration.id, to: url)
            collaboration.titleChanged()
        }
    }

    func updateStatus() {
        guard let document = spreadsheet else { return }
        var title = document.displayName ?? "Untitled spreadsheet"
        if let ext = document.fileURL?.pathExtension, !ext.isEmpty, title.lowercased().hasSuffix("." + ext.lowercased()) {
            title = String(title.dropLast(ext.count + 1))
        }
        state.title = title
        state.formatBadge = document.fileURL == nil ? nil : document.format?.badge
        if document.sharedCopy != nil {
            state.saveStatus = .saved
        } else if document.fileURL == nil {
            state.saveStatus = .draft
        } else {
            state.saveStatus = document.isDocumentEdited ? .edited : .saved
        }
    }

    // MARK: Header alignment

    func updateTitlebarMetrics() {
        guard let window else { return }
        let metrics = TitlebarMetrics.measure(window)
        if state.titlebarLeading != metrics.leading { state.titlebarLeading = metrics.leading }
        if abs(state.titlebarCenterY - metrics.centerY) > 0.5 { state.titlebarCenterY = metrics.centerY }
    }

    func windowDidResize(_ notification: Notification) { updateTitlebarMetrics() }
    func windowDidEnterFullScreen(_ notification: Notification) { updateTitlebarMetrics() }
    func windowDidExitFullScreen(_ notification: Notification) { updateTitlebarMetrics() }

    func windowDidBecomeKey(_ notification: Notification) {
        updateTitlebarMetrics()
        grid.needsDisplay = true
    }

    func windowDidResignKey(_ notification: Notification) { grid.needsDisplay = true }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document?.undoManager
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        client is NSTextField ? fieldEditor : nil
    }

    // MARK: Formula bar

    private func beginFormulaBarEditing() {
        // Editing moves from the cell to the formula bar with whatever was typed so far.
        if let editor = grid.editor {
            formulaBar.field.stringValue = editor.string
            grid.cancelEditing()
            if let textView = formulaBar.field.currentEditor() as? NSTextView {
                textView.string = formulaBar.field.stringValue
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
        formulaEdit = (controller.activeSheetID, controller.selection.active)
        grid.mirroredEditText = formulaBar.field.stringValue
    }

    private func commitFormulaBar(_ text: String, move: GridView.Move?) {
        guard let edit = formulaEdit else { return }
        formulaEdit = nil
        grid.mirroredEditText = nil
        grid.formulaReferenceRanges = []
        guard edit.sheet == controller.activeSheetID else { return }
        var next: GridSelection?
        if let move { next = grid.selection(after: move, from: edit.address) }
        controller.commitInput(text, at: edit.address, then: next)
        if let next { grid.scrollToVisible(next.active) }
        if move != nil { window?.makeFirstResponder(grid) }
        refreshState()
    }

    private func cancelFormulaBar() {
        formulaEdit = nil
        grid.mirroredEditText = nil
        grid.formulaReferenceRanges = []
        window?.makeFirstResponder(grid)
        refreshState()
    }

    /// Commits any entry in progress, in the cell or the formula bar.
    func finishEditing() {
        if grid.editor != nil { grid.commitEditing() }
        if formulaEdit != nil, formulaBar.isEditing {
            formulaBar.endEditingSession()
            commitFormulaBar(formulaBar.field.stringValue, move: nil)
            window?.makeFirstResponder(grid)
        }
    }

    /// The name box: "B5", "A1:C10" or "Sheet2!A1" selects that place.
    private func goToReference(_ text: String) {
        defer {
            window?.makeFirstResponder(grid)
            refreshState()
        }
        var reference = text.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty else { return }
        if let bang = reference.lastIndex(of: "!") {
            let name = reference[..<bang].trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard let index = controller.workbook.sheetIndex(named: name) else { NSSound.beep(); return }
            controller.showSheet(id: controller.workbook.sheets[index].id)
            reference = String(reference[reference.index(after: bang)...])
        }
        guard let range = CellRange(a1: reference), range.end.row < controller.sheet.rowCount,
              range.end.column < controller.sheet.columnCount else {
            NSSound.beep()
            return
        }
        controller.selection = GridSelection(range: range)
        grid.scrollToVisible(range.start)
    }

    // MARK: Zoom

    func setZoom(_ zoom: CGFloat, snap: Bool = true) {
        var level = min(max(zoom, Theme.zoomLevels.first!), Theme.zoomLevels.last!)
        if snap { level = (level * 100).rounded() / 100 }
        guard abs(level - state.zoom) > 0.001 else { return }
        state.zoom = level
        grid.zoom = level
        grid.editor.map { _ in grid.positionEditor() }
    }

    // MARK: ChromeActions

    func rename(to title: String) {
        // A spreadsheet shared with this person is named by its owner.
        guard let document = spreadsheet, document.sharedCopy == nil else { return }
        guard let url = document.fileURL else {
            document.customTitle = title
            synchronizeWindowTitleWithDocumentName()
            return
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(title).appendingPathExtension(url.pathExtension)
        document.move(to: target) { [weak self] error in
            guard let self, error != nil else { return }
            // Sandboxed apps may not rename in place; ask where to save under the new name instead.
            let panel = NSSavePanel()
            panel.nameFieldStringValue = target.lastPathComponent
            panel.directoryURL = url.deletingLastPathComponent()
            panel.message = "Choose where to save “\(title)”."
            panel.beginSheetModal(for: self.window!) { response in
                guard response == .OK, let chosen = panel.url else {
                    self.updateStatus()
                    return
                }
                document.move(to: chosen) { _ in self.updateStatus() }
            }
        }
    }

    func showVersionHistory() {
        guard let document = spreadsheet else { return }
        if document.fileURL == nil {
            let alert = NSAlert()
            alert.messageText = "No versions yet"
            alert.informativeText = "Version history becomes available after the spreadsheet is saved to a file."
            alert.beginSheetModal(for: window!)
            return
        }
        document.browseVersions(nil)
    }

    func showCustomColorPanel(fill: Bool) {
        colorPanelTargetsFill = fill
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = false
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let color = RGBColor(sender.color) else { return }
        if colorPanelTargetsFill { controller.setFillColor(color) } else { controller.setTextColor(color) }
    }

    func dismissBanner() {
        state.banner = nil
    }

    func togglePaintFormat() {
        finishEditing()
        if grid.paintFormats != nil {
            grid.paintFormats = nil
            state.isPaintFormatActive = false
        } else {
            grid.paintFormats = controller.copiedFormats()
            grid.paintFormatSticky = NSEvent.modifierFlags.contains(.option)
            state.isPaintFormatActive = true
        }
        focusGrid()
    }

    func applyBorders(_ kind: BorderKind, line: BorderLine) {
        finishEditing()
        controller.applyBorders(kind, line: line)
        focusGrid()
    }

    func focusGrid() {
        window?.makeFirstResponder(grid)
    }

    func popUp(_ menu: ToolbarMenu, from view: NSView?) {
        finishEditing()
        guard let view else { return }
        ToolbarMenus.make(menu, controller: self).popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 3), in: view)
    }

    // MARK: Find and replace

    /// Shows the Find and replace dialog over the window; it stays open while you work in the sheet.
    func showFindReplace() {
        finishEditing()
        guard let window else { return }
        if let panel = findReplacePanel {
            panel.makeKeyAndOrderFront(nil)
            findReplace.state.focusRequest += 1
            return
        }
        if find.state.isVisible, findReplace.state.options.query.isEmpty { findReplace.state.options.query = find.state.query }
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = "Find and replace"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentViewController = NSHostingController(rootView: FindReplaceView(state: findReplace.state, controller: findReplace) { [weak panel] in
            panel?.close()
        })
        let observer = PanelCloseObserver { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.parent?.removeChildWindow(panel)
            self.findReplacePanel = nil
            self.findReplaceObserver = nil
            self.window?.makeFirstResponder(self.grid)
        }
        panel.delegate = observer
        findReplaceObserver = observer
        findReplacePanel = panel
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let frame = window.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + 60))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Filter

    func showFilterPopover(column: Int, at rect: CGRect) {
        finishEditing()
        guard let filter = controller.displayedFilter, allowsChanges() else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        let values = controller.filterValues(column: column)
        let view = FilterPopoverView(column: column, values: values, criterion: filter.criteria[column] ?? FilterCriterion(),
                                     apply: { [weak self] criterion in self?.controller.setDisplayedFilterCriterion(criterion, column: column) },
                                     sort: { [weak self] ascending in self?.controller.sortFilter(by: column, ascending: ascending) },
                                     close: { [weak popover] in popover?.performClose(nil) })
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: rect, of: grid, preferredEdge: .maxY)
    }

    // MARK: Sidebar

    func showSidebar(_ kind: SidebarKind) {
        finishEditing()
        state.sidebar = kind
        sidebarWidth.constant = 330
    }

    func closeSidebar() {
        state.sidebar = nil
        sidebarWidth.constant = 0
        focusGrid()
    }

    func select(_ range: CellRange) {
        controller.selection = GridSelection(range: range)
        grid.scrollToVisible(range.start)
    }

    // MARK: SheetBarActions

    func addSheet() {
        finishEditing()
        controller.addSheet()
        focusGrid()
    }

    func showSheet(_ id: UUID) {
        finishEditing()
        controller.showSheet(id: id)
        focusGrid()
    }

    func renameSheet(_ id: UUID, to name: String) -> String? {
        if let problem = controller.problem(renaming: id, to: name) { return problem }
        controller.renameSheet(id: id, to: name)
        return nil
    }

    func deleteSheet(_ id: UUID) {
        guard controller.workbook.sheets.count > 1, let index = controller.workbook.sheetIndex(id: id) else {
            NSSound.beep()
            return
        }
        let sheet = controller.workbook.sheets[index]
        guard !sheet.cells.isEmpty else {
            controller.deleteSheet(id: id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete “\(sheet.name)”?"
        alert.informativeText = "You can undo this with Edit ▸ Undo."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.controller.deleteSheet(id: id) }
        }
    }

    func duplicateSheet(_ id: UUID) { controller.duplicateSheet(id: id) }
    func moveSheet(_ id: UUID, by offset: Int) { controller.moveSheet(id: id, by: offset) }
    func setTabColor(_ id: UUID, _ color: RGBColor?) { controller.setTabColor(id: id, color) }

    func sheetMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        // Every item changes the spreadsheet, so none works while it can't be changed.
        let editable = state.isEditable
        menu.autoenablesItems = false
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
            let handler = MenuAction(action)
            item.target = handler
            item.representedObject = handler
            item.isEnabled = editable
            menu.addItem(item)
        }
        add("Delete") { [weak self] in self?.deleteSheet(id) }
        add("Duplicate") { [weak self] in self?.duplicateSheet(id) }
        add("Rename") { [weak self] in self?.state.renameSheetRequest += 1 }
        let colors = NSMenuItem(title: "Change color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        let reset = NSMenuItem(title: "Reset", action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
        let resetHandler = MenuAction { [weak self] in self?.setTabColor(id, nil) }
        reset.target = resetHandler
        reset.representedObject = resetHandler
        colorMenu.addItem(reset)
        for swatch in ColorPalette.brightRow + ColorPalette.shadeRows[3] {
            let item = NSMenuItem(title: swatch.name.capitalized, action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
            let handler = MenuAction { [weak self] in self?.setTabColor(id, RGBColor(hex: swatch.hex)) }
            item.target = handler
            item.representedObject = handler
            item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                swatch.color.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            colorMenu.addItem(item)
        }
        colors.submenu = colorMenu
        colors.isEnabled = editable
        menu.addItem(colors)
        menu.addItem(.separator())
        add("Move right") { [weak self] in self?.moveSheet(id, by: 1) }
        add("Move left") { [weak self] in self?.moveSheet(id, by: -1) }
        return menu
    }

    func showAllSheetsMenu(from view: NSView?) {
        guard let view else { return }
        let menu = NSMenu()
        for sheet in controller.workbook.sheets {
            let id = sheet.id
            let item = NSMenuItem(title: sheet.name, action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
            let handler = MenuAction { [weak self] in self?.showSheet(id) }
            item.target = handler
            item.representedObject = handler
            item.state = id == controller.activeSheetID ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 3), in: view)
    }

    func showStatisticsMenu(from view: NSView?) {
        guard let view else { return }
        let menu = NSMenu()
        for statistic in SelectionStatistic.allCases {
            guard let value = state.statistics.value(statistic) else { continue }
            let text = statistic == .count || statistic == .countNumbers ? Int(value).formatted()
                : EditorState.statisticText(value, format: state.statisticsFormat)
            let item = NSMenuItem(title: "\(statistic.title): \(text)", action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
            let handler = MenuAction { [weak self] in
                self?.state.statistic = statistic
                UserDefaults.standard.set(statistic.rawValue, forKey: SelectionStatistic.key)
            }
            item.target = handler
            item.representedObject = handler
            item.state = statistic == state.statistic ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 3), in: view)
    }
}

/// Lets a menu item run a closure. The item keeps it alive through `representedObject`.
final class MenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func perform(_ sender: Any?) { action() }
}
