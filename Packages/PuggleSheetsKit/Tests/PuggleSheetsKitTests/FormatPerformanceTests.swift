import Foundation
import Testing
@testable import PuggleSheetsKit

/// Display runs for every visible cell on every redraw. The limits are generous; run with
/// `swift test -c release` for meaningful numbers (debug builds get a much larger allowance).
struct FormatPerformanceTests {
    #if DEBUG
    static let allowance = 25.0
    #else
    static let allowance = 1.0
    #endif

    /// Average microseconds per call of `body`, from the fastest of five batches of `count / 5` calls,
    /// so tests running in parallel can't make a slow batch fail the check.
    func microseconds(_ count: Int, _ body: (Int) -> Void) -> Double {
        let clock = ContinuousClock()
        let batch = max(1, count / 5)
        var best = Double.infinity
        for round in 0..<5 {
            let elapsed = clock.measure {
                for index in 0..<batch { body(round * batch + index) }
            }
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            best = min(best, seconds / Double(batch) * 1e6)
        }
        return best
    }

    @Test func cachedPatternsFormatQuickly() {
        let patterns: [String?] = [nil, "#,##0.00", "0.00%", "\"$\"#,##0.00", "M/d/yyyy", "h:mm:ss AM/PM", "0.00E+00",
                                   NumberFormatPresets.accounting.pattern, "[h]:mm:ss", "# ?/?"]
        let values = (0..<1000).map { CellValue.number(Double($0) * 1234.5678 - 50_000 + 1.0 / Double($0 + 3)) }
        for pattern in patterns { _ = CellDisplay.text(for: values[0], pattern: pattern) }

        var characters = 0
        for pattern in patterns {
            let perCall = microseconds(20_000) { index in
                characters &+= CellDisplay.text(for: values[index % values.count], pattern: pattern).text.utf8.count
            }
            #expect(perCall < 2 * Self.allowance, "\(pattern ?? "Automatic"): \(perCall) µs per call")
        }
        #expect(characters > 0)
    }

    @Test func parsingTypedInputIsQuick() {
        let inputs = ["1234", "1,234.56", "12%", "$5.50", "1/2/2026", "13:45", "hello world", "TRUE", "Jan 2, 2026", "=A1+1"]
        var count = 0
        let perCall = microseconds(20_000) { index in
            if case .number = InputParser.parse(inputs[index % inputs.count], currentFormat: nil).value { count += 1 }
        }
        #expect(perCall < 10 * Self.allowance, "\(perCall) µs per parse")
        #expect(count > 0)
    }

    @Test func formattingIsSafeFromManyThreads() async {
        let total = await withTaskGroup(of: Int.self) { group in
            for task in 0..<8 {
                group.addTask {
                    var characters = 0
                    for index in 0..<3000 {
                        // Distinct patterns keep the shared cache inserting while other tasks read it.
                        let pattern = "#,##0." + String(repeating: "0", count: (index + task) % 9) + ";[Red]-0.0"
                        characters += CellDisplay.text(for: .number(Double(index) - 1500.5), pattern: pattern).text.count
                    }
                    return characters
                }
            }
            var sum = 0
            for await characters in group { sum += characters }
            return sum
        }
        #expect(total > 0)
    }
}
