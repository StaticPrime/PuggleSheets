import AppKit
import PuggleSheetsKit

extension NSPasteboard.PasteboardType {
    /// Cells copied from PuggleSheets: formulas, values, formats and merges.
    static let puggleSheetsCells = NSPasteboard.PasteboardType("com.pugglesoft.pugglesheets.cells")
}

enum PasteMode {
    case normal, valuesOnly, formatOnly, transposed
}

/// Copied cells as they travel on the pasteboard.
struct ClipboardPayload: Codable {
    var documentID: UUID
    var sheetID: UUID
    var startRow: Int
    var startColumn: Int
    var rows: [[ClipboardCell]]
    /// Merged blocks inside the copied range, relative to its top-left cell.
    var merges: [[Int]]
    var isCut: Bool

    var source: CellRange {
        CellRange(rows: startRow...(startRow + max(rows.count, 1) - 1),
                  columns: startColumn...(startColumn + max(rows.first?.count ?? 1, 1) - 1))
    }
}

struct ClipboardCell: Codable {
    var formula: String?
    var number: Double?
    var text: String?
    var boolean: Bool?
    var error: String?
    var format: ClipboardFormat?
    var link: String?
    var note: String?
    /// An image in the cell: its file's bytes.
    var image: Data?
    var imageAltText: String?

    init(_ cell: Cell) {
        formula = cell.formula
        link = cell.link
        note = cell.note
        image = cell.image?.image.data
        imageAltText = cell.image?.altText
        switch cell.value {
        case .empty: break
        case .number(let value): number = value
        case .text(let value): text = value
        case .boolean(let value): boolean = value
        case .error(let value): error = value.code
        }
        format = cell.format.isDefault ? nil : ClipboardFormat(cell.format)
    }

    var value: CellValue {
        if let number { return .number(number) }
        if let text { return .text(text) }
        if let boolean { return .boolean(boolean) }
        if let error, let cellError = CellError(code: error) { return .error(cellError) }
        return .empty
    }

    /// The cell to paste. Comments stay with their cell.
    var cell: Cell {
        Cell(value: value, formula: formula, format: format?.format ?? CellFormat(), link: link,
             image: image.flatMap(ImageData.init(data:)).map { CellImage(image: $0, altText: imageAltText ?? "") }, note: note)
    }
}

struct ClipboardFormat: Codable {
    var fontFamily: String?
    var fontSize: Double?
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var strikethrough: Bool
    var textColor: String?
    var fillColor: String?
    var horizontal: String?
    var vertical: String?
    var wrap: String?
    var numberFormat: String?
    /// Top, left, bottom, right as "style color" or nil.
    var borders: [String?]
    /// Degrees, or 1000 for stacked text.
    var rotation: Int?

    init(_ format: CellFormat) {
        fontFamily = format.fontFamily
        fontSize = format.fontSize
        bold = format.bold
        italic = format.italic
        underline = format.underline
        strikethrough = format.strikethrough
        textColor = format.textColor?.hex
        fillColor = format.fillColor?.hex
        horizontal = format.horizontalAlignment?.rawValue
        vertical = format.verticalAlignment?.rawValue
        wrap = format.wrap?.rawValue
        numberFormat = format.numberFormat
        let sides = [format.borders.top, format.borders.left, format.borders.bottom, format.borders.right]
        borders = sides.map { $0.map { "\($0.style.rawValue) \($0.color.hex)" } }
        switch format.textRotation {
        case .angle(let degrees)?: rotation = degrees
        case .stacked?: rotation = 1000
        case nil: rotation = nil
        }
    }

    var format: CellFormat {
        var format = CellFormat()
        format.fontFamily = fontFamily
        format.fontSize = fontSize
        format.bold = bold
        format.italic = italic
        format.underline = underline
        format.strikethrough = strikethrough
        format.textColor = textColor.flatMap(RGBColor.init(hex:))
        format.fillColor = fillColor.flatMap(RGBColor.init(hex:))
        format.horizontalAlignment = horizontal.flatMap(HorizontalAlignment.init(rawValue:))
        format.verticalAlignment = vertical.flatMap(VerticalAlignment.init(rawValue:))
        format.wrap = wrap.flatMap(WrapStrategy.init(rawValue:))
        format.numberFormat = numberFormat
        func line(_ index: Int) -> BorderLine? {
            guard index < borders.count, let text = borders[index] else { return nil }
            let parts = text.split(separator: " ")
            guard parts.count == 2, let style = BorderStyle(rawValue: String(parts[0])),
                  let color = RGBColor(hex: String(parts[1])) else { return nil }
            return BorderLine(style: style, color: color)
        }
        format.borders = CellBorders(top: line(0), left: line(1), bottom: line(2), right: line(3))
        if let rotation { format.textRotation = rotation == 1000 ? .stacked : .angle(min(90, max(-90, rotation))) }
        return format
    }
}

