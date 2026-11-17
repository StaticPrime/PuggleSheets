import AppKit
import PuggleSheetsKit
import SwiftUI

/// Insert ▸ Pivot table: the data range and where the pivot table goes.
struct CreatePivotTableView: View {
    @State var source: String
    let existingDefault: String
    let isValid: (String) -> Bool
    let create: (_ source: String, _ location: String?) -> Bool
    let dismiss: () -> Void
    @State private var newSheet = true
    @State private var location = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create pivot table").font(.system(size: 20))
            PanelSection(title: "Data range") {
                PanelField(placeholder: "Sheet1!A1:D20", text: $source, isValid: isValid(source))
            }
            PanelSection(title: "Insert to") {
                Picker("", selection: $newSheet) {
                    Text("New sheet").tag(true)
                    Text("Existing sheet").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if !newSheet {
                    PanelField(placeholder: "Sheet2!A1", text: $location, isValid: location.isEmpty || isValid(location))
                }
            }
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Color.red)
            }
            HStack {
                Spacer()
                PanelButton(title: "Cancel", primary: false) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                PanelButton(title: "Create", isEnabled: isValid(source) && (newSheet || isValid(location))) {
                    if create(source, newSheet ? nil : location) {
                        dismiss()
                    } else {
                        problem = "Enter a cell like Sheet2!A1 for the pivot table's top-left corner."
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { location = existingDefault }
    }
}

extension PivotValue.Summary {
    var title: String { rawValue }
}

extension PivotValue.ShowAs {
    var title: String {
        switch self {
        case .default: "Default"
        case .percentOfRow: "% of row"
        case .percentOfColumn: "% of column"
        case .percentOfGrandTotal: "% of grand total"
        }
    }
}

/// The pivot table editor: the data range, then rows, columns, values and filters.
struct PivotEditorPanel: View {
    let state: EditorState
    let actions: SidebarActions
    let editFilter: (_ pivotID: UUID, _ filterIndex: Int) -> Void

    private var controller: SpreadsheetController { actions.controller }

    var body: some View {
        let _ = state.ruleRevision
        if let id = state.editingPivotID, let (sheetIndex, pivot) = controller.pivotTable(id: id) {
            let headers = PivotEngine.sourceHeaders(for: pivot, sheetIndex: sheetIndex, workbook: controller.workbook)
            VStack(alignment: .leading, spacing: 0) {
                PanelSection(title: "Data range") {
                    CommitField(placeholder: "Sheet1!A1:D20", value: pivot.source,
                                isValid: controller.workbook.resolve(pivot.source, onSheet: sheetIndex) != nil) { text in
                        let source = controller.qualifiedReference(text)
                        controller.updatePivotTable(id: id) { $0.source = source }
                    }
                }
                groupSection("Rows", id: id, pivot: pivot, headers: headers, rows: true)
                groupSection("Columns", id: id, pivot: pivot, headers: headers, rows: false)
                valueSection(id: id, pivot: pivot, headers: headers)
                filterSection(id: id, pivot: pivot, headers: headers)
            }
        } else {
            Text("Select a cell in a pivot table to edit it.").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
        }
    }

    private func heading(_ headers: [String], _ column: Int) -> String {
        column < headers.count ? headers[column] : "Column \(column + 1)"
    }

    private func sectionHeader(_ title: String, headers: [String], add: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primaryText)
            Spacer()
            Menu {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, name in
                    Button(name) { add(index) }
                }
            } label: {
                Text("Add").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(headers.isEmpty)
        }
    }

    private func card<Content: View>(_ title: String, remove: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                ToolbarIconButton(symbol: "xmark", help: "Remove") { remove() }
            }
            content()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0xF8 / 255, green: 0xF9 / 255, blue: 0xFA / 255)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.divider))
        .font(.system(size: 12))
    }

    @ViewBuilder private func groupSection(_ title: String, id: UUID, pivot: PivotTable, headers: [String], rows: Bool) -> some View {
        let groups = rows ? pivot.rows : pivot.columns
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title, headers: headers) { column in
                controller.updatePivotTable(id: id) { pivot in
                    if rows { pivot.rows.append(PivotGroup(sourceColumn: column)) } else { pivot.columns.append(PivotGroup(sourceColumn: column)) }
                }
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                card(heading(headers, group.sourceColumn)) {
                    controller.updatePivotTable(id: id) { pivot in
                        if rows { pivot.rows.remove(at: index) } else { pivot.columns.remove(at: index) }
                    }
                } content: {
                    HStack {
                        Picker("Order", selection: Binding(get: { group.ascending }, set: { value in
                            controller.updatePivotTable(id: id) { pivot in
                                if rows { pivot.rows[index].ascending = value } else { pivot.columns[index].ascending = value }
                            }
                        })) {
                            Text("Ascending").tag(true)
                            Text("Descending").tag(false)
                        }
                    }
                    Picker("Sort by", selection: Binding(get: { group.sortByValue ?? -1 }, set: { value in
                        controller.updatePivotTable(id: id) { pivot in
                            let sort = value < 0 ? nil : value
                            if rows { pivot.rows[index].sortByValue = sort } else { pivot.columns[index].sortByValue = sort }
                        }
                    })) {
                        Text(heading(headers, group.sourceColumn)).tag(-1)
                        ForEach(Array(pivot.values.enumerated()), id: \.offset) { valueIndex, value in
                            Text(value.name ?? "\(value.summary.title) of \(heading(headers, value.sourceColumn))").tag(valueIndex)
                        }
                    }
                    Toggle("Show totals", isOn: Binding(get: { group.showsTotals }, set: { value in
                        controller.updatePivotTable(id: id) { pivot in
                            if rows { pivot.rows[index].showsTotals = value } else { pivot.columns[index].showsTotals = value }
                        }
                    }))
                    .toggleStyle(.checkbox)
                }
            }
        }
        .padding(.bottom, 16)
    }

    @ViewBuilder private func valueSection(id: UUID, pivot: PivotTable, headers: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Values", headers: headers) { column in
                controller.updatePivotTable(id: id) { $0.values.append(PivotValue(sourceColumn: column)) }
            }
            if pivot.values.count > 1 {
                Picker("Values as", selection: Binding(get: { pivot.valuesInRows }, set: { value in
                    controller.updatePivotTable(id: id) { $0.valuesInRows = value }
                })) {
                    Text("Columns").tag(false)
                    Text("Rows").tag(true)
                }
                .font(.system(size: 12))
            }
            ForEach(Array(pivot.values.enumerated()), id: \.offset) { index, value in
                card(heading(headers, value.sourceColumn)) {
                    controller.updatePivotTable(id: id) { $0.values.remove(at: index) }
                } content: {
                    Picker("Summarize by", selection: Binding(get: { value.summary }, set: { summary in
                        controller.updatePivotTable(id: id) { $0.values[index].summary = summary }
                    })) {
                        ForEach(PivotValue.Summary.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Show as", selection: Binding(get: { value.showAs }, set: { showAs in
                        controller.updatePivotTable(id: id) { $0.values[index].showAs = showAs }
                    })) {
                        ForEach(PivotValue.ShowAs.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
        }
        .padding(.bottom, 16)
    }

    @ViewBuilder private func filterSection(id: UUID, pivot: PivotTable, headers: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Filters", headers: headers) { column in
                controller.updatePivotTable(id: id) { $0.filters.append(PivotFilter(sourceColumn: column)) }
            }
            ForEach(Array(pivot.filters.enumerated()), id: \.offset) { index, filter in
                card(heading(headers, filter.sourceColumn)) {
                    controller.updatePivotTable(id: id) { $0.filters.remove(at: index) }
                } content: {
                    HStack {
                        Text("Status").foregroundStyle(Theme.secondaryText)
                        Button(status(filter.criterion)) { editFilter(id, index) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func status(_ criterion: FilterCriterion) -> String {
        if let condition = criterion.condition { return condition.summary }
        return criterion.hiddenValues.isEmpty ? "Showing all items" : "\(criterion.hiddenValues.count) hidden"
    }
}
