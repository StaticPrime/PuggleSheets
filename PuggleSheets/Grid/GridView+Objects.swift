import AppKit
import PuggleSheetsKit

/// Images and charts floating over the grid: drawn above the cells, anchored to
/// a cell, and moved, resized and deleted when selected.
extension GridView {
    enum ObjectHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    enum ObjectHit {
        case body(UUID)
        case handle(UUID, ObjectHandle)
        case menu(UUID)
    }

    // MARK: Geometry

    /// An object's frame in sheet pixels, measured from the top-left of A1 at 100% zoom.
    func sheetFrame(of anchor: ObjectAnchor) -> CGRect {
        let column = min(max(anchor.cell.column, 0), columns.count - 1), row = min(max(anchor.cell.row, 0), rows.count - 1)
        return CGRect(x: columns.offset(column) + anchor.offsetX, y: rows.offset(row) + anchor.offsetY,
                      width: anchor.width, height: anchor.height)
    }

    /// The anchor for a frame in sheet pixels: the cell holding its top-left corner, and how far into it.
    func anchor(forSheetFrame frame: CGRect) -> ObjectAnchor {
        let x = min(max(0, Double(frame.minX)), max(0, columns.total - 1))
        let y = min(max(0, Double(frame.minY)), max(0, rows.total - 1))
        let column = columns.index(at: x), row = rows.index(at: y)
        return ObjectAnchor(cell: CellAddress(row: row, column: column), offsetX: (x - columns.offset(column)).rounded(),
                            offsetY: (y - rows.offset(row)).rounded(), width: Double(frame.width).rounded(),
                            height: Double(frame.height).rounded())
    }

    /// The anchor an object has now, or while it's being dragged.
    func currentAnchor(of object: SheetObject) -> ObjectAnchor {
        if let live = liveObjectFrame, live.id == object.id { return anchor(forSheetFrame: live.frame) }
        return object.anchor
    }

    /// An object's frame in view coordinates, placed by its anchor cell's pane.
    func objectRect(_ anchor: ObjectAnchor) -> CGRect {
        let column = min(max(anchor.cell.column, 0), columns.count - 1), row = min(max(anchor.cell.row, 0), rows.count - 1)
        return CGRect(x: columnX(column) + CGFloat(anchor.offsetX) * zoom, y: rowY(row) + CGFloat(anchor.offsetY) * zoom,
                      width: CGFloat(anchor.width) * zoom, height: CGFloat(anchor.height) * zoom)
    }

    /// Where an object may show: below the headers, and out of the frozen panes when it scrolls.
    func objectClip(_ anchor: ObjectAnchor) -> CGRect {
        let grid = gridBounds
        let left = mode(forColumn: anchor.cell.column) == .scrolling ? scrollOrigin.x : headerWidth
        let top = mode(forRow: anchor.cell.row) == .scrolling ? scrollOrigin.y : headerHeight
        return CGRect(x: left, y: top, width: max(0, grid.maxX - left), height: max(0, grid.maxY - top))
    }

