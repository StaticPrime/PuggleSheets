import Foundation
import Testing
@testable import PuggleSheetsKit

/// The text `number` shows with `pattern`.
func shown(_ number: Double, _ pattern: String?) -> String {
    CellDisplay.text(for: .number(number), pattern: pattern).text
}

struct FormatNumberPatternTests {
    @Test func digitPlaceholders() {
        #expect(shown(1234.5, "0") == "1235")
        #expect(shown(5, "000") == "005")
        #expect(shown(1.5, "00.00") == "01.50")
        #expect(shown(0, "#") == "")
        #expect(shown(12, "#") == "12")
        #expect(shown(0.25, "#.##") == ".25")
        #expect(shown(1.5, "#.##") == "1.5")
        #expect(shown(5, "#.##") == "5.")
        #expect(shown(1.5, "?.??") == "1.5 ")
        #expect(shown(0.5, "?.??") == " .5 ")
        #expect(shown(1.5, "0.0#") == "1.5")
        #expect(shown(1.25, "0.0#") == "1.25")
        #expect(shown(0.5, ".00") == ".50")
        #expect(shown(1.5, ".00") == "1.50")
        #expect(shown(123_456_789, "0") == "123456789")
    }

    @Test func roundsHalfAwayFromZeroOnDecimalDigits() {
        #expect(shown(2.5, "0") == "3")
        #expect(shown(-2.5, "0") == "-3")
        #expect(shown(0.5, "0") == "1")
        #expect(shown(1.005, "0.00") == "1.01")
        #expect(shown(2.675, "0.00") == "2.68")
        #expect(shown(0.15, "0.0") == "0.2")
        #expect(shown(-0.05, "0.0") == "-0.1")
        #expect(shown(1.45, "0.0") == "1.5")
        #expect(shown(0.1 + 0.2, "0.000000000000000") == "0.300000000000000")
        #expect(shown(9.999, "0.00") == "10.00")
        #expect(shown(0.000123, "0.00") == "0.00")
    }

    @Test func negativesInOneSectionGetAMinusSign() {
        #expect(shown(-1234.5, "#,##0.00") == "-1,234.50")
        #expect(shown(-5, "\"$\"#,##0.00") == "-$5.00")
        #expect(shown(-5, "$0") == "-$5")
        // As in Sheets and Excel, a negative that rounds to zero keeps its sign under a pattern.
        #expect(shown(-0.4, "0") == "-0")
        #expect(shown(-0.0, "0.00") == "0.00")
    }

    @Test func grouping() {
        #expect(shown(1_234_567.891, "#,##0") == "1,234,568")
        #expect(shown(1234.5, "#,##0.00") == "1,234.50")
        #expect(shown(0.5, "#,##0.00") == "0.50")
        #expect(shown(0, "#,##0") == "0")
        #expect(shown(999, "#,##0") == "999")
        #expect(shown(1000, "#,##0") == "1,000")
        #expect(shown(5, "0,000") == "0,005")
        #expect(shown(1e15, "#,##0") == "1,000,000,000,000,000")
    }

    @Test func trailingCommasScale() {
        #expect(shown(1_234_567, "#,##0,") == "1,235")
        #expect(shown(1_234_567, "0.0,,") == "1.2")
        #expect(shown(1_234_567, "#,##0.0,,\"M\"") == "1.2M")
        #expect(shown(999, "0,") == "1")
        #expect(shown(1500, "0,\"K\"") == "2K")
        #expect(shown(2_500_000, "0,.00") == "2500.00")
    }

    @Test func percent() {
        #expect(shown(0.125, "0%") == "13%")
        #expect(shown(0.125, "0.0%") == "12.5%")
        #expect(shown(-0.0512, "0.00%") == "-5.12%")
        #expect(shown(1.005, "0%") == "101%")
        #expect(shown(0.07, "0%") == "7%")
        #expect(shown(5, "0\\%") == "5%")
        #expect(shown(0.5, "0%%") == "5000%%")
    }

