import Foundation

/// Writes OpenDocument spreadsheets (.ods), as LibreOffice lays them out.
enum ODSWriter {
    static let mimetype = "application/vnd.oasis.opendocument.spreadsheet"
    /// LibreOffice's grid.
    static let maximumRows = 1_048_576
    static let maximumColumns = 16_384

    typealias SheetSize = (String?) -> (rows: Int, columns: Int)

    static let namespaces = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" "
        + "xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" "
        + "xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" "
        + "xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" "
        + "xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" "
        + "xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" "
        + "xmlns:xlink=\"http://www.w3.org/1999/xlink\" "
        + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
        + "xmlns:meta=\"urn:oasis:names:tc:opendocument:xmlns:meta:1.0\" "
        + "xmlns:number=\"urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0\" "
        + "xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\" "
        + "xmlns:of=\"urn:oasis:names:tc:opendocument:xmlns:of:1.2\" "
        + "xmlns:ooo=\"http://openoffice.org/2004/office\" "
        + "xmlns:oooc=\"http://openoffice.org/2004/calc\" "
        + "xmlns:tableooo=\"http://openoffice.org/2009/table\" "
        + "xmlns:calcext=\"urn:org:documentfoundation:names:experimental:calc:xmlns:calcext:1.0\" "
        + "xmlns:loext=\"urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0\""

