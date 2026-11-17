import Foundation
import Testing
@testable import PuggleSheetsKit

/// Notes and comment threads in Excel files: legacy comments with their VML drawing, threaded comments
/// with the workbook's persons.
struct IOXLSXCommentTests {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    static func thread(resolved: Bool = false) -> CommentThread {
        CommentThread(comments: [Comment(author: "Ann Lee", date: date, text: "Is this right?"),
                                 Comment(author: "Bob", date: date.addingTimeInterval(90), text: "Yes —\nchecked twice", editedDate: date.addingTimeInterval(300)),
                                 Comment(author: "Ann Lee", date: date.addingTimeInterval(600), text: "Thanks")],
                      isResolved: resolved)
    }

    static func workbook() -> Workbook {
        var sheet = Sheet(name: "Budget")
        sheet[0, 0] = Cell(value: .text("Rent"), note: "Due on the 1st")
        sheet[1, 1] = Cell(value: .number(1200), comment: thread(resolved: true))
        sheet[2, 2] = Cell(note: "Kept beside the thread", comment: CommentThread(comments: [Comment(author: "Cy", date: date, text: "Open")]))
        sheet[3, 0] = Cell(value: .text("Spaces"), note: "  padded note  ")
        var second = Sheet(name: "Second sheet")
        second[4, 4] = Cell(note: "On another sheet")
        second[5, 5] = Cell(comment: CommentThread(comments: [Comment(author: "Bob", date: date, text: "Second sheet thread")]))
        return Workbook(sheets: [sheet, second])
    }

    @Test func notesAndThreadsRoundTrip() throws {
        let workbook = Self.workbook()
        let file = try IOXLSXObjectTests.roundTrip(workbook)
        #expect(file.warnings.isEmpty)
        for (index, sheet) in workbook.sheets.enumerated() {
            let copy = file.workbook.sheets[index]
            for (address, cell) in sheet.cells {
                #expect(copy[address] == cell, "\(sheet.name)!\(address)")
            }
        }
        let data = try SpreadsheetIO.write(workbook, activeSheet: 0, format: .xlsx)
        #expect(try IOXLSXPackageCheck.problems(data).isEmpty)
    }

