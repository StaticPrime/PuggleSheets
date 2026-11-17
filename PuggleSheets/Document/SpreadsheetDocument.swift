import AppKit
import PuggleSheetsKit

/// A spreadsheet window's model: the workbook and file handling.
@objc(SpreadsheetDocument)
final class SpreadsheetDocument: NSDocument {
    var workbook = Workbook()
    /// The sheet showing when the file was saved, or the one to show first.
    var activeSheetIndex = 0
    /// Features found while importing that could not be kept.
    private(set) var importWarnings: Set<ImportWarning> = []
    /// Title typed into the header before the spreadsheet has a file.
    var customTitle: String?
    /// The original file name when a lossy import was reopened as an untitled copy.
    private(set) var importedFileName: String?

    var onStatusChange: (() -> Void)?
    /// Called after the contents were replaced from a file (Revert).
    var onReload: (() -> Void)?

    /// Content parsed off the main thread, applied once the main actor can take it.
    nonisolated(unsafe) private var pendingFile: SpreadsheetFile?

    override init() {
        super.init()
        hasUndoManager = true
    }

    nonisolated override class var autosavesInPlace: Bool { true }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override func makeWindowControllers() {
        if let file = pendingFile {
            pendingFile = nil
            apply(file)
        }
        #if DEBUG
        if fileURL == nil, DebugLaunchOptions.wantsSample, workbook.sheets.allSatisfy({ $0.cells.isEmpty }) {
            workbook = SampleContent.make()
        }
        #endif
        if !importWarnings.isEmpty, let url = fileURL {
            // Never overwrite a file with a lossy copy: continue as an untitled spreadsheet.
            importedFileName = url.deletingPathExtension().lastPathComponent
            fileURL = nil
            fileType = SpreadsheetFileFormat.xlsx.typeIdentifier
        }
        addWindowController(DocumentWindowController(document: self))
    }

    // MARK: Reading and writing

    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        guard let format = SpreadsheetFileFormat(typeName: typeName) else {
            throw SpreadsheetIOError.unreadable("PuggleSheets can't open files of this type.")
        }
        let file = try SpreadsheetIO.read(data, format: format)
        if Thread.isMainThread {
            MainActor.assumeIsolated { apply(file) }
        } else {
            pendingFile = file
        }
    }

    private func apply(_ file: SpreadsheetFile) {
        workbook = file.workbook
        activeSheetIndex = min(max(file.activeSheet, 0), workbook.sheets.count - 1)
        importWarnings = file.warnings
        undoManager?.removeAllActions()
        onReload?()
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let format = SpreadsheetFileFormat(typeName: typeName) else {
            throw SpreadsheetIOError.unwritable("PuggleSheets can't save files of this type.")
        }
        return try SpreadsheetIO.write(workbook, activeSheet: activeSheetIndex, format: format)
    }

    var format: SpreadsheetFileFormat? { fileType.flatMap(SpreadsheetFileFormat.init(typeName:)) }

    // MARK: Names

    override var displayName: String! {
        get {
            if fileURL == nil, let title = customTitle ?? importedFileName { return title }
            let name: String = super.displayName
            if fileURL == nil, name.hasPrefix("Untitled") { return name.replacingOccurrences(of: "Untitled", with: "Untitled spreadsheet") }
            return name
        }
        set { super.displayName = newValue }
    }

    // MARK: Status

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        onStatusChange?()
    }

    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        onStatusChange?()
    }
}
