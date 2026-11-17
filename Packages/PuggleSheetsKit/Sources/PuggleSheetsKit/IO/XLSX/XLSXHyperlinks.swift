import Foundation

/// A `<hyperlink>` as a worksheet lists it, before its relationship is looked up.
struct XLSXHyperlinkEntry: Sendable {
    var reference: String
    var relationshipID: String?
    var location: String?
}

/// Cell links as worksheet hyperlinks: web and email addresses through external relationships,
/// places in the workbook as locations ("'Sheet name'!A1:B2" or a defined name).
enum XLSXHyperlinks {
    /// The most cells one hyperlink element may link when read (they can cover whole columns).
    static let maximumCellsPerHyperlink = 10_000

    /// `<hyperlinks>` for the sheet's linked cells (`linked`, from `XLSXCellFeatures`); web addresses are
    /// added to `relationships`.
    static func write(_ sheet: Sheet, linked addresses: [CellAddress], workbook: Workbook, sheetNames: [String],
                      relationships: inout XLSXRelationshipsWriter) -> XMLWriter {
        let linked = addresses.compactMap { address -> (address: CellAddress, link: String)? in
            guard let link = sheet.cells[address]?.link, address.row >= 0, address.column >= 0,
                  address.row < XLSXLimits.rows, address.column < XLSXLimits.columns else { return nil }
            return (address, link)
        }.sorted { $0.address < $1.address }
        var xml = XMLWriter(fragmentCapacity: 64 + linked.count * 80)
        for (address, link) in linked {
            guard let target = LinkTarget(link: link) else { continue }
            switch target {
            case .url(let url):
                let id = relationships.add(type: XLSXRelationshipType.hyperlink, target: encodedTarget(url), isExternal: true)
                xml.raw("<hyperlink ref=\"\(address.a1)\" r:id=\"\(id)\"/>")
            case .sheet(let id, let range):
                guard let index = workbook.sheetIndex(id: id), sheetNames.indices.contains(index) else { continue }
                xml.raw("<hyperlink ref=\"\(address.a1)\"")
                xml.attribute("location", SheetNames.quoted(sheetNames[index]) + "!" + (range?.a1 ?? "A1"))
                xml.raw("/>")
            case .namedRange(let name):
                xml.raw("<hyperlink ref=\"\(address.a1)\"")
                xml.attribute("location", name)
                xml.raw("/>")
            }
        }
        guard !xml.isEmpty else { return xml }
        var result = XMLWriter(fragmentCapacity: xml.bytes.count + 32)
        result.raw("<hyperlinks>")
        result.append(xml)
        result.raw("</hyperlinks>")
        return result
    }

    /// Characters a URI can't hold (spaces, quotes, angle brackets…) percent-encoded; the rest as typed.
    static func encodedTarget(_ url: String) -> String {
        var result = ""
        for scalar in url.unicodeScalars {
            switch scalar {
            case " ", "\"", "<", ">", "\\", "^", "`", "{", "|", "}":
                result += String(format: "%%%02X", scalar.value)
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                result += String(format: "%%%02X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Sets the links of `entries` on the sheet's cells. Returns true when some couldn't be kept.
    static func apply(_ entries: [XLSXHyperlinkEntry], to sheet: inout Sheet, relationships: [String: XLSXRelationship],
                      sheetIDs: [String: UUID], namedRanges: [NamedRange]) -> Bool {
        var unsupported = false
        for entry in entries {
            guard let range = CellRange(a1: entry.reference.replacingOccurrences(of: "$", with: "")),
                  range.end.row < XLSXLimits.rows, range.end.column < XLSXLimits.columns else {
                unsupported = true
                continue
            }
            var link: String?
            if let id = entry.relationshipID {
                if let relationship = relationships[id], relationship.hasType("hyperlink") {
                    let fragment = entry.location.flatMap { $0.isEmpty ? nil : $0 }
                    link = relationship.rawTarget + (fragment.map { "#" + $0 } ?? "")
                }
            } else if let location = entry.location {
                link = internalLink(location, ownSheet: sheet.id, sheetIDs: sheetIDs, namedRanges: namedRanges)
            }
            guard let link, !link.isEmpty else {
                unsupported = true
                continue
            }
            guard range.cellCount <= maximumCellsPerHyperlink else {
                unsupported = true
                continue
            }
            for address in range.addresses {
                var cell = sheet[address]
                cell.link = link
                sheet[address] = cell
            }
        }
        return unsupported
    }

    /// A location as a link to a sheet and range, or to a named range. `sheetIDs` is keyed by
    /// lowercased sheet name.
    static func internalLink(_ location: String, ownSheet: UUID, sheetIDs: [String: UUID], namedRanges: [NamedRange]) -> String? {
        var text = location.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        var sheetName: String?
        var target = text
        if let bang = text.lastIndex(of: "!") {
            var name = String(text[..<bang])
            if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            sheetName = name
            target = String(text[text.index(after: bang)...])
        }
        let range = CellRange(a1: target.replacingOccurrences(of: "$", with: ""))
        if let sheetName {
            guard let id = sheetIDs[sheetName.lowercased()] else { return nil }
            if let range { return LinkTarget.sheet(id, range).link }
            // A name scoped to that sheet.
            if namedRanges.contains(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) {
                return LinkTarget.namedRange(target).link
            }
            return LinkTarget.sheet(id, nil).link
        }
        if let range { return LinkTarget.sheet(ownSheet, range).link }
        return NamedRange.isValidName(target) || namedRanges.contains(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame })
            ? LinkTarget.namedRange(target).link : nil
    }
}
