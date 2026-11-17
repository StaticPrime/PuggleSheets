import Foundation

/// Chart settings OpenDocument has no place for: the ranges as typed (named ranges included), the
/// aggregation, the legend's "auto" position, and the settings a chart's kind doesn't use (axes of a
/// pie chart, a column chart's pie hole), which come back if the kind is changed again. Kept with a
/// fingerprint of the series the chart object was written with, so they're used only while the
/// chart is unchanged.
struct ODSChartExtras: Equatable {
    /// "Object 1".
    var object: String
    var ranges: [String]
    var aggregation: ChartSpec.Aggregation?
    var legend: ChartSpec.LegendPosition
    var fingerprint: String
    /// Settings some kinds don't write.
    var horizontalAxisTitle = ""
    var verticalAxisTitle = ""
    var verticalMinimum: Double?
    var verticalMaximum: Double?
    var logScale = false
    var showsDataLabels = false
    var pieHole = 0.5
    var pieSliceLabel = ChartSpec.PieLabel.percentage

    init(object: String, spec: ChartSpec, fingerprint: String) {
        self.object = object
        ranges = spec.ranges
        aggregation = spec.aggregation
        legend = spec.legend
        self.fingerprint = fingerprint
        horizontalAxisTitle = spec.horizontalAxisTitle
        verticalAxisTitle = spec.verticalAxisTitle
        verticalMinimum = spec.verticalMinimum
        verticalMaximum = spec.verticalMaximum
        logScale = spec.logScale
        showsDataLabels = spec.showsDataLabels
        pieHole = spec.pieHole
        pieSliceLabel = spec.pieSliceLabel
    }

    init(object: String, ranges: [String], aggregation: ChartSpec.Aggregation?, legend: ChartSpec.LegendPosition, fingerprint: String) {
        self.object = object
        self.ranges = ranges
        self.aggregation = aggregation
        self.legend = legend
        self.fingerprint = fingerprint
    }

    func apply(to spec: inout ChartSpec) {
        if !ranges.isEmpty { spec.ranges = ranges }
        spec.aggregation = aggregation
        // Only "auto" and "right" share a form in the file.
        if spec.legend == .auto || spec.legend == .right, legend == .auto || legend == .right { spec.legend = legend }
        let isPie = spec.kind == .pie || spec.kind == .donut
        if isPie {
            spec.horizontalAxisTitle = horizontalAxisTitle
            spec.verticalAxisTitle = verticalAxisTitle
            spec.verticalMinimum = verticalMinimum
            spec.verticalMaximum = verticalMaximum
            spec.logScale = logScale
            spec.showsDataLabels = showsDataLabels
        } else {
            spec.pieSliceLabel = pieSliceLabel
        }
        // The file rounds the hole to whole percents.
        if spec.kind != .donut || (pieHole * 100).rounded() == (spec.pieHole * 100).rounded() { spec.pieHole = pieHole }
    }

    private static func token(_ range: ODSSheetRange) -> String { "\(range.sheet):\(range.range.a1)" }
    private static func token(_ cell: ODSSheetCell?) -> String { cell.map { "\($0.sheet):\($0.address.a1)" } ?? "-" }

    /// The series and labels a written chart object holds.
    static func fingerprint(layout: ODSChartLayout?, kind: ChartSpec.Kind) -> String {
        let all = layout?.series ?? []
        let series = kind == .pie || kind == .donut ? Array(all.prefix(1)) : all
        return series.map { $0.blocks.map(token).joined(separator: ",") + "@" + token($0.name) }.joined(separator: ";")
            + "|" + (layout?.labelBlocks ?? []).map(token).joined(separator: ",")
    }

    /// The series and labels of a chart object read from a file.
    static func fingerprint(series: [ODSChartReader.FileSeries], kind: ChartSpec.Kind, categories: [ODSSheetRange]) -> String {
        series.map { $0.values.map(token).joined(separator: ",") + "@" + token($0.label) }.joined(separator: ";")
            + "|" + categories.map(token).joined(separator: ",")
    }
}

