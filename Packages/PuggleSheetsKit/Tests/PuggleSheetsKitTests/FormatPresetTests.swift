import Foundation
import Testing
@testable import PuggleSheetsKit

struct FormatPresetTests {
    @Test func menuListsPresetsInOrder() {
        #expect(NumberFormatPresets.all.map(\.name) == ["Automatic", "Plain text", "Number", "Percent", "Scientific", "Accounting",
                                                       "Financial", "Currency", "Currency rounded", "Date", "Time", "Date time",
                                                       "Duration"])
        #expect(Set(NumberFormatPresets.all.map(\.id)).count == NumberFormatPresets.all.count)
        #expect(NumberFormatPresets.automatic.pattern == nil)
        #expect(NumberFormatPresets.number.pattern == "#,##0.00")
        #expect(NumberFormatPresets.accounting.pattern == "_(\"$\"* #,##0.00_);_(\"$\"* \\(#,##0.00\\);_(\"$\"* \"-\"??_);_(@_)")
    }

    @Test func examplesAreWhatThePatternsShow() {
        let examples: [(NumberFormatPreset, Double)] = [
            (NumberFormatPresets.number, 1000.12), (NumberFormatPresets.percent, 0.1012),
            (NumberFormatPresets.scientific, 1010), (NumberFormatPresets.financial, -1000.12),
            (NumberFormatPresets.currency, 1000.12), (NumberFormatPresets.currencyRounded, 1000.12),
            (NumberFormatPresets.date, DateSerial.serial(year: 2008, month: 9, day: 26)),
            (NumberFormatPresets.time, DateSerial.time(hour: 15, minute: 59, second: 0)),
            (NumberFormatPresets.dateTime, DateSerial.serial(year: 2008, month: 9, day: 26, hour: 15, minute: 59, second: 0)),
            (NumberFormatPresets.duration, 1 + 1.0 / 1440),
        ]
        for (preset, value) in examples {
            #expect(shown(value, preset.pattern) == preset.example, "\(preset.name)")
        }
        let accounting = CellDisplay.text(for: .number(-1000.12), pattern: NumberFormatPresets.accounting.pattern)
        #expect(accounting.text.trimmingCharacters(in: .whitespaces) == NumberFormatPresets.accounting.example)
    }

    @Test func presetKinds() {
        let expected: [NumberFormatKind] = [.automatic, .plainText, .number, .percent, .scientific, .accounting, .number,
                                            .currency, .currency, .date, .time, .dateTime, .duration]
        #expect(NumberFormatPresets.all.map { NumberFormatPresets.kind(of: $0.pattern) } == expected)
    }

    @Test func kindOfAnyPattern() {
        let cases: [String: NumberFormatKind] = [
            "0": .number, "#,##0": .number, "0.00;(0.00)": .number, "0.00 \"kg\"": .number, "# ?/?": .number, ";;;": .number,
            "0%": .percent, "[Red]0.0%;[Blue]-0.0%": .percent,
            "0.00E+00": .scientific, "##0.0E+0": .scientific,
            "\"$\"#,##0.00": .currency, "$#,##0": .currency, "[$€-407]#,##0.00": .currency, "#,##0.00 €": .currency,
            "£0": .currency, "_($* #,##0_)": .accounting, "\"$\"* #,##0.00": .accounting,
            "M/d/yyyy": .date, "yyyy-mm-dd": .date, "dddd": .date, "mmm yyyy": .date, "d-mmm": .date,
            "h:mm:ss AM/PM": .time, "H:mm": .time, "mm:ss": .time, "h:mm:ss.000": .time, "AM/PM": .time,
            "M/d/yyyy H:mm:ss": .dateTime, "yyyy-mm-dd hh:mm": .dateTime,
            "[h]:mm:ss": .duration, "[mm]:ss": .duration, "[ss]": .duration,
            "@": .plainText, "\"Name: \"@": .plainText, "[Blue]@": .plainText,
            "General": .automatic, "\"unterminated": .automatic, "": .automatic,
        ]
        for (pattern, kind) in cases {
            #expect(NumberFormatPresets.kind(of: pattern) == kind, "\(pattern)")
        }
        #expect(NumberFormatPresets.kind(of: nil) == .automatic)
    }

    @Test func decimalsFromAutomatic() {
        #expect(NumberFormatPresets.adjustingDecimals(nil, by: 1, for: .number(1.5)) == "0.00")
        #expect(NumberFormatPresets.adjustingDecimals(nil, by: -1, for: .number(1.5)) == "0")
        #expect(NumberFormatPresets.adjustingDecimals(nil, by: 1, for: .number(3)) == "0.0")
        #expect(NumberFormatPresets.adjustingDecimals(nil, by: -1, for: .number(3)) == "0")
        #expect(NumberFormatPresets.adjustingDecimals(nil, by: 1, for: .number(1.0 / 3)) == "0.00000000000")
        #expect(NumberFormatPresets.adjustingDecimals(nil, by: -1, for: .number(1.0 / 3)) == "0.000000000")
        #expect(NumberFormatPresets.adjustingDecimals(nil, by: 2, for: .number(-2.25)) == "0.0000")
        #expect(NumberFormatPresets.adjustingDecimals(nil, by: 1, for: .number(1.5e20)) == "0.00E+00")
        #expect(NumberFormatPresets.adjustingDecimals(nil, by: 1, for: .text("abc")) == "0.0")
        #expect(NumberFormatPresets.adjustingDecimals(nil, by: 1, for: .empty) == "0.0")
        #expect(NumberFormatPresets.adjustingDecimals("General", by: 1, for: .number(1.5)) == "0.00")
        #expect(NumberFormatPresets.adjustingDecimals("", by: -1, for: .number(1.25)) == "0.0")
        #expect(NumberFormatPresets.adjustingDecimals(nil, by: 0, for: .number(1.5)) == nil)
    }

    @Test func decimalsInPatterns() {
        func adjust(_ pattern: String, _ delta: Int) -> String? {
            NumberFormatPresets.adjustingDecimals(pattern, by: delta, for: .number(1234.5))
        }
        #expect(adjust("\"$\"#,##0.00", 1) == "\"$\"#,##0.000")
        #expect(adjust("\"$\"#,##0.00", -1) == "\"$\"#,##0.0")
        #expect(adjust("\"$\"#,##0", 1) == "\"$\"#,##0.0")
        #expect(adjust("0%", 1) == "0.0%")
        #expect(adjust("0.00%", -2) == "0%")
        #expect(adjust("#,##0", 1) == "#,##0.0")
        #expect(adjust("#,##0", -1) == "#,##0")
        #expect(adjust("0.0", -1) == "0")
        #expect(adjust("0.0", -5) == "0")
        #expect(adjust("0", 3) == "0.000")
        #expect(adjust("0.00E+00", 1) == "0.000E+00")
        #expect(adjust("0.00E+00", -2) == "0E+00")
        #expect(adjust("#,##0.0,,\"M\"", 1) == "#,##0.00,,\"M\"")
        #expect(adjust("#,##0,,", 1) == "#,##0.0,,")
        #expect(adjust("[Red]0.0;[Blue]-0.0", 1) == "[Red]0.00;[Blue]-0.00")
        #expect(adjust("0.0#", 1) == "0.0##")
        #expect(adjust("0.00\" kg\"", 1) == "0.000\" kg\"")
        #expect(adjust("\"0.0 \"0", 1) == "\"0.0 \"0.0")
        #expect(adjust(NumberFormatPresets.financial.pattern!, 1) == "#,##0.000;(#,##0.000)")
        #expect(adjust(NumberFormatPresets.accounting.pattern!, 1)
            == "_(\"$\"* #,##0.000_);_(\"$\"* \\(#,##0.000\\);_(\"$\"* \"-\"???_);_(@_)")
        #expect(adjust(NumberFormatPresets.accounting.pattern!, -2)
            == "_(\"$\"* #,##0_);_(\"$\"* \\(#,##0\\);_(\"$\"* \"-\"_);_(@_)")
        #expect(adjust("0.00;-0.00;\"zero\";@", 1) == "0.000;-0.000;\"zero\";@")
    }

    @Test func decimalsLeaveDatesTimesAndTextAlone() {
        for pattern in ["M/d/yyyy", "h:mm:ss AM/PM", "M/d/yyyy H:mm:ss", "[h]:mm:ss", "h:mm:ss.000", "@", "\"x\"@", "# ?/?",
                        "\"unterminated"] {
            #expect(NumberFormatPresets.adjustingDecimals(pattern, by: 1, for: .number(1)) == pattern, "\(pattern)")
            #expect(NumberFormatPresets.adjustingDecimals(pattern, by: -1, for: .number(1)) == pattern, "\(pattern)")
        }
    }
}
