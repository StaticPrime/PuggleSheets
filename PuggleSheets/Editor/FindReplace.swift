import AppKit
import Observation
import PuggleSheetsKit

/// Edit ▸ Find and replace: what to look for, what to put instead, and where.
struct FindReplaceOptions: Equatable {
    enum Scope: Hashable { case allSheets, thisSheet, range }
    var query = ""
    var replacement = ""
    var scope = Scope.allSheets
    var rangeText = ""
    var matchCase = false
    var entireCell = false
    var regex = false
    var withinFormulas = false
}

/// A cell where the text was found.
struct FindReplaceMatch: Hashable, Comparable {
    var sheetIndex: Int
    var address: CellAddress

    static func < (a: Self, b: Self) -> Bool {
        (a.sheetIndex, a.address.row, a.address.column) < (b.sheetIndex, b.address.row, b.address.column)
    }
}

enum FindReplaceProblem: Error {
    case invalidExpression
    case invalidRange
}

/// Matches cells against the options. Cells are searched by what they show, or by their formula when
/// "Also search within formulas" is on, in rows from top to bottom and sheet by sheet.
struct FindReplaceSearch {
    let options: FindReplaceOptions
    private let expression: NSRegularExpression

    init(_ options: FindReplaceOptions) throws {
        self.options = options
        var pattern = options.regex ? options.query : NSRegularExpression.escapedPattern(for: options.query)
        if options.entireCell { pattern = "\\A(?:\(pattern))\\z" }
        let flags: NSRegularExpression.Options = options.matchCase ? [] : [.caseInsensitive]
        guard let expression = try? NSRegularExpression(pattern: pattern, options: flags) else {
            throw FindReplaceProblem.invalidExpression
        }
        self.expression = expression
    }

    func matches(_ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// `text` with every match replaced, and how many there were. Regular expressions can use $1 for groups.
    func replacing(in text: String) -> (text: String, count: Int) {
        let range = NSRange(text.startIndex..., in: text)
        let count = expression.numberOfMatches(in: text, range: range)
        guard count > 0 else { return (text, 0) }
        let template = options.regex ? options.replacement : NSRegularExpression.escapedTemplate(for: options.replacement)
        return (expression.stringByReplacingMatches(in: text, range: range, withTemplate: template), count)
    }

    /// The text a cell is searched by.
    func searchedText(of cell: Cell?, value: CellValue) -> String? {
        if options.withinFormulas, let formula = cell?.formula { return formula }
        guard value != .empty else { return nil }
        return CellDisplay.text(for: value, pattern: cell?.format.numberFormat).text
    }

    /// Every matching cell in the scope, in order.
    func matches(in workbook: Workbook, activeSheet: Int) throws -> [FindReplaceMatch] {
        let targets: [(sheet: Int, range: CellRange?)]
        switch options.scope {
        case .allSheets: targets = workbook.sheets.indices.map { ($0, nil) }
        case .thisSheet: targets = [(activeSheet, nil)]
        case .range:
            guard let target = Self.parseRange(options.rangeText, in: workbook, activeSheet: activeSheet) else {
                throw FindReplaceProblem.invalidRange
            }
            targets = [target]
        }
        var found: [FindReplaceMatch] = []
        for target in targets {
            let sheet = workbook.sheets[target.sheet]
            let cells: [(CellAddress, Cell)] = target.range.map { Array(sheet.cells(in: $0)) } ?? sheet.cells.map { ($0.key, $0.value) }
            for (address, cell) in cells where cell.hasContent {
                if let text = searchedText(of: cell, value: cell.value), matches(text) {
                    found.append(FindReplaceMatch(sheetIndex: target.sheet, address: address))
                }
            }
            for (address, value) in sheet.spilledValues where target.range?.contains(address) ?? true {
                guard sheet.cells[address]?.hasContent != true, let text = searchedText(of: nil, value: value), matches(text) else { continue }
                found.append(FindReplaceMatch(sheetIndex: target.sheet, address: address))
            }
        }
        return found.sorted()
    }

    /// "B2:D10" on the active sheet, or "Sheet2!B2:D10".
    static func parseRange(_ text: String, in workbook: Workbook, activeSheet: Int) -> (sheet: Int, range: CellRange?)? {
        var reference = text.trimmingCharacters(in: .whitespaces)
        var sheet = activeSheet
        if let bang = reference.lastIndex(of: "!") {
            let name = reference[..<bang].trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            guard let index = workbook.sheetIndex(named: name) else { return nil }
            sheet = index
            reference = String(reference[reference.index(after: bang)...])
        }
        guard let range = CellRange(a1: reference.replacingOccurrences(of: "$", with: "")) else { return nil }
        return (sheet, range)
    }
}

extension SpreadsheetController {
    /// The cell at `match` with its matches replaced, and how many there were; nil when it can't change
    /// (a formula's result when formulas aren't searched, or a value spilled from an array).
    func replacement(for match: FindReplaceMatch, search: FindReplaceSearch) -> (cell: Cell, count: Int)? {
        guard workbook.sheets.indices.contains(match.sheetIndex),
              let cell = workbook.sheets[match.sheetIndex].cells[match.address], cell.hasContent else { return nil }
        if let formula = cell.formula {
            guard search.options.withinFormulas else { return nil }
            let result = search.replacing(in: formula)
            guard result.count > 0 else { return nil }
            return (self.cell(forInput: result.text, replacing: cell), result.count)
        }
        let shown = CellDisplay.text(for: cell.value, pattern: cell.format.numberFormat).text
        let result = search.replacing(in: shown)
        guard result.count > 0 else { return nil }
        if case .text = cell.value {
            var replaced = cell
            replaced.value = .text(result.text)
            return (replaced, result.count)
        }
        return (self.cell(forInput: result.text, replacing: cell), result.count)
    }
}

@Observable
final class FindReplaceState {
    var options = FindReplaceOptions()
    var message: String?
    var messageIsProblem = false
    /// Incremented to put the keyboard focus in the find field.
    var focusRequest = 0
}

/// Runs the Find and replace dialog's buttons.
final class FindReplaceController {
    let state = FindReplaceState()
    private unowned let controller: SpreadsheetController
    private unowned let grid: GridView

