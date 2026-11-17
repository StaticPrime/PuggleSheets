import Foundation

/// An axis' range and the values its gridlines and labels sit at.
struct ChartScale: Sendable {
    var lower: Double
    var upper: Double
    var ticks: [Double]
    /// The distance between ticks on linear scales; 0 on log scales.
    var step: Double
    var isLog: Bool
    private let logLower: Double
    private let logSpan: Double

    init(lower: Double, upper: Double, ticks: [Double], step: Double, isLog: Bool = false) {
        self.lower = lower
        self.upper = upper
        self.ticks = ticks
        self.step = step
        self.isLog = isLog
        if isLog {
            logLower = Foundation.log10(lower)
            logSpan = Swift.max(1e-12, Foundation.log10(upper) - logLower)
        } else {
            logLower = 0
            logSpan = 1
        }
    }

    /// Where `value` falls between the ends: 0 at `lower`, 1 at `upper`. Nil for values a log scale can't show.
    @inline(__always) func fraction(_ value: Double) -> Double? {
        if isLog {
            guard value > 0 else { return nil }
            return (Foundation.log10(value) - logLower) / logSpan
        }
        let span = upper - lower
        return span == 0 ? 0.5 : (value - lower) / span
    }

    /// Where bars and areas start: zero, or the end of the axis nearest to it.
    var baseline: Double {
        if isLog { return lower }
        return Swift.min(Swift.max(0, lower), upper)
    }
}

/// "Nice" axis ticks: steps of 1, 2, 2.5 or 5 times a power of ten.
enum ChartTicks {
    static let mantissas: [Double] = [1, 2, 2.5, 5, 10]

