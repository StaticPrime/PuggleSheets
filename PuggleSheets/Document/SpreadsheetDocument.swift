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
    /// For a spreadsheet someone shared with this person: which one it is. It has no file here.
    var sharedCopy: SharedCopy?
    /// While the spreadsheet is shared: its part in that.
    var collaboration: SpreadsheetCollaboration?

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
        if fileURL == nil, sharedCopy == nil, DebugLaunchOptions.wantsSample, workbook.sheets.allSatisfy({ $0.cells.isEmpty }) {
            workbook = SampleContent.make()
        }
        #endif
        if !importWarnings.isEmpty, let url = fileURL {
            // Never overwrite a file with a lossy copy: continue as an untitled spreadsheet.
            importedFileName = url.deletingPathExtension().lastPathComponent
            fileURL = nil
            fileType = SpreadsheetFileFormat.xlsx.typeIdentifier
        }
        let controller = DocumentWindowController(document: self)
        addWindowController(controller)
        CollaborationController.shared?.documentOpened(self, in: controller)
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
            if let sharedCopy { return sharedCopy.title }
            if fileURL == nil, let title = customTitle ?? importedFileName { return title }
            let name: String = super.displayName
            if fileURL == nil, name.hasPrefix("Untitled") { return name.replacingOccurrences(of: "Untitled", with: "Untitled spreadsheet") }
            return name
        }
        set { super.displayName = newValue }
    }

    // MARK: Shared copies

    /// A spreadsheet shared with this person lives in iCloud: it's never saved here unless they save a copy.
    override var isDocumentEdited: Bool {
        if sharedCopy != nil { return collaboration?.hasUnsentChanges ?? false }
        return super.isDocumentEdited
    }

    override var hasUnautosavedChanges: Bool { sharedCopy != nil ? false : super.hasUnautosavedChanges }

    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool, completionHandler: @escaping (Error?) -> Void) {
        guard sharedCopy == nil else { return completionHandler(nil) }
        super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable, completionHandler: completionHandler)
    }

    /// A spreadsheet shared with this person has no file here to move or rename, and its name is its owner's to change.
    /// While a spreadsheet is shared, its copy in iCloud is the one that counts: its file's older versions don't come
    /// back over it.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if sharedCopy != nil, [#selector(NSDocument.move(_:)), #selector(NSDocument.revertToSaved(_:)), #selector(NSDocument.browseVersions(_:))]
            .contains(item.action) {
            return false
        }
        if collaboration?.isLive == true, [#selector(NSDocument.revertToSaved(_:)), #selector(NSDocument.browseVersions(_:))].contains(item.action) {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Saving a spreadsheet shared with this person keeps a copy of it on this Mac.
    override func save(_ sender: Any?) {
        if sharedCopy != nil {
            saveTo(sender)
        } else {
            super.save(sender)
        }
    }

    /// Before closing a shared spreadsheet with changes that haven't reached iCloud, the person chooses.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard let collaboration, collaboration.hasUnsentChanges, let window = windowControllers.first?.window else {
            if sharedCopy != nil {
                Self.answer(true, to: delegate, selector: shouldCloseSelector, document: self, contextInfo: contextInfo)
                return
            }
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        collaboration.flush()
        let alert = NSAlert()
        alert.messageText = "Your latest changes to “\(displayName ?? "the spreadsheet")” haven’t reached iCloud yet."
        alert.informativeText = "The people you share it with won’t see them if you close it now. Wait a moment for iCloud, or keep a copy on this Mac."
        alert.addButton(withTitle: "Keep Open")
        alert.addButton(withTitle: "Close Anyway")
        alert.buttons[1].hasDestructiveAction = true
        let context = UncheckedPointer(pointer: contextInfo)
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn, self.sharedCopy == nil {
                super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: context.pointer)
            } else {
                Self.answer(response == .alertSecondButtonReturn, to: delegate, selector: shouldCloseSelector, document: self, contextInfo: context.pointer)
            }
        }
    }

    /// Calls `-document:shouldClose:contextInfo:` on whoever asked.
    private static func answer(_ shouldClose: Bool, to delegate: Any, selector: Selector?, document: NSDocument, contextInfo: UnsafeMutableRawPointer?) {
        guard let selector, let object = delegate as? NSObject, let method = object.method(for: selector) else { return }
        typealias Callback = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(method, to: Callback.self)(object, selector, document, shouldClose, contextInfo)
    }

    override func close() {
        collaboration?.close()
        collaboration = nil
        super.close()
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

/// A context pointer handed through a completion handler.
private struct UncheckedPointer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer?
}
