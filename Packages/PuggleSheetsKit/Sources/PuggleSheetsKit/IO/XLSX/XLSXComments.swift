import Foundation

/// Notes as Excel's notes (legacy comments, xl/commentsN.xml, shown through a VML drawing) and comment
/// threads as Excel's threaded comments (xl/threadedComments/threadedCommentN.xml with the workbook's
/// persons), each with the legacy copy Excel writes beside it so older versions show it.
///
/// A cell holds one legacy comment in Excel, so a cell with both a note and a thread gets the thread;
/// its note is kept in PuggleSheets' custom XML part (`XLSXExtras`).
enum XLSXComments {
    static let commentsType = XLSXRelationshipType.base + "comments"
    static let vmlDrawingType = XLSXRelationshipType.base + "vmlDrawing"
    static let threadedCommentType = "http://schemas.microsoft.com/office/2017/10/relationships/threadedComment"
    static let personType = "http://schemas.microsoft.com/office/2017/10/relationships/person"
    static let threadedNamespace = "http://schemas.microsoft.com/office/spreadsheetml/2018/threadedcomments"

    static let commentsContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.comments+xml"
    static let vmlContentType = "application/vnd.openxmlformats-officedocument.vmlDrawing"
    static let threadedContentType = "application/vnd.ms-excel.threadedcomments+xml"
    static let personContentType = "application/vnd.ms-excel.person+xml"

    /// Notes' author. Excel needs one, PuggleSheets' notes have none: an empty name keeps Excel from
    /// showing anyone's.
    static let noteAuthor = ""

    /// A comment id as Excel writes it: "{6F9619FF-8B86-D011-B42D-00C04FC964FF}".
    static func excelID(_ id: UUID) -> String { "{" + id.uuidString + "}" }

    /// An id from a file, without braces, uppercased, for matching.
    static func normalizedID(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")).uppercased()
    }

    // MARK: - Writing

    /// The people who wrote comments, listed once in xl/persons/person.xml. Ids come from the names,
    /// so the same workbook is written the same way every time.
    struct Persons {
        private(set) var names: [String] = []
        private var ids: [String: String] = [:]

        var isEmpty: Bool { names.isEmpty }

        mutating func id(for name: String) -> String {
            if let id = ids[name] { return id }
            let id = XLSXComments.excelID(XLSXComments.stableID(for: "person:" + name))
            ids[name] = id
            names.append(name)
            return id
        }

        func part() -> Data {
            var xml = XMLWriter()
            xml.raw("<personList xmlns=\"\(XLSXComments.threadedNamespace)\" xmlns:x=\"\(XLSXNamespace.main)\">")
            for name in names {
                xml.raw("<person")
                xml.attribute("displayName", name)
                xml.attribute("id", ids[name] ?? "")
                xml.attribute("userId", name)
                xml.raw(" providerId=\"None\"/>")
            }
            xml.raw("</personList>")
            return xml.data
        }
    }

