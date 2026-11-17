import Foundation

/// Where a cell's link goes. Links are stored as strings in `Cell.link`: a web or email address, or
/// a place in the spreadsheet written as "#gid=<sheet id>&range=A1:B2" (with our sheet ids) or
/// "#namedrange=Sales".
public enum LinkTarget: Hashable, Sendable {
    /// A web page or email address ("https://…", "mailto:…").
    case url(String)
    /// A sheet in this spreadsheet, and optionally a range in it.
    case sheet(UUID, CellRange?)
    /// A named range in this spreadsheet.
    case namedRange(String)

    public init?(link: String) {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("#") {
            var parameters: [String: String] = [:]
            for pair in text.dropFirst().split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { parameters[parts[0].lowercased()] = parts[1].removingPercentEncoding ?? parts[1] }
            }
            if let name = parameters["namedrange"], !name.isEmpty {
                self = .namedRange(name)
            } else if let id = parameters["gid"].flatMap(UUID.init(uuidString:)) {
                self = .sheet(id, parameters["range"].flatMap { CellRange(a1: $0.replacingOccurrences(of: "$", with: "")) })
            } else {
                return nil
            }
            return
        }
        self = .url(text)
    }

    /// The string `Cell.link` stores.
    public var link: String {
        switch self {
        case .url(let url): url
        case .sheet(let id, let range): "#gid=\(id.uuidString)" + (range.map { "&range=\($0.a1)" } ?? "")
        case .namedRange(let name): "#namedrange=" + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)
        }
    }

    /// The web address typed text stands for, when the whole text is one: "https://example.com",
    /// "www.example.com" (as "https://www.example.com"), "mailto:…" or "ftp://…". Such text
    /// shows as a link.
    public static func detectedURL(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count <= 2048, !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("ftp://") {
            return trimmed.count > lower.prefix(while: { $0 != "/" }).count + 2 ? trimmed : nil
        }
        if lower.hasPrefix("mailto:"), trimmed.count > 7 { return trimmed }
        if lower.hasPrefix("www."), trimmed.count > 4, trimmed.dropFirst(4).contains(".") { return "https://" + trimmed }
        return nil
    }

    /// A typed address as a link: adds "https://" when it has no scheme ("example.com" →
    /// "https://example.com") and "mailto:" for email addresses.
    public static func normalizedURL(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return trimmed }
        if trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil { return trimmed }
        if trimmed.contains("@"), !trimmed.contains("/") { return "mailto:" + trimmed }
        return "https://" + trimmed
    }
}
