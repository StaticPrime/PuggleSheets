import Foundation
import Testing
@testable import PuggleSheetsKit

/// Sharing a workbook between Macs: how it travels, the ops that change it, rewriting one Mac's ops to follow
/// another's, and many Macs editing at once through one log ending up with the same workbook.
struct SharingTests {
    static func address(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    static func range(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    /// Whether two workbooks are the same, comments and the formula engine's results aside.
    static func same(_ a: Workbook, _ b: Workbook) -> Bool { difference(a, b) == nil }

    static func difference(_ a: Workbook, _ b: Workbook) -> String? {
        guard a.sheets.map(\.id) == b.sheets.map(\.id) else { return "sheets \(a.sheets.map(\.name)) vs \(b.sheets.map(\.name))" }
        guard a.namedRanges == b.namedRanges else { return "named ranges" }
        for (x, y) in zip(a.sheets, b.sheets) {
            guard x.name == y.name else { return "name \(x.name) vs \(y.name)" }
            let cells = WorkbookOp.cellChanges(from: x, to: y)
            guard cells.isEmpty else {
                let first = cells.keys.sorted().first!
                return "\(x.name) cells \(cells.keys.sorted().prefix(4).map(\.a1)): \(x.cells[first].map { "\($0.value) \($0.formula ?? "")" } ?? "none") vs \(y.cells[first].map { "\($0.value) \($0.formula ?? "")" } ?? "none")"
            }
            let layout = SheetLayoutPatch.diff(from: x, to: y)
            guard layout.isEmpty else { return "\(x.name) layout \(layout.entries.keys.sorted())" }
        }
        return nil
    }

    static func sample() -> Workbook {
        var budget = Sheet(name: "Budget")
        var bold = CellFormat()
        bold.bold = true
        bold.fillColor = RGBColor(red: 250, green: 240, blue: 200)
        bold.borders.bottom = BorderLine(style: .thick)
        budget[0, 0] = Cell(value: .text("Item"), format: bold)
        budget[0, 1] = Cell(value: .text("Cost"), format: bold, note: "In dollars")
        budget[1, 0] = Cell(value: .text("Rent"))
        budget[1, 1] = Cell(value: .number(1200.5))
        budget[2, 0] = Cell(value: .text("Food"), link: "https://example.com")
        budget[2, 1] = Cell(value: .number(400))
        budget[3, 1] = Cell(value: .number(1600.5), formula: "=SUM(B2:B3)")
        budget[4, 1] = Cell(value: .error(CellError(.divideByZero, "nope")), formula: "=1/0")
        budget[5, 0] = Cell(value: .boolean(true))
        budget[6, 0] = Cell(comment: CommentThread(comments: [Comment(author: "Ana", text: "Check this")]))
        budget.columnWidths = [0: 140, 3: 60]
        budget.rowHeights = [2: 30]
        budget.merges = [range("D1:E1")]
        budget.hiddenRows = [9]
        budget.frozenRows = 1
        budget.conditionalFormats = [ConditionalFormatRule(ranges: [range("B2:B10")],
                                                           style: .condition(CellCondition(.greaterThan, ["=B2*2"]),
                                                                             ConditionalFormat(bold: true)))]
        budget.validations = [DataValidationRule(ranges: [range("A2:A10")], criterion: .listFromRange("Lists!A1:A3"))]
        budget.filter = SheetFilter(range: range("A1:B6"), criteria: [1: FilterCriterion(hiddenValues: ["400"], condition: nil)])
        budget.filteredRows = [2]
        budget.objects = [SheetObject(anchor: ObjectAnchor(cell: address("D3"), width: 300, height: 200),
                                      content: .chart(ChartSpec(kind: .column, ranges: ["A1:B4"])))]
        budget.tables = [SheetTable(name: "Costs", range: range("A1:B4"), columnTypes: [1: .currency], color: RGBColor(red: 1, green: 2, blue: 3))]
        budget.rowGroups = [OutlineGroup(range: 2...3, isCollapsed: false)]
        budget.protections = [ProtectedRange(scope: .range(range("A1:A2")), description: "Header")]
        var lists = Sheet(name: "Lists")
        lists[0, 0] = Cell(value: .text("a"))
        lists[1, 0] = Cell(value: .text("b"), formula: "=Budget!A2")
        lists.tabColor = RGBColor(red: 9, green: 8, blue: 7)
        return Workbook(sheets: [budget, lists], namedRanges: [NamedRange(name: "Costs2", reference: "Budget!$B$2:$B$3")])
    }

    // MARK: Coding

    @Test func workbookTravelsWhole() throws {
        let workbook = Self.sample()
        let data = try SyncCoding.encoder().encode(workbook)
        let back = try SyncCoding.decode(Workbook.self, from: data)
        #expect(Self.difference(workbook, back) == nil)
        #expect(back.sheets[0][6, 0].comment?.comments.first?.text == "Check this")
        let snapshot = SyncSnapshot(revision: 7, workbook: workbook, anchors: [UUID(): CommentAnchor(revision: 7, sheet: workbook.sheets[0].id, address: Self.address("A7"))])
        let restored = try SyncSnapshot(encoded: snapshot.encoded)
        #expect(restored.revision == 7 && restored.anchors.count == 1)
        #expect(Self.difference(workbook.withoutComments, restored.workbook) == nil)
        #expect(restored.workbook.sheets[0][6, 0].comment == nil)
    }

    @Test func opsTravelWhole() throws {
        let workbook = Self.sample()
        let id = workbook.sheets[0].id
        let ops: [WorkbookOp] = [
            .cells(sheet: id, cells: [Self.address("C3"): Cell(value: .number(5), formula: "=B3+1"), Self.address("A1"): Cell()]),
            .layout(sheet: id, patch: SheetLayoutPatch.diff(from: Sheet(name: "x"), to: workbook.sheets[0])),
            .structure(sheet: id, change: .insertRows(at: 2, count: 3)),
            .structure(sheet: id, change: .deleteCells(Self.range("B2:C4"), shiftUp: true)),
            .insertSheet(sheet: workbook.sheets[1], at: 1),
            .removeSheet(sheet: id),
            .renameSheet(sheet: id, name: "Money"),
            .moveSheet(sheet: id, to: 0),
            .namedRanges(workbook.namedRanges),
        ]
        let change = SharedChange(ops)
        let back = try SharedChange(encoded: change.encoded)
        var a = workbook.withoutComments, b = workbook.withoutComments
        a.apply(change.ops)
        b.apply(back.ops)
        #expect(Self.difference(a, b) == nil)
        #expect(back.ops.count == ops.count)
    }

    // MARK: Ops

    @Test func changesTurnOneWorkbookIntoAnother() {
        let old = Self.sample()
        var new = old
        new.sheets[0][1, 1] = Cell(value: .number(1300))
        new.sheets[0][8, 2] = Cell(value: .text("New"), formula: nil)
        new.sheets[0][2, 0] = Cell()
        new.sheets[0].columnWidths[0] = nil
        new.sheets[0].columnWidths[2] = 80
        new.sheets[0].hiddenRows = [4]
        new.sheets[0].merges = []
        new.renameSheet(at: 1, to: "Choices")
        new.sheets.append(Sheet(name: "Extra"))
        new.sheets.swapAt(0, 1)
        new.namedRanges = []
        let ops = WorkbookOp.changes(from: old, to: new)
        #expect(Self.difference(old.withoutComments.applying(ops), new.withoutComments) == nil)
        // A renamed sheet travels as a renaming, so formulas everywhere follow it.
        #expect(ops.contains { if case .renameSheet(_, "Choices") = $0 { true } else { false } })
        // Each column width goes on its own.
        let keys = ops.compactMap { op -> [String]? in if case .layout(_, let patch) = op { Array(patch.entries.keys) } else { nil } }.flatMap { $0 }
        #expect(keys.contains("cw:0") && keys.contains("cw:2") && keys.contains("hr:4") && keys.contains("hr:9") && keys.contains("merges"))
    }

    @Test func inversesTakeChangesBack() {
        let old = Self.sample()
        let id = old.sheets[0].id
        let lists = old.sheets[1].id
        let ops: [WorkbookOp] = [
            .cells(sheet: id, cells: [Self.address("B2"): Cell(value: .number(9))]),
            .structure(sheet: id, change: .deleteRows(at: 1, count: 2)),
            .structure(sheet: id, change: .insertColumns(at: 0, count: 1)),
            .renameSheet(sheet: lists, name: "Options"),
            .removeSheet(sheet: lists),
            .layout(sheet: id, patch: SheetLayoutPatch(entries: ["cw:5": .set(SyncCoding.encode(77.0))])),
        ]
        let after = old.withoutComments.applying(ops)
        let undo = WorkbookOp.inverse(of: ops, before: old, after: after)
        #expect(Self.difference(after.applying(undo), old.withoutComments) == nil)
    }

    @Test func formulasFollowStructuralChanges() {
        var workbook = Self.sample().withoutComments
        let id = workbook.sheets[0].id
        workbook.apply(.structure(sheet: id, change: .insertRows(at: 0, count: 2)))
        #expect(workbook.sheets[0][5, 1].formula == "=SUM(B4:B5)")
        #expect(workbook.sheets[1][1, 0].formula == "=Budget!A4")
        workbook.apply(.renameSheet(sheet: id, name: "Money"))
        #expect(workbook.sheets[1][1, 0].formula == "=Money!A4")
        // A clashing name gets a number.
        workbook.apply(.renameSheet(sheet: workbook.sheets[1].id, name: "money"))
        #expect(workbook.sheets[1].name == "money (2)")
    }

    // MARK: Rewriting to follow

    @Test func cellsFollowRowsInsertedAtTheSameTime() {
        let base = Self.sample().withoutComments
        let id = base.sheets[0].id
        let mine = WorkbookOp.cells(sheet: id, cells: [Self.address("B3"): Cell(value: .number(1), formula: "=B2+B4")])
        let theirs = WorkbookOp.structure(sheet: id, change: .insertRows(at: 1, count: 2))
        let (moved, _) = [mine].rebased(over: [theirs], context: base)
        guard case .cells(_, let cells)? = moved.first else {
            Issue.record("no cells")
            return
        }
        #expect(cells[Self.address("B5")]?.formula == "=B4+B6")
    }

    @Test func structuralChangesFollowEachOther() {
        #expect(StructuralChange.insertRows(at: 5, count: 2).rebased(over: .insertRows(at: 3, count: 1)) == [.insertRows(at: 6, count: 2)])
        #expect(StructuralChange.insertRows(at: 5, count: 2).rebased(over: .deleteRows(at: 2, count: 2)) == [.insertRows(at: 3, count: 2)])
        #expect(StructuralChange.insertRows(at: 5, count: 2).rebased(over: .deleteRows(at: 4, count: 3)) == [.insertRows(at: 4, count: 2)])
        #expect(StructuralChange.deleteRows(at: 5, count: 3).rebased(over: .deleteRows(at: 6, count: 5)) == [.deleteRows(at: 5, count: 1)])
        #expect(StructuralChange.deleteRows(at: 5, count: 3).rebased(over: .deleteRows(at: 4, count: 6)) == [])
        #expect(StructuralChange.deleteRows(at: 5, count: 3).rebased(over: .insertRows(at: 6, count: 2))
            == [.deleteRows(at: 8, count: 2), .deleteRows(at: 5, count: 1)])
        #expect(StructuralChange.deleteColumns(at: 1, count: 1).rebased(over: .insertRows(at: 0, count: 4)) == [.deleteColumns(at: 1, count: 1)])
        #expect(StructuralChange.insertRows(at: 3, count: 2).unmap(Self.address("A4")) == nil)
        #expect(StructuralChange.insertRows(at: 3, count: 2).unmap(Self.address("A7")) == Self.address("A5"))
        #expect(StructuralChange.deleteRows(at: 3, count: 2).unmap(Self.address("A4")) == Self.address("A6"))
    }

    @Test func layoutFollowsColumnsDeletedAtTheSameTime() {
        let base = Self.sample().withoutComments
        let id = base.sheets[0].id
        var edited = base.sheets[0]
        edited.columnWidths[4] = 99
        edited.merges = [Self.range("D2:F2")]
        edited.conditionalFormats[0].ranges = [Self.range("D2:D9")]
        let mine = WorkbookOp.layout(sheet: id, patch: SheetLayoutPatch.diff(from: base.sheets[0], to: edited))
        let theirs = WorkbookOp.structure(sheet: id, change: .deleteColumns(at: 1, count: 1))
        let (moved, _) = [mine].rebased(over: [theirs], context: base)
        var result = base.applying([theirs])
        result.apply(moved)
        #expect(result.sheets[0].columnWidths[3] == 99)
        #expect(result.sheets[0].merges == [Self.range("C2:E2")])
        #expect(result.sheets[0].conditionalFormats.first?.ranges == [Self.range("C2:C9")])
    }

    // MARK: Many Macs

    /// A Mac in the simulation: its workbook, kept as the app keeps it, and its client.
    final class Mac {
        let name: String
        var workbook: Workbook
        let client: SyncClient

        init(name: String, workbook: Workbook) {
            self.name = name
            self.workbook = workbook
            client = SyncClient(revision: 0, workbook: workbook, author: name, authorName: name)
        }

        func apply(_ effects: [SyncEffect]) {
            for effect in effects {
                switch effect {
                case .apply(let change): workbook.apply(change.ops)
                case .replace(let replacement, _): workbook = replacement
                }
            }
        }
    }

    /// A stand-in for the log in iCloud: a revision can be claimed once.
    final class Log {
        var changes: [LoggedChange] = []

        func claim(_ change: LoggedChange) -> LoggedChange? {
            if change.revision == changes.count + 1 {
                changes.append(change)
                return nil
            }
            return changes[change.revision - 1]
        }
    }

    /// Repeatable pseudo-random numbers.
    struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A random edit to `workbook`, as ops.
    static func randomEdit(_ workbook: Workbook, _ random: inout Random) -> [WorkbookOp] {
        let sheet = workbook.sheets[Int.random(in: 0..<workbook.sheets.count, using: &random)]
        let row = Int.random(in: 0..<12, using: &random), column = Int.random(in: 0..<6, using: &random)
        let address = CellAddress(row: row, column: column)
        switch Int.random(in: 0..<100, using: &random) {
        case 0..<35:
            var cells: [CellAddress: Cell] = [address: Cell(value: .number(Double(Int.random(in: 0..<1000, using: &random))))]
            if Bool.random(using: &random) {
                let other = CellAddress(row: Int.random(in: 0..<12, using: &random), column: Int.random(in: 0..<6, using: &random))
                cells[other] = Cell(formula: "=\(CellAddress(row: row, column: column).a1)*2+SUM(A1:B\(row + 3))")
            }
            return [.cells(sheet: sheet.id, cells: cells)]
        case 35..<42:
            let target = workbook.sheets.randomElement(using: &random)!
            return [.cells(sheet: sheet.id, cells: [address: Cell(formula: "='\(target.name)'!C\(row + 1)+1")])]
        case 42..<48:
            return [.cells(sheet: sheet.id, cells: [address: Cell()])]
        case 48..<56:
            var edited = sheet
            edited.columnWidths[column] = Double(Int.random(in: 40..<200, using: &random))
            if Bool.random(using: &random) { edited.rowHeights[row] = 30 }
            return [.layout(sheet: sheet.id, patch: SheetLayoutPatch.diff(from: sheet, to: edited))]
        case 56..<60:
            var edited = sheet
            edited.merges = [CellRange(rows: row...row + 1, columns: column...column + 1)]
            edited.conditionalFormats = [ConditionalFormatRule(ranges: [CellRange(rows: row...row + 3, columns: column...column)],
                                                               style: .condition(CellCondition(.greaterThan, ["=A1"]),
                                                                                 ConditionalFormat(bold: true)))]
            return [.layout(sheet: sheet.id, patch: SheetLayoutPatch.diff(from: sheet, to: edited))]
        case 60..<68:
            return [.structure(sheet: sheet.id, change: .insertRows(at: row, count: Int.random(in: 1...3, using: &random)))]
        case 68..<74:
            guard sheet.rowCount > 20 else { return [] }
            return [.structure(sheet: sheet.id, change: .deleteRows(at: row, count: Int.random(in: 1...3, using: &random)))]
        case 74..<79:
            return [.structure(sheet: sheet.id, change: .insertColumns(at: column, count: 1))]
        case 79..<83:
            guard sheet.columnCount > 8 else { return [] }
            return [.structure(sheet: sheet.id, change: .deleteColumns(at: column, count: Int.random(in: 1...2, using: &random)))]
        case 83..<86:
            let shift = CellRange(rows: row...row + 1, columns: column...column + 1)
            return [.structure(sheet: sheet.id, change: Bool.random(using: &random) ? .insertCells(shift, shiftDown: true) : .deleteCells(shift, shiftUp: false))]
        case 86..<89:
            var new = Sheet(name: "S\(Int.random(in: 0..<5, using: &random))")
            new[0, 0] = Cell(formula: "=Budget!B2")
            return [.insertSheet(sheet: new, at: Int.random(in: 0...workbook.sheets.count, using: &random))]
        case 89..<92:
            guard workbook.sheets.count > 1 else { return [] }
            return [.removeSheet(sheet: sheet.id)]
        case 92..<96:
            return [.renameSheet(sheet: sheet.id, name: ["Budget", "Plan", "Lists", "Data"].randomElement(using: &random)!)]
        case 96..<98:
            return [.moveSheet(sheet: sheet.id, to: Int.random(in: 0..<workbook.sheets.count, using: &random))]
        default:
            return [.namedRanges([NamedRange(name: "N\(row)", reference: "'\(sheet.name)'!$A$1:$A$\(row + 1)")])]
        }
    }

    /// Three Macs editing at random, through one log. With `slowClaims`, a change sent takes a while to be answered,
    /// as over the network: meanwhile its Mac edits, and hears of others' changes, and its change may be rewritten.
    @Test(arguments: Array(1...40), [false, true])
    func manyMacsEndTheSame(seed: Int, slowClaims: Bool) throws {
        var random = Random(state: UInt64(seed) &* 7919 &+ (slowClaims ? 104_729 : 0))
        let start = Self.sample().withoutComments
        let log = Log()
        let macs = (0..<3).map { Mac(name: "Mac \($0)", workbook: start) }
        var inFlight: [String: LoggedChange] = [:]
        func answer(_ mac: Mac, _ sent: LoggedChange) {
            if let existing = log.claim(sent) {
                mac.apply(mac.client.sendTaken(sent.id, by: existing))
            } else {
                mac.client.sent(sent.id)
            }
        }
        func send(_ mac: Mac) {
            if let sent = inFlight.removeValue(forKey: mac.name) {
                answer(mac, sent)
                return
            }
            guard let next = mac.client.nextToSend() else { return }
            if slowClaims { inFlight[mac.name] = next } else { answer(mac, next) }
        }
        func fetch(_ mac: Mac) {
            mac.apply(mac.client.receive(log.changes.filter { $0.revision > mac.client.revision }))
        }
        for step in 0..<400 {
            let mac = macs[Int.random(in: 0..<macs.count, using: &random)]
            switch Int.random(in: 0..<10, using: &random) {
            case 0..<5:
                let ops = Self.randomEdit(mac.workbook, &random)
                guard !ops.isEmpty else { continue }
                mac.workbook.apply(ops)
                mac.client.local(SharedChange(ops))
            case 5..<8:
                send(mac)
            default:
                fetch(mac)
            }
            // The workbook here is always the log's with this Mac's waiting changes on top.
            if let difference = Self.difference(mac.workbook, mac.client.workbookHere) {
                Issue.record("seed \(seed) step \(step) \(mac.name): \(difference)")
                return
            }
        }
        // Everyone sends what's left and catches up.
        for _ in 0..<100 {
            for mac in macs {
                send(mac)
                fetch(mac)
            }
            if macs.allSatisfy({ !$0.client.hasPending }) && inFlight.isEmpty { break }
        }
        for mac in macs { fetch(mac) }
        let logged = start.applying(log.changes.flatMap(\.change.ops))
        for mac in macs {
            #expect(!mac.client.hasPending)
            if let difference = Self.difference(mac.workbook, logged) {
                Issue.record("seed \(seed) \(mac.name) differs from the log: \(difference)")
            }
        }
        #expect(log.changes.count > 10)
    }

    @Test func aChangeThatDidNotComeIsMissedUntilItDoes() {
        let start = Self.sample().withoutComments
        let id = start.sheets[0].id
        let client = SyncClient(revision: 0, workbook: start, author: "ben", authorName: "Ben")
        var workbook = start
        func change(_ revision: Int, _ a1: String) -> LoggedChange {
            LoggedChange(revision: revision, author: "ana", authorName: "Ana",
                         change: SharedChange([.cells(sheet: id, cells: [Self.address(a1): Cell(value: .number(Double(revision)))])]))
        }
        func apply(_ effects: [SyncEffect]) {
            for effect in effects {
                switch effect {
                case .apply(let change): workbook.apply(change.ops)
                case .replace(let replacement, _): workbook = replacement
                }
            }
        }
        // The second change doesn't come with the others: nothing after it can be applied, and it's the one asked for.
        apply(client.receive([change(1, "Z1"), change(3, "Z3")]))
        #expect(workbook.sheets[0][Self.address("Z1")].value == .number(1) && workbook.sheets[0][Self.address("Z3")].value == .empty)
        #expect(client.isMissingChanges && client.missingRevisions == 2...2)
        apply(client.receive([change(2, "Z2")]))
        #expect(workbook.sheets[0][Self.address("Z3")].value == .number(3))
        #expect(!client.isMissingChanges && client.missingRevisions == nil)
    }

    @Test func startingOverDropsWhatWasWaitingToGo() {
        let start = Self.sample().withoutComments
        let id = start.sheets[0].id
        let client = SyncClient(revision: 0, workbook: start, author: "ana", authorName: "Ana")
        client.local(SharedChange([.cells(sheet: id, cells: [Self.address("A1"): Cell(value: .number(1))])]))
        client.local(SharedChange([.cells(sheet: id, cells: [Self.address("A2"): Cell(value: .number(2))])]))
        #expect(client.hasPending)
        client.discardPending()
        #expect(!client.hasPending && client.nextToSend() == nil)
    }

    @Test func commentsFollowTheirCells() {
        let start = Self.sample().withoutComments
        let id = start.sheets[0].id
        let client = SyncClient(revision: 0, workbook: start, author: "a", authorName: "A")
        let anchor = CommentAnchor(revision: 0, sheet: id, address: Self.address("B4"))
        let theirs = LoggedChange(revision: 1, author: "b", authorName: "B",
                                  change: SharedChange([.structure(sheet: id, change: .insertRows(at: 0, count: 3))]))
        _ = client.receive([theirs])
        #expect(client.place(of: anchor) == Self.address("B7"))
        client.local(SharedChange([.structure(sheet: id, change: .deleteRows(at: 0, count: 1))]))
        #expect(client.place(of: anchor) == Self.address("B6"))
        #expect(client.logPlace(of: Self.address("B6"), inSheet: id) == Self.address("B7"))
        let gone = LoggedChange(revision: 2, author: "b", authorName: "B",
                                change: SharedChange([.structure(sheet: id, change: .deleteRows(at: 5, count: 4))]))
        _ = client.receive([gone])
        #expect(client.place(of: anchor) == nil)
    }

    @Test func noticesSumUpWhatChanged() {
        let start = Self.sample()
        let id = start.sheets[0].id
        var tally = ChangeTally()
        tally.record([.cells(sheet: id, cells: [Self.address("C1"): Cell(value: .number(1)), Self.address("C2"): Cell(value: .number(2))])], before: start)
        tally.record([.structure(sheet: id, change: .insertRows(at: 3, count: 1))], before: start)
        tally.recordComment("Looks good to me")
        let notice = tally.notice(author: "Ana Lopez", documentTitle: "Plan")
        #expect(notice?.title == "Ana Lopez edited “Plan”")
        #expect(notice?.body == "Edited 2 cells on Budget, inserted a row and added a comment.")
        var comments = ChangeTally()
        comments.recordReply("Thanks!")
        #expect(comments.notice(author: "Ben", documentTitle: "Plan")?.body == "“Thanks!”")
        var format = ChangeTally()
        var bold = start.sheets[0][1, 1]
        bold.format.bold = true
        format.record([.cells(sheet: id, cells: [Self.address("B2"): bold])], before: start)
        #expect(format.notice(author: "Ben", documentTitle: "Plan")?.body == "Changed the formatting.")
    }

    @Test func mergedCommentsKeepBothSides() {
        let first = Comment(author: "Ana", text: "Is this right?")
        let base = CommentThread(comments: [first])
        var mine = base
        mine.comments.append(Comment(author: "Me", date: Date().addingTimeInterval(5), text: "Yes"))
        mine.isResolved = true
        var theirs = base
        theirs.comments.append(Comment(author: "Ben", date: Date().addingTimeInterval(2), text: "Not sure"))
        let merged = SharedComment.merge(local: mine, base: base, server: theirs)
        #expect(merged.comments.map(\.text) == ["Is this right?", "Not sure", "Yes"])
        #expect(merged.isResolved)
    }
}
