import Foundation

/// Writes Excel workbooks: the smallest package that spreadsheet apps open without repairs.
enum XLSXWriter {
    static func write(_ workbook: Workbook, activeSheet: Int, date: Date = Date()) throws -> Data {
        let sheets = workbook.sheets.isEmpty ? [Sheet(name: "Sheet1")] : workbook.sheets
        let active = min(max(activeSheet, 0), sheets.count - 1)
        let names = XLSXSheetNames.sanitized(sheets.map(\.name))
        var styles = XLSXStyleWriter()
        var strings = XLSXSharedStringsWriter()
        // Sheet sizes by name, for closing open-ended ranges in formulas.
        var sizes: [String: (rows: Int, columns: Int)] = [:]
        for sheet in sheets where sizes[sheet.name.lowercased()] == nil {
            sizes[sheet.name.lowercased()] = (sheet.rowCount, sheet.columnCount)
        }
        func sizer(_ sheet: Sheet) -> (String?) -> (rows: Int, columns: Int) {
            { name in name.flatMap { sizes[$0.lowercased()] } ?? (sheet.rowCount, sheet.columnCount) }
        }
        // Drawings, charts, media, pivot tables and links, numbered across the workbook.
        let book = Workbook(sheets: sheets, namedRanges: workbook.namedRanges)
        var parts = XLSXExtraParts()
        var counters = XLSXPartCounters()
        var media = XLSXDrawingWriter.Media()
        var pivotCaches: [XLSXPivotWriter.Cache] = []
        var persons = XLSXComments.Persons()
        var commented: [[CellAddress]] = []
        var worksheets: [Data] = []
        var filters: [(sheet: Int, name: String, range: CellRange)] = []

        // Tables get Excel ids, valid names and column names before any sheet is written: formulas,
        // slicers and other sheets refer to them.
        var usedNames = Set(workbook.namedRanges.map { $0.name.lowercased() })
        var tableIDs: [UUID: Int] = [:], tableNames: [UUID: String] = [:], tableColumns: [UUID: [String]] = [:]
        for sheet in sheets {
            for table in sheet.tables where table.range.end.row < XLSXLimits.rows && table.range.end.column < XLSXLimits.columns
                && tableIDs[table.id] == nil {
                counters.tables += 1
                tableIDs[table.id] = counters.tables
                tableNames[table.id] = XLSXTables.validName(table.name, used: &usedNames)
                tableColumns[table.id] = XLSXTables.columnNames(table, sheet: sheet)
            }
        }
        let formulaTableNames = Set(sheets.flatMap { $0.tables.map { $0.name.lowercased() } })
        let slicers = XLSXSlicers.plan(book, tableIDs: tableIDs, columnNames: tableColumns)
        let nativeSlicers = Dictionary(slicers.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })

        for (index, sheet) in sheets.enumerated() {
            let features = XLSXCellFeatures(sheet)
            commented.append(features.commented)
            var relationships = XLSXRelationshipsWriter()
            var extras = WorksheetParts(tableNames: formulaTableNames)
            extras.hyperlinks = XLSXHyperlinks.write(sheet, linked: features.links, workbook: book, sheetNames: names, relationships: &relationships)
            var drawingContext = XLSXDrawingWriter.Context(workbook: book, sheetIndex: index, sheetNames: names)
            drawingContext.nativeSlicers = nativeSlicers
            if let target = XLSXDrawingWriter.write(sheet, cellImages: features.images, context: drawingContext,
                                                    counters: &counters, media: &media, parts: &parts) {
                extras.drawing = relationships.add(type: XLSXRelationshipType.drawing, target: target)
            }
            let pivotContext = XLSXPivotWriter.Context(workbook: book, sheetIndex: index, sheetNames: names)
            for (offset, pivot) in sheet.pivotTables.enumerated() {
                guard let written = XLSXPivotWriter.write(pivot, number: offset + 1, sheet: sheet, context: pivotContext,
                                                          counters: &counters, parts: &parts) else { continue }
                _ = relationships.add(type: XLSXRelationshipType.pivotTable, target: written.table)
                pivotCaches.append(written.cache)
            }
            extras.legacyDrawing = XLSXComments.write(sheet, commented: features.commented, counters: &counters, persons: &persons,
                                                      parts: &parts, relationships: &relationships)
            for table in sheet.tables {
                guard let id = tableIDs[table.id], let name = tableNames[table.id], let columns = tableColumns[table.id] else { continue }
                // A slicer's selection is its table's filter on that column. Where the table filters the
                // column too, rows either hides stay hidden: hidden values combine (conditions can't).
                var criteria = table.criteria
                for slicer in slicers where slicer.table == table.id && !slicer.criterion.isEmpty {
                    guard let existing = criteria[slicer.sheetColumn] else {
                        criteria[slicer.sheetColumn] = slicer.criterion
                        continue
                    }
                    if existing.condition == nil, slicer.criterion.condition == nil {
                        criteria[slicer.sheetColumn] = FilterCriterion(hiddenValues: existing.hiddenValues.union(slicer.criterion.hiddenValues))
                    }
                }
                parts.add("xl/tables/table\(id).xml", XLSXTables.part(table, name: name, id: id, columnNames: columns, criteria: criteria, sheet: sheet),
                          contentType: XLSXTables.contentType)
                extras.tableParts.append(relationships.add(type: XLSXTables.relationshipType, target: "../tables/table\(id).xml"))
                for (offset, column) in table.range.columns.enumerated() {
                    extras.headerNames[CellAddress(row: table.headerRow, column: column)] = columns[offset]
                }
            }
            let sheetSlicers = slicers.filter { $0.sheet == index }
            if !sheetSlicers.isEmpty {
                counters.slicerParts += 1
                let number = counters.slicerParts
                parts.add("xl/slicers/slicer\(number).xml", XLSXSlicers.slicerPart(sheetSlicers), contentType: XLSXSlicers.slicerContentType)
                let id = relationships.add(type: XLSXSlicers.slicerType, target: "../slicers/slicer\(number).xml")
                extras.extensions += XLSXSlicers.worksheetExtension(relationship: id)
            }
            // Excel's sheet filter can't overlap a table, which has a filter of its own.
            extras.writesSheetFilter = !(sheet.filter.map { filter in sheet.tables.contains { $0.range.intersects(filter.range) } } ?? false)
            worksheets.append(try worksheet(sheet, name: names[index], isActive: index == active, styles: &styles, strings: &strings,
                                            size: sizer(sheet), parts: extras))
            if !relationships.isEmpty { parts.add("xl/worksheets/_rels/sheet\(index + 1).xml.rels", relationships.data()) }
            if extras.writesSheetFilter, let filter = sheet.filter, let range = XLSXRules.clipped([filter.range]).first {
                filters.append((index, names[index], range))
            }
        }
        // Named ranges without a sheet belong to the first one.
        var definedNames = XMLWriter(fragmentCapacity: 256)
        XLSXRules.writeDefinedNames(workbook.namedRanges, filters: filters, slicerCaches: slicers.map(\.cacheName), size: sizer(sheets[0]),
                                    into: &definedNames)

        // The workbook's relationships: sheets first (rId1…), then styles, strings, pivot caches and filter views.
        let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        var relationships = XLSXRelationshipsWriter()
        for index in sheets.indices { _ = relationships.add(type: base + "worksheet", target: "worksheets/sheet\(index + 1).xml") }
        _ = relationships.add(type: base + "styles", target: "styles.xml")
        if !strings.isEmpty { _ = relationships.add(type: base + "sharedStrings", target: "sharedStrings.xml") }
        let caches = pivotCaches.map { (id: $0.id, relationship: relationships.add(type: XLSXRelationshipType.pivotCacheDefinition, target: $0.target)) }
        let slicerTables = Dictionary(slicers.map { ($0.objectID, tableNames[$0.table] ?? "") }, uniquingKeysWith: { first, _ in first })
        if let target = XLSXExtras.write(sheets, commented: commented, sheetNames: names, nativeSlicers: slicerTables, parts: &parts) {
            _ = relationships.add(type: XLSXRelationshipType.customXml, target: target)
        }
        if !persons.isEmpty {
            parts.add("xl/persons/person.xml", persons.part(), contentType: XLSXComments.personContentType)
            _ = relationships.add(type: XLSXComments.personType, target: "persons/person.xml")
        }
        var slicerCaches: [String] = []
        for slicer in slicers {
            counters.slicerCaches += 1
            let number = counters.slicerCaches
            parts.add("xl/slicerCaches/slicerCache\(number).xml", XLSXSlicers.cachePart(slicer), contentType: XLSXSlicers.slicerCacheContentType)
            slicerCaches.append(relationships.add(type: XLSXSlicers.slicerCacheType, target: "slicerCaches/slicerCache\(number).xml"))
        }