    /// A UUID made from text (two FNV-1a hashes), for ids that stay the same from save to save.
    static func stableID(for text: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return hash
        }
        let high = fnv(0xCBF2_9CE4_8422_2325), low = fnv(0x84222325CBF29CE4)
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: high >> (56 - 8 * index))
            bytes[8 + index] = UInt8(truncatingIfNeeded: low >> (56 - 8 * index))
        }
        bytes[6] = bytes[6] & 0x0F | 0x40
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Writes the notes and comment threads of the `commented` cells (from `XLSXCellFeatures`) into
    /// `parts`, adding their relationships to the worksheet's. Returns the id of the VML drawing for
    /// `<legacyDrawing>`, or nil when there are none.
    static func write(_ sheet: Sheet, commented addresses: [CellAddress], counters: inout XLSXPartCounters, persons: inout Persons,
                      parts: inout XLSXExtraParts, relationships: inout XLSXRelationshipsWriter) -> String? {
        let commented = addresses.compactMap { address -> (address: CellAddress, note: String?, thread: CommentThread?)? in
            guard let cell = sheet.cells[address] else { return nil }
            let thread = cell.comment.flatMap { $0.comments.isEmpty ? nil : $0 }
            guard cell.note != nil || thread != nil, address.row >= 0, address.column >= 0,
                  address.row < XLSXLimits.rows, address.column < XLSXLimits.columns else { return nil }
            return (address, cell.note, thread)
        }.sorted { $0.address < $1.address }
        guard !commented.isEmpty else { return nil }
        counters.comments += 1
        let number = counters.comments

        // The legacy comments: notes, and the copies of threads older Excel shows.
        var authors: [String] = []
        var authorIndexes: [String: Int] = [:]
        func authorIndex(_ name: String) -> Int {
            if let index = authorIndexes[name] { return index }
            authors.append(name)
            authorIndexes[name] = authors.count - 1
            return authors.count - 1
        }
        var list = XMLWriter(fragmentCapacity: commented.count * 160)
        var threads = XMLWriter(fragmentCapacity: 0)
        for item in commented {
            let author: Int, text: String
            if let thread = item.thread {
                author = authorIndex("tc=" + excelID(thread.comments[0].id))
                text = fallbackText(thread)
                writeThread(thread, at: item.address, persons: &persons, into: &threads)
            } else {
                author = authorIndex(noteAuthor)
                text = item.note ?? ""
            }
            list.raw("<comment ref=\"\(item.address.a1)\" authorId=\"\(author)\" shapeId=\"0\"><text>")
            list.raw(XLSXText.needsPreservedSpace(text) ? "<t xml:space=\"preserve\">" : "<t>")
            list.text(XLSXText.encode(text))
            list.raw("</t></text></comment>")
        }
        var comments = XMLWriter(reservingCapacity: 256 + list.bytes.count)
        comments.raw("<comments xmlns=\"\(XLSXNamespace.main)\"><authors>")
        for author in authors {
            comments.raw("<author>")
            comments.text(author)
            comments.raw("</author>")
        }
        comments.raw("</authors><commentList>")
        comments.append(list)
        comments.raw("</commentList></comments>")
        parts.add("xl/comments\(number).xml", comments.data, contentType: commentsContentType)
        _ = relationships.add(type: commentsType, target: "../comments\(number).xml")

        parts.add("xl/drawings/vmlDrawing\(number).vml", vmlDrawing(commented.map(\.address), block: number))
        parts.addDefault(extension: "vml", contentType: vmlContentType)
        let vml = relationships.add(type: vmlDrawingType, target: "../drawings/vmlDrawing\(number).vml")

        if !threads.isEmpty {
            var xml = XMLWriter(reservingCapacity: 256 + threads.bytes.count)
            xml.raw("<ThreadedComments xmlns=\"\(threadedNamespace)\" xmlns:x=\"\(XLSXNamespace.main)\">")
            xml.append(threads)
            xml.raw("</ThreadedComments>")
            parts.add("xl/threadedComments/threadedComment\(number).xml", xml.data, contentType: threadedContentType)
            _ = relationships.add(type: threadedCommentType, target: "../threadedComments/threadedComment\(number).xml")
        }
        return vml
    }

    private static func writeThread(_ thread: CommentThread, at address: CellAddress, persons: inout Persons, into xml: inout XMLWriter) {
        let root = excelID(thread.comments[0].id)
        for (index, comment) in thread.comments.enumerated() {
            xml.raw("<threadedComment ref=\"\(address.a1)\" dT=\"\(timestamp(comment.date))\"")
            xml.attribute("personId", persons.id(for: comment.author))
            xml.attribute("id", excelID(comment.id))
            if index > 0 { xml.attribute("parentId", root) }
            if index == 0 && thread.isResolved { xml.raw(" done=\"1\"") }
            xml.raw("><text>")
            xml.text(comment.text)
            xml.raw("</text></threadedComment>")
        }
    }

    /// The text Excel puts in a thread's legacy copy.
    static func fallbackText(_ thread: CommentThread) -> String {
        var text = "[Threaded comment]\n\nYour version of Excel allows you to read this threaded comment; however, any edits to it "
            + "will get removed if the file is opened in a newer version of Excel. Learn more: https://go.microsoft.com/fwlink/?linkid=870924\n"
        for (index, comment) in thread.comments.enumerated() {
            text += (index == 0 ? "\nComment:\n    " : "\nReply:\n    ") + comment.text.replacingOccurrences(of: "\n", with: "\n    ")
        }
        return text
    }

    /// "2026-11-16T09:30:00.00", in UTC, as threaded comments store dates.
    static func timestamp(_ date: Date) -> String {
        let serial = DateSerial.serial(from: date, timeZone: TimeZone(identifier: "UTC")!)
        let parts = DateSerial.parts(of: serial)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%02d", parts.year, parts.month, parts.day, parts.hour, parts.minute,
                      parts.second, parts.millisecond / 10)
    }

    /// The shapes that show legacy comments: a hidden yellow box beside each cell. `block` keeps shape
    /// ids apart between sheets (Excel numbers them 1024 × block + n).
    static func vmlDrawing(_ addresses: [CellAddress], block: Int) -> Data {
        var xml = XMLWriter(reservingCapacity: 1024 + addresses.count * 700)
        xml.raw("<xml xmlns:v=\"urn:schemas-microsoft-com:vml\" xmlns:o=\"urn:schemas-microsoft-com:office:office\" "
            + "xmlns:x=\"urn:schemas-microsoft-com:office:excel\">")
        xml.raw("<o:shapelayout v:ext=\"edit\"><o:idmap v:ext=\"edit\" data=\"\(block)\"/></o:shapelayout>")
        xml.raw("<v:shapetype id=\"_x0000_t202\" coordsize=\"21600,21600\" o:spt=\"202\" path=\"m,l,21600r21600,l21600,xe\">"
            + "<v:stroke joinstyle=\"miter\"/><v:path gradientshapeok=\"t\" o:connecttype=\"rect\"/></v:shapetype>")
        for (index, address) in addresses.enumerated() {
            xml.raw("<v:shape id=\"_x0000_s\(1024 * block + index + 1)\" type=\"#_x0000_t202\" "
                + "style=\"position:absolute;margin-left:59.25pt;margin-top:1.5pt;width:108pt;height:59.25pt;z-index:\(index + 1);"
                + "visibility:hidden\" fillcolor=\"#ffffe1\" o:insetmode=\"auto\">")
            xml.raw("<v:fill color2=\"#ffffe1\"/><v:shadow on=\"t\" color=\"black\" obscured=\"t\"/><v:path o:connecttype=\"none\"/>"
                + "<v:textbox style=\"mso-direction-alt:auto\"><div style=\"text-align:left\"></div></v:textbox>")
            let column = min(address.column, XLSXLimits.columns - 4), row = address.row
            xml.raw("<x:ClientData ObjectType=\"Note\"><x:MoveWithCells/><x:SizeWithCells/>"
                + "<x:Anchor>\(column + 1), 15, \(max(row - 1, 0)), 10, \(column + 3), 15, \(min(row + 3, XLSXLimits.rows - 1)), 4</x:Anchor>"
                + "<x:AutoFill>False</x:AutoFill><x:Row>\(row)</x:Row><x:Column>\(address.column)</x:Column></x:ClientData></v:shape>")
        }
        xml.raw("</xml>")
        return xml.data
    }

    // MARK: - Reading

    /// A legacy comment: its cell, author and text.
    struct LegacyComment {
        var address: CellAddress
        var author: String
        var text: String
    }

    static func legacyComments(_ data: Data) -> [LegacyComment]? {
        guard let root = try? XMLTree.parse(data), root.name == "comments" else { return nil }
        let authors = root.child("authors")?.children("author").map(\.text) ?? []
        return (root.child("commentList")?.children("comment") ?? []).compactMap { node in
            guard let reference = node["ref"], let range = CellRange(a1: reference.replacingOccurrences(of: "$", with: "")),
                  range.end.row < XLSXLimits.rows, range.end.column < XLSXLimits.columns else { return nil }
            let author = XLSXValue.int(node["authorId"]).flatMap { authors.indices.contains($0) ? authors[$0] : nil } ?? ""
            return LegacyComment(address: range.start, author: author, text: text(of: node.child("text")))
        }
    }

    /// Rich text's characters: every run's `<t>`, leaving out phonetic guides.
    private static func text(of node: XNode?) -> String {
        guard let node else { return "" }
        var result = ""
        for child in node.children {
            switch child.name {
            case "t": result += child.text
            case "r": result += child.child("t")?.text ?? ""
            default: break
            }
        }
        return XLSXText.decode(result)
    }

    /// Display names by person id (normalized).
    static func persons(_ data: Data) -> [String: String] {
        guard let root = try? XMLTree.parse(data) else { return [:] }
        var result: [String: String] = [:]
        for person in root.children("person") {
            if let id = person["id"] { result[normalizedID(id)] = person["displayName"] ?? "" }
        }
        return result
    }

    /// Threads by cell, from a threaded comments part, with each thread's first comment id (normalized).
    static func threads(_ data: Data, persons: [String: String]) -> [CellAddress: (root: String, thread: CommentThread)]? {
        guard let root = try? XMLTree.parse(data), root.name == "ThreadedComments" else { return nil }
        var roots: [(address: CellAddress, id: String, resolved: Bool, comment: Comment)] = []
        var replies: [String: [Comment]] = [:]
        for node in root.children("threadedComment") {
            guard let reference = node["ref"], let range = CellRange(a1: reference.replacingOccurrences(of: "$", with: "")),
                  range.end.row < XLSXLimits.rows, range.end.column < XLSXLimits.columns else { continue }
            let idText = normalizedID(node["id"] ?? "")
            let comment = Comment(id: UUID(uuidString: idText) ?? UUID(), author: node["personId"].flatMap { persons[normalizedID($0)] } ?? "",
                                  date: date(node["dT"]) ?? Date(timeIntervalSince1970: 0), text: node.child("text")?.text ?? "")
            if let parent = node["parentId"] {
                replies[normalizedID(parent), default: []].append(comment)
            } else {
                roots.append((range.start, idText, XLSXValue.isTrue(node["done"]), comment))
            }
        }
        var result: [CellAddress: (root: String, thread: CommentThread)] = [:]
        for item in roots where result[item.address] == nil {
            let thread = CommentThread(id: item.comment.id, comments: [item.comment] + (replies[item.id] ?? []), isResolved: item.resolved)
            result[item.address] = (item.id, thread)
        }
        return result
    }

    /// A threaded comment's date: ISO 8601 ("2026-03-04T05:06:07.89", "…Z", "…+02:00"), in UTC unless
    /// it says otherwise. Computed exactly, so whole seconds come back as they were written.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let bytes = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        var index = 0
        func number(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<count {
                guard bytes[index] >= 0x30, bytes[index] <= 0x39 else { return nil }
                value = value * 10 + Int(bytes[index] - 0x30)
                index += 1
            }
            return value
        }
        func skip(_ character: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == character else { return false }
            index += 1
            return true
        }
        guard let year = number(4), skip(0x2D), let month = number(2), skip(0x2D), let day = number(2),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var seconds = Double(DateSerial.daysFromCivil(year, month, day)) * 86_400
        if skip(0x54) {
            guard let hour = number(2), skip(0x3A), let minute = number(2), hour <= 24, minute < 60 else { return nil }
            var second = 0
            var fraction = 0.0
            if skip(0x3A) {
                guard let whole = number(2) else { return nil }
                second = whole
                if skip(0x2E) || skip(0x2C) {
                    var digits = 0, scale = 1.0
                    while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                        digits = digits * 10 + Int(bytes[index] - 0x30)
                        scale *= 10
                        index += 1
                    }
                    fraction = Double(digits) / scale
                }
            }
            seconds += Double(hour * 3600 + minute * 60 + second)
            // A zone designator moves the wall-clock time to UTC.
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
                let sign = bytes[index] == 0x2D ? -1 : 1
                index += 1
                guard let hours = number(2) else { return nil }
                _ = skip(0x3A)
                let minutes = number(2) ?? 0
                seconds -= Double(sign * (hours * 3600 + minutes * 60))
            }
            return Date(timeIntervalSince1970: seconds + fraction)
        }
        return Date(timeIntervalSince1970: seconds)
    }
}