extension SpreadsheetController {
    // MARK: Copy and cut

    /// Puts the current range on the pasteboard: PuggleSheets cells, tab-separated text and an HTML table.
    func copySelection(cut: Bool = false) {
        let range = selection.current
        let sheet = self.sheet
        // Spilled values copy as values, unless their formula is copied too (it spills again when pasted).
        let rows = range.rows.map { row in
            range.columns.map { column -> ClipboardCell in
                let address = CellAddress(row: row, column: column)
                if let source = sheet.spillSource(of: address), range.contains(source) { return ClipboardCell(sheet[address]) }
                return ClipboardCell(shownCell(at: address, in: sheet))
            }
        }
        let merges = sheet.merges.filter { range.contains($0) }.map {
            [$0.start.row - range.start.row, $0.start.column - range.start.column, $0.rowCount, $0.columnCount]
        }
        let payload = ClipboardPayload(documentID: documentID, sheetID: activeSheetID, startRow: range.start.row,
                                       startColumn: range.start.column, rows: rows, merges: merges, isCut: cut)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let data = try? JSONEncoder().encode(payload) { pasteboard.setData(data, forType: .puggleSheetsCells) }
        pasteboard.setString(tabSeparatedText(range), forType: .string)
        pasteboard.setString(htmlTable(range), forType: .html)
        cutRange = cut ? CutRange(sheetID: activeSheetID, range: range, changeCount: pasteboard.changeCount) : nil
    }

