import Foundation

// How a workbook travels between Macs when it's shared: compact, leaving out what's at its default and what the
// formula engine works out again on every Mac (spilled values, formula links, sparklines).

extension CellValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case number = "n", text = "t", boolean = "b", error = "e", message = "m"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try container.decodeIfPresent(Double.self, forKey: .number) {
            self = .number(number)
        } else if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else if let boolean = try container.decodeIfPresent(Bool.self, forKey: .boolean) {
            self = .boolean(boolean)
        } else if let kind = try container.decodeIfPresent(CellError.Kind.self, forKey: .error) {
            self = .error(CellError(kind, try container.decodeIfPresent(String.self, forKey: .message)))
        } else {
            self = .empty
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty: break
        case .number(let number): try container.encode(number, forKey: .number)
        case .text(let text): try container.encode(text, forKey: .text)
        case .boolean(let boolean): try container.encode(boolean, forKey: .boolean)
        case .error(let error):
            try container.encode(error.kind, forKey: .error)
            try container.encodeIfPresent(error.message, forKey: .message)
        }
    }
}

extension CellFormat: Codable {
    private enum CodingKeys: String, CodingKey {
        case fontFamily = "ff", fontSize = "fs", bold = "b", italic = "i", underline = "u", strikethrough = "s"
        case textColor = "tc", fillColor = "fc", horizontalAlignment = "ha", verticalAlignment = "va", wrap = "w"
        case numberFormat = "nf", borders = "bd", textRotation = "tr"
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize)
        bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try container.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        strikethrough = try container.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        textColor = try container.decodeIfPresent(RGBColor.self, forKey: .textColor)
        fillColor = try container.decodeIfPresent(RGBColor.self, forKey: .fillColor)
        horizontalAlignment = try container.decodeIfPresent(HorizontalAlignment.self, forKey: .horizontalAlignment)
        verticalAlignment = try container.decodeIfPresent(VerticalAlignment.self, forKey: .verticalAlignment)
        wrap = try container.decodeIfPresent(WrapStrategy.self, forKey: .wrap)
        numberFormat = try container.decodeIfPresent(String.self, forKey: .numberFormat)
        borders = try container.decodeIfPresent(CellBorders.self, forKey: .borders) ?? CellBorders()
        textRotation = try container.decodeIfPresent(TextRotation.self, forKey: .textRotation)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fontFamily, forKey: .fontFamily)
        try container.encodeIfPresent(fontSize, forKey: .fontSize)
        if bold { try container.encode(true, forKey: .bold) }
        if italic { try container.encode(true, forKey: .italic) }
        if underline { try container.encode(true, forKey: .underline) }
        if strikethrough { try container.encode(true, forKey: .strikethrough) }
        try container.encodeIfPresent(textColor, forKey: .textColor)
        try container.encodeIfPresent(fillColor, forKey: .fillColor)
        try container.encodeIfPresent(horizontalAlignment, forKey: .horizontalAlignment)
        try container.encodeIfPresent(verticalAlignment, forKey: .verticalAlignment)
        try container.encodeIfPresent(wrap, forKey: .wrap)
        try container.encodeIfPresent(numberFormat, forKey: .numberFormat)
        if !borders.isEmpty { try container.encode(borders, forKey: .borders) }
        try container.encodeIfPresent(textRotation, forKey: .textRotation)
    }
}

extension Cell: Codable {
    private enum CodingKeys: String, CodingKey {
        case value = "v", formula = "f", format = "fm", link = "l", image = "im", note = "n", comment = "c"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(value: try container.decodeIfPresent(CellValue.self, forKey: .value) ?? .empty,
                  formula: try container.decodeIfPresent(String.self, forKey: .formula),
                  format: try container.decodeIfPresent(CellFormat.self, forKey: .format) ?? CellFormat(),
                  link: try container.decodeIfPresent(String.self, forKey: .link),
                  image: try container.decodeIfPresent(CellImage.self, forKey: .image),
                  note: try container.decodeIfPresent(String.self, forKey: .note),
                  comment: try container.decodeIfPresent(CommentThread.self, forKey: .comment))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if value != .empty { try container.encode(value, forKey: .value) }
        try container.encodeIfPresent(formula, forKey: .formula)
        if !format.isDefault { try container.encode(format, forKey: .format) }
        try container.encodeIfPresent(link, forKey: .link)
        try container.encodeIfPresent(image, forKey: .image)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(comment, forKey: .comment)
    }

