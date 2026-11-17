import AppKit
import PuggleSheetsKit

/// Phase 3's edits: images and charts over the grid, images in cells, links, pivot tables and filter views.
extension SpreadsheetController {
    // MARK: Objects over the grid

    var selectedObject: SheetObject? {
        guard let id = selectedObjectID else { return nil }
        return sheet.objects.first { $0.id == id }
    }

    func object(id: UUID) -> SheetObject? {
        sheet.objects.first { $0.id == id }
    }

    /// Adds an image or chart on top of the others and selects it.
    func addObject(_ object: SheetObject, actionName: String) {
        performLayoutEdit(actionName: actionName) { $0.objects.append(object) }
        selectedObjectID = object.id
    }

    /// Changes one object as one undoable step.
    func updateObject(id: UUID, actionName: String, _ change: (inout SheetObject) -> Void) {
        performLayoutEdit(actionName: actionName) { layout in
            guard let index = layout.objects.firstIndex(where: { $0.id == id }) else { return }
            change(&layout.objects[index])
        }
    }

    func removeObject(id: UUID) {
        let removed = object(id: id)
        let name = removed?.chart != nil ? "Delete Chart" : (removed?.slicer != nil ? "Delete Slicer" : "Delete Image")
        if removed?.slicer != nil {
            // The rows the slicer hid show again.
            let index = activeSheetIndex
            performFilterEdit(actionName: name) { $0.sheets[index].objects.removeAll { $0.id == id } }
        } else {
            performLayoutEdit(actionName: name) { $0.objects.removeAll { $0.id == id } }
        }
        if selectedObjectID == id { selectedObjectID = nil }
    }

    /// Brings an object to the front or sends it to the back.
    func reorderObject(id: UUID, toFront: Bool) {
        performLayoutEdit(actionName: toFront ? "Bring to Front" : "Send to Back") { layout in
            guard let index = layout.objects.firstIndex(where: { $0.id == id }) else { return }
            let object = layout.objects.remove(at: index)
            if toFront { layout.objects.append(object) } else { layout.objects.insert(object, at: 0) }
        }
    }

    // MARK: Charts

    /// Insert ▸ Chart: the suggested chart of the selection (or the data around the active
    /// cell), placed beside the data. Returns the new chart's id.
    @discardableResult
    func insertChart() -> UUID {
        let range = selection.current.isSingleCell ? dataRegion(around: selection.active) : selection.current
        let spec = ChartBuilder.suggestedSpec(for: range, sheetIndex: activeSheetIndex, workbook: workbook)
        let cell = CellAddress(row: range.start.row, column: min(range.end.column + 2, sheet.columnCount - 1))
        let object = SheetObject(anchor: ObjectAnchor(cell: cell, offsetX: 0, offsetY: 0, width: 600, height: 371), content: .chart(spec))
        addObject(object, actionName: "Insert Chart")
        return object.id
    }

    func updateChart(id: UUID, actionName: String = "Edit Chart", _ change: (inout ChartSpec) -> Void) {
        updateObject(id: id, actionName: actionName) { object in
            guard case .chart(var spec) = object.content else { return }
            change(&spec)
            object.content = .chart(spec)
        }
    }

    // MARK: Images

    /// Insert ▸ Image ▸ Insert image over cells: at its own size (up to 800 × 600), with its top-left corner at `address`.
    func insertImageOverCells(_ image: ImageData, at address: CellAddress) {
        var width = Double(max(1, image.pixelWidth)), height = Double(max(1, image.pixelHeight))
        let scale = min(1, 800 / width, 600 / height)
        width = (width * scale).rounded()
        height = (height * scale).rounded()
        addObject(SheetObject(anchor: ObjectAnchor(cell: address, width: width, height: height), content: .image(image)),
                  actionName: "Insert Image")
    }

    /// Insert ▸ Image ▸ Insert image in cell: the image replaces the cell's content.
    func insertImageInCell(_ image: ImageData, at address: CellAddress) {
        var cell = sheet[address]
        cell.value = .empty
        cell.formula = nil
        cell.image = CellImage(image: image)
        perform([.cells(sheet: activeSheetID, [address: cell])], actionName: "Insert Image")
    }

    /// "Put image in selected cell": moves a floating image into the active cell.
    func placeObjectInCell(id: UUID) {
        guard let object = object(id: id), let image = object.image else { return }
        let address = selection.active
        var cell = sheet[address]
        cell.value = .empty
        cell.formula = nil
        cell.image = CellImage(image: image, altText: object.altDescription.isEmpty ? object.title : object.altDescription)
        var layout = SheetLayout(sheet)
        layout.objects.removeAll { $0.id == id }
        perform([.layout(sheet: activeSheetID, layout), .cells(sheet: activeSheetID, [address: cell])], actionName: "Place Image in Cell")
        selectedObjectID = nil
    }

    /// An image file from disk or the pasteboard, as PNG unless it's already PNG, JPEG or GIF.
    static func imageData(from data: Data) -> ImageData? {
        if let image = ImageData(data: data) { return image }
        guard let bitmap = NSBitmapImageRep(data: data) ?? NSImage(data: data).flatMap({ image in
            image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        }), let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return ImageData(data: png)
    }