    static func write(_ workbook: Workbook, activeSheet: Int, date: Date = Date()) throws -> Data {
        let sheets = workbook.sheets.isEmpty ? [Sheet(name: "Sheet1")] : workbook.sheets
        let active = min(max(activeSheet, 0), sheets.count - 1)
        let names = XLSXSheetNames.sanitized(sheets.map(\.name), maximumLength: 255)
        var sizes: [String: (rows: Int, columns: Int)] = [:]
        for sheet in sheets where sizes[sheet.name.lowercased()] == nil {
            sizes[sheet.name.lowercased()] = (sheet.rowCount, sheet.columnCount)
        }
        func sizer(_ sheet: Sheet) -> SheetSize {
            { name in name.flatMap { sizes[$0.lowercased()] } ?? (sheet.rowCount, sheet.columnCount) }
        }

        // The workbook as written, with at least one sheet.
        let book = Workbook(sheets: sheets, namedRanges: workbook.namedRanges)
        var sheetNames: [UUID: String] = [:]
        for (index, sheet) in sheets.enumerated() where sheetNames[sheet.id] == nil { sheetNames[sheet.id] = names[index] }

        var styles = ODSStyleWriter()
        var drawings = ODSDrawingWriter()
        var validations = XMLWriter(fragmentCapacity: 256)
        var tables = XMLWriter(fragmentCapacity: 4096)
        var databaseRanges = XMLWriter(fragmentCapacity: 256)
        var validationCount = 0
        var sheetSettings: [ODSSheetSettings] = []
        let tableReferences = ODSTableReferences(workbook: book, names: names)
        for (index, sheet) in sheets.enumerated() {
            let size = sizer(sheet)
            let validationNames = ODSRules.writeValidations(sheet.validations, sheet: names[index], firstNumber: validationCount + 1,
                                                            size: size, into: &validations)
            validationCount += validationNames.count
            // Links, images, notes, comments and formulas with brackets in cells, found in one pass over the cells.
            var extras = CellExtrasList()
            var images: [(address: CellAddress, image: CellImage)] = []
            var settings = ODSSheetSettings(name: names[index], filterViews: sheet.filterViews, protections: sheet.protections)
            for (address, cell) in sheet.cells where cell.link != nil || cell.image != nil || cell.note != nil || cell.comment != nil
                || cell.formula?.utf8.contains(UInt8(ascii: "[")) == true {
                if let formula = cell.formula, formula.utf8.contains(UInt8(ascii: "[")),
                   let written = ODSFormula.exporting(formula, size: size, tables: tableReferences, row: address.row) {
                    // Structured references become the cells they cover: the formula as typed is kept while unchanged.
                    extras.formulas[address] = written.text
                    if written.hasTableReferences {
                        settings.formulas.append(ODSFormulaExtras(address: address, formula: formula, fingerprint: written.text))
                    }
                }
                if let link = cell.link, let href = ODSLinks.href(for: link, sheetNames: sheetNames) { extras.links[address] = href }
                if let image = cell.image { images.append((address, image)) }
                if cell.note != nil || cell.comment != nil {
                    let thread = cell.comment.flatMap { $0.comments.isEmpty ? nil : $0 }
                    if let annotation = ODSAnnotations.write(note: cell.note, thread: thread) { extras.annotations[address] = annotation }
                    if let thread {
                        settings.comments.append(ODSCommentExtras(address: address, thread: thread, content: cell.note == nil ? .thread : .noteAndThread,
                                                                  note: cell.note))
                    }
                }
            }
            // Rows and columns hidden by hand inside collapsed groups, which the file shows as the group's.
            let collapsedRows = ODSOutline.merged(sheet.rowGroups.filter(\.isCollapsed).map(\.range))
            let collapsedColumns = ODSOutline.merged(sheet.columnGroups.filter(\.isCollapsed).map(\.range))
            if !collapsedRows.isEmpty {
                settings.hiddenRows = ODSSheetSettings.runs(sheet.hiddenRows.filter { row in collapsedRows.contains { $0.contains(row) } })
            }
            if !collapsedColumns.isEmpty {
                settings.hiddenColumns = ODSSheetSettings.runs(sheet.hiddenColumns.filter { column in collapsedColumns.contains { $0.contains(column) } })
            }
            extras.frames = drawings.frames(for: sheet, images: images, sheetIndex: index, names: names, workbook: book)
            settings.slicers = drawings.slicers[index] ?? []
            // The sheet filter, then the tables, as database ranges.
            ODSRules.writeFilter(of: sheet, index: index, name: names[index], into: &databaseRanges)
            settings.tables = ODSTables.write(sheet, sheetName: names[index], into: &databaseRanges)
            sheetSettings.append(settings)
            try writeTable(sheet, name: names[index], validationNames: validationNames, styles: &styles, size: size, cellExtras: extras,
                           into: &tables)
        }

        var content = XMLWriter(reservingCapacity: tables.bytes.count + 4096)
        content.raw("<office:document-content \(namespaces) office:version=\"1.3\">")
        content.raw("<office:scripts/>")
        styles.writeFontFaces(into: &content)
        content.raw("<office:automatic-styles>")
        styles.writeAutomaticStyles(into: &content)
        if drawings.hasFrames { content.raw(ODSDrawings.graphicStyle) }
        content.raw("</office:automatic-styles>")
        content.raw("<office:body><office:spreadsheet>")
        // Comparisons ignore case and accept wildcards, as PuggleSheets' formulas do.
        content.raw("<table:calculation-settings table:case-sensitive=\"false\" table:search-criteria-must-apply-to-whole-cell=\"true\" "
            + "table:use-wildcards=\"true\" table:use-regular-expressions=\"false\" table:automatic-find-labels=\"false\"/>")
        if !validations.isEmpty {
            content.raw("<table:content-validations>")
            content.append(validations)
            content.raw("</table:content-validations>")
        }
        content.append(tables)
        ODSRules.writeNamedRanges(workbook.namedRanges, firstSheet: names[0], into: &content)
        if !databaseRanges.isEmpty {
            content.raw("<table:database-ranges>")
            content.append(databaseRanges)
            content.raw("</table:database-ranges>")
        }
        let pivots = ODSPivotTables.write(book, names: names, into: &content)
        content.raw("</office:spreadsheet></office:body></office:document-content>")

        do {
            var zip = ZipWriter(date: date)
            // The media type comes first, uncompressed, so tools can recognize the file by its first bytes.
            try zip.add("mimetype", Data(mimetype.utf8), compress: false)
            try zip.add("META-INF/manifest.xml", manifest(drawings))
            try zip.add("content.xml", content.data)
            try zip.add("styles.xml", stylesPart(styles))
            try zip.add("meta.xml", metaPart(date: date))
            try zip.add("settings.xml", settingsPart(sheets, names: names, activeSheet: active, puggle: sheetSettings,
                                                     charts: drawings.chartExtras, pivots: pivots))
            for part in drawings.parts {
                // Pictures are compressed already.
                try zip.add(part.path, part.data, compress: part.mediaType == "text/xml")
            }
            return try zip.finish()
        } catch {
            throw SpreadsheetIOError.unwritable("This spreadsheet is too large to save as an OpenDocument spreadsheet.")
        }
    }

    // MARK: - Tables

    /// What a cell holds besides its value: an annotation (its note or comments), a link (as its
    /// `xlink:href`), frames, and its `table:formula` when it was written already.
    struct CellExtras {
        var annotation: String?
        var link: String?
        var frames: String?
        var formula: String?
    }

