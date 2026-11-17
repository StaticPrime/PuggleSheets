import AppKit
import PuggleSheetsKit
import SwiftUI

/// What the formula popup shows: names that complete what's typed, or help for the function the caret is in.
struct FormulaAssistContent: Equatable {
    struct Suggestion: Hashable {
        var name: String
        var detail: String
        var isFunction: Bool
    }

    var suggestions: [Suggestion] = []
    var highlighted = 0
    var typed = ""
    var help: FormulaFunctionInfo?
    var argument = 0

    var isEmpty: Bool { suggestions.isEmpty && help == nil }
}

/// Formula autocomplete and argument help, under the cell editor or the formula bar.
/// Up and down pick a suggestion, Tab or Return takes it, Esc closes the list.
final class FormulaAssistant {
    private weak var window: NSWindow?
    private var host: NSHostingView<FormulaAssistView>?
    private weak var textView: NSTextView?
    private var content = FormulaAssistContent()
    private var partialRange: NSRange?
    /// The name the list was closed for with Esc; it stays closed until the typed name changes.
    private var dismissedName: String?
    var namedRanges: () -> [NamedRange] = { [] }
    var tableNames: () -> [String] = { [] }

    init(window: NSWindow) {
        self.window = window
    }

    var isShowingSuggestions: Bool { host?.isHidden == false && !content.suggestions.isEmpty }

    /// Recomputes the popup for the text and caret of `textView`.
    func update(for textView: NSTextView) {
        self.textView = textView
        let caret = textView.selectedRange()
        guard caret.length == 0, let context = FormulaContext.at(caret.location, in: textView.string) else { return hide() }
        var next = FormulaAssistContent()
        if let partial = context.partialName {
            if partial.text != dismissedName {
                dismissedName = nil
                let prefix = partial.text.uppercased()
                let names = namedRanges().filter { $0.name.uppercased().hasPrefix(prefix) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .map { FormulaAssistContent.Suggestion(name: $0.name, detail: $0.reference, isFunction: false) }
                    + tableNames().filter { $0.uppercased().hasPrefix(prefix) }.sorted()
                    .map { FormulaAssistContent.Suggestion(name: $0, detail: "Table", isFunction: false) }
                let functions = FormulaEngine.functionInfo.filter { $0.name.hasPrefix(prefix) }
                    .sorted { Self.rank($0.name, typed: prefix) < Self.rank($1.name, typed: prefix) }
                    .map { FormulaAssistContent.Suggestion(name: $0.name, detail: $0.summary, isFunction: true) }
                next.suggestions = Array((names + functions).prefix(8))
                next.typed = partial.text
                partialRange = partial.range
                if next.typed == content.typed, next.suggestions == content.suggestions { next.highlighted = content.highlighted }
            }
        } else {
            dismissedName = nil
        }
        if let call = context.call, let info = FormulaEngine.functionInfo(named: call.name) {
            next.help = info
            next.argument = call.argument
        }
        guard !next.isEmpty else { return hide() }
        content = next
        show()
    }

    /// The functions people use most come first in the suggestions.
    private static let popular = ["SUM", "AVERAGE", "COUNT", "COUNTA", "IF", "IFERROR", "VLOOKUP", "XLOOKUP", "INDEX", "MATCH",
                                  "MAX", "MIN", "SUMIF", "SUMIFS", "COUNTIF", "COUNTIFS", "ROUND", "TODAY", "NOW", "DATE",
                                  "CONCATENATE", "LEFT", "RIGHT", "MID", "LEN", "TRIM", "UPPER", "LOWER", "UNIQUE", "FILTER",
                                  "SORT", "AND", "OR", "NOT", "ABS", "TEXT", "VALUE", "SPLIT", "JOIN", "AVERAGEIF"]
    private static let popularity = Dictionary(uniqueKeysWithValues: popular.enumerated().map { ($1, $0) })

    private static func rank(_ name: String, typed: String) -> (Int, Int, String) {
        (name == typed ? 0 : 1, popularity[name] ?? popular.count, name)
    }

    /// Keys the popup uses while its list is open. Returns true when it handled the key.
    func handle(_ selector: Selector, in textView: NSTextView) -> Bool {
        guard isShowingSuggestions, textView === self.textView else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            content.highlighted = (content.highlighted + 1) % content.suggestions.count
            show()
        case #selector(NSResponder.moveUp(_:)):
            content.highlighted = (content.highlighted - 1 + content.suggestions.count) % content.suggestions.count
            show()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
            accept(content.highlighted)
        case #selector(NSResponder.cancelOperation(_:)):
            dismissedName = content.typed
            update(for: textView)
        default:
            return false
        }
        return true
    }

