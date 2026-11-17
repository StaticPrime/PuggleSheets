import Foundation

/// One table of content.xml, read.
struct ODSParsedTable {
    var sheet: Sheet
    var styleName: String?
    var isProtected = false
    /// `calcext:conditional-formats`, converted once every sheet is known.
    var conditionalFormats: XNode?
    /// Sheet-scoped `table:named-expressions`.
    var namedExpressions: XNode?
    /// The cells carrying each content validation, as blocks.
    var validationBlocks: [String: [CellRange]] = [:]
    /// Shapes: `draw:frame`s in cells and in `table:shapes`.
    var frames: [ODSParsedFrame] = []
    /// Cells with a link, whose marks are resolved once every sheet is known.
    var linkCells: [CellAddress] = []
    /// On a protected table: the cells whose style leaves them editable.
    var unprotected: [CellRange] = []
}

/// A `draw:frame` of a table, kept as a tree.
struct ODSParsedFrame {
    var node: XNode
    /// The cell holding the frame; nil for shapes anchored to the page (`table:shapes`).
    var anchor: CellAddress?
    /// Position in the document, for frames without a z-index.
    var order: Int
}

/// Streams content.xml: the styles at its top (kept as trees), then each table's columns, rows and cells.
/// Frames (pictures and charts), the rules and the DataPilot tables are kept as trees too, and a cell's
/// first link (`text:a`) as its link.
///
/// Repeated rows and cells are expanded only when they hold something: LibreOffice ends every sheet
/// with about a million repeated empty rows. Formatting repeated over huge blocks (whole rows or
/// columns) is kept only inside the sheet's grid.
final class ODSContentParser: NSObject, XMLParserDelegate {
    /// The cell limit; bigger files are refused rather than filling memory.
    static let maximumCells = 10_000_000
    static let maximumRows = 10_000_000
    static let maximumColumns = 18_278
    /// Blocks of formatting-only cells up to this size are kept as they come; bigger ones (formatting of
    /// whole rows or columns) are clipped to the grid at the end of the table.
    private static let immediateBlockSize = 10_000

    private(set) var tables: [ODSParsedTable] = []
    private(set) var contentValidations: XNode?
    private(set) var namedExpressions: XNode?
    private(set) var databaseRanges: XNode?
    private(set) var dataPilotTables: XNode?
    private(set) var warnings: Set<ImportWarning> = []
    private(set) var isTooLarge = false
    private(set) var styles: ODSStyleSheet

    private struct CellSpec {
        var column: Int
        var repeatCount = 1
        var styleName: String?
        var valueType: String?
        var calcextType: String?
        var value: String?
        var dateValue: String?
        var timeValue: String?
        var booleanValue: String?
        var stringValue: String?
        var formula: String?
        var columnsSpanned = 1
        var rowsSpanned = 1
        var matrixColumns = 1
        var matrixRows = 1
        var validation: String?
        var paragraphs: [String] = []
        /// `text:a` targets in the cell's text, and how many characters they cover.
        var links: [String] = []
        var linkedScalars = 0
        /// The text of the cell's `office:annotation`.
        var note: String?
    }

    private struct ColumnGroup {
        var start: Int
        var count: Int
        var style: String?
        var hidden: Bool
        var defaultCellStyle: String?
    }

    private struct RowGroup {
        var start: Int
        var count: Int
        var style: String?
        var visibility: String?
    }

    // Skipped content and trees.
    private var skipDepth = 0
    private var skippingDrawing = false
    private var subtree: XNodeBuilder?
    private var frameAnchor: CellAddress?
    private var inShapes = false
    private var nullDateOffset = 0.0
    private var formats: [String: CellFormat] = [:]