    @Test func scientific() {
        #expect(shown(12345, "0.00E+00") == "1.23E+04")
        #expect(shown(0.000123, "0.00E+00") == "1.23E-04")
        #expect(shown(0, "0.00E+00") == "0.00E+00")
        #expect(shown(-12345, "0.00E+00") == "-1.23E+04")
        #expect(shown(9.999, "0.00E+00") == "1.00E+01")
        #expect(shown(1e100, "0.00E+00") == "1.00E+100")
        #expect(shown(12345, "0.00E-00") == "1.23E04")
        #expect(shown(0.5, "0.00E-00") == "5.00E-01")
        #expect(shown(12345, "0.0e+0") == "1.2e+4")
        #expect(shown(12345, "##0.0E+0") == "12.3E+3")
        #expect(shown(1234, "##0.0E+0") == "1.2E+3")
        #expect(shown(123_456, "##0.0E+0") == "123.5E+3")
        #expect(shown(0.000123, "##0.0E+0") == "123.0E-6")
        #expect(shown(999.96, "##0.0E+0") == "1.0E+3")
        #expect(shown(12345, "00.00E+00") == "12.35E+03")
        #expect(shown(12345, "0E+0") == "1E+4")
    }

    @Test func literalsAndEscapes() {
        #expect(shown(1234.5, "\"$\"#,##0.00") == "$1,234.50")
        #expect(shown(1.5, "0.00\" kg\"") == "1.50 kg")
        #expect(shown(5, "\\$0") == "$5")
        #expect(shown(5, "0 \"items\"") == "5 items")
        #expect(shown(5_551_234_567, "(000) 000-0000") == "(555) 123-4567")
        #expect(shown(123_456_789, "000-00-0000") == "123-45-6789")
        #expect(shown(5, "+0;-0") == "+5")
        #expect(shown(-5, "+0;-0") == "-5")
        #expect(shown(5, "0_)") == "5 ")
        #expect(shown(5, "\"a;b\"0") == "a;b5")
        #expect(shown(5, "[$€-407]0.00") == "€5.00")
        #expect(shown(5, "[$-409]0.00") == "5.00")
        #expect(shown(5, "0 \\E") == "5 E")
    }

    @Test func fills() {
        let dollars = CellDisplay.text(for: .number(1234.5), pattern: "\"$\"* #,##0.00")
        #expect(dollars.text == "$ 1,234.50")
        #expect(dollars.fill == DisplayText.Fill(before: "$", after: "1,234.50"))
        let dashes = CellDisplay.text(for: .number(5), pattern: "0*-")
        #expect(dashes.text == "5-")
        #expect(dashes.fill == DisplayText.Fill(before: "5", after: "", character: "-"))
        let negative = CellDisplay.text(for: .number(-5), pattern: "\"$\"* 0")
        #expect(negative.fill == DisplayText.Fill(before: "-$", after: "5"))
        #expect(CellDisplay.text(for: .number(5), pattern: "0").fill == nil)
    }

    @Test func accountingAndFinancialPresets() {
        let accounting = NumberFormatPresets.accounting.pattern
        let positive = CellDisplay.text(for: .number(1234.5), pattern: accounting)
        #expect(positive.text == " $ 1,234.50 ")
        #expect(positive.fill == DisplayText.Fill(before: " $", after: "1,234.50 "))
        let negative = CellDisplay.text(for: .number(-1234.5), pattern: accounting)
        #expect(negative.fill == DisplayText.Fill(before: " $", after: "(1,234.50)"))
        let zero = CellDisplay.text(for: .number(0), pattern: accounting)
        #expect(zero.fill == DisplayText.Fill(before: " $", after: "-   "))
        let text = CellDisplay.text(for: .text("abc"), pattern: accounting)
        #expect(text.text == " abc " && text.fill == nil)

        let financial = NumberFormatPresets.financial.pattern
        #expect(shown(-1234.5, financial) == "(1,234.50)")
        #expect(shown(1234.5, financial) == "1,234.50")
        #expect(shown(0, financial) == "0.00")
    }

    @Test func sectionsPickPositiveNegativeZero() {
        #expect(shown(5, "0;-0;\"zero\"") == "5")
        #expect(shown(-5, "0;-0;\"zero\"") == "-5")
        #expect(shown(0, "0;-0;\"zero\"") == "zero")
        // The negative section shows the absolute value.
        #expect(shown(-5, "0;(0)") == "(5)")
        #expect(shown(-5, "0;\"minus \"0") == "minus 5")
        // Two sections: zero uses the first.
        #expect(shown(0, "0.0;(0.0)") == "0.0")
        // Empty sections hide values.
        #expect(shown(-5, "0;;0") == "")
        #expect(shown(0, "0;-0;") == "")
        #expect(shown(5, ";;;") == "")
        #expect(CellDisplay.text(for: .text("abc"), pattern: ";;;").text == "")
    }

