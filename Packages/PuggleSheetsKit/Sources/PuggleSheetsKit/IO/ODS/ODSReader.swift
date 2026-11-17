import Foundation

/// Messages for OpenDocument files that can't be opened.
enum ODSMessages {
    static let notASpreadsheet = "This file isn't an OpenDocument spreadsheet, or it's damaged."
    static let otherDocument = "This is an OpenDocument file, but not a spreadsheet."
    static let encrypted = "This spreadsheet is password-protected. Remove the password in LibreOffice and try again."
    static let damaged = "This OpenDocument spreadsheet is damaged and can't be opened."
    static let tooLarge = "This spreadsheet is too large to open: it has more than 10 million cells."

    static func readError(for error: Error) -> SpreadsheetIOError {
        if let error = error as? SpreadsheetIOError { return error }
        switch error as? ZipError {
        case .notAZip: return .unreadable(notASpreadsheet)
        case .tooLarge: return .unreadable(XLSXMessages.tooLarge)
        case .unsupported, .damaged, nil: return .unreadable(damaged)
        }
    }
}

/// The view settings of settings.xml that PuggleSheets keeps.
struct ODSSettings {
    struct SheetView {
        var frozenRows = 0
        var frozenColumns = 0
        var showsGrid: Bool?
        var tabColor: RGBColor?
    }

    var sheets: [String: SheetView] = [:]
    var activeTable: String?
    var showsGrid: Bool?

    static func parse(_ data: Data) throws -> ODSSettings {
        let root = try XMLTree.parse(data)
        var settings = ODSSettings()
        guard let view = root.descendants("config-item-set").first(where: { $0["name"] == "ooo:view-settings" }),
              let views = view.children("config-item-map-indexed").first(where: { $0["name"] == "Views" }),
              let entry = views.children("config-item-map-entry").first else { return settings }
        for item in entry.children("config-item") {
            switch item["name"] {
            case "ActiveTable": settings.activeTable = item.text
            case "ShowGrid": settings.showsGrid = item.text == "true"
            default: break
            }
        }
        for table in entry.children("config-item-map-named").first(where: { $0["name"] == "Tables" })?.children("config-item-map-entry") ?? [] {
            guard let name = table["name"] else { continue }
            var items: [String: String] = [:]
            for item in table.children("config-item") {
                if let key = item["name"] { items[key] = item.text }
            }
            var sheet = SheetView()
            if items["HorizontalSplitMode"] == "2", let columns = Int(items["HorizontalSplitPosition"] ?? ""), columns > 0 {
                sheet.frozenColumns = columns
            }
            if items["VerticalSplitMode"] == "2", let rows = Int(items["VerticalSplitPosition"] ?? ""), rows > 0 { sheet.frozenRows = rows }
            if let grid = items["ShowGrid"] { sheet.showsGrid = grid == "true" }
            if let color = items["TabColor"].flatMap({ Int($0) }), color >= 0, color <= 0xFF_FFFF {
                sheet.tabColor = RGBColor(red: UInt8(color >> 16 & 0xFF), green: UInt8(color >> 8 & 0xFF), blue: UInt8(color & 0xFF))
            }
            settings.sheets[name] = sheet
        }
        return settings
    }
}

/// Reads OpenDocument spreadsheets (.ods).
enum ODSReader {
    static func read(_ data: Data) throws -> SpreadsheetFile {
        do {
            return try readPackage(try ZipReader(data: data))
        } catch {
            throw ODSMessages.readError(for: error)
        }
    }

