import Foundation

/// One comment in a thread (the first is the comment itself, the rest are replies).
public struct Comment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var author: String
    public var date: Date
    public var text: String
    /// When the text was last changed, if it was.
    public var editedDate: Date?

    public init(id: UUID = UUID(), author: String, date: Date = Date(), text: String, editedDate: Date? = nil) {
        self.id = id
        self.author = author
        self.date = date
        self.text = text
        self.editedDate = editedDate
    }
}

/// Insert ▸ Comment: a discussion attached to a cell. Resolved threads stay with the cell but no
/// longer mark it.
public struct CommentThread: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var comments: [Comment]
    public var isResolved: Bool

    public init(id: UUID = UUID(), comments: [Comment], isResolved: Bool = false) {
        self.id = id
        self.comments = comments
        self.isResolved = isResolved
    }
}
