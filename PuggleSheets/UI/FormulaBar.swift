import AppKit
import PuggleSheetsKit

/// The bar under the toolbar: the name box (the selection's reference), "fx", and the active cell's
/// formula or value, which can be edited here as well as in the cell.
final class FormulaBar: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 30

    let nameBox = NSTextField()
    let field = NSTextField()
    private let fxLabel = NSTextField(labelWithString: "fx")

    /// The formula field is being edited.
    private(set) var isEditing = false
    var onNameBoxCommit: ((String) -> Void)?
    var onBeginEditing: (() -> Void)?
    var onTextChange: ((String) -> Void)?
    var onCommit: ((String, GridView.Move?) -> Void)?
    var onCancel: (() -> Void)?
    /// Offered every key command in the formula field first (the formula popup uses up, down, Tab, Return and Esc).
    var onCommand: ((Selector, NSTextView) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.canvas.cgColor
        for textField in [nameBox, field] {
            textField.isBordered = false
            textField.drawsBackground = false
            textField.focusRingType = .none
            textField.delegate = self
            textField.font = .systemFont(ofSize: 13)
            textField.textColor = NSColor(srgbRed: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255, alpha: 1)
            textField.cell?.isScrollable = true
            textField.cell?.wraps = false
            textField.lineBreakMode = .byClipping
            addSubview(textField)
        }
        nameBox.alignment = .left
        nameBox.toolTip = "Name box: type a cell or range, like B5 or A1:C10, and press Return"
        field.placeholderString = ""
        fxLabel.font = NSFontManager.shared.convert(.systemFont(ofSize: 14), toHaveTrait: .italicFontMask)
        fxLabel.textColor = NSColor(srgbRed: 0x44 / 255, green: 0x47 / 255, blue: 0x46 / 255, alpha: 0.75)
        addSubview(fxLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let height = bounds.height
        nameBox.frame = NSRect(x: 12, y: (height - 18) / 2, width: 88, height: 18)
        fxLabel.sizeToFit()
        fxLabel.frame.origin = NSPoint(x: 116, y: (height - fxLabel.frame.height) / 2)
        field.frame = NSRect(x: 144, y: (height - 18) / 2, width: max(0, bounds.width - 156), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.canvas.setFill()
        bounds.fill()
        GridColors.headerLine.setFill()
        NSRect(x: 106, y: 6, width: 1, height: bounds.height - 12).fill()
        NSRect(x: 136, y: 6, width: 1, height: bounds.height - 12).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// Shows the selection and the active cell's content when not editing.
    func show(reference: String, text: String, spillingFormula: String? = nil) {
        if nameBox.currentEditor() == nil, nameBox.stringValue != reference { nameBox.stringValue = reference }
        if !isEditing, field.stringValue != text { field.stringValue = text }
        // A cell an array formula spilled into shows that formula, grayed out.
        let placeholder = spillingFormula ?? ""
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    /// Mirrors text typed into the cell.
    func mirror(_ text: String) {
        if !isEditing { field.stringValue = text }
    }

    func endEditingSession() {
        isEditing = false
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === field else { return }
        isEditing = true
        onBeginEditing?()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === field else { return }
        onTextChange?(field.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === field, isEditing else { return }
        // Leaving the field (clicking elsewhere) keeps what was typed.
        isEditing = false
        onCommit?(field.stringValue, nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === nameBox {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                onNameBoxCommit?(nameBox.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onNameBoxCommit?("")
                return true
            default:
                return false
            }
        }
        if onCommand?(commandSelector, textView) == true { return true }
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            finish(move: shift ? .up : .down)
            return true
        case #selector(NSResponder.insertTab(_:)):
            finish(move: .right)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            finish(move: .left)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            isEditing = false
            onCancel?()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        default:
            return false
        }
    }

    private func finish(move: GridView.Move) {
        let text = field.stringValue
        isEditing = false
        onCommit?(text, move)
    }
}