    /// The cell without its comment: comments travel apart from the cells they're on (see `SharedComment`).
    public var withoutComment: Cell {
        var cell = self
        cell.comment = nil
        return cell
    }

    /// Whether the two cells hold the same, setting aside a formula's latest result, which the formula engine works
    /// out afresh on every Mac.
    public func hasSameContent(as other: Cell) -> Bool {
        guard formula != nil, formula == other.formula else { return self == other }
        var a = self, b = other
        a.value = .empty
        b.value = .empty
        return a == b
    }
}

/// One stored cell, where it is.
struct CellEntry: Codable {
    var row: Int
    var column: Int
    var cell: Cell

    private enum CodingKeys: String, CodingKey { case row = "r", column = "c", cell = "x" }
}

extension Sheet: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, rowCount, columnCount, cells, defaultColumnWidth, defaultRowHeight, columnWidths, rowHeights
        case frozenRows, frozenColumns, merges, hiddenRows, hiddenColumns, showsGridlines, tabColor, conditionalFormats
        case validations, filter, filteredRows, bandings, objects, pivotTables, filterViews, protections, rowGroups
        case columnGroups, tables
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var sheet = Sheet(name: try container.decode(String.self, forKey: .name), id: try container.decode(UUID.self, forKey: .id),
                          rowCount: try container.decode(Int.self, forKey: .rowCount),
                          columnCount: try container.decode(Int.self, forKey: .columnCount))
        let entries = try container.decodeIfPresent([CellEntry].self, forKey: .cells) ?? []
        var cells: [CellAddress: Cell] = [:]
        cells.reserveCapacity(entries.count)
        for entry in entries { cells[CellAddress(row: entry.row, column: entry.column)] = entry.cell }
        sheet.setCells(cells)
        sheet.defaultColumnWidth = try container.decodeIfPresent(Double.self, forKey: .defaultColumnWidth) ?? Sheet.standardColumnWidth
        sheet.defaultRowHeight = try container.decodeIfPresent(Double.self, forKey: .defaultRowHeight) ?? Sheet.standardRowHeight
        sheet.columnWidths = try container.decodeIfPresent([Int: Double].self, forKey: .columnWidths) ?? [:]
        sheet.rowHeights = try container.decodeIfPresent([Int: Double].self, forKey: .rowHeights) ?? [:]
        sheet.frozenRows = try container.decodeIfPresent(Int.self, forKey: .frozenRows) ?? 0
        sheet.frozenColumns = try container.decodeIfPresent(Int.self, forKey: .frozenColumns) ?? 0
        sheet.merges = try container.decodeIfPresent([CellRange].self, forKey: .merges) ?? []
        sheet.hiddenRows = try container.decodeIfPresent(Set<Int>.self, forKey: .hiddenRows) ?? []
        sheet.hiddenColumns = try container.decodeIfPresent(Set<Int>.self, forKey: .hiddenColumns) ?? []
        sheet.showsGridlines = try container.decodeIfPresent(Bool.self, forKey: .showsGridlines) ?? true
        sheet.tabColor = try container.decodeIfPresent(RGBColor.self, forKey: .tabColor)
        sheet.conditionalFormats = try container.decodeIfPresent([ConditionalFormatRule].self, forKey: .conditionalFormats) ?? []
        sheet.validations = try container.decodeIfPresent([DataValidationRule].self, forKey: .validations) ?? []
        sheet.filter = try container.decodeIfPresent(SheetFilter.self, forKey: .filter)
        sheet.filteredRows = try container.decodeIfPresent(Set<Int>.self, forKey: .filteredRows) ?? []
        sheet.bandings = try container.decodeIfPresent([Banding].self, forKey: .bandings) ?? []
        sheet.objects = try container.decodeIfPresent([SheetObject].self, forKey: .objects) ?? []
        sheet.pivotTables = try container.decodeIfPresent([PivotTable].self, forKey: .pivotTables) ?? []
        sheet.filterViews = try container.decodeIfPresent([FilterView].self, forKey: .filterViews) ?? []
        sheet.protections = try container.decodeIfPresent([ProtectedRange].self, forKey: .protections) ?? []
        sheet.rowGroups = try container.decodeIfPresent([OutlineGroup].self, forKey: .rowGroups) ?? []
        sheet.columnGroups = try container.decodeIfPresent([OutlineGroup].self, forKey: .columnGroups) ?? []
        sheet.tables = try container.decodeIfPresent([SheetTable].self, forKey: .tables) ?? []
        self = sheet
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(rowCount, forKey: .rowCount)
        try container.encode(columnCount, forKey: .columnCount)
        // In row order, so the same sheet always comes out the same.
        let entries = cells.sorted { $0.key < $1.key }.map { CellEntry(row: $0.key.row, column: $0.key.column, cell: $0.value) }
        if !entries.isEmpty { try container.encode(entries, forKey: .cells) }
        if defaultColumnWidth != Sheet.standardColumnWidth { try container.encode(defaultColumnWidth, forKey: .defaultColumnWidth) }
        if defaultRowHeight != Sheet.standardRowHeight { try container.encode(defaultRowHeight, forKey: .defaultRowHeight) }
        if !columnWidths.isEmpty { try container.encode(columnWidths, forKey: .columnWidths) }
        if !rowHeights.isEmpty { try container.encode(rowHeights, forKey: .rowHeights) }
        if frozenRows != 0 { try container.encode(frozenRows, forKey: .frozenRows) }
        if frozenColumns != 0 { try container.encode(frozenColumns, forKey: .frozenColumns) }
        if !merges.isEmpty { try container.encode(merges, forKey: .merges) }
        if !hiddenRows.isEmpty { try container.encode(hiddenRows.sorted(), forKey: .hiddenRows) }
        if !hiddenColumns.isEmpty { try container.encode(hiddenColumns.sorted(), forKey: .hiddenColumns) }
        if !showsGridlines { try container.encode(false, forKey: .showsGridlines) }
        try container.encodeIfPresent(tabColor, forKey: .tabColor)
        if !conditionalFormats.isEmpty { try container.encode(conditionalFormats, forKey: .conditionalFormats) }
        if !validations.isEmpty { try container.encode(validations, forKey: .validations) }
        try container.encodeIfPresent(filter, forKey: .filter)
        if !filteredRows.isEmpty { try container.encode(filteredRows.sorted(), forKey: .filteredRows) }
        if !bandings.isEmpty { try container.encode(bandings, forKey: .bandings) }
        if !objects.isEmpty { try container.encode(objects, forKey: .objects) }
        if !pivotTables.isEmpty { try container.encode(pivotTables, forKey: .pivotTables) }
        if !filterViews.isEmpty { try container.encode(filterViews, forKey: .filterViews) }
        if !protections.isEmpty { try container.encode(protections, forKey: .protections) }
        if !rowGroups.isEmpty { try container.encode(rowGroups, forKey: .rowGroups) }
        if !columnGroups.isEmpty { try container.encode(columnGroups, forKey: .columnGroups) }
        if !tables.isEmpty { try container.encode(tables, forKey: .tables) }
    }

    /// The sheet with its comments taken off its cells.
    public var withoutComments: Sheet {
        let commented = cells.filter { $0.value.comment != nil }
        guard !commented.isEmpty else { return self }
        var sheet = self
        sheet.setCells(commented.mapValues(\.withoutComment))
        return sheet
    }

    /// The sheet without its cells or anything else in it: its identity, name and size.
    var skeleton: Sheet { Sheet(name: name, id: id, rowCount: rowCount, columnCount: columnCount) }
}