    // The current table.
    private var inTable = false
    private var sheet = Sheet(name: "")
    private var tableStyleName: String?
    private var tableIsProtected = false
    private var tableConditionalFormats: XNode?
    private var tableNamedExpressions: XNode?
    private var validationBlocks: [String: [CellRange]] = [:]
    private var columnGroups: [ColumnGroup] = []
    private var columnDefaults: [String?]?
    private var nextColumn = 0
    private var rowGroups: [RowGroup] = []
    private var currentRow = 0
    private var lastRow = -1
    private var lastColumn = -1
    private var deferred: [(rows: ClosedRange<Int>, columns: ClosedRange<Int>, format: CellFormat)] = []
    private var arrayFormulas: [(master: CellAddress, range: CellRange)] = []
    private var cellCount = 0
    private var tableFrames: [ODSParsedFrame] = []
    private var linkCells: [CellAddress] = []
    // Outline groups: those open (where they start, and whether they're collapsed) and those read.
    private var openRowOutlines: [(start: Int, collapsed: Bool)] = []
    private var openColumnOutlines: [(start: Int, collapsed: Bool)] = []
    private var rowOutlines: [OutlineGroup] = []
    private var columnOutlines: [OutlineGroup] = []
    // On a protected table: blocks of cells left editable, and whether a style leaves its cells editable.
    private var unprotectedBlocks: [CellRange] = []
    private var unprotectedStyles: [String: Bool] = [:]

    // The current row and cell.
    private var rowRepeat = 1
    private var rowStyle: String?
    private var rowVisibility: String?
    private var rowDefaultStyle: String?
    private var rowCells: [CellSpec] = []
    private var currentColumn = 0
    private var cell: CellSpec?
    private var inParagraph = false
    private var paragraph = ""
    private var lastWasSpace = false
    private var linkDepth = 0
    private var linkStart = 0
    // A cell's annotation: its paragraphs become the cell's note.
    private var inAnnotation = false
    private var annotationParagraphs: [String] = []

    init(styles: ODSStyleSheet) {
        self.styles = styles
    }