    private static func readPackage(_ zip: ZipReader) throws -> SpreadsheetFile {
        if let data = try? zip.read("mimetype") {
            let mimetype = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if mimetype.hasPrefix("application/vnd.oasis.opendocument."), !mimetype.contains("spreadsheet") {
                throw SpreadsheetIOError.unreadable(ODSMessages.otherDocument)
            }
        }
        var warnings = Set<ImportWarning>()
        if let data = try? zip.read("META-INF/manifest.xml"), let manifest = try? XMLTree.parse(data) {
            for entry in manifest.children("file-entry") {
                let path = entry["full-path"] ?? ""
                if path == "content.xml", entry.child("encryption-data") != nil { throw SpreadsheetIOError.unreadable(ODSMessages.encrypted) }
            }
        }
        if zip.entries.contains(where: { $0.path.hasPrefix("Basic/") || $0.path.hasPrefix("Scripts/") }) { warnings.insert(.macros) }
        guard let content = try zip.read("content.xml") else { throw SpreadsheetIOError.unreadable(ODSMessages.notASpreadsheet) }

        var styles = ODSStyleSheet()
        if let data = try zip.read("styles.xml") {
            let root = try XMLTree.parse(data)
            styles.addFontFaces(root.child("font-face-decls"))
            styles.addStyles(root.child("styles"))
        }
        let parser = ODSContentParser(styles: styles)
        guard XMLParsing.parse(content, delegate: parser) else {
            throw SpreadsheetIOError.unreadable(parser.isTooLarge ? ODSMessages.tooLarge : ODSMessages.damaged)
        }
        warnings.formUnion(parser.warnings)
        let settings = (try? zip.read("settings.xml")).flatMap { try? ODSSettings.parse($0) }

        var sheets: [Sheet] = []
        var fileNames: [String] = []
        var usedNames = Set<String>()
        for (position, table) in parser.tables.enumerated() {
            var sheet = table.sheet
            let fileName = sheet.name
            fileNames.append(fileName)
            sheet.name = uniqueName(fileName, fallback: "Sheet\(position + 1)", used: &usedNames)
            if let style = table.styleName.flatMap({ parser.styles.tableStyles[$0] }) {
                if style.hidden { warnings.insert(.hiddenSheets) }
                sheet.tabColor = style.tabColor
            }
            if let view = settings?.sheets[fileName] {
                sheet.frozenRows = min(view.frozenRows, sheet.rowCount - 1)
                sheet.frozenColumns = min(view.frozenColumns, sheet.columnCount - 1)
                if let grid = view.showsGrid ?? settings?.showsGrid { sheet.showsGridlines = grid }
                if sheet.tabColor == nil { sheet.tabColor = view.tabColor }
            } else if let grid = settings?.showsGrid {
                sheet.showsGridlines = grid
            }
            let validations = ODSRules.validations(parser.contentValidations, blocks: table.validationBlocks)
            sheet.validations = validations.rules
            if validations.unsupported { warnings.insert(.dataValidation) }
            let formats = ODSRules.conditionalFormats(table.conditionalFormats, sheetName: fileName, styles: parser.styles)
            sheet.conditionalFormats = formats.rules
            if formats.unsupported { warnings.insert(.conditionalFormatting) }
            // A protected table refuses edits everywhere but in the cells its styles leave editable.
            if table.isProtected { sheet.protections = [ProtectedRange(scope: .sheet(except: table.unprotected), warningOnly: false)] }
            sheets.append(sheet)
        }

        var nameSources: [(node: XNode, sheet: String?)] = []
        if let node = parser.namedExpressions { nameSources.append((node, nil)) }
        for (index, table) in parser.tables.enumerated() {
            if let node = table.namedExpressions { nameSources.append((node, fileNames[index])) }
        }
        let names = ODSRules.namedRanges(nameSources)
        if names.unsupported { warnings.insert(.namedRanges) }
        let puggle = (try? zip.read("settings.xml")).map(ODSPuggleSettings.parse) ?? ODSPuggleSettings.Contents()

        // Named database ranges with a header row are tables; the others with filter buttons, the sheet's filter.
        var takenNames = Set(names.ranges.map { $0.name.lowercased() })
        for item in ODSTables.databaseRanges(parser.databaseRanges) {
            let index = item.sheet.flatMap { name in fileNames.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame } } ?? (item.sheet == nil ? 0 : nil)
            guard let index, sheets.indices.contains(index) else { continue }
            if item.isTable {
                guard !sheets[index].tables.contains(where: { $0.range.intersection(item.range) != nil }),
                      let table = ODSTables.table(item, sheet: sheets[index], kept: puggle.sheets[fileNames[index]]?.tables.first { $0.rangeName == item.name },
                                                  usedNames: &takenNames, warnings: &warnings) else { continue }
                sheets[index].tables.append(table)
            } else {
                guard item.showsButtons, sheets[index].filter == nil else { continue }
                let result = ODSRules.filterCriteria(item.filter, range: item.range, sheet: sheets[index])
                if result.unsupported { warnings.insert(.filters) }
                sheets[index].filter = SheetFilter(range: item.range, criteria: result.criteria)
            }
            sheets[index].rowCount = max(sheets[index].rowCount, item.range.end.row + 1)
            sheets[index].columnCount = max(sheets[index].columnCount, item.range.end.column + 1)
        }

