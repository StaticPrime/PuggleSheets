import Foundation

/// Protected ranges in Excel's terms. A whole-sheet protection that refuses edits becomes
/// `<sheetProtection>` with its exceptions as unlocked cells; range protections and warnings have no
/// counterpart. Every protection is also kept exactly in PuggleSheets' custom XML part. Passwords are
/// never written, and protected files open whatever their password hashes.
enum XLSXProtection {
    /// The most cells unlocked for a sheet's exceptions; larger exceptions live in the custom part only.
    static let maximumUnlockedCells = 100_000

    /// Whether the sheet is protected in Excel, and the cells left editable.
    static func native(_ sheet: Sheet) -> (protects: Bool, unlocked: Set<CellAddress>) {
        guard let protection = sheet.protections.first(where: { protection in
            guard !protection.warningOnly, case .sheet = protection.scope else { return false }
            return true
        }), case .sheet(let except) = protection.scope else { return (false, []) }
        var unlocked = Set<CellAddress>()
        var budget = maximumUnlockedCells
        let limits = CellRange(rows: 0...(XLSXLimits.rows - 1), columns: 0...(XLSXLimits.columns - 1))
        for range in except {
            guard let range = range.intersection(limits), range.cellCount <= budget else { continue }
            budget -= range.cellCount
            for address in range.addresses where !sheet.protections.contains(where: { !$0.warningOnly && $0.covers(address) }) {
                unlocked.insert(address)
            }
        }
        return (true, unlocked)
    }

    /// `<sheetProtection>` without a password.
    static let sheetProtection = "<sheetProtection sheet=\"1\" objects=\"1\" scenarios=\"1\"/>"

    /// A protected Excel sheet as PuggleSheets' protection: the whole sheet, except its unlocked cells
    /// and the ranges anyone may edit.
    static func protection(unlocked: [CellAddress], editableRanges: [CellRange]) -> ProtectedRange {
        ProtectedRange(scope: .sheet(except: rectangles(unlocked) + editableRanges), warningOnly: false)
    }

    /// Cells as few rectangles: runs along each row, stacked where consecutive rows repeat them.
    static func rectangles(_ addresses: [CellAddress]) -> [CellRange] {
        var byRow: [Int: [Int]] = [:]
        for address in addresses { byRow[address.row, default: []].append(address.column) }
        var open: [ClosedRange<Int>: (top: Int, bottom: Int)] = [:]
        var result: [CellRange] = []
        for row in byRow.keys.sorted() {
            var runs: [ClosedRange<Int>] = []
            for column in Set(byRow[row]!).sorted() {
                if let last = runs.last, last.upperBound + 1 == column {
                    runs[runs.count - 1] = last.lowerBound...column
                } else {
                    runs.append(column...column)
                }
            }
            var next: [ClosedRange<Int>: (top: Int, bottom: Int)] = [:]
            for run in runs {
                if let block = open[run], block.bottom == row - 1 {
                    next[run] = (block.top, row)
                    open[run] = nil
                } else {
                    next[run] = (row, row)
                }
            }
            for (columns, block) in open { result.append(CellRange(rows: block.top...block.bottom, columns: columns)) }
            open = next
        }
        for (columns, block) in open { result.append(CellRange(rows: block.top...block.bottom, columns: columns)) }
        return result.sorted { $0.start < $1.start }
    }
}