/// A pivot table as PuggleSheets defines it, for what LibreOffice's DataPilot can't hold (COUNTUNIQUE,
/// conditions, totals by group), kept with a fingerprint of the DataPilot table written for it.
struct ODSPivotExtras: Equatable {
    /// The DataPilot table's name.
    var name: String
    var pivot: PivotTable
    var fingerprint: String
}

/// A comment thread as PuggleSheets keeps it, and what the cell's annotation was written from.
struct ODSCommentExtras: Equatable {
    var address: CellAddress
    var thread: CommentThread
    var content: ODSAnnotations.Content
    /// The cell's note, when the annotation holds it and the thread.
    var note: String?
}

/// A table as PuggleSheets keeps it, for what LibreOffice's database ranges have no place for: its color,
/// its column types and its exact criteria (the file's filter can't hold every condition), and its name and id.
struct ODSTableExtras: Equatable {
    /// The database range's name, as written.
    var rangeName: String
    var id: UUID
    var name: String
    var color: RGBColor
    /// Column types and criteria by position in the table (0 is its first column).
    var columnTypes: [Int: TableColumnType]
    var criteria: [Int: FilterCriterion]
    /// The filter written for the criteria (`ODSRules.filterFingerprint`): they apply only while the file's
    /// filter is the same.
    var filterFingerprint: String

    init(rangeName: String, id: UUID, name: String, color: RGBColor, columnTypes: [Int: TableColumnType], criteria: [Int: FilterCriterion],
         filterFingerprint: String) {
        self.rangeName = rangeName
        self.id = id
        self.name = name
        self.color = color
        self.columnTypes = columnTypes
        self.criteria = criteria
        self.filterFingerprint = filterFingerprint
    }

    init(_ table: SheetTable, filterFingerprint: String) {
        func byPosition<Value>(_ values: [Int: Value]) -> [Int: Value] {
            var result: [Int: Value] = [:]
            for (column, value) in values where table.range.columns.contains(column) { result[column - table.range.start.column] = value }
            return result
        }
        self.init(rangeName: table.name, id: table.id, name: table.name, color: table.color, columnTypes: byPosition(table.columnTypes),
                  criteria: byPosition(table.criteria), filterFingerprint: filterFingerprint)
    }
}

/// A slicer, which OpenDocument has no place for, and its place among the sheet's objects.
struct ODSSlicerExtras: Equatable {
    var index: Int
    var id: UUID
    var anchor: ObjectAnchor
    var spec: SlicerSpec
    var title: String
    var description: String

    var object: SheetObject { SheetObject(id: id, anchor: anchor, content: .slicer(spec), title: title, altDescription: description) }
}

/// A formula as typed, where the file has the cells its structured references cover (OpenFormula has no
/// table references), and the `table:formula` written: it applies only while the cell's formula is that.
struct ODSFormulaExtras: Equatable {
    var address: CellAddress
    var formula: String
    var fingerprint: String
}

/// What a sheet keeps in PuggleSheets' settings.
struct ODSSheetSettings {
    /// The sheet's name as written.
    var name: String
    var filterViews: [FilterView] = []
    var comments: [ODSCommentExtras] = []
    var protections: [ProtectedRange] = []
    /// Rows and columns hidden by hand inside collapsed groups (the file can't tell them from the group's).
    var hiddenRows: [ClosedRange<Int>] = []
    var hiddenColumns: [ClosedRange<Int>] = []
    var tables: [ODSTableExtras] = []
    var slicers: [ODSSlicerExtras] = []
    var formulas: [ODSFormulaExtras] = []

    var isEmpty: Bool {
        filterViews.isEmpty && comments.isEmpty && protections.isEmpty && hiddenRows.isEmpty && hiddenColumns.isEmpty && tables.isEmpty
            && slicers.isEmpty && formulas.isEmpty
    }

    /// Runs of consecutive indexes.
    static func runs(_ indexes: some Sequence<Int>) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for index in indexes.sorted() {
            if let last = result.last, last.upperBound + 1 == index {
                result[result.count - 1] = last.lowerBound...index
            } else if result.last?.contains(index) != true {
                result.append(index...index)
            }
        }
        return result
    }
}