    /// The text other apps receive: displayed values, tab-separated, quoting cells with line breaks or tabs.
    func tabSeparatedText(_ range: CellRange) -> String {
        range.rows.map { row in
            range.columns.map { column -> String in
                let cell = shownCell(at: CellAddress(row: row, column: column), in: sheet)
                let text = CellDisplay.text(for: cell.value, pattern: cell.format.numberFormat).text
                if text.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) {
                    return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return text
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    private func htmlTable(_ range: CellRange) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
        }
        var html = "<meta charset=\"utf-8\"><table style=\"border-collapse:collapse\">"
        for row in range.rows {
            html += "<tr style=\"height:\(Int(sheet.rowHeight(row)))px\">"
            for column in range.columns {
                let cell = shownCell(at: CellAddress(row: row, column: column), in: sheet)
                let format = cell.format
                var style = "font-family:\(format.resolvedFontFamily);font-size:\(format.resolvedFontSize)pt;"
                if format.bold { style += "font-weight:bold;" }
                if format.italic { style += "font-style:italic;" }
                if format.underline || format.strikethrough {
                    style += "text-decoration:\(format.underline ? "underline " : "")\(format.strikethrough ? "line-through" : "");"
                }
                if let color = format.textColor { style += "color:#\(color.hex);" }
                if let fill = format.fillColor { style += "background-color:#\(fill.hex);" }
                if let alignment = format.horizontalAlignment { style += "text-align:\(alignment.rawValue);" }
                if row == range.start.row { style += "width:\(Int(sheet.columnWidth(column)))px;" }
                let text = CellDisplay.text(for: cell.value, pattern: format.numberFormat).text
                html += "<td style=\"\(style)\">\(escape(text))</td>"
            }
            html += "</tr>"
        }
        return html + "</table>"
    }

    // MARK: Paste

    func paste(_ mode: PasteMode) {
        let pasteboard = NSPasteboard.general
        if mode == .transposed {
            if let data = pasteboard.data(forType: .puggleSheetsCells),
               let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data), !payload.rows.isEmpty {
                pasteTransposed(payload.rows.map { $0.map(\.cell) }, source: payload.source)
            } else if let text = pasteboard.string(forType: .string) {
                let rows = Self.parseTabSeparated(text)
                let cells = rows.map { $0.map { cell(forInput: $0, replacing: Cell()) } }
                // Typed text has no references to shift: pretend it was copied from where it goes.
                let origin = selection.current.start
                let width = cells.map(\.count).max() ?? 0
                let padded = cells.map { $0 + Array(repeating: Cell(), count: width - $0.count) }
                pasteTransposed(padded, source: CellRange(origin, origin.offsetBy(rows: padded.count - 1, columns: max(0, width - 1))))
            }
            return
        }
        if let data = pasteboard.data(forType: .puggleSheetsCells),
           let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data), !payload.rows.isEmpty {
            if payload.isCut, mode == .normal, payload.documentID == documentID, let cut = cutRange,
               cut.changeCount == pasteboard.changeCount, cut.sheetID == payload.sheetID {
                move(payload, from: cut)
            } else {
                paste(payload.rows.map { $0.map(\.cell) }, source: payload.source, merges: payload.merges, mode: mode)
            }
        } else if let text = pasteboard.string(forType: .string) {
            pasteText(text, mode: mode)
        }
    }

    /// Where a block of `height` × `width` cells goes: repeated over the selection when the selection
    /// is a whole multiple of it, else once at the selection's top-left cell.
    private func pasteTargets(height: Int, width: Int) -> [CellAddress] {
        let range = selection.current
        if range.rowCount % height == 0, range.columnCount % width == 0, range.cellCount > height * width {
            return stride(from: range.start.row, through: range.end.row, by: height).flatMap { row in
                stride(from: range.start.column, through: range.end.column, by: width).map { CellAddress(row: row, column: $0) }
            }
        }
        return [range.start]
    }

    private func paste(_ cells: [[Cell]], source: CellRange, merges: [[Int]], mode: PasteMode) {
        let height = cells.count, width = cells[0].count
        let targets = pasteTargets(height: height, width: width)
        var updates: [CellAddress: Cell] = [:]
        var layout = SheetLayout(sheet)
        for origin in targets {
            for (rowOffset, row) in cells.enumerated() {
                for (columnOffset, copied) in row.enumerated() {
                    let address = origin.offsetBy(rows: rowOffset, columns: columnOffset)
                    var cell = sheet[address]
                    switch mode {
                    case .normal:
                        cell = translated(copied, rows: origin.row - source.start.row, columns: origin.column - source.start.column)
                    case .valuesOnly:
                        cell.formula = nil
                        cell.value = copied.value
                    case .formatOnly:
                        cell.format = copied.format
                    case .transposed:
                        break
                    }
                    updates[address] = cell
                }
            }
            let block = CellRange(rows: origin.row...(origin.row + height - 1), columns: origin.column...(origin.column + width - 1))
            if mode != .valuesOnly {
                layout.merges.removeAll { $0.intersects(block) }
                for merge in merges where merge.count == 4 {
                    let start = origin.offsetBy(rows: merge[0], columns: merge[1])
                    layout.merges.append(CellRange(start, start.offsetBy(rows: merge[2] - 1, columns: merge[3] - 1)))
                }
            }
            layout.rowCount = max(layout.rowCount, block.end.row + 1)
            layout.columnCount = max(layout.columnCount, block.end.column + 1)
        }
        let first = targets[0], last = targets[targets.count - 1]
        let pasted = CellRange(first, last.offsetBy(rows: height - 1, columns: width - 1))
        var changes: [WorkbookChange] = []
        if layout != SheetLayout(sheet) { changes.append(.layout(sheet: activeSheetID, layout)) }
        changes.append(.cells(sheet: activeSheetID, updates))
        perform(changes, actionName: "Paste", selection: GridSelection(range: pasted, active: first))
    }

    /// Cut and paste: the cells move, and formulas that pointed at them follow.
    private func move(_ payload: ClipboardPayload, from cut: CutRange) {
        guard let sourceIndex = workbook.sheetIndex(id: cut.sheetID) else { return }
        let destinationIndex = activeSheetIndex
        let source = cut.range
        let target = CellRange(selection.current.start,
                               selection.current.start.offsetBy(rows: source.rowCount - 1, columns: source.columnCount - 1))
        let rows = target.start.row - source.start.row, columns = target.start.column - source.start.column
        guard rows != 0 || columns != 0 || sourceIndex != destinationIndex else { return }
        let moved = sheetCells(in: source, sheet: sourceIndex)
        let movedMerges = workbook.sheets[sourceIndex].merges.filter { source.contains($0) }
        performWorkbookEdit(actionName: "Paste", selection: GridSelection(range: target, active: target.start)) { workbook in
            var cleared: [CellAddress: Cell] = [:]
            for address in source.addresses { cleared[address] = Cell() }
            workbook.sheets[sourceIndex].setCells(cleared)
            workbook.sheets[sourceIndex].merges.removeAll { source.contains($0) }
            var sheet = workbook.sheets[destinationIndex]
            sheet.rowCount = max(sheet.rowCount, target.end.row + 1)
            sheet.columnCount = max(sheet.columnCount, target.end.column + 1)
            sheet.merges.removeAll { $0.intersects(target) }
            sheet.merges.append(contentsOf: movedMerges.map { $0.offsetBy(rows: rows, columns: columns) })
            var placed: [CellAddress: Cell] = [:]
            for address in target.addresses { placed[address] = Cell() }
            for (address, cell) in moved { placed[address.offsetBy(rows: rows, columns: columns)] = cell }
            sheet.setCells(placed)
            workbook.sheets[destinationIndex] = sheet
            workbook.followMove(of: source, inSheet: sourceIndex, rows: rows, columns: columns, toSheet: destinationIndex)
        }
        // A second paste makes a copy.
        cutRange = nil
        var copy = payload
        copy.isCut = false
        if let data = try? JSONEncoder().encode(copy) { NSPasteboard.general.setData(data, forType: .puggleSheetsCells) }
    }

    private func sheetCells(in range: CellRange, sheet index: Int) -> [CellAddress: Cell] {
        var result: [CellAddress: Cell] = [:]
        for (address, cell) in workbook.sheets[index].cells(in: range) { result[address] = cell }
        return result
    }

    /// Text from other apps: tab-separated values, each read as if typed.
    private func pasteText(_ text: String, mode: PasteMode) {
        guard mode != .formatOnly else { return }
        let rows = Self.parseTabSeparated(text)
        guard !rows.isEmpty else { return }
        let width = rows.map(\.count).max() ?? 1
        let cells = rows.map { row in
            (0..<width).map { index -> Cell in
                let field = index < row.count ? row[index] : ""
                return cell(forInput: field, replacing: Cell())
            }
        }
        let start = selection.current.start
        // Keep each target cell's formatting; only the content comes from the text.
        let targets = pasteTargets(height: cells.count, width: width)
        var updates: [CellAddress: Cell] = [:]
        for origin in targets {
            for (rowOffset, row) in cells.enumerated() {
                for (columnOffset, typed) in row.enumerated() {
                    let address = origin.offsetBy(rows: rowOffset, columns: columnOffset)
                    var cell = sheet[address]
                    cell.value = typed.value
                    cell.formula = mode == .valuesOnly ? nil : typed.formula
                    if cell.format.numberFormat == nil { cell.format.numberFormat = typed.format.numberFormat }
                    updates[address] = cell
                }
            }
        }
        let last = targets[targets.count - 1].offsetBy(rows: cells.count - 1, columns: width - 1)
        var changes: [WorkbookChange] = []
        if last.row >= sheet.rowCount || last.column >= sheet.columnCount {
            var layout = SheetLayout(sheet)
            layout.rowCount = max(layout.rowCount, last.row + 1)
            layout.columnCount = max(layout.columnCount, last.column + 1)
            changes.append(.layout(sheet: activeSheetID, layout))
        }
        changes.append(.cells(sheet: activeSheetID, updates))
        perform(changes, actionName: "Paste", selection: GridSelection(range: CellRange(start, last), active: start))
    }

    /// Splits tab-separated text into rows and fields; quoted fields may hold tabs, line breaks and "".
    static func parseTabSeparated(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var atFieldStart = true
        var iterator = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")).makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where atFieldStart:
                inQuotes = true
                atFieldStart = false
            case "\t":
                row.append(field)
                field = ""
                atFieldStart = true
            case "\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                atFieldStart = true
            default:
                field.append(character)
                atFieldStart = false
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