    // MARK: Links

    /// Insert ▸ Link: links the cell, replacing its text when `text` is given (an empty cell shows the link).
    func setLink(_ link: String?, text: String?, at address: CellAddress) {
        var cell = sheet[address]
        let trimmed = link?.trimmingCharacters(in: .whitespacesAndNewlines)
        cell.link = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if let text, !text.isEmpty, text != CellDisplay.editText(for: cell) {
            cell = self.cell(forInput: text, replacing: cell)
            cell.link = (trimmed?.isEmpty ?? true) ? nil : trimmed
        } else if !cell.hasContent, let link = cell.link {
            cell.value = .text(linkTitle(link))
        }
        perform([.cells(sheet: activeSheetID, [address: cell])], actionName: cell.link == nil ? "Remove Link" : "Insert Link")
    }

    /// Removes the links in the selected cells.
    func removeLinks() {
        var updates: [CellAddress: Cell] = [:]
        for range in selection.ranges {
            for (address, cell) in sheet.cells(in: range) where cell.link != nil {
                var copy = cell
                copy.link = nil
                updates[address] = copy
            }
        }
        guard !updates.isEmpty else { return }
        perform([.cells(sheet: activeSheetID, updates)], actionName: "Remove Link")
    }

    /// How a link reads: the address, or the sheet and range it points to.
    func linkTitle(_ link: String) -> String {
        switch LinkTarget(link: link) {
        case .sheet(let id, let range)?:
            let name = workbook.sheetIndex(id: id).map { workbook.sheets[$0].name } ?? "Deleted sheet"
            return range.map { "\(name)!\($0.a1)" } ?? name
        case .namedRange(let name)?:
            return name
        case .url(let url)?:
            return url.replacingOccurrences(of: "^mailto:", with: "", options: .regularExpression)
        case nil:
            return link
        }
    }

    /// Follows a link inside the spreadsheet: shows the sheet and selects the range. Returns false for web links.
    @discardableResult
    func followInternalLink(_ link: String) -> Bool {
        switch LinkTarget(link: link) {
        case .sheet(let id, let range)?:
            guard workbook.sheetIndex(id: id) != nil else { return true }
            showSheet(id: id)
            if let range { selection = GridSelection(range: range, active: range.start) }
            return true
        case .namedRange(let name)?:
            guard let named = workbook.namedRange(name), let target = workbook.resolve(named.reference, onSheet: 0) else { return true }
            showSheet(id: workbook.sheets[target.sheet].id)
            selection = GridSelection(range: target.range, active: target.range.start)
            return true
        default:
            return false
        }
    }

    // MARK: Pivot tables

    /// The pivot table with `id` and the sheet that holds it.
    func pivotTable(id: UUID) -> (sheetIndex: Int, pivot: PivotTable)? {
        for (index, sheet) in workbook.sheets.enumerated() {
            if let pivot = sheet.pivotTables.first(where: { $0.id == id }) { return (index, pivot) }
        }
        return nil
    }

    /// Insert ▸ Pivot table: on a new sheet ("Pivot Table 1") or at `location` ("Sheet2!A1" or "C3").
    /// Returns the new pivot table's id, or nil when the location isn't a cell.
    @discardableResult
    func createPivotTable(source: String, location: String?) -> UUID? {
        let source = qualifiedReference(source)
        if let location {
            guard let target = workbook.resolve(location, onSheet: activeSheetIndex) else { return nil }
            let pivot = PivotTable(anchor: target.range.start, source: source)
            let sheetID = workbook.sheets[target.sheet].id
            var layout = SheetLayout(workbook.sheets[target.sheet])
            layout.pivotTables.append(pivot)
            perform([.layout(sheet: sheetID, layout)], actionName: "Create Pivot Table",
                    selection: GridSelection(pivot.anchor), showing: sheetID)
            return pivot.id
        }
        var number = 1
        while workbook.sheetIndex(named: "Pivot Table \(number)") != nil { number += 1 }
        var sheet = Sheet(name: "Pivot Table \(number)")
        let pivot = PivotTable(anchor: CellAddress(row: 0, column: 0), source: source)
        sheet.pivotTables = [pivot]
        let index = activeSheetIndex
        performWorkbookEdit(actionName: "Create Pivot Table", selection: GridSelection(pivot.anchor), showing: sheet.id) {
            $0.sheets.insert(sheet, at: index + 1)
        }
        return pivot.id
    }

    func updatePivotTable(id: UUID, actionName: String = "Edit Pivot Table", _ change: (inout PivotTable) -> Void) {
        guard let (sheetIndex, _) = pivotTable(id: id) else { return }
        let sheetID = workbook.sheets[sheetIndex].id
        var layout = SheetLayout(workbook.sheets[sheetIndex])
        guard let index = layout.pivotTables.firstIndex(where: { $0.id == id }) else { return }
        change(&layout.pivotTables[index])
        guard layout != SheetLayout(workbook.sheets[sheetIndex]) else { return }
        perform([.layout(sheet: sheetID, layout)], actionName: actionName)
    }

