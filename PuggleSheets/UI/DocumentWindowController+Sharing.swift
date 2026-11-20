import AppKit
import PuggleSheetsKit

/// Sharing a spreadsheet through iCloud: the Collaborate sheet, what sharing lets this person do, and the window's
/// side of sharing ending.
extension DocumentWindowController {
    /// The Collaborate sheet: sharing the spreadsheet, or seeing and changing who it's shared with.
    func showCollaborate() {
        guard let controller = CollaborationController.shared else { return }
        finishEditing()
        let model = CollaborateModel(controller: controller, windowController: self)
        presentSheet { dismiss in
            model.done = dismiss
            return CollaborateView(model: model)
        }
    }

    /// Locks or unlocks the spreadsheet as sharing allows: people who may only comment can still comment.
    func setAccess(_ access: DocumentAccess) {
        guard state.access != access else { return }
        if access != .full {
            grid.cancelEditing()
            if formulaBar.isEditing { finishEditing() }
            grid.paintFormats = nil
            state.isPaintFormatActive = false
            // Sidebars that only change things close; comments and column stats stay, to read.
            if let sidebar = state.sidebar, sidebar != .comments, sidebar != .columnStats { closeSidebar() }
        }
        state.access = access
        formulaBar.field.isEditable = access == .full
        grid.needsDisplay = true
        scheduleStateRefresh()
    }

    /// The spreadsheet stopped being shared: it carries on here as an ordinary spreadsheet, saved in its file.
    func sharingEnded() {
        state.collaboration.reset()
        setAccess(.full)
        controller.collaboration = nil
        updateStatus()
        state.banner = "“\(state.title)” is no longer shared. It’s saved on this Mac, and nobody else can open it any longer."
    }

    /// A spreadsheet someone shared went away: its cells go at once, the window says why, and closes.
    func sharedCopyWentAway(ownerName: String, reason: UnavailableReason) {
        guard let document = spreadsheet, let window else { return }
        let title = document.displayName ?? state.title
        setAccess(.locked)
        controller.applyRemote([.workbook(Workbook())])
        state.collaboration.reset()
        guard reason == .stopped else {
            document.close()
            return
        }
        let alert = NSAlert()
        alert.messageText = "“\(title)” is no longer shared with you"
        alert.informativeText = "\(ownerName) stopped sharing it, so it can’t be opened here any longer."
        alert.addButton(withTitle: "OK")
        window.attachedSheet.map { window.endSheet($0) }
        alert.beginSheetModal(for: window) { _ in
            MainActor.assumeIsolated { document.close() }
        }
    }

    // MARK: Commands

    @objc func psCollaborate(_ sender: Any?) { showCollaborate() }

    /// Leaves a spreadsheet someone shared with this person, once they say so: it closes, and they're out of it.
    @objc func psLeaveShared(_ sender: Any?) {
        guard let document = spreadsheet, let session = document.collaboration, !session.isOwner, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Leave “\(state.title)”?"
        alert.informativeText = "It closes on this Mac, and you’re no longer in it. \(state.collaboration.ownerName) can share it with you again."
        alert.addButton(withTitle: "Leave")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                CollaborationController.shared?.service.leave(session.id) { error in
                    if let error {
                        let problem = NSAlert()
                        problem.messageText = "You couldn’t leave “\(self.state.title)”."
                        problem.informativeText = error.localizedDescription
                        problem.beginSheetModal(for: window)
                        return
                    }
                    session.end()
                    document.close()
                }
            }
        }
    }

    /// Menu commands that change nothing, and so stay available while a shared spreadsheet can only be commented on
    /// (or is still on its way, for those that don't touch the cells).
    /// Whether the spreadsheet can be changed here. When it can't, says so with a beep (and, offline, why), so that
    /// controls which only change things don't open.
    func allowsChanges() -> Bool {
        guard !state.isEditable else { return true }
        controller.refuseChange()
        return false
    }

    static let commandsThatChangeNothing: Set<Selector> = [
        #selector(copy(_:)), #selector(SheetCommands.psFind(_:)), #selector(SheetCommands.psFindNext(_:)),
        #selector(SheetCommands.psFindPrevious(_:)), #selector(SheetCommands.psToggleFormulaBar(_:)),
        #selector(SheetCommands.psSetZoom(_:)), #selector(SheetCommands.psZoomIn(_:)), #selector(SheetCommands.psZoomOut(_:)),
        #selector(SheetCommands.psActualSize(_:)), #selector(SheetCommands.psDownload(_:)), #selector(SheetCommands.psDownloadPDF(_:)),
        #selector(SheetCommands.psPrint(_:)), #selector(SheetCommands.psShowShortcuts(_:)), #selector(SheetCommands.psShowComments(_:)),
        #selector(SheetCommands.psToggleShowFormulas(_:)), #selector(SheetCommands.psToggleShowProtectedRanges(_:)),
        #selector(SheetCommands.psOpenFilterView(_:)), #selector(SheetCommands.psCloseFilterView(_:)),
        #selector(SheetCommands.psColumnStats(_:)), #selector(SheetCommands.psCollaborate(_:)), #selector(SheetCommands.psLeaveShared(_:)),
        #selector(SheetCommands.psRename(_:)),
    ]
}
