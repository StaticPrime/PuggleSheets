import CoreGraphics
import Foundation

/// Charts with axes: columns and bars (clustered, stacked, 100%), lines (straight or smooth), areas
/// (plain, stacked, 100%), scatter and combo charts.
///
/// Layout: value labels right-aligned left of the plot (a right axis' left-aligned
/// at its right), category labels centered under their slots (tilted 30° when text labels don't
/// fit, thinned to every n-th when even that doesn't work), gridlines at the value ticks and a dark
/// line at zero. Line and area charts whose labels are ordered numbers or dates get a continuous
/// horizontal axis with nice ticks; scatter charts always do when their labels are numbers.
///
/// Series with `usesRightAxis` get a right axis whose ticks line up with the left gridlines; stacked,
/// 100% and bar charts keep every series on one axis. Runs of more than two points per pixel column
/// are drawn from per-column envelopes, which look the same and stay fast with thousands of points.
extension ChartComposer {
    enum Mark { case column, line, area, scatter }
    enum Stacking { case none, stacked, percent }

    struct PlotSeries {
        var index: Int
        var name: String
        var color: ChartColor
        var mark: Mark
        var right: Bool
        var lineWidth: Double
        var pointSize: Double
        var smooth: Bool
        var dataLabels: Bool
        var format: String?
        /// The values as given; data labels show these.
        var values: [Double?]
        /// Where each mark ends: the value, or the running total (a share for 100% charts) when stacked.
        var tops: [Double?]
        /// Where stacked marks start; nil when not stacked.
        var bases: [Double]?
    }

    enum XMode {
        case categories
        /// Positions by label value from `lower` to `upper`; `nice` widens the ends to nice ticks.
        case continuous(lower: Double, upper: Double, isDate: Bool, nice: Bool)
    }

    /// The horizontal axis' labels: categories (with thinning and tilt) or ticks of a continuous axis.
    struct XPlan {
        var height = 0.0
        var every = 1
        var slanted = false
        var maxTextWidth = 0.0
        var ticks: [Double] = []
        var labels: [String] = []
        var lower = 0.0
        var upper = 1.0
    }

    static let slantAngle = -30.0

    // MARK: Entry point

    mutating func composeCartesian(_ titles: ChartTitleBlock) {
        let kind = spec.kind
        let horizontal = kind == .bar || kind == .stackedBar || kind == .percentBar
        let stacking: Stacking
        switch kind {
        case .stackedColumn, .stackedBar, .stackedArea: stacking = .stacked
        case .percentColumn, .percentBar, .percentArea: stacking = .percent
        default: stacking = .none
        }
        let series = plotSeries(horizontal: horizontal, stacking: stacking)
        var frame = ChartFrame(left: style.padding, top: titles.bottom, right: width - style.padding, bottom: height - style.padding)
        let entries = series.map { ChartLegendEntry(text: $0.name, color: $0.color) }
        let legend = reserveLegend(entries, placement: legendPlacement(entryCount: entries.count, pie: false), frame: &frame)

        let axisMetrics = engine.metrics(style.axisTitleFont)
        let horizontalTitle = ChartData.oneLine(spec.horizontalAxisTitle.trimmingCharacters(in: .whitespacesAndNewlines))
        let verticalTitle = ChartData.oneLine(spec.verticalAxisTitle.trimmingCharacters(in: .whitespacesAndNewlines))
        var horizontalTitleBaseline = 0.0
        var verticalTitleX = 0.0
        if !horizontalTitle.isEmpty {
            horizontalTitleBaseline = frame.bottom - axisMetrics.descent
            frame.bottom -= axisMetrics.height + style.labelGap
        }
        if !verticalTitle.isEmpty {
            verticalTitleX = frame.left + axisMetrics.ascent
            frame.left += axisMetrics.height + style.labelGap
        }
        // The top value label sticks out half a line above the plot.
        if titles.isEmpty, legend?.placement != .top {
            frame.top = Swift.max(frame.top, style.padding + engine.metrics(style.labelFont).height / 2)
        }

        let plot = horizontal ? composeBars(series, stacking: stacking, frame: frame) : composeVertical(series, stacking: stacking, frame: frame)

        if !horizontalTitle.isEmpty {
            let text = engine.truncated(horizontalTitle, style.axisTitleFont, maxWidth: width - 2 * style.padding)
            let half = engine.width(text, style.axisTitleFont) / 2
            let x = Swift.min(Swift.max(Double(plot.midX), style.padding + half), width - style.padding - half)
            scene.text(ChartText(string: text, font: style.axisTitleFont, color: style.axisTitleColor, x: x, y: horizontalTitleBaseline, anchor: .middle))
        }
        if !verticalTitle.isEmpty {
            let text = engine.truncated(verticalTitle, style.axisTitleFont, maxWidth: Swift.max(Double(plot.height) + 40, height * 0.8))
            scene.text(ChartText(string: text, font: style.axisTitleFont, color: style.axisTitleColor,
                                 x: verticalTitleX, y: Double(plot.midY), anchor: .middle, angle: -90))
        }
        if let legend { emitLegend(legend, plot: plot, centered: legend.placement == .bottom) }
        emitTitles(titles, x: Double(plot.minX))
    }

    // MARK: Series