/// PuggleSheets' own settings in settings.xml: filter views, comment threads, protected ranges, rows and
/// columns hidden inside collapsed groups, slicers, and the table, formula, chart and pivot table settings
/// above. LibreOffice ignores this `config:config-item-set` and doesn't keep it when it saves, so none of it
/// can go stale.
enum ODSPuggleSettings {
    static let setName = "PuggleSheets:settings"

    struct Contents {
        /// What each sheet keeps, by sheet name (as written).
        var sheets: [String: ODSSheetSettings] = [:]
        var charts: [String: ODSChartExtras] = [:]
        var pivots: [String: ODSPivotExtras] = [:]
    }

    // MARK: - Writing

    private static func item(_ name: String, _ type: String, _ value: String, into xml: inout XMLWriter) {
        xml.raw("<config:config-item config:name=\"\(name)\" config:type=\"\(type)\">")
        xml.text(value)
        xml.raw("</config:config-item>")
    }

    /// An indexed map of entries; nothing when there are none (maps need an entry).
    private static func indexed<T>(_ name: String, _ items: [T], into xml: inout XMLWriter, entry: (T, inout XMLWriter) -> Void) {
        guard !items.isEmpty else { return }
        xml.raw("<config:config-item-map-indexed config:name=\"\(name)\">")
        for value in items {
            xml.raw("<config:config-item-map-entry>")
            entry(value, &xml)
            xml.raw("</config:config-item-map-entry>")
        }
        xml.raw("</config:config-item-map-indexed>")
    }

    private static func strings(_ name: String, _ values: [String], into xml: inout XMLWriter) {
        indexed(name, values, into: &xml) { value, xml in item("Value", "string", value, into: &xml) }
    }

    private static func criterion(_ criterion: FilterCriterion, into xml: inout XMLWriter) {
        if let condition = criterion.condition {
            item("Condition", "string", condition.kind.rawValue, into: &xml)
            strings("Values", condition.values, into: &xml)
        }
        strings("HiddenValues", criterion.hiddenValues.sorted(), into: &xml)
    }

    private static func groups(_ name: String, _ groups: [PivotGroup], into xml: inout XMLWriter) {
        indexed(name, groups, into: &xml) { group, xml in
            item("SourceColumn", "int", String(group.sourceColumn), into: &xml)
            item("Ascending", "boolean", group.ascending ? "true" : "false", into: &xml)
            item("ShowsTotals", "boolean", group.showsTotals ? "true" : "false", into: &xml)
            if let value = group.sortByValue { item("SortByValue", "int", String(value), into: &xml) }
        }
    }

    /// The set, or nothing when there's nothing to keep.
    private static func date(_ date: Date) -> String { XLSXValue.string(date.timeIntervalSinceReferenceDate) }

    private static func ranges(_ name: String, _ ranges: [ClosedRange<Int>], into xml: inout XMLWriter) {
        indexed(name, ranges, into: &xml) { range, xml in
            item("First", "int", String(range.lowerBound), into: &xml)
            item("Last", "int", String(range.upperBound), into: &xml)
        }
    }

    /// A finite number as a `double` item; nothing for others.
    private static func number(_ name: String, _ value: Double, into xml: inout XMLWriter) {
        if value.isFinite { item(name, "double", XLSXValue.string(value), into: &xml) }
    }

