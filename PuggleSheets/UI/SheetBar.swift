import AppKit
import PuggleSheetsKit
import SwiftUI

/// What the sheet bar asks its window to do.
protocol SheetBarActions: AnyObject {
    func addSheet()
    func showSheet(_ id: UUID)
    /// Renames a sheet; returns a problem to show instead when the name can't be used.
    func renameSheet(_ id: UUID, to name: String) -> String?
    func sheetMenu(for id: UUID) -> NSMenu
    func deleteSheet(_ id: UUID)
    func duplicateSheet(_ id: UUID)
    func moveSheet(_ id: UUID, by offset: Int)
    func setTabColor(_ id: UUID, _ color: RGBColor?)
    func showAllSheetsMenu(from view: NSView?)
    func showStatisticsMenu(from view: NSView?)
    func focusGrid()
}

/// The bar under the grid: add sheet, all sheets, the sheet tabs, and the selection's sum.
struct SheetBar: View {
    let state: EditorState
    let actions: SheetBarActions

    var body: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(symbol: "plus", help: "Add Sheet") { actions.addSheet() }
            ToolbarDropdown(help: "All Sheets", showsChevron: false, open: { actions.showAllSheetsMenu(from: $0) }) {
                Image(systemName: "line.3.horizontal").font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(state.sheets) { tab in
                        SheetTabView(tab: tab, isActive: tab.id == state.activeSheetID, renameRequest: state.renameSheetRequest, actions: actions)
                    }
                }
                .padding(.horizontal, 4)
            }
            Spacer(minLength: 8)
            if let text = state.statisticText {
                ToolbarDropdown(help: "Selection statistics", open: { actions.showStatisticsMenu(from: $0) }) {
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.trailing, 10)
            }
        }
        .padding(.leading, 8)
        .frame(height: 40)
        .background(Color(nsColor: Theme.canvas))
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

struct SheetTabView: View {
    let tab: SheetTab
    let isActive: Bool
    let renameRequest: Int
    let actions: SheetBarActions
    @State private var isRenaming = false
    @State private var text = ""
    @State private var hovering = false
    @State private var anchor = AnchorHolder()
    @FocusState private var focused: Bool

    private static let activeFill = Color(red: 0xE1 / 255, green: 0xE9 / 255, blue: 0xF7 / 255)

    var body: some View {
        HStack(spacing: 4) {
            if isRenaming {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: max(60, (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 12))
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { isRenaming = false; actions.focusGrid() }
            } else {
                if tab.isProtected {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.secondaryText)
                }
                Text(tab.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Theme.accent : Theme.secondaryText)
                    .lineLimit(1)
            }
            if isActive && !isRenaming {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Self.activeFill : (hovering ? Theme.hoverFill : .clear))
        )
        .overlay(alignment: .bottom) {
            if let color = tab.color {
                Rectangle().fill(Color(nsColor: color.nsColor)).frame(height: 3).padding(.horizontal, 6)
            }
        }
        .background(AnchorView(holder: anchor))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { startRenaming() }
        .onTapGesture {
            if isActive {
                // Clicking the active tab opens its menu.
                guard let view = anchor.view else { return }
                actions.sheetMenu(for: tab.id).popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 3), in: view)
            } else {
                actions.showSheet(tab.id)
            }
        }
        .contextMenu {
            Button("Delete") { actions.deleteSheet(tab.id) }
            Button("Duplicate") { actions.duplicateSheet(tab.id) }
            Button("Rename") { startRenaming() }
            Menu("Change color") {
                Button("Reset") { actions.setTabColor(tab.id, nil) }
                ForEach(ColorPalette.brightRow + ColorPalette.shadeRows[3]) { swatch in
                    Button(swatch.name.capitalized) { actions.setTabColor(tab.id, RGBColor(hex: swatch.hex)) }
                }
            }
            Divider()
            Button("Move right") { actions.moveSheet(tab.id, by: 1) }
            Button("Move left") { actions.moveSheet(tab.id, by: -1) }
        }
        .onChange(of: renameRequest) { _, _ in if isActive { startRenaming() } }
        .onChange(of: focused) { _, isFocused in if !isFocused && isRenaming { commit() } }
        .help(tab.name)
    }

    private func startRenaming() {
        if !isActive { actions.showSheet(tab.id) }
        text = tab.name
        isRenaming = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard isRenaming else { return }
        isRenaming = false
        if text != tab.name, let problem = actions.renameSheet(tab.id, to: text) {
            let alert = NSAlert()
            alert.messageText = "Can’t rename the sheet"
            alert.informativeText = problem
            alert.runModal()
        }
        actions.focusGrid()
    }
}
