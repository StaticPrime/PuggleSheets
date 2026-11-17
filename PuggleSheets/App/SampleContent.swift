#if DEBUG
import AppKit
import PuggleSheetsKit

/// A small budget used to check layout and rendering during development (`-PSSampleDocument YES`).
enum SampleContent {
    static func make() -> Workbook {
        var sheet = Sheet(name: "Budget")
        func set(_ reference: String, _ input: String, _ change: (inout CellFormat) -> Void = { _ in }) {
            guard let address = CellAddress(a1: reference) else { return }
            var cell = sheet[address]
            let parsed = InputParser.parse(input, currentFormat: nil)
            cell.formula = parsed.formula
            cell.value = parsed.value
            if let implied = parsed.impliedFormat { cell.format.numberFormat = implied }
            change(&cell.format)
            sheet[address] = cell
        }
        let header = RGBColor(hex: "D9EAD3")!
        set("A1", "Quarterly budget") { $0.bold = true; $0.fontSize = 14 }
        sheet.merges = [CellRange(a1: "A1:E1")!]
        for (column, title) in ["Item", "Owner", "Due", "Cost", "Share"].enumerated() {
            set(CellAddress(row: 1, column: column).a1, title) { format in
                format.bold = true
                format.fillColor = header
                format.borders.bottom = BorderLine()
            }
        }
        let rows: [(String, String, String, String)] = [
            ("Laptops", "Ana", "1/15/2026", "4200"),
            ("Office rent", "Ben", "2/1/2026", "12000"),
            ("Travel to the customer conference in Lisbon", "Chen", "3/10/2026", "2650.5"),
            ("Software", "Ana", "3/31/2026", "980"),
        ]
        for (index, row) in rows.enumerated() {
            let line = index + 3
            set("A\(line)", row.0)
            set("B\(line)", row.1)
            set("C\(line)", row.2)
            set("D\(line)", row.3) { $0.numberFormat = "\"$\"#,##0.00" }
            set("E\(line)", "=D\(line)/D$8") { $0.numberFormat = "0.0%" }
        }
        set("A8", "Total") { $0.bold = true }
        set("D8", "=SUM(D3:D6)") { format in
            format.bold = true
            format.numberFormat = "\"$\"#,##0.00"
            format.borders.top = BorderLine(style: .double)
        }
        set("A10", "Notes wrap inside their cell when wrapping is on, and the row grows to fit.") { $0.wrap = .wrap }
        set("C10", "Error:")
        set("D10", "=1/0")
        sheet.columnWidths = [0: 180]
        sheet.rowHeights = [1: 40, 9: 48]
        sheet.frozenRows = 2
        // Phase 4: a note, a comment thread, a protected range, a group and rotated text.
        sheet[7, 3].note = "Updated after the January review."
        sheet[2, 0].comment = CommentThread(comments: [
            Comment(author: "Ana Lima", date: Date().addingTimeInterval(-3600 * 26), text: "Should this include the docking stations?"),
            Comment(author: "Ben Ortiz", date: Date().addingTimeInterval(-3600 * 2), text: "Yes, they're in the same order."),
        ])
        sheet.protections = [ProtectedRange(scope: .range(CellRange(a1: "D3:D6")!), description: "Approved costs")]
        sheet.rowGroups = [OutlineGroup(range: 2...5)]
        set("G2", "Q1") { $0.bold = true; $0.textRotation = .angle(45) }
        set("H2", "Q2") { $0.bold = true; $0.textRotation = .stacked }

        var notes = Sheet(name: "Notes")
        notes[0, 0] = Cell(value: .text("Second sheet"))
        notes[1, 0] = Cell(formula: "=Budget!D8")
        if let picture = samplePicture() {
            notes[3, 0] = Cell(value: .text("Image in a cell:"))
            notes[3, 1] = Cell(image: CellImage(image: picture, altText: "Sample picture"))
            notes.rowHeights = [3: 60]
        }
        notes[5, 0] = Cell(value: .text("PuggleSheets on the web"), link: "https://example.com/pugglesheets")
        notes[6, 0] = Cell(value: .text("www.example.com"))
        var pivot = Sheet(name: "Pivot")
        pivot.pivotTables = [PivotTable(anchor: CellAddress(row: 0, column: 0), source: "Tracker!A1:E8",
                                        rows: [PivotGroup(sourceColumn: 1)], columns: [PivotGroup(sourceColumn: 2)],
                                        values: [PivotValue(sourceColumn: 4)])]
        pivot.columnWidths = [0: 120]
        return Workbook(sheets: [sheet, notes, tracker(), pivot, orders()],
                        namedRanges: [NamedRange(name: "Estimates", reference: "Tracker!$E$2:$E$8")])
    }