    // MARK: - Elements

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if skipDepth > 0 {
            skipDepth += 1
            if skippingDrawing { noteDrawing(elementName) }
            return
        }
        if let subtree {
            subtree.start(elementName, ODSContentParser.keepingExtensions(attributeDict))
            return
        }
        switch elementName {
        case "table:table-cell":
            beginCell(attributeDict)
        case "table:covered-table-cell":
            beginCell(attributeDict)
        case "text:p", "text:h":
            if cell != nil {
                inParagraph = true
                paragraph = ""
                lastWasSpace = false
            }
        case "text:s":
            if inParagraph {
                let count = min(max(Int(attributeDict["text:c"] ?? "1") ?? 1, 1), 10_000)
                paragraph += String(repeating: " ", count: count)
                lastWasSpace = true
            }
        case "text:tab":
            if inParagraph {
                paragraph += "\t"
                lastWasSpace = false
            }
        case "text:line-break":
            if inParagraph {
                paragraph += "\n"
                lastWasSpace = false
            }
        case "text:span":
            if inParagraph, !inAnnotation, attributeDict["text:style-name"] != nil { warnings.insert(.richText) }
        case "text:a":
            if inParagraph, !inAnnotation {
                cell?.links.append(attributeDict["xlink:href"] ?? "")
                if linkDepth == 0 { linkStart = paragraph.unicodeScalars.count }
                linkDepth += 1
            }
        case "draw:frame":
            if inTable, inShapes || cell != nil {
                frameAnchor = cell.map { CellAddress(row: currentRow, column: $0.column) }
                subtree = XNodeBuilder(rootName: elementName, attributes: attributeDict)
            } else {
                skip(drawing: true)
            }
        case "table:table-row":
            beginRow(attributeDict)
        case "table:table-column":
            addColumns(attributeDict)
        case "table:table":
            beginTable(attributeDict)
        case "office:annotation":
            if cell != nil, !inAnnotation {
                inAnnotation = true
                annotationParagraphs = []
            } else {
                skip(drawing: false)
            }
        case "table:table-row-group":
            if inTable { openRowOutlines.append((currentRow, attributeDict["table:display"] == "false")) }
        case "table:table-column-group":
            if inTable { openColumnOutlines.append((nextColumn, attributeDict["table:display"] == "false")) }
        case "office:spreadsheet":
            // The order and number of sheets can't be protected in PuggleSheets.
            if XLSXValue.isTrue(attributeDict["table:structure-protected"]) { warnings.insert(.protection) }
        case "table:shapes":
            if inTable { inShapes = true } else { skip(drawing: true) }
        case "office:event-listeners":
            warnings.insert(.macros)
            skip(drawing: false)
        case "office:forms", "table:dde-links", "table:consolidation", "table:label-ranges", "table:table-source", "table:scenario",
             "table:tracked-changes", "office:dde-source", "table:named-expressions-source":
            skip(drawing: false)
        case "office:automatic-styles", "office:font-face-decls", "table:content-validations", "table:named-expressions",
             "table:database-ranges", "calcext:conditional-formats", "table:calculation-settings", "office:scripts",
             "table:data-pilot-tables":
            subtree = XNodeBuilder(rootName: elementName, attributes: attributeDict)
        default:
            if elementName.hasPrefix("draw:") || elementName.hasPrefix("dr3d:") {
                skip(drawing: true)
                noteDrawing(elementName)
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if skipDepth > 0 {
            skipDepth -= 1
            if skipDepth == 0 { skippingDrawing = false }
            return
        }
        if let subtree {
            if subtree.end(), let root = subtree.root {
                self.subtree = nil
                captured(root)
            }
            return
        }
        switch elementName {
        case "table:table-cell", "table:covered-table-cell":
            if let spec = cell { rowCells.append(spec) }
            cell = nil
            inParagraph = false
            inAnnotation = false
        case "text:p", "text:h":
            if inParagraph {
                if inAnnotation {
                    annotationParagraphs.append(paragraph)
                } else {
                    cell?.paragraphs.append(paragraph)
                }
                inParagraph = false
                linkDepth = 0
            }
        case "office:annotation":
            if inAnnotation {
                cell?.note = annotationParagraphs.joined(separator: "\n")
                inAnnotation = false
            }
        case "table:table-row-group":
            if let open = openRowOutlines.popLast(), currentRow > open.start {
                rowOutlines.append(OutlineGroup(range: open.start...(currentRow - 1), isCollapsed: open.collapsed))
            }
        case "table:table-column-group":
            if let open = openColumnOutlines.popLast(), nextColumn > open.start {
                columnOutlines.append(OutlineGroup(range: open.start...(nextColumn - 1), isCollapsed: open.collapsed))
            }
        case "text:a":
            if linkDepth > 0 {
                linkDepth -= 1
                if linkDepth == 0, inParagraph { cell?.linkedScalars += paragraph.unicodeScalars.count - linkStart }
            }
        case "table:shapes":
            inShapes = false
        case "table:table-row":
            endRow(parser)
        case "table:table":
            endTable()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if skipDepth > 0 { return }
        if let subtree {
            subtree.characters(string)
            return
        }
        guard inParagraph else { return }
        // White space collapses as ODF says: runs become one space, none at the start of a paragraph
        // (text:s writes the spaces that count).
        if !string.utf8.contains(where: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
            paragraph += string
            lastWasSpace = false
            return
        }
        for scalar in string.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                if paragraph.isEmpty || lastWasSpace { continue }
                paragraph.unicodeScalars.append(" ")
                lastWasSpace = true
            } else {
                paragraph.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
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

    /// Trees drop attribute prefixes; LibreOffice's extension attributes that share a local name with a
    /// standard one (`loext:layout-mode` beside `table:layout-mode`) are kept apart as "loext-…".
    private static func keepingExtensions(_ attributes: [String: String]) -> [String: String] {
        guard attributes.keys.contains(where: { $0.hasPrefix("loext:") }) else { return attributes }
        var result: [String: String] = [:]
        for (key, value) in attributes {
            result[key.hasPrefix("loext:") ? "loext-" + key.dropFirst(6) : key] = value
        }
        return result
    }

    private func skip(drawing: Bool) {
        skipDepth = 1
        skippingDrawing = drawing
    }

    /// Shapes that can't be kept (groups, drawn shapes and what they hold): embedded objects count as
    /// charts; pictures, shapes and text boxes as images.
    private func noteDrawing(_ name: String) {
        switch name {
        case "draw:object", "draw:object-ole":
            warnings.insert(.charts)
        case "draw:frame", "draw:g", "draw:a", "draw:param", "draw:glue-point", "draw:enhanced-geometry", "draw:equation",
             "draw:handle", "draw:contour-polygon", "draw:contour-path", "draw:image-map", "draw:area-rectangle",
             "draw:area-circle", "draw:area-polygon", "draw:plugin":
            break
        default:
            if name.hasPrefix("draw:") || name.hasPrefix("dr3d:") { warnings.insert(.images) }
        }
    }

    private func captured(_ node: XNode) {
        switch node.name {
        case "automatic-styles":
            styles.addStyles(node)
            formats.removeAll()
        case "font-face-decls":
            styles.addFontFaces(node)
            formats.removeAll()
        case "content-validations":
            contentValidations = node
        case "named-expressions":
            if inTable { tableNamedExpressions = node } else { namedExpressions = node }
        case "database-ranges":
            databaseRanges = node
        case "data-pilot-tables":
            dataPilotTables = node
        case "frame":
            tableFrames.append(ODSParsedFrame(node: node, anchor: frameAnchor, order: tableFrames.count))
            frameAnchor = nil
        case "conditional-formats":
            if inTable { tableConditionalFormats = node }
        case "calculation-settings":
            if let date = node.child("null-date")?["date-value"], let serial = XLSXWorksheetParser.serial(isoDate: date)?.serial {
                nullDateOffset = serial
            }
        case "scripts":
            if !node.children.isEmpty { warnings.insert(.macros) }
        default:
            break
        }
    }

    // MARK: - Tables, columns and rows

    private func beginTable(_ attributes: [String: String]) {
        inTable = true
        sheet = Sheet(name: attributes["table:name"] ?? "")
        tableStyleName = attributes["table:style-name"]
        // Protected tables are kept (their password, if any, isn't needed).
        tableIsProtected = XLSXValue.isTrue(attributes["table:protected"])
        tableConditionalFormats = nil
        tableNamedExpressions = nil
        validationBlocks = [:]
        columnGroups = []
        columnDefaults = nil
        nextColumn = 0
        rowGroups = []
        currentRow = 0
        lastRow = -1
        lastColumn = -1
        deferred = []
        arrayFormulas = []
        tableFrames = []
        linkCells = []
        inShapes = false
        openRowOutlines = []
        openColumnOutlines = []
        rowOutlines = []
        columnOutlines = []
        unprotectedBlocks = []
    }

    private func addColumns(_ attributes: [String: String]) {
        guard inTable else { return }
        let count = min(max(Int(attributes["table:number-columns-repeated"] ?? "1") ?? 1, 1), ODSContentParser.maximumColumns)
        let visibility = attributes["table:visibility"]
        columnGroups.append(ColumnGroup(start: nextColumn, count: count, style: attributes["table:style-name"],
                                        hidden: visibility == "collapse" || visibility == "filter",
                                        defaultCellStyle: attributes["table:default-cell-style-name"]))
        nextColumn = min(nextColumn + count, ODSContentParser.maximumColumns)
    }

    private func beginRow(_ attributes: [String: String]) {
        rowRepeat = min(max(Int(attributes["table:number-rows-repeated"] ?? "1") ?? 1, 1), ODSContentParser.maximumRows)
        rowStyle = attributes["table:style-name"]
        rowVisibility = attributes["table:visibility"]
        rowDefaultStyle = attributes["table:default-cell-style-name"]
        rowCells.removeAll(keepingCapacity: true)
        currentColumn = 0
        if columnDefaults == nil {
            var defaults = [String?](repeating: nil, count: nextColumn)
            for group in columnGroups where group.defaultCellStyle != nil {
                for column in group.start..<min(group.start + group.count, defaults.count) { defaults[column] = group.defaultCellStyle }
            }
            columnDefaults = defaults
        }
    }

    private func beginCell(_ attributes: [String: String]) {
        var spec = CellSpec(column: currentColumn)
        for (key, value) in attributes {
            switch key {
            case "table:number-columns-repeated": spec.repeatCount = min(max(Int(value) ?? 1, 1), ODSContentParser.maximumColumns)
            case "table:style-name": spec.styleName = value
            case "office:value-type": spec.valueType = value
            case "calcext:value-type": spec.calcextType = value
            case "office:value": spec.value = value
            case "office:date-value": spec.dateValue = value
            case "office:time-value": spec.timeValue = value
            case "office:boolean-value": spec.booleanValue = value
            case "office:string-value": spec.stringValue = value
            case "table:formula": spec.formula = value
            case "table:number-columns-spanned": spec.columnsSpanned = min(max(Int(value) ?? 1, 1), ODSContentParser.maximumColumns)
            case "table:number-rows-spanned": spec.rowsSpanned = min(max(Int(value) ?? 1, 1), ODSContentParser.maximumRows)
            case "table:number-matrix-columns-spanned": spec.matrixColumns = min(max(Int(value) ?? 1, 1), ODSContentParser.maximumColumns)
            case "table:number-matrix-rows-spanned": spec.matrixRows = min(max(Int(value) ?? 1, 1), ODSContentParser.maximumRows)
            case "table:content-validation-name": spec.validation = value
            default: break
            }
        }
        currentColumn = min(currentColumn + spec.repeatCount, ODSContentParser.maximumColumns)
        cell = spec
    }

    private func endRow(_ parser: XMLParser) {
        let firstRow = currentRow
        let count = min(rowRepeat, ODSContentParser.maximumRows - firstRow)
        guard inTable, count > 0 else { return }
        rowGroups.append(RowGroup(start: firstRow, count: count, style: rowStyle, visibility: rowVisibility))
        for spec in rowCells { materialize(spec, firstRow: firstRow, rowCount: count) }
        if isTooLarge { parser.abortParsing() }
        currentRow = firstRow + count
    }

    private func format(_ styleName: String?) -> CellFormat {
        let key = styleName ?? ""
        if let cached = formats[key] { return cached }
        let format = styles.cellFormat(styleName)
        formats[key] = format
        return format
    }

    private func columnDefault(_ column: Int) -> String? {
        guard let columnDefaults, column < columnDefaults.count else { return nil }
        return columnDefaults[column]
    }

    /// Adds the cells one cell element stands for (repeated across columns and the row's repeats).
    private func materialize(_ spec: CellSpec, firstRow: Int, rowCount: Int) {
        let lastRowIndex = firstRow + rowCount - 1
        let lastColumnIndex = min(spec.column + spec.repeatCount, ODSContentParser.maximumColumns) - 1
        guard spec.column <= lastColumnIndex else { return }
        let rows = firstRow...lastRowIndex, columns = spec.column...lastColumnIndex
        let blockSize = rowCount * columns.count

        if let name = spec.validation, !name.isEmpty {
            validationBlocks[name, default: []].append(CellRange(rows: rows, columns: columns))
        }
        if spec.columnsSpanned > 1 || spec.rowsSpanned > 1, blockSize <= ODSContentParser.immediateBlockSize {
            for row in rows {
                for column in columns {
                    let merge = CellRange(rows: row...min(row + spec.rowsSpanned - 1, ODSContentParser.maximumRows - 1),
                                          columns: column...min(column + spec.columnsSpanned - 1, ODSContentParser.maximumColumns - 1))
                    sheet.merges.append(merge)
                    lastRow = max(lastRow, merge.end.row)
                    lastColumn = max(lastColumn, merge.end.column)
                }
            }
        }

        let formula = spec.formula.flatMap(ODSFormula.importing)
        var value = value(of: spec)
        if formula == nil, value == .text("") { value = .empty }
        let explicitStyle = spec.styleName ?? rowDefaultStyle
        // A cell's first link applies to all its text; several links or a link around part of the text
        // can't be kept as they are.
        let link = spec.links.first
        if link != nil, Set(spec.links).count > 1 || spec.linkedScalars < spec.paragraphs.reduce(0, { $0 + $1.unicodeScalars.count }) {
            warnings.insert(.hyperlinks)
        }
        if tableIsProtected { noteProtection(of: spec, explicitStyle: explicitStyle, rows: rows, columns: columns) }

        guard formula != nil || value != .empty || link != nil || spec.note != nil else {
            // Formatting alone.
            if let explicitStyle {
                let cellFormat = format(explicitStyle)
                guard !cellFormat.isDefault else { return }
                if blockSize <= ODSContentParser.immediateBlockSize {
                    for row in rows {
                        for column in columns { sheet[row, column] = Cell(format: cellFormat) }
                    }
                    lastRow = max(lastRow, lastRowIndex)
                    lastColumn = max(lastColumn, lastColumnIndex)
                } else {
                    deferred.append((rows, columns, cellFormat))
                }
            } else if blockSize <= ODSContentParser.immediateBlockSize {
                // Column defaults: only for blocks of a sensible size.
                for column in columns {
                    let cellFormat = format(columnDefault(column))
                    guard !cellFormat.isDefault else { continue }
                    for row in rows { sheet[row, column] = Cell(format: cellFormat) }
                    lastRow = max(lastRow, lastRowIndex)
                    lastColumn = max(lastColumn, column)
                }
            }
            return
        }

        guard cellCount + blockSize <= ODSContentParser.maximumCells else {
            isTooLarge = true
            return
        }
        cellCount += blockSize
        for column in columns {
            var cellFormat = format(explicitStyle ?? columnDefault(column))
            var cellValue = value
            switch spec.valueType {
            case "date" where cellFormat.numberFormat == nil:
                let hasTime = (value.numberValue ?? 0).truncatingRemainder(dividingBy: 1) != 0
                cellFormat.numberFormat = hasTime ? NumberFormatPresets.dateTime.pattern : NumberFormatPresets.date.pattern
            case "time" where cellFormat.numberFormat == nil:
                cellFormat.numberFormat = abs(value.numberValue ?? 0) >= 1 ? NumberFormatPresets.duration.pattern : NumberFormatPresets.time.pattern
            case "float" where nullDateOffset != 0 && XLSXNumberFormats.showsDate(cellFormat.numberFormat):
                cellValue = .number((value.numberValue ?? 0) + nullDateOffset)
            default:
                break
            }
            let newCell = Cell(value: cellValue, formula: formula, format: cellFormat, link: link, note: spec.note)
            for row in rows { sheet[row, column] = newCell }
            if link != nil {
                for row in rows { linkCells.append(CellAddress(row: row, column: column)) }
            }
        }
        lastRow = max(lastRow, lastRowIndex)
        lastColumn = max(lastColumn, lastColumnIndex)
        if formula != nil, spec.matrixColumns > 1 || spec.matrixRows > 1, blockSize == 1 {
            let master = CellAddress(row: firstRow, column: spec.column)
            let range = CellRange(master, CellAddress(row: min(firstRow + spec.matrixRows - 1, ODSContentParser.maximumRows - 1),
                                                       column: min(spec.column + spec.matrixColumns - 1, ODSContentParser.maximumColumns - 1)))
            arrayFormulas.append((master, range))
        }
    }

    /// Whether cells with a style (nil: the default style) stay editable on a protected table.
    private func isUnprotected(_ styleName: String?) -> Bool {
        let key = styleName ?? ""
        if let known = unprotectedStyles[key] { return known }
        let result = styles.isUnprotected(styleName)
        unprotectedStyles[key] = result
        return result
    }

    /// Notes the cells of a block that stay editable on a protected table: by their own style, or by
    /// their column's default style.
    private func noteProtection(of spec: CellSpec, explicitStyle: String?, rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        func add(_ block: CellRange) {
            // Blocks continuing the last one down the same columns are joined.
            if let last = unprotectedBlocks.last, last.columns == block.columns, last.end.row + 1 == block.start.row {
                unprotectedBlocks[unprotectedBlocks.count - 1] = last.union(block)
            } else {
                unprotectedBlocks.append(block)
            }
        }
        if let explicitStyle {
            if isUnprotected(explicitStyle) { add(CellRange(rows: rows, columns: columns)) }
            return
        }
        var run: ClosedRange<Int>?
        for column in columns {
            if isUnprotected(columnDefault(column)) {
                run = run.map { $0.lowerBound...column } ?? column...column
            } else if let current = run {
                add(CellRange(rows: rows, columns: current))
                run = nil
            }
        }
        if let run { add(CellRange(rows: rows, columns: run)) }
    }

    private func value(of spec: CellSpec) -> CellValue {
        if spec.calcextType == "error" {
            return .error(ODSContentParser.error(spec.paragraphs.joined(separator: "\n")))
        }
        switch spec.valueType {
        case "float", "percentage", "currency":
            guard let text = spec.value, let number = XLSXValue.double(text) else { return .empty }
            return .number(number)
        case "date":
            guard let text = spec.dateValue, let serial = XLSXWorksheetParser.serial(isoDate: text)?.serial else { return .empty }
            return .number(serial)
        case "time":
            guard let text = spec.timeValue, let days = ODSContentParser.duration(text) else { return .empty }
            return .number(days)
        case "boolean":
            guard let text = spec.booleanValue else { return .empty }
            return .boolean(text == "true" || text == "1")
        case "string":
            return .text(XLSXText.normalizedLineBreaks(spec.stringValue ?? spec.paragraphs.joined(separator: "\n")))
        default:
            let text = spec.paragraphs.joined(separator: "\n")
            return text.isEmpty ? .empty : .text(text)
        }
    }

    // MARK: - The end of a table

    private func endTable() {
        guard inTable else { return }
        inTable = false
        // Taken out of the parser so changes below don't copy its cells.
        var sheet = self.sheet
        self.sheet = Sheet(name: "")
        // The rest of a matrix formula's block holds its results, which the formula spills again.
        for (master, range) in arrayFormulas {
            for (address, cell) in sheet.cells(in: range) where address != master && cell.formula == nil {
                var cleared = cell
                cleared.value = .empty
                sheet[address] = cleared
            }
        }

        // Row and column definitions reaching the last row or column of LibreOffice's grid fill the rest
        // of the sheet: they don't make the grid bigger.
        var rowCount = max(Sheet.defaultRowCount, lastRow + 1)
        for group in rowGroups where group.start + group.count < 1_048_576 { rowCount = max(rowCount, group.start + group.count) }
        var columnCount = max(Sheet.defaultColumnCount, lastColumn + 1)
        for group in columnGroups {
            let end = group.start + group.count
            if end != 1024, end < 16384 { columnCount = max(columnCount, end) }
        }
        sheet.rowCount = min(rowCount, ODSContentParser.maximumRows)
        sheet.columnCount = min(columnCount, ODSContentParser.maximumColumns)
        let grid = sheet.gridRange
        // Outline groups inside the grid, outermost first. Rows and columns hidden because their group is
        // collapsed belong to the group, not to the hidden rows and columns.
        func clipped(_ groups: [OutlineGroup], limit: Int) -> [OutlineGroup] {
            groups.compactMap { group in
                guard group.range.lowerBound < limit else { return nil }
                return OutlineGroup(range: group.range.lowerBound...min(group.range.upperBound, limit - 1), isCollapsed: group.isCollapsed)
            }.sorted { ($0.range.lowerBound, -$0.range.upperBound) < ($1.range.lowerBound, -$1.range.upperBound) }
        }
        sheet.rowGroups = clipped(rowOutlines, limit: sheet.rowCount)
        sheet.columnGroups = clipped(columnOutlines, limit: sheet.columnCount)
        let collapsedRowGroups = sheet.rowGroups.filter(\.isCollapsed), collapsedColumnGroups = sheet.columnGroups.filter(\.isCollapsed)
        func inCollapsedRowGroup(_ row: Int) -> Bool { collapsedRowGroups.contains { $0.range.contains(row) } }
        func inCollapsedColumnGroup(_ column: Int) -> Bool { collapsedColumnGroups.contains { $0.range.contains(column) } }

        // The most common width and height become the defaults. Columns and rows without a size have
        // PuggleSheets' standard one.
        func pixels(_ value: Double) -> Double { value.rounded() }
        func width(_ group: ColumnGroup) -> Double {
            group.style.flatMap { styles.columnWidths[$0] }.map(pixels) ?? Sheet.standardColumnWidth
        }
        var widthCounts: [Double: Int] = [:]
        for group in columnGroups { widthCounts[width(group), default: 0] += group.count }
        if let best = widthCounts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
            sheet.defaultColumnWidth = best.key
        }
        for group in columnGroups {
            let first = group.start, last = min(group.start + group.count, sheet.columnCount) - 1
            guard first <= last else { continue }
            let width = width(group)
            for column in first...last {
                if group.hidden, !inCollapsedColumnGroup(column) { sheet.hiddenColumns.insert(column) }
                if width != sheet.defaultColumnWidth { sheet.columnWidths[column] = width }
            }
        }
        // Rows sized to fit their contents count toward the default but keep it.
        func height(_ group: RowGroup) -> (pixels: Double, fits: Bool) {
            guard let style = group.style.flatMap({ styles.rowStyles[$0] }), let height = style.height else {
                return (Sheet.standardRowHeight, false)
            }
            return (pixels(height), style.optimal)
        }
        var heightCounts: [Double: Int] = [:]
        for group in rowGroups { heightCounts[height(group).pixels, default: 0] += group.count }
        if let best = heightCounts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
            sheet.defaultRowHeight = best.key
        }
        for group in rowGroups {
            let first = group.start, last = min(group.start + group.count, sheet.rowCount) - 1
            guard first <= last else { continue }
            let size = height(group)
            let height: Double? = size.fits ? nil : size.pixels
            for row in first...last {
                if group.visibility == "collapse", !inCollapsedRowGroup(row) { sheet.hiddenRows.insert(row) }
                if group.visibility == "filter" { sheet.filteredRows.insert(row) }
                if let height, height != sheet.defaultRowHeight { sheet.rowHeights[row] = height }
            }
        }

        // Formatting of whole rows and columns, inside the grid.
        var budget = 2_000_000
        for block in deferred {
            guard block.rows.overlaps(grid.rows), block.columns.overlaps(grid.columns) else { continue }
            let rows = block.rows.clamped(to: grid.rows), columns = block.columns.clamped(to: grid.columns)
            guard rows.count * columns.count <= budget else { continue }
            budget -= rows.count * columns.count
            for row in rows {
                for column in columns where sheet.cells[CellAddress(row: row, column: column)] == nil {
                    sheet[row, column] = Cell(format: block.format)
                }
            }
        }
        // Cells left editable on a protected table, inside the grid; a default style that leaves cells
        // editable leaves the whole sheet so.
        var unprotected: [CellRange] = []
        if tableIsProtected {
            if isUnprotected(nil) { unprotectedBlocks.append(grid) }
            unprotected = ODSRules.mergedRanges(unprotectedBlocks.compactMap { $0.intersection(grid) })
        }
        tables.append(ODSParsedTable(sheet: sheet, styleName: tableStyleName, isProtected: tableIsProtected,
                                     conditionalFormats: tableConditionalFormats, namedExpressions: tableNamedExpressions,
                                     validationBlocks: validationBlocks, frames: tableFrames, linkCells: linkCells,
                                     unprotected: unprotected))
        tableFrames = []
        linkCells = []
    }

    // MARK: - Values

    /// "PT13H45M00S", "-PT1H", "P1DT2H30M" → days.
    static func duration(_ text: String) -> Double? {
        let characters = Array(text.trimmingCharacters(in: .whitespaces).uppercased())
        var index = 0
        var negative = false
        if index < characters.count, characters[index] == "-" {
            negative = true
            index += 1
        }
        guard index < characters.count, characters[index] == "P" else { return nil }
        index += 1
        var inTime = false
        var number = ""
        var total = 0.0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character.isASCII, character.isNumber || character == "." || character == "," {
                number.append(character == "," ? "." : character)
                continue
            }
            let value = Double(number) ?? 0
            number = ""
            switch character {
            case "T": inTime = true
            case "Y": total += value * 365
            case "M": total += inTime ? value / 1440 : value * 30
            case "W": total += value * 7
            case "D": total += value
            case "H": total += value / 24
            case "S": total += value / 86400
            default: return nil
            }
        }
        guard number.isEmpty, total.isFinite else { return nil }
        return negative ? -total : total
    }

    /// An error as LibreOffice shows it ("#DIV/0!", "Err:502").
    static func error(_ text: String) -> CellError {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = CellError(code: trimmed) { return error }
        switch trimmed {
        case "Err:503": return CellError(.number)
        case "Err:522", "Err:523": return CellError(.reference)
        case "Err:508", "Err:509", "Err:510", "Err:501": return CellError(.parse)
        default: return CellError(.value)
        }
    }
}
