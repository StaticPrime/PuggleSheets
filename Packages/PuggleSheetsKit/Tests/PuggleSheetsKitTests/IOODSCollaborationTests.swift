import Foundation
import Testing
@testable import PuggleSheetsKit

/// Phase 4 in OpenDocument files: notes and comments, protected ranges, text rotation, and row and
/// column groups.
struct IOODSCollaborationTests {
    static func address(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    static func range(_ a1: String) -> CellRange { CellRange(a1: a1)! }
    static let monday = Date(timeIntervalSinceReferenceDate: 784_900_000.25)

    static func write(_ workbook: Workbook) throws -> Data {
        try SpreadsheetIO.write(workbook, activeSheet: 0, format: .ods)
    }

    static func roundTrip(_ workbook: Workbook) throws -> SpreadsheetFile {
        try SpreadsheetIO.read(try write(workbook), format: .ods)
    }

    static func content(_ data: Data) throws -> String {
        try #require(try IOODSObjectsTests.part("content.xml", of: data))
    }

    static func thread(resolved: Bool = false) -> CommentThread {
        CommentThread(comments: [
            Comment(author: "Ana", date: monday, text: "Is this right?\nIt looks low."),
            Comment(author: "Ben", date: monday.addingTimeInterval(3600.5), text: "Yes, checked.", editedDate: monday.addingTimeInterval(4000)),
        ], isResolved: resolved)
    }

    // MARK: - Notes and comments

    @Test func notesRoundTrip() throws {
        var sheet = Sheet(name: "Notes")
        sheet[0, 0] = Cell(value: .text("Total"), note: "Estimated\n  from Q1   figures")
        sheet[1, 1] = Cell(note: "On an empty cell")
        sheet[2, 2] = Cell(value: .number(5), format: IOTest.format { $0.bold = true }, link: "https://example.com", note: "With a link")
        sheet[3, 0] = Cell(note: "")
        let package = try Self.write(Workbook(sheets: [sheet]))
        let content = try Self.content(package)
        // The annotation comes first in its cell, before the cell's text.
        #expect(content.contains("<table:table-cell office:value-type=\"string\" calcext:value-type=\"string\"><office:annotation><text:p>Estimated</text:p><text:p><text:s text:c=\"2\"/>from Q1 <text:s text:c=\"2\"/>figures</text:p></office:annotation><text:p>Total</text:p></table:table-cell>"))
        #expect(content.contains("<table:table-cell><office:annotation><text:p>On an empty cell</text:p></office:annotation></table:table-cell>"))
        let file = try SpreadsheetIO.read(package, format: .ods)
        #expect(file.warnings.isEmpty)
        let read = file.workbook.sheets[0]
        for address in ["A1", "B2", "C3", "A4"].map(Self.address) { #expect(read[address] == sheet[address], "\(address)") }
    }

    @Test func commentsRoundTrip() throws {
        var sheet = Sheet(name: "Q1 2026")
        sheet[0, 0] = Cell(value: .number(42), comment: Self.thread())
        sheet[1, 0] = Cell(value: .text("Both"), note: "A note", comment: Self.thread(resolved: true))
        sheet[2, 0] = Cell(comment: CommentThread(comments: [Comment(author: "", date: Self.monday, text: "Anonymous")]))
        let package = try Self.write(Workbook(sheets: [Sheet(name: "First"), sheet]))
        let content = try Self.content(package)
        // LibreOffice shows the thread as the annotation: the first comment's author, date and text, then the replies.
        #expect(content.contains("<office:annotation><dc:creator>Ana</dc:creator><dc:date>2025-11-15T11:46:40Z</dc:date><text:p>Is this right?</text:p><text:p>It looks low.</text:p><text:p>Ben: Yes, checked.</text:p></office:annotation><text:p>42</text:p>"))
        // A note and a thread: the note, a blank paragraph, every comment, and the thread's state.
        #expect(content.contains("<office:annotation><text:p>A note</text:p><text:p></text:p><text:p>Ana: Is this right?</text:p><text:p>It looks low.</text:p><text:p>Ben: Yes, checked.</text:p><text:p>(Resolved)</text:p></office:annotation>"))
        let settings = try #require(try IOODSObjectsTests.part("settings.xml", of: package))
        #expect(settings.contains("<config:config-item config:name=\"Author\" config:type=\"string\">Ben</config:config-item>"))

        let file = try SpreadsheetIO.read(package, format: .ods)
        #expect(file.warnings.isEmpty)
        let read = file.workbook.sheets[1]
        for row in 0...2 { #expect(read[row, 0] == sheet[row, 0], "row \(row)") }
    }

    @Test func commentsReadWithoutPuggleSettings() throws {
        // As LibreOffice saves the file: an annotation is a note, a flattened thread included.
        var sheet = Sheet(name: "Sheet1")
        sheet[0, 0] = Cell(value: .number(42), comment: Self.thread())
        sheet[1, 0] = Cell(note: "A note", comment: Self.thread(resolved: true))
        let file = try SpreadsheetIO.read(try IOODSObjectsTests.withoutPuggleSettings(try Self.write(Workbook(sheets: [sheet]))), format: .ods)
        #expect(file.warnings.isEmpty)
        let read = file.workbook.sheets[0]
        #expect(read[0, 0] == Cell(value: .number(42), note: "Is this right?\nIt looks low.\nBen: Yes, checked."))
        #expect(read[1, 0] == Cell(note: "A note\n\nAna: Is this right?\nIt looks low.\nBen: Yes, checked.\n(Resolved)"))
    }

    @Test func readsLibreOfficeAnnotations() throws {
        // Laid out as LibreOffice writes them: a position, styles, the author and date, and formatted paragraphs.
        let body = """
            <table:table table:name="Sheet1">
            <table:table-row><table:table-cell office:value-type="float" office:value="3" calcext:value-type="float">
            <office:annotation office:display="true" draw:style-name="gr1" draw:text-style-name="P1" svg:width="40mm" svg:height="20mm" svg:x="30mm" svg:y="1mm" draw:caption-point-x="-6mm" draw:caption-point-y="1mm">
            <dc:creator>Ann Author</dc:creator><dc:date>2026-11-16T00:00:00</dc:date>
            <text:p><text:span text:style-name="T1">Check</text:span> <text:span text:style-name="T2">this</text:span><text:s text:c="2"/>value</text:p><text:p>Second line</text:p>
            </office:annotation><text:p>3</text:p></table:table-cell>
            <table:table-cell><office:annotation><meta:date-string>11/16/26</meta:date-string><text:p>Only a note</text:p></office:annotation></table:table-cell>
            </table:table-row></table:table>
            """
        let file = try IOTestODS.read(try IOTestODS.package(content: IOTestODS.content(body)))
        #expect(file.warnings.isEmpty)
        let sheet = file.workbook.sheets[0]
        #expect(sheet[0, 0] == Cell(value: .number(3), note: "Check this  value\nSecond line"))
        #expect(sheet[0, 1] == Cell(note: "Only a note"))
    }

    // MARK: - Protected ranges

    @Test func protectionRoundTrip() throws {
        var sheet = Sheet(name: "Budget")
        sheet[0, 0] = Cell(value: .text("Input"), format: IOTest.format { $0.fillColor = RGBColor(hex: "FFF2CC") })
        sheet[1, 1] = Cell(value: .number(10))
        sheet.protections = [
            ProtectedRange(scope: .sheet(except: [Self.range("A1:A3"), Self.range("C5")]), description: "Locked sheet", warningOnly: false),
            ProtectedRange(scope: .range(Self.range("B2:C4")), description: "Totals"),
            ProtectedRange(scope: .range(Self.range("E1:E9")), warningOnly: false),
        ]
        var warned = Sheet(name: "Warned")
        warned.protections = [ProtectedRange(scope: .sheet(except: []), description: "Careful")]
        let package = try Self.write(Workbook(sheets: [sheet, warned]))
        let content = try Self.content(package)
        // The sheet protection that refuses edits is a protected table without a password.
        #expect(content.contains("<table:table table:name=\"Budget\" table:style-name=\"ta1\" table:protected=\"true\">"))
        #expect(!content.contains("protection-key"))
        #expect(content.contains("<table:table table:name=\"Warned\" table:style-name=\"ta1\">"))
        // Its exceptions are cells whose style leaves them editable, formatted or not.
        #expect(content.contains("<style:style style:name=\"ce1\" style:family=\"table-cell\" style:parent-style-name=\"Default\"><style:table-cell-properties fo:background-color=\"#fff2cc\" style:cell-protect=\"none\"/></style:style>"))
        #expect(content.contains("<style:style style:name=\"ce2\" style:family=\"table-cell\" style:parent-style-name=\"Default\"><style:table-cell-properties style:cell-protect=\"none\"/></style:style>"))
        #expect(content.contains("<table:table-row table:style-name=\"ro1\"><table:table-cell table:style-name=\"ce1\" office:value-type=\"string\" calcext:value-type=\"string\"><text:p>Input</text:p></table:table-cell><table:table-cell table:number-columns-repeated=\"25\"/></table:table-row>"))
        #expect(content.contains("<table:table-cell table:style-name=\"ce2\"/><table:table-cell table:number-columns-repeated=\"23\"/>"))

        let file = try SpreadsheetIO.read(package, format: .ods)
        #expect(file.warnings.isEmpty)
        #expect(file.workbook.sheets[0].protections == sheet.protections)
        #expect(file.workbook.sheets[1].protections == warned.protections)
        #expect(file.workbook.sheets[0][0, 0] == sheet[0, 0] && file.workbook.sheets[0].cells.count == sheet.cells.count)

        // As LibreOffice saves it: the protected table, with its editable cells as exceptions.
        let saved = try SpreadsheetIO.read(try IOODSObjectsTests.withoutPuggleSettings(package), format: .ods)
        #expect(saved.warnings.isEmpty)
        #expect(saved.workbook.sheets[0].protections.map(\.scope) == [.sheet(except: [Self.range("A1:A3"), Self.range("C5")])])
        #expect(saved.workbook.sheets[0].protections.first?.warningOnly == false)
        #expect(saved.workbook.sheets[1].protections.isEmpty)
    }

    @Test func readsLibreOfficeProtection() throws {
        // A password hash, LibreOffice's protection options, editable cells by cell style and by column default.
        let body = """
            <table:table table:name="Locked" table:style-name="ta1" table:protected="true" table:protection-key="JzG9z7OyFq4hUm0S8EeqX7hTuJc=" table:protection-key-digest-algorithm="http://www.w3.org/2000/09/xmldsig#sha1">
            <loext:table-protection loext:select-protected-cells="true" loext:select-unprotected-cells="true"/>
            <table:table-column table:default-cell-style-name="Default"/><table:table-column table:default-cell-style-name="open"/><table:table-column table:number-columns-repeated="1022" table:default-cell-style-name="Default"/>
            <table:table-row><table:table-cell table:style-name="open" office:value-type="float" office:value="1"><text:p>1</text:p></table:table-cell><table:table-cell table:number-columns-repeated="1023"/></table:table-row>
            <table:table-row><table:table-cell table:style-name="openFormatted" table:number-columns-repeated="1"/><table:table-cell/><table:table-cell table:style-name="locked"/><table:table-cell table:number-columns-repeated="1021"/></table:table-row>
            <table:table-row table:number-rows-repeated="1048574"><table:table-cell table:number-columns-repeated="1024"/></table:table-row>
            </table:table>
            """
        let styles = """
            <style:style style:name="open" style:family="table-cell" style:parent-style-name="Default"><style:table-cell-properties style:cell-protect="none" style:print-content="true"/></style:style>
            <style:style style:name="openFormatted" style:family="table-cell" style:parent-style-name="open"><style:table-cell-properties fo:background-color="#ffff00"/></style:style>
            <style:style style:name="locked" style:family="table-cell" style:parent-style-name="Default"><style:table-cell-properties style:cell-protect="protected formula-hidden"/></style:style>
            """
        let file = try IOTestODS.read(try IOTestODS.package(content: IOTestODS.content(body, automaticStyles: styles)))
        #expect(file.warnings.isEmpty)
        let sheet = file.workbook.sheets[0]
        // A1:A2 (by their own styles) and column B (by its default style) stay editable, within the grid.
        #expect(sheet.protections.map(\.scope) == [.sheet(except: [Self.range("A1:A2"), Self.range("B1:B1000")])])
        #expect(sheet.protections.first?.warningOnly == false)
        #expect(sheet[0, 0].value == .number(1))

        // Protecting the workbook's structure can't be kept.
        let structure = IOTestODS.content("<table:table table:name=\"Sheet1\"><table:table-row><table:table-cell/></table:table-row></table:table>")
            .replacingOccurrences(of: "<office:spreadsheet>", with: "<office:spreadsheet table:structure-protected=\"true\" table:protection-key=\"abc\">")
        #expect(try IOTestODS.read(try IOTestODS.package(content: structure)).warnings == [.protection])
    }

    // MARK: - Text rotation

    @Test func textRotationRoundTrip() throws {
        var sheet = Sheet(name: "Rotation")
        let rotations: [TextRotation] = [.angle(45), .angle(-30), .angle(90), .angle(-90), .stacked, .angle(0)]
        for (column, rotation) in rotations.enumerated() {
            sheet[0, column] = Cell(value: .text("Turned"), format: IOTest.format { $0.textRotation = rotation })
        }
        sheet[1, 0] = Cell(value: .text("Bordered"), format: IOTest.format {
            $0.textRotation = .angle(60)
            $0.borders = CellBorders(top: BorderLine())
        })
        let package = try Self.write(Workbook(sheets: [sheet]))
        let content = try Self.content(package)
        // Counterclockwise degrees from 0 to 360, inside the cell, or from the bottom edge (with slanted borders) when bordered.
        #expect(content.contains("<style:table-cell-properties style:rotation-angle=\"45\" style:rotation-align=\"none\"/>"))
        #expect(content.contains("style:rotation-angle=\"330\" style:rotation-align=\"none\""))
        #expect(content.contains("style:rotation-angle=\"270\" style:rotation-align=\"none\""))
        #expect(content.contains("<style:table-cell-properties style:direction=\"ttb\"/>"))
        #expect(content.contains("style:rotation-angle=\"60\" style:rotation-align=\"bottom\""))
        let read = try SpreadsheetIO.read(package, format: .ods).workbook.sheets[0]
        for column in 0..<5 { #expect(read[0, column] == sheet[0, column], "\(rotations[column])") }
        #expect(read[0, 5].format.textRotation == nil && read[0, 5].format.isDefault)
        #expect(read[1, 0] == sheet[1, 0])

        // LibreOffice's angles, with or without units; upside-down angles come back upright.
        #expect(ODSStyleSheet.rotation(degrees: 315) == .angle(-45))
        #expect(ODSStyleSheet.rotation(degrees: 135) == .angle(90) && ODSStyleSheet.rotation(degrees: 225) == .angle(-90))
        #expect(ODSStyleSheet.degrees("90deg") == 90 && ODSStyleSheet.degrees("100grad") == 90)
        #expect(ODSStyleSheet.rotation(degrees: 0) == nil && ODSStyleSheet.rotation(degrees: 360) == nil)
        #expect(ODSStyleSheet.rotation(degrees: 1e308) != .stacked && ODSStyleSheet.rotation(degrees: -405) == .angle(-45))
    }

    // MARK: - Row and column groups

    static func groupedSheet() -> Sheet {
        var sheet = Sheet(name: "Outline")
        for row in 0..<12 { sheet[row, 0] = Cell(value: .number(Double(row))) }
        sheet.rowGroups = [OutlineGroup(range: 1...8), OutlineGroup(range: 2...4, isCollapsed: true), OutlineGroup(range: 6...7),
                           OutlineGroup(range: 10...11, isCollapsed: true)]
        sheet.columnGroups = [OutlineGroup(range: 1...3, isCollapsed: true), OutlineGroup(range: 2...2)]
        // Hidden by hand: inside an expanded group, and inside a collapsed one.
        sheet.hiddenRows = [7, 3]
        sheet.hiddenColumns = [5]
        return sheet
    }

    @Test func groupsRoundTrip() throws {
        let sheet = Self.groupedSheet()
        let package = try Self.write(Workbook(sheets: [sheet]))
        let content = try Self.content(package)
        // Nested groups; collapsed ones hidden, with their rows and columns collapsed.
        #expect(content.contains("<table:table-column-group table:display=\"false\"><table:table-column table:style-name=\"co1\" table:visibility=\"collapse\" table:default-cell-style-name=\"Default\"/><table:table-column-group><table:table-column table:style-name=\"co1\" table:visibility=\"collapse\" table:default-cell-style-name=\"Default\"/></table:table-column-group><table:table-column table:style-name=\"co1\" table:visibility=\"collapse\" table:default-cell-style-name=\"Default\"/></table:table-column-group>"))
        let rows = content.components(separatedBy: "<table:table table:name=\"Outline\"")[1]
        let order = ["<table:table-row-group>", "<text:p>1</text:p>", "<table:table-row-group table:display=\"false\">",
                     "<table:table-row table:style-name=\"ro1\" table:visibility=\"collapse\"><table:table-cell office:value-type=\"float\" office:value=\"2\"",
                     "</table:table-row-group>", "<text:p>5</text:p>", "<table:table-row-group>", "<text:p>7</text:p>", "</table:table-row-group>",
                     "<text:p>8</text:p>", "</table:table-row-group>", "<text:p>9</text:p>", "<table:table-row-group table:display=\"false\">",
                     "<text:p>11</text:p>", "</table:table-row-group>"]
        var position = rows.startIndex
        for marker in order {
            guard let found = rows.range(of: marker, range: position..<rows.endIndex) else {
                Issue.record("missing \(marker)")
                break
            }
            position = found.upperBound
        }

        let file = try SpreadsheetIO.read(package, format: .ods)
        #expect(file.warnings.isEmpty)
        let read = file.workbook.sheets[0]
        #expect(read.rowGroups == sheet.rowGroups && read.columnGroups == sheet.columnGroups)
        #expect(read.hiddenRows == sheet.hiddenRows && read.hiddenColumns == sheet.hiddenColumns)
        #expect((0..<12).map(read.isRowHidden) == (0..<12).map(sheet.isRowHidden))

        // As LibreOffice saves it: rows hidden by hand inside a collapsed group become the group's.
        let saved = try SpreadsheetIO.read(try IOODSObjectsTests.withoutPuggleSettings(package), format: .ods).workbook.sheets[0]
        #expect(saved.rowGroups == sheet.rowGroups && saved.columnGroups == sheet.columnGroups)
        #expect(saved.hiddenRows == [7] && saved.hiddenColumns == [5])
    }

    @Test func groupsThatOverlapAreLeftOut() throws {
        var sheet = Sheet(name: "Sheet1")
        sheet.rowGroups = [OutlineGroup(range: 2...5), OutlineGroup(range: 4...8, isCollapsed: true), OutlineGroup(range: 2...5)]
        sheet.columnGroups = [OutlineGroup(range: 30...31)]
        let read = try Self.roundTrip(Workbook(sheets: [sheet])).workbook.sheets[0]
        // Only groups that sit inside one another can be written; a group past the grid grows it.
        #expect(read.rowGroups == [OutlineGroup(range: 2...5), OutlineGroup(range: 2...5)])
        #expect(read.columnGroups == [OutlineGroup(range: 30...31)] && read.columnCount == 32)
    }

    // MARK: - Everything together

    @Test func survivesDamagedCollaboration() throws {
        var sheet = Self.groupedSheet()
        sheet[0, 1] = Cell(value: .text("Rotated"), format: IOTest.format { $0.textRotation = .angle(30) }, note: "Note")
        sheet[0, 2] = Cell(value: .text("Discussed"), comment: Self.thread())
        sheet.protections = [ProtectedRange(scope: .sheet(except: [Self.range("B1:B5")]), warningOnly: false),
                             ProtectedRange(scope: .range(Self.range("F1:F3")), description: "Careful")]
        let package = try Self.write(Workbook(sheets: [sheet]))
        let zip = try ZipReader(data: package)
        var parts: [String: Data] = [:]
        for entry in zip.entries { parts[entry.path] = try zip.read(entry) }
        let fragments = ["<table:table-row-group table:display=\"false\">", "</table:table-row-group>", "<table:table-column-group>",
                         "<office:annotation><text:p>x", "</office:annotation>", "style:rotation-angle=\"1e308\"", "style:direction=\"ttb\"",
                         "table:protected=\"true\"", "style:cell-protect=\"none\"", "config:type=\"int\">999999999999<",
                         "<config:config-item config:name=\"Last\" config:type=\"int\">2000000000</config:config-item>"]
        var random = IOTestRandom(seed: 1618)
        var readable = 0
        for _ in 0..<200 {
            var damaged = parts
            let target = random.next() % 2 == 0 ? "content.xml" : "settings.xml"
            var scalars = Array(String(decoding: parts[target] ?? Data(), as: UTF8.self).unicodeScalars)
            for _ in 0..<(1 + Int(random.next() % 4)) {
                let position = Int(random.next() % UInt64(scalars.count + 1))
                switch random.next() % 3 {
                case 0: scalars.removeSubrange(position..<min(scalars.count, position + Int(random.next() % 60)))
                case 1: scalars.insert(contentsOf: fragments[Int(random.next() % UInt64(fragments.count))].unicodeScalars, at: position)
                default:
                    let end = min(scalars.count, position + Int(random.next() % 120))
                    scalars.insert(contentsOf: scalars[position..<end], at: position)
                }
            }
            damaged[target] = Data(String(String.UnicodeScalarView(scalars)).utf8)
            var writer = ZipWriter()
            for entry in zip.entries { try writer.add(entry.path, damaged[entry.path] ?? Data(), compress: entry.path != "mimetype") }
            do {
                let file = try SpreadsheetIO.read(try writer.finish(), format: .ods)
                readable += 1
                #expect(!file.workbook.sheets.isEmpty)
                #expect(file.workbook.sheets.allSatisfy { $0.hiddenRows.count <= $0.rowCount })
            } catch let error as SpreadsheetIOError {
                #expect(!(error.errorDescription ?? "").isEmpty)
            }
        }
        #expect(readable > 0)
    }

    @Test func everythingValidatesAndRoundTrips() throws {
        var sheet = Self.groupedSheet()
        sheet[0, 1] = Cell(value: .text("Rotated"), format: IOTest.format { $0.textRotation = .angle(30) }, note: "Note")
        sheet[0, 2] = Cell(value: .text("Discussed"), comment: Self.thread())
        sheet.protections = [ProtectedRange(scope: .sheet(except: [Self.range("B1:B5")]), warningOnly: false)]
        let workbook = Workbook(sheets: [sheet, IOODSObjectsTests.everythingWorkbook().sheets[0]])
        let package = try Self.write(workbook)
        let zip = try ZipReader(data: package)
        for entry in zip.entries where entry.path.hasSuffix(".xml") {
            #expect(IOTestPackage.isWellFormed(try zip.read(entry)), "\(entry.path)")
        }
        let file = try SpreadsheetIO.read(package, format: .ods)
        #expect(file.warnings.isEmpty)
        let read = file.workbook.sheets[0]
        #expect(read[0, 1] == sheet[0, 1] && read[0, 2] == sheet[0, 2])
        #expect(read.protections == sheet.protections && read.rowGroups == sheet.rowGroups)
    }
}
