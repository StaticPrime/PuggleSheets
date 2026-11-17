import AppKit
import PuggleSheetsKit
import SwiftUI
import UniformTypeIdentifiers

/// The last image or chart copied in PuggleSheets, while the pasteboard still holds it.
@MainActor
enum ObjectClipboard {
    private static var stored: (object: SheetObject, changeCount: Int)?

    static func store(_ object: SheetObject, changeCount: Int) {
        stored = (object, changeCount)
    }

    static func object(forChangeCount changeCount: Int) -> SheetObject? {
        guard let stored, stored.changeCount == changeCount else { return nil }
        return stored.object
    }
}

/// Charts, images, links, pivot tables and filter views: commands, menus and panels.
extension DocumentWindowController {
    // MARK: Charts

    func psInsertChart(_ sender: Any?) {
        finishEditing()
        let id = controller.insertChart()
        if let object = controller.object(id: id) { grid.scrollToVisible(object.anchor.cell) }
        showChartEditor(id)
    }

    func showChartEditor(_ id: UUID) {
        state.editingObjectID = id
        controller.selectedObjectID = id
        showSidebar(.chartEditor)
    }

    /// The menu of an image or chart: from its ⋮ button or a right-click.
    func objectMenu(for id: UUID) -> NSMenu? {
        guard let object = controller.object(id: id) else { return nil }
        let menu = NSMenu()
        func add(_ title: String, symbol: String? = nil, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
            let handler = MenuAction(action)
            item.target = handler
            item.representedObject = handler
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        if object.slicer != nil {
            add("Edit slicer", symbol: "pencil") { [weak self] in self?.showSlicerEditor(id) }
            add("Delete slicer", symbol: "trash") { [weak self] in self?.controller.removeObject(id: id) }
        } else if let spec = object.chart {
            add("Edit chart", symbol: "pencil") { [weak self] in self?.showChartEditor(id) }
            add("Delete chart", symbol: "trash") { [weak self] in self?.controller.removeObject(id: id) }
            menu.addItem(.separator())
            let download = NSMenuItem(title: "Download", action: nil, keyEquivalent: "")
            download.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)
            let downloadMenu = NSMenu()
            for (title, type) in [("PNG image (.png)", UTType.png), ("PDF document (.pdf)", UTType.pdf), ("Scalable Vector Graphics (.svg)", UTType.svg)] {
                let item = NSMenuItem(title: title, action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
                let handler = MenuAction { [weak self] in self?.downloadChart(id: id, spec: spec, type: type) }
                item.target = handler
                item.representedObject = handler
                downloadMenu.addItem(item)
            }
            download.submenu = downloadMenu
            menu.addItem(download)
        } else {
            add("Put image in selected cell", symbol: "square.and.arrow.down") { [weak self] in self?.controller.placeObjectInCell(id: id) }
            add("Reset size", symbol: "arrow.uturn.backward") { [weak self] in
                guard let self, let image = self.controller.object(id: id)?.image else { return }
                self.controller.updateObject(id: id, actionName: "Reset Size") {
                    $0.anchor.width = Double(image.pixelWidth)
                    $0.anchor.height = Double(image.pixelHeight)
                }
            }
            add("Delete image", symbol: "trash") { [weak self] in self?.controller.removeObject(id: id) }
        }
        menu.addItem(.separator())
        add("Copy", symbol: "doc.on.doc") { [weak self] in self?.copyObject(id: id, cut: false) }
        add("Alt text", symbol: "text.below.photo") { [weak self] in self?.editAltText(id: id) }
        add("Bring to front", symbol: "square.3.layers.3d.top.filled") { [weak self] in self?.controller.reorderObject(id: id, toFront: true) }
        add("Send to back", symbol: "square.3.layers.3d.bottom.filled") { [weak self] in self?.controller.reorderObject(id: id, toFront: false) }
        return menu
    }

    func showObjectMenu(_ id: UUID, at rect: CGRect) {
        guard let menu = objectMenu(for: id) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: grid)
    }