        var workbook = Workbook(sheets: sheets, namedRanges: names.ranges)
        readLinks(parser.tables, fileNames: fileNames, workbook: &workbook, warnings: &warnings)
        let drawings = ODSDrawingReader(zip: zip, fileNames: fileNames, chartExtras: puggle.charts)
        for (index, table) in parser.tables.enumerated() {
            drawings.read(table.frames, sheetIndex: index, workbook: &workbook, warnings: &warnings)
        }
        ODSPivotTables.read(parser.dataPilotTables, workbook: &workbook, fileNames: fileNames, extras: puggle.pivots, warnings: &warnings)
        for (index, name) in fileNames.enumerated() {
            guard let kept = puggle.sheets[name] else { continue }
            apply(kept, to: &workbook.sheets[index])
        }
        var active = 0
        if let name = settings?.activeTable, let index = fileNames.firstIndex(of: name) { active = index }
        return SpreadsheetFile(workbook: workbook, activeSheet: min(active, workbook.sheets.count - 1), warnings: warnings)
    }

    /// What PuggleSheets keeps for a sheet in its settings: filter views, comment threads (and what the
    /// cell's annotation held), protected ranges, rows and columns hidden inside collapsed groups, formulas
    /// as typed and slicers. (Tables are read with the database ranges.)
    private static func apply(_ kept: ODSSheetSettings, to sheet: inout Sheet) {
        sheet.filterViews = kept.filterViews
        for extras in kept.comments where extras.address.row < ODSContentParser.maximumRows && extras.address.column < ODSContentParser.maximumColumns {
            var cell = sheet[extras.address]
            // The annotation was written from the thread (and note): unless something changed it, it isn't a note.
            if cell.note == ODSAnnotations.text(note: extras.note, thread: extras.thread) { cell.note = extras.note }
            cell.comment = extras.thread
            sheet[extras.address] = cell
        }
        if !kept.protections.isEmpty { sheet.protections = kept.protections }
        // Inside the grid only.
        for range in kept.hiddenRows where range.lowerBound < sheet.rowCount { sheet.hiddenRows.formUnion(range.clamped(to: 0...(sheet.rowCount - 1))) }
        for range in kept.hiddenColumns where range.lowerBound < sheet.columnCount {
            sheet.hiddenColumns.formUnion(range.clamped(to: 0...(sheet.columnCount - 1)))
        }
        // Formulas with structured references, which the file has as the cells they cover: while unchanged.
        for formula in kept.formulas {
            guard var cell = sheet.cells[formula.address], let current = cell.formula, current == ODSFormula.importing(formula.fingerprint) else { continue }
            cell.formula = formula.formula
            sheet[formula.address] = cell
        }
        // Slicers, in their places among the objects.
        for slicer in kept.slicers.sorted(by: { $0.index < $1.index }) {
            var object = slicer.object
            object.anchor.cell = CellAddress(row: min(object.anchor.cell.row, ODSContentParser.maximumRows - 1),
                                             column: min(object.anchor.cell.column, ODSContentParser.maximumColumns - 1))
            sheet.objects.insert(object, at: min(slicer.index, sheet.objects.count))
        }
    }

    /// Links to places in the spreadsheet, once every sheet and named range is known.
    private static func readLinks(_ tables: [ODSParsedTable], fileNames: [String], workbook: inout Workbook, warnings: inout Set<ImportWarning>) {
        let sheets = zip(fileNames, workbook.sheets).map { (name: $0.0, id: $0.1.id) }
        for (index, table) in tables.enumerated() where !table.linkCells.isEmpty {
            var sheet = workbook.sheets[index]
            for address in table.linkCells {
                guard var cell = sheet.cells[address], let href = cell.link else { continue }
                cell.link = ODSLinks.link(forHref: href, sheets: sheets, namedRanges: workbook.namedRanges, currentSheet: index)
                // A mark naming nothing in the spreadsheet can't be kept.
                if cell.link == nil { warnings.insert(.hyperlinks) }
                sheet[address] = cell
            }
            workbook.sheets[index] = sheet
        }
    }

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