    /// The extras of a sheet's cells, by kind.
    struct CellExtrasList {
        var annotations: [CellAddress: String] = [:]
        var links: [CellAddress: String] = [:]
        var frames: [CellAddress: String] = [:]
        var formulas: [CellAddress: String] = [:]
    }

    private static func writeTable(_ sheet: Sheet, name: String, validationNames: [String?], styles: inout ODSStyleWriter,
                                   size: SheetSize, cellExtras: CellExtrasList, into xml: inout XMLWriter) throws {
        if sheet.cells.keys.contains(where: { $0.row >= maximumRows || $0.column >= maximumColumns }) {
            throw SpreadsheetIOError.unwritable("The sheet “\(name)” has cells beyond row 1,048,576 or column XFD, "
                + "which OpenDocument spreadsheets can't hold.")
        }
        // The grid, grown to hold everything the sheet has, within LibreOffice's limits.
        var rows = max(sheet.rowCount, 1), columns = max(sheet.columnCount, 1)
        for address in sheet.cells.keys {
            rows = max(rows, address.row + 1)
            columns = max(columns, address.column + 1)
        }
        for row in sheet.rowHeights.keys where row < maximumRows { rows = max(rows, row + 1) }
        for row in sheet.hiddenRows.union(sheet.filteredRows) where row < maximumRows { rows = max(rows, row + 1) }
        for column in sheet.columnWidths.keys where column < maximumColumns { columns = max(columns, column + 1) }
        for column in sheet.hiddenColumns where column < maximumColumns { columns = max(columns, column + 1) }
        for merge in sheet.merges where merge.end.row < maximumRows && merge.end.column < maximumColumns {
            rows = max(rows, merge.end.row + 1)
            columns = max(columns, merge.end.column + 1)
        }
        if let filter = sheet.filter, filter.range.end.row < maximumRows, filter.range.end.column < maximumColumns {
            rows = max(rows, filter.range.end.row + 1)
            columns = max(columns, filter.range.end.column + 1)
        }
        for table in sheet.tables where table.range.end.row < maximumRows && table.range.end.column < maximumColumns {
            rows = max(rows, table.range.end.row + 1)
            columns = max(columns, table.range.end.column + 1)
        }
        for group in sheet.rowGroups where group.range.upperBound < maximumRows { rows = max(rows, group.range.upperBound + 1) }
        for group in sheet.columnGroups where group.range.upperBound < maximumColumns { columns = max(columns, group.range.upperBound + 1) }
        var extras: [CellAddress: CellExtras] = [:]
        for (address, annotation) in cellExtras.annotations { extras[address, default: CellExtras()].annotation = annotation }
        for (address, href) in cellExtras.links { extras[address, default: CellExtras()].link = href }
        for (address, formula) in cellExtras.formulas { extras[address, default: CellExtras()].formula = formula }
        for (address, xml) in cellExtras.frames {
            extras[address, default: CellExtras()].frames = xml
            rows = max(rows, address.row + 1)
            columns = max(columns, address.column + 1)
        }
        var extraColumns: [Int: [Int]] = [:]
        for address in extras.keys { extraColumns[address.row, default: []].append(address.column) }
        let rowLimit = min(rows, maximumRows)
        let columnLimit = min(columns, maximumColumns)
        let export = SheetExport(sheet, rowLimit: rowLimit, columnLimit: columnLimit)

        let grid = CellRange(rows: 0...(rowLimit - 1), columns: 0...(columnLimit - 1))
        // A whole-sheet protection that refuses edits is a protected table, its exceptions cells whose style
        // leaves them editable. No password is set. PuggleSheets' settings keep every protection exactly.
        let sheetProtection = sheet.protections.first { protection in
            if case .sheet = protection.scope { return !protection.warningOnly }
            return false
        }
        var unprotected: [CellRange] = []
        if case .sheet(let except)? = sheetProtection?.scope { unprotected = except.compactMap { $0.intersection(grid) } }

        xml.raw("<table:table")
        xml.attribute("table:name", name)
        xml.raw(" table:style-name=\"\(styles.tableStyle(tabColor: sheet.tabColor))\"")
        if sheetProtection != nil { xml.raw(" table:protected=\"true\"") }
        xml.raw(">")
        var columnOutline = ODSOutline(sheet.columnGroups, limit: columnLimit, element: "table:table-column-group")
        writeColumns(sheet, count: columnLimit, outline: &columnOutline, styles: &styles, into: &xml)

        // Entries by row; merges as spans on their first cell and covered cells elsewhere.
        var rowEntries: [Int: [(column: Int, entry: SheetExport.Entry)]] = [:]
        for (address, entry) in export.entries { rowEntries[address.row, default: []].append((address.column, entry)) }
        var spans: [CellAddress: (columns: Int, rows: Int)] = [:]
        var coveredRows: [Int: [ClosedRange<Int>]] = [:]
        for merge in XLSXWriter.validMerges(sheet.merges) where merge.end.row < rowLimit && merge.end.column < columnLimit {
            spans[merge.start] = (merge.columnCount, merge.rowCount)
            for row in merge.rows { coveredRows[row, default: []].append(merge.columns) }
        }
        // Validations: the last rule for a cell wins.
        var validationRanges: [(range: CellRange, name: String)] = []
        for (rule, name) in zip(sheet.validations, validationNames) {
            guard let name else { continue }
            for range in rule.ranges { if let clipped = range.intersection(grid) { validationRanges.append((clipped, name)) } }
        }

        var interestingRows = Set(rowEntries.keys).union(sheet.rowHeights.keys).union(sheet.hiddenRows).union(sheet.filteredRows)
            .union(coveredRows.keys).union(extraColumns.keys)
        for (range, _) in validationRanges { interestingRows.formUnion(range.rows) }
        for range in unprotected { interestingRows.formUnion(range.rows) }
        interestingRows = interestingRows.filter { $0 >= 0 && $0 < rowLimit }
        var rowOutline = ODSOutline(sheet.rowGroups, limit: rowLimit, element: "table:table-row-group")
        // Rows are written up to each row with something, and to each group's start and end.
        let stops = interestingRows.union(rowOutline.boundaries.filter { $0 < rowLimit }).sorted()

        let defaultRowStyle = styles.rowStyle(height: sheet.defaultRowHeight)
        let emptyRowBody = "<table:table-cell table:number-columns-repeated=\"\(columnLimit)\"/>"
        var pending: (head: String, body: [UInt8], count: Int)?
        func flush(into xml: inout XMLWriter) {
            guard let row = pending else { return }
            xml.raw(row.count > 1 ? "<table:table-row \(row.head) table:number-rows-repeated=\"\(row.count)\">" : "<table:table-row \(row.head)>")
            xml.raw(String(decoding: row.body, as: UTF8.self))
            xml.raw("</table:table-row>")
            pending = nil
        }
        func add(head: String, body: [UInt8], count: Int, into xml: inout XMLWriter) {
            if let current = pending, current.head == head, current.body == body {
                pending?.count += count
            } else {
                flush(into: &xml)
                pending = (head, body, count)
            }
        }
        // Empty rows between, hidden inside collapsed groups (groups start and end at stops, so a run is all
        // inside a group or all outside it).
        func addEmptyRows(_ rows: Range<Int>, into xml: inout XMLWriter) {
            guard !rows.isEmpty else { return }
            let head = "table:style-name=\"\(defaultRowStyle)\"" + (rowOutline.isCollapsed(rows.lowerBound) ? " table:visibility=\"collapse\"" : "")
            add(head: head, body: Array(emptyRowBody.utf8), count: rows.count, into: &xml)
        }
        var nextRow = 0
        var rowBody = XMLWriter(fragmentCapacity: 1024)
        for row in stops {
            addEmptyRows(nextRow..<row, into: &xml)
            if rowOutline.boundaries.contains(row) {
                flush(into: &xml)
                rowOutline.writeTags(at: row, into: &xml)
            }
            nextRow = row
            guard interestingRows.contains(row) else { continue }
            var head = "table:style-name=\"\(styles.rowStyle(height: sheet.rowHeight(row)))\""
            if sheet.hiddenRows.contains(row) || rowOutline.isCollapsed(row) {
                head += " table:visibility=\"collapse\""
            } else if sheet.filteredRows.contains(row) {
                head += " table:visibility=\"filter\""
            }
            rowBody.removeAll()
            let rowValidations = validationRanges.filter { $0.range.rows.contains(row) }
            let rowUnprotected = unprotected.isEmpty ? [] : ODSOutline.merged(unprotected.filter { $0.rows.contains(row) }.map(\.columns))
            writeCells(row: row, entries: rowEntries[row] ?? [], spans: spans, covered: coveredRows[row] ?? [], validations: rowValidations,
                       unprotected: rowUnprotected, extras: extras, extraColumns: extraColumns[row] ?? [], columnLimit: columnLimit,
                       styles: &styles, size: size, into: &rowBody)
            add(head: head, body: rowBody.bytes, count: 1, into: &xml)
            nextRow = row + 1
        }
        addEmptyRows(nextRow..<rowLimit, into: &xml)
        flush(into: &xml)
        rowOutline.closeAll(into: &xml)

        ODSRules.writeConditionalFormats(sheet.conditionalFormats, sheet: name, styles: &styles, size: size, into: &xml)
        xml.raw("</table:table>")
    }

