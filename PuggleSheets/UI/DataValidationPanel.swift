import AppKit
import PuggleSheetsKit
import SwiftUI

/// Data ▸ Data validation: the sheet's rules, and an editor for one.
struct DataValidationPanel: View {
    let state: EditorState
    let actions: SidebarActions
    @State private var draft: Draft?

    private var controller: SpreadsheetController { actions.controller }

    enum CriterionKind: Hashable {
        case dropdown, dropdownFromRange, checkbox, condition(CellCondition.Kind)

        var title: String {
            switch self {
            case .dropdown: "Dropdown"
            case .dropdownFromRange: "Dropdown (from a range)"
            case .checkbox: "Checkbox"
            case .condition(let kind): kind.title
            }
        }
    }

    struct Draft {
        var id = UUID()
        var isNew = true
        var range = ""
        var kind = CriterionKind.dropdown
        var items = ["Option 1", "Option 2"]
        var sourceRange = ""
        var usesCustomValues = false
        var checkedValue = ""
        var uncheckedValue = ""
        var values = ["", ""]
        var rejectsInvalid = false
        var showsHelp = false
        var helpText = ""
        var showsDropdown = true

        init(range: String, kind: CriterionKind = .dropdown) {
            self.range = range
            self.kind = kind
        }

        init(_ rule: DataValidationRule) {
            id = rule.id
            isNew = false
            range = rangesText(rule.ranges)
            switch rule.criterion {
            case .list(let items):
                kind = .dropdown
                self.items = items
            case .listFromRange(let reference):
                kind = .dropdownFromRange
                sourceRange = reference
            case .checkbox(let checked, let unchecked):
                kind = .checkbox
                usesCustomValues = checked != nil
                checkedValue = checked ?? ""
                uncheckedValue = unchecked ?? ""
            case .condition(let condition):
                kind = .condition(condition.kind)
                values = condition.values + Array(repeating: "", count: max(0, 2 - condition.values.count))
            }
            rejectsInvalid = rule.rejectsInvalid
            showsHelp = rule.helpText != nil
            helpText = rule.helpText ?? ""
            showsDropdown = rule.showsDropdown
        }

        var criterion: DataValidationRule.Criterion {
            switch kind {
            case .dropdown: .list(items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            case .dropdownFromRange: .listFromRange(sourceRange.trimmingCharacters(in: .whitespaces))
            case .checkbox: usesCustomValues ? .checkbox(checked: checkedValue, unchecked: uncheckedValue) : .checkbox(checked: nil, unchecked: nil)
            case .condition(let kind): .condition(CellCondition(kind, Array(values.prefix(kind.valueCount))))
            }
        }

        func rule(ranges: [CellRange]) -> DataValidationRule {
            DataValidationRule(id: id, ranges: ranges, criterion: criterion, rejectsInvalid: rejectsInvalid,
                               helpText: showsHelp && !helpText.isEmpty ? helpText : nil, showsDropdown: showsDropdown)
        }
    }

