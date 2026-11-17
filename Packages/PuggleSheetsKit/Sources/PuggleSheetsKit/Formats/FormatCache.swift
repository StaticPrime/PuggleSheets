import Foundation

/// Parsed patterns by pattern text. Display runs for every visible cell on every redraw, so each
/// pattern is parsed once. Safe to use from any thread.
final class FormatCache: @unchecked Sendable {
    static let shared = FormatCache()

    /// Workbooks use a handful of patterns; the limit only guards against unbounded growth.
    private let limit = 4096
    private let lock = NSLock()
    private var formats: [String: ParsedFormat] = [:]

    func format(for pattern: String) -> ParsedFormat {
        lock.lock()
        let cached = formats[pattern]
        lock.unlock()
        if let cached { return cached }

        let parsed = FormatParser.parse(pattern)
        lock.lock()
        if formats.count >= limit { formats.removeAll(keepingCapacity: true) }
        formats[pattern] = parsed
        lock.unlock()
        return parsed
    }
}
