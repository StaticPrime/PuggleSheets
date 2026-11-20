import AppKit
import PuggleSheetsKit
import SwiftUI

enum ToolbarMenu {
    case zoom, numberFormats, font, merge, horizontalAlign, verticalAlign, wrap, rotation, functions, download
}

/// What the header and toolbar ask their window to do.
protocol ChromeActions: AnyObject {
    var controller: SpreadsheetController { get }
    func popUp(_ menu: ToolbarMenu, from view: NSView?)
    func rename(to title: String)
    func showVersionHistory()
    func showComments()
    func showCustomColorPanel(fill: Bool)
    func dismissBanner()
    func togglePaintFormat()
    func applyBorders(_ kind: BorderKind, line: BorderLine)
    func focusGrid()
    func showCollaborate()
}

/// Header, toolbar and info banner above the formula bar.
struct ChromeView: View {
    let state: EditorState
    let actions: ChromeActions

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(state: state, actions: actions)
            FormattingToolbar(state: state, actions: actions)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            if let banner = state.banner {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Color.orange)
                    Text(banner).font(.system(size: 12.5)).foregroundStyle(Theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Dismiss") { actions.dismissBanner() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.bannerFill)
            }
        }
        .background(Color(nsColor: Theme.canvas))
        // The header shares the title bar band with the window buttons.
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Lines a header row up with the window's close, minimise and zoom buttons.
enum TitlebarMetrics {
    static let rowHeight: CGFloat = 32

    /// Leading inset after the window buttons and the vertical center of those buttons, from the window top.
    @MainActor
    static func measure(_ window: NSWindow) -> (leading: CGFloat, centerY: CGFloat) {
        if window.styleMask.contains(.fullScreen) { return (18, 22) }
        guard let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton), close.superview != nil else { return (78, 18) }
        let closeFrame = close.convert(close.bounds, to: nil)
        let zoomFrame = zoom.convert(zoom.bounds, to: nil)
        return (zoomFrame.maxX + 16, window.frame.height - closeFrame.midY)
    }
}

/// Spreadsheet header: icon, editable title, format badge and save status, with version history and
/// Download on the right. Menus live in the macOS menu bar, as in every Mac app.
struct HeaderView: View {
    let state: EditorState
    let actions: ChromeActions
    @State private var titleText = ""
    @FocusState private var titleFocused: Bool