    static func write(sheets: [ODSSheetSettings], charts: [ODSChartExtras], pivots: [ODSPivotExtras], into xml: inout XMLWriter) {
        let views = sheets.flatMap { sheet in sheet.filterViews.map { (sheet.name, $0) } }
        let comments = sheets.flatMap { sheet in sheet.comments.map { (sheet.name, $0) } }
        let protections = sheets.flatMap { sheet in sheet.protections.map { (sheet.name, $0) } }
        let hidden = sheets.filter { !$0.hiddenRows.isEmpty || !$0.hiddenColumns.isEmpty }
        let tables = sheets.flatMap { sheet in sheet.tables.map { (sheet.name, $0) } }
        let slicers = sheets.flatMap { sheet in sheet.slicers.map { (sheet.name, $0) } }
        let formulas = sheets.flatMap { sheet in sheet.formulas.map { (sheet.name, $0) } }
        guard !views.isEmpty || !comments.isEmpty || !protections.isEmpty || !hidden.isEmpty || !tables.isEmpty || !slicers.isEmpty
            || !formulas.isEmpty || !charts.isEmpty || !pivots.isEmpty else { return }
        xml.raw("<config:config-item-set config:name=\"\(setName)\">")
        item("Version", "int", "1", into: &xml)
        indexed("Tables", tables, into: &xml) { pair, xml in
            let (sheet, table) = pair
            item("Sheet", "string", sheet, into: &xml)
            item("DatabaseRange", "string", table.rangeName, into: &xml)
            item("Id", "string", table.id.uuidString, into: &xml)
            item("Name", "string", table.name, into: &xml)
            item("Color", "string", table.color.hex, into: &xml)
            item("FilterFingerprint", "string", table.filterFingerprint, into: &xml)
            indexed("ColumnTypes", table.columnTypes.sorted { $0.key < $1.key }, into: &xml) { pair, xml in
                item("Column", "int", String(pair.key), into: &xml)
                item("Type", "string", pair.value.settingsName, into: &xml)
                if case .dropdown(let values) = pair.value { strings("Values", values, into: &xml) }
            }
            indexed("Criteria", table.criteria.sorted { $0.key < $1.key }, into: &xml) { pair, xml in
                item("Column", "int", String(pair.key), into: &xml)
                criterion(pair.value, into: &xml)
            }
        }
        indexed("Slicers", slicers, into: &xml) { pair, xml in
            let (sheet, slicer) = pair
            item("Sheet", "string", sheet, into: &xml)
            item("Index", "int", String(slicer.index), into: &xml)
            item("Id", "string", slicer.id.uuidString, into: &xml)
            item("Cell", "string", slicer.anchor.cell.a1, into: &xml)
            number("OffsetX", slicer.anchor.offsetX, into: &xml)
            number("OffsetY", slicer.anchor.offsetY, into: &xml)
            number("Width", slicer.anchor.width, into: &xml)
            number("Height", slicer.anchor.height, into: &xml)
            item("Title", "string", slicer.title, into: &xml)
            item("Description", "string", slicer.description, into: &xml)
            item("Source", "string", slicer.spec.range, into: &xml)
            item("Column", "int", String(slicer.spec.column), into: &xml)
            item("Heading", "string", slicer.spec.title, into: &xml)
            item("AppliesToPivotTables", "boolean", slicer.spec.appliesToPivotTables ? "true" : "false", into: &xml)
            if let color = slicer.spec.backgroundColor { item("BackgroundColor", "string", color.hex, into: &xml) }
            criterion(slicer.spec.criterion, into: &xml)
        }
        indexed("Formulas", formulas, into: &xml) { pair, xml in
            let (sheet, formula) = pair
            item("Sheet", "string", sheet, into: &xml)
            item("Cell", "string", formula.address.a1, into: &xml)
            item("Formula", "string", formula.formula, into: &xml)
            item("Fingerprint", "string", formula.fingerprint, into: &xml)
        }
        indexed("Comments", comments, into: &xml) { pair, xml in
            let (sheet, extras) = pair
            item("Sheet", "string", sheet, into: &xml)
            item("Cell", "string", extras.address.a1, into: &xml)
            item("Id", "string", extras.thread.id.uuidString, into: &xml)
            item("Resolved", "boolean", extras.thread.isResolved ? "true" : "false", into: &xml)
            item("Annotation", "string", extras.content.rawValue, into: &xml)
            if let note = extras.note { item("Note", "string", note, into: &xml) }
            indexed("Comments", extras.thread.comments, into: &xml) { comment, xml in
                item("Id", "string", comment.id.uuidString, into: &xml)
                item("Author", "string", comment.author, into: &xml)
                item("Date", "double", date(comment.date), into: &xml)
                item("Text", "string", comment.text, into: &xml)
                if let edited = comment.editedDate { item("EditedDate", "double", date(edited), into: &xml) }
            }
        }
        indexed("Protections", protections, into: &xml) { pair, xml in
            let (sheet, protection) = pair
            item("Sheet", "string", sheet, into: &xml)
            item("Id", "string", protection.id.uuidString, into: &xml)
            item("Description", "string", protection.description, into: &xml)
            item("WarningOnly", "boolean", protection.warningOnly ? "true" : "false", into: &xml)
            switch protection.scope {
            case .range(let range):
                item("Range", "string", range.a1, into: &xml)
            case .sheet(let except):
                item("Scope", "string", "sheet", into: &xml)
                strings("Except", except.map(\.a1), into: &xml)
            }
        }
        indexed("HiddenInGroups", hidden, into: &xml) { sheet, xml in
            item("Sheet", "string", sheet.name, into: &xml)
            ranges("Rows", sheet.hiddenRows, into: &xml)
            ranges("Columns", sheet.hiddenColumns, into: &xml)
        }
        indexed("FilterViews", views, into: &xml) { pair, xml in
            let (sheet, view) = pair
            item("Sheet", "string", sheet, into: &xml)
            item("Id", "string", view.id.uuidString, into: &xml)
            item("Name", "string", view.name, into: &xml)
            item("Range", "string", view.range.a1, into: &xml)
            indexed("Criteria", view.criteria.sorted { $0.key < $1.key }, into: &xml) { pair, xml in
                item("Column", "int", String(pair.key), into: &xml)
                criterion(pair.value, into: &xml)
            }
        }
        indexed("Charts", charts, into: &xml) { chart, xml in
            item("Object", "string", chart.object, into: &xml)
            item("Fingerprint", "string", chart.fingerprint, into: &xml)
            item("Legend", "string", chart.legend.rawValue, into: &xml)
            if let aggregation = chart.aggregation { item("Aggregation", "string", aggregation.rawValue, into: &xml) }
            strings("Ranges", chart.ranges, into: &xml)
            item("HorizontalAxisTitle", "string", chart.horizontalAxisTitle, into: &xml)
            item("VerticalAxisTitle", "string", chart.verticalAxisTitle, into: &xml)
            if let minimum = chart.verticalMinimum, minimum.isFinite { item("VerticalMinimum", "double", XLSXValue.string(minimum), into: &xml) }
            if let maximum = chart.verticalMaximum, maximum.isFinite { item("VerticalMaximum", "double", XLSXValue.string(maximum), into: &xml) }
            item("LogScale", "boolean", chart.logScale ? "true" : "false", into: &xml)
            item("ShowsDataLabels", "boolean", chart.showsDataLabels ? "true" : "false", into: &xml)
            if chart.pieHole.isFinite { item("PieHole", "double", XLSXValue.string(chart.pieHole), into: &xml) }
            item("PieSliceLabel", "string", chart.pieSliceLabel.rawValue, into: &xml)
        }
        indexed("PivotTables", pivots, into: &xml) { extras, xml in
            let pivot = extras.pivot
            item("Name", "string", extras.name, into: &xml)
            item("Fingerprint", "string", extras.fingerprint, into: &xml)
            item("Id", "string", pivot.id.uuidString, into: &xml)
            item("Anchor", "string", pivot.anchor.a1, into: &xml)
            item("Source", "string", pivot.source, into: &xml)
            item("ValuesInRows", "boolean", pivot.valuesInRows ? "true" : "false", into: &xml)
            groups("Rows", pivot.rows, into: &xml)
            groups("Columns", pivot.columns, into: &xml)
            indexed("Values", pivot.values, into: &xml) { value, xml in
                item("SourceColumn", "int", String(value.sourceColumn), into: &xml)
                item("Summary", "string", value.summary.rawValue, into: &xml)
                item("ShowAs", "string", value.showAs.rawValue, into: &xml)
                if let name = value.name { item("Name", "string", name, into: &xml) }
            }
            indexed("Filters", pivot.filters, into: &xml) { filter, xml in
                item("SourceColumn", "int", String(filter.sourceColumn), into: &xml)
                criterion(filter.criterion, into: &xml)
            }
        }
        xml.raw("</config:config-item-set>")
    }

