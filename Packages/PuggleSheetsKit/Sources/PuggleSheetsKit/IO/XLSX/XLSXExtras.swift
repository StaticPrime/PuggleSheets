import Foundation

/// What PuggleSheets keeps that Excel has no place for, in a custom XML part of its own
/// (customXml/item1.xml): filter views, protected ranges exactly as set, notes on cells that also hold
/// a comment thread, and what Excel's threaded comments leave out (thread ids, edit dates). Excel
/// carries custom XML parts along unchanged and ignores them.
///
/// The root is named after the part's first use, filter views, so earlier versions still find them.
///
///     <filterViews xmlns="http://schemas.pugglesoft.com/pugglesheets/2026/filterViews">
///       <sheet sheetId="1" name="Sales">
///         <filterView id="…" name="East only" range="A1:D20">
///           <criterion column="2"><hide value="West"/><condition kind="greaterThan"><value>10</value></condition></criterion>
///         </filterView>
///         <protectedRange id="…" description="Totals" warningOnly="1" range="E2:E40"/>
///         <protectedRange id="…" warningOnly="0" wholeSheet="1"><except range="B2:C9"/></protectedRange>
///         <note thread="{first comment's id}">Text</note>
///         <thread root="{first comment's id}" id="{thread id}"><edited comment="{comment id}" date="2026-11-16T09:30:00Z"/></thread>
///         <table name="Orders" id="…" color="1A73E8" range="A1:D20"><columnType column="3" type="dropdown"><item>Open</item></columnType>
///           <criterion column="2">…</criterion></table>
///         <slicer position="1" id="…" range="Orders" filterColumn="2" caption="" pivots="1" table="Orders" row="3" column="6"
///           offsetX="0" offsetY="0" width="180" height="240"><criterion>…</criterion></slicer>
///       </sheet>
///     </filterViews>
///
/// Sheets are given by their `sheetId` (index + 1, as the workbook part numbers them), which Excel
/// keeps when sheets are renamed or moved, and by name. Notes and threads are tied to the thread's
/// first comment, which Excel keeps with its cell when rows and columns move.
enum XLSXExtras {
    static let namespace = "http://schemas.pugglesoft.com/pugglesheets/2026/filterViews"
    /// The custom XML part's id; one part per workbook, so it can be fixed.
    static let itemID = "{5C2F7E8A-9B41-4D6E-8F3A-2B7C1D9E0A64}"

    /// One sheet's share of the part.
    struct SheetExtras: Equatable {
        var filterViews: [FilterView] = []
        var protections: [ProtectedRange] = []
        /// Notes of cells with a thread, by the thread's first comment id (normalized).
        var notes: [String: String] = [:]
        /// Thread ids, by the thread's first comment id (normalized).
        var threadIDs: [String: UUID] = [:]
        /// Edit dates, by comment id (normalized).
        var editedDates: [String: Date] = [:]
        /// Tables' details Excel's tables don't hold, by lowercased name.
        var tables: [String: TableDetails] = [:]
        /// Slicers, with their positions among the sheet's objects (back to front).
        var slicers: [Slicer] = []

        var isEmpty: Bool { self == SheetExtras() }
    }

    struct TableDetails: Equatable {
        var id: UUID
        var color: RGBColor
        var columnTypes: [Int: TableColumnType]
        var criteria: [Int: FilterCriterion]
        /// The range as set, which Excel's table may have grown (a table needs a data row there).
        var range: CellRange?
    }

    struct Slicer: Equatable {
        var position: Int
        var object: SheetObject
        /// The Excel table it was also written for as an Excel slicer; nil when it lives only here.
        var table: String?
    }

