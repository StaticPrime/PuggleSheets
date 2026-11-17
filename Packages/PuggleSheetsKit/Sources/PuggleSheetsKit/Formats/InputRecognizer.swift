import Foundation

/// Recognizes numbers, percentages, currency amounts, dates and times in typed text (en-US).
enum InputRecognizer {
    struct Recognized: Equatable {
        var value: Double
        var format: String?
    }

    /// `text` must already be trimmed.
    static func recognize(_ text: String) -> Recognized? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        return number(bytes) ?? dateTime(bytes)
    }

    // MARK: Numbers

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    /// [sign] ["$"] [sign] digits [.digits] [e[sign]digits] [spaces "%"], with valid grouping.
    private static func number(_ bytes: [UInt8]) -> Recognized? {
        let count = bytes.count
        var index = 0
        var negative = false
        var signed = false
        var currency = false
        for _ in 0..<2 {
            guard index < count else { break }
            if !signed, bytes[index] == 0x2B || bytes[index] == 0x2D {
                signed = true
                negative = bytes[index] == 0x2D
                index += 1
            } else if !currency, bytes[index] == 0x24 {
                currency = true
                index += 1
                while index < count, bytes[index] == 0x20 { index += 1 }
            }
        }

        var literal: [UInt8] = []
        let integerStart = index
        while index < count, isDigit(bytes[index]) {
            literal.append(bytes[index])
            index += 1
        }
        var grouped = false
        let firstGroup = index - integerStart
        if index < count, bytes[index] == 0x2C, (1...3).contains(firstGroup) {
            while index < count, bytes[index] == 0x2C {
                guard index + 3 < count, isDigit(bytes[index + 1]), isDigit(bytes[index + 2]), isDigit(bytes[index + 3]),
                      index + 4 == count || !isDigit(bytes[index + 4]) else { return nil }
                literal.append(contentsOf: bytes[(index + 1)...(index + 3)])
                index += 4
            }
            grouped = true
        }
        let integerDigits = literal.count
        var fractionDigits = 0
        if index < count, bytes[index] == 0x2E {
            index += 1
            literal.append(0x2E)
            while index < count, isDigit(bytes[index]) {
                literal.append(bytes[index])
                fractionDigits += 1
                index += 1
            }
        }
        guard integerDigits + fractionDigits > 0 else { return nil }
        if integerDigits == 0 { literal.insert(0x30, at: 0) }
        if fractionDigits == 0, literal.last == 0x2E { literal.removeLast() }

        var hasExponent = false
        if index < count, bytes[index] == 0x45 || bytes[index] == 0x65 {
            var end = index + 1
            var exponent: [UInt8] = [0x65]
            if end < count, bytes[end] == 0x2B || bytes[end] == 0x2D {
                exponent.append(bytes[end])
                end += 1
            }
            let digitsStart = end
            while end < count, isDigit(bytes[end]) {
                exponent.append(bytes[end])
                end += 1
            }
            guard end > digitsStart else { return nil }
            literal.append(contentsOf: exponent)
            hasExponent = true
            index = end
        }

        var percent = false
        var end = index
        while end < count, bytes[end] == 0x20 { end += 1 }
        if end < count, bytes[end] == 0x25 {
            percent = true
            index = end + 1
        }
        guard index == count else { return nil }
        if hasExponent, percent || currency { return nil }
        if percent, currency { return nil }
        if percent { literal.append(contentsOf: Array("e-2".utf8)) }

        guard let magnitude = Double(String(decoding: literal, as: UTF8.self)), magnitude.isFinite else { return nil }
        let value = negative ? -magnitude : magnitude
        let format: String?
        if percent {
            format = fractionDigits > 0 ? "0.00%" : "0%"
        } else if currency {
            format = fractionDigits > 0 ? "\"$\"#,##0.00" : "\"$\"#,##0"
        } else if hasExponent {
            format = "0.00E+00"
        } else if grouped {
            format = fractionDigits > 0 ? "#,##0.00" : "#,##0"
        } else {
            format = nil
        }
        return Recognized(value: value == 0 ? 0 : value, format: format)
    }

    // MARK: Dates and times

    enum Token: Equatable {
        case number(Int, digits: Int)
        case word(String)
        case symbol(UInt8)
        case space
    }

    static func tokens(_ bytes: [UInt8]) -> [Token]? {
        var tokens: [Token] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if isDigit(byte) {
                var value = 0
                let start = index
                while index < bytes.count, isDigit(bytes[index]) {
                    guard index - start < 9 else { return nil }
                    value = value * 10 + Int(bytes[index] - 0x30)
                    index += 1
                }
                tokens.append(.number(value, digits: index - start))
            } else if (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A {
                let start = index
                while index < bytes.count, (bytes[index] | 0x20) >= 0x61 && (bytes[index] | 0x20) <= 0x7A { index += 1 }
                tokens.append(.word(String(decoding: bytes[start..<index], as: UTF8.self).lowercased()))
            } else if byte == 0x20 || byte == 0x09 {
                while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
                tokens.append(.space)
            } else {
                tokens.append(.symbol(byte))
                index += 1
            }
        }
        return tokens
    }

    private static func dateTime(_ bytes: [UInt8]) -> Recognized? {
        guard let first = bytes.first, isDigit(first) || (first | 0x20) >= 0x61 && (first | 0x20) <= 0x7A,
              let tokens = tokens(bytes) else { return nil }
        if let time = time(tokens[...]) {
            let format: String
            if time.hour >= 24 {
                format = "[h]:mm:ss"
            } else if time.twelveHour {
                format = time.hasSeconds ? "h:mm:ss AM/PM" : "h:mm AM/PM"
            } else {
                format = time.hasSeconds ? "H:mm:ss" : "H:mm"
            }
            return Recognized(value: time.fraction, format: format)
        }
        for match in dateMatches(tokens) {
            guard let serial = serial(year: match.year ?? currentYear(), month: match.month, day: match.day) else { continue }
            if match.end == tokens.count { return Recognized(value: serial, format: "M/d/yyyy") }
            switch tokens[match.end] {
            case .space, .word("t"): break
            default: continue
            }
            guard let time = time(tokens[(match.end + 1)...]), time.hour < 24 else { continue }
            return Recognized(value: serial + time.fraction, format: time.hasSeconds ? "M/d/yyyy H:mm:ss" : "M/d/yyyy H:mm")
        }
        return nil
    }

    struct Time {
        var fraction: Double
        var hour: Int
        var hasSeconds: Bool
        var twelveHour: Bool
    }

    /// "13:45", "1:45 PM", "1:45:30", "1:45:30.5", "1 PM", "25:30:00": the whole slice or nothing.
    static func time(_ tokens: ArraySlice<Token>) -> Time? {
        var index = tokens.startIndex
        let end = tokens.endIndex
        guard index < end, case .number(let hours, let hourDigits) = tokens[index], hourDigits <= 6 else { return nil }
        index += 1
        var minutes = 0
        var seconds = 0.0
        var hasMinutes = false
        var hasSeconds = false
        if index < end, tokens[index] == .symbol(0x3A) {
            guard index + 1 < end, case .number(let value, let digits) = tokens[index + 1], digits <= 2, value < 60 else { return nil }
            minutes = value
            hasMinutes = true
            index += 2
            if index < end, tokens[index] == .symbol(0x3A) {
                guard index + 1 < end, case .number(let value, let digits) = tokens[index + 1], digits <= 2, value < 60 else { return nil }
                seconds = Double(value)
                hasSeconds = true
                index += 2
                if index < end, tokens[index] == .symbol(0x2E) {
                    guard index + 1 < end, case .number(let value, let digits) = tokens[index + 1] else { return nil }
                    seconds += Double(value) / pow(10, Double(digits))
                    index += 2
                }
            }
        }
        var pm: Bool?
        var next = index
        if next < end, tokens[next] == .space { next += 1 }
        if next < end, case .word(let word) = tokens[next], ["am", "pm", "a", "p"].contains(word) {
            pm = word.hasPrefix("p")
            index = next + 1
        }
        guard index == end, hasMinutes || pm != nil else { return nil }
        var hour = hours
        if let pm {
            guard hours <= 12 else { return nil }
            hour = hours % 12 + (pm ? 12 : 0)
        }
        let fraction = (Double(hour) * 3600 + Double(minutes) * 60 + seconds) / 86_400
        return Time(fraction: fraction, hour: hour, hasSeconds: hasSeconds, twelveHour: pm != nil)
    }

    struct DateMatch {
        /// Nil for this year ("1/2", "Jan 2").
        var year: Int?
        var month: Int
        var day: Int
        /// The index of the first token after the date.
        var end: Int
    }

    static let monthsByName: [String: Int] = {
        var months: [String: Int] = ["sept": 9]
        for (index, name) in FormatRenderer.monthNames.enumerated() {
            months[name.lowercased()] = index + 1
            months[String(name.lowercased().prefix(3))] = index + 1
        }
        return months
    }()

    /// Every way the start of `tokens` reads as a date, longest forms first. Years are already
    /// four-digit (nil for this year); validity is checked later.
    static func dateMatches(_ tokens: [Token]) -> [DateMatch] {
        var matches: [DateMatch] = []
        func number(_ index: Int) -> (value: Int, digits: Int)? {
            guard index < tokens.count, case .number(let value, let digits) = tokens[index] else { return nil }
            return (value, digits)
        }
        func month(_ index: Int) -> Int? {
            guard index < tokens.count, case .word(let word) = tokens[index] else { return nil }
            return monthsByName[word]
        }
        func isSymbol(_ index: Int, _ symbol: UInt8) -> Bool {
            index < tokens.count && tokens[index] == .symbol(symbol)
        }
        func isSpace(_ index: Int) -> Bool {
            index < tokens.count && tokens[index] == .space
        }
        /// Where the year starts after a day or month that ends before `index`: after "-" in dashed
        /// dates, else after a comma and/or a space.
        func yearIndex(after index: Int, dashed: Bool) -> Int? {
            if dashed { return isSymbol(index, 0x2D) ? index + 1 : nil }
            var next = index
            if isSymbol(next, 0x2C) { next += 1 }
            if isSpace(next) { next += 1 }
            return next > index ? next : nil
        }

        // 1/2/2026, 1-2-26, 2026-01-02, 2026/1/2
        if let first = number(0), let second = number(2), let third = number(4),
           isSymbol(1, 0x2F) && isSymbol(3, 0x2F) || isSymbol(1, 0x2D) && isSymbol(3, 0x2D) {
            if first.digits == 4, second.digits <= 2, third.digits <= 2 {
                matches.append(DateMatch(year: first.value, month: second.value, day: third.value, end: 5))
            } else if first.digits <= 2, second.digits <= 2, let year = fullYear(third) {
                matches.append(DateMatch(year: year, month: first.value, day: second.value, end: 5))
            }
        }
        // 1/2 (this year)
        if let first = number(0), let second = number(2), isSymbol(1, 0x2F), first.digits <= 2, second.digits <= 2 {
            matches.append(DateMatch(year: nil, month: first.value, day: second.value, end: 3))
        }
        // Jan 2, 2026 / January 2 2026 / Jan. 2 / Jan-2-2026
        if let monthNumber = month(0) {
            var dayIndex = isSymbol(1, 0x2E) ? 2 : 1
            let dashed = isSymbol(dayIndex, 0x2D)
            if dashed || isSpace(dayIndex) { dayIndex += 1 }
            if dayIndex > 1, let day = number(dayIndex), day.digits <= 2 {
                if let yearStart = yearIndex(after: dayIndex + 1, dashed: dashed), let year = number(yearStart).flatMap(fullYear) {
                    matches.append(DateMatch(year: year, month: monthNumber, day: day.value, end: yearStart + 1))
                }
                matches.append(DateMatch(year: nil, month: monthNumber, day: day.value, end: dayIndex + 1))
            }
        }
        // 2 Jan 2026 / 2-Jan-2026 / 2 Jan
        if let day = number(0), day.digits <= 2, isSpace(1) || isSymbol(1, 0x2D), let monthNumber = month(2) {
            let dashed = isSymbol(1, 0x2D)
            let afterMonth = isSymbol(3, 0x2E) ? 4 : 3
            if let yearStart = yearIndex(after: afterMonth, dashed: dashed), let year = number(yearStart).flatMap(fullYear) {
                matches.append(DateMatch(year: year, month: monthNumber, day: day.value, end: yearStart + 1))
            }
            matches.append(DateMatch(year: nil, month: monthNumber, day: day.value, end: afterMonth))
        }
        return matches
    }

    /// Four-digit years as typed; one- or two-digit years 00–29 are 20xx and 30–99 are 19xx.
    private static func fullYear(_ year: (value: Int, digits: Int)) -> Int? {
        switch year.digits {
        case 1, 2: year.value < 30 ? 2000 + year.value : 1900 + year.value
        case 4: year.value
        default: nil
        }
    }

    private static func serial(year: Int, month: Int, day: Int) -> Double? {
        guard (1...12).contains(month), day >= 1, day <= DateSerial.daysInMonth(year: year, month: month) else { return nil }
        return DateSerial.serial(year: year, month: month, day: day)
    }

    static func currentYear() -> Int {
        Calendar(identifier: .gregorian).component(.year, from: Date())
    }
}
