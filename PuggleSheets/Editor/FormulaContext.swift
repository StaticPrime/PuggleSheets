import Foundation

/// What the caret is in while a formula is typed: a partly typed name (for autocomplete) and the
/// function call around it (for the argument help).
struct FormulaContext: Equatable {
    /// The name being typed right before the caret, and where it is (UTF-16).
    var partialName: (text: String, range: NSRange)?
    /// The innermost function call around the caret and which argument (from 0) the caret is in.
    var call: (name: String, argument: Int)?

    static func == (a: Self, b: Self) -> Bool {
        a.partialName?.text == b.partialName?.text && a.partialName?.range == b.partialName?.range
            && a.call?.name == b.call?.name && a.call?.argument == b.call?.argument
    }

    static func nameCharacter(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || (0x30...0x39).contains(unit) || unit == 0x5F || unit == 0x2E
    }

    /// Reads `text` up to `caret`. nil unless the text is a formula.
    static func at(_ caret: Int, in text: String) -> FormulaContext? {
        let units = Array(text.utf16)
        guard units.first == 0x3D, caret >= 1, caret <= units.count else { return nil }
        var frames: [(name: String?, argument: Int)] = []
        var inString = false
        var index = 1
        var nameStart: Int?
        while index < caret {
            let unit = units[index]
            if inString {
                if unit == 0x22 { inString = false }
                index += 1
                continue
            }
            if nameCharacter(unit) {
                if nameStart == nil { nameStart = index }
                index += 1
                continue
            }
            let name = nameStart.map { String(utf16CodeUnits: Array(units[$0..<index]), count: index - $0) }
            nameStart = nil
            switch unit {
            case 0x22: inString = true
            case 0x28: frames.append((name, 0))                                          // (
            case 0x7B: frames.append((nil, 0))                                           // {
            case 0x29, 0x7D: if !frames.isEmpty { frames.removeLast() }                  // ) }
            case 0x2C, 0x3B: if !frames.isEmpty { frames[frames.count - 1].argument += 1 } // , ;
            default: break
            }
            index += 1
        }
        guard !inString else { return nil }
        var context = FormulaContext()
        if let start = nameStart, let first = units[start...].first, !(0x30...0x39).contains(first), first != 0x2E,
           caret == units.count || !nameCharacter(units[caret]) {
            let before = start > 0 ? units[start - 1] : 0x3D
            // Not right after a sheet name or a quote ("Sheet1!A" or "'My sheet'!A").
            if before != 0x21, before != 0x27 {
                context.partialName = (String(utf16CodeUnits: Array(units[start..<caret]), count: caret - start),
                                       NSRange(location: start, length: caret - start))
            }
        }
        if let frame = frames.last(where: { $0.name != nil }), let name = frame.name {
            context.call = (name.uppercased(), frame.argument)
        }
        return context
    }
}