    var body: some View {
        let _ = state.ruleRevision
        if let draft {
            editor(draft)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            let rules = controller.sheet.validations
            if rules.isEmpty {
                Text("No rules yet. Rules limit what can go in cells, or turn them into dropdowns and checkboxes.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(rules) { rule in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rangesText(rule.ranges)).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primaryText)
                        Text(description(rule.criterion)).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(2)
                    }
                    Spacer()
                    ToolbarIconButton(symbol: "trash", help: "Remove rule") { controller.removeValidation(id: rule.id) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider))
                .contentShape(Rectangle())
                .onTapGesture { draft = Draft(rule) }
            }
            Button {
                draft = Draft(range: state.selectionReference)
            } label: {
                Label("Add rule", systemImage: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .onAppear { if let pending = state.pendingValidationKind { draft = Draft(range: state.selectionReference, kind: pending); state.pendingValidationKind = nil } }
    }

    private func description(_ criterion: DataValidationRule.Criterion) -> String {
        switch criterion {
        case .list(let items): "Dropdown: " + items.joined(separator: ", ")
        case .listFromRange(let reference): "Dropdown (from a range): " + reference
        case .checkbox(let checked, let unchecked):
            checked.map { "Checkbox: \($0) / \(unchecked ?? "")" } ?? "Checkbox"
        case .condition(let condition): condition.summary
        }
    }

    // MARK: Editor

    private func editor(_ current: Draft) -> some View {
        let binding = Binding<Draft>(get: { draft ?? current }, set: { draft = $0 })
        let ranges = parseRanges(binding.wrappedValue.range, sheetName: controller.sheet.name)
        return VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Apply to range") {
                PanelField(placeholder: "A1:A10", text: binding.range, isValid: ranges != nil)
            }
            PanelSection(title: "Criteria") {
                criterionMenu(binding)
                criterionFields(binding)
            }
            PanelSection(title: "Advanced options") {
                Toggle("Show help text for a selected cell", isOn: binding.showsHelp).font(.system(size: 13))
                if binding.wrappedValue.showsHelp {
                    PanelField(placeholder: "Help text", text: binding.helpText)
                }
                Text("If the data is invalid:").font(.system(size: 13)).foregroundStyle(Theme.primaryText).padding(.top, 4)
                Picker("", selection: binding.rejectsInvalid) {
                    Text("Show a warning").tag(false)
                    Text("Reject the input").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if binding.wrappedValue.kind == .dropdown || binding.wrappedValue.kind == .dropdownFromRange {
                    Toggle("Show the dropdown chip", isOn: binding.showsDropdown).font(.system(size: 13)).padding(.top, 4)
                }
            }
            HStack {
                if !binding.wrappedValue.isNew {
                    PanelButton(title: "Remove rule", primary: false) {
                        controller.removeValidation(id: binding.wrappedValue.id)
                        draft = nil
                    }
                }
                Spacer()
                PanelButton(title: "Cancel", primary: false) { draft = nil }
                PanelButton(title: "Done", isEnabled: ranges != nil) {
                    guard let ranges else { return }
                    let rule = binding.wrappedValue.rule(ranges: ranges)
                    if case .checkbox = rule.criterion, binding.wrappedValue.isNew {
                        controller.selection = GridSelection(range: ranges[0])
                        controller.insertCheckboxes()
                    } else {
                        controller.setValidation(rule)
                    }
                    draft = nil
                }
            }
        }
    }

    private func criterionMenu(_ binding: Binding<Draft>) -> some View {
        Menu {
            Button(CriterionKind.dropdown.title) { binding.wrappedValue.kind = .dropdown }
            Button(CriterionKind.dropdownFromRange.title) { binding.wrappedValue.kind = .dropdownFromRange }
            Divider()
            ForEach(Array(CellCondition.Kind.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.self) { kind in
                    Button(kind.title) { binding.wrappedValue.kind = .condition(kind) }
                }
            }
            Divider()
            Button(CriterionKind.checkbox.title) { binding.wrappedValue.kind = .checkbox }
        } label: {
            HStack {
                Text(binding.wrappedValue.kind.title).font(.system(size: 13)).foregroundStyle(Theme.primaryText)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.divider))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    @ViewBuilder
    private func criterionFields(_ binding: Binding<Draft>) -> some View {
        switch binding.wrappedValue.kind {
        case .dropdown:
            ForEach(binding.wrappedValue.items.indices, id: \.self) { index in
                HStack {
                    PanelField(placeholder: "Option \(index + 1)", text: Binding(
                        get: { index < binding.wrappedValue.items.count ? binding.wrappedValue.items[index] : "" },
                        set: { if index < binding.wrappedValue.items.count { binding.wrappedValue.items[index] = $0 } }))
                    ToolbarIconButton(symbol: "trash", help: "Remove item", isEnabled: binding.wrappedValue.items.count > 1) {
                        binding.wrappedValue.items.remove(at: index)
                    }
                }
            }
            Button {
                binding.wrappedValue.items.append("")
            } label: {
                Label("Add another item", systemImage: "plus").font(.system(size: 13)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        case .dropdownFromRange:
            PanelField(placeholder: "Sheet1!A1:A10", text: binding.sourceRange)
        case .checkbox:
            Toggle("Use custom cell values", isOn: binding.usesCustomValues).font(.system(size: 13))
            if binding.wrappedValue.usesCustomValues {
                PanelField(placeholder: "Checked", text: binding.checkedValue)
                PanelField(placeholder: "Unchecked", text: binding.uncheckedValue)
            }
        case .condition(let kind):
            ConditionValueFields(kind: kind, values: binding.values)
        }
    }
}
