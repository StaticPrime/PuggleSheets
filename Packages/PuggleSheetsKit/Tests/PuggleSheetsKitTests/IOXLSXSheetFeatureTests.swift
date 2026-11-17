import Foundation
import Testing
@testable import PuggleSheetsKit

/// Protected ranges, text rotation, and row and column groups in Excel files.
struct IOXLSXSheetFeatureTests {
    static func range(_ text: String) -> CellRange { CellRange(a1: text)! }

    // MARK: - Protected ranges

    static func protectedSheet() -> Sheet {
        var sheet = Sheet(name: "Ledger")
        sheet[0, 0] = Cell(value: .text("Total"), format: IOTest.format { $0.bold = true })
        sheet[1, 1] = Cell(value: .number(42))
        sheet[5, 3] = Cell(value: .text("free"))
        sheet.protections = [
            ProtectedRange(scope: .sheet(except: [range("B2:C3"), range("D6")]), description: "Everything but the inputs", warningOnly: false),
            ProtectedRange(scope: .range(range("C3")), description: "Formula", warningOnly: false),
            ProtectedRange(scope: .range(range("F1:F20")), description: "Check first"),
        ]
        return sheet
    }

    @Test func protectionsRoundTripExactly() throws {
        let sheet = Self.protectedSheet()
        let file = try IOXLSXObjectTests.roundTrip(Workbook(sheets: [sheet]))
        #expect(file.warnings.isEmpty)
        #expect(file.workbook.sheets[0].protections == sheet.protections)
        #expect(file.workbook.sheets[0][0, 0] == sheet[0, 0] && file.workbook.sheets[0][1, 1] == sheet[1, 1])
    }

    @Test func wholeSheetProtectionAsExcelWritesIt() throws {
        let data = try SpreadsheetIO.write(Workbook(sheets: [Self.protectedSheet()]), activeSheet: 0, format: .xlsx)
        #expect(try IOXLSXPackageCheck.problems(data).isEmpty)
        let sheetPart = try #require(try IOTestPackage.part("xl/worksheets/sheet1.xml", of: data))
        // No password, right after the cells.
        #expect(sheetPart.contains("</sheetData><sheetProtection sheet=\"1\" objects=\"1\" scenarios=\"1\"/><pageMargins"))
        #expect(!sheetPart.contains("password") && !sheetPart.contains("hashValue"))
        // The exceptions are unlocked cells, written even when empty; C3, protected on its own, stays locked.
        let styles = try #require(try IOTestPackage.part("xl/styles.xml", of: data))
        #expect(styles.contains("<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyProtection=\"1\"><protection locked=\"0\"/></xf>"))
        let style = try #require(Self.unlockedStyleIndex(styles))
        for cell in ["B2", "C2", "B3", "D6"] {
            #expect(sheetPart.contains("<c r=\"\(cell)\" s=\"\(style)\""), "\(cell)")
        }
        #expect(!sheetPart.contains("<c r=\"C3\""))
        #expect(!sheetPart.contains("<c r=\"A1\" s=\"\(style)\""))
    }

    /// The index of the first unlocked cell format in styles.xml.
    static func unlockedStyleIndex(_ styles: String) -> Int? {
        guard let cellXfs = styles.range(of: "<cellXfs")?.upperBound else { return nil }
        let formats = styles[cellXfs...].components(separatedBy: "<xf ").dropFirst()
        return formats.firstIndex { $0.contains("locked=\"0\"") }.map { $0 - 1 }
    }