    /// Columns, in runs of the same width and visibility, inside their groups.
    private static func writeColumns(_ sheet: Sheet, count: Int, outline: inout ODSOutline, styles: inout ODSStyleWriter,
                                     into xml: inout XMLWriter) {
        var column = 0
        func isHidden(_ column: Int) -> Bool { sheet.hiddenColumns.contains(column) || outline.isCollapsed(column) }
        while column < count {
            if outline.boundaries.contains(column) { outline.writeTags(at: column, into: &xml) }
            let width = sheet.columnWidth(column)
            let hidden = isHidden(column)
            var end = column + 1
            while end < count, !outline.boundaries.contains(end), sheet.columnWidth(end) == width, isHidden(end) == hidden { end += 1 }
            xml.raw("<table:table-column table:style-name=\"\(styles.columnStyle(width: width))\"")
            if hidden { xml.raw(" table:visibility=\"collapse\"") }
            if end - column > 1 { xml.raw(" table:number-columns-repeated=\"\(end - column)\"") }
            xml.raw(" table:default-cell-style-name=\"Default\"/>")
            column = end
        }
        outline.closeAll(into: &xml)
    }

    /// One row's cells, from the first column to the last one with anything; runs of identical empty
    /// cells are repeated.
    private static func writeCells(row: Int, entries: [(column: Int, entry: SheetExport.Entry)], spans: [CellAddress: (columns: Int, rows: Int)],
                                   covered: [ClosedRange<Int>], validations: [(range: CellRange, name: String)], unprotected: [ClosedRange<Int>],
                                   extras: [CellAddress: CellExtras], extraColumns: [Int], columnLimit: Int, styles: inout ODSStyleWriter,
                                   size: SheetSize, into xml: inout XMLWriter) {
        var columns = Set(entries.map(\.column))
        for range in covered { columns.formUnion(range) }
        for item in validations { columns.formUnion(item.range.columns) }
        for range in unprotected { columns.formUnion(range) }
        columns.formUnion(extraColumns)
        let byColumn = Dictionary(entries.map { ($0.column, $0.entry) }, uniquingKeysWith: { first, _ in first })
        guard let last = columns.filter({ $0 < columnLimit }).max() else {
            xml.raw("<table:table-cell table:number-columns-repeated=\"\(columnLimit)\"/>")
            return
        }
        var empty: (attributes: String, count: Int)?
        func flushEmpty(into xml: inout XMLWriter) {
            guard let run = empty else { return }
            xml.raw("<table:table-cell\(run.attributes)")
            if run.count > 1 { xml.raw(" table:number-columns-repeated=\"\(run.count)\"") }
            xml.raw("/>")
            empty = nil
        }
        for column in 0...last {
            let address = CellAddress(row: row, column: column)
            let validation = validations.last { $0.range.columns.contains(column) }?.name
            let span = spans[address]
            let isCovered = span == nil && covered.contains { $0.contains(column) }
            let entry = byColumn[column]
            let style: String?
            if !unprotected.isEmpty, unprotected.contains(where: { $0.contains(column) }) {
                style = styles.unprotectedCellStyle(entry?.format ?? CellFormat())
            } else {
                style = entry.flatMap { styles.cellStyle($0.format) }
            }
            let extra = extraColumns.isEmpty ? nil : extras[address]
            if entry?.hasContent != true, span == nil, !isCovered, extra == nil {
                var attributes = ""
                if let style { attributes += " table:style-name=\"\(style)\"" }
                if let validation { attributes += " table:content-validation-name=\"\(validation)\"" }
                if let run = empty, run.attributes == attributes {
                    empty?.count += 1
                } else {
                    flushEmpty(into: &xml)
                    empty = (attributes, 1)
                }
                continue
            }
            flushEmpty(into: &xml)
            writeCell(entry, style: style, validation: validation, span: span, covered: isCovered, extra: extra, size: size, into: &xml)
        }
        flushEmpty(into: &xml)
        if last + 1 < columnLimit {
            xml.raw("<table:table-cell table:number-columns-repeated=\"\(columnLimit - last - 1)\"/>")
        }
    }