    /// What a sheet contributes: its filter views, protections, tables' details and slicers, and the
    /// notes and thread details of its `commented` cells (from `XLSXCellFeatures`). `nativeSlicers` gives
    /// the table each slicer written as an Excel slicer belongs to.
    static func extras(of sheet: Sheet, commented: [CellAddress], nativeSlicers: [UUID: String] = [:]) -> SheetExtras {
        var extras = SheetExtras(filterViews: sheet.filterViews, protections: sheet.protections)
        for table in sheet.tables {
            extras.tables[table.name.lowercased()] = TableDetails(id: table.id, color: table.color, columnTypes: table.columnTypes,
                                                                  criteria: table.criteria, range: table.range)
        }
        for (position, object) in sheet.objects.enumerated() where object.slicer != nil {
            extras.slicers.append(Slicer(position: position, object: object, table: nativeSlicers[object.id]))
        }
        for address in commented {
            guard let cell = sheet.cells[address], let thread = cell.comment, let first = thread.comments.first else { continue }
            let root = first.id.uuidString
            if let note = cell.note { extras.notes[root] = note }
            if thread.id != first.id { extras.threadIDs[root] = thread.id }
            for comment in thread.comments {
                if let edited = comment.editedDate { extras.editedDates[comment.id.uuidString] = edited }
            }
        }
        return extras
    }

    /// The part, or nil when no sheet has anything for it. `commented` lists each sheet's cells with notes
    /// or comments.
    static func part(_ sheets: [Sheet], commented: [[CellAddress]], sheetNames: [String], nativeSlicers: [UUID: String] = [:]) -> Data? {
        let all = sheets.indices.map {
            extras(of: sheets[$0], commented: $0 < commented.count ? commented[$0] : [], nativeSlicers: nativeSlicers)
        }
        guard all.contains(where: { !$0.isEmpty }) else { return nil }
        var xml = XMLWriter()
        xml.raw("<filterViews xmlns=\"\(namespace)\">")
        for (index, extras) in all.enumerated() where !extras.isEmpty {
            xml.raw("<sheet sheetId=\"\(index + 1)\"")
            xml.attribute("name", sheetNames[index])
            xml.raw(">")
            for view in extras.filterViews { writeFilterView(view, into: &xml) }
            for protection in extras.protections { writeProtection(protection, into: &xml) }
            for table in sheets[index].tables { writeTable(table, into: &xml) }
            for slicer in extras.slicers { writeSlicer(slicer, into: &xml) }
            for (root, note) in extras.notes.sorted(by: { $0.key < $1.key }) {
                xml.raw("<note")
                xml.attribute("thread", XLSXComments.excelID(UUID(uuidString: root) ?? UUID()))
                xml.raw(">")
                xml.text(note)
                xml.raw("</note>")
            }
            // Thread details, grouped under each thread's first comment.
            var roots = Set(extras.threadIDs.keys)
            var editedByRoot: [String: [(String, Date)]] = [:]
            for address in index < commented.count ? commented[index] : [] {
                guard let thread = sheets[index].cells[address]?.comment, let first = thread.comments.first else { continue }
                let edited = thread.comments.compactMap { comment in comment.editedDate.map { (comment.id.uuidString, $0) } }
                if !edited.isEmpty {
                    editedByRoot[first.id.uuidString] = edited
                    roots.insert(first.id.uuidString)
                }
            }
            for root in roots.sorted() {
                xml.raw("<thread root=\"\(XLSXComments.excelID(UUID(uuidString: root) ?? UUID()))\"")
                if let id = extras.threadIDs[root] { xml.raw(" id=\"\(XLSXComments.excelID(id))\"") }
                xml.raw(">")
                for (comment, date) in editedByRoot[root] ?? [] {
                    xml.raw("<edited comment=\"\(XLSXComments.excelID(UUID(uuidString: comment) ?? UUID()))\" date=\"\(isoDate(date))\"/>")
                }
                xml.raw("</thread>")
            }
            xml.raw("</sheet>")
        }
        xml.raw("</filterViews>")
        return xml.data
    }

    private static func writeFilterView(_ view: FilterView, into xml: inout XMLWriter) {
        xml.raw("<filterView")
        xml.attribute("id", view.id.uuidString)
        xml.attribute("name", view.name)
        xml.attribute("range", view.range.a1)
        xml.raw(">")
        for (column, criterion) in view.criteria.sorted(by: { $0.key < $1.key }) { writeCriterion(criterion, column: column, into: &xml) }
        xml.raw("</filterView>")
    }

