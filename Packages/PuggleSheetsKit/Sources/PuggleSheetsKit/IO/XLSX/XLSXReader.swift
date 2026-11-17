import Foundation

/// Messages for files that can't be opened.
enum XLSXMessages {
    static let notAWorkbook = "This file isn't an Excel workbook, or it's damaged."
    static let legacyOrEncrypted = "This file is password-protected or uses the older Excel 97–2003 format (.xls), "
        + "which PuggleSheets can't open. Save it as an Excel workbook (.xlsx) without a password and try again."
    static let damaged = "This Excel file is damaged and can't be opened."
    static let unsupported = "This Excel file is stored in a way PuggleSheets can't open."
    static let tooLarge = "This file is too large to open."

    static func damagedSheet(_ name: String) -> String {
        "The sheet “\(name)” in this file is damaged, so the file can't be opened."
    }

    static func readError(for error: Error) -> SpreadsheetIOError {
        if let error = error as? SpreadsheetIOError { return error }
        switch error as? ZipError {
        case .notAZip: return .unreadable(notAWorkbook)
        case .unsupported: return .unreadable(unsupported)
        case .tooLarge: return .unreadable(tooLarge)
        case .damaged, nil: return .unreadable(damaged)
        }
    }
}

/// Reads Excel workbooks (.xlsx, also .xlsm and strict Open XML).
enum XLSXReader {
    static func read(_ data: Data) throws -> SpreadsheetFile {
        // Encrypted workbooks and .xls files are OLE compound documents.
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            throw SpreadsheetIOError.unreadable(XLSXMessages.legacyOrEncrypted)
        }
        do {
            var reader = WorkbookReader(zip: try ZipReader(data: data))
            return try reader.read()
        } catch {
            throw XLSXMessages.readError(for: error)
        }
    }

    private struct WorkbookReader {
        let zip: ZipReader
        var warnings: Set<ImportWarning> = []
        var namedRanges: [NamedRange] = []
        /// Slicer caches by name: the table and column (Excel's ids) each filters, nil for those on pivot tables.
        var slicerCaches: [String: (table: Int, column: Int)?] = [:]
        /// Tables by Excel id: their sheet, position in it and column ids, for slicers.
        var tablesByID: [Int: (sheet: Int, index: Int, columns: [Int])] = [:]
        /// Each sheet's slicer frames (from its drawing) and slicers (from its slicer parts).
        var slicerFrames: [Int: [XLSXDrawingReader.SlicerFrame]] = [:]
        var sheetSlicers: [Int: [String: (cache: String, caption: String)]] = [:]

        init(zip: ZipReader) {
            self.zip = zip
        }

        mutating func read() throws -> SpreadsheetFile {
            let workbookPath = try findWorkbook()
            guard let workbookData = try zip.read(workbookPath) else { throw SpreadsheetIOError.unreadable(XLSXMessages.notAWorkbook) }
            let workbook = try XMLTree.parse(workbookData)
            guard workbook.name == "workbook" else { throw SpreadsheetIOError.unreadable(XLSXMessages.notAWorkbook) }
            let relationships = try XLSXPackage.relationships(of: workbookPath, in: zip)
            var relationshipsByID: [String: XLSXRelationship] = [:]
            for relationship in relationships where relationshipsByID[relationship.id] == nil {
                relationshipsByID[relationship.id] = relationship
            }

            var context = XLSXWorksheetContext()
            let theme = loadTheme(relationships)
            if let path = relationships.first(where: { $0.hasType("styles") && !$0.isExternal })?.target, let data = try zip.read(path) {
                context.styles = try XLSXStyleSheet.parse(data, theme: theme)
            } else {
                context.styles = XLSXStyleSheet(palette: XLSXColorPalette(theme: theme))
            }
            if let path = relationships.first(where: { $0.hasType("sharedStrings") && !$0.isExternal })?.target,
               let data = try zip.read(path) {
                let shared = try XLSXSharedStringsParser.parse(data)
                context.sharedStrings = shared.strings
                if shared.hasRichText { warnings.insert(.richText) }
            }
            context.uses1904Dates = XLSXValue.isTrue(workbook.child("workbookPr")?["date1904"])
            for relationship in relationships where relationship.hasType("slicerCache") && !relationship.isExternal {
                if let data = try? zip.read(relationship.target), let cache = XLSXSlicers.cache(data) {
                    slicerCaches[cache.name] = .some(cache.table.map { (table: $0.id, column: $0.column) })
                }
            }
            noteWorkbookFeatures(workbook, relationships)

            var sheets: [Sheet] = []
            var usedNames = Set<String>()
            /// For each sheet entry in the file, the index of the closest sheet kept.
            var keptIndex: [Int] = []
            /// The kept sheets' parts and links, for the pass after every sheet is read.
            var kept: [(path: String, hyperlinks: [XLSXHyperlinkEntry])] = []
            /// Kept sheets by the file's `sheetId` and by the name the file gives them (lowercased).
            var sheetIDs: [Int: Int] = [:]
            var fileNames: [String: Int] = [:]
            for (position, node) in (workbook.child("sheets")?.children("sheet") ?? []).enumerated() {
                defer { keptIndex.append(max(sheets.count - 1, 0)) }
                guard let id = node["id"], let relationship = relationshipsByID[id], !relationship.isExternal else {
                    throw SpreadsheetIOError.unreadable(XLSXMessages.damaged)
                }
                if relationship.hasType("chartsheet") {
                    warnings.insert(.charts)
                    continue
                }
                if relationship.hasType("dialogsheet") || relationship.hasType("xlMacrosheet") || relationship.hasType("xlIntlMacrosheet") {
                    warnings.insert(.macros)
                    continue
                }
                guard relationship.hasType("worksheet") else { continue }
                if let state = node["state"], state == "hidden" || state == "veryHidden" { warnings.insert(.hiddenSheets) }
                let name = Self.uniqueName(node["name"] ?? "", fallback: "Sheet\(position + 1)", used: &usedNames)
                guard let data = try zip.read(relationship.target) else {
                    throw SpreadsheetIOError.unreadable(XLSXMessages.damagedSheet(name))
                }
                do {
                    let parsed = try XLSXWorksheetParser.parse(data, name: name, context: context)
                    if let sheetID = XLSXValue.int(node["sheetId"]), sheetIDs[sheetID] == nil { sheetIDs[sheetID] = sheets.count }
                    let fileName = (node["name"] ?? name).lowercased()
                    if fileNames[fileName] == nil { fileNames[fileName] = sheets.count }
                    sheets.append(parsed.sheet)
                    kept.append((relationship.target, parsed.hyperlinks))
                    warnings.formUnion(parsed.warnings)
                } catch {
                    throw SpreadsheetIOError.unreadable(XLSXMessages.damagedSheet(name))
                }
            }

            // Links, drawings and pivot tables refer to other sheets: read once every sheet is known.
            var caches: [Int: String] = [:]
            for cache in workbook.child("pivotCaches")?.children("pivotCache") ?? [] {
                if let id = XLSXValue.int(cache["cacheId"]), let relationship = cache["id"].flatMap({ relationshipsByID[$0] }), !relationship.isExternal {
                    caches[id] = relationship.target
                }
            }
            // The people who wrote threaded comments.
            var persons: [String: String] = [:]
            if let path = relationships.first(where: { $0.hasType("person") && !$0.isExternal })?.target, let data = try? zip.read(path) {
                persons = XLSXComments.persons(data)
            }
            for index in sheets.indices {
                readSheetParts(index, path: kept[index].path, hyperlinks: kept[index].hyperlinks, sheets: &sheets, fileNames: fileNames,
                               theme: theme, caches: caches, persons: persons)
            }
            resolveSlicers(&sheets)
            // Excel's bare table names mean their data rows.
            let tableNames = Set(sheets.flatMap { $0.tables.map { $0.name.lowercased() } })
            if !tableNames.isEmpty {
                for index in sheets.indices {
                    var updates: [CellAddress: Cell] = [:]
                    for (address, cell) in sheets[index].cells {
                        guard let formula = cell.formula else { continue }
                        let qualified = XLSXFormula.qualifyingTableNames(formula, tableNames: tableNames)
                        if qualified != formula {
                            var updated = cell
                            updated.formula = qualified
                            updates[address] = updated
                        }
                    }
                    sheets[index].setCells(updates)
                }
            }
            readExtras(relationships, sheets: &sheets, sheetIDs: sheetIDs, fileNames: fileNames)

            var activeSheet = 0
            if let tab = XLSXValue.int(workbook.child("bookViews")?.child("workbookView")?["activeTab"]), !keptIndex.isEmpty {
                activeSheet = keptIndex[min(max(tab, 0), keptIndex.count - 1)]
            }
            let book = Workbook(sheets: sheets, namedRanges: namedRanges)
            return SpreadsheetFile(workbook: book, activeSheet: min(activeSheet, book.sheets.count - 1), warnings: warnings)
        }

        /// A sheet's links, drawing (images and charts) and pivot tables, and warnings for the parts
        /// that can't be kept (comments, tables, slicers, background pictures).
        private mutating func readSheetParts(_ index: Int, path: String, hyperlinks: [XLSXHyperlinkEntry], sheets: inout [Sheet],
                                             fileNames: [String: Int], theme: XLSXTheme, caches: [Int: String], persons: [String: String]) {
            let relationships = (try? XLSXPackage.relationships(of: path, in: zip)) ?? []
            var byID: [String: XLSXRelationship] = [:]
            for relationship in relationships where byID[relationship.id] == nil { byID[relationship.id] = relationship }

            if !hyperlinks.isEmpty {
                var ids: [String: UUID] = [:]
                for (name, sheetIndex) in fileNames { ids[name] = sheets[sheetIndex].id }
                for sheet in sheets where ids[sheet.name.lowercased()] == nil { ids[sheet.name.lowercased()] = sheet.id }
                if XLSXHyperlinks.apply(hyperlinks, to: &sheets[index], relationships: byID, sheetIDs: ids, namedRanges: namedRanges) {
                    warnings.insert(.hyperlinks)
                }
            }

            for relationship in relationships {
                if relationship.hasType("drawing") {
                    guard !relationship.isExternal else { continue }
                    // The contexts share the sheets' storage; they end before the sheet changes, so it isn't copied.
                    let drawing: XLSXDrawingReader.Result
                    do {
                        let charts = XLSXChartReader.Context(sheetIndex: index, sheets: sheets, sheetIndexes: fileNames, theme: theme)
                        drawing = XLSXDrawingReader.read(relationship.target, zip: zip, sheet: sheets[index], charts: charts)
                    }
                    warnings.formUnion(drawing.warnings)
                    sheets[index].objects.append(contentsOf: drawing.objects)
                    slicerFrames[index, default: []] += drawing.slicerFrames.map { frame in
                        var frame = frame
                        frame.position += sheets[index].objects.count - drawing.objects.count
                        return frame
                    }
                    for (address, image) in drawing.cellImages {
                        var cell = sheets[index][address]
                        cell.image = image
                        sheets[index][address] = cell
                    }
                    sheets[index].rowCount = max(sheets[index].rowCount, drawing.lastRow + 1)
                    sheets[index].columnCount = max(sheets[index].columnCount, drawing.lastColumn + 1)
                } else if relationship.hasType("pivotTable") {
                    guard !relationship.isExternal else { continue }
                    let result: XLSXPivotReader.Result
                    do {
                        let context = XLSXPivotReader.Context(sheetIndex: index, sheets: sheets, sheetIndexes: fileNames,
                                                              namedRanges: namedRanges, caches: caches)
                        result = XLSXPivotReader.read(relationship.target, zip: zip, context: context)
                    }
                    if result.unsupported { warnings.insert(.pivotTables) }
                    guard let pivot = result.pivot else { continue }
                    // The stored results would block the recomputed ones.
                    for range in result.cleared { sheets[index].removeCells(in: range) }
                    sheets[index].pivotTables.append(pivot)
                } else if relationship.hasType("table") {
                    guard !relationship.isExternal, let data = try? zip.read(relationship.target) else {
                        warnings.insert(.filters)
                        continue
                    }
                    let read = XLSXTables.read(data, sheet: sheets[index], theme: theme)
                    if read.unsupported { warnings.insert(.filters) }
                    guard let table = read.table else { continue }
                    if let id = read.id { tablesByID[id] = (index, sheets[index].tables.count, read.columnIDs) }
                    sheets[index].tables.append(table)
                    // Rows the table's filter hides are the filter's, not hidden by hand.
                    if !table.criteria.isEmpty, let rows = table.dataRange?.rows {
                        let filtered = sheets[index].hiddenRows.filter { rows.contains($0) }
                        sheets[index].hiddenRows.subtract(filtered)
                        sheets[index].filteredRows.formUnion(filtered)
                    }
                } else if relationship.hasType("slicer") {
                    if !relationship.isExternal, let data = try? zip.read(relationship.target) {
                        sheetSlicers[index, default: [:]].merge(XLSXSlicers.slicers(data)) { first, _ in first }
                    }
                } else if relationship.hasType("timeline") {
                    warnings.insert(.filters)
                } else if relationship.hasType("image") {
                    // A background picture.
                    warnings.insert(.images)
                }
            }
            readComments(relationships, sheet: &sheets[index], persons: persons)
        }

        /// Threads from threaded comments; other legacy comments are read as notes. A thread's legacy copy
        /// (its author "tc={id}") is left out.
        private mutating func readComments(_ relationships: [XLSXRelationship], sheet: inout Sheet, persons: [String: String]) {
            var threadRoots = Set<String>()
            for relationship in relationships where relationship.hasType("threadedComment") && !relationship.isExternal {
                guard let data = try? zip.read(relationship.target), let threads = XLSXComments.threads(data, persons: persons) else {
                    warnings.insert(.comments)
                    continue
                }
                for (address, item) in threads {
                    threadRoots.insert(item.root)
                    var cell = sheet[address]
                    cell.comment = item.thread
                    sheet[address] = cell
                }
            }
            for relationship in relationships where relationship.hasType("comments") && !relationship.isExternal {
                guard let data = try? zip.read(relationship.target), let comments = XLSXComments.legacyComments(data) else {
                    warnings.insert(.comments)
                    continue
                }
                for comment in comments {
                    if comment.author.hasPrefix("tc="), threadRoots.contains(XLSXComments.normalizedID(String(comment.author.dropFirst(3)))) {
                        continue
                    }
                    var cell = sheet[comment.address]
                    cell.note = XLSXText.normalizedLineBreaks(comment.text)
                    sheet[comment.address] = cell
                }
            }
        }

        /// Excel's table slicers as slicers on their tables: the frame in the drawing, the sheet's slicer list
        /// and the workbook's cache name the table and column. The slicer's selection is the table's filter
        /// on that column, which becomes the slicer's criterion. Slicers on pivot tables can't be kept.
        private mutating func resolveSlicers(_ sheets: inout [Sheet]) {
            // Table columns whose filter became slicers' criteria, removed from the tables afterwards.
            var moved: [(sheet: Int, table: Int, column: Int)] = []
            defer {
                for item in moved { sheets[item.sheet].tables[item.table].criteria[item.column] = nil }
            }
            for (sheetIndex, frames) in slicerFrames.sorted(by: { $0.key < $1.key }) {
                var inserted = 0
                for frame in frames.sorted(by: { $0.position < $1.position }) {
                    guard let slicer = sheetSlicers[sheetIndex]?[frame.name], let cache = slicerCaches[slicer.cache], let target = cache,
                          let table = tablesByID[target.table], let position = table.columns.firstIndex(of: target.column),
                          sheets[table.sheet].tables.indices.contains(table.index) else {
                        warnings.insert(.filters)
                        continue
                    }
                    let model = sheets[table.sheet].tables[table.index]
                    let column = model.range.start.column + position
                    guard model.range.columns.contains(column) else {
                        warnings.insert(.filters)
                        continue
                    }
                    let header = CellAddress(row: model.headerRow, column: column)
                    let headerText = CellDisplay.text(for: sheets[table.sheet].value(at: header), pattern: nil).text
                    // Excel's table slicers leave pivot tables alone.
                    let spec = SlicerSpec(range: model.name, column: position, title: slicer.caption == headerText ? "" : slicer.caption,
                                          criterion: model.criteria[column] ?? FilterCriterion(), appliesToPivotTables: false)
                    moved.append((table.sheet, table.index, column))
                    let object = SheetObject(anchor: frame.anchor, content: .slicer(spec), title: frame.title, altDescription: frame.description)
                    let at = min(frame.position + inserted, sheets[sheetIndex].objects.count)
                    sheets[sheetIndex].objects.insert(object, at: at)
                    inserted += 1
                }
            }
        }

        /// What PuggleSheets kept in its custom XML part: filter views, protections exactly as set (in place
        /// of the ones read from Excel's sheet protection), tables' ids, colors, column types and filters,
        /// slicers exactly as set, notes of cells with threads, thread details.
        private func readExtras(_ relationships: [XLSXRelationship], sheets: inout [Sheet], sheetIDs: [Int: Int], fileNames: [String: Int]) {
            // Slicers that live only in the part, on the sheets that hold them, for the rows they hide.
            var filtering: [(sheet: Int, spec: SlicerSpec)] = []
            defer { if !filtering.isEmpty { Self.markRowsFiltered(by: filtering, sheets: &sheets, namedRanges: namedRanges) } }
            for relationship in relationships where relationship.hasType("customXml") && !relationship.isExternal {
                guard let data = try? zip.read(relationship.target),
                      let extras = XLSXExtras.read(data, sheetIDs: sheetIDs, sheetNames: fileNames) else { continue }
                for (index, item) in extras where sheets.indices.contains(index) {
                    sheets[index].filterViews.append(contentsOf: item.filterViews)
                    if !item.protections.isEmpty { sheets[index].protections = item.protections }
                    // Tables keep their id, color, column types and filter exactly, and their range unless
                    // Excel's table changed.
                    sheets[index].tables = sheets[index].tables.map { table in
                        guard let details = item.tables[table.name.lowercased()] else { return table }
                        let range = details.range.flatMap { XLSXTables.excelRange($0) == table.range ? $0 : nil } ?? table.range
                        return SheetTable(id: details.id, name: table.name, range: range, columnTypes: details.columnTypes,
                                          color: details.color, criteria: details.criteria)
                    }
                    if !item.slicers.isEmpty { sheets[index].objects = Self.mergingSlicers(item.slicers, into: sheets[index].objects) }
                    for slicer in item.slicers where slicer.table == nil {
                        if case .slicer(let spec) = slicer.object.content, !spec.criterion.isEmpty { filtering.append((index, spec)) }
                    }
                    guard !item.notes.isEmpty || !item.threadIDs.isEmpty || !item.editedDates.isEmpty else { continue }
                    var updates: [CellAddress: Cell] = [:]
                    for (address, cell) in sheets[index].cells {
                        guard var thread = cell.comment, let first = thread.comments.first else { continue }
                        let root = first.id.uuidString
                        var updated = cell
                        if let note = item.notes[root] { updated.note = note }
                        if let id = item.threadIDs[root] { thread = CommentThread(id: id, comments: thread.comments, isResolved: thread.isResolved) }
                        for position in thread.comments.indices {
                            if let edited = item.editedDates[thread.comments[position].id.uuidString] { thread.comments[position].editedDate = edited }
                        }
                        updated.comment = thread
                        if updated != cell { updates[address] = updated }
                    }
                    sheets[index].setCells(updates)
                }
            }
        }

        /// Excel's file only knows rows as hidden: those inside the data rows of a slicer with a selection are
        /// the slicer's, not hidden by hand (as for filters). Excel's own slicers are on tables, whose rows
        /// are sorted out with the table.
        static func markRowsFiltered(by slicers: [(sheet: Int, spec: SlicerSpec)], sheets: inout [Sheet], namedRanges: [NamedRange]) {
            let workbook = Workbook(sheets: sheets, namedRanges: namedRanges)
            for (index, spec) in slicers {
                guard let target = workbook.resolve(spec.range, onSheet: index), target.range.rowCount > 1,
                      sheets.indices.contains(target.sheet) else { continue }
                let rows = (target.range.start.row + 1)...target.range.end.row
                let filtered = sheets[target.sheet].hiddenRows.filter { rows.contains($0) }
                sheets[target.sheet].hiddenRows.subtract(filtered)
                sheets[target.sheet].filteredRows.formUnion(filtered)
            }
        }

        /// A sheet's objects with the slicers kept in PuggleSheets' part instead of Excel's: exactly as they
        /// were, in their places among the other objects. One that was also written as an Excel slicer stays
        /// while the file still has an Excel slicer on its table column (it was deleted in Excel otherwise);
        /// Excel slicers that match none of them were added in Excel and stay too, in front.
        static func mergingSlicers(_ kept: [XLSXExtras.Slicer], into objects: [SheetObject]) -> [SheetObject] {
            func key(_ table: String, _ column: Int) -> String { table.lowercased() + "|" + String(column) }
            var result: [SheetObject] = []
            var excel: [(key: String, object: SheetObject)] = []
            for object in objects {
                if case .slicer(let spec) = object.content {
                    excel.append((key(spec.range, spec.column), object))
                } else {
                    result.append(object)
                }
            }
            var unmatched = Array(excel.indices)
            for slicer in kept.sorted(by: { $0.position < $1.position }) {
                if let table = slicer.table, case .slicer(let spec) = slicer.object.content {
                    guard let match = unmatched.firstIndex(where: { excel[$0].key == key(table, spec.column) }) else { continue }
                    unmatched.remove(at: match)
                }
                result.insert(slicer.object, at: min(slicer.position, result.count))
            }
            return result + unmatched.map { excel[$0].object }
        }

        /// The workbook part, through the package relationships (or its usual place).
        private func findWorkbook() throws -> String {
            let relationships = try XLSXPackage.relationships(of: "", in: zip)
            if let main = relationships.first(where: { $0.hasType("officeDocument") && !$0.isExternal }), zip.contains(main.target) {
                return main.target
            }
            guard zip.contains("xl/workbook.xml") else { throw SpreadsheetIOError.unreadable(XLSXMessages.notAWorkbook) }
            return "xl/workbook.xml"
        }

        /// The theme's colors and fonts; a missing or unreadable theme falls back to Office's.
        private func loadTheme(_ relationships: [XLSXRelationship]) -> XLSXTheme {
            guard let path = relationships.first(where: { $0.hasType("theme") && !$0.isExternal })?.target,
                  let data = try? zip.read(path), let theme = try? XLSXTheme.parse(data) else { return .office }
            return theme
        }

        private mutating func noteWorkbookFeatures(_ workbook: XNode, _ relationships: [XLSXRelationship]) {
            // Sheet-scoped names count sheets as the file lists them, chart sheets included.
            let sheetNames = (workbook.child("sheets")?.children("sheet") ?? []).map { $0["name"] ?? "" }
            let names = XLSXRules.namedRanges(workbook.child("definedNames")?.children("definedName") ?? [], sheetNames: sheetNames,
                                              ignoring: Set(slicerCaches.keys.map { $0.lowercased() }))
            namedRanges = names.ranges
            if names.unsupported { warnings.insert(.namedRanges) }
            if let protection = workbook.child("workbookProtection"),
               XLSXValue.isTrue(protection["lockStructure"]) || XLSXValue.isTrue(protection["lockWindows"]) {
                warnings.insert(.protection)
            }
            let contentTypes = (try? zip.read("[Content_Types].xml")).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let macroEnabled = contentTypes.contains("macroEnabled")
            if macroEnabled || relationships.contains(where: { $0.hasType("vbaProject") })
                || zip.entries.contains(where: { $0.path.lowercased().hasSuffix("vbaproject.bin") }) {
                warnings.insert(.macros)
            }
        }

        /// Sheet names must be unique (ignoring case) and not empty.
        private static func uniqueName(_ name: String, fallback: String, used: inout Set<String>) -> String {
            let base = name.isEmpty ? fallback : name
            var candidate = base
            var number = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(base) (\(number))"
                number += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }
}