    func plotSeries(horizontal: Bool, stacking: Stacking) -> [PlotSeries] {
        var result: [PlotSeries] = []
        for (index, series) in data.series.enumerated() {
            let seriesStyle = spec.style(ofSeries: index)
            let mark: Mark
            switch spec.kind {
            case .line, .smoothLine: mark = .line
            case .area, .stackedArea, .percentArea: mark = .area
            case .scatter: mark = .scatter
            case .combo:
                switch seriesStyle.type {
                case .column?: mark = .column
                case .line?: mark = .line
                case .area?: mark = .area
                case nil: mark = index == 0 ? .column : .line
                }
            default: mark = .column
            }
            let defaultPoint = mark == .scatter ? 7.0 : 0
            let defaultLine = mark == .scatter ? 0.0 : 2
            result.append(PlotSeries(
                index: index, name: series.name, color: ChartColor(ChartBuilder.color(ofSeries: index, in: spec)), mark: mark,
                right: seriesStyle.usesRightAxis && !horizontal && stacking == .none,
                lineWidth: Swift.max(0, Swift.min(seriesStyle.lineWidth ?? defaultLine, 40)),
                pointSize: Swift.max(0, Swift.min(seriesStyle.pointSize ?? defaultPoint, 60)),
                smooth: spec.kind == .smoothLine, dataLabels: seriesStyle.showsDataLabels ?? spec.showsDataLabels,
                format: series.numberFormat, values: series.values, tops: series.values, bases: nil))
        }
        // With every series on the right axis there's nothing for the left one: use a single axis.
        if !result.isEmpty, result.allSatisfy(\.right) {
            for index in result.indices { result[index].right = false }
        }
        if stacking != .none { stack(&result, percent: stacking == .percent) }
        return result
    }

    /// Stacks the series in order: columns and bars stack positive and negative values apart, areas
    /// keep one running total and treat gaps as zero. 100% charts stack shares of each label's total.
    func stack(_ series: inout [PlotSeries], percent: Bool) {
        let count = data.count
        var positive = [Double](repeating: 0, count: count)
        var negative = [Double](repeating: 0, count: count)
        var totals = [Double](repeating: 0, count: count)
        if percent {
            for item in series {
                for index in 0..<count { if let value = item.values[index] { totals[index] += abs(value) } }
            }
        }
        for seriesIndex in series.indices {
            let areas = series[seriesIndex].mark == .area
            var bases = [Double](repeating: 0, count: count)
            var tops = [Double?](repeating: nil, count: count)
            for index in 0..<count {
                guard var value = series[seriesIndex].values[index] ?? (areas ? 0 : nil) else {
                    bases[index] = positive[index]
                    continue
                }
                if percent { value = totals[index] > 0 ? value / totals[index] : 0 }
                if areas || value >= 0 {
                    bases[index] = positive[index]
                    positive[index] += value
                    tops[index] = positive[index]
                } else {
                    bases[index] = negative[index]
                    negative[index] += value
                    tops[index] = negative[index]
                }
            }
            series[seriesIndex].bases = bases
            series[seriesIndex].tops = tops
        }
    }

    /// The values an axis must show. Columns, bars and areas include zero; lines and scatter points
    /// include it when the data comes within its own spread of it.
    func valueRange(_ series: [PlotSeries], right: Bool, log: Bool, stacking: Stacking) -> (low: Double, high: Double)? {
        var low = Double.infinity, high = -Double.infinity
        var needsZero = stacking != .none
        for item in series where item.right == right {
            if item.mark == .column || item.mark == .area { needsZero = true }
            for index in 0..<data.count {
                guard let top = item.tops[index] else { continue }
                if !log || top > 0 {
                    low = Swift.min(low, top)
                    high = Swift.max(high, top)
                }
                if let bases = item.bases, !log || bases[index] > 0 {
                    low = Swift.min(low, bases[index])
                    high = Swift.max(high, bases[index])
                }
            }
        }
        guard low <= high else { return nil }
        if log { return (low, high) }
        if needsZero {
            low = Swift.min(low, 0)
            high = Swift.max(high, 0)
        } else {
            let spread = high - low
            if low > 0, low <= spread { low = 0 } else if high < 0, -high <= spread { high = 0 }
        }
        return (low, high)
    }

    func valueScale(_ range: (low: Double, high: Double)?, intervals: Int, log: Bool, stacking: Stacking, pinned: Bool) -> ChartScale {
        if stacking == .percent {
            return ChartTicks.percent(hasNegative: (range?.low ?? 0) < -1e-12, hasPositive: (range?.high ?? 1) > 1e-12 || (range?.low ?? 0) >= 0)
        }
        let fixedLower = pinned ? spec.verticalMinimum.flatMap { $0.isFinite ? $0 : nil } : nil
        let fixedUpper = pinned ? spec.verticalMaximum.flatMap { $0.isFinite ? $0 : nil } : nil
        if log {
            return ChartTicks.logarithmic(lower: range?.low ?? 1, upper: range?.high ?? 10, fixedLower: fixedLower, fixedUpper: fixedUpper)
        }
        return ChartTicks.linear(lower: range?.low ?? 0, upper: range?.high ?? 1, intervals: intervals, fixedLower: fixedLower, fixedUpper: fixedUpper)
    }

    func valueLabels(_ scale: ChartScale, format: String?, stacking: Stacking) -> [String] {
        if stacking == .percent { return scale.ticks.map { ChartNumberText.text($0, pattern: "0%") } }
        return ChartNumberText.tickLabels(scale.ticks, step: scale.step, pattern: format)
    }

    /// The number format of the first series on an axis that has one.
    func axisFormat(_ series: [PlotSeries], right: Bool) -> String? {
        series.first { $0.right == right && $0.format != nil }?.format
    }

    var labelsAreDates: Bool {
        switch NumberFormatPresets.kind(of: data.labelFormat) {
        case .date, .dateTime, .time: return true
        default: return false
        }
    }

    /// Text labels (not numbers or dates) may tilt; numeric ones only thin out, like an axis.
    var labelsAreText: Bool {
        guard spec.firstColumnIsLabels else { return false }
        for index in 0..<data.count where data.labelValues[index] == nil && !data.labels[index].isEmpty { return true }
        return false
    }