    private static func writeCriterion(_ criterion: FilterCriterion, column: Int?, into xml: inout XMLWriter) {
        xml.raw(column.map { "<criterion column=\"\($0)\">" } ?? "<criterion>")
        for value in criterion.hiddenValues.sorted() {
            xml.raw("<hide")
            xml.attribute("value", value)
            xml.raw("/>")
        }
        if let condition = criterion.condition {
            xml.raw("<condition")
            xml.attribute("kind", condition.kind.rawValue)
            xml.raw(">")
            for value in condition.values {
                xml.raw("<value>")
                xml.text(value)
                xml.raw("</value>")
            }
            xml.raw("</condition>")
        }
        xml.raw("</criterion>")
    }

    private static func criterion(_ node: XNode) -> FilterCriterion {
        var item = FilterCriterion(hiddenValues: Set(node.children("hide").compactMap { $0["value"] }))
        if let condition = node.child("condition"), let kind = condition["kind"].flatMap(CellCondition.Kind.init(rawValue:)) {
            item.condition = CellCondition(kind, condition.children("value").map(\.text))
        }
        return item
    }

    private static func writeTable(_ table: SheetTable, into xml: inout XMLWriter) {
        xml.raw("<table")
        xml.attribute("name", table.name)
        xml.attribute("id", table.id.uuidString)
        xml.raw(" color=\"\(table.color.hex)\" range=\"\(table.range.a1)\">")
        for (column, type) in table.columnTypes.sorted(by: { $0.key < $1.key }) {
            let name: String
            var items: [String] = []
            switch type {
            case .text: name = "text"
            case .number: name = "number"
            case .percent: name = "percent"
            case .currency: name = "currency"
            case .date: name = "date"
            case .time: name = "time"
            case .dateTime: name = "dateTime"
            case .checkbox: name = "checkbox"
            case .dropdown(let values):
                name = "dropdown"
                items = values
            }
            xml.raw("<columnType column=\"\(column)\" type=\"\(name)\"")
            guard !items.isEmpty else {
                xml.raw("/>")
                continue
            }
            xml.raw(">")
            for item in items {
                xml.raw("<item>")
                xml.text(item)
                xml.raw("</item>")
            }
            xml.raw("</columnType>")
        }
        for (column, criterion) in table.criteria.sorted(by: { $0.key < $1.key }) { writeCriterion(criterion, column: column, into: &xml) }
        xml.raw("</table>")
    }

    private static func writeSlicer(_ slicer: Slicer, into xml: inout XMLWriter) {
        guard case .slicer(let spec) = slicer.object.content else { return }
        let anchor = slicer.object.anchor
        xml.raw("<slicer position=\"\(slicer.position)\"")
        xml.attribute("id", slicer.object.id.uuidString)
        if !slicer.object.title.isEmpty { xml.attribute("title", slicer.object.title) }
        if !slicer.object.altDescription.isEmpty { xml.attribute("description", slicer.object.altDescription) }
        xml.attribute("range", spec.range)
        xml.raw(" filterColumn=\"\(spec.column)\"")
        xml.attribute("caption", spec.title)
        xml.raw(" pivots=\"\(spec.appliesToPivotTables ? 1 : 0)\"")
        if let color = spec.backgroundColor { xml.raw(" color=\"\(color.hex)\"") }
        if let table = slicer.table { xml.attribute("table", table) }
        xml.raw(" row=\"\(anchor.cell.row)\" column=\"\(anchor.cell.column)\" offsetX=\"\(XLSXValue.string(anchor.offsetX))\" "
            + "offsetY=\"\(XLSXValue.string(anchor.offsetY))\" width=\"\(XLSXValue.string(anchor.width))\" "
            + "height=\"\(XLSXValue.string(anchor.height))\">")
        writeCriterion(spec.criterion, column: nil, into: &xml)
        xml.raw("</slicer>")
    }