    private func downloadChart(id: UUID, spec: ChartSpec, type: UTType) {
        guard let window, let object = controller.object(id: id) else { return }
        let table = ChartBuilder.table(for: spec, sheetIndex: controller.activeSheetIndex, workbook: controller.workbook)
        let size = CGSize(width: object.anchor.width, height: object.anchor.height)
        let data: Data? = switch type {
        case .png: ChartRenderer.pngData(spec, table: table, size: size, scale: 2)
        case .pdf: ChartRenderer.pdfData(spec, table: table, size: size)
        default: ChartRenderer.svg(spec, table: table, size: size).data(using: .utf8)
        }
        guard let data, !data.isEmpty else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        let title = spec.title.isEmpty ? "Chart" : spec.title
        panel.nameFieldStringValue = title + "." + (type.preferredFilenameExtension ?? "png")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    private func editAltText(id: UUID) {
        guard let window, let object = controller.object(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Alt text"
        alert.informativeText = "Describe the \(object.chart != nil ? "chart" : "image") for people who use screen readers."
        let title = NSTextField(string: object.title)
        title.placeholderString = "Title"
        let description = NSTextField(string: object.altDescription)
        description.placeholderString = "Description"
        let stack = NSStackView(views: [title, description])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 56)
        title.frame.size.width = 280
        description.frame.size.width = 280
        alert.accessoryView = stack
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.controller.updateObject(id: id, actionName: "Alt Text") {
                $0.title = title.stringValue
                $0.altDescription = description.stringValue
            }
        }
    }

    // MARK: Copying objects

