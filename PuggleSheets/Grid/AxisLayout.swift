import Foundation

/// Positions along one axis of the grid (rows or columns) in sheet pixels at 100% zoom.
/// Most rows and columns have the default size, so only the exceptions are stored: offsets are
/// `index × default` plus the summed differences of the exceptions before `index`.
struct AxisLayout {
    let count: Int
    let defaultSize: Double
    /// Sorted indexes whose size differs from the default (custom or hidden).
    private let keys: [Int]
    private let sizes: [Double]
    /// `deltas[i]` is the summed difference from the default of `keys[0..<i]`.
    private let deltas: [Double]

    init(count: Int, defaultSize: Double, custom: [Int: Double], hidden: Set<Int>) {
        self.count = count
        self.defaultSize = defaultSize
        var exceptions: [Int: Double] = [:]
        for (index, size) in custom where index < count && size != defaultSize { exceptions[index] = size }
        for index in hidden where index < count { exceptions[index] = 0 }
        keys = exceptions.keys.sorted()
        sizes = keys.map { exceptions[$0]! }
        var running = 0.0
        var deltas = [0.0]
        deltas.reserveCapacity(keys.count + 1)
        for size in sizes {
            running += size - defaultSize
            deltas.append(running)
        }
        self.deltas = deltas
    }

    func size(_ index: Int) -> Double {
        let position = lowerBound(index)
        return position < keys.count && keys[position] == index ? sizes[position] : defaultSize
    }

    func isHidden(_ index: Int) -> Bool { size(index) == 0 }

    /// The start of `index`; `offset(count)` is the total length.
    func offset(_ index: Int) -> Double {
        let clamped = min(max(index, 0), count)
        return Double(clamped) * defaultSize + deltas[lowerBound(clamped)]
    }

    var total: Double { offset(count) }

    /// The row or column containing `position`, clamped to the axis. Hidden entries are never returned.
    func index(at position: Double) -> Int {
        guard count > 0 else { return 0 }
        if position <= 0 { return firstVisible(from: 0) }
        var low = 0, high = count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offset(mid) <= position { low = mid } else { high = mid - 1 }
        }
        return firstVisible(from: low)
    }

    /// `index` or the next visible one after it (or the last visible one before it at the end).
    func firstVisible(from index: Int) -> Int {
        var current = min(max(index, 0), count - 1)
        while current < count - 1, isHidden(current) { current += 1 }
        while current > 0, isHidden(current) { current -= 1 }
        return current
    }

    /// The next visible index in `direction` (+1 or -1) from `index`, or `index` at the edge.
    func step(from index: Int, by direction: Int) -> Int {
        var current = index + direction
        while current >= 0, current < count, isHidden(current) { current += direction }
        return current >= 0 && current < count ? current : index
    }

    private func lowerBound(_ index: Int) -> Int {
        var low = 0, high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if keys[mid] < index { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
