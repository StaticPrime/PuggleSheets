import AppKit
import PuggleSheetsKit
import SwiftUI

/// Format ▸ Alternating colors: banded rows for the selected range.
struct AlternatingColorsPanel: View {
    let state: EditorState
    let actions: SidebarActions
    @State private var draft: Banding?
    @State private var rangeText = ""
    @State private var hasHeader = true
    @State private var hasFooter = false

    private var controller: SpreadsheetController { actions.controller }

    /// The default styles: header, first and second colors.
    static let presets: [(RGBColor, RGBColor, RGBColor)] = [
        ("BDBDBD", "FFFFFF", "F3F3F3"), ("5B95F9", "FFFFFF", "E8F0FE"), ("63D297", "FFFFFF", "E7F9EF"), ("F7CB4D", "FFFFFF", "FEF8E3"),
        ("F46524", "FFFFFF", "FFE6DD"), ("5CB3CC", "FFFFFF", "E8F4F7"), ("8989EB", "FFFFFF", "E8E7FC"), ("E67C73", "FFFFFF", "FCE8E6"),
    ].map { (RGBColor(hex: $0.0)!, RGBColor(hex: $0.1)!, RGBColor(hex: $0.2)!) }

    var body: some View {
        let _ = state.ruleRevision
        let ranges = parseRanges(rangeText, sheetName: controller.sheet.name)
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Apply to range") {
                PanelField(placeholder: "A1:D20", text: $rangeText, isValid: ranges?.count == 1)
            }
            PanelSection(title: "Styles") {
                Toggle("Header", isOn: $hasHeader).font(.system(size: 13))
                Toggle("Footer", isOn: $hasFooter).font(.system(size: 13))
                Text("Default styles").font(.system(size: 12)).foregroundStyle(Theme.secondaryText).padding(.top, 6)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(56)), count: 4), spacing: 8) {
                    ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                        Button {
                            setColors(header: preset.0, first: preset.1, second: preset.2)
                        } label: {
                            VStack(spacing: 0) {
                                Rectangle().fill(Color(nsColor: preset.0.nsColor)).frame(height: 10)
                                Rectangle().fill(Color(nsColor: preset.1.nsColor)).frame(height: 10)
                                Rectangle().fill(Color(nsColor: preset.2.nsColor)).frame(height: 10)
                                Rectangle().fill(Color(nsColor: preset.1.nsColor)).frame(height: 10)
                            }
                            .frame(width: 50)
                            .overlay(Rectangle().stroke(Theme.divider))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let current = draft {
                PanelSection(title: "Custom style") {
                    HStack(spacing: 14) {
                        if hasHeader {
                            colorChoice("Header", Binding(get: { current.headerColor }, set: { draft?.headerColor = $0 }))
                        }
                        colorChoice("Color 1", Binding(get: { current.firstColor }, set: { if let color = $0 { draft?.firstColor = color } }))
                        colorChoice("Color 2", Binding(get: { current.secondColor }, set: { if let color = $0 { draft?.secondColor = color } }))
                        if hasFooter {
                            colorChoice("Footer", Binding(get: { current.footerColor }, set: { draft?.footerColor = $0 }))
                        }
                    }
                }
            }
            HStack {
                if let existing = controller.selectedBanding {
                    PanelButton(title: "Remove alternating colors", primary: false) {
                        controller.removeBanding(id: existing.id)
                        actions.closeSidebar()
                    }
                }
                Spacer()
                PanelButton(title: "Done", isEnabled: ranges?.count == 1) {
                    if let range = ranges?.first, var banding = draft {
                        banding.range = range
                        banding.headerColor = hasHeader ? (banding.headerColor ?? Self.presets[0].0) : nil
                        banding.footerColor = hasFooter ? (banding.footerColor ?? banding.headerColor ?? Self.presets[0].0) : nil
                        controller.setBanding(banding)
                    }
                    actions.closeSidebar()
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        if let existing = controller.selectedBanding {
            draft = existing
            rangeText = existing.range.a1
            hasHeader = existing.headerColor != nil
            hasFooter = existing.footerColor != nil
        } else {
            let preset = Self.presets[0]
            let range = controller.selection.current.isSingleCell ? controller.dataRegion(around: controller.selection.active) : controller.selection.current
            draft = Banding(range: range, headerColor: preset.0, firstColor: preset.1, secondColor: preset.2)
            rangeText = range.a1
        }
    }

    private func setColors(header: RGBColor, first: RGBColor, second: RGBColor) {
        draft?.headerColor = header
        draft?.firstColor = first
        draft?.secondColor = second
        if hasFooter { draft?.footerColor = header }
    }

    private func colorChoice(_ title: String, _ color: Binding<RGBColor?>) -> some View {
        VStack(spacing: 4) {
            ColorWell(help: title, color: color, allowsNone: false)
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        }
    }
}

/// Data ▸ Named ranges: the workbook's names, and an editor for one.
struct NamedRangesPanel: View {
    let state: EditorState
    let actions: SidebarActions
    @State private var editing: (original: String?, name: String, reference: String)?
    @State private var problem: String?

    private var controller: SpreadsheetController { actions.controller }

    var body: some View {
        let _ = state.ruleRevision
        VStack(alignment: .leading, spacing: 10) {
            if let current = editing {
                editor(current)
            } else {
                let names = controller.workbook.namedRanges.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if names.isEmpty {
                    Text("No named ranges yet. Names let formulas say =SUM(Sales) instead of =SUM(Sheet1!B2:B20).")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                }
                ForEach(names, id: \.name) { named in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(named.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primaryText)
                            Text(named.reference).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        ToolbarIconButton(symbol: "pencil", help: "Edit") { editing = (named.name, named.name, named.reference) }
                        ToolbarIconButton(symbol: "trash", help: "Delete") { controller.removeNamedRange(named.name) }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.divider))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let target = controller.resolve(named) {
                            controller.showSheet(id: controller.workbook.sheets[target.sheet].id)
                            actions.select(target.range)
                        }
                    }
                }
                Button {
                    problem = nil
                    editing = (nil, "", controller.absoluteReference(controller.selection.current))
                } label: {
                    Label("Add a range", systemImage: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func editor(_ current: (original: String?, name: String, reference: String)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Name") {
                PanelField(placeholder: "Sales", text: Binding(get: { editing?.name ?? "" }, set: { editing?.name = $0 }))
            }
            PanelSection(title: "Range") {
                PanelField(placeholder: "Sheet1!A1:B10", text: Binding(get: { editing?.reference ?? "" }, set: { editing?.reference = $0 }))
            }
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Color.red).padding(.bottom, 10)
            }
            HStack {
                Spacer()
                PanelButton(title: "Cancel", primary: false) { editing = nil }
                PanelButton(title: "Done") {
                    guard let edit = editing else { return }
                    if let issue = controller.problem(namingRange: edit.name, replacing: edit.original) {
                        problem = issue
                        return
                    }
                    let reference = edit.reference.trimmingCharacters(in: .whitespaces)
                    guard controller.resolve(NamedRange(name: edit.name, reference: reference)) != nil else {
                        problem = "Enter a range like Sheet1!A1:B10."
                        return
                    }
                    controller.setNamedRange(name: edit.name, reference: reference, replacing: edit.original)
                    editing = nil
                }
            }
        }
    }
}
