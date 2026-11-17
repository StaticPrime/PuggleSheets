import AppKit
import PuggleSheetsKit
import SwiftUI

/// Format ▸ Conditional formatting: the sheet's rules, and an editor for one.
struct ConditionalFormatPanel: View {
    let state: EditorState
    let actions: SidebarActions
    @State private var draft: Draft?

    private var controller: SpreadsheetController { actions.controller }

    /// A rule being added or edited.
    struct Draft {
        var id = UUID()
        var isNew = true
        var range = ""
        var usesColorScale = false
        var kind = CellCondition.Kind.isNotEmpty
        var values = ["", ""]
        var format = ConditionalFormat(fillColor: RGBColor(hex: "B7E1CD"))
        var scale = ColorScale(minimum: .init(kind: .minimum, color: .white), maximum: .init(kind: .maximum, color: RGBColor(hex: "57BB8A")!))

        init(range: String) {
            self.range = range
        }

        init(_ rule: ConditionalFormatRule) {
            id = rule.id
            isNew = false
            range = rangesText(rule.ranges)
            switch rule.style {
            case .condition(let condition, let format):
                kind = condition.kind
                values = condition.values + Array(repeating: "", count: max(0, 2 - condition.values.count))
                self.format = format
            case .colorScale(let scale):
                usesColorScale = true
                self.scale = scale
            }
        }