    @Test func rangesAndWarningsHaveNoExcelProtection() throws {
        var sheet = Sheet(name: "S")
        sheet.protections = [ProtectedRange(scope: .sheet(except: []), description: "Warn only"),
                             ProtectedRange(scope: .range(Self.range("A1:B2")), warningOnly: false)]
        let data = try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx)
        #expect(!(try IOTestPackage.part("xl/worksheets/sheet1.xml", of: data) ?? "").contains("sheetProtection"))
        #expect(try IOTestPackage.read(data).workbook.sheets[0].protections == sheet.protections)
    }

    @Test func excelSheetProtectionIsRead() throws {
        let styles = IOTestPackage.styles("<cellXfs count=\"3\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" applyProtection=\"1\"><protection locked=\"0\"/></xf>"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" applyProtection=\"1\"><protection hidden=\"1\"/></xf></cellXfs>")
        let body = """
            <sheetData><row r="1"><c r="A1" s="2"><v>1</v></c><c r="B1" s="1"/><c r="C1" s="1"/></row>
            <row r="2"><c r="B2" s="1"/><c r="C2" s="1"><v>5</v></c></row><row r="5"><c r="E5" s="1"/></row></sheetData>
            <sheetProtection algorithmName="SHA-512" hashValue="xyz=" saltValue="abc=" spinCount="100000" password="CC1A" sheet="1" objects="1" scenarios="1"/>
            <protectedRanges><protectedRange sqref="G1:G10 H2" name="Inputs"/></protectedRanges>
            """
        let file = try IOTestPackage.read(try IOTestPackage.xlsx(sheet: body, styles: styles))
        #expect(file.warnings.isEmpty)
        let sheet = file.workbook.sheets[0]
        #expect(sheet.protections.count == 1)
        let protection = try #require(sheet.protections.first)
        #expect(!protection.warningOnly && protection.description.isEmpty)
        // Unlocked cells become exception blocks, followed by the ranges anyone may edit.
        #expect(protection.scope == .sheet(except: [Self.range("B1:C2"), Self.range("E5"), Self.range("G1:G10"), Self.range("H2")]))
        #expect(sheet[1, 2].value == .number(5) && sheet[0, 0].value == .number(1))
        // Not protected: no protection.
        let open = try IOTestPackage.read(try IOTestPackage.xlsx(sheet: "<sheetData/><sheetProtection sheet=\"0\"/>"))
        #expect(open.workbook.sheets[0].protections.isEmpty && open.warnings.isEmpty)
    }

    @Test func largeExceptionsStayInPuggleSheetsPart() throws {
        var sheet = Sheet(name: "S")
        sheet.protections = [ProtectedRange(scope: .sheet(except: [Self.range("A1:Z10000")]), warningOnly: false)]
        let data = try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx)
        // 260,000 cells is more than unlocking cell by cell is worth.
        let sheetPart = try #require(try IOTestPackage.part("xl/worksheets/sheet1.xml", of: data))
        #expect(sheetPart.contains("<sheetProtection") && !sheetPart.contains("<c r="))
        #expect(try IOTestPackage.read(data).workbook.sheets[0].protections == sheet.protections)
    }

    // MARK: - Text rotation

    @Test func textRotationRoundTrips() throws {
        let rotations: [TextRotation] = [.angle(-90), .angle(-45), .angle(-1), .angle(1), .angle(30), .angle(90), .stacked]
        var sheet = Sheet(name: "S")
        for (row, rotation) in rotations.enumerated() {
            sheet[row, 0] = Cell(value: .text("turned"), format: IOTest.format { $0.textRotation = rotation; $0.bold = row == 0 })
        }
        let file = try IOXLSXObjectTests.roundTrip(Workbook(sheets: [sheet]))
        for row in rotations.indices { #expect(file.workbook.sheets[0][row, 0] == sheet[row, 0], "\(rotations[row])") }
        let styles = try IOXLSXObjectTests.part("xl/styles.xml", of: Workbook(sheets: [sheet]))
        for value in [180, 135, 91, 1, 30, 90, 255] {
            #expect(styles.contains("<alignment textRotation=\"\(value)\"/>"), "\(value)")
        }
        #expect(XLSXStyleSheet.rotation(0) == nil && XLSXStyleSheet.rotation(200) == nil && XLSXStyleSheet.rotation(nil) == nil)
        #expect(XLSXStyleWriter.rotation(.angle(120)) == 90 && XLSXStyleWriter.rotation(.angle(-200)) == 180)
    }

    // MARK: - Row and column groups

    static func groupedSheet() -> Sheet {
        var sheet = Sheet(name: "Groups")
        sheet[0, 0] = Cell(value: .text("Region"))
        sheet.rowGroups = [OutlineGroup(range: 2...10), OutlineGroup(range: 3...5, isCollapsed: true), OutlineGroup(range: 7...8),
                           OutlineGroup(range: 14...16, isCollapsed: true), OutlineGroup(range: 20...22)]
        sheet.columnGroups = [OutlineGroup(range: 1...4), OutlineGroup(range: 2...3, isCollapsed: true), OutlineGroup(range: 8...9, isCollapsed: true)]
        // Hidden by hand, inside a group and outside.
        sheet.hiddenRows = [8, 30]
        sheet.hiddenColumns = [12]
        return sheet
    }

    static func sorted(_ groups: [OutlineGroup]) -> [OutlineGroup] {
        groups.sorted { ($0.range.lowerBound, -$0.range.upperBound) < ($1.range.lowerBound, -$1.range.upperBound) }
    }

    @Test func groupsRoundTrip() throws {
        let sheet = Self.groupedSheet()
        let file = try IOXLSXObjectTests.roundTrip(Workbook(sheets: [sheet]))
        #expect(file.warnings.isEmpty)
        let copy = file.workbook.sheets[0]
        #expect(Self.sorted(copy.rowGroups) == Self.sorted(sheet.rowGroups))
        #expect(Self.sorted(copy.columnGroups) == Self.sorted(sheet.columnGroups))
        // Rows hidden by collapsed groups read back as collapsed, not hidden by hand.
        #expect(copy.hiddenRows == [8, 30] && copy.hiddenColumns == [12])
        #expect(copy.isRowHidden(4) && copy.isColumnHidden(3) && !copy.isRowHidden(9))
        #expect(copy.rowCount == sheet.rowCount && copy.columnCount == sheet.columnCount)
    }

    @Test func groupsAsExcelWritesThem() throws {
        let sheetPart = try IOXLSXObjectTests.part("xl/worksheets/sheet1.xml", of: Workbook(sheets: [Self.groupedSheet()]))
        #expect(sheetPart.contains("<sheetFormatPr defaultColWidth=\"14.28515625\" defaultRowHeight=\"15.75\" customHeight=\"1\" "
            + "outlineLevelRow=\"2\" outlineLevelCol=\"2\"/>"))
        #expect(sheetPart.contains("<row r=\"3\" outlineLevel=\"1\"/><row r=\"4\" hidden=\"1\" outlineLevel=\"2\"/><row r=\"5\" hidden=\"1\" outlineLevel=\"2\"/>"
            + "<row r=\"6\" hidden=\"1\" outlineLevel=\"2\"/><row r=\"7\" outlineLevel=\"1\" collapsed=\"1\"/>"))
        // Row 9 is hidden by hand inside an open group.
        #expect(sheetPart.contains("<row r=\"9\" hidden=\"1\" outlineLevel=\"2\"/>"))
        #expect(sheetPart.contains("<row r=\"18\" collapsed=\"1\"/>"))
        #expect(sheetPart.contains("<cols><col min=\"2\" max=\"2\" width=\"14.28515625\" outlineLevel=\"1\"/>"
            + "<col min=\"3\" max=\"4\" width=\"14.28515625\" hidden=\"1\" outlineLevel=\"2\"/>"
            + "<col min=\"5\" max=\"5\" width=\"14.28515625\" outlineLevel=\"1\" collapsed=\"1\"/>"
            + "<col min=\"9\" max=\"10\" width=\"14.28515625\" hidden=\"1\" outlineLevel=\"1\"/><col min=\"11\" max=\"11\" width=\"14.28515625\" collapsed=\"1\"/>"
            + "<col min=\"13\" max=\"13\" width=\"14.28515625\" hidden=\"1\"/></cols>"))
    }

    @Test func excelOutlinesAreRead() throws {
        // Summary rows above their groups, as some files set it.
        let body = """
            <sheetPr><outlinePr summaryBelow="0"/></sheetPr><sheetFormatPr defaultRowHeight="15" outlineLevelRow="2"/>
            <cols><col min="3" max="5" width="9" hidden="1" outlineLevel="1"/><col min="6" max="6" width="9" collapsed="1"/></cols>
            <sheetData><row r="2" collapsed="1"/><row r="3" hidden="1" outlineLevel="1"/><row r="4" hidden="1" outlineLevel="2"/>
            <row r="5" hidden="1" outlineLevel="2"/><row r="6" outlineLevel="1"/><row r="8" hidden="1"/></sheetData>
            """
        let file = try IOTestPackage.read(try IOTestPackage.xlsx(sheet: body))
        let sheet = file.workbook.sheets[0]
        #expect(Self.sorted(sheet.rowGroups) == [OutlineGroup(range: 2...5, isCollapsed: true), OutlineGroup(range: 3...4)])
        #expect(sheet.columnGroups == [OutlineGroup(range: 2...4, isCollapsed: true)])
        #expect(sheet.hiddenRows == [7] && sheet.hiddenColumns.isEmpty)
        #expect(sheet.columnCount == 26)
    }

    @Test func deepNestingIsClampedToExcelsSevenLevels() throws {
        var sheet = Sheet(name: "Deep")
        sheet.rowGroups = (0..<9).map { OutlineGroup(range: $0...(20 - $0)) }
        let copy = try IOXLSXObjectTests.roundTrip(Workbook(sheets: [sheet])).workbook.sheets[0]
        #expect(Self.sorted(copy.rowGroups) == (0..<7).map { OutlineGroup(range: $0...(20 - $0)) })
        #expect(try IOXLSXObjectTests.part("xl/worksheets/sheet1.xml", of: Workbook(sheets: [sheet])).contains("outlineLevelRow=\"7\""))
    }

    @Test func collapsedGroupsEndingWithTheirParentStayOpen() throws {
        // Excel marks a collapse on the row after a group, at the level just outside it; a group ending where its
        // parent ends has no such row, so its collapse isn't kept (its rows stay hidden only in PuggleSheets).
        var sheet = Sheet(name: "S")
        sheet.rowGroups = [OutlineGroup(range: 2...10), OutlineGroup(range: 6...10, isCollapsed: true)]
        let copy = try IOXLSXObjectTests.roundTrip(Workbook(sheets: [sheet])).workbook.sheets[0]
        #expect(Self.sorted(copy.rowGroups) == [OutlineGroup(range: 2...10), OutlineGroup(range: 6...10)])
        // Its rows were written hidden, and read back as hidden by hand.
        #expect(copy.hiddenRows == Set(6...10))
    }

    @Test func groupsSurviveWithEverythingElse() throws {
        var sheet = Self.groupedSheet()
        sheet.protections = Self.protectedSheet().protections
        sheet[3, 3] = Cell(value: .text("note here"), format: IOTest.format { $0.textRotation = .angle(15) }, note: "In a collapsed group")
        // Rows hidden inside a filtered range read back as the filter's, so the filter sits apart.
        sheet.filter = SheetFilter(range: Self.range("A25:C28"))
        sheet.filteredRows = [26]
        let data = try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: .xlsx)
        #expect(try IOXLSXPackageCheck.problems(data).isEmpty)
        let copy = try IOTestPackage.read(data).workbook.sheets[0]
        #expect(copy[3, 3] == sheet[3, 3])
        #expect(copy.filteredRows == [26] && copy.hiddenRows == [8, 30])
        #expect(Self.sorted(copy.rowGroups) == Self.sorted(sheet.rowGroups))
        #expect(copy.protections == sheet.protections)
    }
}