    func xMode() -> XMode {
        let count = data.count
        guard count > 0 else { return .categories }
        switch spec.kind {
        case .scatter:
            var low = Double.infinity, high = -Double.infinity
            for index in 0..<count {
                if let value = data.labelValues[index] {
                    low = Swift.min(low, value)
                    high = Swift.max(high, value)
                } else if !data.labels[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    return .categories
                }
            }
            guard low <= high else { return .categories }
            if low == high { (low, high) = (low - 1, high + 1) }
            return .continuous(lower: low, upper: high, isDate: labelsAreDates, nice: !labelsAreDates)
        case .line, .smoothLine, .area, .stackedArea, .percentArea:
            guard spec.firstColumnIsLabels, count >= 2 else { return .categories }
            var rising = true, falling = true
            var previous: Double?
            for value in data.labelValues {
                guard let value else { return .categories }
                if let previous {
                    if value < previous { rising = false }
                    if value > previous { falling = false }
                }
                previous = value
            }
            guard rising || falling, let first = data.labelValues.first ?? nil, let last = data.labelValues.last ?? nil, first != last else {
                return .categories
            }
            return .continuous(lower: Swift.min(first, last), upper: Swift.max(first, last), isDate: labelsAreDates, nice: false)
        default:
            return .categories
        }
    }

    // MARK: Columns, lines, areas, scatter

