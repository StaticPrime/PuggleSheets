import AppKit
import SwiftUI

/// Edit ▸ Find and replace (⇧⌘H).
struct FindReplaceView: View {
    @Bindable var state: FindReplaceState
    let controller: FindReplaceController
    let close: () -> Void
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    label("Find")
                    PanelField(placeholder: "", text: $state.options.query)
                        .focused($findFocused)
                }
                GridRow {
                    label("Replace with")
                    PanelField(placeholder: "", text: $state.options.replacement)
                }
                GridRow {
                    label("Search")
                    Picker("", selection: $state.options.scope) {
                        Text("All sheets").tag(FindReplaceOptions.Scope.allSheets)
                        Text("This sheet").tag(FindReplaceOptions.Scope.thisSheet)
                        Text("Specific range").tag(FindReplaceOptions.Scope.range)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .padding(.leading, -8)
                }
                if state.options.scope == .range {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        PanelField(placeholder: "Sheet1!A1:D10", text: $state.options.rangeText)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Match case", isOn: $state.options.matchCase)
                        Toggle("Match entire cell contents", isOn: $state.options.entireCell)
                        Toggle("Search using regular expressions", isOn: $state.options.regex)
                        Toggle("Also search within formulas", isOn: $state.options.withinFormulas)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                }
            }
            Text(state.message ?? " ")
                .font(.system(size: 12))
                .foregroundStyle(state.messageIsProblem ? Color.red : Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                PanelButton(title: "Find", primary: false, isEnabled: !state.options.query.isEmpty) { controller.find() }
                    .keyboardShortcut(.defaultAction)
                PanelButton(title: "Replace", primary: false, isEnabled: !state.options.query.isEmpty) { controller.replace() }
                PanelButton(title: "Replace all", primary: false, isEnabled: !state.options.query.isEmpty) { controller.replaceAll() }
                Spacer()
                PanelButton(title: "Done") { close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: state.options) { _, _ in state.message = nil }
        .onAppear { findFocused = true }
        .onChange(of: state.focusRequest) { _, _ in findFocused = true }
    }

    private func label(_ title: String) -> some View {
        Text(title).font(.system(size: 13)).foregroundStyle(Theme.primaryText).gridColumnAlignment(.leading)
    }
}

/// Calls back when a panel closes, so its owner can let go of it.
final class PanelCloseObserver: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}
