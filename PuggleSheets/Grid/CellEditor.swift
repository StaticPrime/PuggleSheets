import AppKit
import PuggleSheetsKit

/// The text view that edits a cell in place. It grows to the right (and down for line breaks) as
/// the text gets longer.
final class CellEditor: NSTextView {
    enum Entry {
        /// Started by typing over the cell: arrow keys finish the entry and move.
        case replace
        /// Started with Return, F2 or a double-click: arrow keys move the caret.
        case edit
    }

    let address: CellAddress
    let sheetID: UUID
    let entry: Entry
    private let localUndoManager = UndoManager()
    /// ⌘Return: commit to every selected cell.
    var onCommandReturn: (() -> Void)?

    init(address: CellAddress, sheetID: UUID, entry: Entry) {
        self.address = address
        self.sheetID = sheetID
        self.entry = entry
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        super.init(frame: .zero, textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isHorizontallyResizable = true
        isVerticallyResizable = true
        drawsBackground = true
        backgroundColor = .white
        focusRingType = .none
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        smartInsertDeleteEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The key being handled, so commands can tell Shift-Return from Return without relying on
    /// whatever event the app saw last.
    private(set) var currentKeyEvent: NSEvent?

    override func keyDown(with event: NSEvent) {
        currentKeyEvent = event
        defer { currentKeyEvent = nil }
        super.keyDown(with: event)
    }

    /// Typing undo stays inside the editor; the spreadsheet records the committed entry as one step.
    override var undoManager: UndoManager? { localUndoManager }

    override var isFlipped: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "\r" {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The width and height the text needs, plus the editor's insets.
    var neededSize: CGSize {
        guard let layoutManager, let textContainer else { return .zero }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).size
        return CGSize(width: ceil(used.width) + textContainerInset.width * 2 + 6, height: ceil(used.height) + textContainerInset.height * 2)
    }
}

extension GridView: NSTextViewDelegate {
    enum Move {
        case down, up, right, left
    }

    /// Starts editing the active cell. `text` replaces its content (typing over it); nil edits the existing content.
    func beginEditing(replacingWith text: String? = nil, entry: CellEditor.Entry) {
        guard editor == nil else { return }
        // A shared spreadsheet that can only be commented on (or hasn't come yet) can't be typed into.
        guard controller.state.isEditable else {
            NSSound.beep()
            if controller.state.access == .offline { controller.collaboration?.explainOffline() }
            return
        }
        let address = controller.selection.active
        scrollToVisible(address)
        let editor = CellEditor(address: address, sheetID: controller.activeSheetID, entry: entry)
        editor.delegate = self
        configure(editor)
        editor.string = text ?? controller.editText(at: address)
        editor.onCommandReturn = { [weak self] in self?.commitEditingToSelection() }
        addSubview(editor)
        self.editor = editor
        mirroredEditText = nil
        positionEditor()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        pointingRange = nil
        updateReferenceHighlights(text: editor.string, in: editor)
        onBeginEditing?(editor)
        needsDisplay = true
    }

    private func configure(_ editor: CellEditor) {
        let format = controller.sheet[editor.address].format
        let font = renderer.font(for: format, zoom: zoom)
        editor.font = font
        editor.textColor = (format.textColor ?? .black).nsColor
        editor.backgroundColor = (format.fillColor ?? .white).nsColor
        editor.insertionPointColor = .black
        editor.textContainerInset = NSSize(width: CellRenderer.horizontalPadding * zoom, height: CellRenderer.verticalPadding * zoom)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: font, .foregroundColor: editor.textColor ?? .black, .paragraphStyle: paragraph]
    }

    /// Places the editor over its cell, wide and tall enough for its text, just inside the blue
    /// border the grid draws around it (`editorBorderRect`).
    func positionEditor() {
        guard let editor else { return }
        let border = editorBorderRect(for: editor)
        editor.frame = border.insetBy(dx: 1, dy: 1)
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    /// The editor's outline: the cell, grown to fit the text up to the grid's right edge.
    func editorBorderRect(for editor: CellEditor) -> CGRect {
        let cell = rect(for: controller.mergedRange(at: editor.address))
        let needed = editor.neededSize
        let maxWidth = max(cell.width, gridBounds.maxX - cell.minX - 4)
        let width = min(max(cell.width, needed.width + 2), maxWidth)
        let height = max(cell.height, needed.height + 2)
        return CGRect(x: cell.minX, y: cell.minY, width: width, height: height)
    }

    /// Commits the entry and moves the active cell (inside a selected range, cycling through it).
    func commitEditing(move: Move? = nil) {
        guard let editor else { return }
        let text = editor.string
        let address = editor.address
        endEditing()
        var next: GridSelection?
        if let move { next = selection(after: move, from: address) }
        controller.commitInput(text, at: address, then: next)
        if let next { scrollToVisible(next.active) }
    }

    func commitEditingToSelection() {
        guard let editor else { return }
        let text = editor.string
        endEditing()
        controller.commitInputToSelection(text)
    }

    func cancelEditing() {
        guard editor != nil else { return }
        endEditing()
    }

    private func endEditing() {
        guard let editor else { return }
        let hadFocus = window?.firstResponder === editor
        editor.delegate = nil
        editor.removeFromSuperview()
        self.editor = nil
        formulaAssistant?.hide()
        pointingRange = nil
        pointingAnchor = nil
        formulaReferenceRanges = []
        if hadFocus || window?.firstResponder == nil || window?.firstResponder === window { window?.makeFirstResponder(self) }
        onEndEditing?()
        needsDisplay = true
    }

    /// Where Return, Tab and the arrows go after an entry: inside a selected range they cycle through it.
    func selection(after move: Move, from address: CellAddress) -> GridSelection {
        let current = controller.selection
        let range = current.current
        if !range.isSingleCell, range.contains(address) {
            var next = address
            switch move {
            case .down, .up:
                let step = move == .down ? 1 : -1
                next.row += step
                if !range.rows.contains(next.row) {
                    next.row = step > 0 ? range.start.row : range.end.row
                    next.column += step
                    if !range.columns.contains(next.column) { next.column = step > 0 ? range.start.column : range.end.column }
                }
            case .right, .left:
                let step = move == .right ? 1 : -1
                next.column += step
                if !range.columns.contains(next.column) {
                    next.column = step > 0 ? range.start.column : range.end.column
                    next.row += step
                    if !range.rows.contains(next.row) { next.row = step > 0 ? range.start.row : range.end.row }
                }
            }
            var result = current
            result.active = next
            return result
        }
        let merged = controller.mergedRange(at: address)
        var next = address
        switch move {
        case .down:
            next = CellAddress(row: rows.step(from: merged.end.row, by: 1), column: tabStartColumn ?? address.column)
        case .up:
            next = CellAddress(row: rows.step(from: merged.start.row, by: -1), column: address.column)
        case .right:
            next = CellAddress(row: address.row, column: columns.step(from: merged.end.column, by: 1))
        case .left:
            next = CellAddress(row: address.row, column: columns.step(from: merged.start.column, by: -1))
        }
        // Return after a run of Tabs goes back to the column the run started in.
        if move == .right || move == .left {
            if tabStartColumn == nil { tabStartColumn = address.column }
        } else {
            tabStartColumn = nil
        }
        return GridSelection(next)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let editor = textView as? CellEditor else { return false }
        if formulaAssistant?.handle(commandSelector, in: editor) == true { return true }
        let shift = (editor.currentKeyEvent ?? NSApp.currentEvent)?.modifierFlags.contains(.shift) ?? false
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitEditing(move: shift ? .up : .down)
            return true
        case #selector(NSResponder.insertTab(_:)):
            commitEditing(move: .right)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            commitEditing(move: .left)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEditing()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        default:
            break
        }
        // Typing over a cell, the arrows finish the entry (formulas keep the caret moving).
        if editor.entry == .replace, !editor.string.hasPrefix("=") {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)): commitEditing(move: .down); return true
            case #selector(NSResponder.moveUp(_:)): commitEditing(move: .up); return true
            case #selector(NSResponder.moveLeft(_:)): commitEditing(move: .left); return true
            case #selector(NSResponder.moveRight(_:)): commitEditing(move: .right); return true
            default: break
            }
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        guard let editor else { return }
        // Typing ends a pointed reference: the next click inserts a new one.
        if !isInsertingPointedReference { pointingRange = nil }
        updateReferenceHighlights(text: editor.string, in: editor)
        positionEditor()
        onEditorTextChange?(editor.string)
        formulaAssistant?.update(for: editor)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let editor, notification.object as? CellEditor === editor else { return }
        formulaAssistant?.update(for: editor)
    }
}
