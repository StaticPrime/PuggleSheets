import Foundation

/// What every worksheet of a workbook shares.
struct XLSXWorksheetContext: Sendable {
    var sharedStrings: [String] = []
    var styles = XLSXStyleSheet()
    /// Serial numbers count from 1904-01-01 (old Mac Excel) instead of 1899-12-30.
    var uses1904Dates = false

    /// Days between the two date systems' serial 0.
    static let date1904Offset = 1462.0
}

/// Streams one worksheet part (xl/worksheets/sheetN.xml) into a `Sheet`.
final class XLSXWorksheetParser: NSObject, XMLParserDelegate {
    private var sheet: Sheet
    private var warnings: Set<ImportWarning> = []
    private let context: XLSXWorksheetContext

    // Where we are.
    private var inSheetData = false
    private var inSheetProperties = false
    private var sheetViewCount = 0
    private var inFirstSheetView = false
    /// Nesting depth inside `<extLst>`, whose contents are only scanned for features.
    private var extensionDepth = 0
    /// Rules are small: they're kept as trees and converted once the cells are known.
    private var subtree: XNodeBuilder?
    private var validationNodes: [XNode] = []
    private var conditionalFormatNodes: [XNode] = []
    private var autoFilterNode: XNode?
    private var filterMode = false
    private var hyperlinks: [XLSXHyperlinkEntry] = []
    // Outlines and protection, applied once the sheet is read.
    private var rowLevels: [Int: Int] = [:]
    private var collapsedRows = Set<Int>()
    private var summaryBelow = true
    private var summaryRight = true
    private var isProtected = false
    private var editableRanges: [CellRange] = []
    private var unlockedCells: [CellAddress] = []

    // The current row and cell.
    private var currentRow = -1
    private var nextColumn = 0
    private var inCell = false
    private var cellAddress: CellAddress?
    private var cellStyle = 0
    private var cellType = CellType.number
    private var capture = Capture.none
    private var valueText = ""
    private var hasValue = false
    private var formulaText = ""
    private var hasFormula = false
    private var formulaKind = FormulaKind.normal
    private var formulaReference: String?
    private var formulaSharedIndex: String?
    private var inInlineString = false
    private var hasInlineString = false
    private var inlinePhoneticDepth = 0
    private var inlineText = ""
    private var inlineRun = ""
    private var inlinePreservesSpace = false

    // Layout gathered along the way, applied once the extent is known.
    private var columnSpans: [ColumnSpan] = []
    /// Custom row heights in points.
    private var rowHeights: [Int: Double] = [:]
    private var defaultColumnWidth: Double?
    private var baseColumnWidth: Double?
    private var defaultRowHeight: Double?
    private var lastRow = -1
    private var lastColumn = -1
    private var mergedRanges: Set<CellRange> = []
    private var arrayFormulas: [(master: CellAddress, range: CellRange)] = []
    private var sharedMasters: [String: (address: CellAddress, formula: XLSXShiftableFormula)] = [:]
    private var pendingShared: [(address: CellAddress, index: String)] = []

    private enum CellType {
        case number, sharedString, formulaString, inlineString, boolean, error, date

        init(_ attribute: String?) {
            switch attribute {
            case "s": self = .sharedString
            case "str": self = .formulaString
            case "inlineStr": self = .inlineString
            case "b": self = .boolean
            case "e": self = .error
            case "d": self = .date
            default: self = .number
            }
        }
    }

    private enum FormulaKind {
        case normal, shared, array, dataTable

        init(_ attribute: String?) {
            switch attribute {
            case "shared": self = .shared
            case "array": self = .array
            case "dataTable": self = .dataTable
            default: self = .normal
            }
        }
    }

    private enum Capture { case none, value, formula, inlineText }

    private struct ColumnSpan {
        var first: Int
        var last: Int
        var width: Double?
        var hidden: Bool
        var level = 0
        var collapsed = false
    }

    private init(name: String, context: XLSXWorksheetContext) {
        sheet = Sheet(name: name)
        self.context = context
    }

