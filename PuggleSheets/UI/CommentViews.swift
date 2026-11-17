import AppKit
import PuggleSheetsKit
import SwiftUI

/// A round badge with someone's initials, in a color that stays the same for a name.
struct AvatarView: View {
    let name: String
    var size: CGFloat = 28

    static let colors: [Color] = [
        Color(red: 0.10, green: 0.45, blue: 0.91), Color(red: 0.85, green: 0.19, blue: 0.15), Color(red: 0.12, green: 0.56, blue: 0.24),
        Color(red: 0.91, green: 0.44, blue: 0.04), Color(red: 0.56, green: 0.27, blue: 0.68), Color(red: 0.00, green: 0.54, blue: 0.58),
    ]

    var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        let index = abs(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % Self.colors.count
        Circle()
            .fill(Self.colors[index])
            .frame(width: size, height: size)
            .overlay(Text(initials).font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(Color.white))
    }
}

/// How comments are dated: "2:45 PM Today", "Nov 14".
func commentDateText(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) + " Today" }
    if calendar.isDateInYesterday(date) { return date.formatted(date: .omitted, time: .shortened) + " Yesterday" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

/// The note shown beside a cell when pointing at it.
struct NotePopupView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: 220, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white).shadow(color: .black.opacity(0.3), radius: 3, y: 1))
            .padding(6)
            .fixedSize()
    }
}

/// Insert ▸ Note: the note's text, saved when the editor closes.
struct NoteEditorView: View {
    @State var text: String
    let save: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .focused($focused)
            .frame(width: 240, height: 120)
            .padding(8)
            .background(Color.white)
            .onAppear { focused = true }
            .onDisappear { save(text) }
    }
}

/// A comment thread beside its cell: the comments, a reply box, and resolve, edit and delete.
/// Without a thread it's the composer for a new comment.
struct CommentCardView: View {
    let thread: CommentThread?
    let author: String
    let post: (String) -> Void
    let edit: (UUID, String) -> Void
    let delete: (UUID) -> Void
    let resolve: () -> Void
    let close: () -> Void
    @State private var reply = ""
    @State private var editing: UUID?
    @State private var editText = ""
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let thread {
                ForEach(Array(thread.comments.enumerated()), id: \.element.id) { index, comment in
                    commentRow(comment, isFirst: index == 0)
                }
            } else {
                HStack(spacing: 8) {
                    AvatarView(name: author)
                    Text(author).font(.system(size: 13, weight: .medium))
                }
            }
            VStack(alignment: .trailing, spacing: 8) {
                TextField(thread == nil ? "Comment" : "Reply", text: $reply, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($replyFocused)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(replyFocused ? Theme.accent : Theme.divider, lineWidth: replyFocused ? 2 : 1))
                    .onSubmit(send)
                if thread == nil || !reply.isEmpty || replyFocused {
                    HStack {
                        PanelButton(title: "Cancel", primary: false) {
                            reply = ""
                            if thread == nil { close() } else { replyFocused = false }
                        }
                        PanelButton(title: thread == nil ? "Comment" : "Reply", isEnabled: !reply.trimmingCharacters(in: .whitespaces).isEmpty) { send() }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white).shadow(color: .black.opacity(0.28), radius: 5, y: 2))
        .padding(8)
        .onAppear { if thread == nil { replyFocused = true } }
        .onExitCommand { close() }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply = ""
        post(text)
    }

    @ViewBuilder private func commentRow(_ comment: Comment, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                AvatarView(name: comment.author)
                VStack(alignment: .leading, spacing: 1) {
                    Text(comment.author).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(commentDateText(comment.date) + (comment.editedDate == nil ? "" : " (edited)"))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 4)
                if isFirst {
                    ToolbarIconButton(symbol: "checkmark", help: "Mark as resolved and hide discussion") { resolve() }
                }
                Menu {
                    Button("Edit") {
                        editing = comment.id
                        editText = comment.text
                    }
                    Button(isFirst ? "Delete thread" : "Delete") { delete(comment.id) }
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).foregroundStyle(Theme.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if editing == comment.id {
                TextField("", text: $editText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                HStack {
                    Spacer()
                    PanelButton(title: "Cancel", primary: false) { editing = nil }
                    PanelButton(title: "Save") {
                        edit(comment.id, editText)
                        editing = nil
                    }
                }
            } else {
                Text(comment.text).font(.system(size: 13)).foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The comment history: every comment thread in the spreadsheet, open or resolved.
struct CommentsPanel: View {
    let state: EditorState
    let actions: SidebarActions
    let open: (_ sheetIndex: Int, _ address: CellAddress) -> Void
    @State private var filter = 0

    private var controller: SpreadsheetController { actions.controller }

    var body: some View {
        let _ = state.ruleRevision
        let threads = controller.commentThreads().filter { filter == 0 || (filter == 1 ? !$0.thread.isResolved : $0.thread.isResolved) }
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $filter) {
                Text("All").tag(0)
                Text("Open").tag(1)
                Text("Resolved").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if threads.isEmpty {
                Text(filter == 2 ? "No resolved comments." : "No comments yet. Select a cell and choose Insert ▸ Comment (⌥⌘M).")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(threads, id: \.thread.id) { item in
                let sheetName = controller.workbook.sheets[item.sheetIndex].name
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(sheetName)!\(item.address.a1)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                        Spacer()
                        if item.thread.isResolved {
                            Text("Resolved").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if let first = item.thread.comments.first {
                        HStack(spacing: 8) {
                            AvatarView(name: first.author, size: 22)
                            Text(first.author).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(commentDateText(first.date)).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        }
                        Text(first.text).font(.system(size: 13)).lineLimit(3)
                    }
                    if item.thread.comments.count > 1 {
                        Text(item.thread.comments.count == 2 ? "1 reply" : "\(item.thread.comments.count - 1) replies")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                    if item.thread.isResolved {
                        Button("Reopen") {
                            open(item.sheetIndex, item.address)
                            controller.setCommentResolved(false, at: item.address)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider))
                .contentShape(Rectangle())
                .onTapGesture { open(item.sheetIndex, item.address) }
            }
        }
    }
}
