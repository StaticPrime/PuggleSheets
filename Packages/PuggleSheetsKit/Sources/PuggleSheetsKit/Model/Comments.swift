import Foundation

/// One comment in a thread (the first is the comment itself, the rest are replies).
public struct Comment: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var author: String
    /// In a shared spreadsheet, who wrote it: their iCloud identity. Nil for comments made before it was shared.
    public var authorID: String?
    public var date: Date
    public var text: String
    /// When the text was last changed, if it was.
    public var editedDate: Date?

    public init(id: UUID = UUID(), author: String, authorID: String? = nil, date: Date = Date(), text: String, editedDate: Date? = nil) {
        self.id = id
        self.author = author
        self.authorID = authorID
        self.date = date
        self.text = text
        self.editedDate = editedDate
    }
}

/// Insert ▸ Comment: a discussion attached to a cell. Resolved threads stay with the cell but no
/// longer mark it.
public struct CommentThread: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var comments: [Comment]
    public var isResolved: Bool

    public init(id: UUID = UUID(), comments: [Comment], isResolved: Bool = false) {
        self.id = id
        self.comments = comments
        self.isResolved = isResolved
    }

    /// The same discussion with new identities for the thread and each comment: for a copy of it, kept apart from
    /// the original.
    public func copiedAnew() -> CommentThread {
        CommentThread(comments: comments.map { Comment(author: $0.author, authorID: $0.authorID, date: $0.date, text: $0.text,
                                                        editedDate: $0.editedDate) },
                      isResolved: isResolved)
    }
}
