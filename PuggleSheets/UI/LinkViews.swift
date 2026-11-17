import AppKit
import PuggleSheetsKit
import SwiftUI

/// Insert ▸ Link (⌘K): the cell's text and where it links to, with the spreadsheet's sheets and named
/// ranges to pick from.
struct InsertLinkView: View {
    @State var text: String
    @State var link: String
    let sheets: [(id: UUID, name: String)]
    let namedRanges: [String]
    let hasLink: Bool
    let apply: (_ text: String, _ link: String) -> Void
    let remove: () -> Void
    let close: () -> Void
    @FocusState private var linkFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelField(placeholder: "Text", text: $text)
            PanelField(placeholder: "Search or paste a link", text: $link)
                .focused($linkFocused)
                .onSubmit { commit() }
            if suggestions.isEmpty == false {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions, id: \.link) { suggestion in
                        Button {
                            link = suggestion.link
                            if text.isEmpty { text = suggestion.title }
                            commit()
                        } label: {
                            Label(suggestion.title, systemImage: suggestion.symbol)
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
                .frame(maxHeight: 180)
            }
            HStack {
                if hasLink {
                    PanelButton(title: "Remove link", primary: false) {
                        remove()
                        close()
                    }
                }
                Spacer()
                PanelButton(title: "Apply", isEnabled: !link.trimmingCharacters(in: .whitespaces).isEmpty) { commit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { linkFocused = true }
    }

    private struct Suggestion {
        var title: String
        var link: String
        var symbol: String
    }

    /// Sheets and named ranges matching what's typed (all of them while the field is empty).
    private var suggestions: [Suggestion] {
        let query = link.trimmingCharacters(in: .whitespaces)
        guard !query.contains("://"), !query.contains("."), !query.hasPrefix("#") else { return [] }
        let sheetItems = sheets.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map { Suggestion(title: $0.name, link: LinkTarget.sheet($0.id, nil).link, symbol: "tablecells") }
        let nameItems = namedRanges.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .map { Suggestion(title: $0, link: LinkTarget.namedRange($0).link, symbol: "tag") }
        return Array((sheetItems + nameItems).prefix(8))
    }

    private func commit() {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        apply(text, LinkTarget.normalizedURL(trimmed))
        close()
    }
}

/// The card shown under a linked cell: where it goes, and copy, edit and remove buttons.
struct LinkCardView: View {
    let title: String
    let isInternal: Bool
    let open: () -> Void
    let copy: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isInternal ? "tablecells" : "globe")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            Button(action: open) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0x11 / 255, green: 0x55 / 255, blue: 0xCC / 255))
                    .underline()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(isInternal ? "Go to this place" : "Open in your browser")
            Divider().frame(height: 18)
            ToolbarIconButton(symbol: "doc.on.doc", help: "Copy link") { copy() }
            ToolbarIconButton(symbol: "pencil", help: "Edit link") { edit() }
            ToolbarIconButton(symbol: "xmark.circle", help: "Remove link") { remove() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white).shadow(color: .black.opacity(0.25), radius: 4, y: 1))
        .padding(8)
        .fixedSize()
    }
}

/// The dark bar across the top of the grid while a filter view is open: its name and range, options and close.
struct FilterViewBar: View {
    let state: EditorState
    let controller: SpreadsheetController
    let close: () -> Void

    var body: some View {
        let _ = state.ruleRevision
        if let view = controller.activeFilterView {
            HStack(spacing: 12) {
                Text("Name").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.8))
                CommitField(placeholder: "Filter 1", value: view.name) { name in
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    controller.updateFilterView(id: view.id, actionName: "Rename Filter View") { $0.name = trimmed }
                }
                .frame(width: 160)
                .colorScheme(.dark)
                Text("Range").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.8))
                CommitField(placeholder: "A1:D20", value: view.range.a1) { text in
                    guard let range = CellRange(a1: text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")) else { return }
                    controller.updateFilterView(id: view.id, actionName: "Update Filter View Range") { $0.range = range }
                }
                .frame(width: 120)
                .colorScheme(.dark)
                Menu {
                    Button("Duplicate") { controller.duplicateFilterView(id: view.id) }
                    Button("Delete") { controller.deleteFilterView(id: view.id) }
                } label: {
                    Image(systemName: "gearshape").foregroundStyle(Color.white)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close filter view")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .background(Color(red: 0x3C / 255, green: 0x40 / 255, blue: 0x43 / 255))
        }
    }
}
