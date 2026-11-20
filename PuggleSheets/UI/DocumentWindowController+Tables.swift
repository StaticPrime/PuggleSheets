import AppKit
import PuggleSheetsKit
import SwiftUI

/// Tables and slicers: commands, the table menu and the filter pop-ups.
extension DocumentWindowController {
    func psConvertToTable(_ sender: Any?) {
        finishEditing()
        guard let id = controller.convertToTable() else { return }
        showTableSettings(id)
    }

    func psAddSlicer(_ sender: Any?) {
        finishEditing()
        let id = controller.addSlicer()
        showSlicerEditor(id)
    }

    func showTableSettings(_ id: UUID) {
        state.editingTableID = id
        showSidebar(.table)
    }

    func showSlicerEditor(_ id: UUID) {
        state.editingObjectID = id
        controller.selectedObjectID = id
        showSidebar(.slicer)
    }

    /// A table's filter button (sort and filter that column) or its name chip (the table menu).
    func handleTableControl(_ tableID: UUID, column: Int?, rect: CGRect) {
        finishEditing()
        guard let table = controller.sheet.tables.first(where: { $0.id == tableID }), allowsChanges() else { return }
        guard let column else { return showTableMenu(table, at: rect) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        let values = RuleEvaluator.filterValues(column: column, filter: table.asFilter, sheetIndex: controller.activeSheetIndex,
                                                workbook: controller.workbook)
        let view = FilterPopoverView(column: column, values: values, criterion: table.criteria[column] ?? FilterCriterion(),
                                     apply: { [weak self] criterion in self?.controller.setTableCriterion(criterion, column: column, tableID: tableID) },
                                     sort: { [weak self] ascending in self?.controller.sortTable(id: tableID, by: column, ascending: ascending) },
                                     close: { [weak popover] in popover?.performClose(nil) })
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: rect, of: grid, preferredEdge: .maxY)
    }

    private func showTableMenu(_ table: SheetTable, at rect: CGRect) {
        let menu = NSMenu()
        func add(_ title: String, symbol: String, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
            let handler = MenuAction(action)
            item.target = handler
            item.representedObject = handler
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("Rename table…", symbol: "pencil") { [weak self] in self?.askToRenameTable(table) }
        add("Table settings", symbol: "slider.horizontal.3") { [weak self] in self?.showTableSettings(table.id) }
        add("Add a slicer", symbol: "line.3.horizontal.decrease.circle") { [weak self] in self?.psAddSlicer(nil) }
        menu.addItem(.separator())
        add("Delete table (keep data)", symbol: "trash") { [weak self] in self?.controller.removeTable(id: table.id) }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: grid)
    }

    private func askToRenameTable(_ table: SheetTable) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename table"
        let field = NSTextField(string: table.name)
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if let problem = self.controller.renameTable(id: table.id, to: field.stringValue) {
                DispatchQueue.main.async { self.showProblem(problem) }
            }
        }
    }

    /// A slicer's status line: its values and conditions.
    func showSlicerFilter(_ id: UUID, at rect: CGRect) {
        finishEditing()
        guard let spec = controller.object(id: id)?.slicer, allowsChanges() else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        let view = FilterPopoverView(column: spec.column, values: controller.slicerValues(spec), criterion: spec.criterion, showsSort: false,
                                     apply: { [weak self] criterion in self?.controller.updateSlicer(id: id, actionName: "Slicer") { $0.criterion = criterion } },
                                     sort: { _ in },
                                     close: { [weak popover] in popover?.performClose(nil) })
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: rect, of: grid, preferredEdge: .maxY)
    }
}