    // MARK: - Reading

    private static func items(_ entry: XNode) -> [String: String] {
        var result: [String: String] = [:]
        for item in entry.children("config-item") {
            if let name = item["name"] { result[name] = item.text }
        }
        return result
    }

    private static func entries(_ parent: XNode, _ name: String) -> [XNode] {
        parent.children.first { ($0.name == "config-item-map-indexed" || $0.name == "config-item-map-named") && $0["name"] == name }?
            .children("config-item-map-entry") ?? []
    }

    private static func strings(_ parent: XNode, _ name: String) -> [String] {
        entries(parent, name).compactMap { items($0)["Value"] }
    }

    private static func criterion(_ entry: XNode) -> FilterCriterion {
        var criterion = FilterCriterion(hiddenValues: Set(strings(entry, "HiddenValues")))
        if let kind = items(entry)["Condition"].flatMap(CellCondition.Kind.init(rawValue:)) {
            criterion.condition = CellCondition(kind, strings(entry, "Values"))
        }
        return criterion
    }

    private static func groups(_ parent: XNode, _ name: String) -> [PivotGroup]? {
        var result: [PivotGroup] = []
        for entry in entries(parent, name) {
            let values = items(entry)
            guard let column = XLSXValue.int(values["SourceColumn"]), column >= 0 else { return nil }
            result.append(PivotGroup(sourceColumn: column, ascending: values["Ascending"] != "false", showsTotals: values["ShowsTotals"] != "false",
                                     sortByValue: XLSXValue.int(values["SortByValue"])))
        }
        return result
    }

