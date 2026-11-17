import Foundation
import Testing
@testable import PuggleSheetsKit

/// Phase 4's model: notes, comments, protected ranges, row and column groups and text rotation.
struct CollaborationModelTests {
    static func address(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    static func range(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    @Test func notesAndCommentsKeepCells() {
        #expect(!Cell(note: "Check this").isEmpty)
        let thread = CommentThread(comments: [Comment(author: "Ana", text: "Is this right?")])
        #expect(!Cell(comment: thread).isEmpty)
        #expect(!Cell(note: "x").hasContent)
        var sheet = Sheet(name: "Sheet1")
        sheet[2, 1] = Cell(value: .number(4), note: "Estimated")
        sheet.applyStructuralChange(.insertRows(at: 0, count: 2))
        #expect(sheet[Self.address("B5")].note == "Estimated")
    }

    @Test func protectedRanges() {
        let range = ProtectedRange(scope: .range(Self.range("B2:C5")), description: "Totals")
        #expect(range.covers(Self.address("C3")) && !range.covers(Self.address("D3")))
        #expect(range.covers(anyOf: Self.range("A1:B2")) && !range.covers(anyOf: Self.range("D1:E9")))
        let sheet = ProtectedRange(scope: .sheet(except: [Self.range("A1:A10")]), warningOnly: false)
        #expect(!sheet.covers(Self.address("A5")) && sheet.covers(Self.address("B5")))
        #expect(!sheet.covers(anyOf: Self.range("A2:A4")) && sheet.covers(anyOf: Self.range("A2:B4")))

        var model = Sheet(name: "Sheet1")
        model.protections = [range, sheet]
        #expect(model.protection(covering: Self.address("C3"))?.id == sheet.id)
        model.applyStructuralChange(.insertColumns(at: 0, count: 1))
        #expect(model.protections[0].scope == .range(Self.range("C2:D5")))
        #expect(model.protections[1].scope == .sheet(except: [Self.range("B1:B10")]))
        model.applyStructuralChange(.deleteColumns(at: 2, count: 2))
        #expect(model.protections.count == 1)
    }

    @Test func outlineGroups() {
        var sheet = Sheet(name: "Sheet1")
        sheet.rowGroups = [OutlineGroup(range: 2...9), OutlineGroup(range: 4...6, isCollapsed: true)]
        #expect(sheet.isRowHidden(5) && !sheet.isRowHidden(3))
        #expect(sheet.rowGroups.depth(of: sheet.rowGroups[1]) == 1 && sheet.rowGroups.maximumDepth == 2)
        #expect(sheet.rowGroups.collapsedIndexes == [4, 5, 6])
        sheet.applyStructuralChange(.insertRows(at: 0, count: 1))
        #expect(sheet.rowGroups.map(\.range) == [3...10, 5...7])
        sheet.applyStructuralChange(.deleteRows(at: 5, count: 3))
        #expect(sheet.rowGroups.map(\.range) == [3...7])
        sheet.columnGroups = [OutlineGroup(range: 1...2, isCollapsed: true)]
        #expect(sheet.isColumnHidden(2) && !sheet.isColumnHidden(3))
    }

    @Test func textRotationIsFormatting() {
        var format = CellFormat()
        format.textRotation = .angle(45)
        #expect(!format.isDefault)
        format.textRotation = .stacked
        #expect(format != CellFormat())
    }
}