    func removePivotTable(id: UUID) {
        guard let (sheetIndex, _) = pivotTable(id: id) else { return }
        var layout = SheetLayout(workbook.sheets[sheetIndex])
        layout.pivotTables.removeAll { $0.id == id }
        perform([.layout(sheet: workbook.sheets[sheetIndex].id, layout)], actionName: "Delete Pivot Table")
    }

    /// A reference as pivot tables and charts keep it: with its sheet name, so it keeps pointing at the
    /// same data from any sheet.
    func qualifiedReference(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard let target = workbook.resolve(trimmed, onSheet: activeSheetIndex) else { return trimmed }
        if !trimmed.contains("!"), workbook.namedRange(trimmed) != nil { return trimmed }
        return Self.quotedSheetName(workbook.sheets[target.sheet].name) + "!" + target.range.a1
    }

    // MARK: Filter views

    /// The filter view open on the active sheet in this window, if any.
    var activeFilterView: FilterView? {
        guard let id = openFilterViews[activeSheetID] else { return nil }
        return sheet.filterViews.first { $0.id == id }
    }

    /// Opens a filter view (nil closes the open one). Only this window's display changes.
    func openFilterView(_ id: UUID?) {
        openFilterViews[activeSheetID] = id
        notify([.layout, .cells])
    }

    /// Data ▸ Filter views ▸ Create new filter view: over the sheet filter's range, the selection or the data around it.
    func createFilterView() {
        let range = sheet.filter?.range ?? filterRangeForSelection
        addFilterView(FilterView(name: nextFilterViewName(), range: range))
    }

    /// Data ▸ Filter views ▸ Save as filter view: the sheet's filter, kept as a view.
    func saveFilterAsView() {
        guard let filter = sheet.filter else { return createFilterView() }
        addFilterView(FilterView(name: nextFilterViewName(), range: filter.range, criteria: filter.criteria))
    }

    private func addFilterView(_ view: FilterView) {
        performLayoutEdit(actionName: "Create Filter View") { $0.filterViews.append(view) }
        openFilterView(view.id)
    }

    func nextFilterViewName() -> String {
        var number = 1
        while sheet.filterViews.contains(where: { $0.name == "Filter \(number)" }) { number += 1 }
        return "Filter \(number)"
    }

    func updateFilterView(id: UUID, actionName: String, _ change: (inout FilterView) -> Void) {
        performLayoutEdit(actionName: actionName) { layout in
            guard let index = layout.filterViews.firstIndex(where: { $0.id == id }) else { return }
            change(&layout.filterViews[index])
        }
    }

    func duplicateFilterView(id: UUID) {
        guard let view = sheet.filterViews.first(where: { $0.id == id }) else { return }
        addFilterView(FilterView(name: "Copy of \(view.name)", range: view.range, criteria: view.criteria))
    }

    func deleteFilterView(id: UUID) {
        if openFilterViews[activeSheetID] == id { openFilterViews[activeSheetID] = nil }
        performLayoutEdit(actionName: "Delete Filter View") { $0.filterViews.removeAll { $0.id == id } }
    }

    /// Rows the open filter view hides, computed as the sheet's filter would hide them.
    var filterViewHiddenRows: Set<Int> {
        guard let view = activeFilterView else { return [] }
        return RuleEvaluator.filteredRows(for: view.asFilter, sheetIndex: activeSheetIndex, workbook: workbook)
    }

    /// Rows hidden on screen: by hand, and by the open filter view or else the sheet's filter.
    var displayHiddenRows: Set<Int> {
        let base = sheet.hiddenRows.union(sheet.rowGroups.collapsedIndexes)
        guard let view = activeFilterView else { return base.union(sheet.filteredRows) }
        if let cache = filterViewRowCache, cache.view == view, cache.generation == editGeneration, cache.sheet == activeSheetID {
            return base.union(cache.rows)
        }
        let rows = filterViewHiddenRows
        filterViewRowCache = (view, editGeneration, activeSheetID, rows)
        return base.union(rows)
    }

    /// The values a filter button lists: from the open filter view's range, or the sheet filter's.
    func filterValues(column: Int) -> [(value: String, count: Int)] {
        guard let view = activeFilterView else {
            return RuleEvaluator.filterValues(column: column, sheetIndex: activeSheetIndex, workbook: workbook)
        }
        return RuleEvaluator.filterValues(column: column, filter: view.asFilter, sheetIndex: activeSheetIndex, workbook: workbook)
    }

    /// Sets a filter button's criterion on the open filter view, or on the sheet's filter.
    func setDisplayedFilterCriterion(_ criterion: FilterCriterion?, column: Int) {
        guard let view = activeFilterView else { return setFilterCriterion(criterion, column: column) }
        updateFilterView(id: view.id, actionName: "Filter") { view in
            view.criteria[column] = (criterion?.isEmpty ?? true) ? nil : criterion
        }
    }

    /// The filter whose buttons the grid shows: the open filter view's, or the sheet's own.
    var displayedFilter: SheetFilter? {
        activeFilterView?.asFilter ?? sheet.filter
    }
}