    /// Phase 5: a table with typed columns, a slicer, sparklines, QUERY and MAP with LAMBDA.
    private static func orders() -> Sheet {
        var sheet = Sheet(name: "Orders")
        let rows: [[String]] = [
            ["Order", "Region", "Amount", "Shipped", "Jan", "Feb", "Mar", "Trend"],
            ["1001", "East", "1250", "TRUE", "4", "7", "6"],
            ["1002", "West", "980", "FALSE", "8", "5", "9"],
            ["1003", "North", "1430", "TRUE", "3", "6", "10"],
            ["1004", "East", "610", "FALSE", "9", "4", "2"],
            ["1005", "West", "2120", "TRUE", "5", "8", "7"],
            ["1006", "North", "870", "TRUE", "6", "6", "8"],
        ]
        for (row, values) in rows.enumerated() {
            for (column, text) in values.enumerated() {
                let parsed = InputParser.parse(text, currentFormat: nil)
                var cell = Cell(value: parsed.value)
                if column == 2, row > 0 { cell.format.numberFormat = "\"$\"#,##0.00" }
                if column == 3 { cell.format.horizontalAlignment = .center }
                sheet[row, column] = cell
            }
            if row > 0 { sheet[row, 7] = Cell(formula: "=SPARKLINE(E\(row + 1):G\(row + 1))") }
        }
        sheet.tables = [SheetTable(name: "Sales", range: CellRange(a1: "A1:H7")!, columnTypes: [2: .currency, 3: .checkbox])]
        sheet.validations = [DataValidationRule(ranges: [CellRange(a1: "D2:D7")!], criterion: .checkbox(checked: nil, unchecked: nil))]
        sheet[0, 9] = Cell(value: .text("Totals by region"), format: { var format = CellFormat(); format.bold = true; return format }())
        sheet[1, 9] = Cell(formula: "=QUERY(Sales, \"select B, sum(C) group by B label sum(C) 'Total'\", 1)")
        sheet[7, 9] = Cell(value: .text("Amount plus 10%"), format: { var format = CellFormat(); format.bold = true; return format }())
        sheet[8, 9] = Cell(formula: "=MAP(C2:C7, LAMBDA(amount, amount * 1.1))")
        sheet.columnWidths = [7: 120, 9: 140]
        sheet.objects = [SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 8, column: 0), offsetX: 6, offsetY: 6, width: 220, height: 64),
                                     content: .slicer(SlicerSpec(range: "Sales", column: 1)))]
        return sheet
    }

    /// A small drawn picture for the image samples.
    static func samplePicture() -> ImageData? {
        let image = NSImage(size: NSSize(width: 160, height: 100), flipped: false) { rect in
            NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.66, blue: 0.33, alpha: 1),
                       ending: NSColor(srgbRed: 0.98, green: 0.74, blue: 0.02, alpha: 1))?.draw(in: rect, angle: 30)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white]
            ("Puggle" as NSString).draw(at: NSPoint(x: 44, y: 38), withAttributes: attributes)
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return ImageData(data: png)
    }

    /// Phase 2's rules: a dropdown, checkboxes, a color scale, a conditional fill, alternating colors,
    /// a filter, a named range and a spilling formula.
    private static func tracker() -> Sheet {
        var sheet = Sheet(name: "Tracker")
        let rows: [[String]] = [
            ["Task", "Owner", "Status", "Done", "Estimate"],
            ["Design the grid", "Ana", "Done", "TRUE", "8"],
            ["Formula engine", "Ben", "In progress", "FALSE", "13"],
            ["Excel files", "Chen", "Done", "TRUE", "5"],
            ["Printing", "Ana", "Not started", "FALSE", "3"],
            ["Filters", "Ben", "In progress", "FALSE", "5"],
            ["Charts", "Chen", "Not started", "FALSE", "8"],
            ["Comments", "Ana", "Not started", "FALSE", "2"],
        ]
        for (row, values) in rows.enumerated() {
            for (column, text) in values.enumerated() {
                let parsed = InputParser.parse(text, currentFormat: nil)
                var cell = Cell(value: parsed.value)
                if row == 0 { cell.format.bold = true }
                if column == 3 { cell.format.horizontalAlignment = .center }
                sheet[row, column] = cell
            }
        }
        sheet[9, 3] = Cell(value: .text("Total"), format: { var format = CellFormat(); format.bold = true; return format }())
        sheet[9, 4] = Cell(formula: "=SUM(Estimates)")
        sheet[0, 6] = Cell(value: .text("Sorted tasks"), format: { var format = CellFormat(); format.bold = true; return format }())
        sheet[1, 6] = Cell(formula: "=SORT(A2:A8)")
        sheet.columnWidths = [0: 150, 6: 150]
        sheet.validations = [
            DataValidationRule(ranges: [CellRange(a1: "C2:C8")!], criterion: .list(["Not started", "In progress", "Done"])),
            DataValidationRule(ranges: [CellRange(a1: "D2:D8")!], criterion: .checkbox(checked: nil, unchecked: nil)),
        ]
        sheet.conditionalFormats = [
            ConditionalFormatRule(ranges: [CellRange(a1: "C2:C8")!],
                                  style: .condition(CellCondition(.textIsExactly, ["Done"]), ConditionalFormat(fillColor: RGBColor(hex: "B7E1CD")))),
            ConditionalFormatRule(ranges: [CellRange(a1: "E2:E8")!],
                                  style: .colorScale(ColorScale(minimum: .init(kind: .minimum, color: .white),
                                                                maximum: .init(kind: .maximum, color: RGBColor(hex: "57BB8A")!)))),
        ]
        sheet.bandings = [Banding(range: CellRange(a1: "A1:E8")!, headerColor: RGBColor(hex: "BDBDBD"), firstColor: .white,
                                  secondColor: RGBColor(hex: "F3F3F3")!)]
        sheet.filter = SheetFilter(range: CellRange(a1: "A1:E8")!)
        sheet.filterViews = [FilterView(name: "Ana's tasks", range: CellRange(a1: "A1:E8")!,
                                        criteria: [1: FilterCriterion(hiddenValues: ["Ben", "Chen"])])]
        sheet.objects = [SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 11, column: 0), offsetX: 8, offsetY: 4, width: 520, height: 300),
                                     content: .chart(ChartSpec(kind: .column, ranges: ["A1:A8", "E1:E8"], title: "Estimate by task")))]
        if let picture = samplePicture() {
            sheet.objects.append(SheetObject(anchor: ObjectAnchor(cell: CellAddress(row: 11, column: 6), offsetX: 10, offsetY: 4, width: 160, height: 100),
                                             content: .image(picture), title: "Sample picture"))
        }
        sheet.frozenRows = 1
        return sheet
    }
}
#endif
