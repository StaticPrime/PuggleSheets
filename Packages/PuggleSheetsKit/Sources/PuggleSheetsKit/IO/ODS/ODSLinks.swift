import Foundation

/// Cell links as OpenDocument writes them: `text:a xlink:href` around the cell's text.
///
/// Web and email addresses are written as they are. Places in the spreadsheet use LibreOffice's
/// marks, which its "jump to mark" reads: `#Sheet1.A1:B2` (a sheet's range, the sheet name quoted when
/// it isn't a plain word: `#'Q1 2026'.A1`), `#Name` for a named range, and `#Sheet name` for a whole
/// sheet.
enum ODSLinks {
    /// The `xlink:href` for one of our links; nil when there's nothing to link to (a deleted sheet).
    static func href(for link: String, sheetNames: [UUID: String]) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let target = LinkTarget(link: trimmed) else { return trimmed }
        switch target {
        case .url(let url):
            return url
        case .sheet(let id, let range):
            guard let name = sheetNames[id] else { return nil }
            guard let range else { return "#" + name }
            return "#" + ODSFormula.quotedSheet(name) + "." + range.a1
        case .namedRange(let name):
            return "#" + name
        }
    }

    /// Our link for an `xlink:href` read from a file. Marks become "#gid=…&range=…" or
    /// "#namedrange=…"; nil for a mark that names nothing in the spreadsheet.
    static func link(forHref href: String, sheets: [(name: String, id: UUID)], namedRanges: [NamedRange], currentSheet: Int) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("#") else { return trimmed }
        var mark = String(trimmed.dropFirst())
        // LibreOffice decodes escaped characters (%20) in marks.
        if mark.contains("%"), let decoded = mark.removingPercentEncoding { mark = decoded }
        guard !mark.isEmpty else { return nil }
        func sheetIndex(_ name: String?) -> Int? {
            guard let name else { return sheets.indices.contains(currentSheet) ? currentSheet : nil }
            return sheets.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        // A range or cell, as LibreOffice tries first.
        if let address = ODSFormula.parseAddress(Substring(mark)), let range = address.range, let index = sheetIndex(address.sheet) {
            return LinkTarget.sheet(sheets[index].id, range).link
        }
        // Excel's form, "Sheet1!A1:B2", as some converters leave it.
        if let bang = mark.lastIndex(of: "!") {
            var name = String(mark[..<bang])
            if name.count >= 2, name.hasPrefix("'"), name.hasSuffix("'") {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            let reference = mark[mark.index(after: bang)...].replacingOccurrences(of: "$", with: "")
            if let range = CellRange(a1: reference), let index = sheetIndex(name) {
                return LinkTarget.sheet(sheets[index].id, range).link
            }
        }
        // Then named ranges, then sheets.
        if let named = namedRanges.first(where: { $0.name.caseInsensitiveCompare(mark) == .orderedSame }) {
            return LinkTarget.namedRange(named.name).link
        }
        if let index = sheets.firstIndex(where: { $0.name.caseInsensitiveCompare(mark) == .orderedSame }) {
            return LinkTarget.sheet(sheets[index].id, nil).link
        }
        return nil
    }
}