    private static func writeCell(_ entry: SheetExport.Entry?, style: String?, validation: String?, span: (columns: Int, rows: Int)?,
                                  covered: Bool, extra: CellExtras?, size: SheetSize, into xml: inout XMLWriter) {
        let element = covered ? "table:covered-table-cell" : "table:table-cell"
        xml.raw("<\(element)")
        if let style { xml.raw(" table:style-name=\"\(style)\"") }
        if let validation { xml.raw(" table:content-validation-name=\"\(validation)\"") }
        if let span {
            xml.raw(" table:number-columns-spanned=\"\(span.columns)\" table:number-rows-spanned=\"\(span.rows)\"")
        }
        guard let entry, entry.hasContent else {
            writeContent(nil, extra: extra, element: element, into: &xml)
            return
        }
        if let formula = extra?.formula ?? entry.formula.flatMap({ ODSFormula.exporting($0, size: size) }) {
            xml.attribute("table:formula", formula)
            if let spill = entry.spillRange {
                xml.raw(" table:number-matrix-columns-spanned=\"\(spill.columnCount)\" table:number-matrix-rows-spanned=\"\(spill.rowCount)\"")
            }
        }
        let isFormula = entry.formula != nil
        var shown: String?
        switch entry.value {
        case .empty:
            break
        case .number(let number) where number.isFinite:
            let pattern = entry.format.numberFormat
            switch NumberFormatPresets.kind(of: pattern) {
            case .date, .dateTime:
                if let date = isoDate(number) {
                    xml.raw(" office:value-type=\"date\" office:date-value=\"\(date)\" calcext:value-type=\"date\"")
                } else {
                    xml.raw(" office:value-type=\"float\" office:value=\"\(XLSXValue.string(number))\" calcext:value-type=\"float\"")
                }
            case .time, .duration:
                xml.raw(" office:value-type=\"time\" office:time-value=\"\(isoDuration(number))\" calcext:value-type=\"time\"")
            case .percent:
                xml.raw(" office:value-type=\"percentage\" office:value=\"\(XLSXValue.string(number))\" calcext:value-type=\"percentage\"")
            case .currency, .accounting:
                xml.raw(" office:value-type=\"currency\"")
                if let code = currencyCode(pattern) { xml.raw(" office:currency=\"\(code)\"") }
                xml.raw(" office:value=\"\(XLSXValue.string(number))\" calcext:value-type=\"currency\"")
            default:
                xml.raw(" office:value-type=\"float\" office:value=\"\(XLSXValue.string(number))\" calcext:value-type=\"float\"")
            }
            shown = CellDisplay.text(for: entry.value, pattern: pattern).text
        case .number:
            xml.raw(" office:value-type=\"string\" office:string-value=\"\" calcext:value-type=\"error\"")
            shown = CellError.Kind.number.rawValue
        case .text(let text):
            xml.raw(" office:value-type=\"string\"")
            if isFormula { xml.attribute("office:string-value", text) }
            xml.raw(" calcext:value-type=\"string\"")
            shown = text
        case .boolean(let value):
            xml.raw(" office:value-type=\"boolean\" office:boolean-value=\"\(value)\" calcext:value-type=\"boolean\"")
            shown = value ? "TRUE" : "FALSE"
        case .error(let error):
            xml.raw(" office:value-type=\"string\" office:string-value=\"\" calcext:value-type=\"error\"")
            shown = error.code
        }
        writeContent(shown, extra: extra, element: element, into: &xml)
    }