    private var titleWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 16)
        let text = titleText.isEmpty ? "Untitled spreadsheet" : titleText
        return min(520, max(80, (text as NSString).size(withAttributes: [.font: font]).width + 14))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .help("PuggleSheets")
            TextField("Untitled spreadsheet", text: $titleText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(Theme.primaryText)
                .frame(width: titleWidth, height: 24)
                .padding(.horizontal, 3)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(titleFocused ? Theme.accent : .clear, lineWidth: 1.5))
                .hoverBackground()
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .disabled(!state.collaboration.isOwner && state.collaboration.isShared)
                .help(state.collaboration.isShared && !state.collaboration.isOwner ? "Only its owner can rename it" : "Rename")
            if let badge = state.formatBadge {
                Text(badge)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.secondaryText.opacity(0.5), lineWidth: 1))
                    .help("This file is stored in \(badge.dropFirst()) format")
            }
            Image(systemName: statusSymbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .help(statusText)
            Spacer(minLength: 12)
            // As the window narrows, the status words go first, then the buttons' words.
            ViewThatFits(in: .horizontal) {
                trailingControls(showsStatus: true, compact: false)
                trailingControls(showsStatus: false, compact: false)
                trailingControls(showsStatus: false, compact: true)
            }
        }
        .frame(height: TitlebarMetrics.rowHeight)
        .padding(.leading, state.titlebarLeading)
        .padding(.trailing, 14)
        .padding(.top, max(0, state.titlebarCenterY - TitlebarMetrics.rowHeight / 2))
        .padding(.bottom, 8)
        .background(WindowDragArea())
        .onAppear { titleText = state.title }
        .onChange(of: state.title) { _, newValue in if !titleFocused { titleText = newValue } }
        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
        .onChange(of: state.renameRequest) { _, _ in titleFocused = true }
        .onExitCommand { titleText = state.title; titleFocused = false; actions.focusGrid() }
    }

    private func trailingControls(showsStatus: Bool, compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if showsStatus {
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            CollaboratorAvatars(state: state.collaboration)
            ToolbarIconButton(symbol: "text.bubble", help: "Show all comments") { actions.showComments() }
            ToolbarIconButton(symbol: "clock.arrow.circlepath", help: "Open version history") { actions.showVersionHistory() }
            if state.showsCollaborateButton { collaborateButton(compact: compact) }
            ToolbarDropdown(help: "Download a copy", showsChevron: false, open: { actions.popUp(.download, from: $0) }) {
                Group {
                    if compact {
                        Image(systemName: "arrow.down.to.line")
                    } else {
                        Label("Download", systemImage: "arrow.down.to.line")
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 0.0, green: 0.12, blue: 0.27))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(Color(red: 0.76, green: 0.87, blue: 1.0)))
                .fixedSize()
            }
        }
    }

    private var collaborateSymbol: String { state.collaboration.isShared ? "person.2.fill" : "person.badge.plus" }

    /// The Collaborate button, for spreadsheets of this person's: those shared with them don't have it.
    private func collaborateButton(compact: Bool) -> some View {
        Button { actions.showCollaborate() } label: {
            Group {
                if compact {
                    Image(systemName: collaborateSymbol)
                } else {
                    Label("Collaborate", systemImage: collaborateSymbol)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, compact ? 10 : 12)
            .frame(height: 30)
            .background(Capsule().fill(Theme.accent))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(state.collaboration.isShared ? "See and change who this spreadsheet is shared with" : "Share this spreadsheet with people to work on it together")
        .accessibilityLabel("Collaborate")
    }

    /// While shared, how its iCloud copy is keeping up; otherwise how its file is.
    private var statusText: String { state.collaboration.isShared ? state.collaboration.statusText : state.saveStatus.text }
    private var statusSymbol: String { state.collaboration.isShared ? state.collaboration.statusSymbol : state.saveStatus.symbol }

    private func commitTitle() {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == state.title {
            titleText = state.title
        } else {
            actions.rename(to: trimmed)
        }
        if titleFocused {
            titleFocused = false
            actions.focusGrid()
        }
    }
}

/// The rounded formatting bar. Groups that do not fit move into an overflow popover.
struct FormattingToolbar: View {
    let state: EditorState
    let actions: ChromeActions
    @State private var showingOverflow = false

    private var controller: SpreadsheetController { actions.controller }
    private var summary: FormatSummary { state.summary }
    private let groupCount = 8

    var body: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                row(overflowFrom: 99)
                row(overflowFrom: 7)
                row(overflowFrom: 6)
                row(overflowFrom: 5)
                row(overflowFrom: 4)
            }
            Spacer(minLength: 0)
            // A shared spreadsheet that can only be commented on here, or not changed at all just now, says so.
            if let badge = state.accessBadge {
                Label(badge.title, systemImage: badge.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 8)
                    .fixedSize()
                    .help(state.access == .offline ? "Changes can’t be saved until iCloud can be reached" : "You can comment, but not change the cells")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(Capsule().fill(Theme.toolbarFill))
    }

    private func row(overflowFrom: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<min(overflowFrom, groupCount), id: \.self) { index in
                if index > 0 { ToolbarDivider() }
                group(index).disabled(index >= 2 && !state.isEditable)
            }
            if overflowFrom < groupCount {
                ToolbarDivider()
                ToolbarIconButton(symbol: "ellipsis", help: "More", isOn: showingOverflow) { showingOverflow = true }
                    .popover(isPresented: $showingOverflow, arrowEdge: .bottom) {
                        HStack(spacing: 1) {
                            ForEach(overflowFrom..<groupCount, id: \.self) { index in
                                if index > overflowFrom { ToolbarDivider() }
                                group(index).disabled(index >= 2 && !state.isEditable)
                            }
                        }
                        .padding(8)
                    }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func group(_ index: Int) -> some View {
        switch index {
        case 0: historyGroup
        case 1: zoomControl
        case 2: numberGroup
        case 3: fontControl
        case 4: FontSizeControl(size: CGFloat(summary.fontSize), set: { controller.setFontSize(Double($0)) },
                                step: { controller.stepFontSize(by: Double($0)) })
        case 5: textStyleGroup
        case 6: cellGroup
        default: alignmentGroup
        }
    }

    private var historyGroup: some View {
        HStack(spacing: 1) {
            ToolbarIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", isEnabled: state.canUndo) { controller.undoManager?.undo() }
            ToolbarIconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", isEnabled: state.canRedo) { controller.undoManager?.redo() }
            ToolbarIconButton(symbol: "paintbrush.pointed", help: "Paint format", isOn: state.isPaintFormatActive, isEnabled: state.isEditable) {
                actions.togglePaintFormat()
            }
        }
    }

    private var zoomControl: some View {
        ToolbarDropdown(help: "Zoom", open: { actions.popUp(.zoom, from: $0) }) {
            Text(state.zoomLabel).font(.system(size: 13)).foregroundStyle(Theme.primaryText).frame(width: 38)
        }
    }

    private var numberGroup: some View {
        HStack(spacing: 1) {
            TextToolbarButton(text: "$", help: "Format as currency") { controller.setNumberFormat(NumberFormatPresets.currency.pattern) }
            TextToolbarButton(text: "%", help: "Format as percent") { controller.setNumberFormat(NumberFormatPresets.percent.pattern) }
            DecimalToolbarButton(increase: false) { controller.adjustDecimals(by: -1) }
            DecimalToolbarButton(increase: true) { controller.adjustDecimals(by: 1) }
            ToolbarDropdown(help: "More formats", open: { actions.popUp(.numberFormats, from: $0) }) {
                Text("123").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var fontControl: some View {
        ToolbarDropdown(help: "Font", open: { actions.popUp(.font, from: $0) }) {
            Text(summary.format.fontFamily == nil ? "Default (\(CellFormat.defaultFontFamily))" : summary.fontFamily)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
        }
    }

    private var textStyleGroup: some View {
        HStack(spacing: 1) {
            ToolbarIconButton(symbol: "bold", help: "Bold (⌘B)", isOn: summary.format.bold) { controller.toggleBold() }
            ToolbarIconButton(symbol: "italic", help: "Italic (⌘I)", isOn: summary.format.italic) { controller.toggleItalic() }
            ToolbarIconButton(symbol: "strikethrough", help: "Strikethrough (⇧⌘X)", isOn: summary.format.strikethrough) {
                controller.toggleStrikethrough()
            }
            ColorToolbarButton(isFill: false, currentHex: summary.format.textColor?.hex) { color in
                controller.setTextColor(color.flatMap { RGBColor($0) })
            } custom: { actions.showCustomColorPanel(fill: false) }
        }
    }

    private var cellGroup: some View {
        HStack(spacing: 1) {
            ColorToolbarButton(isFill: true, currentHex: summary.format.fillColor?.hex) { color in
                controller.setFillColor(color.flatMap { RGBColor($0) })
            } custom: { actions.showCustomColorPanel(fill: true) }
            BordersToolbarButton { kind, line in actions.applyBorders(kind, line: line) }
            SplitToolbarButton(symbol: "arrow.right.and.line.vertical.and.arrow.left", help: "Merge cells", isOn: summary.isMerged,
                               action: { controller.merge(summary.isMerged ? .unmerge : .all) },
                               openPresets: { actions.popUp(.merge, from: $0) })
        }
    }

    private var horizontalSymbol: String {
        switch summary.format.horizontalAlignment {
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        default: "text.alignleft"
        }
    }

    private var verticalSymbol: String {
        switch summary.format.resolvedVerticalAlignment {
        case .top: "align.vertical.top"
        case .middle: "align.vertical.center"
        case .bottom: "align.vertical.bottom"
        }
    }

    private var wrapSymbol: String {
        switch summary.format.resolvedWrap {
        case .overflow: "arrow.forward.to.line"
        case .wrap: "arrow.turn.down.left"
        case .clip: "arrow.right.to.line.compact"
        }
    }

    private var alignmentGroup: some View {
        HStack(spacing: 1) {
            ToolbarDropdown(help: "Horizontal align", open: { actions.popUp(.horizontalAlign, from: $0) }) {
                Image(systemName: horizontalSymbol).font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
            }
            ToolbarDropdown(help: "Vertical align", open: { actions.popUp(.verticalAlign, from: $0) }) {
                Image(systemName: verticalSymbol).font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
            }
            ToolbarDropdown(help: "Text wrapping", open: { actions.popUp(.wrap, from: $0) }) {
                Image(systemName: wrapSymbol).font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
            }
            ToolbarDropdown(help: "Text rotation", open: { actions.popUp(.rotation, from: $0) }) {
                Image(systemName: "textformat.alt").font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
                    .rotationEffect(.degrees(summary.format.textRotation == nil ? 0 : -45))
            }
            ToolbarDropdown(help: "Functions", open: { actions.popUp(.functions, from: $0) }) {
                Image(systemName: "sum").font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

/// A toolbar button labelled with text ("$", "%").
struct TextToolbarButton: View {
    let text: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 26, height: 28)
                .hoverBackground()
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// ".0←" and ".00→": fewer or more decimal places.
struct DecimalToolbarButton: View {
    let increase: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if !increase { Image(systemName: "arrow.left").font(.system(size: 7, weight: .bold)) }
                Text(increase ? ".00" : ".0").font(.system(size: 12, weight: .semibold))
                if increase { Image(systemName: "arrow.right").font(.system(size: 7, weight: .bold)) }
            }
            .foregroundStyle(Theme.secondaryText)
            .frame(width: 30, height: 28)
            .hoverBackground()
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(increase ? "Increase decimal places" : "Decrease decimal places")
        .accessibilityLabel(increase ? "Increase decimal places" : "Decrease decimal places")
    }
}

/// The borders button: a palette of border types plus line color and style.
struct BordersToolbarButton: View {
    let apply: (BorderKind, BorderLine) -> Void
    @State private var showing = false
    @State private var color = RGBColor.black
    @State private var style = BorderStyle.thin

    private let symbols: [BorderKind: String] = [
        .all: "squareshape.split.2x2", .inner: "plus", .horizontal: "rectangle.split.1x2", .vertical: "rectangle.split.2x1",
        .outer: "square", .left: "rectangle.leftthird.inset.filled", .top: "rectangle.topthird.inset.filled",
        .right: "rectangle.rightthird.inset.filled", .bottom: "rectangle.bottomthird.inset.filled", .clear: "square.dashed",
    ]

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "squareshape.split.2x2")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28, height: 28)
                .hoverBackground(isOn: showing)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Borders")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    ForEach([[BorderKind.all, .inner, .horizontal, .vertical, .outer], [.left, .top, .right, .bottom, .clear]], id: \.self) { row in
                        HStack(spacing: 4) {
                            ForEach(row, id: \.self) { kind in
                                Button {
                                    showing = false
                                    apply(kind, BorderLine(style: style, color: color))
                                } label: {
                                    Image(systemName: symbols[kind] ?? "square")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.secondaryText)
                                        .frame(width: 28, height: 28)
                                        .hoverBackground()
                                }
                                .buttonStyle(.plain)
                                .help(kind.title)
                            }
                        }
                    }
                }
                Divider().frame(height: 60)
                VStack(alignment: .leading, spacing: 6) {
                    Menu {
                        ForEach(ColorPalette.grayRow + ColorPalette.brightRow) { swatch in
                            Button(swatch.name) { color = RGBColor(hex: swatch.hex) ?? .black }
                        }
                    } label: {
                        Label("Border color", systemImage: "pencil.and.outline")
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundStyle(Color(nsColor: color.nsColor))
                    .fixedSize()
                    Menu {
                        ForEach(BorderStyle.allCases, id: \.self) { item in
                            Button(item.rawValue.capitalized) { style = item }
                        }
                    } label: {
                        Label("Border style: \(style.rawValue)", systemImage: "lineweight")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(10)
        }
    }
}