    private static func writeProtection(_ protection: ProtectedRange, into xml: inout XMLWriter) {
        xml.raw("<protectedRange")
        xml.attribute("id", protection.id.uuidString)
        if !protection.description.isEmpty { xml.attribute("description", protection.description) }
        xml.raw(" warningOnly=\"\(protection.warningOnly ? 1 : 0)\"")
        switch protection.scope {
        case .range(let range):
            xml.raw(" range=\"\(range.a1)\"/>")
        case .sheet(let except):
            xml.raw(" wholeSheet=\"1\">")
            for range in except { xml.raw("<except range=\"\(range.a1)\"/>") }
            xml.raw("</protectedRange>")
        }
    }

    /// "2026-11-16T09:30:00.250Z".
    static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// The custom XML part's properties part, naming its schema.
    static func propertiesPart() -> Data {
        var xml = XMLWriter()
        xml.raw("<ds:datastoreItem ds:itemID=\"\(itemID)\" xmlns:ds=\"http://schemas.openxmlformats.org/officeDocument/2006/customXml\">")
        xml.raw("<ds:schemaRefs><ds:schemaRef ds:uri=\"\(namespace)\"/></ds:schemaRefs></ds:datastoreItem>")
        return xml.data
    }

    /// Writes the parts and returns the target of the workbook's relationship to them, or nil.
    static func write(_ sheets: [Sheet], commented: [[CellAddress]], sheetNames: [String], nativeSlicers: [UUID: String] = [:],
                      parts: inout XLSXExtraParts) -> String? {
        guard let data = part(sheets, commented: commented, sheetNames: sheetNames, nativeSlicers: nativeSlicers) else { return nil }
        parts.add("customXml/item1.xml", data)
        parts.add("customXml/itemProps1.xml", propertiesPart(), contentType: XLSXContentType.customXmlProperties)
        var relationships = XLSXRelationshipsWriter()
        _ = relationships.add(type: XLSXRelationshipType.customXmlProps, target: "itemProps1.xml")
        parts.add("customXml/_rels/item1.xml.rels", relationships.data())
        return "../customXml/item1.xml"
    }

    /// The part's contents by sheet index. `sheetIDs` maps the workbook's `sheetId`s to sheet indexes,
    /// `sheetNames` lowercased names. Nil when the part isn't PuggleSheets'.
    static func read(_ data: Data, sheetIDs: [Int: Int], sheetNames: [String: Int]) -> [Int: SheetExtras]? {
        guard String(decoding: data.prefix(4096), as: UTF8.self).contains(namespace),
              let root = try? XMLTree.parse(data), root.name == "filterViews" else { return nil }
        var result: [Int: SheetExtras] = [:]
        for sheet in root.children("sheet") {
            guard let index = XLSXValue.int(sheet["sheetId"]).flatMap({ sheetIDs[$0] }) ?? sheet["name"].flatMap({ sheetNames[$0.lowercased()] })
            else { continue }
            var extras = result[index] ?? SheetExtras()
            for node in sheet.children {
                switch node.name {
                case "filterView":
                    if let view = filterView(node) { extras.filterViews.append(view) }
                case "protectedRange":
                    if let protection = protection(node) { extras.protections.append(protection) }
                case "note":
                    if let thread = node["thread"] { extras.notes[XLSXComments.normalizedID(thread)] = node.text }
                case "table":
                    guard let name = node["name"], let id = node["id"].flatMap(UUID.init(uuidString:)),
                          let color = node["color"].flatMap(RGBColor.init(hex:)) else { continue }
                    var types: [Int: TableColumnType] = [:]
                    for column in node.children("columnType") {
                        guard let index = XLSXValue.int(column["column"]), let type = columnType(column) else { continue }
                        types[index] = type
                    }
                    var criteria: [Int: FilterCriterion] = [:]
                    for item in node.children("criterion") {
                        if let column = XLSXValue.int(item["column"]) { criteria[column] = criterion(item) }
                    }
                    extras.tables[name.lowercased()] = TableDetails(id: id, color: color, columnTypes: types, criteria: criteria,
                                                                    range: node["range"].flatMap(CellRange.init(a1:)))
                case "slicer":
                    if let slicer = slicer(node) { extras.slicers.append(slicer) }
                case "thread":
                    guard let root = node["root"].map(XLSXComments.normalizedID) else { continue }
                    if let id = node["id"].flatMap({ UUID(uuidString: XLSXComments.normalizedID($0)) }) { extras.threadIDs[root] = id }
                    for edited in node.children("edited") {
                        if let comment = edited["comment"].map(XLSXComments.normalizedID), let date = date(edited["date"]) {
                            extras.editedDates[comment] = date
                        }
                    }
                default:
                    continue
                }
            }
            result[index] = extras
        }
        return result
    }

