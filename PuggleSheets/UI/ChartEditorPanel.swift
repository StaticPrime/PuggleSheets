import AppKit
import PuggleSheetsKit
import SwiftUI

/// A text field that applies its text when Return is pressed or it loses focus, so typing doesn't
/// record an undo step per keystroke.
struct CommitField: View {
    let placeholder: String
    let value: String
    var isValid = true
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        PanelField(placeholder: placeholder, text: $text, isValid: isValid)
            .focused($focused)
            .onSubmit { if text != value { commit(text) } }
            .onChange(of: focused) { _, isFocused in if !isFocused, text != value { commit(text) } }
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
    }
}

extension ChartSpec.Kind {
    var title: String {
        switch self {
        case .column: "Column chart"
        case .stackedColumn: "Stacked column chart"
        case .percentColumn: "100% stacked column chart"
        case .bar: "Bar chart"
        case .stackedBar: "Stacked bar chart"
        case .percentBar: "100% stacked bar chart"
        case .line: "Line chart"
        case .smoothLine: "Smooth line chart"
        case .area: "Area chart"
        case .stackedArea: "Stacked area chart"
        case .percentArea: "100% stacked area chart"
        case .pie: "Pie chart"
        case .donut: "Doughnut chart"
        case .scatter: "Scatter chart"
        case .combo: "Combo chart"
        }
    }

    var symbol: String {
        switch self {
        case .column, .stackedColumn, .percentColumn, .combo: "chart.bar"
        case .bar, .stackedBar, .percentBar: "chart.bar.xaxis"
        case .line, .smoothLine: "chart.xyaxis.line"
        case .area, .stackedArea, .percentArea: "chart.line.uptrend.xyaxis"
        case .pie, .donut: "chart.pie"
        case .scatter: "chart.dots.scatter"
        }
    }

    var isPie: Bool { self == .pie || self == .donut }
    var hasLines: Bool { [.line, .smoothLine, .area, .stackedArea, .percentArea, .scatter, .combo].contains(self) }

    /// The chart type menu's groups.
    static let groups: [(String, [ChartSpec.Kind])] = [
        ("Line", [.line, .smoothLine, .combo]),
        ("Area", [.area, .stackedArea, .percentArea]),
        ("Column", [.column, .stackedColumn, .percentColumn]),
        ("Bar", [.bar, .stackedBar, .percentBar]),
        ("Pie", [.pie, .donut]),
        ("Scatter", [.scatter]),
    ]
}

/// Insert ▸ Chart's chart editor: Setup (type, data, headers and labels) and Customize (style,
/// titles, series, legend, axis, gridlines).
struct ChartEditorPanel: View {
    let state: EditorState
    let actions: SidebarActions
    @State private var tab = 0
    @State private var titleTarget = 0
    @State private var seriesIndex = 0

    private var controller: SpreadsheetController { actions.controller }