    /// The end of a cell's start tag and its content: its annotation, its text (inside its link), then its
    /// frames.
    private static func writeContent(_ shown: String?, extra: CellExtras?, element: String, into xml: inout XMLWriter) {
        let text = shown ?? ""
        guard !text.isEmpty || extra != nil else {
            xml.raw("/>")
            return
        }
        xml.raw(">")
        if let annotation = extra?.annotation { xml.raw(annotation) }
        if !text.isEmpty || extra?.link != nil { writeParagraphs(text, link: extra?.link, into: &xml) }
        if let frames = extra?.frames { xml.raw(frames) }
        xml.raw("</\(element)>")
    }

    /// Text as paragraphs, one per line. Spaces that ODF would collapse (at the start of a paragraph, or
    /// after another space) are written as text:s, tabs as text:tab.
    static func writeParagraphs(_ text: String, link: String? = nil, into xml: inout XMLWriter) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            xml.raw("<text:p>")
            if let link {
                xml.raw("<text:a")
                xml.attribute("xlink:href", link)
                xml.raw(" xlink:type=\"simple\">")
            }
            let needsCare = line.hasPrefix(" ") || line.contains("  ") || line.contains("\t")
            if !needsCare {
                xml.text(String(line))
            } else {
                var plain = ""
                var spaces = 0
                var atStart = true
                func flushSpaces() {
                    guard spaces > 0 else { return }
                    if atStart {
                        xml.text(plain)
                        plain = ""
                        xml.raw(spaces > 1 ? "<text:s text:c=\"\(spaces)\"/>" : "<text:s/>")
                    } else {
                        plain += " "
                        if spaces > 1 {
                            xml.text(plain)
                            plain = ""
                            xml.raw(spaces > 2 ? "<text:s text:c=\"\(spaces - 1)\"/>" : "<text:s/>")
                        }
                    }
                    spaces = 0
                    atStart = false
                }
                for character in line {
                    switch character {
                    case " ":
                        spaces += 1
                    case "\t":
                        flushSpaces()
                        xml.text(plain)
                        plain = ""
                        xml.raw("<text:tab/>")
                        atStart = false
                    default:
                        flushSpaces()
                        plain.append(character)
                        atStart = false
                    }
                }
                flushSpaces()
                xml.text(plain)
            }
            if link != nil { xml.raw("</text:a>") }
            xml.raw("</text:p>")
        }
    }

    /// "2026-11-16" or "2026-11-16T13:45:00.5" for a serial; nil outside years 1–9999.
    static func isoDate(_ serial: Double) -> String? {
        let parts = DateSerial.parts(of: serial)
        guard (1...9999).contains(parts.year) else { return nil }
        func pad(_ value: Int, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        var text = "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))"
        guard parts.hour != 0 || parts.minute != 0 || parts.second != 0 || parts.millisecond != 0 else { return text }
        text += "T\(pad(parts.hour, 2)):\(pad(parts.minute, 2)):\(pad(parts.second, 2))"
        if parts.millisecond != 0 { text += "." + pad(parts.millisecond, 3) }
        return text
    }

    /// "PT13H45M00S" for a fraction of a day (hours keep counting past 24).
    static func isoDuration(_ days: Double) -> String {
        let milliseconds = Int((abs(days) * 86_400_000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60000 % 60
        let seconds = milliseconds / 1000 % 60
        let fraction = milliseconds % 1000
        var text = (days < 0 ? "-PT" : "PT") + "\(hours)H" + (minutes < 10 ? "0" : "") + "\(minutes)M" + (seconds < 10 ? "0" : "") + "\(seconds)"
        if fraction != 0 { text += "." + String(format: "%03d", fraction) }
        return text + "S"
    }

    private static func currencyCode(_ pattern: String?) -> String? {
        guard let pattern else { return nil }
        let codes: [(Character, String)] = [("$", "USD"), ("€", "EUR"), ("£", "GBP"), ("¥", "JPY"), ("₹", "INR"), ("₩", "KRW"), ("₽", "RUB")]
        return codes.first { pattern.contains($0.0) }?.1
    }

    // MARK: - Other parts

    private static func manifest(_ drawings: ODSDrawingWriter) -> Data {
        var xml = XMLWriter()
        xml.raw("<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\">")
        xml.raw("<manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.3\" manifest:media-type=\"\(mimetype)\"/>")
        for part in ["content.xml", "styles.xml", "meta.xml", "settings.xml"] {
            xml.raw("<manifest:file-entry manifest:full-path=\"\(part)\" manifest:media-type=\"text/xml\"/>")
        }
        drawings.writeManifestEntries(into: &xml)
        xml.raw("</manifest:manifest>")
        return xml.data
    }

    private static func stylesPart(_ styles: ODSStyleWriter) -> Data {
        var xml = XMLWriter()
        xml.raw("<office:document-styles \(namespaces) office:version=\"1.3\">")
        xml.raw("<office:font-face-decls><style:font-face style:name=\"Arial\" svg:font-family=\"Arial\" style:font-family-generic=\"swiss\" "
            + "style:font-pitch=\"variable\"/></office:font-face-decls>")
        xml.raw("<office:styles>")
        xml.raw("<style:default-style style:family=\"table-cell\"><style:paragraph-properties style:tab-stop-distance=\"0.5in\"/>"
            + "<style:text-properties style:font-name=\"Arial\" fo:font-size=\"10pt\" fo:language=\"en\" fo:country=\"US\"/></style:default-style>")
        xml.raw("<number:number-style style:name=\"N0\"><number:number number:min-integer-digits=\"1\"/></number:number-style>")
        xml.raw("<style:style style:name=\"Default\" style:family=\"table-cell\"/>")
        styles.writeConditionalStyles(into: &xml)
        xml.raw("</office:styles>")
        xml.raw("<office:automatic-styles><style:page-layout style:name=\"pm1\"/></office:automatic-styles>")
        xml.raw("<office:master-styles><style:master-page style:name=\"Default\" style:page-layout-name=\"pm1\"/></office:master-styles>")
        xml.raw("</office:document-styles>")
        return xml.data
    }

    private static func metaPart(date: Date) -> Data {
        let stamp = date.formatted(.iso8601)
        var xml = XMLWriter()
        xml.raw("<office:document-meta \(namespaces) office:version=\"1.3\"><office:meta>")
        xml.raw("<meta:generator>PuggleSheets</meta:generator><meta:creation-date>\(stamp)</meta:creation-date><dc:date>\(stamp)</dc:date>")
        xml.raw("</office:meta></office:document-meta>")
        return xml.data
    }

    private static func settingsPart(_ sheets: [Sheet], names: [String], activeSheet: Int, puggle: [ODSSheetSettings],
                                     charts: [ODSChartExtras], pivots: [ODSPivotExtras]) -> Data {
        var xml = XMLWriter()
        xml.raw("<office:document-settings xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" "
            + "xmlns:config=\"urn:oasis:names:tc:opendocument:xmlns:config:1.0\" xmlns:ooo=\"http://openoffice.org/2004/office\" office:version=\"1.3\">")
        xml.raw("<office:settings><config:config-item-set config:name=\"ooo:view-settings\">")
        xml.raw("<config:config-item-map-indexed config:name=\"Views\"><config:config-item-map-entry>")
        xml.raw("<config:config-item config:name=\"ViewId\" config:type=\"string\">view1</config:config-item>")
        xml.raw("<config:config-item-map-named config:name=\"Tables\">")
        func item(_ name: String, _ type: String, _ value: String) {
            xml.raw("<config:config-item config:name=\"\(name)\" config:type=\"\(type)\">")
            xml.text(value)
            xml.raw("</config:config-item>")
        }
        for (index, sheet) in sheets.enumerated() {
            xml.raw("<config:config-item-map-entry")
            xml.attribute("config:name", names[index])
            xml.raw(">")
            let rows = min(max(sheet.frozenRows, 0), maximumRows - 1)
            let columns = min(max(sheet.frozenColumns, 0), maximumColumns - 1)
            item("HorizontalSplitMode", "short", columns > 0 ? "2" : "0")
            item("VerticalSplitMode", "short", rows > 0 ? "2" : "0")
            item("HorizontalSplitPosition", "int", String(columns))
            item("VerticalSplitPosition", "int", String(rows))
            item("ActiveSplitRange", "short", rows > 0 && columns > 0 ? "3" : rows > 0 ? "2" : columns > 0 ? "1" : "2")
            item("PositionLeft", "int", "0")
            item("PositionRight", "int", String(columns))
            item("PositionTop", "int", "0")
            item("PositionBottom", "int", String(rows))
            item("ShowGrid", "boolean", sheet.showsGridlines ? "true" : "false")
            xml.raw("</config:config-item-map-entry>")
        }
        xml.raw("</config:config-item-map-named>")
        item("ActiveTable", "string", names[activeSheet])
        item("ShowGrid", "boolean", sheets[activeSheet].showsGridlines ? "true" : "false")
        item("HasColumnRowHeaders", "boolean", "true")
        item("HasSheetTabs", "boolean", "true")
        xml.raw("</config:config-item-map-entry></config:config-item-map-indexed>")
        xml.raw("</config:config-item-set>")
        ODSPuggleSettings.write(sheets: puggle, charts: charts, pivots: pivots, into: &xml)
        xml.raw("</office:settings></office:document-settings>")
        return xml.data
    }
}