extension Workbook: Codable {
    private enum CodingKeys: String, CodingKey { case sheets, namedRanges }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sheets: try container.decode([Sheet].self, forKey: .sheets),
                  namedRanges: try container.decodeIfPresent([NamedRange].self, forKey: .namedRanges) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sheets, forKey: .sheets)
        if !namedRanges.isEmpty { try container.encode(namedRanges, forKey: .namedRanges) }
    }

    /// The workbook with every comment taken off its cells.
    public var withoutComments: Workbook {
        var workbook = self
        for index in workbook.sheets.indices { workbook.sheets[index] = workbook.sheets[index].withoutComments }
        return workbook
    }

    /// Every comment thread on a cell, by thread, with where it is.
    public var commentPlaces: [UUID: (sheet: UUID, address: CellAddress, thread: CommentThread)] {
        var result: [UUID: (sheet: UUID, address: CellAddress, thread: CommentThread)] = [:]
        for sheet in sheets {
            for (address, cell) in sheet.cells {
                if let thread = cell.comment { result[thread.id] = (sheet.id, address, thread) }
            }
        }
        return result
    }
}

/// Encoding for what travels: JSON, which keeps numbers exactly and needs no schema, with non-numbers spelled out.
enum SyncCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    static func encode(_ value: some Encodable) -> Data {
        (try? encoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }
}