    func hide() {
        host?.isHidden = true
        content = FormulaAssistContent()
        partialRange = nil
    }

    private func accept(_ index: Int) {
        guard let textView, let range = partialRange, content.suggestions.indices.contains(index),
              NSMaxRange(range) <= (textView.string as NSString).length else { return }
        let suggestion = content.suggestions[index]
        textView.insertText(suggestion.isFunction ? suggestion.name + "(" : suggestion.name, replacementRange: range)
        update(for: textView)
    }

    private func show() {
        guard let window, let contentView = window.contentView, let textView else { return }
        let view = FormulaAssistView(content: content) { [weak self] index in self?.accept(index) }
        let host: NSHostingView<FormulaAssistView>
        if let existing = self.host {
            existing.rootView = view
            host = existing
        } else {
            host = NSHostingView(rootView: view)
            host.sizingOptions = [.intrinsicContentSize]
            self.host = host
        }
        if host.superview !== contentView { contentView.addSubview(host, positioned: .above, relativeTo: nil) }
        host.isHidden = false
        let size = host.intrinsicContentSize
        // The formula bar's field editor scrolls inside a clip view the size of the field.
        let anchorView: NSView = (textView.superview as? NSClipView) ?? textView
        let anchor = contentView.convert(anchorView.bounds, from: anchorView)
        // The view draws an 8-point margin around its card for the shadow.
        var frame = NSRect(x: anchor.minX - 8, y: 0, width: size.width, height: size.height)
        let bounds = contentView.bounds
        if contentView.isFlipped {
            frame.origin.y = anchor.maxY - 4
            if frame.maxY > bounds.maxY { frame.origin.y = anchor.minY - size.height + 4 }
        } else {
            frame.origin.y = anchor.minY - size.height + 4
            if frame.minY < bounds.minY { frame.origin.y = anchor.maxY - 4 }
        }
        frame.origin.x = max(bounds.minX, min(frame.origin.x, bounds.maxX - size.width))
        host.frame = frame
    }
}

struct FormulaAssistView: View {
    let content: FormulaAssistContent
    let accept: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !content.suggestions.isEmpty {
                ForEach(Array(content.suggestions.enumerated()), id: \.offset) { index, suggestion in
                    HStack(spacing: 12) {
                        Text(Self.name(suggestion.name, typed: content.typed))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.primaryText)
                            .fixedSize()
                        Text(suggestion.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(index == content.highlighted ? Color(red: 0xF1 / 255, green: 0xF3 / 255, blue: 0xF4 / 255) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { accept(index) }
                }
            } else if let help = content.help {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.syntax(help.syntax, argument: content.argument))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.primaryText)
                    Text("Summary").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText).padding(.top, 4)
                    Text(help.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .padding(.vertical, content.suggestions.isEmpty ? 0 : 6)
        .frame(width: content.suggestions.isEmpty ? 360 : 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white).shadow(color: .black.opacity(0.28), radius: 4, y: 1))
        .padding(8)
    }

    /// The name with the typed part in bold.
    static func name(_ name: String, typed: String) -> AttributedString {
        let count = min(typed.count, name.count)
        var bold = AttributedString(String(name.prefix(count)))
        bold.font = .system(size: 13, weight: .bold)
        return bold + AttributedString(String(name.dropFirst(count)))
    }

    /// "SUM(value1, [value2, ...])" with the argument the caret is in highlighted.
    static func syntax(_ syntax: String, argument: Int) -> AttributedString {
        guard let open = syntax.firstIndex(of: "("), let close = syntax.lastIndex(of: ")"), open < close else {
            return AttributedString(syntax)
        }
        let inner = syntax[syntax.index(after: open)..<close]
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in inner {
            if character == "[" { depth += 1 } else if character == "]" { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
        var active: Int?
        if argument < parts.count {
            active = argument
        } else if let last = parts.last, last.contains("...") {
            active = parts.count - 1
        }
        var result = AttributedString(String(syntax[..<open]) + "(")
        for (index, part) in parts.enumerated() {
            if index > 0 { result += AttributedString(", ") }
            var piece = AttributedString(part)
            if index == active {
                piece.font = .system(size: 13, weight: .bold)
                piece.backgroundColor = Color(red: 0xFD / 255, green: 0xE2 / 255, blue: 0x93 / 255).opacity(0.6)
            }
            result += piece
        }
        return result + AttributedString(")")
    }
}