    func handleRect(_ handle: ObjectHandle, in rect: CGRect) -> CGRect {
        let size: CGFloat = 8
        let point: CGPoint = switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
        return CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    /// The ⋮ button at the top right of a selected object.
    func objectMenuButtonRect(in rect: CGRect) -> CGRect {
        CGRect(x: rect.maxX - 32, y: rect.minY + 6, width: 26, height: 26)
    }

    // MARK: Drawing

    /// Draws every object above the cells (and, in print, the ones on the page).
    func drawObjects() {
        for object in sheet.objects {
            let anchor = currentAnchor(of: object)
            let rect = objectRect(anchor)
            let clip = printSettings == nil ? objectClip(anchor) : rect
            guard rect.intersects(clip), rect.width > 1, rect.height > 1 else { continue }
            NSGraphicsContext.saveGraphicsState()
            if printSettings == nil { NSBezierPath(rect: clip).addClip() }
            drawObject(object, in: rect)
            if printSettings == nil, controller.selectedObjectID == object.id { drawObjectSelection(object, in: rect) }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    func drawObject(_ object: SheetObject, in rect: CGRect) {
        switch object.content {
        case .image(let image):
            nsImage(for: image)?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .chart(let spec):
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.clip(to: rect)
            ChartRenderer.draw(spec, table: chartTable(for: object.id, spec: spec), in: rect, context: context)
            context.restoreGState()
            // Charts have a hairline frame only while selected; images and charts look flush otherwise.
        case .slicer(let spec):
            drawSlicer(spec, in: rect)
        }
    }

    private func drawObjectSelection(_ object: SheetObject, in rect: CGRect) {
        let outline = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        outline.lineWidth = 2
        GridColors.selection.setStroke()
        outline.stroke()
        for handle in ObjectHandle.allCases {
            let square = handleRect(handle, in: rect)
            NSColor.white.setFill()
            square.fill()
            GridColors.selection.setStroke()
            let border = NSBezierPath(rect: square.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
        if object.chart != nil, rect.width > 80, rect.height > 60 {
            let button = objectMenuButtonRect(in: rect)
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: button, xRadius: 13, yRadius: 13).fill()
            GridColors.rgb(0x444746).setFill()
            for index in 0..<3 {
                let dot = CGRect(x: button.midX - 1.75, y: button.midY - 7.5 + CGFloat(index) * 6, width: 3.5, height: 3.5)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }

    /// Decoded images, shared by objects and cells.
    func nsImage(for image: ImageData) -> NSImage? {
        if let cached = imageCache[image] { return cached }
        guard let decoded = NSImage(data: image.data) else { return nil }
        if imageCache.count > 64 { imageCache.removeAll() }
        imageCache[image] = decoded
        return decoded
    }

    /// A chart's labels and series, read again after every edit.
    func chartTable(for id: UUID, spec: ChartSpec) -> ChartTable {
        if let cached = chartTableCache[id], cached.spec == spec, cached.generation == controller.editGeneration { return cached.table }
        let table = ChartBuilder.table(for: spec, sheetIndex: drawnSheetIndex, workbook: controller.workbook)
        chartTableCache[id] = (spec, controller.editGeneration, table)
        return table
    }

    // MARK: Mouse

    func objectHit(at point: CGPoint) -> ObjectHit? {
        guard printSettings == nil else { return nil }
        if let selected = controller.selectedObject {
            let anchor = currentAnchor(of: selected)
            let rect = objectRect(anchor)
            if objectClip(anchor).contains(point) {
                if selected.chart != nil, rect.width > 80, rect.height > 60, objectMenuButtonRect(in: rect).contains(point) {
                    return .menu(selected.id)
                }
                for handle in ObjectHandle.allCases where handleRect(handle, in: rect).insetBy(dx: -3, dy: -3).contains(point) {
                    return .handle(selected.id, handle)
                }
            }
        }
        for object in sheet.objects.reversed() {
            let anchor = currentAnchor(of: object)
            if objectRect(anchor).contains(point), objectClip(anchor).contains(point) { return .body(object.id) }
        }
        return nil
    }

    /// Clicks on objects: selects, starts a move or resize, or opens the menu. Returns false when no object was hit.
    func handleObjectMouseDown(at point: CGPoint, event: NSEvent) -> Bool {
        guard let hit = objectHit(at: point) else { return false }
        switch hit {
        case .menu(let id):
            if let object = controller.object(id: id) {
                onObjectMenu?(id, objectMenuButtonRect(in: objectRect(object.anchor)))
            }
        case .handle(let id, let handle):
            guard let object = controller.object(id: id) else { return true }
            drag = .resizingObject(id, handle, start: point, origin: sheetFrame(of: object.anchor))
        case .body(let id):
            controller.selectedObjectID = id
            guard let object = controller.object(id: id) else { return true }
            // A slicer's status line opens its filter.
            if object.slicer != nil, event.clickCount == 1, slicerStatusRect(in: objectRect(object.anchor)).contains(point) {
                onSlicerDropdown?(id, slicerStatusRect(in: objectRect(object.anchor)))
                needsDisplay = true
                return true
            }
            if event.clickCount == 2 {
                onObjectDoubleClick?(id)
                return true
            }
            drag = .movingObject(id, start: point, origin: sheetFrame(of: object.anchor))
        }
        needsDisplay = true
        return true
    }

    func handleObjectDrag(to point: CGPoint) {
        switch drag {
        case .movingObject(let id, let start, let origin):
            var frame = origin
            frame.origin.x = max(0, origin.minX + (point.x - start.x) / zoom)
            frame.origin.y = max(0, origin.minY + (point.y - start.y) / zoom)
            liveObjectFrame = (id, frame)
        case .resizingObject(let id, let handle, let start, let origin):
            let dx = (point.x - start.x) / zoom, dy = (point.y - start.y) / zoom
            var minX = origin.minX, minY = origin.minY, maxX = origin.maxX, maxY = origin.maxY
            switch handle {
            case .topLeft: minX += dx; minY += dy
            case .top: minY += dy
            case .topRight: maxX += dx; minY += dy
            case .right: maxX += dx
            case .bottomRight: maxX += dx; maxY += dy
            case .bottom: maxY += dy
            case .bottomLeft: minX += dx; maxY += dy
            case .left: minX += dx
            }
            let minimum: CGFloat = 20
            if maxX - minX < minimum { if [.topLeft, .left, .bottomLeft].contains(handle) { minX = maxX - minimum } else { maxX = minX + minimum } }
            if maxY - minY < minimum { if [.topLeft, .top, .topRight].contains(handle) { minY = maxY - minimum } else { maxY = minY + minimum } }
            var frame = CGRect(x: max(0, minX), y: max(0, minY), width: maxX - max(0, minX), height: maxY - max(0, minY))
            // Images keep their shape when dragged by a corner.
            if [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(handle), controller.object(id: id)?.image != nil, origin.height > 0 {
                let ratio = origin.width / origin.height
                let height = max(minimum, frame.width / ratio)
                if [.topLeft, .topRight].contains(handle) { frame.origin.y = origin.maxY - height }
                frame.size.height = height
            }
            liveObjectFrame = (id, frame)
        default:
            return
        }
        needsDisplay = true
    }

    /// Ends a move or resize: the new place becomes one undoable step.
    func finishObjectDrag() {
        guard let live = liveObjectFrame else { return }
        liveObjectFrame = nil
        let moved: Bool = if case .movingObject = drag { true } else { false }
        guard let object = controller.object(id: live.id) else { return }
        let anchor = anchor(forSheetFrame: live.frame)
        guard anchor != object.anchor else { needsDisplay = true; return }
        let kind = object.chart != nil ? "Chart" : "Image"
        controller.updateObject(id: live.id, actionName: moved ? "Move \(kind)" : "Resize \(kind)") { $0.anchor = anchor }
    }

    // MARK: Keyboard

    /// Keys for the selected object: Delete removes it, Esc deselects it, the arrows nudge it
    /// (Shift for 10 pixels). Returns false for keys that go to the cells.
    func handleObjectKey(_ event: NSEvent) -> Bool {
        guard let object = controller.selectedObject else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 {
            controller.selectedObjectID = nil
            return true
        }
        if flags.isEmpty, event.specialKey == .delete || event.specialKey == .deleteForward || event.specialKey == .backspace {
            controller.removeObject(id: object.id)
            return true
        }
        if flags.subtracting(.shift).isEmpty, let key = event.specialKey,
           [.leftArrow, .rightArrow, .upArrow, .downArrow].contains(key) {
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            var frame = sheetFrame(of: object.anchor)
            switch key {
            case .leftArrow: frame.origin.x = max(0, frame.minX - step)
            case .rightArrow: frame.origin.x += step
            case .upArrow: frame.origin.y = max(0, frame.minY - step)
            default: frame.origin.y += step
            }
            controller.updateObject(id: object.id, actionName: object.chart != nil ? "Move Chart" : "Move Image") {
                $0.anchor = anchor(forSheetFrame: frame)
            }
            return true
        }
        if flags.contains(.command) { return false }
        // Typing goes to the cells again.
        controller.selectedObjectID = nil
        return false
    }

    // MARK: Cursor

    func objectCursor(at point: CGPoint) -> NSCursor? {
        if case .movingObject = drag { return .closedHand }
        if case .resizingObject = drag { return .crosshair }
        guard let hit = objectHit(at: point) else { return nil }
        switch hit {
        case .menu: return .pointingHand
        case .handle(_, let handle):
            switch handle {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            default: return .crosshair
            }
        case .body: return .openHand
        }
    }
}