    @Test func conditions() {
        let pattern = "[>100]\"big\";[<0]\"negative\";\"small\""
        #expect(shown(150, pattern) == "big")
        #expect(shown(-5, pattern) == "negative")
        #expect(shown(50, pattern) == "small")
        #expect(shown(100, pattern) == "small")

        let thousands = "[>=1000]#,##0.0,\"K\";0"
        #expect(shown(1500, thousands) == "1.5K")
        #expect(shown(999, thousands) == "999")
        #expect(shown(2_500_000, thousands) == "2,500.0K")

        #expect(shown(5, "[<=0]\"low\";\"high\"") == "high")
        #expect(shown(-5, "[<=0]\"low\";\"high\"") == "low")
        #expect(shown(1, "[=1]\"one\";[<>1]0") == "one")
        #expect(shown(2, "[=1]\"one\";[<>1]0") == "2")
        #expect(shown(-1500, "[>=1000]0,\"K\";[>=1]0;0") == "-1500")
        // A first section with a condition shows the value without its sign, as in Excel.
        #expect(shown(-7, "[<0]0;0") == "7")
        // No matching section: Automatic.
        #expect(shown(5, "[>10]0") == "5")
        #expect(shown(2, "[>=1.5]\"yes\";\"no\"") == "yes")
    }

    @Test func colors() {
        let red = RGBColor(red: 255, green: 0, blue: 0)
        let blue = RGBColor(red: 0, green: 0, blue: 255)
        #expect(CellDisplay.text(for: .number(5), pattern: "[Red]0;[Blue]-0").color == red)
        let negative = CellDisplay.text(for: .number(-5), pattern: "[Red]0;[Blue]-0")
        #expect(negative.text == "-5" && negative.color == blue)
        #expect(CellDisplay.text(for: .number(5), pattern: "0").color == nil)
        let expected: [String: String] = ["Black": "000000", "White": "FFFFFF", "Red": "FF0000", "Green": "00FF00",
                                          "Blue": "0000FF", "Yellow": "FFFF00", "Magenta": "FF00FF", "Cyan": "00FFFF"]
        for (name, hex) in expected {
            #expect(CellDisplay.text(for: .number(1), pattern: "[\(name)]0").color?.hex == hex)
            #expect(CellDisplay.text(for: .number(1), pattern: "[\(name.uppercased())]0").color?.hex == hex)
        }
        #expect(CellDisplay.text(for: .number(1), pattern: "[Color10]0").color?.hex == "008000")
        #expect(CellDisplay.text(for: .number(1), pattern: "[Color3]0").color == red)
        let conditional = CellDisplay.text(for: .number(150), pattern: "[Green][>100]0;[Red]0")
        #expect(conditional.color?.hex == "00FF00")
        #expect(CellDisplay.text(for: .text("x"), pattern: "0;0;0;[Magenta]@").color?.hex == "FF00FF")
    }

    @Test func fractions() {
        #expect(shown(1.5, "# ?/?") == "1 1/2")
        #expect(shown(0.5, "# ?/?") == " 1/2")
        #expect(shown(3, "# ?/?") == "3    ")
        #expect(shown(0, "# ?/?") == "0    ")
        #expect(shown(-1.5, "# ?/?") == "-1 1/2")
        #expect(shown(3.14159265, "# ?/?") == "3 1/7")
        #expect(shown(3.14159265, "# ??/??") == "3 14/99")
        #expect(shown(0.5, "# ??/??") == "  1/2 ")
        #expect(shown(2.675, "# ??/??") == "2 27/40")
        #expect(shown(0.75, "?/8") == "6/8")
        #expect(shown(1.5, "?/8") == "12/8")
        #expect(shown(1.5, "# ?/8") == "1 4/8")
        #expect(shown(2.125, "# ?/4") == "2 1/4")
        #expect(shown(1.999, "# ?/4") == "2    ")
        #expect(shown(0.5, "?/?") == "1/2")
        #expect(shown(2.5, "?/?") == "5/2")
        #expect(shown(0, "?/?") == "0/1")
        #expect(shown(0.37, "# ?/100") == " 37/100")
        #expect(shown(0.25, "# ???/???") == "   1/4  ")
        #expect(shown(1234.5, "#,### ?/?") == "1,234 1/2")
        #expect(shown(1e20, "?/?") == "1E+20")
    }

