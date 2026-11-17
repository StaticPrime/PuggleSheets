import Foundation
import Testing
@testable import PuggleSheetsKit

/// Axis ticks and the text of tick, data and slice labels.
struct ChartTickTests {
    @Test func niceSteps() {
        #expect(ChartTicks.niceStep(atLeast: 0.3) == 0.5)
        #expect(ChartTicks.niceStep(atLeast: 46) == 50)
        #expect(ChartTicks.niceStep(atLeast: 1) == 1)
        #expect(ChartTicks.niceStep(atLeast: 2.2) == 2.5)
        #expect(ChartTicks.niceStep(atLeast: 7) == 10)
        #expect(ChartTicks.niceStep(atLeast: 0.0012) == 0.002)
        #expect(ChartTicks.niceStep(atLeast: 1_200_000) == 2_000_000)
        #expect(ChartTicks.previousNiceStep(5) == 2.5 && ChartTicks.previousNiceStep(2.5) == 2)
        #expect(ChartTicks.previousNiceStep(2) == 1 && ChartTicks.previousNiceStep(1) == 0.5)
    }

    @Test func linearScales() {
        let sales = ChartTicks.linear(lower: 0, upper: 230, intervals: 5)
        #expect(sales.lower == 0 && sales.upper == 250 && sales.step == 50)
        #expect(sales.ticks == [0, 50, 100, 150, 200, 250])

        // The step below the even split wins when it comes closer to the wanted count.
        let four = ChartTicks.linear(lower: 0, upper: 230, intervals: 4)
        #expect(four.step == 50 && four.upper == 250)

        let mixed = ChartTicks.linear(lower: -65, upper: 92, intervals: 4)
        #expect(mixed.ticks == [-100, -50, 0, 50, 100])

        let fractions = ChartTicks.linear(lower: 0, upper: 0.9, intervals: 4)
        #expect(fractions.ticks == [0, 0.25, 0.5, 0.75, 1])

        let tenths = ChartTicks.linear(lower: 0.1, upper: 0.7, intervals: 6)
        #expect(tenths.ticks == [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7])

        // All zero, and a single value.
        #expect(ChartTicks.linear(lower: 0, upper: 0, intervals: 5).ticks == [0, 0.2, 0.4, 0.6, 0.8, 1])
        let single = ChartTicks.linear(lower: 42, upper: 42, intervals: 5)
        #expect(single.lower < 42 && single.upper > 42)

        // A pinned minimum and maximum: ticks are the step's multiples between them.
        let pinned = ChartTicks.linear(lower: 0, upper: 230, intervals: 5, fixedLower: 100, fixedUpper: 200)
        #expect(pinned.lower == 100 && pinned.upper == 200)
        #expect(pinned.ticks == [100, 120, 140, 160, 180, 200])
        let pinnedLow = ChartTicks.linear(lower: 0, upper: 230, intervals: 5, fixedLower: -30)
        #expect(pinnedLow.lower == -30 && pinnedLow.ticks.first == 0 && pinnedLow.upper == 250)
    }

    @Test func scaleFractions() {
        let scale = ChartTicks.linear(lower: 0, upper: 230, intervals: 5)
        #expect(scale.fraction(125) == 0.5)
        #expect(scale.baseline == 0)
        let negative = ChartTicks.linear(lower: -80, upper: -20, intervals: 3)
        #expect(negative.baseline == negative.upper)
        let log = ChartTicks.logarithmic(lower: 12, upper: 4_200_000)
        #expect(log.fraction(-1) == nil && log.fraction(0) == nil)
        #expect(abs(log.fraction(1000)! - 2.0 / 6) < 1e-12)
        #expect(log.baseline == 10)
    }

    @Test func logScales() {
        let wide = ChartTicks.logarithmic(lower: 12, upper: 4_200_000)
        #expect(wide.lower == 10 && wide.upper == 10_000_000)
        #expect(wide.ticks == [10, 100, 1000, 10_000, 100_000, 1_000_000, 10_000_000])
        let narrow = ChartTicks.logarithmic(lower: 3, upper: 70)
        #expect(narrow.ticks == [1, 2, 5, 10, 20, 50, 100])
        // Nothing positive to show: one decade.
        let empty = ChartTicks.logarithmic(lower: -5, upper: 0)
        #expect(empty.lower == 1 && empty.upper == 10)
        let pinned = ChartTicks.logarithmic(lower: 12, upper: 900, fixedLower: 1)
        #expect(pinned.lower == 1 && pinned.upper == 1000)
    }

    @Test func alignedRightAxis() {
        let right = ChartTicks.aligned(lower: 0.21, upper: 0.36, intervals: 5)
        #expect(right.ticks.count == 6)
        #expect(right.lower <= 0.21 && right.upper >= 0.36)
        #expect(right.ticks == [0.2, 0.25, 0.3, 0.35, 0.4, 0.45])
        let counts = ChartTicks.aligned(lower: 0, upper: 7, intervals: 4)
        #expect(counts.ticks == [0, 2, 4, 6, 8])
    }

