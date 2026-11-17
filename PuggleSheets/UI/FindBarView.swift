import SwiftUI

/// The find box at the top right of the grid.
struct FindBarView: View {
    @Bindable var state: FindState
    let controller: FindController
    @FocusState private var focused: Bool

    var body: some View {
        if state.isVisible {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                TextField("Find in sheet", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 180)
                    .focused($focused)
                    .onSubmit { controller.next() }
                    .onChange(of: state.query) { _, _ in controller.search() }
                    .onExitCommand { controller.hide() }
                Text(state.countText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
                ToolbarIconButton(symbol: "chevron.up", help: "Previous (⇧⌘G)", isEnabled: state.matchCount > 0) { controller.previous() }
                ToolbarIconButton(symbol: "chevron.down", help: "Next (⌘G)", isEnabled: state.matchCount > 0) { controller.next() }
                ToolbarIconButton(symbol: "xmark", help: "Close") { controller.hide() }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white).shadow(color: .black.opacity(0.22), radius: 4, y: 2))
            .padding(8)
            .onAppear { focused = true }
            .onChange(of: state.focusRequest) { _, _ in focused = true }
        }
    }
}