    @Test func general() {
        #expect(shown(1234.5, "General") == "1234.5")
        #expect(shown(1.0 / 3, "general") == "0.3333333333")
        let negative = CellDisplay.text(for: .number(-1234.5), pattern: "General;[Red]-General")
        #expect(negative.text == "-1234.5" && negative.color?.hex == "FF0000")
        #expect(shown(-2, "General;(General)") == "(2)")
        #expect(shown(5, "\"Total: \"General") == "Total: 5")
    }

    @Test func textSections() {
        func text(_ value: String, _ pattern: String) -> String {
            CellDisplay.text(for: .text(value), pattern: pattern).text
        }
        #expect(text("abc", "0;-0;\"zero\";\"text: \"@") == "text: abc")
        #expect(text("abc", "0;-0;0;\"no text\"") == "no text")
        #expect(text("abc", "@") == "abc")
        #expect(text("abc", "\"pre\"@") == "preabc")
        #expect(text("abc", "@@") == "abcabc")
        #expect(text("abc", "0.00;@\" ok\"") == "abc ok")
        #expect(text("abc", "0.00") == "abc")
        #expect(text("abc", "#,##0;(#,##0)") == "abc")
        #expect(CellDisplay.text(for: .text("abc"), pattern: "[Blue]@").color?.hex == "0000FF")
        let filled = CellDisplay.text(for: .text("abc"), pattern: "@*.")
        #expect(filled.fill == DisplayText.Fill(before: "abc", after: "", character: "."))
        // Numbers with a text-only pattern show as Automatic.
        #expect(shown(1234.5, "@") == "1234.5")
        #expect(shown(1234.5, "\"x\"@") == "1234.5")
        #expect(shown(-3, "0.00;@") == "-3.00")
    }

    @Test func booleansErrorsAndEmptyIgnorePatterns() {
        for pattern in [nil, "0.00", "[Red]0;[Blue]0;0;\"t\"@", "M/d/yyyy", "@"] as [String?] {
            #expect(CellDisplay.text(for: .boolean(true), pattern: pattern) == DisplayText(text: "TRUE"))
            #expect(CellDisplay.text(for: .boolean(false), pattern: pattern) == DisplayText(text: "FALSE"))
            #expect(CellDisplay.text(for: .error(CellError(.divideByZero)), pattern: pattern) == DisplayText(text: "#DIV/0!"))
            #expect(CellDisplay.text(for: .empty, pattern: pattern) == DisplayText(text: ""))
        }
    }

    @Test func invalidPatternsFallBackToAutomatic() {
        for pattern in ["\"unterminated", "[Red", "0;0;0;0;0", "[>abc]0", "", "[<]0"] {
            #expect(shown(1234.5, pattern) == "1234.5")
            #expect(CellDisplay.text(for: .number(1234.5), pattern: pattern).color == nil)
            #expect(CellDisplay.text(for: .text("abc"), pattern: pattern).text == "abc")
        }
    }

    @Test func oddPatternsNeverCrash() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["0", "#", "?", ".", ",", "%", "E+", "e-", "/", "@", "*", "_", "\\", "\"", "[", "]", ";", "y", "m", "d", "h",
                      "s", "AM/PM", "A/P", "[h]", "[Red]", "[>5]", "General", "$", " ", "-", "(", ")", "1", "8", "00", "##"]
        let values: [Double] = [0, 1, -1, 0.5, -0.5, 1234.5678, -98765.4321, 1e-12, 1e15, 1e300, -1e300, 46024.62, 1e9,
                                .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNonzeroMagnitude]
        for _ in 0..<3000 {
            let length = Int.random(in: 1...8, using: &generator)
            let pattern = (0..<length).map { _ in pieces.randomElement(using: &generator)! }.joined()
            for value in values {
                _ = CellDisplay.text(for: .number(value), pattern: pattern)
            }
            _ = CellDisplay.text(for: .text("x"), pattern: pattern)
            _ = NumberFormatPresets.kind(of: pattern)
            _ = NumberFormatPresets.adjustingDecimals(pattern, by: 1, for: .number(1))
            _ = NumberFormatPresets.adjustingDecimals(pattern, by: -1, for: .number(1))
        }
        #expect(shown(.infinity, "0") == "#NUM!")
        #expect(shown(.nan, nil) == "#NUM!")
    }
}