        do {
            var zip = ZipWriter(date: date)
            try zip.add("[Content_Types].xml", contentTypes(sheetCount: sheets.count, hasSharedStrings: !strings.isEmpty, parts: parts))
            try zip.add("_rels/.rels", packageRelationships())
            try zip.add("docProps/app.xml", appProperties())
            try zip.add("docProps/core.xml", coreProperties(date: date))
            try zip.add("xl/workbook.xml", workbookPart(names: names, activeSheet: active, definedNames: definedNames, pivotCaches: caches,
                                                        extensions: slicerCaches.isEmpty ? "" : XLSXSlicers.workbookExtension(relationships: slicerCaches)))
            try zip.add("xl/_rels/workbook.xml.rels", relationships.data())
            try zip.add("xl/styles.xml", styles.data())
            if !strings.isEmpty { try zip.add("xl/sharedStrings.xml", strings.data()) }
            for (index, part) in worksheets.enumerated() {
                try zip.add("xl/worksheets/sheet\(index + 1).xml", part)
            }
            for file in parts.files {
                // Images are compressed already.
                let compress = !(file.path.hasPrefix("xl/media/") && !file.path.hasSuffix(".xml"))
                try zip.add(file.path, file.data, compress: compress)
            }
            return try zip.finish()
        } catch {
            throw SpreadsheetIOError.unwritable("This spreadsheet is too large to save as an Excel workbook.")
        }
    }

    // MARK: - Worksheets

    /// What a worksheet part carries beyond its cells: elements pointing at other parts, table headers'
    /// names, extensions.
    struct WorksheetParts {
        var hyperlinks = XMLWriter(fragmentCapacity: 0)
        var drawing: String?
        var legacyDrawing: String?
        /// Relationship ids of the sheet's tables.
        var tableParts: [String] = []
        /// Table header cells and the column names they must show.
        var headerNames: [CellAddress: String] = [:]
        /// `<ext>` elements for `<extLst>`.
        var extensions = ""
        /// Lowercased names of the workbook's tables, for formulas.
        var tableNames: Set<String> = []
        var writesSheetFilter = true
    }

    static func worksheet(_ sheet: Sheet, name: String, isActive: Bool, styles: inout XLSXStyleWriter,
                          strings: inout XLSXSharedStringsWriter, size: (String?) -> (rows: Int, columns: Int),
                          parts: WorksheetParts = WorksheetParts()) throws -> Data {
        if sheet.cells.keys.contains(where: { $0.row >= XLSXLimits.rows || $0.column >= XLSXLimits.columns }) { throw tooBig(name) }
        // Typed cells, spilled results (as cached values, so Excel shows them) and banded fills.
        let cells = SheetExport(sheet, rowLimit: XLSXLimits.rows, columnLimit: XLSXLimits.columns)
        // A protected sheet's exceptions are unlocked cells, written even when empty.
        let protection = XLSXProtection.native(sheet)
        var entries = cells.entries
        if !protection.unlocked.isEmpty || !parts.headerNames.isEmpty {
            // Table headers show their column names as plain text, as Excel requires.
            var headers = parts.headerNames
            for index in entries.indices {
                guard let name = headers.removeValue(forKey: entries[index].address) else { continue }
                entries[index].entry.value = .text(name)
                entries[index].entry.formula = nil
                entries[index].entry.spillRange = nil
            }
            let written = Set(entries.map(\.address))
            entries += headers.map { (address: $0.key, entry: SheetExport.Entry(value: .text($0.value), formula: nil, format: CellFormat())) }
            entries += protection.unlocked.subtracting(written).subtracting(headers.keys).map { address in
                (address: address, entry: SheetExport.Entry(value: .empty, formula: nil, format: CellFormat()))
            }
            entries.sort { $0.address < $1.address }
        }
        let rowOutline = XLSXOutline.levels(sheet.rowGroups, limit: XLSXLimits.rows)
        let columnOutline = XLSXOutline.levels(sheet.columnGroups, limit: XLSXLimits.columns)

        var xml = XMLWriter(reservingCapacity: 256 + entries.count * 40)
        xml.raw("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">")
        let filtering = parts.writesSheetFilter && sheet.filter != nil && !sheet.filteredRows.isEmpty
        if sheet.tabColor != nil || filtering {
            xml.raw(filtering ? "<sheetPr filterMode=\"1\">" : "<sheetPr>")
            if let tabColor = sheet.tabColor { xml.raw("<tabColor rgb=\"FF\(tabColor.hex)\"/>") }
            xml.raw("</sheetPr>")
        }
        // The cells' extent, with table headers that were empty.
        var dimension = cells.usedRange
        for address in parts.headerNames.keys {
            dimension = dimension.map {
                CellRange(rows: min($0.start.row, address.row)...max($0.end.row, address.row),
                          columns: min($0.start.column, address.column)...max($0.end.column, address.column))
            } ?? CellRange(rows: address.row...address.row, columns: address.column...address.column)
        }
        xml.raw("<dimension ref=\"\(dimension?.a1 ?? "A1")\"/>")
        writeSheetView(sheet, isActive: isActive, into: &xml)
        xml.raw("<sheetFormatPr defaultColWidth=\"\(XLSXValue.string(XLSXUnits.columnWidth(fromPixels: sheet.defaultColumnWidth)))\" "
            + "defaultRowHeight=\"\(XLSXValue.string(XLSXUnits.points(fromPixels: sheet.defaultRowHeight)))\" customHeight=\"1\"")
        if rowOutline.maximum > 0 { xml.raw(" outlineLevelRow=\"\(rowOutline.maximum)\"") }
        if columnOutline.maximum > 0 { xml.raw(" outlineLevelCol=\"\(columnOutline.maximum)\"") }
        xml.raw("/>")
        writeColumns(sheet, outline: columnOutline, into: &xml)

        // Rows with cells, a height, an outline level, or hidden (by hand, the filter or a collapsed group), in order.
        let hiddenRows = sheet.hiddenRows.union(sheet.filteredRows).union(rowOutline.hidden)
        var rowSet = Set(sheet.rowHeights.keys).union(hiddenRows).union(rowOutline.levels.keys).union(rowOutline.collapsedMarks)
        for (address, _) in entries { rowSet.insert(address.row) }
        let rows = rowSet.filter { $0 >= 0 && $0 < XLSXLimits.rows }.sorted()
        var columnNames: [String] = []
        var next = 0
        xml.raw("<sheetData>")
        for row in rows {
            let number = String(row + 1)
            xml.raw("<row r=\"\(number)\"")
            if let height = sheet.rowHeights[row] {
                xml.raw(" ht=\"\(XLSXValue.string(XLSXUnits.points(fromPixels: height)))\" customHeight=\"1\"")
            }
            if hiddenRows.contains(row) { xml.raw(" hidden=\"1\"") }
            if let level = rowOutline.levels[row] { xml.raw(" outlineLevel=\"\(level)\"") }
            if rowOutline.collapsedMarks.contains(row) { xml.raw(" collapsed=\"1\"") }
            guard next < entries.count, entries[next].address.row == row else {
                xml.raw("/>")
                continue
            }
            xml.raw(">")
            while next < entries.count, entries[next].address.row == row {
                let (address, entry) = entries[next]
                while columnNames.count <= address.column { columnNames.append(CellAddress.columnName(columnNames.count)) }
                let unlocked = !protection.unlocked.isEmpty && protection.unlocked.contains(address)
                writeCell(entry, reference: columnNames[address.column] + number, unlocked: unlocked, styles: &styles, strings: &strings,
                          size: size, tableNames: parts.tableNames, into: &xml)
                next += 1
            }
            xml.raw("</row>")
        }
        xml.raw("</sheetData>")

        if protection.protects { xml.raw(XLSXProtection.sheetProtection) }
        if parts.writesSheetFilter, let filter = sheet.filter { XLSXRules.writeAutoFilter(filter, sheet: sheet, into: &xml) }
        let merges = validMerges(sheet.merges)
        if !merges.isEmpty {
            xml.raw("<mergeCells count=\"\(merges.count)\">")
            for merge in merges { xml.raw("<mergeCell ref=\"\(merge.a1)\"/>") }
            xml.raw("</mergeCells>")
        }
        XLSXRules.writeConditionalFormats(sheet.conditionalFormats, styles: &styles, size: size, into: &xml)
        XLSXRules.writeValidations(sheet.validations, size: size, into: &xml)
        xml.append(parts.hyperlinks)
        xml.raw("<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>")
        if let drawing = parts.drawing { xml.raw("<drawing r:id=\"\(drawing)\"/>") }
        if let legacyDrawing = parts.legacyDrawing { xml.raw("<legacyDrawing r:id=\"\(legacyDrawing)\"/>") }
        if !parts.tableParts.isEmpty {
            xml.raw("<tableParts count=\"\(parts.tableParts.count)\">")
            for id in parts.tableParts { xml.raw("<tablePart r:id=\"\(id)\"/>") }
            xml.raw("</tableParts>")
        }
        if !parts.extensions.isEmpty { xml.raw("<extLst>\(parts.extensions)</extLst>") }
        xml.raw("</worksheet>")
        return xml.data
    }

    /// Merges Excel accepts: inside its grid, more than one cell, not overlapping an earlier merge.
    static func validMerges(_ merges: [CellRange]) -> [CellRange] {
        var result: [CellRange] = []
        for merge in merges where !merge.isSingleCell && merge.start.row >= 0 && merge.start.column >= 0
            && merge.end.row < XLSXLimits.rows && merge.end.column < XLSXLimits.columns {
            // Overlaps are checked pairwise, which stays cheap for any realistic number of merges.
            if result.count < 5000, result.contains(where: { $0.intersects(merge) }) { continue }
            result.append(merge)
        }
        return result
    }

    private static func tooBig(_ name: String) -> SpreadsheetIOError {
        .unwritable("The sheet “\(name)” has cells beyond row 1,048,576 or column XFD, which Excel can't hold.")
    }

    private static func writeSheetView(_ sheet: Sheet, isActive: Bool, into xml: inout XMLWriter) {
        xml.raw("<sheetViews><sheetView")
        if !sheet.showsGridlines { xml.raw(" showGridLines=\"0\"") }
        if isActive { xml.raw(" tabSelected=\"1\"") }
        xml.raw(" workbookViewId=\"0\">")
        let rows = min(max(sheet.frozenRows, 0), XLSXLimits.rows - 1)
        let columns = min(max(sheet.frozenColumns, 0), XLSXLimits.columns - 1)
        if rows > 0 || columns > 0 {
            let topLeft = CellAddress(row: rows, column: columns).a1
            let pane = rows > 0 && columns > 0 ? "bottomRight" : rows > 0 ? "bottomLeft" : "topRight"
            xml.raw("<pane")
            if columns > 0 { xml.raw(" xSplit=\"\(columns)\"") }
            if rows > 0 { xml.raw(" ySplit=\"\(rows)\"") }
            xml.raw(" topLeftCell=\"\(topLeft)\" activePane=\"\(pane)\" state=\"frozen\"/>")
            if rows > 0, columns > 0 {
                let right = CellAddress(row: 0, column: columns).a1
                let bottom = CellAddress(row: rows, column: 0).a1
                xml.raw("<selection pane=\"topRight\" activeCell=\"\(right)\" sqref=\"\(right)\"/>")
                xml.raw("<selection pane=\"bottomLeft\" activeCell=\"\(bottom)\" sqref=\"\(bottom)\"/>")
            }
            xml.raw("<selection pane=\"\(pane)\" activeCell=\"\(topLeft)\" sqref=\"\(topLeft)\"/>")
        } else {
            xml.raw("<selection activeCell=\"A1\" sqref=\"A1\"/>")
        }
        xml.raw("</sheetView></sheetViews>")
    }

    /// `<col>` spans for columns with their own width, hidden or grouped, consecutive equal columns merged.
    private static func writeColumns(_ sheet: Sheet, outline: XLSXOutline.Levels, into xml: inout XMLWriter) {
        let hiddenColumns = sheet.hiddenColumns.union(outline.hidden)
        let columns = Set(sheet.columnWidths.keys).union(hiddenColumns).union(outline.levels.keys).union(outline.collapsedMarks)
            .filter { $0 >= 0 && $0 < XLSXLimits.columns }.sorted()
        guard !columns.isEmpty else { return }
        struct Span { var first: Int; var last: Int; var width: Double?; var hidden: Bool; var level: Int; var collapsed: Bool }
        var spans: [Span] = []
        for column in columns {
            let width = sheet.columnWidths[column]
            let hidden = hiddenColumns.contains(column)
            let level = outline.levels[column] ?? 0, collapsed = outline.collapsedMarks.contains(column)
            if var span = spans.last, span.last == column - 1, span.width == width, span.hidden == hidden, span.level == level,
               span.collapsed == collapsed {
                span.last = column
                spans[spans.count - 1] = span
            } else {
                spans.append(Span(first: column, last: column, width: width, hidden: hidden, level: level, collapsed: collapsed))
            }
        }
        xml.raw("<cols>")
        for span in spans {
            let width = XLSXUnits.columnWidth(fromPixels: span.width ?? sheet.defaultColumnWidth)
            xml.raw("<col min=\"\(span.first + 1)\" max=\"\(span.last + 1)\" width=\"\(XLSXValue.string(width))\"")
            if span.width != nil { xml.raw(" customWidth=\"1\"") }
            if span.hidden { xml.raw(" hidden=\"1\"") }
            if span.level > 0 { xml.raw(" outlineLevel=\"\(span.level)\"") }
            if span.collapsed { xml.raw(" collapsed=\"1\"") }
            xml.raw("/>")
        }
        xml.raw("</cols>")
    }

    private static func writeCell(_ cell: SheetExport.Entry, reference: String, unlocked: Bool, styles: inout XLSXStyleWriter,
                                  strings: inout XLSXSharedStringsWriter, size: (String?) -> (rows: Int, columns: Int),
                                  tableNames: Set<String>, into xml: inout XMLWriter) {
        xml.raw("<c r=\"\(reference)\"")
        let style = styles.index(for: cell.format, unlocked: unlocked)
        if style != 0 { xml.raw(" s=\"\(style)\"") }

        if let formula = cell.formula.flatMap({ XLSXFormula.exporting($0, size: size, tableNames: tableNames) }) {
            // The formula and its last result, typed so other apps show it before recalculating.
            switch cell.value {
            case .empty:
                xml.raw(">")
            case .number(let number) where number.isFinite:
                xml.raw(">")
            case .number:
                xml.raw(" t=\"e\">")
            case .text:
                xml.raw(" t=\"str\">")
            case .boolean:
                xml.raw(" t=\"b\">")
            case .error:
                xml.raw(" t=\"e\">")
            }
            // A formula whose result spills is an array formula over the spill, so Excel shows every value.
            xml.raw(cell.spillRange.map { "<f t=\"array\" ref=\"\($0.a1)\">" } ?? "<f>")
            xml.text(formula)
            xml.raw("</f>")
            switch cell.value {
            case .empty:
                break
            case .number(let number):
                xml.raw(number.isFinite ? "<v>\(XLSXValue.string(number))</v>" : "<v>#NUM!</v>")
            case .text(let text):
                xml.raw("<v>")
                xml.text(XLSXText.encode(text))
                xml.raw("</v>")
            case .boolean(let value):
                xml.raw(value ? "<v>1</v>" : "<v>0</v>")
            case .error(let error):
                xml.raw("<v>\(errorCode(error))</v>")
            }
            xml.raw("</c>")
            return
        }

        switch cell.value {
        case .empty:
            xml.raw("/>")
        case .number(let number) where number.isFinite:
            xml.raw("><v>\(XLSXValue.string(number))</v></c>")
        case .number:
            xml.raw(" t=\"e\"><v>#NUM!</v></c>")
        case .text(let text):
            xml.raw(" t=\"s\"><v>\(strings.index(of: text))</v></c>")
        case .boolean(let value):
            xml.raw(value ? " t=\"b\"><v>1</v></c>" : " t=\"b\"><v>0</v></c>")
        case .error(let error):
            xml.raw(" t=\"e\"><v>\(errorCode(error))</v></c>")
        }
    }

    /// Excel knows the classic error codes only; a formula PuggleSheets couldn't parse (#ERROR!) is
    /// written as #NAME?, the closest one. Recalculating restores it.
    private static func errorCode(_ error: CellError) -> String {
        error.kind == .parse ? CellError.Kind.name.rawValue : error.code
    }

    // MARK: - Package parts

    private static func contentTypes(sheetCount: Int, hasSharedStrings: Bool, parts: XLSXExtraParts) -> Data {
        var xml = XMLWriter()
        xml.raw("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">")
        xml.raw("<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>")
        xml.raw("<Default Extension=\"xml\" ContentType=\"application/xml\"/>")
        for (fileExtension, contentType) in parts.defaults.sorted(by: { $0.key < $1.key }) {
            xml.raw("<Default")
            xml.attribute("Extension", fileExtension)
            xml.attribute("ContentType", contentType)
            xml.raw("/>")
        }
        for (part, contentType) in parts.overrides {
            xml.raw("<Override")
            xml.attribute("PartName", part)
            xml.attribute("ContentType", contentType)
            xml.raw("/>")
        }
        xml.raw("<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>")
        for index in 1...sheetCount {
            xml.raw("<Override PartName=\"/xl/worksheets/sheet\(index).xml\" "
                + "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>")
        }
        xml.raw("<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>")
        if hasSharedStrings {
            xml.raw("<Override PartName=\"/xl/sharedStrings.xml\" "
                + "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>")
        }
        xml.raw("<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>")
        xml.raw("<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>")
        xml.raw("</Types>")
        return xml.data
    }

    private static func packageRelationships() -> Data {
        var xml = XMLWriter()
        xml.raw("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">")
        xml.raw("<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>")
        xml.raw("<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>")
        xml.raw("<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>")
        xml.raw("</Relationships>")
        return xml.data
    }

    private static func appProperties() -> Data {
        var xml = XMLWriter()
        xml.raw("<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" "
            + "xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">")
        xml.raw("<Application>PuggleSheets</Application></Properties>")
        return xml.data
    }

    private static func coreProperties(date: Date) -> Data {
        let stamp = date.formatted(.iso8601)
        var xml = XMLWriter()
        xml.raw("<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" "
            + "xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">")
        xml.raw("<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:created>")
        xml.raw("<dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:modified>")
        xml.raw("</cp:coreProperties>")
        return xml.data
    }

    private static func workbookPart(names: [String], activeSheet: Int, definedNames: XMLWriter,
                                     pivotCaches: [(id: Int, relationship: String)], extensions: String) -> Data {
        var xml = XMLWriter()
        xml.raw("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">")
        xml.raw("<workbookPr/>")
        xml.raw("<bookViews><workbookView xWindow=\"0\" yWindow=\"0\" windowWidth=\"28800\" windowHeight=\"16000\" activeTab=\"\(activeSheet)\"/></bookViews>")
        xml.raw("<sheets>")
        for (index, name) in names.enumerated() {
            xml.raw("<sheet")
            xml.attribute("name", name)
            xml.raw(" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>")
        }
        xml.raw("</sheets>")
        xml.append(definedNames)
        xml.raw("<calcPr fullCalcOnLoad=\"1\"/>")
        if !pivotCaches.isEmpty {
            xml.raw("<pivotCaches>")
            for cache in pivotCaches { xml.raw("<pivotCache cacheId=\"\(cache.id)\" r:id=\"\(cache.relationship)\"/>") }
            xml.raw("</pivotCaches>")
        }
        if !extensions.isEmpty { xml.raw("<extLst>\(extensions)</extLst>") }
        xml.raw("</workbook>")
        return xml.data
    }
}

/// The cells of a sheet that need parts of their own (links, images, notes and comments), found in one
/// pass so each writer looks only at its own.
struct XLSXCellFeatures {
    private(set) var links: [CellAddress] = []
    private(set) var images: [CellAddress] = []
    /// Cells with a note or a comment thread.
    private(set) var commented: [CellAddress] = []

    init(_ sheet: Sheet) {
        for (address, cell) in sheet.cells {
            if cell.link != nil { links.append(address) }
            if cell.image != nil { images.append(address) }
            if cell.note != nil || cell.comment != nil { commented.append(address) }
        }
    }
}

/// The shared string table: each distinct text once, cells refer to it by index.
struct XLSXSharedStringsWriter {
    private var indexes: [String: Int] = [:]
    private var strings: [String] = []
    private var references = 0

    var isEmpty: Bool { strings.isEmpty }

    mutating func index(of text: String) -> Int {
        references += 1
        if let index = indexes[text] { return index }
        strings.append(text)
        indexes[text] = strings.count - 1
        return strings.count - 1
    }

    /// xl/sharedStrings.xml.
    func data() -> Data {
        var xml = XMLWriter(reservingCapacity: 128 + strings.count * 24)
        xml.raw("<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"\(references)\" uniqueCount=\"\(strings.count)\">")
        for text in strings {
            xml.raw(XLSXText.needsPreservedSpace(text) ? "<si><t xml:space=\"preserve\">" : "<si><t>")
            xml.text(XLSXText.encode(text))
            xml.raw("</t></si>")
        }
        xml.raw("</sst>")
        return xml.data
    }
}

/// Excel's rules for sheet names.
enum XLSXSheetNames {
    static let maximumLength = 31

    /// Names Excel accepts: at most 31 characters, none of `[ ] : * ? / \`, not starting or ending with
    /// an apostrophe, unique ignoring case. Valid names are kept as they are.
    static func sanitized(_ names: [String], maximumLength: Int = XLSXSheetNames.maximumLength) -> [String] {
        var used = Set<String>()
        var result: [String] = []
        for (index, name) in names.enumerated() {
            var clean = String(String.UnicodeScalarView(name.unicodeScalars.filter { scalar in
                !"[]:*?/\\".unicodeScalars.contains(scalar) && scalar.value >= 0x20 && scalar.value != 0xFFFE && scalar.value != 0xFFFF
            }))
            while clean.hasPrefix("'") { clean.removeFirst() }
            while clean.hasSuffix("'") { clean.removeLast() }
            if clean.trimmingCharacters(in: .whitespaces).isEmpty { clean = "Sheet\(index + 1)" }
            clean = truncated(clean, to: maximumLength)
            var candidate = clean
            var number = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(number))"
                candidate = truncated(clean, to: maximumLength - suffix.utf16.count) + suffix
                number += 1
            }
            used.insert(candidate.lowercased())
            result.append(candidate)
        }
        return result
    }

    /// The longest prefix of whole characters within `length` UTF-16 units.
    private static func truncated(_ text: String, to length: Int) -> String {
        guard text.utf16.count > length else { return text }
        var result = ""
        for character in text {
            guard result.utf16.count + character.utf16.count <= length else { break }
            result.append(character)
        }
        return result
    }
}
