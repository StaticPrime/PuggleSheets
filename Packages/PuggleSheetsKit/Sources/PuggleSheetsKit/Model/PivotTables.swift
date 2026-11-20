import Foundation

/// Insert ▸ Pivot table: a summary of source data, shown from `anchor` down and to the right. Its
/// results behave like a spilling formula's: the formula engine places them in the sheet's spilled
/// values, and data in the way shows #REF! in the anchor cell.
public struct PivotTable: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    /// The pivot table's top-left cell, on the sheet that holds it.
    public var anchor: CellAddress
    /// The source data, headers in its first row: "Sheet1!A1:E200", or a range on the pivot's own sheet.
    public var source: String
    public var rows: [PivotGroup]
    public var columns: [PivotGroup]
    public var values: [PivotValue]
    public var filters: [PivotFilter]
    /// With several values: false puts them side by side in columns (the default), true
    /// stacks them in rows.
    public var valuesInRows: Bool

    public init(id: UUID = UUID(), anchor: CellAddress, source: String, rows: [PivotGroup] = [], columns: [PivotGroup] = [],
                values: [PivotValue] = [], filters: [PivotFilter] = [], valuesInRows: Bool = false) {
        self.id = id
        self.anchor = anchor
        self.source = source
        self.rows = rows
        self.columns = columns
        self.values = values
        self.filters = filters
        self.valuesInRows = valuesInRows
    }

    /// Renumbers source columns after columns moved (`map` returns nil for deleted ones, whose
    /// groups, values and filters are removed).
    public mutating func remapSourceColumns(_ map: (Int) -> Int?) {
        rows = rows.compactMap { group in map(group.sourceColumn).map { var group = group; group.sourceColumn = $0; return group } }
        columns = columns.compactMap { group in map(group.sourceColumn).map { var group = group; group.sourceColumn = $0; return group } }
        filters = filters.compactMap { filter in map(filter.sourceColumn).map { var filter = filter; filter.sourceColumn = $0; return filter } }
        var valueIndexes: [Int: Int] = [:]
        var kept: [PivotValue] = []
        for (index, value) in values.enumerated() {
            guard let column = map(value.sourceColumn) else { continue }
            var value = value
            value.sourceColumn = column
            valueIndexes[index] = kept.count
            kept.append(value)
        }
        values = kept
        func remapSort(_ group: inout PivotGroup) { group.sortByValue = group.sortByValue.flatMap { valueIndexes[$0] } }
        for index in rows.indices { remapSort(&rows[index]) }
        for index in columns.indices { remapSort(&columns[index]) }
    }

    /// Every source column the pivot table uses.
    public var usedSourceColumns: Set<Int> {
        Set(rows.map(\.sourceColumn) + columns.map(\.sourceColumn) + values.map(\.sourceColumn) + filters.map(\.sourceColumn))
    }
}

/// A row or column group: one entry per distinct value of a source column.
public struct PivotGroup: Hashable, Sendable, Codable {
    /// Index into the source range's columns (0 is its first column).
    public var sourceColumn: Int
    public var ascending: Bool
    public var showsTotals: Bool
    /// "Sort by": orders groups by this value's summary (an index into `values`)
    /// rather than by their labels.
    public var sortByValue: Int?

    public init(sourceColumn: Int, ascending: Bool = true, showsTotals: Bool = true, sortByValue: Int? = nil) {
        self.sourceColumn = sourceColumn
        self.ascending = ascending
        self.showsTotals = showsTotals
        self.sortByValue = sortByValue
    }
}

/// A summarized value.
public struct PivotValue: Hashable, Sendable, Codable {
    public enum Summary: String, CaseIterable, Sendable, Codable {
        case sum = "SUM", countA = "COUNTA", count = "COUNT", countUnique = "COUNTUNIQUE", average = "AVERAGE"
        case max = "MAX", min = "MIN", median = "MEDIAN", product = "PRODUCT"
        case stdev = "STDEV", stdevp = "STDEVP", variance = "VAR", variancep = "VARP"
    }

    public enum ShowAs: String, CaseIterable, Sendable, Codable {
        case `default`, percentOfRow, percentOfColumn, percentOfGrandTotal
    }

    public var sourceColumn: Int
    public var summary: Summary
    public var showAs: ShowAs
    /// A heading instead of the default "SUM of Sales".
    public var name: String?

    public init(sourceColumn: Int, summary: Summary = .sum, showAs: ShowAs = .default, name: String? = nil) {
        self.sourceColumn = sourceColumn
        self.summary = summary
        self.showAs = showAs
        self.name = name
    }
}

/// Leaves out source rows, by values or by a condition (the same choices as a sheet filter).
public struct PivotFilter: Hashable, Sendable, Codable {
    public var sourceColumn: Int
    public var criterion: FilterCriterion

    public init(sourceColumn: Int, criterion: FilterCriterion = FilterCriterion()) {
        self.sourceColumn = sourceColumn
        self.criterion = criterion
    }
}

/// What a pivot table shows, cell by cell, and what each cell is, so it can be styled.
public struct PivotOutput: Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        /// Headings: the row group names, column group values and value names at the top.
        case header
        /// A row group's value down the left.
        case rowLabel
        case value
        /// A group's total row or column, its label included.
        case total
        /// The grand totals, their labels included.
        case grandTotal
        case empty
    }

    /// Rows of cells; every row has the same length.
    public var values: [[CellValue]]
    public var roles: [[Role]]
    /// The number format for each cell (value cells take their source column's format), nil for automatic.
    public var numberFormats: [[String?]]

    public init(values: [[CellValue]] = [], roles: [[Role]] = [], numberFormats: [[String?]] = []) {
        self.values = values
        self.roles = roles
        self.numberFormats = numberFormats
    }

    public var rowCount: Int { values.count }
    public var columnCount: Int { values.first?.count ?? 0 }
}
