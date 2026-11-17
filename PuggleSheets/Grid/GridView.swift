import AppKit
import PuggleSheetsKit

/// The spreadsheet grid: headers, frozen panes and cells, all drawn by this view.
/// Geometry is kept in sheet pixels (100% zoom, where a pixel is a point) and scaled by `zoom`.
final class GridView: NSView {
    unowned let controller: SpreadsheetController

    static let rowHeaderWidth: CGFloat = 46
    static let columnHeaderHeight: CGFloat = 22
    /// Space under the last row for the "Add more rows" button.
    static let footerHeight: CGFloat = 64

    var zoom: CGFloat = 1 {
        didSet {
            guard zoom != oldValue else { return }
            clampScroll()
            invalidateCaches()
        }
    }

    private(set) var frozenRowCount = 0
    private(set) var frozenColumnCount = 0
    /// Outline levels in use by row and column groups (each needs a band of buttons).
    private(set) var rowOutlineLevels = 0
    private(set) var columnOutlineLevels = 0
    private var cachedFrozenWidth = 0.0
    private var cachedFrozenHeight = 0.0
    private var rowNumberDigits = 4

    /// Scroll position of the unfrozen part, in sheet pixels.
    private(set) var scrollOffset = CGPoint.zero
    private var scrollOffsets: [UUID: CGPoint] = [:]
    private(set) var rows = AxisLayout(count: 1000, defaultSize: 21, custom: [:], hidden: [])
    private(set) var columns = AxisLayout(count: 26, defaultSize: 100, custom: [:], hidden: [])

    var editor: CellEditor?
    /// Shows text being typed in the formula bar inside the cell.
    var mirroredEditText: String? {
        didSet { needsDisplay = true }
    }
    let renderer = CellRenderer()

    /// Mouse interaction in progress (selecting, resizing, filling).
    var drag: GridDrag?
    /// Where the freeze bar being dragged is, in view coordinates.
    var freezeDragPosition: CGFloat?
    /// An image or chart being moved or resized: its frame in sheet pixels.
    var liveObjectFrame: (id: UUID, frame: CGRect)?
    /// Decoded images, by their data.
    var imageCache: [ImageData: NSImage] = [:]
    /// Pivot tables' results, kept until the next edit.
    var pivotOutputCache: [UUID: (generation: Int, pivot: PivotTable, output: PivotOutput)] = [:]
    /// The pivot table's Edit button was clicked.
    var onEditPivot: ((UUID) -> Void)?
    /// Charts' data, kept until the next edit.
    var chartTableCache: [UUID: (spec: ChartSpec, generation: Int, table: ChartTable)] = [:]
    /// The ⋮ button of a selected chart was clicked: the object and the button's rectangle.
    var onObjectMenu: ((UUID, CGRect) -> Void)?
    /// A table's filter button (with the column) or its name chip (without) was clicked.
    var onTableControl: ((UUID, Int?, CGRect) -> Void)?
    /// A slicer's status line was clicked: the slicer and the line's rectangle.
    var onSlicerDropdown: ((UUID, CGRect) -> Void)?
    /// An object was double-clicked (charts open their editor).
    var onObjectDoubleClick: ((UUID) -> Void)?
    /// The visible part of the sheet moved (scrolling or zooming).
    var onViewportChange: (() -> Void)?
    /// The mouse moved onto another cell (nil when it left the cells), for note pop-ups.
    var onHoverCell: ((CellAddress?) -> Void)?
    var hoveredAddress: CellAddress?
    /// View ▸ Show ▸ Formulas (⌃`).
    var showsFormulas = false {
        didSet { if showsFormulas != oldValue { invalidateRuleCaches(); needsDisplay = true } }
    }
    /// View ▸ Show ▸ Protected ranges.
    var showsProtectedRanges = false {
        didSet { if showsProtectedRanges != oldValue { needsDisplay = true } }
    }
    /// Builds the right-click menu for an object.
    var objectMenuProvider: ((UUID) -> NSMenu?)?
    var autoscrollTimer: Timer?
    var lastDragEvent: NSEvent?
    /// The paint-format brush: formats to apply to the next selection.
    var paintFormats: [[CellFormat]]?
    var paintFormatSticky = false
    /// The column a run of Tab entries started in; Return goes back to it on the next row.
    var tabStartColumn: Int?
    /// Ranges a formula being edited refers to, outlined in their colors.
    var formulaReferenceRanges: [(CellRange, NSColor)] = []
    /// Conditional formatting and invalid-value marks for regions of the sheet, computed once per
    /// generation (every edit starts a new one) so scrolling doesn't evaluate rules every frame.
    struct RuleCacheEntry {
        var range: CellRange
        var formats: [CellAddress: ConditionalFormat]
        var invalid: Set<CellAddress>
    }
    var ruleCache: [RuleCacheEntry] = []
    /// Cells matching Edit ▸ Find, tinted in the grid.
    var findMatches = Set<CellAddress>() {
        didSet { if findMatches != oldValue { needsDisplay = true } }
    }
    /// The reference text inserted by clicking cells while typing a formula, which a drag extends.
    var pointingRange: NSRange?
    /// The cell a pointing drag started from.
    var pointingAnchor: CellAddress?
    /// True while pointing inserts text, so the edit isn't mistaken for typing.
    var isInsertingPointedReference = false
    /// A column or row being resized by dragging, shown before the change is committed.
    var liveSize: (isColumn: Bool, index: Int, size: Double)?