    private mutating func composeVertical(_ series: [PlotSeries], stacking: Stacking, frame: ChartFrame) -> CGRect {
        let count = data.count
        let labelFont = style.labelFont
        let metrics = engine.metrics(labelFont)
        let gap = style.labelGap
        let log = spec.logScale && stacking != .percent
        let hasRight = series.contains(where: \.right)
        let mode = xMode()
        let leftFormat = axisFormat(series, right: false)
        let rightFormat = axisFormat(series, right: true)
        let leftRange = valueRange(series, right: false, log: log, stacking: stacking)
        let rightRange = hasRight ? valueRange(series, right: true, log: log, stacking: stacking) : nil

        let plotTop = frame.top
        var plotBottom = frame.bottom - (metrics.height + gap)
        var plotLeft = frame.left, plotRight = frame.right
        var leftScale = ChartTicks.linear(lower: 0, upper: 1, intervals: 5)
        var rightScale: ChartScale?
        var leftLabels: [String] = [], rightLabels: [String] = []
        var plan = XPlan()
        for pass in 0..<3 {
            let plotHeight = Swift.max(8, plotBottom - plotTop)
            let intervals = Swift.max(2, Swift.min(10, Int((plotHeight / (56 * style.scale)).rounded())))
            leftScale = valueScale(leftRange, intervals: intervals, log: log, stacking: stacking, pinned: true)
            leftLabels = valueLabels(leftScale, format: leftFormat, stacking: stacking)
            let leftWidth = leftLabels.reduce(0) { Swift.max($0, engine.width($1, labelFont)) }
            plotLeft = frame.left + (leftWidth > 0 ? leftWidth + gap : 0)
            if hasRight {
                let scale: ChartScale
                if log {
                    scale = valueScale(rightRange, intervals: intervals, log: true, stacking: stacking, pinned: false)
                } else {
                    scale = ChartTicks.aligned(lower: rightRange?.low ?? 0, upper: rightRange?.high ?? 1, intervals: Swift.max(1, leftScale.ticks.count - 1))
                }
                rightLabels = valueLabels(scale, format: rightFormat, stacking: stacking)
                let rightWidth = rightLabels.reduce(0) { Swift.max($0, engine.width($1, labelFont)) }
                plotRight = frame.right - (rightWidth > 0 ? rightWidth + gap : 0)
                rightScale = scale
            }
            plan = planX(mode, plotWidth: Swift.max(1, plotRight - plotLeft), maxHeight: height * 0.3)
            let bottom = frame.bottom - (plan.height > 0 ? plan.height + gap : 0)
            let settled = abs(bottom - plotBottom) < 0.5
            plotBottom = bottom
            if settled || pass == 2 { break }
        }

        let plot = CGRect(x: plotLeft, y: plotTop, width: Swift.max(1, plotRight - plotLeft), height: Swift.max(1, plotBottom - plotTop))
        let minX = Double(plot.minX), maxX = Double(plot.maxX), minY = Double(plot.minY), maxY = Double(plot.maxY)
        let plotWidth = Double(plot.width), plotHeight = Double(plot.height)
        func y(_ value: Double, _ scale: ChartScale) -> Double? {
            scale.fraction(value).map { maxY - $0 * plotHeight }
        }
        let slot = plotWidth / Double(Swift.max(1, count))
        let continuous: Bool
        let xSpan = plan.upper - plan.lower
        if case .continuous = mode { continuous = true } else { continuous = false }
        let labelValues = data.labelValues
        let xLower = plan.lower
        func x(_ index: Int) -> Double? {
            if continuous {
                guard let value = labelValues[index] else { return nil }
                return minX + (value - xLower) / (xSpan == 0 ? 1 : xSpan) * plotWidth
            }
            return minX + (Double(index) + 0.5) * slot
        }

        // Gridlines, at the left axis' ticks (and the x ticks of scatter charts).
        if spec.showsGridlines {
            let path = CGMutablePath()
            for tick in leftScale.ticks {
                if let position = y(tick, leftScale), position >= minY - 0.5, position <= maxY + 0.5 {
                    path.addRect(CGRect(x: minX, y: (position - 0.5).rounded(), width: plotWidth, height: 1))
                }
            }
            if continuous, spec.kind == .scatter {
                for tick in plan.ticks {
                    let position = minX + (tick - plan.lower) / (xSpan == 0 ? 1 : xSpan) * plotWidth
                    if position >= minX - 0.5, position <= maxX + 0.5 {
                        path.addRect(CGRect(x: (position - 0.5).rounded(), y: minY, width: 1, height: plotHeight))
                    }
                }
            }
            scene.fill(path, style.gridlineColor)
        }

        let pinned = spec.verticalMinimum != nil || spec.verticalMaximum != nil || log
        if pinned { scene.clip(plot.insetBy(dx: -12, dy: -1)) }
        let scaleOf = { (item: PlotSeries) -> ChartScale in item.right ? (rightScale ?? leftScale) : leftScale }

        // Areas under everything, then columns, the zero line, lines and points.
        let areas = series.filter { $0.mark == .area }.map { areaPaths($0, scale: scaleOf($0), x: x, y: y, plotWidth: plotWidth) }
        for (item, paths) in areas { scene.fill(paths.fill, item.color.opacity(ChartStyle.areaOpacity)) }
        for (item, paths) in areas {
            scene.stroke(paths.line, item.color, width: item.lineWidth)
            if item.lineWidth > 0 { scene.fill(paths.denseLine, item.color) }
        }
        let columns = series.filter { $0.mark == .column }
        let groups = stacking == .none ? columns.count : 1
        let groupWidth = slot * ChartStyle.groupWidth
        let barWidth = Swift.max(groupWidth / Double(Swift.max(1, groups)), Swift.min(1, slot))
        func columnCenter(_ order: Int, _ index: Int) -> Double {
            let start = minX + (Double(index) + 0.5) * slot
            if stacking != .none || groups <= 1 { return start }
            return start - groupWidth / 2 + (Double(order) + 0.5) * barWidth
        }
        for (order, item) in columns.enumerated() {
            let scale = scaleOf(item)
            let path = CGMutablePath()
            var pending: CGRect?
            var pendingBucket = Int.min
            let decimate = slot < 1
            for index in 0..<count {
                guard let top = item.tops[index], let yTop = y(top, scale) else { continue }
                let base = item.bases?[index] ?? scale.baseline
                let yBase = y(base, scale) ?? maxY
                var left = columnCenter(order, index) - barWidth / 2
                var right = left + barWidth
                if barWidth >= 2 {
                    left = left.rounded()
                    right = Swift.max(left + 1, right.rounded())
                }
                let rect = CGRect(x: left, y: Swift.min(yTop, yBase), width: right - left, height: abs(yTop - yBase))
                if decimate {
                    let bucket = Int(left.rounded(.down))
                    if bucket == pendingBucket, let current = pending {
                        pending = current.union(rect)
                        continue
                    }
                    if let current = pending { path.addRect(current) }
                    pending = rect
                    pendingBucket = bucket
                } else {
                    path.addRect(rect)
                }
            }
            if let pending { path.addRect(pending) }
            scene.fill(path, item.color)
        }
        if !log, let zero = y(0, leftScale), leftScale.lower <= 0, leftScale.upper >= 0 {
            scene.fill(CGRect(x: minX, y: (zero - 0.5).rounded(), width: plotWidth, height: 1), style.baselineColor)
        }
        if continuous, spec.kind == .scatter, !labelsAreDates, plan.lower <= 0, plan.upper >= 0, xSpan > 0 {
            let zero = minX + (0 - plan.lower) / xSpan * plotWidth
            scene.fill(CGRect(x: (zero - 0.5).rounded(), y: minY, width: 1, height: plotHeight), style.baselineColor)
        }
        for item in series where item.mark == .line || item.mark == .scatter {
            drawLine(item, scale: scaleOf(item), x: x, y: y, plotWidth: plotWidth)
        }
        if pinned { scene.endClip() }

        // Data labels.
        for item in series where item.dataLabels {
            let scale = scaleOf(item)
            let order = columns.firstIndex { $0.index == item.index } ?? 0
            emitVerticalDataLabels(item, scale: scale, stacked: stacking != .none, barWidth: barWidth,
                                   x: { item.mark == .column ? columnCenter(order, $0) : x($0) }, y: y, plot: plot)
        }

        // Value labels.
        for (index, tick) in leftScale.ticks.enumerated() {
            guard let position = y(tick, leftScale), position >= minY - 0.5, position <= maxY + 0.5 else { continue }
            scene.text(ChartText(string: leftLabels[index], font: labelFont, color: style.verticalLabelColor,
                                 x: minX - gap, y: position + metrics.middle, anchor: .end))
        }
        if let rightScale {
            for (index, tick) in rightScale.ticks.enumerated() {
                guard let position = y(tick, rightScale), position >= minY - 0.5, position <= maxY + 0.5 else { continue }
                scene.text(ChartText(string: rightLabels[index], font: labelFont, color: style.verticalLabelColor,
                                     x: maxX + gap, y: position + metrics.middle))
            }
        }

        // Horizontal axis labels.
        if continuous {
            for (index, tick) in plan.ticks.enumerated() where index < plan.labels.count {
                let position = minX + (tick - plan.lower) / (xSpan == 0 ? 1 : xSpan) * plotWidth
                guard position >= minX - 1, position <= maxX + 1 else { continue }
                emitCenteredLabel(plan.labels[index], x: position, baseline: maxY + gap + metrics.ascent)
            }
        } else {
            emitCategoryLabels(plan, plotLeft: minX, slot: slot, top: maxY + gap)
        }
        return plot
    }