    static func parse(_ data: Data, name: String, context: XLSXWorksheetContext) throws
        -> (sheet: Sheet, warnings: Set<ImportWarning>, hyperlinks: [XLSXHyperlinkEntry]) {
        let parser = XLSXWorksheetParser(name: name, context: context)
        guard XMLParsing.parse(data, delegate: parser) else { throw MalformedXMLError() }
        parser.finish()
        return (parser.sheet, parser.warnings, parser.hyperlinks)
    }

    // MARK: - Elements

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if let subtree {
            subtree.start(elementName, attributeDict)
            return
        }
        if extensionDepth > 0 {
            extensionDepth += 1
            let local = XMLParsing.localName(elementName)
            if local == "dataValidations" {
                subtree = XNodeBuilder(rootName: elementName, attributes: attributeDict)
            } else {
                noteExtension(local)
            }
            return
        }
        start(elementName, attributeDict)
    }

    /// A rule element finished.
    private func captured(_ node: XNode) {
        switch node.name {
        case "dataValidations": validationNodes.append(node)
        case "conditionalFormatting": conditionalFormatNodes.append(node)
        case "autoFilter": autoFilterNode = node
        default: break
        }
    }

    private func start(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "c":
            if inSheetData { beginCell(attributes) }
        case "v":
            if inCell {
                capture = .value
                valueText = ""
                hasValue = true
            }
        case "f":
            if inCell { beginFormula(attributes) }
        case "is":
            if inCell {
                inInlineString = true
                hasInlineString = true
                inlineText = ""
            }
        case "t":
            if inInlineString, inlinePhoneticDepth == 0 {
                capture = .inlineText
                inlineRun = ""
                inlinePreservesSpace = attributes["xml:space"] == "preserve"
            }
        case "r":
            if inInlineString, inlinePhoneticDepth == 0 { warnings.insert(.richText) }
        case "rPh":
            if inInlineString { inlinePhoneticDepth += 1 }
        case "row":
            if inSheetData { beginRow(attributes) }
        case "sheetData":
            inSheetData = true
        case "col":
            readColumns(attributes)
        case "sheetFormatPr":
            defaultColumnWidth = XLSXValue.double(attributes["defaultColWidth"])
            baseColumnWidth = XLSXValue.double(attributes["baseColWidth"])
            defaultRowHeight = XLSXValue.double(attributes["defaultRowHeight"])
        case "sheetView":
            sheetViewCount += 1
            inFirstSheetView = sheetViewCount == 1
            if inFirstSheetView, let gridlines = attributes["showGridLines"] { sheet.showsGridlines = XLSXValue.isOn(gridlines) }
        case "pane":
            if inFirstSheetView { readPane(attributes) }
        case "sheetPr":
            inSheetProperties = true
            filterMode = XLSXValue.isTrue(attributes["filterMode"])
        case "tabColor":
            if inSheetProperties { sheet.tabColor = context.styles.palette.color(attributes) }
        case "outlinePr":
            if inSheetProperties {
                summaryBelow = XLSXValue.isOn(attributes["summaryBelow"])
                summaryRight = XLSXValue.isOn(attributes["summaryRight"])
            }
        case "mergeCell":
            readMerge(attributes)
        case "hyperlink":
            // Links are looked up once every sheet is read (they can point to other sheets).
            let id = attributes.first { $0.key == "id" || $0.key.hasSuffix(":id") }?.value
            hyperlinks.append(XLSXHyperlinkEntry(reference: attributes["ref"] ?? "", relationshipID: id, location: attributes["location"]))
        case "dataValidations", "conditionalFormatting", "autoFilter":
            subtree = XNodeBuilder(rootName: name, attributes: attributes)
        case "sheetProtection":
            // Password hashes are ignored: the protection is kept, never its password.
            isProtected = XLSXValue.isTrue(attributes["sheet"])
        case "protectedRange":
            // Ranges anyone may edit on the protected sheet.
            editableRanges += XLSXRules.ranges(attributes["sqref"] ?? "")
        case "picture":
            warnings.insert(.images)
        case "extLst":
            extensionDepth = 1
        default:
            if let local = XMLParsing.strippingPrefix(name) { start(local, attributes) }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let subtree {
            if subtree.end(), let root = subtree.root {
                self.subtree = nil
                captured(root)
                if extensionDepth > 0 { extensionDepth -= 1 }
            }
            return
        }
        if extensionDepth > 0 {
            extensionDepth -= 1
            return
        }
        end(elementName)
    }

    private func end(_ name: String) {
        switch name {
        case "c":
            if inCell { endCell() }
        case "v", "f":
            if capture == .value || capture == .formula { capture = .none }
        case "t":
            if capture == .inlineText {
                inlineText += inlinePreservesSpace ? inlineRun : XLSXText.trimmingXMLWhitespace(inlineRun)
                capture = .none
            }
        case "rPh":
            if inInlineString { inlinePhoneticDepth = max(0, inlinePhoneticDepth - 1) }
        case "is":
            inInlineString = false
        case "sheetData":
            inSheetData = false
        case "sheetView":
            inFirstSheetView = false
        case "sheetPr":
            inSheetProperties = false
        default:
            if let local = XMLParsing.strippingPrefix(name) { end(local) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let subtree {
            subtree.characters(string)
            return
        }
        switch capture {
        case .none: return
        case .value: valueText += string
        case .formula: formulaText += string
        case .inlineText: inlineRun += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        parser.abortParsing()
    }

    /// Features stored in extension lists (Excel 2010+ conditional formats, validations, sparklines…).
    private func noteExtension(_ name: String) {
        switch name {
        case "conditionalFormatting": warnings.insert(.conditionalFormatting)
        case "sparklineGroup": warnings.insert(.charts)
        case "timelineRefs": warnings.insert(.filters)
        default: break
        }
    }

    // MARK: - Rows and cells

    private func beginRow(_ attributes: [String: String]) {
        if let number = XLSXValue.int(attributes["r"]), number >= 1 {
            currentRow = min(number, XLSXLimits.rows + 1) - 1
        } else {
            currentRow = min(currentRow + 1, XLSXLimits.rows)
        }
        nextColumn = 0
        guard currentRow < XLSXLimits.rows else { return }
        let height = XLSXValue.double(attributes["ht"])
        let customHeight = XLSXValue.isTrue(attributes["customHeight"])
        if let level = XLSXValue.int(attributes["outlineLevel"]), level > 0 {
            rowLevels[currentRow] = min(level, XLSXOutline.maximumLevel)
            lastRow = max(lastRow, currentRow)
        }
        if XLSXValue.isTrue(attributes["collapsed"]) { collapsedRows.insert(currentRow) }
        if XLSXValue.isTrue(attributes["hidden"]) || (customHeight && height == 0) {
            sheet.hiddenRows.insert(currentRow)
            lastRow = max(lastRow, currentRow)
        }
        if customHeight, let height, height > 0 {
            rowHeights[currentRow] = height
            lastRow = max(lastRow, currentRow)
        }
    }

    private func beginCell(_ attributes: [String: String]) {
        inCell = true
        if let reference = attributes["r"] {
            cellAddress = XLSXWorksheetParser.address(reference)
        } else {
            let row = max(currentRow, 0)
            cellAddress = row < XLSXLimits.rows && nextColumn < XLSXLimits.columns ? CellAddress(row: row, column: nextColumn) : nil
        }
        if let cellAddress { nextColumn = cellAddress.column + 1 }
        cellStyle = attributes["s"].flatMap { Int($0) } ?? 0
        cellType = CellType(attributes["t"])
        // Rich values: Excel 365's pictures in cells and linked data types, stored apart from the cell.
        if attributes["vm"] != nil { warnings.insert(.images) }
        capture = .none
        valueText = ""
        hasValue = false
        formulaText = ""
        hasFormula = false
        inInlineString = false
        hasInlineString = false
        inlinePhoneticDepth = 0
        inlineText = ""
    }

    private func beginFormula(_ attributes: [String: String]) {
        capture = .formula
        hasFormula = true
        formulaText = ""
        formulaKind = FormulaKind(attributes["t"])
        formulaReference = attributes["ref"]
        formulaSharedIndex = attributes["si"]
    }

    private func endCell() {
        inCell = false
        capture = .none
        guard let address = cellAddress else { return }
        var cell = Cell(format: context.styles.format(at: cellStyle))

        switch cellType {
        case .number:
            if hasValue, let number = XLSXValue.double(valueText) {
                let shift = context.uses1904Dates && context.styles.showsDate(at: cellStyle) ? XLSXWorksheetContext.date1904Offset : 0
                cell.value = .number(number + shift)
            }
        case .sharedString:
            if let index = XLSXValue.int(valueText), context.sharedStrings.indices.contains(index) {
                cell.value = .text(context.sharedStrings[index])
            }
        case .formulaString:
            if hasValue { cell.value = .text(XLSXText.decode(valueText)) }
        case .inlineString:
            // Some writers put inline text in <v> instead of <is>.
            cell.value = .text(XLSXText.decode(hasInlineString ? inlineText : valueText))
        case .boolean:
            if hasValue { cell.value = .boolean(XLSXValue.isTrue(valueText.trimmingCharacters(in: .whitespaces))) }
        case .error:
            if hasValue { cell.value = .error(XLSXWorksheetParser.error(valueText)) }
        case .date:
            if let date = XLSXWorksheetParser.serial(isoDate: valueText) {
                cell.value = .number(date.serial)
                if cell.format.numberFormat == nil {
                    cell.format.numberFormat = date.hasDate
                        ? (date.hasTime ? NumberFormatPresets.dateTime.pattern : NumberFormatPresets.date.pattern)
                        : NumberFormatPresets.time.pattern
                }
            }
        }

        if hasFormula { cell.formula = formula(at: address) }
        if context.styles.isUnlocked(at: cellStyle) { unlockedCells.append(address) }
        // An empty string is an empty cell, unless a formula produced it.
        if cell.formula == nil, cell.value == .text("") { cell.value = .empty }
        guard !cell.isEmpty else { return }
        sheet[address] = cell
        lastRow = max(lastRow, address.row)
        lastColumn = max(lastColumn, address.column)
    }

    /// The cell's formula with its "=", following shared and array formulas.
    private func formula(at address: CellAddress) -> String? {
        let hasText = formulaText.contains { !$0.isWhitespace }
        switch formulaKind {
        case .normal:
            return hasText ? XLSXFormula.importing(formulaText) : nil
        case .array:
            guard hasText else { return nil }
            if let reference = formulaReference, let range = CellRange(a1: reference), !range.isSingleCell {
                arrayFormulas.append((address, range))
            }
            return XLSXFormula.importing(formulaText)
        case .shared:
            guard let index = formulaSharedIndex else { return hasText ? XLSXFormula.importing(formulaText) : nil }
            if hasText {
                let formula = XLSXFormula.importing(formulaText)
                sharedMasters[index] = (address, XLSXShiftableFormula(formula))
                return formula
            }
            if let master = sharedMasters[index] { return XLSXWorksheetParser.derive(master, at: address) }
            pendingShared.append((address, index))
            return nil
        case .dataTable:
            // What-if tables: the cached results stay as values.
            return nil
        }
    }

    private static func derive(_ master: (address: CellAddress, formula: XLSXShiftableFormula), at address: CellAddress) -> String {
        master.formula.shifted(rows: address.row - master.address.row, columns: address.column - master.address.column)
    }

    // MARK: - Layout

    private func readColumns(_ attributes: [String: String]) {
        guard let first = XLSXValue.int(attributes["min"]), let last = XLSXValue.int(attributes["max"]),
              first >= 1, last >= first, first <= XLSXLimits.columns else { return }
        columnSpans.append(ColumnSpan(first: first - 1, last: min(last, XLSXLimits.columns) - 1,
                                      width: XLSXValue.double(attributes["width"]), hidden: XLSXValue.isTrue(attributes["hidden"]),
                                      level: min(max(XLSXValue.int(attributes["outlineLevel"]) ?? 0, 0), XLSXOutline.maximumLevel),
                                      collapsed: XLSXValue.isTrue(attributes["collapsed"])))
    }

    private func readPane(_ attributes: [String: String]) {
        guard attributes["state"] == "frozen" || attributes["state"] == "frozenSplit" else { return }
        if let columns = XLSXValue.double(attributes["xSplit"]), columns >= 1 {
            sheet.frozenColumns = Int(min(columns, Double(XLSXLimits.columns - 1)))
        }
        if let rows = XLSXValue.double(attributes["ySplit"]), rows >= 1 {
            sheet.frozenRows = Int(min(rows, Double(XLSXLimits.rows - 1)))
        }
    }

    private func readMerge(_ attributes: [String: String]) {
        guard let reference = attributes["ref"], let range = CellRange(a1: reference), !range.isSingleCell,
              range.end.row < XLSXLimits.rows, range.end.column < XLSXLimits.columns,
              mergedRanges.insert(range).inserted else { return }
        sheet.merges.append(range)
        lastRow = max(lastRow, range.end.row)
        lastColumn = max(lastColumn, range.end.column)
    }

    /// Applies what needs the whole sheet: deferred shared formulas, array results, the grid size and
    /// column widths.
    private func finish() {
        for (address, index) in pendingShared {
            guard let master = sharedMasters[index] else { continue }
            var cell = sheet[address]
            cell.formula = XLSXWorksheetParser.derive(master, at: address)
            sheet[address] = cell
        }
        // The rest of an array formula's block holds its results, which the formula fills in again when
        // it's calculated; kept as values, they would block that. (The work is bounded for absurd files.)
        var budget = 20_000_000
        for (master, range) in arrayFormulas {
            budget -= min(range.cellCount, sheet.cells.count)
            guard budget >= 0 else { break }
            for (address, cell) in sheet.cells(in: range) where address != master && cell.formula == nil {
                var cleared = cell
                cleared.value = .empty
                sheet[address] = cleared
            }
        }

        // Groups first: rows hidden only because their group is collapsed aren't hidden by hand (nor by the filter).
        sheet.rowGroups = XLSXOutline.groups(levels: rowLevels, collapsedMarks: collapsedRows, summaryAfter: summaryBelow)
        sheet.hiddenRows.subtract(sheet.rowGroups.collapsedIndexes)
        readRules()
        if isProtected {
            sheet.protections = [XLSXProtection.protection(unlocked: unlockedCells, editableRanges: editableRanges)]
        }

        // Column spans reaching Excel's (16384) or LibreOffice's (1024) last column mean "all remaining
        // columns": they apply to the grid without growing it.
        var columnCount = max(Sheet.defaultColumnCount, lastColumn + 1)
        // A column only marking the group before it as collapsed doesn't grow the grid.
        for span in columnSpans where span.last < 1023 && !(span.collapsed && !span.hidden && span.level == 0) {
            columnCount = max(columnCount, span.last + 1)
        }
        sheet.rowCount = max(Sheet.defaultRowCount, lastRow + 1)
        sheet.columnCount = columnCount
        if let height = defaultRowHeight, height > 0 { sheet.defaultRowHeight = XLSXUnits.pixels(fromPoints: height) }
        // Heights equal to the default (some writers mark every row) aren't worth keeping, like widths below.
        for (row, points) in rowHeights {
            let pixels = XLSXUnits.pixels(fromPoints: points)
            if pixels != sheet.defaultRowHeight { sheet.rowHeights[row] = pixels }
        }
        if let width = defaultColumnWidth, width > 0 {
            sheet.defaultColumnWidth = XLSXUnits.pixels(fromColumnWidth: width)
        } else {
            sheet.defaultColumnWidth = XLSXUnits.pixels(fromBaseColumnWidth: baseColumnWidth ?? 8)
        }

        var columnBudget = 5_000_000
        var columnLevels: [Int: Int] = [:]
        var collapsedColumns = Set<Int>()
        for span in columnSpans {
            // A collapsed mark can sit on the column just past the grid.
            if span.collapsed { collapsedColumns.formUnion(span.first...min(span.last, span.first + 64)) }
            let last = min(span.last, columnCount - 1)
            guard span.first <= last else { continue }
            columnBudget -= last - span.first + 1
            guard columnBudget >= 0 else { break }
            let pixels = span.width.flatMap { $0 > 0 ? XLSXUnits.pixels(fromColumnWidth: $0) : nil }
            for column in span.first...last {
                if span.hidden { sheet.hiddenColumns.insert(column) }
                if let pixels, pixels != sheet.defaultColumnWidth { sheet.columnWidths[column] = pixels }
                if span.level > 0 { columnLevels[column] = span.level }
            }
        }
        sheet.columnGroups = XLSXOutline.groups(levels: columnLevels, collapsedMarks: collapsedColumns, summaryAfter: summaryRight)
        sheet.hiddenColumns.subtract(sheet.columnGroups.collapsedIndexes)
        sheet.frozenRows = min(sheet.frozenRows, sheet.rowCount - 1)
        sheet.frozenColumns = min(sheet.frozenColumns, sheet.columnCount - 1)
    }

    /// Validations, conditional formats and the filter. Rows hidden inside a filter that filters something
    /// are the filter's, not hidden by hand.
    private func readRules() {
        let validations = XLSXRules.validations(validationNodes)
        sheet.validations = validations.rules
        if validations.unsupported { warnings.insert(.dataValidation) }
        let formats = XLSXRules.conditionalFormats(conditionalFormatNodes, styles: context.styles)
        sheet.conditionalFormats = formats.rules
        if formats.unsupported { warnings.insert(.conditionalFormatting) }
        guard let node = autoFilterNode else { return }
        let result = XLSXRules.filter(node, sheet: sheet)
        if result.unsupported { warnings.insert(.filters) }
        guard let filter = result.filter else { return }
        sheet.filter = filter
        lastRow = max(lastRow, filter.range.end.row)
        lastColumn = max(lastColumn, filter.range.end.column)
        if filterMode || !filter.criteria.isEmpty, let rows = FilterValues.dataRows(of: filter.range) {
            let filtered = sheet.hiddenRows.filter { rows.contains($0) }
            sheet.hiddenRows.subtract(filtered)
            sheet.filteredRows = filtered
        }
    }

    // MARK: - Values

    /// Parses "B12" (letters, then digits; "$" allowed) inside Excel's limits.
    static func address(_ reference: String) -> CellAddress? {
        var column = 0, row = 0, letters = 0, digits = 0
        for byte in reference.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A:
                guard digits == 0, letters < 3 else { return nil }
                column = column * 26 + Int(byte & 0x1F)
                letters += 1
            case 0x30...0x39:
                guard letters > 0, digits < 7 else { return nil }
                row = row * 10 + Int(byte - 0x30)
                digits += 1
            case 0x24:
                continue
            default:
                return nil
            }
        }
        guard digits > 0, row >= 1, row <= XLSXLimits.rows, column >= 1, column <= XLSXLimits.columns else { return nil }
        return CellAddress(row: row - 1, column: column - 1)
    }

    /// An error code from a file. Codes newer than PuggleSheets' set fold into the closest one.
    static func error(_ code: String) -> CellError {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        if let error = CellError(code: trimmed) { return error }
        switch trimmed.uppercased() {
        case "#SPILL!": return CellError(.reference)
        case "#GETTING_DATA", "#BUSY!": return CellError(.notAvailable)
        default: return CellError(.value)
        }
    }

    /// An ISO 8601 date and time ("2024-03-01", "2024-03-01T13:30:00.5Z", "T13:30") as a serial number.
    /// Any time zone designator is ignored: spreadsheets show wall-clock times.
    static func serial(isoDate text: String) -> (serial: Double, hasDate: Bool, hasTime: Bool)? {
        let bytes = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        var index = 0
        func number(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<count {
                let byte = bytes[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
                index += 1
            }
            return value
        }
        func skip(_ character: Character) -> Bool {
            guard index < bytes.count, bytes[index] == character.asciiValue else { return false }
            index += 1
            return true
        }
        var serial = 0.0
        var hasDate = false
        var hasTime = false
        if bytes.first != UInt8(ascii: "T") {
            guard let year = number(4), skip("-"), let month = number(2), skip("-"), let day = number(2),
                  (1...12).contains(month), (1...31).contains(day) else { return nil }
            serial = DateSerial.serial(year: year, month: month, day: day)
            hasDate = true
        }
        if skip("T") {
            guard let hour = number(2), skip(":"), let minute = number(2), hour <= 24, minute < 60 else { return nil }
            var seconds = 0.0
            if skip(":") {
                guard let whole = number(2) else { return nil }
                seconds = Double(whole)
                if skip(".") || skip(",") {
                    var scale = 0.1
                    while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                        seconds += Double(bytes[index] - 0x30) * scale
                        scale /= 10
                        index += 1
                    }
                }
            }
            serial += DateSerial.time(hour: hour, minute: minute, second: seconds)
            hasTime = hour != 0 || minute != 0 || seconds != 0 || !hasDate
        }
        guard hasDate || hasTime else { return nil }
        return (serial, hasDate, hasTime)
    }
}
