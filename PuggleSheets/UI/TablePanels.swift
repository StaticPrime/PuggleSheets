import AppKit
import PuggleSheetsKit
import SwiftUI

extension TableColumnType {
    /// The choices the table settings offer.
    static let choices: [(title: String, type: TableColumnType?)] = [
        ("Automatic", nil), ("Text", .text), ("Number", .number), ("Percent", .percent), ("Currency", .currency),
        ("Date", .date), ("Time", .time), ("Date time", .dateTime), ("Checkbox", .checkbox), ("Dropdown", .dropdown([])),
    ]

    var title: String {
        switch self {
        case .text: "Text"
        case .number: "Number"
        case .percent: "Percent"
        case .currency: "Currency"
        case .date: "Date"
        case .time: "Time"
        case .dateTime: "Date time"
        case .checkbox: "Checkbox"
        case .dropdown: "Dropdown"
        }
    }

    var isDropdown: Bool { if case .dropdown = self { true } else { false } }
}

/// Format ▸ Table settings: the table's name, color and column types.
struct TablePanel: View {
    let state: EditorState
    let actions: SidebarActions
    @State private var problem: String?

    private var controller: SpreadsheetController { actions.controller }

    var body: some View {
        let _ = state.ruleRevision
        if let id = state.editingTableID, let table = controller.sheet.tables.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 0) {
                PanelSection(title: "Table name") {
                    CommitField(placeholder: "Table1", value: table.name) { name in
                        problem = controller.renameTable(id: id, to: name)
                    }
                    if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Color.red) }
                }
                PanelSection(title: "Range") {
                    Text(table.range.a1).font(.system(size: 13)).foregroundStyle(Theme.primaryText)
                }
                PanelSection(title: "Color") {
                    HStack(spacing: 8) {
                        ForEach(SheetTable.colors, id: \.self) { color in
                            Button {
                                controller.updateTable(id: id, actionName: "Table Color") { $0.color = color }
                            } label: {
                                Circle().fill(Color(nsColor: color.nsColor)).frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(Color.black.opacity(table.color == color ? 0.6 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                PanelSection(title: "Column types") {
                    ForEach(Array(table.range.columns), id: \.self) { column in
                        columnRow(table, column: column)
                    }
                }
                HStack {
                    PanelButton(title: "Delete table", primary: false) {
                        controller.removeTable(id: id)
                        actions.closeSidebar()
                    }
                    Spacer()
                }
            }
        } else {
            Text("Select a cell in a table to see its settings.").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
        }
    }

    private func columnRow(_ table: SheetTable, column: Int) -> some View {
        let header = CellDisplay.text(for: controller.sheet.value(at: CellAddress(row: table.headerRow, column: column)), pattern: nil).text
        let type = table.columnTypes[column]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(header.isEmpty ? "Column \(CellAddress.columnName(column))" : header).font(.system(size: 13)).lineLimit(1)
                Spacer()
                Picker("", selection: Binding(get: { type.map(\.title) ?? "Automatic" }, set: { title in
                    let chosen = TableColumnType.choices.first { $0.title == title }?.type
                    controller.setTableColumnType(chosen, column: column, tableID: table.id)
                })) {
                    ForEach(TableColumnType.choices, id: \.title) { Text($0.title).tag($0.title) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if case .dropdown(let options)? = type {
                CommitField(placeholder: "Options, separated by commas", value: options.joined(separator: ", ")) { text in
                    let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    controller.setTableColumnType(.dropdown(items), column: column, tableID: table.id)
                }
            }
        }
    }
}

/// A slicer's settings: its data, column, title, whether it filters pivot tables, and its color.
struct SlicerPanel: View {
    let state: EditorState
    let actions: SidebarActions

    private var controller: SpreadsheetController { actions.controller }

    var body: some View {
        let _ = state.ruleRevision
        if let id = state.editingObjectID, let spec = controller.object(id: id)?.slicer {
            let headings = controller.slicerHeadings(spec)
            VStack(alignment: .leading, spacing: 0) {
                PanelSection(title: "Data range") {
                    CommitField(placeholder: "Sheet1!A1:D20", value: spec.range,
                                isValid: controller.workbook.resolve(spec.range, onSheet: controller.activeSheetIndex) != nil) { text in
                        let range = controller.qualifiedReference(text)
                        controller.updateSlicer(id: id) { $0.range = range }
                    }
                }
                PanelSection(title: "Column") {
                    Picker("", selection: Binding(get: { spec.column }, set: { column in
                        controller.updateSlicer(id: id) {
                            $0.column = column
                            $0.criterion = FilterCriterion()
                        }
                    })) {
                        ForEach(Array(headings.enumerated()), id: \.offset) { index, heading in Text(heading).tag(index) }
                    }
                    .labelsHidden()
                }
                PanelSection(title: "Title") {
                    CommitField(placeholder: headings.indices.contains(spec.column) ? headings[spec.column] : "Title", value: spec.title) { title in
                        controller.updateSlicer(id: id) { $0.title = title }
                    }
                }
                PanelSection(title: "Options") {
                    Toggle("Apply to pivot tables", isOn: Binding(get: { spec.appliesToPivotTables }, set: { value in
                        controller.updateSlicer(id: id) { $0.appliesToPivotTables = value }
                    }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    HStack {
                        Text("Background color").font(.system(size: 13))
                        Spacer()
                        ColorWell(help: "Background color", color: Binding(get: { spec.backgroundColor }, set: { color in
                            controller.updateSlicer(id: id) { $0.backgroundColor = color }
                        }))
                    }
                }
            }
        } else {
            Text("Select a slicer to edit it.").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
        }
    }
}