    /// Category labels under their slots: every `plan.every`-th one, level or tilted.
    private mutating func emitCategoryLabels(_ plan: XPlan, plotLeft: Double, slot: Double, top: Double) {
        let font = style.labelFont
        let metrics = engine.metrics(font)
        let radians = -ChartComposer.slantAngle * .pi / 180
        for index in stride(from: 0, to: data.count, by: Swift.max(1, plan.every)) {
            let center = plotLeft + (Double(index) + 0.5) * slot
            if plan.slanted {
                // The label ends at its slot, its top corner at the axis, and is cut short rather than
                // run off the chart's left edge.
                let anchor = center + sin(radians) * metrics.ascent
                let room = (anchor - 2) / cos(radians)
                let label = engine.truncated(data.labels[index], font, maxWidth: Swift.min(plan.maxTextWidth, room))
                scene.text(ChartText(string: label, font: font, color: style.horizontalLabelColor,
                                     x: anchor, y: top + cos(radians) * metrics.ascent,
                                     anchor: .end, angle: ChartComposer.slantAngle))
            } else {
                let label = engine.truncated(data.labels[index], font, maxWidth: plan.maxTextWidth)
                emitCenteredLabel(label, x: center, baseline: top + metrics.ascent)
            }
        }
    }

    /// A horizontal axis label centered at `x`, kept inside the chart.
    private mutating func emitCenteredLabel(_ label: String, x: Double, baseline: Double) {
        let font = style.labelFont
        let half = engine.width(label, font) / 2
        let position = Swift.min(Swift.max(x, half + 2), width - half - 2)
        scene.text(ChartText(string: label, font: font, color: style.horizontalLabelColor, x: position, y: baseline, anchor: .middle))
    }

    // MARK: Horizontal axis plans

    func planX(_ mode: XMode, plotWidth: Double, maxHeight: Double) -> XPlan {
        switch mode {
        case .categories:
            return planCategories(plotWidth: plotWidth, maxHeight: maxHeight)
        case .continuous(let lower, let upper, let isDate, let nice):
            return planContinuous(lower: lower, upper: upper, isDate: isDate, nice: nice, plotWidth: plotWidth)
        }
    }

    /// Fits category labels: level when they fit their slots; tilted when they're text, every slot
    /// has room for a tilted line and the tilt keeps within `maxHeight`; otherwise level, showing
    /// every n-th label (tilted every n-th when that shows many more of a text axis' labels).
    func planCategories(plotWidth: Double, maxHeight: Double) -> XPlan {
        var plan = XPlan()
        let count = data.count
        guard count > 0 else { return plan }
        let font = style.labelFont
        let metrics = engine.metrics(font)
        let slot = plotWidth / Double(count)
        let gap = 8 * style.scale
        let widest = widestLabel(data.labels, font)
        guard widest > 0 else { return plan }
        plan.height = metrics.height
        plan.maxTextWidth = widest
        if widest + gap <= slot { return plan }

        let radians = -ChartComposer.slantAngle * .pi / 180
        let slantPitch = metrics.height / sin(radians)
        let maxSlantWidth = Swift.max(0, (maxHeight - metrics.height * cos(radians)) / sin(radians))
        let slantWidth = Swift.min(widest, maxSlantWidth)
        let slantHeight = slantWidth * sin(radians) + metrics.height * cos(radians)
        let canSlant = labelsAreText && maxSlantWidth >= 3 * metrics.height
        if canSlant, slot >= slantPitch {
            plan.slanted = true
            plan.maxTextWidth = slantWidth
            plan.height = slantHeight
            return plan
        }
        let capped = Swift.min(widest, Swift.max(plotWidth / 3, 40 * style.scale))
        let everyLevel = Swift.max(1, Int(((capped + gap) / slot).rounded(.up)))
        if canSlant {
            let everySlanted = Swift.max(1, Int((slantPitch / slot).rounded(.up)))
            if Double(everySlanted) * 1.5 < Double(everyLevel) {
                plan.slanted = true
                plan.every = everySlanted
                plan.maxTextWidth = slantWidth
                plan.height = slantHeight
                return plan
            }
        }
        plan.every = everyLevel
        plan.maxTextWidth = capped
        return plan
    }

    /// Ticks for a continuous axis: as many nice ticks (calendar ticks for dates) as fit their labels.
    func planContinuous(lower: Double, upper: Double, isDate: Bool, nice: Bool, plotWidth: Double) -> XPlan {
        var plan = XPlan()
        let font = style.labelFont
        plan.height = engine.metrics(font).height
        var target = Swift.max(2, Swift.min(10, Int(plotWidth / (90 * style.scale))))
        for _ in 0..<6 {
            var ticks: [Double]
            var labels: [String]
            var low = lower, high = upper
            if isDate {
                let (dateTicks, pattern) = ChartTicks.dates(lower: low, upper: high, intervals: target)
                ticks = dateTicks
                let format = pattern ?? data.labelFormat
                labels = ticks.map { ChartNumberText.text($0, pattern: format) }
            } else {
                let scale = ChartTicks.linear(lower: low, upper: high, intervals: target)
                if nice {
                    low = scale.lower
                    high = scale.upper
                    ticks = scale.ticks
                } else {
                    let tolerance = (high - low) * 1e-9
                    ticks = scale.ticks.filter { $0 >= low - tolerance && $0 <= high + tolerance }
                }
                labels = ChartNumberText.tickLabels(ticks, step: scale.step, pattern: data.labelFormat, grouping: false)
            }
            plan.ticks = ticks
            plan.labels = labels
            plan.lower = low
            plan.upper = high
            let widest = labels.reduce(0) { Swift.max($0, engine.width($1, font)) }
            let span = Swift.max(high - low, 1e-12)
            var spacing = plotWidth
            for (first, second) in zip(ticks, ticks.dropFirst()) { spacing = Swift.min(spacing, (second - first) / span * plotWidth) }
            if widest + 12 * style.scale <= spacing || target <= 1 { break }
            target = Swift.max(1, Swift.min(target - 1, Int(Double(target) * spacing / (widest + 12 * style.scale))))
        }
        return plan
    }

