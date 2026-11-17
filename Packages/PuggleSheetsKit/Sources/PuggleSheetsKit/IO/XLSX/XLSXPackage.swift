import Foundation

/// A relationship from one package part to another (Open Packaging Conventions).
struct XLSXRelationship: Sendable {
    var id: String
    var type: String
    /// The target part's path inside the package, or the raw target of an external relationship.
    var target: String
    var isExternal: Bool
    /// The target as written, before it's resolved against the source part.
    var rawTarget: String

    /// Matches the last segment of the type, so transitional and strict URIs both work:
    /// ".../2006/relationships/worksheet" and ".../ooxml/officeDocument/relationships/worksheet".
    func hasType(_ name: String) -> Bool {
        type.hasSuffix("/" + name)
    }
}

enum XLSXPackage {
    /// "xl/workbook.xml" → "xl/_rels/workbook.xml.rels"; "" (the package itself) → "_rels/.rels".
    static func relationshipsPath(for part: String) -> String {
        guard let slash = part.lastIndex(of: "/") else { return "_rels/\(part).rels" }
        return "\(part[..<slash])/_rels/\(part[part.index(after: slash)...]).rels"
    }

    /// Resolves a relationship target against the part it comes from: "worksheets/sheet1.xml" from
    /// "xl/workbook.xml" is "xl/worksheets/sheet1.xml"; "/xl/styles.xml" is absolute; ".." goes up.
    static func resolve(_ target: String, from part: String) -> String {
        let decoded = target.removingPercentEncoding ?? target
        var segments: [Substring] = []
        if !decoded.hasPrefix("/"), let slash = part.lastIndex(of: "/") {
            segments = part[..<slash].split(separator: "/")
        }
        for segment in decoded.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": if !segments.isEmpty { segments.removeLast() }
            default: segments.append(segment)
            }
        }
        return segments.joined(separator: "/")
    }

    /// The relationships of `part` ("" for the package), with targets resolved. Empty when the part
    /// has none; throws when the relationships part isn't valid XML.
    static func relationships(of part: String, in zip: ZipReader) throws -> [XLSXRelationship] {
        guard let data = try zip.read(relationshipsPath(for: part)) else { return [] }
        let root = try XMLTree.parse(data)
        return root.children("Relationship").compactMap { node in
            guard let id = node["Id"], let type = node["Type"], let target = node["Target"] else { return nil }
            let external = node["TargetMode"]?.caseInsensitiveCompare("External") == .orderedSame
            return XLSXRelationship(id: id, type: type, target: external ? target : resolve(target, from: part), isExternal: external,
                                    rawTarget: target)
        }
    }
}
