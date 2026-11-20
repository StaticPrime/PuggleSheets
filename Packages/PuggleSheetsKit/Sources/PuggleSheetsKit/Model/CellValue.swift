import Foundation

/// What a cell holds, or what its formula produced. Dates and times are numbers (see `DateSerial`)
/// shown through a date or time number format.
public enum CellValue: Hashable, Sendable {
    case empty
    case number(Double)
    case text(String)
    case boolean(Bool)
    case error(CellError)

    public var isEmpty: Bool { self == .empty }

    public var numberValue: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    public var textValue: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    public var booleanValue: Bool? {
        if case .boolean(let boolean) = self { return boolean }
        return nil
    }

    public var errorValue: CellError? {
        if case .error(let error) = self { return error }
        return nil
    }
}

/// A formula error such as #DIV/0!. Two errors are equal when their kinds match; the message is
/// the explanation shown when hovering the cell ("Function DIVIDE parameter 2 cannot be zero.").
public struct CellError: Error, Hashable, Sendable, CustomStringConvertible, Codable {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case null = "#NULL!"
        case divideByZero = "#DIV/0!"
        case value = "#VALUE!"
        case reference = "#REF!"
        case name = "#NAME?"
        case number = "#NUM!"
        case notAvailable = "#N/A"
        /// A formula that can't be parsed.
        case parse = "#ERROR!"
    }

    public var kind: Kind
    public var message: String?

    public init(_ kind: Kind, _ message: String? = nil) {
        self.kind = kind
        self.message = message
    }

    /// Parses "#DIV/0!" and the other error codes (case-insensitive).
    public init?(code: String) {
        guard let kind = Kind.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(code) == .orderedSame }) else { return nil }
        self.init(kind)
    }

    public var code: String { kind.rawValue }
    public var description: String { kind.rawValue }

    public static func == (lhs: CellError, rhs: CellError) -> Bool { lhs.kind == rhs.kind }
    public func hash(into hasher: inout Hasher) { hasher.combine(kind) }
}