        func rule(ranges: [CellRange]) -> ConditionalFormatRule {
            let style: ConditionalFormatRule.Style = usesColorScale
                ? .colorScale(scale)
                : .condition(CellCondition(kind, Array(values.prefix(kind.valueCount))), format)
            return ConditionalFormatRule(id: id, ranges: ranges, style: style)
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
            let rules = controller.sheet.conditionalFormats
            if rules.isEmpty {
                Text("No rules yet. Rules change how cells look when their values meet a condition.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                HStack(spacing: 10) {
                    preview(rule.style)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(description(rule.style)).font(.system(size: 13)).foregroundStyle(Theme.primaryText).lineLimit(2)
                        Text(rangesText(rule.ranges)).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    VStack(spacing: 0) {
                        ToolbarIconButton(symbol: "chevron.up", help: "Move up", isEnabled: index > 0) { controller.moveConditionalFormat(id: rule.id, by: -1) }
                        ToolbarIconButton(symbol: "chevron.down", help: "Move down", isEnabled: index < rules.count - 1) {
                            controller.moveConditionalFormat(id: rule.id, by: 1)
                        }
                    }
                    ToolbarIconButton(symbol: "trash", help: "Delete rule") { controller.removeConditionalFormat(id: rule.id) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider))
                .contentShape(Rectangle())
                .onTapGesture { draft = Draft(rule) }
            }
            Button {
                draft = Draft(range: state.selectionReference)
            } label: {
                Label("Add another rule", systemImage: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private func preview(_ style: ConditionalFormatRule.Style) -> some View {
        Group {
            switch style {
            case .condition(_, let format):
                Text("123")
                    .font(.system(size: 13, weight: format.bold == true ? .bold : .regular))
                    .italic(format.italic == true)
                    .underline(format.underline == true)
                    .strikethrough(format.strikethrough == true)
                    .foregroundStyle(Color(nsColor: (format.textColor ?? .black).nsColor))
                    .frame(width: 44, height: 28)
                    .background(Color(nsColor: (format.fillColor ?? .white).nsColor))
            case .colorScale(let scale):
                LinearGradient(colors: [scale.minimum.color, scale.midpoint?.color, scale.maximum.color].compactMap { $0 }.map { Color(nsColor: $0.nsColor) },
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 44, height: 28)
            }
        }
        .overlay(Rectangle().stroke(Theme.divider))
    }

    private func description(_ style: ConditionalFormatRule.Style) -> String {
        switch style {
        case .condition(let condition, _): condition.summary
        case .colorScale: "Color scale"
        }
    }

    // MARK: Editor

    private func editor(_ current: Draft) -> some View {
        let binding = Binding<Draft>(get: { draft ?? current }, set: { draft = $0 })
        let ranges = parseRanges(binding.wrappedValue.range, sheetName: controller.sheet.name)
        return VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: binding.usesColorScale) {
                Text("Single color").tag(false)
                Text("Color scale").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.bottom, 14)
            PanelSection(title: "Apply to range") {
                PanelField(placeholder: "A1:B10", text: binding.range, isValid: ranges != nil)
            }
            if binding.wrappedValue.usesColorScale {
                scaleEditor(binding)
            } else {
                PanelSection(title: "Format rules") {
                    ConditionPicker(title: "Format cells if…", kind: binding.kind)
                    ConditionValueFields(kind: binding.wrappedValue.kind, values: binding.values)
                }
                PanelSection(title: "Formatting style") {
                    FormatStyleEditor(format: binding.format)
                }
            }
            HStack {
                if !binding.wrappedValue.isNew {
                    PanelButton(title: "Remove rule", primary: false) {
                        controller.removeConditionalFormat(id: binding.wrappedValue.id)
                        draft = nil
                    }
                }
                Spacer()
                PanelButton(title: "Cancel", primary: false) { draft = nil }
                PanelButton(title: "Done", isEnabled: ranges != nil) {
                    guard let ranges else { return }
                    controller.setConditionalFormat(binding.wrappedValue.rule(ranges: ranges))
                    draft = nil
                }
            }
        }
    }

    private func scaleEditor(_ binding: Binding<Draft>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Preview") {
                let scale = binding.wrappedValue.scale
                LinearGradient(colors: [scale.minimum.color, scale.midpoint?.color, scale.maximum.color].compactMap { $0 }.map { Color(nsColor: $0.nsColor) },
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 28)
                    .overlay(Rectangle().stroke(Theme.divider))
                HStack(spacing: 6) {
                    ForEach(Array(Self.scalePresets.enumerated()), id: \.offset) { _, preset in
                        Button {
                            binding.wrappedValue.scale.minimum.color = preset[0]
                            binding.wrappedValue.scale.maximum.color = preset[preset.count - 1]
                            if preset.count == 3 {
                                binding.wrappedValue.scale.midpoint = .init(kind: .percentile, value: "50", color: preset[1])
                            } else {
                                binding.wrappedValue.scale.midpoint = nil
                            }
                        } label: {
                            LinearGradient(colors: preset.map { Color(nsColor: $0.nsColor) }, startPoint: .leading, endPoint: .trailing)
                                .frame(width: 34, height: 18)
                                .overlay(Rectangle().stroke(Theme.divider))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ScalePointEditor(title: "Minpoint", point: binding.scale.minimum, extreme: .minimum)
            ScalePointEditor(title: "Midpoint", optionalPoint: binding.scale.midpoint)
            ScalePointEditor(title: "Maxpoint", point: binding.scale.maximum, extreme: .maximum)
        }
    }

    static let scalePresets: [[RGBColor]] = [
        [.white, RGBColor(hex: "57BB8A")!],
        [RGBColor(hex: "57BB8A")!, .white],
        [.white, RGBColor(hex: "E67C73")!],
        [RGBColor(hex: "E67C73")!, .white],
        [RGBColor(hex: "E67C73")!, RGBColor(hex: "FFD666")!, RGBColor(hex: "57BB8A")!],
        [RGBColor(hex: "57BB8A")!, RGBColor(hex: "FFD666")!, RGBColor(hex: "E67C73")!],
    ]
}

/// One point of a color scale: what it's anchored to and its color.
struct ScalePointEditor: View {
    let title: String
    @Binding var point: ColorScale.Point?
    let extreme: ColorScale.PointKind?

    init(title: String, point: Binding<ColorScale.Point>, extreme: ColorScale.PointKind) {
        self.title = title
        self._point = Binding(get: { point.wrappedValue }, set: { if let value = $0 { point.wrappedValue = value } })
        self.extreme = extreme
    }

    init(title: String, optionalPoint: Binding<ColorScale.Point?>) {
        self.title = title
        self._point = optionalPoint
        self.extreme = nil
    }

    private var kinds: [ColorScale.PointKind?] {
        var kinds: [ColorScale.PointKind?] = extreme == nil ? [nil] : [extreme]
        kinds += [.number, .percent, .percentile]
        return kinds
    }

    private func label(_ kind: ColorScale.PointKind?) -> String {
        switch kind {
        case nil: "None"
        case .minimum: "Min value"
        case .maximum: "Max value"
        case .number: "Number"
        case .percent: "Percent"
        case .percentile: "Percentile"
        }
    }

    var body: some View {
        PanelSection(title: title) {
            HStack(spacing: 8) {
                Picker("", selection: Binding<ColorScale.PointKind?>(
                    get: { point?.kind },
                    set: { kind in
                        if let kind {
                            let value = kind == .minimum || kind == .maximum ? nil : (point?.value ?? "50")
                            point = ColorScale.Point(kind: kind, value: value, color: point?.color ?? RGBColor(hex: "FFD666")!)
                        } else {
                            point = nil
                        }
                    })) {
                    ForEach(kinds, id: \.self) { Text(label($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                if let current = point, current.kind != .minimum, current.kind != .maximum {
                    PanelField(placeholder: "Value", text: Binding(get: { current.value ?? "" }, set: { point?.value = $0 }))
                        .frame(width: 70)
                }
                Spacer()
                if point != nil {
                    ColorWell(help: "\(title) color", color: Binding(get: { point?.color }, set: { if let color = $0 { point?.color = color } }),
                              allowsNone: false)
                }
            }
        }
    }
}

/// The condition list, in groups.
struct ConditionPicker: View {
    let title: String
    @Binding var kind: CellCondition.Kind
    var kinds: [[CellCondition.Kind]] = CellCondition.Kind.groups

    var body: some View {
        Menu {
            ForEach(Array(kinds.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.self) { item in
                    Button(item.title) { kind = item }
                }
            }
        } label: {
            HStack {
                Text(kind.title).font(.system(size: 13)).foregroundStyle(Theme.primaryText)
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
        .help(title)
    }
}

/// The value fields a condition takes (none, one, or two for "between").
struct ConditionValueFields: View {
    let kind: CellCondition.Kind
    @Binding var values: [String]

    private var placeholder: String {
        if kind == .customFormula { return "=A1>10" }
        if kind.isDate { return "today, past week or a date" }
        return "Value or formula"
    }

    var body: some View {
        if kind.valueCount >= 1 {
            PanelField(placeholder: placeholder, text: value(0))
        }
        if kind.valueCount == 2 {
            PanelField(placeholder: placeholder, text: value(1))
        }
    }

    private func value(_ index: Int) -> Binding<String> {
        Binding(get: { index < values.count ? values[index] : "" }, set: { newValue in
            while values.count <= index { values.append("") }
            values[index] = newValue
        })
    }
}

/// Bold, italic, underline, strikethrough, text color and fill color for a conditional rule.
struct FormatStyleEditor: View {
    @Binding var format: ConditionalFormat

    var body: some View {
        HStack(spacing: 2) {
            toggle("bold", help: "Bold", value: $format.bold)
            toggle("italic", help: "Italic", value: $format.italic)
            toggle("underline", help: "Underline", value: $format.underline)
            toggle("strikethrough", help: "Strikethrough", value: $format.strikethrough)
            Divider().frame(height: 20).padding(.horizontal, 6)
            Text("A").font(.system(size: 14, weight: .medium, design: .serif)).foregroundStyle(Theme.secondaryText)
            ColorWell(help: "Text color", color: $format.textColor)
            Spacer().frame(width: 10)
            PaintBucketShape().fill(style: FillStyle(eoFill: true)).foregroundStyle(Theme.secondaryText).frame(width: 15, height: 15)
            ColorWell(help: "Fill color", color: $format.fillColor)
        }
    }

    private func toggle(_ symbol: String, help: String, value: Binding<Bool?>) -> some View {
        ToolbarIconButton(symbol: symbol, help: help, isOn: value.wrappedValue == true) {
            value.wrappedValue = value.wrappedValue == true ? nil : true
        }
    }
}
