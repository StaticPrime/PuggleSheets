import AppKit
import Observation
import PuggleSheetsKit

enum SaveStatus: Equatable {
    case draft, edited, saved

    var text: String {
        switch self {
        case .draft: "Not saved to a file yet"
        case .edited: "Saving…"
        case .saved: "Saved to this Mac"
        }
    }

    var symbol: String {
        switch self {
        case .draft: "doc.badge.clock"
        case .edited: "arrow.triangle.2.circlepath"
        case .saved: "checkmark.circle"
        }
    }
}

/// The active cell's formatting, as the toolbar shows it.
struct FormatSummary: Equatable {
    var format = CellFormat()
    var isMerged = false

    var fontFamily: String { format.resolvedFontFamily }
    var fontSize: Double { format.resolvedFontSize }
    var numberFormatKind: NumberFormatKind { NumberFormatPresets.kind(of: format.numberFormat) }
}

/// The selection statistic shown at the bottom right ("Sum: 42").
enum SelectionStatistic: Int, CaseIterable {
    case sum, average, minimum, maximum, count, countNumbers

    var title: String {
        switch self {
        case .sum: "Sum"
        case .average: "Average"
        case .minimum: "Min"
        case .maximum: "Max"
        case .count: "Count"
        case .countNumbers: "Count Numbers"
        }
    }

    static let key = "PSSelectionStatistic"

    static var saved: SelectionStatistic {
        SelectionStatistic(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .sum
    }
}

/// Numbers about the selected cells.
struct SelectionStatistics: Equatable {
    var count = 0
    var numbers: [Double] = []

    func value(_ statistic: SelectionStatistic) -> Double? {
        switch statistic {
        case .sum: numbers.isEmpty ? nil : numbers.reduce(0, +)
        case .average: numbers.isEmpty ? nil : numbers.reduce(0, +) / Double(numbers.count)
        case .minimum: numbers.min()
        case .maximum: numbers.max()
        case .count: Double(count)
        case .countNumbers: Double(numbers.count)
        }
    }
}

struct SheetTab: Equatable, Identifiable {
    var id: UUID
    var name: String
    var color: RGBColor?
    /// The whole sheet is protected (its tab shows a lock).
    var isProtected = false
}

/// Everything the SwiftUI header, toolbar and sheet bar display for one window.
@Observable
final class EditorState {
    var title = "Untitled spreadsheet"
    var formatBadge: String?
    var saveStatus: SaveStatus = .draft
    /// Where the header row sits next to the window buttons (see `TitlebarMetrics`).
    var titlebarLeading: CGFloat = 78
    var titlebarCenterY: CGFloat = 18
    var banner: String?
    /// Incremented to ask the header to focus the title field (File ▸ Rename).
    var renameRequest = 0

    var zoom: CGFloat = 1
    var canUndo = false
    var canRedo = false
    var isPaintFormatActive = false
    var summary = FormatSummary()

    var sheets: [SheetTab] = []
    var activeSheetID: UUID?
    /// Incremented to ask the sheet bar to rename the active tab.
    var renameSheetRequest = 0
    var statistics = SelectionStatistics()
    var statistic = SelectionStatistic.saved
    /// The selection's number format, used for its sum, average, minimum and maximum.
    var statisticsFormat: String?
    /// The panel open on the right, if any.
    var sidebar: SidebarKind?
    /// Incremented after every change so the side panels re-read the sheet's rules.
    var ruleRevision = 0
    /// The selection as "A1:C5", for prefilling "Apply to range" fields.
    var selectionReference = "A1"
    /// Insert ▸ Dropdown opens the data validation panel straight on a new dropdown rule.
    var pendingValidationKind: DataValidationPanel.CriterionKind?
    /// The chart the chart editor shows.
    var editingObjectID: UUID?
    /// The pivot table the pivot table editor shows.
    var editingPivotID: UUID?
    /// The table the table settings show.
    var editingTableID: UUID?

    var zoomLabel: String { "\(Int((zoom * 100).rounded()))%" }

    /// A statistic in the selection's number format, or grouped with up to two decimals.
    static func statisticText(_ value: Double, format: String?) -> String {
        switch NumberFormatPresets.kind(of: format) {
        case .number, .percent, .currency, .accounting, .scientific, .date, .time, .dateTime, .duration:
            return CellDisplay.text(for: .number(value), pattern: format).text
        default:
            let rounded = value == value.rounded() || abs(value) >= 1e15
            return CellDisplay.text(for: .number(value), pattern: rounded ? "#,##0" : "#,##0.00").text
        }
    }

    /// "Sum: 1,234.5", or nil when the selection has nothing to summarize.
    var statisticText: String? {
        guard statistics.count > 1 || (statistic == .count && statistics.count > 0) else { return nil }
        guard let value = statistics.value(statistic) else { return nil }
        if statistic == .count || statistic == .countNumbers { return "\(statistic.title): \(Int(value).formatted())" }
        return "\(statistic.title): \(Self.statisticText(value, format: statisticsFormat))"
    }
}