    var body: some View {
        let _ = state.ruleRevision
        if let id = state.editingObjectID, let object = controller.object(id: id), let spec = object.chart {
            let table = ChartBuilder.table(for: spec, sheetIndex: controller.activeSheetIndex, workbook: controller.workbook)
            VStack(alignment: .leading, spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Setup").tag(0)
                    Text("Customize").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.bottom, 16)
                if tab == 0 { setup(id, spec, table) } else { customize(id, spec, table) }
            }
        } else {
            Text("Select a chart to edit it.").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
        }
    }

    private func change(_ id: UUID, _ edit: @escaping (inout ChartSpec) -> Void) {
        controller.updateChart(id: id, edit)
    }

    // MARK: Setup

    @ViewBuilder private func setup(_ id: UUID, _ spec: ChartSpec, _ table: ChartTable) -> some View {
        PanelSection(title: "Chart type") {
            Menu {
                ForEach(ChartSpec.Kind.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1, id: \.self) { kind in
                            Button { change(id) { $0.kind = kind } } label: { Label(kind.title, systemImage: kind.symbol) }
                        }
                    }
                }
            } label: {
                Label(spec.kind.title, systemImage: spec.kind.symbol).font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.divider))
        }
        let rangesText = spec.ranges.joined(separator: ", ")
        PanelSection(title: "Data range") {
            CommitField(placeholder: "A1:D10", value: rangesText,
                        isValid: spec.ranges.allSatisfy { controller.workbook.resolve($0, onSheet: controller.activeSheetIndex) != nil }) { text in
                let ranges = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                change(id) { $0.ranges = ranges }
            }
        }
        if spec.firstColumnIsLabels {
            PanelSection(title: spec.kind == .scatter ? "X-axis" : (spec.kind.isPie ? "Label" : "X-axis")) {
                Text(labelHeading(spec, table)).font(.system(size: 13)).foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.divider))
            }
        }
        PanelSection(title: spec.kind.isPie ? "Value" : "Series") {
            if table.series.isEmpty {
                Text("No data").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(Array(table.series.prefix(spec.kind.isPie ? 1 : table.series.count).enumerated()), id: \.offset) { index, series in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: seriesColor(spec, index).nsColor)).frame(width: 12, height: 12)
                    Text(series.name).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.divider))
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Switch rows / columns", isOn: Binding(get: { spec.switchRowsAndColumns }, set: { value in change(id) { $0.switchRowsAndColumns = value } }))
            Toggle(spec.switchRowsAndColumns ? "Use column A as headers" : "Use row 1 as headers",
                   isOn: Binding(get: { spec.firstRowIsHeader }, set: { value in change(id) { $0.firstRowIsHeader = value } }))
            Toggle(spec.switchRowsAndColumns ? "Use row 1 as labels" : "Use column A as labels",
                   isOn: Binding(get: { spec.firstColumnIsLabels }, set: { value in change(id) { $0.firstColumnIsLabels = value } }))
            HStack {
                Toggle("Aggregate", isOn: Binding(get: { spec.aggregation != nil },
                                                  set: { value in change(id) { $0.aggregation = value ? .sum : nil } }))
                if let aggregation = spec.aggregation {
                    Picker("", selection: Binding(get: { aggregation }, set: { value in change(id) { $0.aggregation = value } })) {
                        ForEach(ChartSpec.Aggregation.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 13))
    }

    private func labelHeading(_ spec: ChartSpec, _ table: ChartTable) -> String {
        guard spec.firstRowIsHeader, let first = spec.ranges.first,
              let target = controller.workbook.resolve(first, onSheet: controller.activeSheetIndex) else { return "Labels" }
        let value = controller.workbook.sheets[target.sheet].value(at: target.range.start)
        let text = CellDisplay.text(for: value, pattern: nil).text
        return text.isEmpty ? "Labels" : text
    }

    private func seriesColor(_ spec: ChartSpec, _ index: Int) -> RGBColor {
        spec.style(ofSeries: index).color ?? ChartBuilder.palette[index % ChartBuilder.palette.count]
    }

    // MARK: Customize

    @ViewBuilder private func customize(_ id: UUID, _ spec: ChartSpec, _ table: ChartTable) -> some View {
        DisclosureGroup("Chart style") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Background color").font(.system(size: 13))
                    Spacer()
                    ColorWell(help: "Background color", color: Binding(get: { spec.backgroundColor }, set: { value in change(id) { $0.backgroundColor = value } }))
                }
                HStack {
                    Text("Font").font(.system(size: 13))
                    Spacer()
                    Picker("", selection: Binding(get: { spec.fontFamily ?? "" }, set: { value in change(id) { $0.fontFamily = value.isEmpty ? nil : value } })) {
                        Text("Default").tag("")
                        ForEach(["Arial", "Roboto", "Helvetica Neue", "Georgia", "Times New Roman", "Courier New", "Verdana", "Trebuchet MS"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.vertical, 8)
        }
        DisclosureGroup("Chart & axis titles") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $titleTarget) {
                    Text("Chart title").tag(0)
                    Text("Chart subtitle").tag(1)
                    if !spec.kind.isPie {
                        Text("Horizontal axis title").tag(2)
                        Text("Vertical axis title").tag(3)
                    }
                }
                .labelsHidden()
                CommitField(placeholder: "Title text", value: titleText(spec)) { text in
                    let target = titleTarget
                    change(id) { spec in
                        switch target {
                        case 0: spec.title = text
                        case 1: spec.subtitle = text
                        case 2: spec.horizontalAxisTitle = text
                        default: spec.verticalAxisTitle = text
                        }
                    }
                }
                .id(titleTarget)
            }
            .padding(.vertical, 8)
        }
        if !table.series.isEmpty {
            DisclosureGroup("Series") { seriesControls(id, spec, table).padding(.vertical, 8) }
        }
        DisclosureGroup("Legend") {
            Picker("Position", selection: Binding(get: { spec.legend }, set: { value in change(id) { $0.legend = value } })) {
                ForEach(ChartSpec.LegendPosition.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .padding(.vertical, 8)
        }
        if spec.kind.isPie {
            DisclosureGroup("Pie chart") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Donut hole", selection: Binding(get: { spec.kind == .donut ? spec.pieHole : 0 },
                                                            set: { value in change(id) { $0.kind = value > 0 ? .donut : .pie; if value > 0 { $0.pieHole = value } } })) {
                        Text("None").tag(0.0)
                        Text("25%").tag(0.25)
                        Text("50%").tag(0.5)
                        Text("75%").tag(0.75)
                    }
                    Picker("Slice label", selection: Binding(get: { spec.pieSliceLabel }, set: { value in change(id) { $0.pieSliceLabel = value } })) {
                        ForEach(ChartSpec.PieLabel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                .padding(.vertical, 8)
            }
        } else {
            DisclosureGroup("Vertical axis") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Min").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                            CommitField(placeholder: "Auto", value: spec.verticalMinimum.map(Self.number) ?? "") { text in
                                change(id) { $0.verticalMinimum = Double(text.trimmingCharacters(in: .whitespaces)) }
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Max").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                            CommitField(placeholder: "Auto", value: spec.verticalMaximum.map(Self.number) ?? "") { text in
                                change(id) { $0.verticalMaximum = Double(text.trimmingCharacters(in: .whitespaces)) }
                            }
                        }
                    }
                    Toggle("Log scale", isOn: Binding(get: { spec.logScale }, set: { value in change(id) { $0.logScale = value } }))
                        .toggleStyle(.checkbox)
                }
                .padding(.vertical, 8)
            }
            DisclosureGroup("Gridlines") {
                Toggle("Major gridlines", isOn: Binding(get: { spec.showsGridlines }, set: { value in change(id) { $0.showsGridlines = value } }))
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 8)
            }
        }
    }

    private func titleText(_ spec: ChartSpec) -> String {
        switch titleTarget {
        case 0: spec.title
        case 1: spec.subtitle
        case 2: spec.horizontalAxisTitle
        default: spec.verticalAxisTitle
        }
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    private func seriesControls(_ id: UUID, _ spec: ChartSpec, _ table: ChartTable) -> some View {
        let count = spec.kind.isPie ? 1 : table.series.count
        let index = min(seriesIndex, max(0, count - 1))
        let style = spec.style(ofSeries: index)
        func update(_ edit: @escaping (inout ChartSeriesStyle) -> Void) {
            change(id) { spec in
                while spec.series.count <= index { spec.series.append(ChartSeriesStyle()) }
                edit(&spec.series[index])
            }
        }
        return VStack(alignment: .leading, spacing: 10) {
            if count > 1 {
                Picker("", selection: $seriesIndex) {
                    ForEach(0..<count, id: \.self) { Text(table.series[$0].name).tag($0) }
                }
                .labelsHidden()
            }
            if !spec.kind.isPie {
                HStack {
                    Text("Color").font(.system(size: 13))
                    Spacer()
                    ColorWell(help: "Series color", color: Binding(get: { style.color ?? seriesColor(spec, index) },
                                                                   set: { value in update { $0.color = value } }), allowsNone: false)
                }
            }
            if spec.kind == .combo {
                Picker("Type", selection: Binding(get: { style.type ?? (index == 0 ? .column : .line) }, set: { value in update { $0.type = value } })) {
                    ForEach(ChartSeriesStyle.SeriesType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            if spec.kind.hasLines {
                Picker("Line thickness", selection: Binding(get: { style.lineWidth ?? 2 }, set: { value in update { $0.lineWidth = value } })) {
                    ForEach([1.0, 2, 3, 4, 6, 8], id: \.self) { Text("\(Int($0))px").tag($0) }
                }
                Picker("Point size", selection: Binding(get: { style.pointSize ?? (spec.kind == .scatter ? 7 : 0) },
                                                        set: { value in update { $0.pointSize = value } })) {
                    Text("None").tag(0.0)
                    ForEach([3.0, 5, 7, 10, 14], id: \.self) { Text("\(Int($0))px").tag($0) }
                }
            }
            Toggle("Data labels", isOn: Binding(get: { style.showsDataLabels ?? spec.showsDataLabels },
                                                set: { value in update { $0.showsDataLabels = value } }))
            if !spec.kind.isPie {
                Toggle("Right axis", isOn: Binding(get: { style.usesRightAxis }, set: { value in update { $0.usesRightAxis = value } }))
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 13))
    }
}