    init(controller: SpreadsheetController, grid: GridView) {
        self.controller = controller
        self.grid = grid
    }

    private var query: String { state.options.query }

    private func search() -> (FindReplaceSearch, [FindReplaceMatch])? {
        do {
            let search = try FindReplaceSearch(state.options)
            return (search, try search.matches(in: controller.workbook, activeSheet: controller.activeSheetIndex))
        } catch FindReplaceProblem.invalidRange {
            report("Enter a range like A1:D10 or Sheet1!A1:D10.", problem: true)
        } catch {
            report("“\(query)” isn’t a valid regular expression.", problem: true)
        }
        return nil
    }

    private func report(_ message: String?, problem: Bool = false) {
        state.message = message
        state.messageIsProblem = problem
    }

    private var here: FindReplaceMatch {
        FindReplaceMatch(sheetIndex: controller.activeSheetIndex, address: controller.selection.active)
    }

    /// Selects the next match after the active cell, wrapping around to the first.
    func find() {
        guard !query.isEmpty, let (_, matches) = search() else { return }
        guard !matches.isEmpty else { return report("No results found for “\(query)”.") }
        let current = here
        if let next = matches.first(where: { $0 > current }) {
            report(nil)
            select(next)
        } else if matches == [current] {
            report("No other results found.")
        } else {
            report("No more results, looping around.")
            select(matches[0])
        }
    }

    /// Replaces the selected match, then finds the next one.
    func replace() {
        guard !query.isEmpty, let (search, matches) = search() else { return }
        let current = here
        if matches.contains(current), let result = controller.replacement(for: current, search: search) {
            controller.perform([.cells(sheet: controller.workbook.sheets[current.sheetIndex].id, [current.address: result.cell])],
                               actionName: "Replace")
        }
        find()
    }

    /// Replaces every match in the scope as one undoable step.
    func replaceAll() {
        guard !query.isEmpty, let (search, matches) = search() else { return }
        guard !matches.isEmpty else { return report("No results found for “\(query)”.") }
        var changes: [UUID: [CellAddress: Cell]] = [:]
        var count = 0
        for match in matches {
            guard let result = controller.replacement(for: match, search: search) else { continue }
            changes[controller.workbook.sheets[match.sheetIndex].id, default: [:]][match.address] = result.cell
            count += result.count
        }
        guard count > 0 else {
            return report("“\(query)” only appears in formula results. Turn on “Also search within formulas” to change formulas.")
        }
        let order = controller.workbook.sheets.map(\.id)
        let steps = changes.sorted { (order.firstIndex(of: $0.key) ?? 0) < (order.firstIndex(of: $1.key) ?? 0) }
            .map { WorkbookChange.cells(sheet: $0.key, $0.value) }
        controller.perform(steps, actionName: "Replace All")
        report("Replaced \(count) \(count == 1 ? "instance" : "instances") of \(query) with \(state.options.replacement).")
    }

    private func select(_ match: FindReplaceMatch) {
        let id = controller.workbook.sheets[match.sheetIndex].id
        controller.showSheet(id: id)
        controller.selection = GridSelection(match.address)
        grid.scrollToVisible(match.address)
    }
}