    @Test func notesAsExcelWritesThem() throws {
        let data = try SpreadsheetIO.write(Self.workbook(), activeSheet: 0, format: .xlsx)
        let comments = try #require(try IOTestPackage.part("xl/comments1.xml", of: data))
        // Notes have no author; a thread's legacy copy names it as Excel does ("tc=" and the thread's id).
        #expect(comments.contains("<authors><author></author><author>tc={"))
        #expect(comments.contains("<comment ref=\"A1\" authorId=\"0\" shapeId=\"0\"><text><t>Due on the 1st</t></text></comment>"))
        #expect(comments.contains("<t xml:space=\"preserve\">  padded note  </t>"))
        #expect(comments.contains("<comment ref=\"B2\" authorId=\"1\" shapeId=\"0\"><text><t>[Threaded comment]\n\nYour version of Excel"))
        #expect(comments.contains("Comment:\n    Is this right?\nReply:\n    Yes —\n    checked twice\nReply:\n    Thanks</t>"))
        let vml = try #require(try IOTestPackage.part("xl/drawings/vmlDrawing1.vml", of: data))
        #expect(IOTestPackage.isWellFormed(Data(vml.utf8)))
        #expect(vml.contains("<o:idmap v:ext=\"edit\" data=\"1\"/>"))
        #expect(vml.contains("<x:ClientData ObjectType=\"Note\"><x:MoveWithCells/><x:SizeWithCells/><x:Anchor>1, 15, 0, 10, 3, 15, 3, 4</x:Anchor>"
            + "<x:AutoFill>False</x:AutoFill><x:Row>0</x:Row><x:Column>0</x:Column></x:ClientData>"))
        // Four shapes, numbered from 1025; the second sheet's drawing numbers from 2049.
        #expect(vml.contains("id=\"_x0000_s1028\"") && !vml.contains("id=\"_x0000_s1029\""))
        let secondVML = try #require(try IOTestPackage.part("xl/drawings/vmlDrawing2.vml", of: data))
        #expect(secondVML.contains("<o:idmap v:ext=\"edit\" data=\"2\"/>") && secondVML.contains("id=\"_x0000_s2049\""))
        let sheet = try #require(try IOTestPackage.part("xl/worksheets/sheet1.xml", of: data))
        #expect(sheet.hasSuffix("<legacyDrawing r:id=\"rId2\"/></worksheet>"))
        let relationships = try #require(try IOTestPackage.part("xl/worksheets/_rels/sheet1.xml.rels", of: data))
        #expect(relationships.contains("<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments\" "
            + "Target=\"../comments1.xml\"/>"))
        #expect(relationships.contains("<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/vmlDrawing\" "
            + "Target=\"../drawings/vmlDrawing1.vml\"/>"))
        #expect(relationships.contains("<Relationship Id=\"rId3\" Type=\"http://schemas.microsoft.com/office/2017/10/relationships/threadedComment\" "
            + "Target=\"../threadedComments/threadedComment1.xml\"/>"))
        let types = try #require(try IOTestPackage.part("[Content_Types].xml", of: data))
        #expect(types.contains("<Default Extension=\"vml\" ContentType=\"application/vnd.openxmlformats-officedocument.vmlDrawing\"/>"))
        #expect(types.contains("<Override PartName=\"/xl/comments1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.comments+xml\"/>"))
        #expect(types.contains("<Override PartName=\"/xl/threadedComments/threadedComment1.xml\" ContentType=\"application/vnd.ms-excel.threadedcomments+xml\"/>"))
        #expect(types.contains("<Override PartName=\"/xl/persons/person.xml\" ContentType=\"application/vnd.ms-excel.person+xml\"/>"))
    }

    @Test func threadsAsExcelWritesThem() throws {
        let workbook = Self.workbook()
        let data = try XLSXWriter.write(workbook, activeSheet: 0, date: Self.date)
        let threads = try #require(try IOTestPackage.part("xl/threadedComments/threadedComment1.xml", of: data))
        let thread = Self.thread(resolved: true)
        let root = XLSXComments.excelID(workbook.sheets[0][1, 1].comment!.comments[0].id)
        let ann = XLSXComments.excelID(XLSXComments.stableID(for: "person:Ann Lee"))
        #expect(threads.contains("<threadedComment ref=\"B2\" dT=\"2026-09-21T14:13:20.00\" personId=\"\(ann)\" id=\"\(root)\" done=\"1\">"
            + "<text>Is this right?</text></threadedComment>"))
        #expect(threads.contains("dT=\"2026-09-21T14:14:50.00\""))
        #expect(threads.contains("parentId=\"\(root)\"><text>Yes —\nchecked twice</text>"))
        #expect(thread.comments.count == 3)
        let persons = try #require(try IOTestPackage.part("xl/persons/person.xml", of: data))
        #expect(persons.contains("<person displayName=\"Ann Lee\" id=\"\(ann)\" userId=\"Ann Lee\" providerId=\"None\"/>"))
        // Each person once, for the whole workbook.
        #expect(persons.components(separatedBy: "displayName=\"Bob\"").count == 2)
        let relationships = try #require(try IOTestPackage.part("xl/_rels/workbook.xml.rels", of: data))
        #expect(relationships.contains("Type=\"http://schemas.microsoft.com/office/2017/10/relationships/person\" Target=\"persons/person.xml\""))
        // The note beside a thread, and what threaded comments can't hold, wait in PuggleSheets' part.
        let extras = try #require(try IOTestPackage.part("customXml/item1.xml", of: data))
        #expect(extras.contains(">Kept beside the thread</note>"))
        #expect(extras.contains("<edited comment=\"\(XLSXComments.excelID(workbook.sheets[0][1, 1].comment!.comments[1].id))\" date=\"2026-09-21T14:18:20.000Z\"/>"))
        // The same workbook is written the same way every time.
        #expect(try XLSXWriter.write(workbook, activeSheet: 0, date: Self.date) == data)
    }

    @Test func excelNotesBecomeNotes() throws {
        // Excel's notes: the author's name in bold, then the text.
        let comments = IOTestPackage.declaration + "<comments xmlns=\"\(IOTestPackage.mainNamespace)\"><authors><author>Dana</author></authors>"
            + "<commentList><comment ref=\"B3\" authorId=\"0\" shapeId=\"0\"><text><r><rPr><b/><sz val=\"9\"/></rPr><t>Dana:</t></r>"
            + "<r><rPr><sz val=\"9\"/></rPr><t xml:space=\"preserve\">\r\nCheck the total</t></r><rPh sb=\"0\" eb=\"1\"><t>x</t></rPh></text></comment>"
            + "<comment ref=\"$C$4\" authorId=\"7\"><text><t>Plain</t></text></comment></commentList></comments>"
        let data = try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("S", "<sheetData/><legacyDrawing r:id=\"rId2\"/>",
                                                                        relationships: [("comments", "../comments1.xml"),
                                                                                        ("vmlDrawing", "../drawings/vmlDrawing1.vml")])],
                                          parts: ["xl/comments1.xml": comments])
        let file = try IOTestPackage.read(data)
        #expect(file.warnings.isEmpty)
        let sheet = file.workbook.sheets[0]
        #expect(sheet[2, 1] == Cell(note: "Dana:\nCheck the total"))
        #expect(sheet[3, 2].note == "Plain")
    }

    static func excelThreadPackage(withThreads: Bool = true) throws -> Data {
        let persons = IOTestPackage.declaration + "<personList xmlns=\"\(XLSXComments.threadedNamespace)\" xmlns:x=\"\(IOTestPackage.mainNamespace)\">"
            + "<person displayName=\"Eve Example\" id=\"{1D2B3C4E-0000-4000-8000-00000000000A}\" userId=\"eve@example.com\" providerId=\"AD\"/>"
            + "<person displayName=\"Finn\" id=\"{1D2B3C4E-0000-4000-8000-00000000000B}\" userId=\"S::finn@example.com::abc\" providerId=\"AD\"/></personList>"
        let threads = IOTestPackage.declaration + "<ThreadedComments xmlns=\"\(XLSXComments.threadedNamespace)\" xmlns:x=\"\(IOTestPackage.mainNamespace)\">"
            + "<threadedComment ref=\"A2\" dT=\"2026-03-04T05:06:07.89\" personId=\"{1D2B3C4E-0000-4000-8000-00000000000A}\" "
            + "id=\"{AAAAAAAA-0000-4000-8000-000000000001}\" done=\"1\"><text>@Finn please look</text>"
            + "<mentions><mention mentionpersonId=\"{1D2B3C4E-0000-4000-8000-00000000000B}\" mentionId=\"{0}\" startIndex=\"0\" length=\"5\"/></mentions>"
            + "</threadedComment><threadedComment ref=\"A2\" dT=\"2026-03-04T06:00:00.00\" personId=\"{1D2B3C4E-0000-4000-8000-00000000000B}\" "
            + "id=\"{AAAAAAAA-0000-4000-8000-000000000002}\" parentId=\"{AAAAAAAA-0000-4000-8000-000000000001}\"><text>Done</text></threadedComment>"
            + "</ThreadedComments>"
        // The legacy copy of the thread, and a note on another cell.
        let comments = IOTestPackage.declaration + "<comments xmlns=\"\(IOTestPackage.mainNamespace)\"><authors>"
            + "<author>tc={AAAAAAAA-0000-4000-8000-000000000001}</author><author>Eve Example</author></authors><commentList>"
            + "<comment ref=\"A2\" authorId=\"0\" shapeId=\"0\"><text><t>[Threaded comment]\n\nYour version of Excel…\n\nComment:\n    @Finn please look</t></text></comment>"
            + "<comment ref=\"D1\" authorId=\"1\" shapeId=\"0\"><text><t>A note</t></text></comment></commentList></comments>"
        var relationships: [(type: String, target: String)] = [("comments", "../comments1.xml"), ("vmlDrawing", "../drawings/vmlDrawing1.vml")]
        var parts = ["xl/comments1.xml": comments, "xl/persons/person.xml": persons]
        if withThreads {
            relationships.append((XLSXComments.threadedCommentType, "../threadedComments/threadedComment1.xml"))
            parts["xl/threadedComments/threadedComment1.xml"] = threads
        }
        return try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("S", "<sheetData/><legacyDrawing r:id=\"rId2\"/>", relationships: relationships)],
                                      workbookRelationships: [(XLSXComments.personType, "persons/person.xml")], parts: parts)
    }

    @Test func excelThreadsAreRead() throws {
        let file = try IOTestPackage.read(try Self.excelThreadPackage())
        #expect(file.warnings.isEmpty)
        let sheet = file.workbook.sheets[0]
        let thread = try #require(sheet[1, 0].comment)
        #expect(thread.isResolved)
        #expect(thread.comments.map(\.author) == ["Eve Example", "Finn"])
        #expect(thread.comments.map(\.text) == ["@Finn please look", "Done"])
        #expect(thread.comments[0].id == UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001"))
        // Dates without a time zone are UTC; hundredths of a second are kept.
        #expect(thread.comments[1].date == Date(timeIntervalSince1970: 1_772_604_000))
        #expect(abs(thread.comments[0].date.timeIntervalSince1970 - 1_772_600_767.89) < 0.001)
        // The thread's legacy copy isn't a note; the other legacy comment is.
        #expect(sheet[1, 0].note == nil)
        #expect(sheet[0, 3].note == "A note")
        // Without the threaded comments part, the legacy copy is all there is: a note.
        let older = try IOTestPackage.read(try Self.excelThreadPackage(withThreads: false)).workbook.sheets[0]
        #expect(older[1, 0].comment == nil && older[1, 0].note?.hasPrefix("[Threaded comment]") == true)
    }

    @Test func threadDatesWithZones() {
        #expect(XLSXComments.date("2026-03-04T06:00:00Z") == Date(timeIntervalSince1970: 1_772_604_000))
        #expect(XLSXComments.date("2026-03-04T08:00:00+02:00") == Date(timeIntervalSince1970: 1_772_604_000))
        #expect(XLSXComments.date("2026-03-04T01:00:00-05:00") == Date(timeIntervalSince1970: 1_772_604_000))
        #expect(XLSXComments.date("not a date") == nil)
    }

    @Test func damagedCommentPartsOnlyWarn() throws {
        var sheet = IOXLSXSheetFeatureTests.groupedSheet()
        sheet.protections = IOXLSXSheetFeatureTests.protectedSheet().protections
        for (address, cell) in Self.workbook().sheets[0].cells { sheet[address] = cell }
        let data = try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx)
        let zip = try ZipReader(data: data)
        var parts: [String: Data] = [:]
        for entry in zip.entries { parts[entry.path] = try zip.read(entry) }
        var random = IOTestRandom(seed: 404)
        for target in ["xl/comments1.xml", "xl/threadedComments/threadedComment1.xml", "xl/persons/person.xml", "customXml/item1.xml",
                       "xl/worksheets/sheet1.xml", "xl/styles.xml"] {
            for _ in 0..<25 {
                var damaged = parts
                var bytes = [UInt8](damaged[target]!)
                for _ in 0..<3 where !bytes.isEmpty {
                    let position = Int(random.next() % UInt64(bytes.count))
                    switch random.next() % 3 {
                    case 0: bytes.removeSubrange(position..<min(bytes.count, position + Int(random.next() % 40)))
                    case 1: bytes.insert(contentsOf: Array("outlineLevel=\"99\" collapsed=\"1\" ".utf8), at: position)
                    default: bytes[position] = UInt8(truncatingIfNeeded: random.next())
                    }
                }
                damaged[target] = Data(bytes)
                // Damage costs the damaged part's content, or refuses the file when it's the sheet or styles.
                do {
                    let file = try IOTestPackage.read(try IOTestPackage.zip(damaged))
                    #expect(file.workbook.sheets.count == 1)
                    #expect(file.workbook.sheets[0].rowGroups.allSatisfy { $0.range.lowerBound >= 0 })
                } catch let error as SpreadsheetIOError {
                    #expect(target == "xl/worksheets/sheet1.xml" || target == "xl/styles.xml", "\(target): \(error)")
                }
            }
        }
    }

    @Test func emptyThreadsAndDamagedPartsAreHandled() throws {
        var sheet = Sheet(name: "S")
        sheet[0, 0] = Cell(value: .number(1), comment: CommentThread(comments: []))
        let data = try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx)
        #expect(try ZipReader(data: data).entries.allSatisfy { !$0.path.contains("omment") })
        // A damaged comments part costs the notes only.
        let broken = try IOTestPackage.xlsx(sheets: [IOTestPackage.SheetPart("S", "<sheetData><row r=\"1\"><c r=\"A1\"><v>5</v></c></row></sheetData>",
                                                                          relationships: [("comments", "../comments1.xml")])],
                                            parts: ["xl/comments1.xml": "<comments><commentList><comment ref=\"A1\""])
        let file = try IOTestPackage.read(broken)
        #expect(file.warnings == [.comments])
        #expect(file.workbook.sheets[0][0, 0].value == .number(5))
    }
}
