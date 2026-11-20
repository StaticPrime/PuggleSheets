import Foundation

/// What someone has changed in a shared spreadsheet since the people they share it with were last told, and the short
/// summary that tells them: which cells changed on which sheets, rows, columns and sheets added or taken out,
/// formatting, and comments; not every change.
public struct ChangeTally: Equatable, Sendable {
    /// Cells whose content changed, by sheet name, in the order the sheets were first edited.
    private var editedCells: [String: Set<CellAddress>] = [:]
    private var editedSheetOrder: [String] = []
    public private(set) var formattingChanged = false
    public private(set) var rowsInserted = 0
    public private(set) var rowsDeleted = 0
    public private(set) var columnsInserted = 0
    public private(set) var columnsDeleted = 0
    public private(set) var cellsShifted = false
    public private(set) var sheetsAdded = 0
    public private(set) var sheetsDeleted = 0
    public private(set) var sheetsRenamed = 0
    public private(set) var namedRangesChanged = false
    public private(set) var commentsAdded = 0
    public private(set) var repliesAdded = 0
    public private(set) var commentsResolved = 0
    /// The words of the latest comment or reply.
    public private(set) var commentExcerpt: String?

    public init() {}

    public var isEmpty: Bool { self == ChangeTally() }

    public var cellsEdited: Int { editedCells.values.reduce(0) { $0 + $1.count } }

    // MARK: Counting

    /// A change made here, to `workbook` as it was just before.
    public mutating func record(_ ops: [WorkbookOp], before workbook: Workbook) {
        var workbook = workbook
        for (index, op) in ops.enumerated() {
            switch op {
            case .cells(let id, let cells):
                guard let index = workbook.sheetIndex(id: id) else { break }
                let sheet = workbook.sheets[index]
                for (address, cell) in cells {
                    let old = sheet.cells[address]?.withoutComment ?? Cell()
                    if old.value != cell.value || old.formula != cell.formula || old.note != cell.note || old.link != cell.link
                        || old.image != cell.image {
                        if editedCells[sheet.name] == nil { editedSheetOrder.append(sheet.name) }
                        editedCells[sheet.name, default: []].insert(address)
                    } else if old.format != cell.format {
                        formattingChanged = true
                    }
                }
            case .layout(_, let patch):
                if !patch.isEmpty { formattingChanged = true }
            case .structure(_, let change):
                switch change {
                case .insertRows(_, let count): rowsInserted += count
                case .deleteRows(_, let count): rowsDeleted += count
                case .insertColumns(_, let count): columnsInserted += count
                case .deleteColumns(_, let count): columnsDeleted += count
                case .insertCells, .deleteCells: cellsShifted = true
                }
            case .insertSheet: sheetsAdded += 1
            case .removeSheet: sheetsDeleted += 1
            case .renameSheet: sheetsRenamed += 1
            case .moveSheet: break
            case .namedRanges: namedRangesChanged = true
            }
            // The workbook as the next op finds it (not after the last: that would copy every cell for nothing).
            if index < ops.count - 1 { workbook.apply(op) }
        }
    }

    public mutating func recordComment(_ text: String) {
        commentsAdded += 1
        commentExcerpt = Self.excerpt(text)
    }

    public mutating func recordReply(_ text: String) {
        repliesAdded += 1
        commentExcerpt = Self.excerpt(text)
    }

    public mutating func recordResolved() { commentsResolved += 1 }

    private static func excerpt(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return words.count > 70 ? String(words.prefix(70)) + "…" : words
    }

    // MARK: Words