    @Test func percentAxes() {
        #expect(ChartTicks.percent(hasNegative: false, hasPositive: true).ticks == [0, 0.25, 0.5, 0.75, 1])
        #expect(ChartTicks.percent(hasNegative: true, hasPositive: true).ticks == [-1, -0.5, 0, 0.5, 1])
    }

    @Test func dateTicks() {
        let start = DateSerial.serial(year: 2024, month: 1, day: 1), end = DateSerial.serial(year: 2024, month: 12, day: 31)
        let (quarters, quarterPattern) = ChartTicks.dates(lower: start, upper: end, intervals: 4)
        #expect(quarterPattern == "MMM yyyy")
        #expect(quarters == [1, 4, 7, 10].map { DateSerial.serial(year: 2024, month: $0, day: 1) })

        let (years, yearPattern) = ChartTicks.dates(lower: start, upper: DateSerial.serial(year: 2030, month: 6, day: 1), intervals: 4)
        #expect(yearPattern == "yyyy")
        #expect(years == [2024, 2026, 2028, 2030].map { DateSerial.serial(year: $0, month: 1, day: 1) })

        let (days, dayPattern) = ChartTicks.dates(lower: start + 0.5, upper: start + 10, intervals: 5)
        #expect(dayPattern == nil)
        #expect(days == [start + 1, start + 3, start + 5, start + 7, start + 9])

        let (hours, hourPattern) = ChartTicks.dates(lower: start, upper: start + 0.5, intervals: 4)
        #expect(hourPattern == "h:mm AM/PM")
        #expect(hours.count == 5 && hours[1] == start + 3.0 / 24)
    }

    @Test func tickLabels() {
        // Automatic: as many decimals as the step needs, thousands grouped.
        #expect(ChartNumberText.tickLabels([0, 0.25, 0.5], step: 0.25, pattern: nil) == ["0.00", "0.25", "0.50"])
        #expect(ChartNumberText.tickLabels([0, 2500, 5000], step: 2500, pattern: nil) == ["0", "2,500", "5,000"])
        #expect(ChartNumberText.tickLabels([2000, 2005], step: 5, pattern: nil, grouping: false) == ["2000", "2005"])
        // Big numbers are shortened, keeping the currency.
        #expect(ChartNumberText.tickLabels([0, 10_000, 20_000], step: 10_000, pattern: nil) == ["0", "10K", "20K"])
        #expect(ChartNumberText.tickLabels([0, 1_500_000, 3_000_000], step: 1_500_000, pattern: "\"$\"#,##0.00") == ["$0", "$1.5M", "$3M"])
        #expect(ChartNumberText.tickLabels([-2_000_000_000, 0], step: 1, pattern: "#,##0") == ["-2B", "0"])
        // Under 10,000 the data's own format shows.
        #expect(ChartNumberText.tickLabels([0, 50], step: 50, pattern: "\"$\"#,##0.00") == ["$0.00", "$50.00"])
        // Percents, dates and scientific formats are never shortened.
        #expect(ChartNumberText.tickLabels([0, 0.5], step: 0.5, pattern: "0%") == ["0%", "50%"])
        let day = DateSerial.serial(year: 2026, month: 2, day: 14)
        #expect(ChartNumberText.tickLabels([day], step: 1, pattern: "M/d/yyyy") == ["2/14/2026"])
        #expect(ChartNumberText.tickLabels([20_000], step: 1, pattern: "0.00E+00") == ["2.00E+04"])
        // Accounting's padding is trimmed.
        #expect(ChartNumberText.text(5, pattern: NumberFormatPresets.accounting.pattern).hasPrefix("$"))
    }

    @Test func compactNumbers() {
        #expect(ChartNumberText.compact(999_999, prefix: "", suffix: "") == "1M")
        #expect(ChartNumberText.compact(1_250_000, prefix: "", suffix: "") == "1.25M")
        #expect(ChartNumberText.compact(12_500, prefix: "€", suffix: "") == "€12.5K")
        #expect(ChartNumberText.compact(-3e12, prefix: "", suffix: " kr") == "-3T kr")
        #expect(ChartNumberText.compact(0.5, prefix: "", suffix: "") == "0.5")
        #expect(ChartNumberText.affixes(of: "#,##0.00 \"€\"") == ("", " €"))
        #expect(ChartNumberText.affixes(of: "\"$\"#,##0") == ("$", ""))
    }

    @Test func sliceAndDataLabels() {
        #expect(ChartNumberText.percent(0.364) == "36.4%")
        #expect(ChartNumberText.percent(0.25) == "25%")
        #expect(ChartNumberText.percent(1) == "100%")
        #expect(ChartNumberText.percent(0.0004) == "0%")
        #expect(ChartNumberText.dataLabel(1234.5, pattern: "#,##0.0") == "1,234.5")
        #expect(ChartNumberText.dataLabel(0.125, pattern: nil) == "0.125")
    }
}