    /// The smallest nice step that is at least `raw`.
    static func niceStep(atLeast raw: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return 1 }
        let power = pow(10, (log10(raw)).rounded(.down))
        for mantissa in mantissas where mantissa * power >= raw * (1 - 1e-12) {
            return mantissa * power
        }
        return 10 * power
    }

    /// Ticks covering `lower...upper` in about `intervals` nice steps. `fixedLower` and `fixedUpper` pin
    /// the ends (the axis minimum and maximum); ticks then fall on multiples of the step between them.
    static func linear(lower dataLower: Double, upper dataUpper: Double, intervals: Int,
                       fixedLower: Double? = nil, fixedUpper: Double? = nil) -> ChartScale {
        var low = fixedLower ?? dataLower
        var high = fixedUpper ?? dataUpper
        if !low.isFinite || !high.isFinite { (low, high) = (0, 1) }
        if low > high {
            if fixedLower != nil, fixedUpper == nil { high = low } else if fixedUpper != nil, fixedLower == nil { low = high } else { swap(&low, &high) }
        }
        if high - low <= Swift.max(abs(low), abs(high)) * 1e-12 {
            // One value: give it room around it.
            let room = low == 0 ? 1 : abs(low) * 0.1
            switch (fixedLower, fixedUpper) {
            case (nil, nil):
                if low == 0 { high = 1 } else { low -= room; high += room }
            case (_, nil): high = low + room
            case (nil, _): low = high - room
            default: high = low + room
            }
        }
        // The nice step at or above the even split, or the one below it when that comes closer to
        // the wanted number of intervals (ties go to the tighter fit).
        let target = Swift.max(1, intervals)
        let above = niceStep(atLeast: (high - low) / Double(target))
        let below = previousNiceStep(above)
        func span(_ step: Double) -> (count: Double, size: Double) {
            let first = fixedLower.map { $0 / step } ?? (low / step + 1e-9).rounded(.down)
            let last = fixedUpper.map { $0 / step } ?? (high / step - 1e-9).rounded(.up)
            return (last - first, (last - first) * step)
        }
        let (aboveSpan, belowSpan) = (span(above), span(below))
        let aboveMiss = abs(aboveSpan.count - Double(target)), belowMiss = abs(belowSpan.count - Double(target))
        let step = belowMiss < aboveMiss || (belowMiss == aboveMiss && belowSpan.size < aboveSpan.size - 1e-9 * above) ? below : above
        let lower = fixedLower ?? ((low / step + 1e-9).rounded(.down) * step)
        let upper = fixedUpper ?? ((high / step - 1e-9).rounded(.up) * step)
        return ChartScale(lower: lower, upper: upper, ticks: multiples(of: step, from: lower, to: upper), step: step)
    }

    /// The nice step just below `step` (itself nice): 5 → 2.5, 2.5 → 2, 2 → 1, 1 → 0.5.
    static func previousNiceStep(_ step: Double) -> Double {
        guard step.isFinite, step > 0 else { return 1 }
        let power = pow(10, (log10(step) + 1e-9).rounded(.down))
        let mantissa = step / power
        if mantissa > 4.9 { return 2.5 * power }
        if mantissa > 2.4 { return 2 * power }
        if mantissa > 1.9 { return power }
        return 0.5 * power
    }

    /// A scale with exactly `intervals` nice steps covering `lower...upper`, for a right axis whose
    /// gridlines line up with the left axis'.
    static func aligned(lower dataLower: Double, upper dataUpper: Double, intervals: Int) -> ChartScale {
        var low = dataLower, high = dataUpper
        if !low.isFinite || !high.isFinite { (low, high) = (0, 1) }
        if high - low <= Swift.max(abs(low), abs(high)) * 1e-12 {
            if low == 0 { high = 1 } else { high = low + abs(low) * 0.1 }
        }
        let count = Swift.max(1, intervals)
        var step = niceStep(atLeast: (high - low) / Double(count))
        for _ in 0..<64 {
            let lower = (low / step + 1e-9).rounded(.down) * step
            if lower + Double(count) * step >= high - step * 1e-9 {
                let decimals = self.decimals(of: step)
                let ticks = (0...count).map { rounded(lower + Double($0) * step, decimals: decimals) }
                return ChartScale(lower: lower, upper: lower + Double(count) * step, ticks: ticks, step: step)
            }
            step = niceStep(atLeast: step * (1 + 1e-9))
        }
        return linear(lower: low, upper: high, intervals: count)
    }

    /// A log scale from a power of ten to a power of ten, with ticks at the powers of ten (and at 2
    /// and 5 times them when the range spans two decades or fewer). Values at or below zero can't be shown.
    static func logarithmic(lower dataLower: Double, upper dataUpper: Double, fixedLower: Double? = nil,
                            fixedUpper: Double? = nil) -> ChartScale {
        let pinnedLower = fixedLower.flatMap { $0 > 0 ? $0 : nil }
        let pinnedUpper = fixedUpper.flatMap { $0 > 0 ? $0 : nil }
        var low = pinnedLower ?? dataLower
        var high = pinnedUpper ?? dataUpper
        if !(low > 0) || !low.isFinite { low = high > 0 && high.isFinite ? high / 10 : 1 }
        if !(high > 0) || !high.isFinite || high < low { high = low * 10 }
        let firstPower = (log10(low) + 1e-9).rounded(.down)
        var lastPower = (log10(high) - 1e-9).rounded(.up)
        if lastPower <= firstPower { lastPower = firstPower + 1 }
        let lower = pinnedLower ?? pow(10, firstPower)
        let upper = pinnedUpper ?? pow(10, lastPower)
        let decades = Int(lastPower - firstPower)
        let factors: [Double] = decades <= 2 ? [1, 2, 5] : [1]
        let every = Swift.max(1, Int((Double(decades) / 8).rounded(.up)))
        var ticks: [Double] = []
        for decade in 0...decades where decade % every == 0 {
            let power = pow(10, firstPower + Double(decade))
            for factor in factors {
                let value = factor * power
                if value >= lower * (1 - 1e-9), value <= upper * (1 + 1e-9) { ticks.append(value) }
            }
        }
        return ChartScale(lower: lower, upper: upper, ticks: ticks, step: 0, isLog: true)
    }

    /// The axis of a 100% chart: 0 to 100% in quarters (or −100% to 100% in halves with negative values).
    static func percent(hasNegative: Bool, hasPositive: Bool) -> ChartScale {
        switch (hasNegative, hasPositive) {
        case (true, true): return ChartScale(lower: -1, upper: 1, ticks: [-1, -0.5, 0, 0.5, 1], step: 0.5)
        case (true, false): return ChartScale(lower: -1, upper: 0, ticks: [-1, -0.75, -0.5, -0.25, 0], step: 0.25)
        default: return ChartScale(lower: 0, upper: 1, ticks: [0, 0.25, 0.5, 0.75, 1], step: 0.25)
        }
    }

    /// Multiples of `step` from `lower` to `upper`, rounded to the step's decimals.
    static func multiples(of step: Double, from lower: Double, to upper: Double) -> [Double] {
        guard step > 0, step.isFinite, upper >= lower else { return [] }
        let decimals = self.decimals(of: step)
        var ticks: [Double] = []
        var index = (lower / step - 1e-9).rounded(.up)
        while index * step <= upper + step * 1e-9, ticks.count < 1000 {
            ticks.append(rounded(index * step, decimals: decimals))
            index += 1
        }
        return ticks
    }

    /// The decimals needed to write multiples of `step` exactly (0.25 → 2).
    static func decimals(of step: Double) -> Int {
        guard step > 0, step.isFinite else { return 0 }
        var decimals = 0
        var scaled = step
        while decimals < 12, abs(scaled - scaled.rounded()) > 1e-6 * Swift.max(1, abs(scaled)) {
            scaled *= 10
            decimals += 1
        }
        return decimals
    }

    static func rounded(_ value: Double, decimals: Int) -> Double {
        guard decimals > 0 else { return value.rounded() == 0 ? 0 : value.rounded() }
        let factor = pow(10, Double(decimals))
        let result = (value * factor).rounded() / factor
        return result == 0 ? 0 : result
    }

    // MARK: Dates

    /// Ticks on calendar boundaries between the serials `lower` and `upper`, about `intervals` apart:
    /// minutes or hours, days or weeks, months (1, 2, 3, 6) or years. Also the pattern the labels use:
    /// nil means the data's own format (day steps), others name the unit ("MMM yyyy", "yyyy").
    static func dates(lower: Double, upper: Double, intervals: Int) -> (ticks: [Double], pattern: String?) {
        let span = upper - lower
        guard span > 0, span.isFinite else { return ([lower], nil) }
        let raw = span / Double(Swift.max(1, intervals))
        if raw < 1 {
            let steps = [1.0, 2, 5, 10, 15, 30].map { $0 / 1440 } + [1.0, 2, 3, 6, 12].map { $0 / 24 }
            if let step = steps.first(where: { $0 >= raw * (1 - 1e-9) }) {
                let ticks = multiples(of: step, from: lower, to: upper).map { ($0 * 1440).rounded() / 1440 }
                if ticks.count >= 2 { return (ticks, "h:mm AM/PM") }
            }
        }
        if raw <= 14 {
            let step = [1.0, 2, 7, 14].first { $0 >= raw * (1 - 1e-9) } ?? 14
            var ticks: [Double] = []
            var day = (lower - 1e-9).rounded(.up)
            while day <= upper + 1e-9, ticks.count < 1000 {
                ticks.append(day)
                day += step
            }
            if ticks.count >= 2 { return (ticks, nil) }
        }
        if raw <= 183 {
            let step = [1, 2, 3, 6].first { Double($0) * 30.44 >= raw * (1 - 1e-9) } ?? 6
            let ticks = monthStarts(from: lower, to: upper, every: step)
            if ticks.count >= 2 { return (ticks, "MMM yyyy") }
        }
        let rawYears = raw / 365.25
        let yearStep = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000].first { Double($0) >= rawYears * (1 - 1e-9) } ?? 1000
        let years = monthStarts(from: lower, to: upper, every: 12 * yearStep)
        if years.count >= 2 { return (years, "yyyy") }
        // Too short a span for the unit: plain nice numbers in the data's format.
        let scale = linear(lower: lower, upper: upper, intervals: intervals)
        return (scale.ticks.filter { $0 >= lower - 1e-9 && $0 <= upper + 1e-9 }, nil)
    }

    /// The first days of months between two serials, every `months` months, aligned to multiples of
    /// the step (quarters start in January, April, July and October).
    static func monthStarts(from lower: Double, to upper: Double, every months: Int) -> [Double] {
        let step = Swift.max(1, months)
        let parts = DateSerial.parts(of: lower)
        var index = parts.year * 12 + (parts.month - 1)
        if DateSerial.serial(year: parts.year, month: parts.month, day: 1) < lower - 1e-9 { index += 1 }
        let remainder = ((index % step) + step) % step
        if remainder != 0 { index += step - remainder }
        var ticks: [Double] = []
        while ticks.count < 1000 {
            let year = Int((Double(index) / 12).rounded(.down))
            let month = index - year * 12 + 1
            let serial = DateSerial.serial(year: year, month: month, day: 1)
            if serial > upper + 1e-9 { break }
            ticks.append(serial)
            index += step
        }
        return ticks
    }
}