    /// Copies an image or chart: PuggleSheets pastes the object, other apps get a picture of it.
    func copyObject(id: UUID, cut: Bool) {
        guard let object = controller.object(id: id) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch object.content {
        case .image(let image):
            pasteboard.setData(image.data, forType: image.format == .png ? .png : NSPasteboard.PasteboardType(UTType(mimeType: image.format.mimeType)?.identifier ?? "public.image"))
        case .chart(let spec):
            let table = ChartBuilder.table(for: spec, sheetIndex: controller.activeSheetIndex, workbook: controller.workbook)
            if let png = ChartRenderer.pngData(spec, table: table, size: CGSize(width: object.anchor.width, height: object.anchor.height), scale: 2) {
                pasteboard.setData(png, forType: .png)
            }
        case .slicer:
            // Other apps get nothing for a slicer; PuggleSheets pastes it.
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("com.pugglesoft.pugglesheets.slicer"))
        }
        ObjectClipboard.store(object, changeCount: pasteboard.changeCount)
        if cut { controller.removeObject(id: id) }
    }

    /// Pastes a copied object, or a picture from another app, over the cells at the active cell.
    /// Returns false when the pasteboard holds neither.
    func pasteObjectOrImage() -> Bool {
        let pasteboard = NSPasteboard.general
        let address = controller.selection.active
        if let object = ObjectClipboard.object(forChangeCount: pasteboard.changeCount) {
            var anchor = object.anchor
            anchor.cell = address
            anchor.offsetX = 0
            anchor.offsetY = 0
            controller.addObject(SheetObject(anchor: anchor, content: object.content, title: object.title,
                                             altDescription: object.altDescription), actionName: "Paste")
            return true
        }
        guard pasteboard.types?.contains(.puggleSheetsCells) != true, pasteboard.string(forType: .string) == nil,
              let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              let image = SpreadsheetController.imageData(from: data) else { return false }
        controller.insertImageOverCells(image, at: address)
        return true
    }

    // MARK: Images

    func psInsertImageInCell(_ sender: Any?) { chooseImage(inCell: true) }
    func psInsertImageOverCells(_ sender: Any?) { chooseImage(inCell: false) }

    private func chooseImage(inCell: Bool) {
        finishEditing()
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = inCell ? "Choose an image to put in the selected cell" : "Choose an image to place over the cells"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url), let image = SpreadsheetController.imageData(from: data) else {
                return self.showProblem("PuggleSheets can’t read that image.")
            }
            let address = self.controller.selection.active
            if inCell { self.controller.insertImageInCell(image, at: address) } else { self.controller.insertImageOverCells(image, at: address) }
        }
    }

    // MARK: Links

    func psInsertLink(_ sender: Any?) {
        finishEditing()
        showLinkEditor()
    }

    func showLinkEditor() {
        let address = controller.selection.active
        let sheet = controller.sheet
        let cell = sheet[address]
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        let view = InsertLinkView(text: cell.hasContent ? CellDisplay.text(for: cell.value, pattern: cell.format.numberFormat).text : "",
                                  link: cell.link ?? sheet.link(at: address) ?? "",
                                  sheets: controller.workbook.sheets.map { ($0.id, $0.name) },
                                  namedRanges: controller.workbook.namedRanges.map(\.name),
                                  hasLink: cell.link != nil,
                                  apply: { [weak self] text, link in self?.controller.setLink(link, text: text, at: address) },
                                  remove: { [weak self] in self?.controller.setLink(nil, text: nil, at: address) },
                                  close: { [weak popover] in popover?.performClose(nil) })
        popover.contentViewController = NSHostingController(rootView: view)
        grid.scrollToVisible(address)
        popover.show(relativeTo: grid.cellRect(address), of: grid, preferredEdge: .maxY)
    }

    /// Opens a link: places in the spreadsheet are selected, web pages open in the browser.
    func openLink(_ link: String) {
        if controller.followInternalLink(link) {
            focusGrid()
            return
        }
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "ftp"].contains(scheme) else {
            return NSSound.beep()
        }
        NSWorkspace.shared.open(url)
    }

    /// Shows the link card under the active cell when it holds a link.
    func updateLinkCard() {
        let address = controller.selection.active
        guard grid.editor == nil, !formulaBar.isEditing, controller.selectedObjectID == nil, controller.selection.ranges.count == 1,
              controller.selection.current == controller.mergedRange(at: address),
              let link = controller.sheet.link(at: address), let contentView = window?.contentView else {
            linkCard?.isHidden = true
            return
        }
        let cellRect = grid.cellRect(address)
        guard grid.gridBounds.intersects(cellRect) else {
            linkCard?.isHidden = true
            return
        }
        let isInternal = LinkTarget(link: link).map { if case .url = $0 { false } else { true } } ?? false
        let view = LinkCardView(title: controller.linkTitle(link), isInternal: isInternal,
                                open: { [weak self] in self?.openLink(link) },
                                copy: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(link, forType: .string)
                                },
                                edit: { [weak self] in self?.showLinkEditor() },
                                remove: { [weak self] in self?.controller.setLink(nil, text: nil, at: address) })
        let card: NSHostingView<LinkCardView>
        if let existing = linkCard {
            existing.rootView = view
            card = existing
        } else {
            card = NSHostingView(rootView: view)
            card.sizingOptions = [.intrinsicContentSize]
            contentView.addSubview(card, positioned: .above, relativeTo: nil)
            linkCard = card
        }
        card.isHidden = false
        let size = card.intrinsicContentSize
        let anchor = contentView.convert(cellRect, from: grid)
        var frame = NSRect(x: anchor.minX - 8, y: anchor.minY - size.height + 4, width: size.width, height: size.height)
        if contentView.isFlipped { frame.origin.y = anchor.maxY - 4 }
        frame.origin.x = max(0, min(frame.origin.x, contentView.bounds.maxX - size.width))
        card.frame = frame
    }

    // MARK: Pivot tables

    func psInsertPivotTable(_ sender: Any?) {
        finishEditing()
        let range = controller.selection.current.isSingleCell ? controller.dataRegion(around: controller.selection.active) : controller.selection.current
        let source = SpreadsheetController.quotedSheetName(controller.sheet.name) + "!" + range.a1
        let controller = self.controller
        presentSheet { [weak self] dismiss in
            CreatePivotTableView(source: source, existingDefault: "",
                                 isValid: { controller.workbook.resolve($0, onSheet: controller.activeSheetIndex) != nil },
                                 create: { source, location in
                                     guard let id = controller.createPivotTable(source: source, location: location) else { return false }
                                     DispatchQueue.main.async { self?.showPivotEditor(id) }
                                     return true
                                 },
                                 dismiss: dismiss)
        }
    }

    func showPivotEditor(_ id: UUID) {
        state.editingPivotID = id
        showSidebar(.pivotEditor)
    }

    func editPivotFilter(pivotID: UUID, index: Int) {
        guard let (sheetIndex, pivot) = controller.pivotTable(id: pivotID), pivot.filters.indices.contains(index) else { return }
        let filter = pivot.filters[index]
        let values = PivotEngine.sourceValues(column: filter.sourceColumn, for: pivot, sheetIndex: sheetIndex, workbook: controller.workbook)
        presentSheet { [weak self] dismiss in
            FilterPopoverView(column: filter.sourceColumn, values: values, criterion: filter.criterion, showsSort: false,
                              apply: { criterion in
                                  self?.controller.updatePivotTable(id: pivotID, actionName: "Pivot Table Filter") { pivot in
                                      if pivot.filters.indices.contains(index) { pivot.filters[index].criterion = criterion }
                                  }
                              },
                              sort: { _ in },
                              close: dismiss)
        }
    }

    // MARK: Filter views

    func psCreateFilterView(_ sender: Any?) { finishEditing(); controller.createFilterView() }
    func psSaveFilterAsView(_ sender: Any?) { finishEditing(); controller.saveFilterAsView() }
    func psCloseFilterView(_ sender: Any?) { controller.openFilterView(nil) }

    func psOpenFilterView(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        finishEditing()
        controller.openFilterView(controller.activeFilterView?.id == id ? nil : id)
    }

    func updateFilterViewBar() {
        let showing = controller.activeFilterView != nil
        filterViewBarHeight.constant = showing ? 40 : 0
    }
}