    private static func columnType(_ node: XNode) -> TableColumnType? {
        switch node["type"] {
        case "text": .text
        case "number": .number
        case "percent": .percent
        case "currency": .currency
        case "date": .date
        case "time": .time
        case "dateTime": .dateTime
        case "checkbox": .checkbox
        case "dropdown": .dropdown(node.children("item").map(\.text))
        default: nil
        }
    }

    private static func slicer(_ node: XNode) -> Slicer? {
        guard let id = node["id"].flatMap(UUID.init(uuidString:)), let range = node["range"],
              let row = XLSXValue.int(node["row"]), let column = XLSXValue.int(node["column"]), row >= 0, column >= 0,
              let width = XLSXValue.double(node["width"]), let height = XLSXValue.double(node["height"]) else { return nil }
        let anchor = ObjectAnchor(cell: CellAddress(row: row, column: column), offsetX: XLSXValue.double(node["offsetX"]) ?? 0,
                                  offsetY: XLSXValue.double(node["offsetY"]) ?? 0, width: width, height: height)
        let spec = SlicerSpec(range: range, column: max(0, XLSXValue.int(node["filterColumn"]) ?? 0), title: node["caption"] ?? "",
                              criterion: node.child("criterion").map(criterion) ?? FilterCriterion(),
                              appliesToPivotTables: XLSXValue.isOn(node["pivots"]), backgroundColor: node["color"].flatMap(RGBColor.init(hex:)))
        return Slicer(position: max(0, XLSXValue.int(node["position"]) ?? 0),
                      object: SheetObject(id: id, anchor: anchor, content: .slicer(spec), title: node["title"] ?? "",
                                          altDescription: node["description"] ?? ""),
                      table: node["table"])
    }

    private static func filterView(_ node: XNode) -> FilterView? {
        guard let range = CellRange(a1: node["range"] ?? ""), range.end.row < XLSXLimits.rows, range.end.column < XLSXLimits.columns
        else { return nil }
        var criteria: [Int: FilterCriterion] = [:]
        for item in node.children("criterion") {
            guard let column = XLSXValue.int(item["column"]), range.columns.contains(column) else { continue }
            let value = criterion(item)
            if !value.isEmpty { criteria[column] = value }
        }
        let id = node["id"].flatMap(UUID.init(uuidString:)) ?? UUID()
        return FilterView(id: id, name: node["name"] ?? "Filter", range: range, criteria: criteria)
    }

    private static func protection(_ node: XNode) -> ProtectedRange? {
        let scope: ProtectedRange.Scope
        if XLSXValue.isTrue(node["wholeSheet"]) {
            scope = .sheet(except: node.children("except").compactMap { CellRange(a1: $0["range"] ?? "") })
        } else if let range = CellRange(a1: node["range"] ?? "") {
            scope = .range(range)
        } else {
            return nil
        }
        return ProtectedRange(id: node["id"].flatMap(UUID.init(uuidString:)) ?? UUID(), scope: scope, description: node["description"] ?? "",
                              warningOnly: XLSXValue.isTrue(node["warningOnly"]))
    }
}