    /// A filter button was clicked: the column and the button's rectangle.
    var onFilterButton: ((Int, CGRect) -> Void)?
    /// Builds the right-click menu for a place in the grid.
    var menuProvider: ((GridLocation) -> NSMenu?)?
    /// Asks the window to edit in the formula bar or report changes.
    var onBeginEditing: ((CellEditor) -> Void)?
    var onEditorTextChange: ((String) -> Void)?
    /// Autocomplete and argument help for formulas typed into the cell editor.
    var formulaAssistant: FormulaAssistant?
    var onEndEditing: (() -> Void)?
    var onZoomGesture: ((CGFloat) -> Void)?

    init(controller: SpreadsheetController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL, .png, .tiff])
        reloadLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    /// Set on a grid that only draws pages for printing: the sheet to draw and whether to draw gridlines.
    /// Print grids have no headers, frozen panes or scrolling limits.
    var printSettings: (sheetIndex: Int, gridlines: Bool)?

    var sheet: Sheet { printSettings.map { controller.workbook.sheets[$0.sheetIndex] } ?? controller.sheet }

    /// The filter whose buttons show: the open filter view's on screen, the sheet's own in print.
    var displayedFilter: SheetFilter? { printSettings == nil ? controller.displayedFilter : sheet.filter }

    /// While a filter view is open, the headers are darker.
    var headerFillColor: NSColor { showsFilterView ? GridColors.rgb(0x5F6368) : GridColors.headerFill }
    var headerTextColor: NSColor { showsFilterView ? .white : GridColors.headerText }
    var showsFilterView: Bool { printSettings == nil && controller.activeFilterView != nil }

    /// The sheet whose rules (conditional formatting, validation) apply to what's drawn.
    var drawnSheetIndex: Int { printSettings?.sheetIndex ?? controller.activeSheetIndex }

    /// Moves a print grid so that `origin` (in sheet pixels) is drawn at the view's origin.
    func setPrintOrigin(_ origin: CGPoint) {
        scrollOffset = origin
    }

    // MARK: Layout

    /// Rebuilds row and column positions after sizes, counts or hidden rows/columns changed.
    func reloadLayout() {
        let sheet = self.sheet
        var rowHeights = sheet.rowHeights, columnWidths = sheet.columnWidths
        if let live = liveSize {
            if live.isColumn { columnWidths[live.index] = live.size } else { rowHeights[live.index] = live.size }
        }
        rows = AxisLayout(count: sheet.rowCount, defaultSize: sheet.defaultRowHeight, custom: rowHeights,
                          hidden: printSettings == nil ? controller.displayHiddenRows
                            : sheet.hiddenRows.union(sheet.filteredRows).union(sheet.rowGroups.collapsedIndexes))
        columns = AxisLayout(count: sheet.columnCount, defaultSize: sheet.defaultColumnWidth, custom: columnWidths,
                             hidden: sheet.hiddenColumns.union(sheet.columnGroups.collapsedIndexes))
        // Geometry runs for every cell drawn, so it reads these instead of the sheet.
        rowOutlineLevels = printSettings == nil ? sheet.rowGroups.maximumDepth : 0
        columnOutlineLevels = printSettings == nil ? sheet.columnGroups.maximumDepth : 0
        frozenRowCount = printSettings == nil ? min(sheet.frozenRows, sheet.rowCount) : 0
        frozenColumnCount = printSettings == nil ? min(sheet.frozenColumns, sheet.columnCount) : 0
        cachedFrozenWidth = columns.offset(frozenColumnCount)
        cachedFrozenHeight = rows.offset(frozenRowCount)
        rowNumberDigits = String(sheet.rowCount).count
        clampScroll()
        needsDisplay = true
        positionEditor()
    }

    /// Switching sheets keeps each sheet's scroll position.
    func sheetWillChange(from oldID: UUID) {
        scrollOffsets[oldID] = scrollOffset
    }

    func sheetDidChange() {
        scrollOffset = scrollOffsets[controller.activeSheetID] ?? .zero
        reloadLayout()
    }

    func invalidateCaches() {
        renderer.invalidate()
        needsDisplay = true
        positionEditor()
    }

    override func layout() {
        super.layout()
        clampScroll()
        positionEditor()
    }

    /// The grid draws its own thin scroll bars along the right and bottom edges.
    static let scrollbarThickness: CGFloat = 12

    /// The area cells and headers use: the view minus the scroll bars.
    var gridBounds: CGRect {
        let thickness = Self.scrollbarThickness
        return CGRect(x: 0, y: 0, width: max(0, bounds.width - thickness), height: max(0, bounds.height - thickness))
    }

    /// The scroll bar tracks, alongside the scrolling (unfrozen) part of the grid.
    func scrollTrack(vertical: Bool) -> CGRect {
        let grid = gridBounds
        if vertical {
            return CGRect(x: grid.maxX, y: scrollOrigin.y, width: Self.scrollbarThickness, height: max(0, grid.maxY - scrollOrigin.y))
        }
        return CGRect(x: scrollOrigin.x, y: grid.maxY, width: max(0, grid.maxX - scrollOrigin.x), height: Self.scrollbarThickness)
    }

    /// The scroll bar thumb, or nil when everything fits.
    func scrollThumb(vertical: Bool) -> CGRect? {
        let track = scrollTrack(vertical: vertical)
        let limit = vertical ? maximumScroll.y : maximumScroll.x
        guard limit > 0 else { return nil }
        let visible = (vertical ? track.height : track.width) / zoom
        let length = vertical ? track.height : track.width
        let thumbLength = max(30, length * visible / (visible + limit))
        let position = (length - thumbLength) * (vertical ? scrollOffset.y : scrollOffset.x) / limit
        return vertical
            ? CGRect(x: track.minX + 2, y: track.minY + position, width: track.width - 4, height: thumbLength)
            : CGRect(x: track.minX + position, y: track.minY + 2, width: thumbLength, height: track.height - 4)
    }

    /// Scrolls so the thumb's leading edge sits at `position` along its track.
    func scroll(thumbTo position: CGFloat, vertical: Bool) {
        guard let thumb = scrollThumb(vertical: vertical) else { return }
        let track = scrollTrack(vertical: vertical)
        let travel = (vertical ? track.height - thumb.height : track.width - thumb.width)
        guard travel > 0 else { return }
        let fraction = min(max((position - (vertical ? track.minY : track.minX)) / travel, 0), 1)
        let limit = maximumScroll
        setScrollOffset(vertical ? CGPoint(x: scrollOffset.x, y: fraction * limit.y) : CGPoint(x: fraction * limit.x, y: scrollOffset.y))
    }

    var headerWidth: CGFloat {
        guard printSettings == nil else { return 0 }
        let digits = max(3, rowNumberDigits)
        return rowOutlineWidth + max(Self.rowHeaderWidth, CGFloat(digits) * 8 + 22) * zoom
    }

    var headerHeight: CGFloat { printSettings == nil ? columnOutlineHeight + Self.columnHeaderHeight * zoom : 0 }

    /// Sizes of the frozen bands, in sheet pixels.
    var frozenWidth: Double { cachedFrozenWidth }
    var frozenHeight: Double { cachedFrozenHeight }

    /// Where the scrolling pane starts, in view coordinates.
    var scrollOrigin: CGPoint {
        CGPoint(x: headerWidth + CGFloat(frozenWidth) * zoom, y: headerHeight + CGFloat(frozenHeight) * zoom)
    }

    enum AxisMode { case frozen, scrolling }

    func mode(forRow row: Int) -> AxisMode { row < frozenRowCount ? .frozen : .scrolling }
    func mode(forColumn column: Int) -> AxisMode { column < frozenColumnCount ? .frozen : .scrolling }

    /// View x of a sheet-pixel position along the columns.
    func viewX(_ position: Double, mode: AxisMode) -> CGFloat {
        switch mode {
        case .frozen: return headerWidth + CGFloat(position) * zoom
        case .scrolling: return scrollOrigin.x + CGFloat(position - frozenWidth - Double(scrollOffset.x)) * zoom
        }
    }

    func viewY(_ position: Double, mode: AxisMode) -> CGFloat {
        switch mode {
        case .frozen: return headerHeight + CGFloat(position) * zoom
        case .scrolling: return scrollOrigin.y + CGFloat(position - frozenHeight - Double(scrollOffset.y)) * zoom
        }
    }

    func columnX(_ column: Int, mode: AxisMode? = nil) -> CGFloat {
        viewX(columns.offset(column), mode: mode ?? self.mode(forColumn: column))
    }

    func rowY(_ row: Int, mode: AxisMode? = nil) -> CGFloat {
        viewY(rows.offset(row), mode: mode ?? self.mode(forRow: row))
    }

    /// The view rectangle of a range, positioned by its top-left cell's pane (or the given modes).
    func rect(for range: CellRange, xMode: AxisMode? = nil, yMode: AxisMode? = nil) -> CGRect {
        let xm = xMode ?? mode(forColumn: range.start.column), ym = yMode ?? mode(forRow: range.start.row)
        let left = viewX(columns.offset(range.start.column), mode: xm)
        let right = viewX(columns.offset(range.end.column + 1), mode: xm)
        let top = viewY(rows.offset(range.start.row), mode: ym)
        let bottom = viewY(rows.offset(range.end.row + 1), mode: ym)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The rectangle of a cell, or of the merged block it belongs to.
    func cellRect(_ address: CellAddress) -> CGRect {
        rect(for: controller.mergedRange(at: address))
    }

    // MARK: Panes

    struct Pane {
        var rect: CGRect
        var rows: ClosedRange<Int>
        var columns: ClosedRange<Int>
        var xMode: AxisMode
        var yMode: AxisMode
    }

    /// The four regions (frozen corner, frozen rows, frozen columns, scrolling area) that have rows and columns showing.
    var panes: [Pane] {
        let grid = gridBounds
        let origin = scrollOrigin
        var result: [Pane] = []
        let frozenRowRange: ClosedRange<Int>? = frozenRowCount > 0 ? 0...(frozenRowCount - 1) : nil
        let frozenColumnRange: ClosedRange<Int>? = frozenColumnCount > 0 ? 0...(frozenColumnCount - 1) : nil
        let scrollRows = visibleScrollingRows, scrollColumns = visibleScrollingColumns
        let left = CGRect(x: headerWidth, y: 0, width: max(0, origin.x - headerWidth), height: 0)
        let top = CGRect(x: 0, y: headerHeight, width: 0, height: max(0, origin.y - headerHeight))
        let scrollWidth = max(0, grid.maxX - origin.x), scrollHeight = max(0, grid.maxY - origin.y)
        if let frozenRowRange, let frozenColumnRange {
            result.append(Pane(rect: CGRect(x: left.minX, y: top.minY, width: left.width, height: top.height),
                               rows: frozenRowRange, columns: frozenColumnRange, xMode: .frozen, yMode: .frozen))
        }
        if let frozenRowRange, let scrollColumns {
            result.append(Pane(rect: CGRect(x: origin.x, y: top.minY, width: scrollWidth, height: top.height),
                               rows: frozenRowRange, columns: scrollColumns, xMode: .scrolling, yMode: .frozen))
        }
        if let frozenColumnRange, let scrollRows {
            result.append(Pane(rect: CGRect(x: left.minX, y: origin.y, width: left.width, height: scrollHeight),
                               rows: scrollRows, columns: frozenColumnRange, xMode: .frozen, yMode: .scrolling))
        }
        if let scrollRows, let scrollColumns {
            result.append(Pane(rect: CGRect(x: origin.x, y: origin.y, width: scrollWidth, height: scrollHeight),
                               rows: scrollRows, columns: scrollColumns, xMode: .scrolling, yMode: .scrolling))
        }
        return result
    }

    var visibleScrollingRows: ClosedRange<Int>? {
        let first = frozenRowCount
        guard first < rows.count else { return nil }
        let height = Double(max(0, gridBounds.maxY - scrollOrigin.y) / zoom)
        let top = frozenHeight + Double(scrollOffset.y)
        let start = max(first, rows.index(at: top))
        let end = max(start, rows.index(at: top + height))
        return start...end
    }

    var visibleScrollingColumns: ClosedRange<Int>? {
        let first = frozenColumnCount
        guard first < columns.count else { return nil }
        let width = Double(max(0, gridBounds.maxX - scrollOrigin.x) / zoom)
        let left = frozenWidth + Double(scrollOffset.x)
        let start = max(first, columns.index(at: left))
        let end = max(start, columns.index(at: left + width))
        return start...end
    }

    // MARK: Hit testing

    enum GridLocation: Equatable {
        case corner
        case columnHeader(Int)
        case rowHeader(Int)
        case cell(CellAddress)
        case footer
        case outside
    }

    func location(at point: CGPoint) -> GridLocation {
        let grid = gridBounds
        guard grid.contains(point) else { return .outside }
        let inHeaderRow = point.y < headerHeight, inHeaderColumn = point.x < headerWidth
        if inHeaderRow && inHeaderColumn { return .corner }
        let column = columnIndex(atViewX: point.x)
        let row = rowIndex(atViewY: point.y)
        if inHeaderRow { return .columnHeader(column) }
        if inHeaderColumn { return row.map { .rowHeader($0) } ?? .footer }
        guard let row else { return .footer }
        return .cell(CellAddress(row: row, column: column))
    }

    /// The column under a view x, clamped to the sheet.
    func columnIndex(atViewX x: CGFloat) -> Int {
        let position: Double
        if x < scrollOrigin.x {
            position = Double((x - headerWidth) / zoom)
        } else {
            position = Double((x - scrollOrigin.x) / zoom) + frozenWidth + Double(scrollOffset.x)
        }
        return columns.index(at: position)
    }

    /// The row under a view y, clamped to the sheet; nil below the last row.
    func rowIndex(atViewY y: CGFloat) -> Int? {
        let position: Double
        if y < scrollOrigin.y {
            position = Double((y - headerHeight) / zoom)
        } else {
            position = Double((y - scrollOrigin.y) / zoom) + frozenHeight + Double(scrollOffset.y)
        }
        if position >= rows.total { return nil }
        return rows.index(at: position)
    }

    /// The rectangle of the "Add more rows" bar under the last row, when it's showing.
    var footerRect: CGRect? {
        let bottom = viewY(rows.total, mode: frozenRowCount >= rows.count ? .frozen : .scrolling)
        guard bottom < gridBounds.maxY else { return nil }
        return CGRect(x: 0, y: bottom, width: gridBounds.width, height: Self.footerHeight * zoom)
    }

    // MARK: Scrolling

    /// Largest scroll offsets: the content after the frozen bands minus the visible area.
    var maximumScroll: CGPoint {
        let visibleWidth = Double(max(0, gridBounds.maxX - scrollOrigin.x) / zoom)
        let visibleHeight = Double(max(0, gridBounds.maxY - scrollOrigin.y) / zoom)
        return CGPoint(x: max(0, columns.total - frozenWidth - visibleWidth + 20),
                       y: max(0, rows.total - frozenHeight - visibleHeight + Double(Self.footerHeight)))
    }

    func setScrollOffset(_ offset: CGPoint) {
        let limit = maximumScroll
        let clamped = CGPoint(x: min(max(0, offset.x), limit.x), y: min(max(0, offset.y), limit.y))
        guard clamped != scrollOffset else { return }
        scrollOffset = clamped
        updateScrollers()
        needsDisplay = true
        positionEditor()
        onViewportChange?()
    }

    func clampScroll() {
        setScrollOffset(scrollOffset)
        updateScrollers()
    }

    func updateScrollers() {
        needsDisplay = true
    }

    /// A click on a scroll bar's track pages toward the click.
    func pageScroll(vertical: Bool, toward point: CGPoint) {
        guard let thumb = scrollThumb(vertical: vertical) else { return }
        let page = (vertical ? scrollTrack(vertical: true).height : scrollTrack(vertical: false).width) / zoom * 0.9
        let forward = vertical ? point.y > thumb.maxY : point.x > thumb.maxX
        let delta = forward ? page : -page
        setScrollOffset(vertical ? CGPoint(x: scrollOffset.x, y: scrollOffset.y + delta) : CGPoint(x: scrollOffset.x + delta, y: scrollOffset.y))
    }

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= 21 * 3
            dy *= 21 * 3
        }
        // A vertical wheel with Shift scrolls sideways, as in browsers.
        if event.modifierFlags.contains(.shift), dx == 0 { swap(&dx, &dy) }
        setScrollOffset(CGPoint(x: scrollOffset.x - dx / zoom, y: scrollOffset.y - dy / zoom))
    }

    override func magnify(with event: NSEvent) {
        onZoomGesture?(event.magnification)
    }

    /// Scrolls so that the cell (or merged block) at `address` is fully visible.
    func scrollToVisible(_ address: CellAddress) {
        let range = controller.mergedRange(at: address)
        var offset = scrollOffset
        let visibleWidth = Double(max(0, gridBounds.maxX - scrollOrigin.x) / zoom)
        let visibleHeight = Double(max(0, gridBounds.maxY - scrollOrigin.y) / zoom)
        if range.end.column >= frozenColumnCount {
            let left = columns.offset(max(range.start.column, frozenColumnCount)) - frozenWidth
            let right = columns.offset(range.end.column + 1) - frozenWidth
            if left < Double(offset.x) { offset.x = CGFloat(left) } else if right > Double(offset.x) + visibleWidth {
                offset.x = CGFloat(min(left, right - visibleWidth))
            }
        }
        if range.end.row >= frozenRowCount {
            let top = rows.offset(max(range.start.row, frozenRowCount)) - frozenHeight
            let bottom = rows.offset(range.end.row + 1) - frozenHeight
            if top < Double(offset.y) { offset.y = CGFloat(top) } else if bottom > Double(offset.y) + visibleHeight {
                offset.y = CGFloat(min(top, bottom - visibleHeight))
            }
        }
        setScrollOffset(offset)
    }

    /// How many rows fit in the scrolling pane, for Page Up and Page Down.
    var rowsPerPage: Int {
        max(1, Int(Double(max(0, gridBounds.maxY - scrollOrigin.y) / zoom) / sheet.defaultRowHeight) - 1)
    }
}

/// A mouse interaction in progress.
enum GridDrag {
    case selecting(extendRanges: Bool)
    case selectingColumns(anchor: Int)
    case selectingRows(anchor: Int)
    case resizingColumn(Int, startX: CGFloat, startWidth: Double, columns: [Int])
    case resizingRow(Int, startY: CGFloat, startHeight: Double, rows: [Int])
    case filling(source: CellRange, target: CellRange)
    /// Dragging a scroll bar thumb; `grab` is where it was grabbed, from its leading edge.
    case scrolling(vertical: Bool, grab: CGFloat)
    /// Clicking or dragging over cells to insert their reference into a formula being typed.
    case pointing
    /// Dragging the gray bar that freezes rows (or columns) to a new place.
    case freezing(rows: Bool)
    /// Moving an image or chart; `origin` is its frame in sheet pixels when the drag began.
    case movingObject(UUID, start: CGPoint, origin: CGRect)
    case resizingObject(UUID, GridView.ObjectHandle, start: CGPoint, origin: CGRect)
}