    /// The notification: a title naming who changed which spreadsheet, and a line saying roughly what they did. Nil
    /// when there's nothing to tell.
    public func notice(author: String, documentTitle: String) -> (title: String, body: String)? {
        guard !isEmpty else { return nil }
        let name = author.isEmpty ? "Someone" : author
        let title = documentTitle.count > 48 ? String(documentTitle.prefix(47)) + "…" : documentTitle
        let edited = cellsEdited > 0 || formattingChanged || rowsInserted + rowsDeleted + columnsInserted + columnsDeleted > 0
            || cellsShifted || sheetsAdded + sheetsDeleted + sheetsRenamed > 0 || namedRangesChanged
        let commented = commentsAdded + repliesAdded + commentsResolved > 0
        if !edited, !commented { return nil }
        if !edited {
            let heading = commentsAdded == 0 && repliesAdded > 0 ? "\(name) replied in “\(title)”"
                : (commentsAdded == 0 && repliesAdded == 0 ? "\(name) resolved comments in “\(title)”" : "\(name) commented on “\(title)”")
            if commentsAdded + repliesAdded == 1, commentsResolved == 0, let commentExcerpt {
                return (heading, "“\(commentExcerpt)”")
            }
            return (heading, Self.sentence(commentParts))
        }
        var parts: [String] = []
        let cells = cellsEdited
        if cells > 0 {
            let sheets = editedSheetOrder.filter { !(editedCells[$0]?.isEmpty ?? true) }
            if sheets.count == 1 {
                parts.append("edited " + Self.count(cells, "cell") + " on " + sheets[0])
            } else {
                parts.append("edited " + Self.count(cells, "cell") + " on \(sheets.count) sheets")
            }
        }
        if rowsInserted > 0 { parts.append("inserted " + Self.count(rowsInserted, "row", exact: true)) }
        if rowsDeleted > 0 { parts.append("deleted " + Self.count(rowsDeleted, "row", exact: true)) }
        if columnsInserted > 0 { parts.append("inserted " + Self.count(columnsInserted, "column", exact: true)) }
        if columnsDeleted > 0 { parts.append("deleted " + Self.count(columnsDeleted, "column", exact: true)) }
        if cellsShifted { parts.append("moved cells") }
        if sheetsAdded > 0 { parts.append("added " + Self.count(sheetsAdded, "sheet", exact: true)) }
        if sheetsDeleted > 0 { parts.append("deleted " + Self.count(sheetsDeleted, "sheet", exact: true)) }
        if sheetsRenamed > 0 { parts.append("renamed " + Self.count(sheetsRenamed, "sheet", exact: true)) }
        if formattingChanged { parts.append("changed the formatting") }
        if namedRangesChanged { parts.append("changed the named ranges") }
        parts += commentParts
        return ("\(name) edited “\(title)”", Self.sentence(parts))
    }

    private var commentParts: [String] {
        var parts: [String] = []
        if commentsAdded > 0 { parts.append("added " + Self.count(commentsAdded, "comment", exact: true)) }
        if repliesAdded > 0 { parts.append(repliesAdded == 1 ? "replied to a comment" : "added \(repliesAdded) replies") }
        if commentsResolved > 0 { parts.append("resolved " + Self.count(commentsResolved, "comment", exact: true)) }
        return parts
    }

    /// "a cell", "3 cells", "about 120 cells".
    private static func count(_ value: Int, _ noun: String, exact: Bool = false) -> String {
        if value == 1 { return (noun.first.map { "aeiou".contains($0) } ?? false ? "an " : "a ") + noun }
        if !exact, value >= 20 {
            let rounded = value >= 100 ? (value + 5) / 10 * 10 : value
            return "about \(rounded) \(noun)s"
        }
        return "\(value) \(noun)s"
    }

    /// "Edited 3 cells on Budget, inserted a row and added a comment."
    private static func sentence(_ parts: [String]) -> String {
        guard var first = parts.first else { return "" }
        first = first.prefix(1).uppercased() + first.dropFirst()
        let all = [first] + parts.dropFirst()
        let joined = all.count <= 1 ? all.joined() : all.dropLast().joined(separator: ", ") + " and " + all.last!
        return joined + "."
    }
}
