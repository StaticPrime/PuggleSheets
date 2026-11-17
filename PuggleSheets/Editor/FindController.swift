import AppKit
import Observation
import PuggleSheetsKit

@Observable
final class FindState {
    var isVisible = false
    var query = ""
    var matchCount = 0
    /// Zero-based position of the selected match, or nil when none is selected.
    var currentIndex: Int?
    /// Incremented to put the keyboard focus in the find field.
    var focusRequest = 0

    var countText: String {
        guard !query.isEmpty else { return "" }
        guard matchCount > 0 else { return "0 of 0" }
        return "\((currentIndex ?? -1) + 1) of \(matchCount)"
    }
}

/// Edit ▸ Find: matches the shown text of the active sheet's cells, ignoring case.
final class FindController {
    let state = FindState()
    private unowned let controller: SpreadsheetController
    private unowned let grid: GridView
    private(set) var matches: [CellAddress] = []
    private var refreshScheduled = false

    init(controller: SpreadsheetController, grid: GridView) {
        self.controller = controller
        self.grid = grid
    }

    func show() {
        state.isVisible = true
        state.focusRequest += 1
        search(selectFirst: false)
    }

    func hide() {
        state.isVisible = false
        matches = []
        grid.findMatches = []
        grid.window?.makeFirstResponder(grid)
    }

    /// Finds every match in row-major order and selects the first one at or after the active cell.
    func search(selectFirst: Bool = true) {
        let query = state.query
        guard state.isVisible, !query.isEmpty else {
            matches = []
            state.matchCount = 0
            state.currentIndex = nil
            grid.findMatches = []
            return
        }
        let sheet = controller.sheet
        func shows(_ value: CellValue, _ pattern: String?) -> Bool {
            CellDisplay.text(for: value, pattern: pattern).text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        var found = sheet.cells.compactMap { address, cell -> CellAddress? in
            cell.hasContent && shows(cell.value, cell.format.numberFormat) ? address : nil
        }
        for (address, value) in sheet.spilledValues where !(sheet.cells[address]?.hasContent ?? false) {
            if shows(value, sheet.cells[address]?.format.numberFormat) { found.append(address) }
        }
        matches = found.sorted()
        state.matchCount = matches.count
        grid.findMatches = Set(matches)
        guard !matches.isEmpty else {
            state.currentIndex = nil
            return
        }
        let active = controller.selection.active
        let index = matches.firstIndex { $0 >= active } ?? 0
        if selectFirst { select(index) } else { state.currentIndex = matches[index] == active ? index : nil }
    }

    /// Searches again after edits, without moving the selection.
    func scheduleRefresh() {
        guard state.isVisible, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.search(selectFirst: false)
        }
    }

    func next() { step(by: 1) }
    func previous() { step(by: -1) }

    private func step(by offset: Int) {
        if matches.isEmpty { search(selectFirst: false) }
        guard !matches.isEmpty else { return NSSound.beep() }
        let active = controller.selection.active
        let index: Int
        if let current = state.currentIndex, matches.indices.contains(current), matches[current] == active {
            index = (current + offset + matches.count) % matches.count
        } else if offset > 0 {
            index = matches.firstIndex { $0 > active } ?? 0
        } else {
            index = matches.lastIndex { $0 < active } ?? matches.count - 1
        }
        select(index)
    }

    private func select(_ index: Int) {
        state.currentIndex = index
        controller.selection = GridSelection(matches[index])
        grid.scrollToVisible(matches[index])
    }
}
