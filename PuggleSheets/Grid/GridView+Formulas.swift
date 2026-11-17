import AppKit
import PuggleSheetsKit

/// While a formula is being typed: its references are colored in the editor and outlined in the
/// grid, and clicking or dragging over cells inserts their references.
extension GridView {
    /// Reference colors, in order of first appearance.
    static let referenceColors: [NSColor] = [
        GridColors.rgb(0x4285F4), GridColors.rgb(0xEA4335), GridColors.rgb(0xA142F4), GridColors.rgb(0x34A853),
        GridColors.rgb(0xF4B400), GridColors.rgb(0x24C1E0), GridColors.rgb(0xF538A0), GridColors.rgb(0xE8710A),
    ]

    /// Colors each distinct reference in `text` and returns the ranges to outline in the grid.
    func referenceHighlights(in text: String) -> (spans: [(NSRange, NSColor)], ranges: [(CellRange, NSColor)]) {
        guard text.hasPrefix("=") else { return ([], []) }
        var colors: [String: NSColor] = [:]
        var spans: [(NSRange, NSColor)] = []
        var ranges: [(CellRange, NSColor)] = []
        let string = text as NSString
        let sheetName = controller.sheet.name
        for reference in FormulaReferences.references(in: text, workbook: controller.workbook) {
            let span = NSRange(location: reference.location, length: reference.length)
            guard NSMaxRange(span) <= string.length else { continue }
            let key = string.substring(with: span).uppercased()
            let color = colors[key] ?? Self.referenceColors[colors.count % Self.referenceColors.count]
            colors[key] = color
            spans.append((span, color))
            if reference.sheet == nil || reference.sheet?.caseInsensitiveCompare(sheetName) == .orderedSame {
                ranges.append((reference.range(rowCount: sheet.rowCount, columnCount: sheet.columnCount), color))
            }
        }
        return (spans, ranges)
    }

    /// Recolors the editor's references and refreshes the outlines in the grid.
    func updateReferenceHighlights(text: String, in textView: NSTextView?) {
        let highlights = referenceHighlights(in: text)
        if let textView, let storage = textView.textStorage {
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: textView.textColor ?? .black, range: whole)
            for (span, color) in highlights.spans where NSMaxRange(span) <= storage.length {
                storage.addAttribute(.foregroundColor, value: color, range: span)
            }
            storage.endEditing()
        }
        formulaReferenceRanges = highlights.ranges
        needsDisplay = true
    }

    func drawReferenceHighlights(in pane: Pane) {
        for (range, color) in formulaReferenceRanges {
            let rect = self.rect(for: range, xMode: pane.xMode, yMode: pane.yMode)
            guard rect.intersects(pane.rect) else { continue }
            color.withAlphaComponent(0.12).setFill()
            rect.fill()
            color.setStroke()
            let outline = NSBezierPath(rect: rect.offsetBy(dx: -0.5, dy: -0.5))
            outline.lineWidth = 2
            outline.stroke()
        }
    }

    // MARK: Pointing at cells

    /// Whether clicking a cell should insert a reference at the editor's caret: the formula is
    /// waiting for an operand (after "=", "(", "," or an operator), or the caret sits right after a
    /// reference inserted by pointing.
    func canPoint(in editor: CellEditor) -> Bool {
        guard editor.string.hasPrefix("=") else { return false }
        let selected = editor.selectedRange()
        if let pointing = pointingRange, NSMaxRange(pointing) == selected.location || pointing == selected { return true }
        let before = (editor.string as NSString).substring(to: selected.location)
        guard let last = before.last(where: { $0 != " " }) else { return false }
        return "=(,+-*/^&<>:;{".contains(last)
    }

    /// Starts or extends a reference by pointing: replaces the previously pointed reference, if any.
    func insertPointedReference(_ range: CellRange, in editor: CellEditor) {
        let text = range.isSingleCell ? range.start.a1 : range.a1
        let target: NSRange
        if let pointing = pointingRange, NSMaxRange(pointing) <= (editor.string as NSString).length {
            target = pointing
        } else {
            target = editor.selectedRange()
        }
        isInsertingPointedReference = true
        editor.insertText(text, replacementRange: target)
        isInsertingPointedReference = false
        pointingRange = NSRange(location: target.location, length: (text as NSString).length)
        editor.setSelectedRange(NSRange(location: NSMaxRange(pointingRange!), length: 0))
    }
}
