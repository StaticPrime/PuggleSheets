import Foundation

/// Notes and comment threads as OpenDocument annotations (`office:annotation`), LibreOffice Calc's one
/// kind of cell comment: an author, a date and paragraphs, without replies or a resolved state.
///
/// - A note is written as the annotation's paragraphs.
/// - A thread is kept exactly in PuggleSheets' settings, and written as the annotation too, so
///   LibreOffice shows it: the first comment's author and date are the annotation's, its text the first
///   paragraphs, each reply follows as "Author: text", and "(Resolved)" ends a resolved thread.
/// - A cell with both writes its note, a blank paragraph, then every comment as "Author: text".
///
/// Without PuggleSheets' settings (a file LibreOffice saved), an annotation reads back as a note: a
/// flattened thread becomes a note of its text. Annotations from other apps are notes too.
enum ODSAnnotations {
    /// What a cell's annotation holds, as PuggleSheets' settings record it.
    enum Content: String {
        /// The flattened thread.
        case thread
        /// The note, then the flattened thread.
        case noteAndThread
    }

    /// The paragraphs, author and date of the annotation for a cell's note and thread; nil for neither.
    static func annotation(note: String?, thread: CommentThread?) -> (author: String?, date: Date?, paragraphs: [String])? {
        guard let thread, !thread.comments.isEmpty else {
            return note.map { (nil, nil, $0.components(separatedBy: "\n")) }
        }
        var paragraphs: [String] = []
        func add(_ comment: Comment, prefixed: Bool) {
            var lines = comment.text.components(separatedBy: "\n")
            if prefixed { lines[0] = "\(comment.author): " + lines[0] }
            paragraphs += lines
        }
        let first = thread.comments[0]
        if let note {
            paragraphs = note.components(separatedBy: "\n") + [""]
            for comment in thread.comments { add(comment, prefixed: true) }
        } else {
            add(first, prefixed: false)
            for reply in thread.comments.dropFirst() { add(reply, prefixed: true) }
        }
        if thread.isResolved { paragraphs.append("(Resolved)") }
        return note == nil ? (first.author.isEmpty ? nil : first.author, first.date, paragraphs) : (nil, nil, paragraphs)
    }

    /// The note an annotation for a cell's note and thread reads back as.
    static func text(note: String?, thread: CommentThread?) -> String? {
        annotation(note: note, thread: thread)?.paragraphs.joined(separator: "\n")
    }

    /// `office:annotation`, which goes first in its cell.
    static func write(note: String?, thread: CommentThread?) -> String? {
        guard let annotation = annotation(note: note, thread: thread) else { return nil }
        var xml = XMLWriter(fragmentCapacity: 256)
        xml.raw("<office:annotation>")
        if let author = annotation.author {
            xml.raw("<dc:creator>")
            xml.text(author)
            xml.raw("</dc:creator>")
        }
        if let date = annotation.date {
            xml.raw("<dc:date>\(isoDate(date))</dc:date>")
        }
        for paragraph in annotation.paragraphs { ODSWriter.writeParagraphs(paragraph, into: &xml) }
        xml.raw("</office:annotation>")
        return String(decoding: xml.bytes, as: UTF8.self)
    }

    /// "2026-11-16T10:05:00Z" (xsd:dateTime, UTC, whole seconds).
    static func isoDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))T\(pad(parts.hour, 2)):\(pad(parts.minute, 2)):\(pad(parts.second, 2))Z"
    }
}
