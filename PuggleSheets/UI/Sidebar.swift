import AppKit
import PuggleSheetsKit
import SwiftUI

/// The panels that open on the right of the grid.
enum SidebarKind: Equatable {
    case conditionalFormatting, dataValidation, alternatingColors, namedRanges, chartEditor, pivotEditor, comments, protections, columnStats
    case table, slicer

    var title: String {
        switch self {
        case .conditionalFormatting: "Conditional format rules"
        case .dataValidation: "Data validation rules"
        case .alternatingColors: "Alternating colors"
        case .namedRanges: "Named ranges"
        case .chartEditor: "Chart editor"
        case .pivotEditor: "Pivot table editor"
        case .comments: "Comments"
        case .protections: "Protected sheets & ranges"
        case .columnStats: "Column stats"
        case .table: "Table settings"
        case .slicer: "Slicer"
        }
    }
}

/// What the side panels ask their window to do.
protocol SidebarActions: AnyObject {
    var controller: SpreadsheetController { get }
    func closeSidebar()
    func select(_ range: CellRange)
    func editPivotFilter(pivotID: UUID, index: Int)
    func openComment(sheetIndex: Int, address: CellAddress)
}

struct SidebarView: View {
    let state: EditorState
    let actions: SidebarActions

    var body: some View {
        if let kind = state.sidebar {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(kind.title).font(.system(size: 16)).foregroundStyle(Theme.primaryText)
                    Spacer()
                    ToolbarIconButton(symbol: "xmark", help: "Close") { actions.closeSidebar() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                ScrollView {
                    Group {
                        switch kind {
                        case .conditionalFormatting: ConditionalFormatPanel(state: state, actions: actions)
                        case .dataValidation: DataValidationPanel(state: state, actions: actions)
                        case .alternatingColors: AlternatingColorsPanel(state: state, actions: actions)
                        case .namedRanges: NamedRangesPanel(state: state, actions: actions)
                        case .chartEditor: ChartEditorPanel(state: state, actions: actions)
                        case .pivotEditor:
                            PivotEditorPanel(state: state, actions: actions) { [weak actions] pivotID, index in
                                actions?.editPivotFilter(pivotID: pivotID, index: index)
                            }
                        case .comments:
                            CommentsPanel(state: state, actions: actions) { [weak actions] sheetIndex, address in
                                actions?.openComment(sheetIndex: sheetIndex, address: address)
                            }
                        case .protections: ProtectionPanel(state: state, actions: actions)
                        case .columnStats: ColumnStatsPanel(state: state, actions: actions)
                        case .table: TablePanel(state: state, actions: actions)
                        case .slicer: SlicerPanel(state: state, actions: actions)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.white)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.divider).frame(width: 1) }
        }
    }
}

// MARK: Shared pieces

extension CellCondition.Kind {
    /// The name the panels show.
    var title: String {
        switch self {
        case .isEmpty: "Is empty"
        case .isNotEmpty: "Is not empty"
        case .textContains: "Text contains"
        case .textDoesNotContain: "Text does not contain"
        case .textStartsWith: "Text starts with"
        case .textEndsWith: "Text ends with"
        case .textIsExactly: "Text is exactly"
        case .textIsValidEmail: "Text is valid email"
        case .textIsValidURL: "Text is valid URL"
        case .dateIs: "Date is"
        case .dateIsBefore: "Date is before"
        case .dateIsAfter: "Date is after"
        case .dateIsOnOrBefore: "Date is on or before"
        case .dateIsOnOrAfter: "Date is on or after"
        case .dateIsBetween: "Date is between"
        case .dateIsNotBetween: "Date is not between"
        case .dateIsValid: "Is valid date"
        case .greaterThan: "Greater than"
        case .greaterThanOrEqual: "Greater than or equal to"
        case .lessThan: "Less than"
        case .lessThanOrEqual: "Less than or equal to"
        case .isEqual: "Is equal to"
        case .isNotEqual: "Is not equal to"
        case .isBetween: "Is between"
        case .isNotBetween: "Is not between"
        case .customFormula: "Custom formula is"
        }
    }

    var isDate: Bool { rawValue.hasPrefix("date") }

    /// Groups of kinds, separated by dividers in pickers.
    static let groups: [[CellCondition.Kind]] = [
        [.isEmpty, .isNotEmpty],
        [.textContains, .textDoesNotContain, .textStartsWith, .textEndsWith, .textIsExactly, .textIsValidEmail, .textIsValidURL],
        [.dateIs, .dateIsBefore, .dateIsAfter, .dateIsOnOrBefore, .dateIsOnOrAfter, .dateIsBetween, .dateIsNotBetween, .dateIsValid],
        [.greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual, .isEqual, .isNotEqual, .isBetween, .isNotBetween],
        [.customFormula],
    ]
}

extension CellCondition {
    /// "Greater than 10", "Is between 1 and 5", "Custom formula is =A1>B1".
    var summary: String {
        switch kind.valueCount {
        case 0: kind.title
        case 2: "\(kind.title) \(values.first ?? "") and \(values.dropFirst().first ?? "")"
        default: "\(kind.title) \(values.first ?? "")"
        }
    }
}

/// Parses "A1:C5" or "A1:C5, E1:E5" (sheet names allowed when they name the active sheet).
func parseRanges(_ text: String, sheetName: String) -> [CellRange]? {
    let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    var ranges: [CellRange] = []
    for part in parts {
        var reference = part
        if let bang = part.lastIndex(of: "!") {
            let name = part[..<bang].trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard name.caseInsensitiveCompare(sheetName) == .orderedSame else { return nil }
            reference = String(part[part.index(after: bang)...])
        }
        guard let range = CellRange(a1: reference.replacingOccurrences(of: "$", with: "")) else { return nil }
        ranges.append(range)
    }
    return ranges
}

func rangesText(_ ranges: [CellRange]) -> String {
    ranges.map(\.a1).joined(separator: ", ")
}

/// A labelled section of a panel.
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
            content()
        }
        .padding(.bottom, 14)
    }
}

/// A text field styled for the panels.
struct PanelField: View {
    let placeholder: String
    @Binding var text: String
    var isValid = true

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isValid ? Theme.divider : Color.red, lineWidth: 1))
    }
}

/// A color swatch that opens the toolbar's palette.
struct ColorWell: View {
    let help: String
    @Binding var color: RGBColor?
    var allowsNone = true
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: (color ?? .white).nsColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                .overlay {
                    if color == nil {
                        Path { path in
                            path.move(to: CGPoint(x: 3, y: 19))
                            path.addLine(to: CGPoint(x: 19, y: 3))
                        }
                        .stroke(Color.red, lineWidth: 1)
                    }
                }
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ColorPaletteView(selectedHex: color?.hex) { picked in
                showing = false
                if let picked { color = RGBColor(picked) } else if allowsNone { color = nil }
            } custom: {
                showing = false
            }
        }
    }
}

/// A primary button in a panel, such as "Done".
struct PanelButton: View {
    let title: String
    var primary = true
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(primary ? Color.white : Theme.accent)
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(Capsule().fill(primary ? Theme.accent : Color.clear))
                .overlay(Capsule().strokeBorder(primary ? Color.clear : Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}
