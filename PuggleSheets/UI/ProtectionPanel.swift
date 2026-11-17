import AppKit
import PuggleSheetsKit
import SwiftUI

/// Data ▸ Protect sheets and ranges: the active sheet's protections, and an editor for one.
struct ProtectionPanel: View {
    let state: EditorState
    let actions: SidebarActions
    @State private var editingID: UUID?
    @State private var isEditing = false
    @State private var descriptionText = ""
    @State private var protectsSheet = false
    @State private var rangeText = ""
    @State private var hasExceptions = false
    @State private var exceptionsText = ""
    @State private var warningOnly = true

    private var controller: SpreadsheetController { actions.controller }

    var body: some View {
        let _ = state.ruleRevision
        if isEditing { editor } else { list }
    }

    private func label(_ protection: ProtectedRange) -> String {
        switch protection.scope {
        case .range(let range): range.a1
        case .sheet(let except): except.isEmpty ? controller.sheet.name : "\(controller.sheet.name) (except \(rangesText(except)))"
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.sheet.protections.isEmpty {
                Text("Protect a range or this sheet so that it warns before it changes, or can't be changed until you remove the protection.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(controller.sheet.protections) { protection in
                HStack(spacing: 10) {
                    Image(systemName: protection.warningOnly ? "exclamationmark.triangle" : "lock.fill")
                        .foregroundStyle(Theme.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(protection.description.isEmpty ? label(protection) : protection.description)
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primaryText).lineLimit(1)
                        Text(label(protection)).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    ToolbarIconButton(symbol: "trash", help: "Remove protection") { controller.removeProtection(id: protection.id) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider))
                .contentShape(Rectangle())
                .onTapGesture { load(protection) }
            }
            Button {
                load(nil)
            } label: {
                Label("Add a sheet or range", systemImage: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private var editor: some View {
        let ranges = parseRanges(rangeText, sheetName: controller.sheet.name)
        let exceptions = hasExceptions ? parseRanges(exceptionsText, sheetName: controller.sheet.name) : []
        let valid = (protectsSheet || ranges?.count == 1) && (!hasExceptions || exceptions != nil)
        return VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Description") {
                PanelField(placeholder: "Enter a description", text: $descriptionText)
            }
            Picker("", selection: $protectsSheet) {
                Text("Range").tag(false)
                Text("Sheet").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 14)
            if protectsSheet {
                PanelSection(title: "Sheet") {
                    Text(controller.sheet.name).font(.system(size: 13))
                    Toggle("Except certain cells", isOn: $hasExceptions).toggleStyle(.checkbox).font(.system(size: 13))
                    if hasExceptions {
                        PanelField(placeholder: "A1:B10", text: $exceptionsText, isValid: exceptions != nil)
                    }
                }
            } else {
                PanelSection(title: "Range") {
                    PanelField(placeholder: "A1:D10", text: $rangeText, isValid: ranges?.count == 1)
                }
            }
            PanelSection(title: "Permissions") {
                Picker("", selection: $warningOnly) {
                    Text("Show a warning when editing this range").tag(true)
                    Text("Restrict editing: changes are refused until the protection is removed").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .font(.system(size: 13))
            }
            HStack {
                Spacer()
                PanelButton(title: "Cancel", primary: false) { isEditing = false }
                PanelButton(title: "Done", isEnabled: valid) {
                    let scope: ProtectedRange.Scope = protectsSheet ? .sheet(except: exceptions ?? []) : .range(ranges?.first ?? CellRange(CellAddress(row: 0, column: 0)))
                    controller.setProtection(ProtectedRange(id: editingID ?? UUID(), scope: scope,
                                                            description: descriptionText.trimmingCharacters(in: .whitespaces),
                                                            warningOnly: warningOnly))
                    isEditing = false
                }
            }
        }
    }

    private func load(_ protection: ProtectedRange?) {
        editingID = protection?.id
        descriptionText = protection?.description ?? ""
        warningOnly = protection?.warningOnly ?? true
        switch protection?.scope {
        case .sheet(let except)?:
            protectsSheet = true
            hasExceptions = !except.isEmpty
            exceptionsText = rangesText(except)
            rangeText = controller.selection.current.a1
        case .range(let range)?:
            protectsSheet = false
            rangeText = range.a1
            hasExceptions = false
            exceptionsText = ""
        case nil:
            protectsSheet = false
            rangeText = controller.selection.current.a1
            hasExceptions = false
            exceptionsText = ""
        }
        isEditing = true
    }
}

/// Data ▸ Column stats: counts, a summary of the numbers and the most frequent values in the active column.
struct ColumnStatsPanel: View {
    let state: EditorState
    let actions: SidebarActions

    private var controller: SpreadsheetController { actions.controller }

    var body: some View {
        let _ = state.ruleRevision
        let _ = state.selectionReference
        let sheet = controller.sheet
        let column = controller.selection.active.column
        let lastRow = sheet.contentRange?.end.row ?? 0
        let values = (0...lastRow).map { sheet.value(at: CellAddress(row: $0, column: column)) }
        let filled = values.filter { $0 != .empty }
        let numbers = filled.compactMap(\.numberValue).sorted()
        var counts: [String: Int] = [:]
        for value in filled { counts[CellDisplay.text(for: value, pattern: nil).text, default: 0] += 1 }
        let frequent = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(10)
        let format = { (number: Double) in EditorState.statisticText(number, format: nil) }
        return VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Column \(CellAddress.columnName(column))") {
                statRow("Count", "\(filled.count)")
                statRow("Empty", "\(values.count - filled.count)")
                statRow("Unique", "\(counts.count)")
            }
            if !numbers.isEmpty {
                PanelSection(title: "Numbers") {
                    statRow("Sum", format(numbers.reduce(0, +)))
                    statRow("Average", format(numbers.reduce(0, +) / Double(numbers.count)))
                    statRow("Median", format(numbers.count % 2 == 1 ? numbers[numbers.count / 2]
                                             : (numbers[numbers.count / 2 - 1] + numbers[numbers.count / 2]) / 2))
                    statRow("Min", format(numbers.first ?? 0))
                    statRow("Max", format(numbers.last ?? 0))
                }
            }
            if !frequent.isEmpty {
                PanelSection(title: "Frequency") {
                    let top = frequent.first?.value ?? 1
                    ForEach(Array(frequent), id: \.key) { item in
                        HStack(spacing: 8) {
                            Text(item.key.isEmpty ? "(blank)" : item.key).font(.system(size: 12)).lineLimit(1).frame(width: 110, alignment: .leading)
                            GeometryReader { geometry in
                                RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.26, green: 0.52, blue: 0.96))
                                    .frame(width: max(2, geometry.size.width * CGFloat(item.value) / CGFloat(top)))
                            }
                            .frame(height: 12)
                            Text("\(item.value)").font(.system(size: 12)).monospacedDigit().frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value).font(.system(size: 13)).monospacedDigit()
        }
    }
}

/// File ▸ Import: where the file's data goes.
enum ImportLocation: String, CaseIterable, Identifiable {
    case newSpreadsheet = "Create new spreadsheet"
    case insertSheets = "Insert new sheet(s)"
    case replaceSpreadsheet = "Replace spreadsheet"
    case replaceSheet = "Replace current sheet"
    case appendToSheet = "Append to current sheet"
    case replaceAtSelection = "Replace data at selected cell"

    var id: Self { self }

    /// Delimited files hold one sheet; workbooks can't be appended or placed at a cell.
    static func choices(delimited: Bool) -> [ImportLocation] {
        delimited ? allCases : [.newSpreadsheet, .insertSheets, .replaceSpreadsheet]
    }
}

struct ImportView: View {
    let fileName: String
    let delimited: Bool
    let finish: (_ location: ImportLocation?, _ tabs: Bool?) -> Void
    @State private var location = ImportLocation.insertSheets
    @State private var separator = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import file").font(.system(size: 20))
            Text(fileName).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            PanelSection(title: "Import location") {
                Picker("", selection: $location) {
                    ForEach(ImportLocation.choices(delimited: delimited)) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .font(.system(size: 13))
            }
            if delimited {
                PanelSection(title: "Separator type") {
                    Picker("", selection: $separator) {
                        Text("Detect automatically").tag(0)
                        Text("Tab").tag(1)
                        Text("Comma").tag(2)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            HStack {
                Spacer()
                PanelButton(title: "Cancel", primary: false) { finish(nil, nil) }
                    .keyboardShortcut(.cancelAction)
                PanelButton(title: "Import data") { finish(location, separator == 0 ? nil : separator == 1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