    private static func pivot(_ entry: XNode) -> ODSPivotExtras? {
        let values = items(entry)
        guard let name = values["Name"], let fingerprint = values["Fingerprint"], let source = values["Source"],
              let anchor = values["Anchor"].flatMap({ CellAddress(a1: $0) }),
              let rows = groups(entry, "Rows"), let columns = groups(entry, "Columns") else { return nil }
        var pivotValues: [PivotValue] = []
        for item in entries(entry, "Values") {
            let fields = items(item)
            guard let column = XLSXValue.int(fields["SourceColumn"]), column >= 0,
                  let summary = fields["Summary"].flatMap(PivotValue.Summary.init(rawValue:)) else { return nil }
            pivotValues.append(PivotValue(sourceColumn: column, summary: summary,
                                          showAs: fields["ShowAs"].flatMap(PivotValue.ShowAs.init(rawValue:)) ?? .default, name: fields["Name"]))
        }
        var filters: [PivotFilter] = []
        for item in entries(entry, "Filters") {
            guard let column = XLSXValue.int(items(item)["SourceColumn"]), column >= 0 else { return nil }
            filters.append(PivotFilter(sourceColumn: column, criterion: criterion(item)))
        }
        let pivot = PivotTable(id: values["Id"].flatMap(UUID.init(uuidString:)) ?? UUID(), anchor: anchor, source: source, rows: rows,
                               columns: columns, values: pivotValues, filters: filters, valuesInRows: values["ValuesInRows"] == "true")
        return ODSPivotExtras(name: name, pivot: pivot, fingerprint: fingerprint)
    }

