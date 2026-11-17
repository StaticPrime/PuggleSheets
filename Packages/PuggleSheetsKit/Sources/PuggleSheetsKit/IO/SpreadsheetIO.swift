import Foundation

/// File formats PuggleSheets opens and saves.
public enum SpreadsheetFileFormat: String, CaseIterable, Sendable {
    case xlsx, ods, csv, tsv

    public init?(typeName: String) {
        switch typeName.lowercased() {
        case "org.openxmlformats.spreadsheetml.sheet", "xlsx": self = .xlsx
        case "org.oasis-open.opendocument.spreadsheet", "ods": self = .ods
        case "public.comma-separated-values-text", "csv": self = .csv
        case "public.tab-separated-values-text", "tsv": self = .tsv
        default: return nil
        }
    }

    /// The uniform type identifier.
    public var typeIdentifier: String {
        switch self {
        case .xlsx: "org.openxmlformats.spreadsheetml.sheet"
        case .ods: "org.oasis-open.opendocument.spreadsheet"
        case .csv: "public.comma-separated-values-text"
        case .tsv: "public.tab-separated-values-text"
        }
    }

    public var fileExtension: String { rawValue }

    /// As listed in File ▸ Download.
    public var displayName: String {
        switch self {
        case .xlsx: "Microsoft Excel (.xlsx)"
        case .ods: "OpenDocument (.ods)"
        case .csv: "Comma-separated values (.csv, current sheet)"
        case .tsv: "Tab-separated values (.tsv, current sheet)"
        }
    }

    /// ".XLSX", shown next to the title.
    public var badge: String { "." + rawValue.uppercased() }

    /// False for formats that keep only the current sheet's values.
    public var keepsEverything: Bool { self == .xlsx || self == .ods }
}

/// Things found in a file that PuggleSheets can't keep yet.
public enum ImportWarning: String, CaseIterable, Sendable {
    case charts, images, pivotTables, conditionalFormatting, dataValidation, comments, filters, namedRanges,
         hiddenSheets, macros, richText, hyperlinks, protection, filterViews

    /// "charts", "conditional formatting", … for "PuggleSheets can't keep charts and images yet".
    public var userDescription: String {
        switch self {
        case .charts: "charts"
        case .images: "images"
        case .pivotTables: "pivot tables"
        case .conditionalFormatting: "conditional formatting"
        case .dataValidation: "data validation"
        case .comments: "comments and notes"
        case .filters: "filters"
        case .namedRanges: "named ranges"
        case .hiddenSheets: "hidden sheets"
        case .macros: "macros"
        case .richText: "mixed formatting inside cells"
        case .hyperlinks: "links"
        case .protection: "protected sheets and ranges"
        case .filterViews: "filter views"
        }
    }
}

/// A file's contents.
public struct SpreadsheetFile: Sendable {
    public var workbook: Workbook
    /// The sheet that was showing when the file was saved.
    public var activeSheet: Int
    public var warnings: Set<ImportWarning>

    public init(workbook: Workbook, activeSheet: Int = 0, warnings: Set<ImportWarning> = []) {
        self.workbook = workbook
        self.activeSheet = activeSheet
        self.warnings = warnings
    }
}

public enum SpreadsheetIOError: Error, LocalizedError {
    case unreadable(String)
    case unwritable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let message), .unwritable(let message): message
        }
    }
}

public enum SpreadsheetIO {
    /// Reads a file. Formula cells keep the formula text and the cached results stored in the file;
    /// CSV and TSV values are interpreted as if typed (numbers, dates, percentages…).
    public static func read(_ data: Data, format: SpreadsheetFileFormat) throws -> SpreadsheetFile {
        switch format {
        case .xlsx: try XLSXReader.read(data)
        case .ods: try ODSReader.read(data)
        case .csv: DelimitedReader.read(data, delimiter: .comma)
        case .tsv: DelimitedReader.read(data, delimiter: .tab)
        }
    }

    /// Writes a file. CSV and TSV hold the values of `activeSheet` only, as displayed.
    public static func write(_ workbook: Workbook, activeSheet: Int, format: SpreadsheetFileFormat) throws -> Data {
        switch format {
        case .xlsx: try XLSXWriter.write(workbook, activeSheet: activeSheet)
        case .ods: try ODSWriter.write(workbook, activeSheet: activeSheet)
        case .csv: DelimitedWriter.write(workbook, activeSheet: activeSheet, delimiter: .comma)
        case .tsv: DelimitedWriter.write(workbook, activeSheet: activeSheet, delimiter: .tab)
        }
    }
}
