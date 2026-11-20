#if DEBUG
import AppKit
import PuggleSheetsKit

/// `-PSSelfTest YES`: drives a real spreadsheet window and prints SELFTEST PASS/FAIL lines.
/// Each step runs in its own turn of the run loop, so each is its own undo step, as for a person.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "PSSelfTest") else { return }
        if UserDefaults.standard.string(forKey: "PSSelfTestSuite") == "collaboration" {
            CollaborationSelfTest.run()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { run() }
    }

    private static var failures = 0
    private static var steps: [() -> Void] = []

    static func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("SELFTEST PASS: \(name)")
        } else {
            failures += 1
            print("SELFTEST FAIL: \(name) — \(detail())")
        }
    }

    private static func step(_ body: @escaping () -> Void) { steps.append(body) }

    private static func runSteps(from index: Int = 0) {
        guard index < steps.count else {
            print(failures == 0 ? "SELFTEST DONE: all passed" : "SELFTEST DONE: \(failures) failed")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        steps[index]()
        // Steps run from timers, not events, and AppKit closes the undo group an edit opened only after
        // handling an event. An empty application event ends the step as a key press or click would.
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { runSteps(from: index + 1) }
    }

    private static func address(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    /// Types into whatever has keyboard focus with real key events, as a person would.
    private static func type(_ text: String, into window: NSWindow?) {
        for character in text {
            let string = String(character)
            let code: UInt16 = character == "\r" ? 36 : (character == "\t" ? 48 : 0)
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window?.windowNumber ?? 0, context: nil,
                                               characters: string, charactersIgnoringModifiers: string,
                                               isARepeat: false, keyCode: code) else { continue }
            window?.firstResponder?.keyDown(with: event)
        }
    }

    private static func run() {
        // A fresh spreadsheet of its own, so documents macOS restored at launch are left alone.
        let existing = Set(NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }.map(ObjectIdentifier.init))
        NSDocumentController.shared.newDocument(nil)
        guard let window = NSApp.windows.compactMap({ $0.windowController as? DocumentWindowController })
            .first(where: { !existing.contains(ObjectIdentifier($0)) }) else {
            print("SELFTEST FAIL: no spreadsheet window")
            exit(1)
        }
        let controller = window.controller
        let grid = window.grid
        window.window?.makeKeyAndOrderFront(nil)
        window.window?.makeFirstResponder(grid)
        func value(_ a1: String) -> CellValue { controller.sheet[address(a1)].value }
        func cell(_ a1: String) -> Cell { controller.sheet[address(a1)] }
        func select(_ a1: String) { controller.selection = GridSelection(range: CellRange(a1: a1)!) }
        func shown(_ a1: String) -> String { CellDisplay.text(for: value(a1), pattern: cell(a1).format.numberFormat).text }

        // Typing with real keys: Return commits and moves down, Tab moves right.
        step {
            select("A1")
            type("5\r7\r", into: window.window)
        }
        step {
            check(value("A1") == .number(5) && value("A2") == .number(7), "typing numbers into cells", "\(value("A1")) \(value("A2"))")
            check(controller.selection.active == address("A3"), "Return moves down", controller.selection.active.a1)
            type("=A1+A2\t", into: window.window)
        }
        step {
            check(value("A3") == .number(12), "a formula computes", "\(value("A3")) \(cell("A3").formula ?? "")")
            check(controller.selection.active == address("B3"), "Tab moves right", controller.selection.active.a1)
            type("12%\r", into: window.window)
        }
        step {
            check(value("B3") == .number(0.12) && cell("B3").format.numberFormat?.contains("%") == true,
                  "typing a percentage stores a number with a percent format", "\(value("B3")) \(cell("B3").format.numberFormat ?? "nil")")
            check(controller.selection.active == address("A4"), "Return after Tab goes back to the first column", controller.selection.active.a1)
            select("C1")
            type("=SUM(A1:A2", into: window.window)
        }
        step {
            check(window.formulaBar.field.stringValue == "=SUM(A1:A2", "the formula bar mirrors typing in the cell", window.formulaBar.field.stringValue)
            type("\r", into: window.window)
        }
        step {
            check(cell("C1").formula == "=SUM(A1:A2)" && value("C1") == .number(12), "missing parentheses are closed",
                  "\(cell("C1").formula ?? "nil") \(value("C1"))")
            // Pointing: while a formula waits for an operand, clicking cells inserts their reference.
            select("C2")
            grid.beginEditing(replacingWith: "=SUM(", entry: .replace)
            guard let editor = grid.editor else { return check(false, "the cell editor opens") }
            check(grid.canPoint(in: editor), "a formula waiting for an operand can point at cells")
            grid.insertPointedReference(CellRange(a1: "A1:A2")!, in: editor)
            grid.insertPointedReference(CellRange(a1: "A1:A3")!, in: editor)
            check(editor.string == "=SUM(A1:A3", "dragging extends the pointed reference", editor.string)
            check(grid.formulaReferenceRanges.map(\.0) == [CellRange(a1: "A1:A3")!], "references are outlined while editing",
                  "\(grid.formulaReferenceRanges.map(\.0))")
            type("\r", into: window.window)
        }
        step {
            check(cell("C2").formula == "=SUM(A1:A3)", "a pointed formula is entered", cell("C2").formula ?? "nil")
        }

        // Recalculation and undo.
        step { controller.commitInput("10", at: address("A1")) }
        step {
            check(value("A3") == .number(17), "dependent formulas recalculate", "\(value("A3"))")
            controller.undoManager?.undo()
        }
        step {
            check(value("A1") == .number(5) && value("A3") == .number(12), "undo restores the value and the result", "\(value("A1")) \(value("A3"))")
            controller.undoManager?.redo()
        }
        step { check(value("A1") == .number(10) && value("A3") == .number(17), "redo", "\(value("A1"))") }

        // Formatting.
        step {
            select("A1:A3")
            controller.toggleBold()
            check(cell("A2").format.bold && cell("A3").format.bold, "bold applies to the selection")
        }
        step {
            controller.setNumberFormat(NumberFormatPresets.currency.pattern)
            check(shown("A1") == "$10.00", "currency format", shown("A1"))
        }
        step {
            controller.applyBorders(.outer, line: BorderLine())
            check(cell("A1").format.borders.top != nil && cell("A3").format.borders.bottom != nil && cell("A2").format.borders.top == nil,
                  "outer borders go around the selection")
        }
        step {
            controller.clearFormatting()
            check(cell("A1").format.isDefault, "clear formatting")
        }

        // Rows and columns: formulas follow.
        step {
            select("A2")
            controller.insertRows(above: true)
            check(value("A3") == .number(7) && cell("A4").formula == "=A1+A3", "inserting a row moves cells and formulas follow",
                  "\(value("A3")) \(cell("A4").formula ?? "nil")")
        }
        step {
            select("A2")
            controller.deleteSelectedRows()
            check(cell("A3").formula == "=A1+A2" && value("A3") == .number(17), "deleting a row", "\(cell("A3").formula ?? "nil")")
        }
        step {
            select("A1")
            controller.insertColumns(left: true)
            check(cell("B3").formula == "=B1+B2", "inserting a column", "\(cell("B3").formula ?? "nil")")
        }
        step {
            controller.undoManager?.undo()
            check(cell("A3").formula == "=A1+A2", "undo insert column", "\(cell("A3").formula ?? "nil")")
        }

        // Copy and paste shifts references; cut and paste moves them.
        step {
            select("A3")
            controller.copySelection()
            select("C3")
            controller.paste(.normal)
            check(cell("C3").formula == "=C1+C2", "pasting a formula shifts its references", "\(cell("C3").formula ?? "nil")")
        }
        step {
            select("A1")
            controller.copySelection(cut: true)
            select("D1")
            controller.paste(.normal)
            check(value("D1") == .number(10) && value("A1") == .empty && cell("A3").formula == "=D1+A2",
                  "cut and paste moves the cell and its references", "\(value("D1")) \(cell("A3").formula ?? "nil")")
        }
        step {
            controller.undoManager?.undo()
            check(value("A1") == .number(10) && cell("A3").formula == "=A1+A2", "undo cut and paste")
        }
        step {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("1\t2\n3\t4", forType: .string)
            select("F1")
            controller.paste(.normal)
            check(value("G2") == .number(4), "pasting tab-separated text from other apps", "\(value("G2"))")
        }

        // Fill.
        step {
            controller.commitInput("1", at: address("H1"))
            controller.commitInput("2", at: address("H2"))
            controller.autoFill(from: CellRange(a1: "H1:H2")!, to: CellRange(a1: "H1:H5")!)
            check(value("H5") == .number(5), "autofill continues a series", "\(value("H5"))")
            controller.commitInput("Item 1", at: address("I1"))
            controller.autoFill(from: CellRange(a1: "I1")!, to: CellRange(a1: "I1:I3")!)
            check(value("I3") == .text("Item 3"), "autofill numbered text", "\(value("I3"))")
        }
        step {
            controller.commitInput("=H1*2", at: address("J1"))
            select("J1:J3")
            controller.fillDown()
            check(cell("J3").formula == "=H3*2" && value("J3") == .number(6), "fill down shifts formulas", "\(cell("J3").formula ?? "nil")")
        }

        // Merge, sort, freeze, hide.
        step {
            select("K1:L2")
            controller.merge(.all)
            check(controller.sheet.merges.contains(CellRange(a1: "K1:L2")!), "merge cells")
        }
        step {
            controller.merge(.unmerge)
            check(!controller.sheet.merges.contains { $0.intersects(CellRange(a1: "K1:L2")!) }, "unmerge")
        }
        step {
            controller.commitInput("pear", at: address("M1"))
            controller.commitInput("apple", at: address("M2"))
            controller.commitInput("fig", at: address("M3"))
            select("M1:M3")
            controller.sort(controller.selection.current, by: 12, ascending: true)
            check(value("M1") == .text("apple") && value("M3") == .text("pear"), "sort a range", "\(value("M1")) \(value("M3"))")
        }
        step {
            window.find.show()
            window.find.state.query = "APP"
            window.find.search()
            check(window.find.matches == [address("M1")] && controller.selection.active == address("M1") && window.find.state.countText == "1 of 1",
                  "find matches the shown text, ignoring case", "\(window.find.matches) \(window.find.state.countText)")
            window.find.hide()
        }
        step {
            controller.freeze(rows: 1, columns: 1)
            check(controller.sheet.frozenRows == 1 && controller.sheet.frozenColumns == 1, "freeze rows and columns")
            controller.hideColumns([3])
            check(controller.sheet.hiddenColumns.contains(3), "hide a column")
            select("C1:E1")
            controller.unhideColumns()
            check(controller.sheet.hiddenColumns.isEmpty, "unhide columns")
        }

        // Sheets.
        var firstSheet = controller.activeSheetID
        step {
            firstSheet = controller.activeSheetID
            controller.addSheet()
            check(controller.workbook.sheets.count == 2 && controller.sheet.name == "Sheet2", "add a sheet", controller.sheet.name)
            controller.commitInput("=Sheet1!A1*3", at: address("A1"))
            check(value("A1") == .number(30), "cross-sheet reference", "\(value("A1"))")
        }
        step {
            controller.renameSheet(id: firstSheet, to: "Data")
            check(cell("A1").formula == "=Data!A1*3" && value("A1") == .number(30), "renaming a sheet updates formulas", cell("A1").formula ?? "nil")
        }
        step {
            controller.duplicateSheet(id: controller.activeSheetID)
            check(controller.workbook.sheets.count == 3 && controller.sheet.name == "Copy of Sheet2", "duplicate a sheet", controller.sheet.name)
        }
        step {
            controller.deleteSheet(id: controller.activeSheetID)
            check(controller.workbook.sheets.count == 2, "delete a sheet")
            controller.showSheet(id: firstSheet)
            check(controller.activeSheetID == firstSheet && grid.sheet.id == firstSheet, "switch sheets")
        }

        // Rows grow to fit wrapped text.
        step {
            controller.commitInput("A long note that needs several lines once it wraps inside a narrow column.", at: address("A10"))
            select("A10")
            controller.setWrap(.wrap)
            check(controller.sheet.rowHeight(9) > 40, "a row grows to fit wrapped text", "\(controller.sheet.rowHeight(9))")
        }
        step {
            controller.setWrap(.overflow)
            check(controller.sheet.rowHeight(9) == controller.sheet.defaultRowHeight, "and shrinks back", "\(controller.sheet.rowHeight(9))")
        }

        // Files.
        step {
            do {
                let data = try SpreadsheetIO.write(controller.workbook, activeSheet: 0, format: .xlsx)
                let file = try SpreadsheetIO.read(data, format: .xlsx)
                let sheet = file.workbook.sheets[0]
                check(file.workbook.sheets.map(\.name) == controller.workbook.sheets.map(\.name), "xlsx keeps the sheets")
                check(sheet[address("A3")].formula == "=A1+A2" && sheet[address("A3")].value == .number(17), "xlsx keeps formulas and results",
                      "\(sheet[address("A3")].formula ?? "nil") \(sheet[address("A3")].value)")
                check(sheet.frozenRows == 1 && sheet[address("B3")].format.numberFormat == cell("B3").format.numberFormat,
                      "xlsx keeps frozen rows and number formats")
                let csv = String(decoding: try SpreadsheetIO.write(controller.workbook, activeSheet: 0, format: .csv), as: UTF8.self)
                check(csv.hasPrefix("10,"), "csv export", String(csv.prefix(80)))
            } catch {
                check(false, "files", "\(error)")
            }
        }

        // Zoom.
        step {
            window.setZoom(1.5)
            check(grid.zoom == 1.5 && window.state.zoomLabel == "150%", "zoom")
            window.setZoom(1)
        }

        phaseTwo(window)
        phaseThree(window)
        phaseFour(window)
        phaseFive(window)
        runSteps()
    }

    /// Tables, slicers and the new formulas: QUERY, SPARKLINE, LAMBDA and friends, SORTN, GETPIVOTDATA.
    private static func phaseFive(_ window: DocumentWindowController) {
        let controller = window.controller
        func value(_ a1: String) -> CellValue { controller.sheet[address(a1)].value }
        func shownValue(_ a1: String) -> CellValue { controller.sheet.value(at: address(a1)) }
        func select(_ a1: String) { controller.selection = GridSelection(range: CellRange(a1: a1)!) }
        var tableID: UUID?

        step {
            controller.addSheet()
            let rows = [["Region", "Amount", "Shipped"], ["East", "100", "TRUE"], ["West", "250", "FALSE"], ["East", "175", "TRUE"], ["North", "90", "FALSE"]]
            for (row, items) in rows.enumerated() {
                for (column, text) in items.enumerated() { controller.commitInput(text, at: CellAddress(row: row, column: column)) }
            }
            select("B2")
            tableID = controller.convertToTable()
            let table = controller.sheet.tables.first
            check(table?.name == "Table1" && table?.range == CellRange(a1: "A1:C5") && table?.columnTypes[2] == .checkbox,
                  "convert to table", "\(String(describing: table))")
            controller.commitInput("West", at: address("A6"))
            check(controller.sheet.tables.first?.range == CellRange(a1: "A1:C6"), "typing below a table adds a row to it")
            controller.commitInput("60", at: address("B6"))
        }
        step {
            guard let id = tableID else { return check(false, "table", "missing") }
            controller.setTableColumnType(.currency, column: 1, tableID: id)
            check(controller.sheet[address("B3")].format.numberFormat == "\"$\"#,##0.00", "a currency column formats its cells")
            controller.commitInput("=SUM(Table1[Amount])", at: address("E1"))
            check(value("E1") == .number(675), "a formula refers to a table column", "\(value("E1"))")
            check(controller.renameTable(id: id, to: "Sales") == nil && controller.sheet[address("E1")].formula == "=SUM(Sales[Amount])"
                  && value("E1") == .number(675), "renaming a table updates formulas", controller.sheet[address("E1")].formula ?? "")
            controller.setTableCriterion(FilterCriterion(hiddenValues: ["East"]), column: 0, tableID: id)
            check(controller.sheet.filteredRows == [1, 3], "a table's filter hides rows", "\(controller.sheet.filteredRows.sorted())")
            controller.setTableCriterion(nil, column: 0, tableID: id)
            check(controller.sheet.filteredRows.isEmpty, "and shows them again")
        }
        // A slicer filters its range.
        step {
            select("A1")
            let slicerID = controller.addSlicer()
            controller.updateSlicer(id: slicerID) { $0.criterion = FilterCriterion(hiddenValues: ["West"]) }
            check(controller.sheet.filteredRows == [2, 5], "a slicer hides rows of its data", "\(controller.sheet.filteredRows.sorted())")
            controller.removeObject(id: slicerID)
            check(controller.sheet.filteredRows.isEmpty, "deleting a slicer shows its rows again")
        }
        // The new formulas.
        step {
            controller.commitInput("=QUERY(A1:B6, \"select A, sum(B) group by A order by A label sum(B) 'Total'\", 1)", at: address("G1"))
            check(shownValue("G1") == .text("Region") && shownValue("H1") == .text("Total") && shownValue("G2") == .text("East")
                  && shownValue("H2") == .number(275), "QUERY groups and sums", "\(shownValue("G1")) \(shownValue("H1")) \(shownValue("H2"))")
            controller.commitInput("=SPARKLINE(B2:B6)", at: address("E3"))
            let spark = controller.sheet.sparklines[address("E3")]
            check(spark?.kind == .line && spark?.values.count == 5, "SPARKLINE draws a chart in its cell", "\(String(describing: spark))")
            controller.commitInput("=MAP(B2:B3, LAMBDA(x, x * 2))", at: address("J1"))
            controller.commitInput("=LET(a, 2, b, 3, a * b)", at: address("K1"))
            controller.commitInput("=REDUCE(0, B2:B6, LAMBDA(total, x, total + x))", at: address("L1"))
            check(shownValue("J1") == .number(200) && shownValue("J2") == .number(500) && value("K1") == .number(6) && value("L1") == .number(675),
                  "MAP, LET, LAMBDA and REDUCE", "\(shownValue("J1")) \(value("K1")) \(value("L1"))")
            controller.commitInput("=SORTN(A2:B6, 2, 0, 2, FALSE)", at: address("M1"))
            check(shownValue("M1") == .text("West") && shownValue("N1") == .number(250) && shownValue("M2") == .text("East"),
                  "SORTN keeps the top rows", "\(shownValue("M1")) \(shownValue("N1"))")
        }
        // Files keep tables and slicers.
        step {
            var sheet = Sheet(name: "Kept")
            for (row, items) in [["Region", "Amount"], ["East", "1"], ["West", "2"]].enumerated() {
                for (column, text) in items.enumerated() { sheet[row, column] = Cell(value: InputParser.parse(text, currentFormat: nil).value) }
            }
            sheet.tables = [SheetTable(name: "Kept1", range: CellRange(a1: "A1:B3")!, columnTypes: [1: .currency])]
            sheet.objects = [SheetObject(anchor: ObjectAnchor(cell: address("D1"), width: 200, height: 60),
                                         content: .slicer(SlicerSpec(range: "Kept1", column: 0, criterion: FilterCriterion(hiddenValues: ["West"]))))]
            sheet[0, 3] = Cell(formula: "=SUM(Kept1[Amount])")
            for format in [SpreadsheetFileFormat.xlsx, .ods] {
                do {
                    let data = try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: format)
                    let read = try SpreadsheetIO.read(data, format: format).workbook.sheets[0]
                    check(read.tables.first?.name == "Kept1" && read.tables.first?.columnTypes[1] == .currency, "\(format) keeps tables",
                          "\(String(describing: read.tables.first))")
                    check(read.objects.first?.slicer?.criterion.hiddenValues == ["West"], "\(format) keeps slicers")
                    check(read[0, 3].formula == "=SUM(Kept1[Amount])", "\(format) keeps table references", read[0, 3].formula ?? "nil")
                } catch {
                    check(false, "\(format) files", "\(error)")
                }
            }
        }
    }

    /// Notes, comments, protected ranges, groups, rotation, transposed paste, randomizing and importing.
    private static func phaseFour(_ window: DocumentWindowController) {
        let controller = window.controller
        let grid = window.grid
        func value(_ a1: String) -> CellValue { controller.sheet[address(a1)].value }
        func select(_ a1: String) { controller.selection = GridSelection(range: CellRange(a1: a1)!) }

        step {
            controller.addSheet()
            for (row, items) in [["Name", "Score"], ["Ana", "70"], ["Ben", "40"], ["Chen", "90"], ["Dee", "55"]].enumerated() {
                for (column, text) in items.enumerated() { controller.commitInput(text, at: CellAddress(row: row, column: column)) }
            }
            controller.setNote("Checked by hand", at: address("B2"))
            check(controller.sheet[address("B2")].note == "Checked by hand" && value("B2") == .number(70), "add a note")
            controller.commitInput("75", at: address("B2"))
            check(controller.sheet[address("B2")].note == "Checked by hand", "a note stays when the value changes")
            select("B2")
            controller.clearNotes()
            check(controller.sheet[address("B2")].note == nil, "clear notes")
        }
        step {
            controller.addComment("Is this final?", at: address("A3"))
            controller.addComment("Yes.", at: address("A3"))
            let thread = controller.sheet[address("A3")].comment
            check(thread?.comments.map(\.text) == ["Is this final?", "Yes."] && thread?.comments.first?.author == controller.commentAuthor,
                  "comment and reply", "\(String(describing: thread?.comments.map(\.text)))")
            controller.editComment(thread!.comments[1].id, text: "Yes, final.", at: address("A3"))
            check(controller.sheet[address("A3")].comment?.comments[1].text == "Yes, final." &&
                  controller.sheet[address("A3")].comment?.comments[1].editedDate != nil, "edit a comment")
            controller.setCommentResolved(true, at: address("A3"))
            check(controller.sheet[address("A3")].comment?.isResolved == true && controller.commentThreads().contains { $0.address == address("A3") },
                  "resolve a comment thread")
            controller.deleteComment(thread!.comments[0].id, at: address("A3"))
            check(controller.sheet[address("A3")].comment == nil, "delete a comment thread")
        }
        // Protected ranges warn (and can be cancelled) or refuse.
        step {
            controller.setProtection(ProtectedRange(scope: .range(CellRange(a1: "B2:B5")!), description: "Scores"))
            var asked = 0
            let original = controller.onProtectedEdit
            controller.onProtectedEdit = { _ in asked += 1; return .cancel }
            controller.commitInput("1", at: address("B3"))
            check(asked == 1 && value("B3") == .number(40), "a protected range warns, and Cancel keeps the value", "\(value("B3"))")
            controller.onProtectedEdit = { _ in .proceed }
            controller.commitInput("41", at: address("B3"))
            check(value("B3") == .number(41), "and OK makes the change")
            controller.commitInput("x", at: address("A3"))
            check(value("A3") == .text("x"), "cells outside protected ranges edit freely")
            controller.setProtection(ProtectedRange(scope: .sheet(except: [CellRange(a1: "A1:A10")!]), warningOnly: false))
            var refused = false
            controller.onProtectedEdit = { protection in refused = !protection.warningOnly; return .cancel }
            controller.commitInput("99", at: address("C9"))
            check(refused && value("C9") == .empty, "a restricted sheet refuses edits")
            select("C1:C3")
            controller.insertCells(shiftDown: true)
            check(value("C2") == .empty && controller.sheet[address("C4")].hasContent == false, "and refuses shifting its cells")
            controller.commitInput("ok", at: address("A9"))
            check(value("A9") == .text("ok"), "except in its exception ranges")
            controller.onProtectedEdit = original
            for protection in controller.sheet.protections { controller.removeProtection(id: protection.id) }
            check(controller.sheet.protections.isEmpty, "remove protections")
        }
        // Row groups collapse and expand.
        step {
            select("A2:A4")
            controller.groupRows()
            check(controller.sheet.rowGroups == [OutlineGroup(range: 1...3)], "group rows", "\(controller.sheet.rowGroups)")
            controller.toggleGroup(controller.sheet.rowGroups[0], rows: true)
            check(grid.rows.isHidden(2) && controller.sheet.isRowHidden(2) && !controller.sheet.hiddenRows.contains(2), "collapse a group")
            check(grid.rowOutlineWidth > 0 && grid.headerWidth > grid.rowOutlineWidth, "the grid shows the outline band")
            controller.setAllGroupsCollapsed(false, rows: true)
            check(!grid.rows.isHidden(2), "expand all groups")
            select("A2:A4")
            controller.ungroupRows()
            check(controller.sheet.rowGroups.isEmpty && grid.rowOutlineWidth == 0, "ungroup rows")
        }
        // Rotation, formulas shown, transposed paste and randomizing.
        step {
            select("A1")
            controller.setTextRotation(.angle(90))
            check(controller.sheet[address("A1")].format.textRotation == .angle(90) && controller.sheet.rowHeight(0) > 30,
                  "rotated text makes its row taller", "\(controller.sheet.rowHeight(0))")
            controller.commitInput("=B2*2", at: address("D1"))
            grid.showsFormulas = true
            let shown = grid.displayCell(at: address("D1"), in: controller.sheet, rules: grid.ruleResults(for: CellRange(a1: "A1:D5")!))
            check(shown?.value == .text("=B2*2"), "show formulas", "\(String(describing: shown?.value))")
            grid.showsFormulas = false
            select("A1:B2")
            controller.copySelection()
            select("F1")
            controller.paste(.transposed)
            check(value("F1") == .text("Name") && value("G1") == .text("Ana") && value("F2") == .text("Score") && value("G2") == .number(75),
                  "paste transposed", "\(value("G1")) \(value("F2"))")
            let before = (1...4).map { value("A\($0 + 1)") }
            select("A2:B5")
            controller.randomizeRange()
            let after = (1...4).map { value("A\($0 + 1)") }
            check(Set(before.map { "\($0)" }) == Set(after.map { "\($0)" }), "randomize range keeps the rows")
        }
        // Importing a file into the spreadsheet.
        step {
            let csv = Data("City,Visits\nLisbon,3\nOslo,5\n".utf8)
            guard let file = try? SpreadsheetIO.read(csv, format: .csv) else { return check(false, "import", "unreadable") }
            let count = controller.workbook.sheets.count
            controller.importWorkbook(file.workbook, name: "cities", location: .insertSheets)
            check(controller.workbook.sheets.count == count + 1 && controller.sheet.name == "cities" && value("B3") == .number(5),
                  "import a CSV file as a new sheet", controller.sheet.name)
            controller.importWorkbook(file.workbook, name: "cities", location: .appendToSheet)
            check(value("A4") == .text("City") && value("B6") == .number(5), "append imported data", "\(value("A4"))")
        }
        // Files keep notes, comments, protections, rotation and groups.
        step {
            var sheet = Sheet(name: "Kept")
            sheet[0, 0] = Cell(value: .text("Total"), note: "A note")
            sheet[1, 0] = Cell(value: .number(4), comment: CommentThread(comments: [Comment(author: "Ana", text: "Why?"), Comment(author: "Ben", text: "Because.")]))
            var rotated = CellFormat()
            rotated.textRotation = .angle(45)
            sheet[2, 0] = Cell(value: .text("Tilted"), format: rotated)
            sheet.protections = [ProtectedRange(scope: .range(CellRange(a1: "A1:A3")!), description: "Keep", warningOnly: false)]
            sheet.rowGroups = [OutlineGroup(range: 4...6, isCollapsed: true)]
            for format in [SpreadsheetFileFormat.xlsx, .ods] {
                do {
                    let data = try SpreadsheetIO.write(Workbook(sheets: [sheet]), activeSheet: 0, format: format)
                    let read = try SpreadsheetIO.read(data, format: format).workbook.sheets[0]
                    check(read[0, 0].note == "A note" && read[1, 0].comment?.comments.map(\.text) == ["Why?", "Because."], "\(format) keeps notes and comments",
                          "\(String(describing: read[0, 0].note)) \(String(describing: read[1, 0].comment?.comments.map(\.text)))")
                    check(read.protections.count == 1 && read.protections.first?.warningOnly == false, "\(format) keeps protected ranges")
                    check(read[2, 0].format.textRotation == .angle(45) && read.rowGroups == sheet.rowGroups, "\(format) keeps rotation and groups",
                          "\(String(describing: read[2, 0].format.textRotation)) \(read.rowGroups)")
                } catch {
                    check(false, "\(format) files", "\(error)")
                }
            }
        }
    }

    /// Charts, images, links, pivot tables and filter views.
    private static func phaseThree(_ window: DocumentWindowController) {
        let controller = window.controller
        let grid = window.grid
        func value(_ a1: String) -> CellValue { controller.sheet[address(a1)].value }
        func shownValue(_ a1: String) -> CellValue { controller.sheet.value(at: address(a1)) }
        func select(_ a1: String) { controller.selection = GridSelection(range: CellRange(a1: a1)!) }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) {
            let location = grid.convert(point, to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.window?.windowNumber ?? 0, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: grid.mouseDown(with: event)
            case .leftMouseDragged: grid.mouseDragged(with: event)
            default: grid.mouseUp(with: event)
            }
        }
        var chartID: UUID?

        step {
            controller.addSheet()
            let rows = [["Month", "Sales", "Costs"], ["Jan", "120", "80"], ["Feb", "150", "90"], ["Mar", "90", "70"], ["Apr", "200", "120"]]
            for (r, row) in rows.enumerated() {
                for (c, text) in row.enumerated() { controller.commitInput(text, at: CellAddress(row: r, column: c)) }
            }
            select("A1:C5")
            chartID = controller.insertChart()
            let object = controller.selectedObject
            check(object?.chart?.ranges.isEmpty == false && object?.anchor.cell == address("E1"), "insert a chart beside the data",
                  "\(String(describing: object?.anchor.cell.a1))")
            let table = ChartBuilder.table(for: object?.chart ?? ChartSpec(ranges: []), sheetIndex: controller.activeSheetIndex, workbook: controller.workbook)
            check(table.labels == ["Jan", "Feb", "Mar", "Apr"] && table.series.map(\.name) == ["Sales", "Costs"], "the chart reads its data",
                  "\(table.labels) \(table.series.map(\.name))")
        }
        // Dragging the chart moves it; undo puts it back.
        step {
            guard let id = chartID, let object = controller.object(id: id) else { return check(false, "drag a chart", "no chart") }
            let rect = grid.objectRect(object.anchor)
            let start = CGPoint(x: rect.midX, y: rect.midY)
            mouse(.leftMouseDown, start)
            mouse(.leftMouseDragged, CGPoint(x: start.x + 100, y: start.y + 42))
            mouse(.leftMouseUp, CGPoint(x: start.x + 100, y: start.y + 42))
            let moved = controller.object(id: id)?.anchor
            check(moved?.cell == address("F3") && moved?.width == object.anchor.width, "drag a chart", "\(String(describing: moved))")
        }
        step {
            controller.undoManager?.undo()
            check(controller.object(id: chartID ?? UUID())?.anchor.cell == address("E1"), "undo moving a chart")
        }
        // Resizing by the bottom-right handle.
        step {
            guard let id = chartID, let object = controller.object(id: id) else { return }
            controller.selectedObjectID = id
            let rect = grid.objectRect(object.anchor)
            mouse(.leftMouseDown, CGPoint(x: rect.maxX, y: rect.maxY))
            mouse(.leftMouseDragged, CGPoint(x: rect.maxX - 100, y: rect.maxY - 71))
            mouse(.leftMouseUp, CGPoint(x: rect.maxX - 100, y: rect.maxY - 71))
            let resized = controller.object(id: id)?.anchor
            check(resized?.width == 500 && resized?.height == 300, "resize a chart", "\(String(describing: resized))")
        }
        // Copy and paste the chart, then delete the copy with the Delete key.
        step {
            guard let id = chartID else { return }
            controller.selectedObjectID = id
            window.copy(nil)
            select("A8")
            window.paste(nil)
            check(controller.sheet.objects.count == 2 && controller.selectedObject?.anchor.cell == address("A8"), "copy and paste a chart",
                  "\(controller.sheet.objects.count)")
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.window?.windowNumber ?? 0, context: nil,
                                               characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51) else { return }
            window.window?.makeFirstResponder(grid)
            grid.keyDown(with: event)
            check(controller.sheet.objects.count == 1 && controller.selectedObjectID == nil, "Delete removes the selected chart")
        }
        // Images over cells and in cells.
        step {
            guard let picture = SampleContent.samplePicture() else { return check(false, "images", "no picture") }
            select("H2")
            controller.insertImageOverCells(picture, at: address("H2"))
            check(controller.selectedObject?.image?.pixelWidth == picture.pixelWidth, "insert an image over cells")
            controller.insertImageInCell(picture, at: address("A10"))
            check(controller.sheet[address("A10")].image != nil && controller.sheet[address("A10")].hasContent, "insert an image in a cell")
            controller.commitInput("text", at: address("A10"))
            check(controller.sheet[address("A10")].image == nil && value("A10") == .text("text"), "typing replaces an image in a cell")
        }
        // Links.
        step {
            controller.setLink("https://example.com/sales", text: "Sales report", at: address("A12"))
            check(controller.sheet.link(at: address("A12")) == "https://example.com/sales" && value("A12") == .text("Sales report"), "insert a link")
            let budget = controller.workbook.sheets[0]
            controller.setLink(LinkTarget.sheet(budget.id, CellRange(a1: "B2:C3")).link, text: "Budget", at: address("A13"))
            select("A13")
            controller.followInternalLink(controller.sheet.link(at: address("A13")) ?? "")
            check(controller.sheet.id == budget.id && controller.selection.current == CellRange(a1: "B2:C3"), "follow a link to a range",
                  controller.sheet.name)
            controller.showSheet(id: controller.workbook.sheets[controller.workbook.sheets.count - 1].id)
            controller.commitInput("=HYPERLINK(\"https://example.com/x\", \"Go\")", at: address("A14"))
            check(value("A14") == .text("Go") && controller.sheet.link(at: address("A14")) == "https://example.com/x", "HYPERLINK makes a link",
                  "\(value("A14")) \(controller.sheet.link(at: address("A14")) ?? "none")")
        }
        // Pivot tables.
        var pivotID: UUID?
        step {
            let source = controller.sheet.name + "!A1:C5"
            pivotID = controller.createPivotTable(source: source, location: nil)
            controller.updatePivotTable(id: pivotID ?? UUID()) { pivot in
                pivot.rows = [PivotGroup(sourceColumn: 0)]
                pivot.values = [PivotValue(sourceColumn: 1)]
            }
            check(controller.sheet.name.hasPrefix("Pivot Table") && controller.sheet.pivotTables.count == 1, "create a pivot table on a new sheet",
                  controller.sheet.name)
            check(shownValue("A1") == .text("Month") && shownValue("B1") == .text("SUM of Sales") && shownValue("A6") == .text("Grand Total")
                  && shownValue("B6") == .number(560), "the pivot table summarizes its source",
                  "\(shownValue("A1")) \(shownValue("B1")) \(shownValue("A6")) \(shownValue("B6"))")
        }
        step {
            guard let (sheetIndex, pivot) = controller.pivotTable(id: pivotID ?? UUID()) else { return check(false, "pivot", "missing") }
            let sourceSheet = controller.workbook.resolve(pivot.source, onSheet: sheetIndex)!.sheet
            let sourceID = controller.workbook.sheets[sourceSheet].id
            controller.showSheet(id: sourceID)
            controller.commitInput("1000", at: address("B2"))
            controller.showSheet(id: controller.workbook.sheets[sheetIndex].id)
            check(shownValue("B6") == .number(1440), "a pivot table follows its source data", "\(shownValue("B6"))")
            select("A1")
            controller.clearContents()
            check(controller.sheet.pivotTables.isEmpty && shownValue("B6") == .empty, "clearing its corner deletes a pivot table")
            controller.showSheet(id: sourceID)
        }
        // Filter views.
        step {
            select("A1:C5")
            controller.createFilterView()
            guard let view = controller.activeFilterView else { return check(false, "create a filter view", "none") }
            controller.setDisplayedFilterCriterion(FilterCriterion(hiddenValues: ["Feb", "Mar"]), column: 0)
            check(controller.displayHiddenRows == [2, 3] && controller.sheet.filteredRows.isEmpty && controller.sheet.filter == nil,
                  "a filter view hides rows only in its window", "\(controller.displayHiddenRows.sorted())")
            check(grid.rows.isHidden(2) && grid.showsFilterView, "the grid shows the filter view")
            controller.openFilterView(nil)
            check(controller.displayHiddenRows.isEmpty && !grid.rows.isHidden(2), "close a filter view")
            check(controller.sheet.filterViews.first?.id == view.id, "the filter view is kept")
        }
        // Printing includes objects.
        step {
            var settings = PrintSettings()
            settings.scope = .currentSheet
            let view = PrintPagesView(controller: controller, settings: settings, title: "Self test")
            check(!view.pages.isEmpty && view.pdfData().starts(with: Data("%PDF".utf8)), "print a sheet with a chart and an image")
        }
        // Files keep charts, images, links, pivot tables and filter views.
        step {
            for format in [SpreadsheetFileFormat.xlsx, .ods] {
                do {
                    let data = try SpreadsheetIO.write(controller.workbook, activeSheet: controller.activeSheetIndex, format: format)
                    let file = try SpreadsheetIO.read(data, format: format)
                    let sheet = file.workbook.sheets[controller.activeSheetIndex]
                    check(sheet.objects.contains { $0.chart != nil } && sheet.objects.contains { $0.image != nil }, "\(format) keeps charts and images",
                          "\(sheet.objects.count) objects")
                    check(sheet.link(at: address("A12")) == "https://example.com/sales", "\(format) keeps links")
                    check(sheet.filterViews.count == 1, "\(format) keeps filter views", "\(file.warnings)")
                } catch {
                    check(false, "\(format) files", "\(error)")
                }
            }
        }
    }

    /// Rules, filters, names, spilling, find and replace, shifting cells, cleanup, freezing and printing.
    private static func phaseTwo(_ window: DocumentWindowController) {
        let controller = window.controller
        let grid = window.grid
        func value(_ a1: String) -> CellValue { controller.sheet[address(a1)].value }
        func shownValue(_ a1: String) -> CellValue { controller.sheet.value(at: address(a1)) }
        func select(_ a1: String) { controller.selection = GridSelection(range: CellRange(a1: a1)!) }
        func range(_ a1: String) -> CellRange { CellRange(a1: a1)! }
        func put(_ rows: [[String]], at origin: String) {
            let start = address(origin)
            for (r, row) in rows.enumerated() {
                for (c, text) in row.enumerated() { controller.commitInput(text, at: CellAddress(row: start.row + r, column: start.column + c)) }
            }
        }

        step {
            controller.addSheet()
            put([["Name", "Team", "Score"], ["Ana", "Red", "70"], ["Ben", "Blue", "40"], ["Chen", "Red", "90"],
                 ["Dee", "Blue", "55"], ["Eli", "Red", "20"]], at: "A1")
            check(value("C6") == .number(20), "a new sheet with data", "\(value("C6"))")
        }

        // Data validation: a dropdown that rejects other values, and checkboxes.
        step {
            controller.setValidation(DataValidationRule(ranges: [range("B2:B6")], criterion: .list(["Red", "Blue"]), rejectsInvalid: true))
            var rejected: String?
            let original = controller.onRejectedInput
            controller.onRejectedInput = { rejected = $0 }
            controller.commitInput("Green", at: address("B2"))
            controller.onRejectedInput = original
            check(rejected != nil && value("B2") == .text("Red"), "validation rejects a value not in the list", rejected ?? "accepted")
            check(controller.dropdownItems(at: address("B3")) == ["Red", "Blue"], "dropdown items")
        }
        step {
            select("D2:D6")
            controller.insertCheckboxes()
            check(value("D2") == .boolean(false), "insert checkboxes", "\(value("D2"))")
            controller.toggleCheckboxes(at: [address("D2")])
            check(value("D2") == .boolean(true), "a checkbox toggles", "\(value("D2"))")
        }

        // Conditional formatting.
        step {
            controller.setConditionalFormat(ConditionalFormatRule(ranges: [range("C2:C6")],
                style: .condition(CellCondition(.greaterThan, ["50"]), ConditionalFormat(fillColor: RGBColor(hex: "B7E1CD")))))
            let formats = RuleEvaluator.conditionalFormats(in: range("A1:D6"), sheetIndex: controller.activeSheetIndex, workbook: controller.workbook)
            check(formats[address("C2")]?.fillColor == RGBColor(hex: "B7E1CD") && formats[address("C3")] == nil,
                  "conditional formatting colors values over 50", "\(formats.keys.map(\.a1).sorted())")
        }

        // Named ranges and a spilling formula.
        step {
            controller.setNamedRange(name: "Scores", reference: "$C$2:$C$6")
            check(controller.workbook.namedRange("scores")?.reference == "\(controller.sheet.name)!$C$2:$C$6",
                  "a named range is kept on its sheet", controller.workbook.namedRange("scores")?.reference ?? "none")
            controller.commitInput("=SUM(Scores)", at: address("F1"))
            check(value("F1") == .number(275), "a formula uses a named range", "\(value("F1"))")
            controller.commitInput("=SORT(C2:C6)", at: address("G1"))
            check(shownValue("G1") == .number(20) && shownValue("G5") == .number(90), "an array formula spills",
                  "\(shownValue("G1")) \(shownValue("G5"))")
            check(controller.spillingFormula(at: address("G3")) == "=SORT(C2:C6)", "spilled cells show their formula")
        }
        step {
            controller.commitInput("x", at: address("G4"))
            let blocked: Bool = if case .error = value("G1") { true } else { false }
            check(blocked, "a blocked spill shows an error", "\(value("G1"))")
            select("G4")
            controller.clearContents()
            check(shownValue("G4") == .number(70), "and spills again when cleared", "\(shownValue("G4"))")
        }

        // Filters.
        step {
            select("A1")
            controller.createFilter()
            check(controller.sheet.filter?.range == range("A1:D6"), "create a filter", controller.sheet.filter?.range.a1 ?? "none")
            controller.setFilterCriterion(FilterCriterion(hiddenValues: ["Blue"]), column: 1)
            check(controller.sheet.filteredRows == [2, 4], "filter by values hides rows", "\(controller.sheet.filteredRows.sorted())")
            let values = RuleEvaluator.filterValues(column: 1, sheetIndex: controller.activeSheetIndex, workbook: controller.workbook)
            check(values.map(\.value) == ["Blue", "Red"], "filter values list", "\(values)")
        }
        step {
            controller.setFilterCriterion(FilterCriterion(condition: CellCondition(.greaterThan, ["60"])), column: 2)
            check(controller.sheet.filteredRows == [2, 4, 5], "filter by condition", "\(controller.sheet.filteredRows.sorted())")
            controller.removeFilter()
            check(controller.sheet.filter == nil && controller.sheet.filteredRows.isEmpty, "remove the filter")
        }

        // Find and replace.
        step {
            window.findReplace.state.options = FindReplaceOptions(query: "red", replacement: "Green", scope: .thisSheet)
            window.findReplace.replaceAll()
            check(value("B2") == .text("Green") && value("B4") == .text("Green"), "replace all", "\(value("B2"))")
            controller.undoManager?.undo()
            check(value("B2") == .text("Red"), "undo replace all", "\(value("B2"))")
            window.findReplace.state.options = FindReplaceOptions(query: "SUM", replacement: "SUMSQ", scope: .thisSheet, withinFormulas: true)
            window.findReplace.replaceAll()
            check(controller.sheet[address("F1")].formula == "=SUMSQ(Scores)", "replace within formulas",
                  controller.sheet[address("F1")].formula ?? "")
            controller.undoManager?.undo()
            window.findReplace.state.options = FindReplaceOptions(query: "^[A-C]", scope: .thisSheet, matchCase: true, regex: true)
            select("A1")
            window.findReplace.find()
            check(controller.selection.active == address("A2"), "find with a regular expression", controller.selection.active.a1)
        }

        // Shifting cells.
        step {
            controller.commitInput("=A4", at: address("H1"))
            select("A2:A3")
            controller.insertCells(shiftDown: true)
            check(value("A4") == .text("Ana") && value("A2") == .empty && value("B2") == .text("Red"),
                  "insert cells and shift down", "\(value("A4")) \(value("A2"))")
            check(controller.sheet[address("H1")].formula == "=A6", "formulas follow shifted cells", controller.sheet[address("H1")].formula ?? "")
            controller.undoManager?.undo()
            select("B2")
            controller.deleteCells(shiftUp: false)
            check(value("B2") == .number(70), "delete cells and shift left", "\(value("B2"))")
            controller.undoManager?.undo()
            check(value("B2") == .text("Red"), "undo delete cells", "\(value("B2"))")
        }

        // Data cleanup.
        step {
            put([["  too   many  spaces "], ["a,b,c"], ["Ana"], ["Ben"], ["Ana"]], at: "J1")
            select("J1")
            controller.trimWhitespace()
            check(value("J1") == .text("too many spaces"), "trim whitespace", "\(value("J1"))")
            select("J2")
            controller.splitTextToColumns(separator: nil)
            check(value("J2") == .text("a") && value("K2") == .text("b") && value("L2") == .text("c"), "split text to columns",
                  "\(value("K2"))")
            let result = controller.removeDuplicates(in: range("J3:J5"), columns: [9], hasHeader: false)
            check(result.removed == 1 && value("J5") == .empty, "remove duplicates", "\(result)")
        }

        // Dragging the freeze bar from the corner down to below row 2.
        step {
            @MainActor func mouse(_ type: NSEvent.EventType, _ point: CGPoint) {
                let location = grid.convert(point, to: nil)
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.window?.windowNumber ?? 0, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                switch type {
                case .leftMouseDown: grid.mouseDown(with: event)
                case .leftMouseDragged: grid.mouseDragged(with: event)
                default: grid.mouseUp(with: event)
                }
            }
            let start = CGPoint(x: grid.headerWidth / 2, y: grid.headerHeight - 2)
            let end = CGPoint(x: grid.headerWidth / 2, y: grid.rowY(2) + 3)
            mouse(.leftMouseDown, start)
            mouse(.leftMouseDragged, end)
            mouse(.leftMouseUp, end)
            check(controller.sheet.frozenRows == 2, "drag the freeze bar", "\(controller.sheet.frozenRows)")
        }

        // Formula help.
        step {
            check(FormulaContext.at(3, in: "=SU")?.partialName?.text == "SU", "autocomplete reads the typed name")
            let context = FormulaContext.at(14, in: "=SUMIF(A1:A5, ")
            check(context?.call?.name == "SUMIF" && context?.call?.argument == 1, "argument help follows the caret",
                  "\(String(describing: context?.call))")
        }

        // Printing.
        step {
            var settings = PrintSettings()
            settings.scope = .currentSheet
            let view = PrintPagesView(controller: controller, settings: settings, title: "Self test")
            let pdf = view.pdfData()
            check(!view.pages.isEmpty && pdf.starts(with: Data("%PDF".utf8)), "print to PDF", "\(view.pages.count) pages")
            settings.scale = .fitWidth
            check(PrintPagesView(controller: controller, settings: settings, title: "").pages.count == 1, "fit to width makes one page")
            settings.scale = .custom
            settings.customScale = 400
            check(PrintPagesView(controller: controller, settings: settings, title: "").pages.count > view.pages.count,
                  "a bigger scale makes more pages")
        }

        // OpenDocument.
        step {
            do {
                let data = try SpreadsheetIO.write(controller.workbook, activeSheet: controller.activeSheetIndex, format: .ods)
                let file = try SpreadsheetIO.read(data, format: .ods)
                let sheet = file.workbook.sheets[controller.activeSheetIndex]
                check(file.workbook.sheets.map(\.name) == controller.workbook.sheets.map(\.name), "ods keeps the sheets")
                check(sheet[address("F1")].formula == "=SUM(Scores)" && sheet[address("F1")].value == .number(275), "ods keeps formulas",
                      "\(sheet[address("F1")].formula ?? "nil") \(sheet[address("F1")].value)")
                check(file.workbook.namedRanges.map(\.name) == ["Scores"], "ods keeps named ranges")
            } catch {
                check(false, "ods", "\(error)")
            }
        }
    }
}
#endif