    /// A date kept as seconds since 2001; nil for one beyond a few thousand years either way.
    private static func date(_ text: String?) -> Date? {
        guard let seconds = XLSXValue.double(text), abs(seconds) < 1e11 else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static func ranges(_ parent: XNode, _ name: String) -> [ClosedRange<Int>] {
        entries(parent, name).compactMap { entry in
            let values = items(entry)
            guard let first = XLSXValue.int(values["First"]), let last = XLSXValue.int(values["Last"]), first >= 0, first <= last else { return nil }
            return first...last
        }
    }

    private static func thread(_ entry: XNode) -> CommentThread? {
        var comments: [Comment] = []
        for item in entries(entry, "Comments") {
            let values = items(item)
            guard let posted = date(values["Date"]) else { return nil }
            comments.append(Comment(id: values["Id"].flatMap(UUID.init(uuidString:)) ?? UUID(), author: values["Author"] ?? "", date: posted,
                                    text: values["Text"] ?? "", editedDate: date(values["EditedDate"])))
        }
        guard !comments.isEmpty else { return nil }
        let values = items(entry)
        return CommentThread(id: values["Id"].flatMap(UUID.init(uuidString:)) ?? UUID(), comments: comments, isResolved: values["Resolved"] == "true")
    }

    private static func protection(_ entry: XNode) -> ProtectedRange? {
        let values = items(entry)
        let scope: ProtectedRange.Scope
        if values["Scope"] == "sheet" {
            scope = .sheet(except: strings(entry, "Except").compactMap { CellRange(a1: $0) })
        } else if let range = values["Range"].flatMap({ CellRange(a1: $0) }) {
            scope = .range(range)
        } else {
            return nil
        }
        return ProtectedRange(id: values["Id"].flatMap(UUID.init(uuidString:)) ?? UUID(), scope: scope, description: values["Description"] ?? "",
                              warningOnly: values["WarningOnly"] != "false")
    }

    static func parse(_ data: Data) -> Contents {
        guard let root = try? XMLTree.parse(data),
              let set = root.descendants("config-item-set").first(where: { $0["name"] == setName }) else { return Contents() }
        var contents = Contents()
        func sheet(_ name: String) -> ODSSheetSettings { contents.sheets[name] ?? ODSSheetSettings(name: name) }
        for entry in entries(set, "Comments") {
            let values = items(entry)
            guard let name = values["Sheet"], let address = values["Cell"].flatMap({ CellAddress(a1: $0) }), let thread = thread(entry),
                  let content = values["Annotation"].flatMap(ODSAnnotations.Content.init(rawValue:)) else { continue }
            var settings = sheet(name)
            settings.comments.append(ODSCommentExtras(address: address, thread: thread, content: content, note: values["Note"]))
            contents.sheets[name] = settings
        }
        for entry in entries(set, "Protections") {
            guard let name = items(entry)["Sheet"], let protection = protection(entry) else { continue }
            var settings = sheet(name)
            settings.protections.append(protection)
            contents.sheets[name] = settings
        }
        for entry in entries(set, "HiddenInGroups") {
            guard let name = items(entry)["Sheet"] else { continue }
            var settings = sheet(name)
            settings.hiddenRows += ranges(entry, "Rows")
            settings.hiddenColumns += ranges(entry, "Columns")
            contents.sheets[name] = settings
        }
        for entry in entries(set, "FilterViews") {
            let values = items(entry)
            guard let sheet = values["Sheet"], let range = values["Range"].flatMap({ CellRange(a1: $0) }) else { continue }
            var criteria: [Int: FilterCriterion] = [:]
            for item in entries(entry, "Criteria") {
                guard let column = XLSXValue.int(items(item)["Column"]), range.columns.contains(column) else { continue }
                criteria[column] = criterion(item)
            }
            let view = FilterView(id: values["Id"].flatMap(UUID.init(uuidString:)) ?? UUID(), name: values["Name"] ?? "Filter",
                                  range: range, criteria: criteria)
            var settings = contents.sheets[sheet] ?? ODSSheetSettings(name: sheet)
            settings.filterViews.append(view)
            contents.sheets[sheet] = settings
        }
        for entry in entries(set, "Charts") {
            let values = items(entry)
            guard let object = values["Object"], let fingerprint = values["Fingerprint"] else { continue }
            var extras = ODSChartExtras(object: object, ranges: strings(entry, "Ranges"),
                                        aggregation: values["Aggregation"].flatMap(ChartSpec.Aggregation.init(rawValue:)),
                                        legend: values["Legend"].flatMap(ChartSpec.LegendPosition.init(rawValue:)) ?? .auto,
                                        fingerprint: fingerprint)
            extras.horizontalAxisTitle = values["HorizontalAxisTitle"] ?? ""
            extras.verticalAxisTitle = values["VerticalAxisTitle"] ?? ""
            extras.verticalMinimum = XLSXValue.double(values["VerticalMinimum"])
            extras.verticalMaximum = XLSXValue.double(values["VerticalMaximum"])
            extras.logScale = values["LogScale"] == "true"
            extras.showsDataLabels = values["ShowsDataLabels"] == "true"
            extras.pieHole = XLSXValue.double(values["PieHole"]) ?? 0.5
            extras.pieSliceLabel = values["PieSliceLabel"].flatMap(ChartSpec.PieLabel.init(rawValue:)) ?? .percentage
            contents.charts[object] = extras
        }
        for entry in entries(set, "PivotTables") {
            if let extras = pivot(entry) { contents.pivots[extras.name] = extras }
        }
        for entry in entries(set, "Tables") {
            guard let name = items(entry)["Sheet"], let table = table(entry) else { continue }
            var settings = sheet(name)
            settings.tables.append(table)
            contents.sheets[name] = settings
        }
        for entry in entries(set, "Slicers") {
            guard let name = items(entry)["Sheet"], let slicer = slicer(entry) else { continue }
            var settings = sheet(name)
            settings.slicers.append(slicer)
            contents.sheets[name] = settings
        }
        for entry in entries(set, "Formulas") {
            let values = items(entry)
            guard let name = values["Sheet"], let address = values["Cell"].flatMap({ CellAddress(a1: $0) }), let formula = values["Formula"],
                  formula.hasPrefix("="), let fingerprint = values["Fingerprint"] else { continue }
            var settings = sheet(name)
            settings.formulas.append(ODSFormulaExtras(address: address, formula: formula, fingerprint: fingerprint))
            contents.sheets[name] = settings
        }
        return contents
    }

    private static func table(_ entry: XNode) -> ODSTableExtras? {
        let values = items(entry)
        guard let rangeName = values["DatabaseRange"], let name = values["Name"] else { return nil }
        var columnTypes: [Int: TableColumnType] = [:]
        for item in entries(entry, "ColumnTypes") {
            let fields = items(item)
            guard let column = XLSXValue.int(fields["Column"]), column >= 0, column < ODSWriter.maximumColumns,
                  let type = TableColumnType(settingsName: fields["Type"], values: strings(item, "Values")) else { continue }
            columnTypes[column] = type
        }
        var criteria: [Int: FilterCriterion] = [:]
        for item in entries(entry, "Criteria") {
            guard let column = XLSXValue.int(items(item)["Column"]), column >= 0, column < ODSWriter.maximumColumns else { continue }
            criteria[column] = criterion(item)
        }
        return ODSTableExtras(rangeName: rangeName, id: values["Id"].flatMap(UUID.init(uuidString:)) ?? UUID(), name: name,
                              color: values["Color"].flatMap(RGBColor.init(hex:)) ?? SheetTable.colors[0], columnTypes: columnTypes,
                              criteria: criteria, filterFingerprint: values["FilterFingerprint"] ?? "")
    }

    private static func slicer(_ entry: XNode) -> ODSSlicerExtras? {
        let values = items(entry)
        guard let cell = values["Cell"].flatMap({ CellAddress(a1: $0) }), let source = values["Source"] else { return nil }
        // Pixels, within reason.
        func length(_ name: String) -> Double {
            guard let value = XLSXValue.double(values[name]), value.isFinite, abs(value) < 1e7 else { return 0 }
            return value
        }
        let anchor = ObjectAnchor(cell: cell, offsetX: length("OffsetX"), offsetY: length("OffsetY"), width: max(0, length("Width")),
                                  height: max(0, length("Height")))
        let spec = SlicerSpec(range: source, column: max(0, XLSXValue.int(values["Column"]) ?? 0), title: values["Heading"] ?? "",
                              criterion: criterion(entry), appliesToPivotTables: values["AppliesToPivotTables"] != "false",
                              backgroundColor: values["BackgroundColor"].flatMap(RGBColor.init(hex:)))
        return ODSSlicerExtras(index: max(0, XLSXValue.int(values["Index"]) ?? Int.max), id: values["Id"].flatMap(UUID.init(uuidString:)) ?? UUID(),
                               anchor: anchor, spec: spec, title: values["Title"] ?? "", description: values["Description"] ?? "")
    }
}

/// Table column types as PuggleSheets' settings name them.
private extension TableColumnType {
    var settingsName: String {
        switch self {
        case .text: "text"
        case .number: "number"
        case .percent: "percent"
        case .currency: "currency"
        case .date: "date"
        case .time: "time"
        case .dateTime: "dateTime"
        case .checkbox: "checkbox"
        case .dropdown: "dropdown"
        }
    }

    init?(settingsName: String?, values: [String]) {
        switch settingsName {
        case "text": self = .text
        case "number": self = .number
        case "percent": self = .percent
        case "currency": self = .currency
        case "date": self = .date
        case "time": self = .time
        case "dateTime": self = .dateTime
        case "checkbox": self = .checkbox
        case "dropdown": self = .dropdown(values)
        default: return nil
        }
    }
}
