import Foundation

/// One cell: an entered value or a formula with its latest result, plus formatting, and optionally a
/// link or an image.
public struct Cell: Hashable, Sendable {
    /// The entered value, or the formula's most recent result.
    public var value: CellValue
    /// The formula with its leading "=" ("=SUM(A1:A3)"), or nil for an entered value.
    public var formula: String?
    public var format: CellFormat
    /// Insert ▸ Link: where the cell's text links to (see `LinkTarget`).
    public var link: String?
    /// Insert ▸ Image ▸ Insert image in cell. The image takes the place of a value.
    public var image: CellImage?
    /// Insert ▸ Note: plain text shown when pointing at the cell.
    public var note: String?
    /// Insert ▸ Comment: the cell's discussion.
    public var comment: CommentThread?

    public init(value: CellValue = .empty, formula: String? = nil, format: CellFormat = CellFormat(),
                link: String? = nil, image: CellImage? = nil, note: String? = nil, comment: CommentThread? = nil) {
        self.value = value
        self.formula = formula
        self.format = format
        self.link = link
        self.image = image
        self.note = note
        self.comment = comment
    }

    /// Holds a value, a formula or an image (formatting alone doesn't count).
    public var hasContent: Bool { formula != nil || value != .empty || image != nil }

    /// Neither content, formatting, a link, a note nor a comment: nothing worth storing.
    public var isEmpty: Bool { !hasContent && format.isDefault && link == nil && note == nil && comment == nil }
}