    /// The widest label's width. Thousands of labels are sampled: only the longest ones by length are measured.
    func widestLabel(_ labels: [String], _ font: ChartFont) -> Double {
        if labels.count <= 400 { return labels.reduce(0) { Swift.max($0, engine.width($1, font)) } }
        var longest = 0
        for label in labels { longest = Swift.max(longest, label.utf8.count) }
        let threshold = longest * 3 / 4
        var candidates: [Int] = []
        for (index, label) in labels.enumerated() where label.utf8.count >= threshold { candidates.append(index) }
        let step = Swift.max(1, candidates.count / 400)
        var widest = 0.0
        for position in stride(from: 0, to: candidates.count, by: step) {
            widest = Swift.max(widest, engine.width(labels[candidates[position]], font))
        }
        return widest
    }

    // MARK: Marks

    /// Splits a series into runs of points between gaps.
    private func runs(_ values: [Double?], scale: ChartScale, x: (Int) -> Double?, y: (Double, ChartScale) -> Double?) -> [[CGPoint]] {
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for index in 0..<data.count {
            if let value = values[index], let px = x(index), let py = y(value, scale) {
                current.append(CGPoint(x: px, y: py))
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// An area's translucent fill, the line on top to stroke, and (for dense runs) the line as
    /// shapes to fill.
    private func areaPaths(_ item: PlotSeries, scale: ChartScale, x: (Int) -> Double?, y: (Double, ChartScale) -> Double?,
                           plotWidth: Double) -> (item: PlotSeries, (fill: CGPath, line: CGPath, denseLine: CGPath)) {
        let fill = CGMutablePath()
        let line = CGMutablePath()
        let denseLine = CGMutablePath()
        if let bases = item.bases {
            // A band from the series below to this one's running total.
            var tops: [CGPoint] = [], bottoms: [CGPoint] = []
            tops.reserveCapacity(data.count)
            bottoms.reserveCapacity(data.count)
            for index in 0..<data.count {
                guard let px = x(index), let top = item.tops[index], let yTop = y(top, scale), let yBase = y(bases[index], scale) else { continue }
                tops.append(CGPoint(x: px, y: yTop))
                bottoms.append(CGPoint(x: px, y: yBase))
            }
            guard !tops.isEmpty else { return (item, (fill, line, denseLine)) }
            if ChartComposer.isDense(tops.count, width: plotWidth) {
                let upper = ChartComposer.envelopes(tops), lower = ChartComposer.envelopes(bottoms)
                fill.addLines(between: upper.map { CGPoint(x: Double($0.column) + 0.5, y: $0.top) })
                for column in lower.reversed() { fill.addLine(to: CGPoint(x: Double(column.column) + 0.5, y: column.bottom)) }
                fill.closeSubpath()
                ChartComposer.addDenseLine(upper, width: item.lineWidth, to: denseLine)
            } else {
                fill.addLines(between: tops)
                for point in bottoms.reversed() { fill.addLine(to: point) }
                fill.closeSubpath()
                line.addLines(between: tops)
            }
        } else {
            let base = y(scale.baseline, scale) ?? 0
            for run in runs(item.tops, scale: scale, x: x, y: y) {
                guard let first = run.first, let last = run.last else { continue }
                if ChartComposer.isDense(run.count, width: plotWidth) {
                    let columns = ChartComposer.envelopes(run)
                    fill.move(to: CGPoint(x: Double(columns[0].column) + 0.5, y: base))
                    for column in columns { fill.addLine(to: CGPoint(x: Double(column.column) + 0.5, y: column.top)) }
                    fill.addLine(to: CGPoint(x: Double(columns[columns.count - 1].column) + 0.5, y: base))
                    fill.closeSubpath()
                    ChartComposer.addDenseLine(columns, width: item.lineWidth, to: denseLine)
                } else {
                    fill.move(to: CGPoint(x: first.x, y: base))
                    for point in run { fill.addLine(to: point) }
                    fill.addLine(to: CGPoint(x: last.x, y: base))
                    fill.closeSubpath()
                    line.addLines(between: run)
                }
            }
        }
        return (item, (fill, line, denseLine))
    }

    private mutating func drawLine(_ item: PlotSeries, scale: ChartScale, x: (Int) -> Double?, y: (Double, ChartScale) -> Double?, plotWidth: Double) {
        let path = CGMutablePath()
        let denseLine = CGMutablePath()
        var points: [CGPoint] = []
        var lonePoints: [CGPoint] = []
        let pointRadius = item.pointSize / 2
        for run in runs(item.tops, scale: scale, x: x, y: y) {
            if item.lineWidth > 0 {
                if run.count == 1 {
                    // A lone point between gaps would be invisible as a line.
                    if pointRadius <= 0 { lonePoints.append(run[0]) }
                } else if ChartComposer.isDense(run.count, width: plotWidth) {
                    ChartComposer.addDenseLine(ChartComposer.envelopes(run), width: item.lineWidth, to: denseLine)
                } else if item.smooth, run.count > 2 {
                    ChartComposer.addSmoothCurve(run, to: path)
                } else {
                    path.addLines(between: run)
                }
            }
            if pointRadius > 0 { points.append(contentsOf: run) }
        }
        scene.stroke(path, item.color, width: item.lineWidth)
        scene.fill(denseLine, item.color)
        scene.dots(lonePoints, radius: Swift.max(2.5, item.lineWidth), item.color)
        scene.dots(points, radius: pointRadius, item.color)
    }

    /// One pixel column of a dense run: its highest and lowest points, and where the run enters and leaves it.
    struct ColumnEnvelope {
        var column: Int
        var top: Double
        var bottom: Double
        var first: Double
        var last: Double
    }

    /// More than two points per pixel column. Such runs draw from per-column envelopes: the same
    /// picture at pixel size, without the thousands of overlapping segments that slow Core Graphics down.
    static func isDense(_ count: Int, width: Double) -> Bool { Double(count) > width * 2 + 8 }

    /// The envelope of each pixel column a run of points (in x order) passes through.
    static func envelopes(_ points: [CGPoint]) -> [ColumnEnvelope] {
        var result: [ColumnEnvelope] = []
        guard let start = points.first else { return result }
        var current = ColumnEnvelope(column: Int(start.x.rounded(.down)), top: start.y, bottom: start.y, first: start.y, last: start.y)
        for point in points.dropFirst() {
            let column = Int(point.x.rounded(.down))
            if column != current.column {
                result.append(current)
                current = ColumnEnvelope(column: column, top: point.y, bottom: point.y, first: point.y, last: point.y)
            } else {
                current.top = Swift.min(current.top, point.y)
                current.bottom = Swift.max(current.bottom, point.y)
                current.last = point.y
            }
        }
        result.append(current)
        return result
    }

    /// A dense line as one band: along the columns' tops (and the steps in from the previous column)
    /// and back along their bottoms, widened by the line's thickness. A simple polygon without overlaps.
    static func addDenseLine(_ columns: [ColumnEnvelope], width lineWidth: Double, to path: CGMutablePath) {
        guard !columns.isEmpty else { return }
        let half = Swift.max(0.5, lineWidth / 2)
        var tops: [CGPoint] = [], bottoms: [CGPoint] = []
        tops.reserveCapacity(columns.count)
        bottoms.reserveCapacity(columns.count)
        var previousLast: Double?
        for column in columns {
            var top = column.top, bottom = column.bottom
            if let previousLast {
                top = Swift.min(top, previousLast)
                bottom = Swift.max(bottom, previousLast)
            }
            let x = Double(column.column) + 0.5
            tops.append(CGPoint(x: x, y: top - half))
            bottoms.append(CGPoint(x: x, y: bottom + half))
            previousLast = column.last
        }
        if tops.count == 1 {
            path.addRect(CGRect(x: tops[0].x - 0.5, y: tops[0].y, width: 1, height: bottoms[0].y - tops[0].y))
            return
        }
        path.addLines(between: tops)
        for point in bottoms.reversed() { path.addLine(to: point) }
        path.closeSubpath()
    }

    /// A smooth curve through the points (Catmull-Rom), for smooth lines.
    static func addSmoothCurve(_ points: [CGPoint], to path: CGMutablePath) {
        path.move(to: points[0])
        for index in 0..<(points.count - 1) {
            let p0 = points[Swift.max(0, index - 1)], p1 = points[index], p2 = points[index + 1], p3 = points[Swift.min(points.count - 1, index + 2)]
            let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
    }

    /// Values above columns (below negative ones), centered in stacked segments when they fit, and
    /// above line and scatter points. Labels that would overlap the previous one are skipped.
    private mutating func emitVerticalDataLabels(_ item: PlotSeries, scale: ChartScale, stacked: Bool, barWidth: Double,
                                                 x: (Int) -> Double?, y: (Double, ChartScale) -> Double?, plot: CGRect) {
        let font = style.dataLabelFont
        let metrics = engine.metrics(font)
        var lastRight = -Double.infinity
        for index in 0..<data.count {
            guard let value = item.values[index], let top = item.tops[index], let px = x(index), let yTop = y(top, scale) else { continue }
            let label = ChartNumberText.dataLabel(value, pattern: item.format)
            let labelWidth = engine.width(label, font)
            guard px - labelWidth / 2 >= lastRight + 2 else { continue }
            var color = style.dataLabelColor
            var baseline: Double
            if item.mark == .column, stacked, let bases = item.bases, let yBase = y(bases[index], scale) {
                guard abs(yTop - yBase) >= metrics.height, labelWidth <= barWidth + 4 else { continue }
                baseline = (yTop + yBase) / 2 + metrics.middle
                color = ChartColor.white
            } else if item.mark == .column {
                baseline = top >= scale.baseline ? yTop - 4 * style.scale - metrics.descent : yTop + 4 * style.scale + metrics.ascent
            } else {
                baseline = yTop - Swift.max(4, item.pointSize / 2 + 3) * style.scale - metrics.descent
            }
            baseline = Swift.min(Swift.max(baseline, Double(plot.minY) - metrics.descent), height - metrics.descent)
            scene.text(ChartText(string: label, font: font, color: color, x: px, y: baseline, anchor: .middle))
            lastRight = px + labelWidth / 2
        }
    }

    // MARK: Bars

    private mutating func composeBars(_ series: [PlotSeries], stacking: Stacking, frame: ChartFrame) -> CGRect {
        let count = data.count
        let font = style.labelFont
        let metrics = engine.metrics(font)
        let gap = style.labelGap
        let log = spec.logScale && stacking != .percent
        let range = valueRange(series, right: false, log: log, stacking: stacking)
        let format = axisFormat(series, right: false)
        let plotTop = frame.top
        let plotBottom = frame.bottom - (metrics.height + gap)
        let labelWidth = Swift.min(widestLabel(data.labels, font), Swift.max(60 * style.scale, width * 0.3))
        let plotLeft = frame.left + (labelWidth > 0 ? labelWidth + gap : 0)
        var plotRight = frame.right
        var scale = ChartTicks.linear(lower: 0, upper: 1, intervals: 4)
        var labels: [String] = []
        var target = Swift.max(2, Swift.min(8, Int((plotRight - plotLeft) / (90 * style.scale))))
        for _ in 0..<6 {
            scale = valueScale(range, intervals: target, log: log, stacking: stacking, pinned: true)
            labels = valueLabels(scale, format: format, stacking: stacking)
            let widest = labels.reduce(0) { Swift.max($0, engine.width($1, font)) }
            plotRight = frame.right - Swift.max(0, widest / 2 - style.padding / 2)
            let spacing = (plotRight - plotLeft) / Double(Swift.max(1, scale.ticks.count - 1))
            if widest + 12 * style.scale <= spacing || target <= 1 { break }
            target -= 1
        }
        let plot = CGRect(x: plotLeft, y: plotTop, width: Swift.max(1, plotRight - plotLeft), height: Swift.max(1, plotBottom - plotTop))
        let minX = Double(plot.minX), minY = Double(plot.minY), maxY = Double(plot.maxY)
        let plotWidth = Double(plot.width), plotHeight = Double(plot.height)
        func x(_ value: Double) -> Double? { scale.fraction(value).map { minX + $0 * plotWidth } }
        let slot = plotHeight / Double(Swift.max(1, count))

        if spec.showsGridlines {
            let path = CGMutablePath()
            for tick in scale.ticks {
                if let position = x(tick), position >= minX - 0.5, position <= Double(plot.maxX) + 0.5 {
                    path.addRect(CGRect(x: (position - 0.5).rounded(), y: minY, width: 1, height: plotHeight))
                }
            }
            scene.fill(path, style.gridlineColor)
        }
        let pinned = spec.verticalMinimum != nil || spec.verticalMaximum != nil || log
        if pinned { scene.clip(plot.insetBy(dx: -1, dy: -12)) }
        let groups = stacking == .none ? series.count : 1
        let groupHeight = slot * ChartStyle.groupWidth
        let barHeight = Swift.max(groupHeight / Double(Swift.max(1, groups)), Swift.min(1, slot))
        func barCenter(_ order: Int, _ index: Int) -> Double {
            let center = minY + (Double(index) + 0.5) * slot
            if stacking != .none || groups <= 1 { return center }
            return center - groupHeight / 2 + (Double(order) + 0.5) * barHeight
        }
        for (order, item) in series.enumerated() {
            let path = CGMutablePath()
            var pending: CGRect?
            var pendingBucket = Int.min
            let decimate = slot < 1
            for index in 0..<count {
                guard let top = item.tops[index], let xTop = x(top) else { continue }
                let xBase = x(item.bases?[index] ?? scale.baseline) ?? minX
                var upper = barCenter(order, index) - barHeight / 2
                var lower = upper + barHeight
                if barHeight >= 2 {
                    upper = upper.rounded()
                    lower = Swift.max(upper + 1, lower.rounded())
                }
                let rect = CGRect(x: Swift.min(xTop, xBase), y: upper, width: abs(xTop - xBase), height: lower - upper)
                if decimate {
                    let bucket = Int(upper.rounded(.down))
                    if bucket == pendingBucket, let current = pending {
                        pending = current.union(rect)
                        continue
                    }
                    if let current = pending { path.addRect(current) }
                    pending = rect
                    pendingBucket = bucket
                } else {
                    path.addRect(rect)
                }
            }
            if let pending { path.addRect(pending) }
            scene.fill(path, item.color)
        }
        if !log, scale.lower <= 0, scale.upper >= 0, let zero = x(0) {
            scene.fill(CGRect(x: (zero - 0.5).rounded(), y: minY, width: 1, height: plotHeight), style.baselineColor)
        }
        if pinned { scene.endClip() }

        // Data labels past the bars' ends (inside stacked segments when they fit).
        let labelFont = style.dataLabelFont
        let labelMetrics = engine.metrics(labelFont)
        for (order, item) in series.enumerated() where item.dataLabels {
            var lastBottom = -Double.infinity
            for index in 0..<count {
                guard let value = item.values[index], let top = item.tops[index], let xTop = x(top) else { continue }
                let center = barCenter(order, index)
                guard center - labelMetrics.height / 2 >= lastBottom else { continue }
                let label = ChartNumberText.dataLabel(value, pattern: item.format)
                let labelWidth = engine.width(label, labelFont)
                if stacking != .none, let bases = item.bases, let xBase = x(bases[index]) {
                    guard abs(xTop - xBase) >= labelWidth + 4, barHeight >= labelMetrics.height else { continue }
                    scene.text(ChartText(string: label, font: labelFont, color: .white, x: (xTop + xBase) / 2,
                                         y: center + labelMetrics.middle, anchor: .middle))
                } else if top >= scale.baseline {
                    scene.text(ChartText(string: label, font: labelFont, color: style.dataLabelColor, x: xTop + 4 * style.scale,
                                         y: center + labelMetrics.middle))
                } else {
                    scene.text(ChartText(string: label, font: labelFont, color: style.dataLabelColor, x: xTop - 4 * style.scale,
                                         y: center + labelMetrics.middle, anchor: .end))
                }
                lastBottom = center + labelMetrics.height / 2
            }
        }

        // Category labels at the left, thinned when the bars are too thin for them.
        let every = slot >= metrics.height + 2 ? 1 : Int(((metrics.height + 2) / slot).rounded(.up))
        for index in stride(from: 0, to: count, by: every) {
            let label = engine.truncated(data.labels[index], font, maxWidth: labelWidth)
            scene.text(ChartText(string: label, font: font, color: style.verticalLabelColor, x: minX - gap,
                                 y: minY + (Double(index) + 0.5) * slot + metrics.middle, anchor: .end))
        }
        // Value labels under the plot.
        for (index, tick) in scale.ticks.enumerated() {
            guard let position = x(tick), position >= minX - 0.5, position <= Double(plot.maxX) + 0.5 else { continue }
            emitCenteredLabel(labels[index], x: position, baseline: maxY + gap + metrics.ascent)
        }
        return plot
    }
}
