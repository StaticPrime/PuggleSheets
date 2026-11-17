import AppKit
import PuggleSheetsKit
import SwiftUI

/// The popover under a filter button: sort, filter by condition, filter by values.
struct FilterPopoverView: View {
    let column: Int
    let values: [(value: String, count: Int)]
    let criterion: FilterCriterion
    var showsSort = true
    let apply: (FilterCriterion) -> Void
    let sort: (Bool) -> Void
    let close: () -> Void

    @State private var hidden: Set<String> = []
    @State private var useCondition = false
    @State private var kind = CellCondition.Kind.textContains
    @State private var conditionValues = ["", ""]
    @State private var search = ""
    @State private var showsCondition = false
    @State private var showsValues = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsSort {
                Button { sort(true); close() } label: { Label("Sort A → Z", systemImage: "arrow.up").font(.system(size: 13)) }
                    .buttonStyle(.plain)
                Button { sort(false); close() } label: { Label("Sort Z → A", systemImage: "arrow.down").font(.system(size: 13)) }
                    .buttonStyle(.plain)
                Divider()
            }
            DisclosureGroup("Filter by condition", isExpanded: $showsCondition) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Use a condition", isOn: $useCondition).font(.system(size: 13))
                    if useCondition {
                        ConditionPicker(title: "Condition", kind: $kind)
                        ConditionValueFields(kind: kind, values: $conditionValues)
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 13, weight: .medium))
            DisclosureGroup("Filter by values", isExpanded: $showsValues) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Select all") { hidden = [] }.buttonStyle(.link)
                        Text("–").foregroundStyle(Theme.secondaryText)
                        Button("Clear") { hidden = Set(values.map(\.value)) }.buttonStyle(.link)
                        Spacer()
                        Text("Displaying \(visibleValues.count)").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                    .font(.system(size: 12))
                    PanelField(placeholder: "Search", text: $search)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(visibleValues, id: \.value) { item in
                                Toggle(isOn: Binding(get: { !hidden.contains(item.value) },
                                                     set: { shown in if shown { hidden.remove(item.value) } else { hidden.insert(item.value) } })) {
                                    HStack {
                                        Text(item.value.isEmpty ? "(Blanks)" : item.value).font(.system(size: 13)).lineLimit(1)
                                        Spacer()
                                        Text("\(item.count)").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .frame(height: min(200, CGFloat(max(1, visibleValues.count)) * 22 + 4))
                }
                .padding(.top, 6)
            }
            .font(.system(size: 13, weight: .medium))
            HStack {
                Spacer()
                PanelButton(title: "Cancel", primary: false) { close() }
                PanelButton(title: "OK") {
                    let condition = useCondition ? CellCondition(kind, Array(conditionValues.prefix(kind.valueCount))) : nil
                    apply(FilterCriterion(hiddenValues: hidden, condition: condition))
                    close()
                }
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            hidden = criterion.hiddenValues
            if let condition = criterion.condition {
                useCondition = true
                showsCondition = true
                kind = condition.kind
                conditionValues = condition.values + Array(repeating: "", count: max(0, 2 - condition.values.count))
            }
        }
    }

    private var visibleValues: [(value: String, count: Int)] {
        search.isEmpty ? values : values.filter { $0.value.localizedCaseInsensitiveContains(search) }
    }
}
