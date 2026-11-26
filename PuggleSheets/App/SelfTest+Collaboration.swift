#if DEBUG
import AppKit
import PuggleSheetsKit

/// Drives collaboration end to end on the stand-in "iCloud" (`-PSSelfTest YES -PSSelfTestSuite collaboration`):
/// sharing the window's spreadsheet, people on other "Macs" editing and commenting along with it (rows inserted while
/// others type, the same cell typed into at once), undo, access, the summaries sent after a quiet spell, stopping
/// sharing, and spreadsheets someone else shares, read-only.
@MainActor
final class CollaborationSelfTest {
    private struct Step {
        let name: String
        let timeout: TimeInterval
        /// Whether the step changes this window's spreadsheet, so its changes get an undo group of their own.
        let here: Bool
        let act: () -> Void
        let check: () -> Bool
    }

    private let window: DocumentWindowController
    private var steps: [Step] = []
    private var failures = 0
    private let cloud = StandInCloud.shared
    private let ana = StandInPerson(Collaborator(id: "ana@example.com", name: "Ana Lopez", address: "ana@example.com"))
    private let ben = StandInPerson(Collaborator(id: "ben@example.com", name: "Ben Carter", address: "ben@example.com"))
    private let cy = StandInPerson(Collaborator(id: "cy@example.com", name: "Cy Park", address: "cy@example.com"))
    private var linkedSpreadsheet: UUID?
    private var linkRefused = false
    private var model: CollaborateModel!
    private var bensSpreadsheet: UUID?
    private var bensWindow: DocumentWindowController?
    private var renameRequestsBefore = 0
    private var titleBeforeRename = ""
    private var startedNotices = 0
    private var offlineWorkbook = Workbook()
    private var offlineThreads = 0
    private var random = SystemRandomNumberGenerator()

    init(window: DocumentWindowController) { self.window = window }

    static func run() {
        SpreadsheetCollaboration.noticeDelay = 1
        StandInCloud.shared.latency = 0.03
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let window = NSApp.windows.compactMap({ $0.windowController as? DocumentWindowController }).first else {
                print("SELFTEST FAIL: no window")
                NSApp.terminate(nil)
                return
            }
            let test = CollaborationSelfTest(window: window)
            test.defineSteps()
            test.next()
        }
    }

    private var sheets: SpreadsheetController { window.controller }
    private var document: SpreadsheetDocument { window.spreadsheet! }
    private var state: CollaborationState { window.state.collaboration }
    private var session: SpreadsheetCollaboration? { document.collaboration }

    private func address(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    /// What a cell here holds, as typed.
    private func text(_ a1: String, in controller: SpreadsheetController? = nil) -> String {
        (controller ?? sheets).editText(at: address(a1))
    }

    private func type(_ text: String, in a1: String, controller: SpreadsheetController? = nil) {
        (controller ?? sheets).commitInput(text, at: address(a1))
    }

    private func select(_ a1: String) {
        sheets.selection = GridSelection(address(a1))
    }

    /// Whether Ana's workbook and this window's hold the same, comments and formulas' latest results aside.
    private var sameAsAna: Bool { Self.same(sheets.workbook, ana.workbook) }

    /// Whether two workbooks hold the same, comments and formulas' latest results aside.
    private static func same(_ here: Workbook, _ there: Workbook) -> Bool {
        guard here.sheets.map(\.id) == there.sheets.map(\.id) else { return false }
        return zip(here.sheets, there.sheets).allSatisfy { a, b in
            a.name == b.name && WorkbookOp.cellChanges(from: a, to: b).isEmpty && SheetLayoutPatch.diff(from: a, to: b).isEmpty
        }
    }

    /// How many comment threads the workbook here holds.
    private var threadCount: Int { sheets.workbook.sheets.reduce(0) { $0 + $1.cells.values.filter { $0.comment != nil }.count } }

    /// A step that acts, then waits until its check passes (or gives up).
    private func step(_ name: String, timeout: TimeInterval = 4, here: Bool = false, _ act: @escaping () -> Void = {},
                      until check: @escaping () -> Bool) {
        steps.append(Step(name: name, timeout: timeout, here: here, act: act, check: check))
    }

    private func next() {
        guard !steps.isEmpty else {
            print(failures == 0 ? "SELFTEST DONE: all passed" : "SELFTEST DONE: \(failures) failed")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        let step = steps.removeFirst()
        let undoManager = sheets.undoManager
        undoManager?.groupsByEvent = false
        // AppKit groups undo by input event; steps are not events, so each that edits gets its own group.
        if step.here { undoManager?.beginUndoGrouping() }
        step.act()
        if step.here { undoManager?.endUndoGrouping() }
        let deadline = Date().addingTimeInterval(step.timeout)
        func poll() {
            if step.check() {
                print("SELFTEST PASS: \(step.name)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.next() }
            } else if Date() > deadline {
                failures += 1
                let cells = ["A3", "B3", "A7", "A9", "F4", "B9", "K1", "K2", "L31"].map { "\($0)=\(text($0))/\(ana.text($0))" }.joined(separator: " ")
                print("SELFTEST FAIL: \(step.name) — here/ana: \(cells) same \(sameAsAna) \(session?.undoDescription ?? "")")
                print("SELFTEST INFO: notices \(cloud.notices.dropFirst(startedNotices).map { "\($0.to): \($0.title) / \($0.body)" })")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.next() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
        }
        poll()
    }

    private var everythingSent: Bool { !(session?.hasUnsentChanges ?? true) }

    /// A picture too big to travel inside a change record (its noise doesn't compress), as a pasted photo is.
    private static let testPicture: Data = {
        let width = 640, height = 480
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
                                         hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 3, bitsPerPixel: 24),
              let pixels = rep.bitmapData else { return Data() }
        var seed: UInt32 = 20_261_120
        for index in 0..<(width * height * 3) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }()

    /// Whether a cell of `controller`'s sheet holds the test picture.
    private func holdsTestPicture(_ a1: String, in controller: SpreadsheetController? = nil) -> Bool {
        (controller ?? sheets).sheet.cells[address(a1)]?.image?.image.data == Self.testPicture
    }
    private var anaCaughtUp: Bool { ana.client?.hasPending == false && everythingSent && sameAsAna }

    /// Has the stand-in tell everyone in the window's spreadsheet how it's shared, afresh.
    private func refreshSharing() {
        guard let id = session?.id, let document = cloud.documents[id] else { return }
        document.sharingVersion += 1
        cloud.changed(id)
    }

    /// The comment thread on a cell here, if any.
    private func thread(_ a1: String) -> CommentThread? {
        sheets.sheet.cells[address(a1)]?.comment
    }

    private func defineSteps() {
        // MARK: Renaming

        step("the File menu has one Rename, the standard one") {} until: {
            let file = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu
            file?.update()
            let renames = file?.items.filter { $0.title.hasPrefix("Rename") } ?? []
            return renames.count == 1 && renames.first?.action == NSSelectorFromString("renameDocument:")
        }
        step("Rename selects the whole name in the header, ready to type over") {
            self.renameRequestsBefore = self.window.state.renameRequest
            self.titleBeforeRename = self.window.state.title
            // As File ▸ Rename does for the window in front: the standard rename command, up this window's responder
            // chain. Sent this way it doesn't need PuggleSheets to be the frontmost app, which a self-test started from
            // a script may not be allowed to become.
            let window = self.window.window
            _ = (window?.firstResponder ?? window)?.tryToPerform(NSSelectorFromString("renameDocument:"), with: nil)
        } until: {
            guard self.window.state.renameRequest > self.renameRequestsBefore,
                  let field = self.window.window?.firstResponder as? NSTextView, field.isFieldEditor, !field.string.isEmpty
            else { return false }
            return field.selectedRange() == NSRange(location: 0, length: (field.string as NSString).length)
        }
        step("leaving the name as it was changes nothing") {
            self.window.window?.makeFirstResponder(nil)
        } until: {
            !((self.window.window?.firstResponder as? NSTextView)?.isFieldEditor ?? false) && self.window.state.title == self.titleBeforeRename
        }

        // MARK: Sharing a spreadsheet of this person's

        step("a new spreadsheet isn't shared", here: true) {
            self.type("Budget", in: "A1")
            self.type("100", in: "B1")
            self.type("Rent", in: "A2")
            self.type("=B1*3", in: "B2")
        } until: {
            !self.state.isShared && self.text("A1") == "Budget" && self.sheets.sheet[self.address("B2")].value == .number(300)
        }
        step("it's saved on this Mac before it's shared") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Collaboration self-test \(UUID().uuidString.prefix(6)).xlsx")
            self.document.save(to: url, ofType: SpreadsheetFileFormat.xlsx.typeIdentifier, for: .saveAsOperation) { _ in }
        } until: {
            self.document.fileURL != nil
        }
        step("sharing makes it live, with undo kept by the shared spreadsheet") {
            self.model = CollaborateModel(controller: CollaborationController.shared, windowController: self.window)
            self.model.share()
        } until: {
            self.state.isShared && self.session?.phase == .live && self.sheets.collaboration === self.session
                && self.cloud.documents[self.session?.id ?? UUID()] != nil && self.state.statusText == "Saved in iCloud"
        }
        step("invited people join, one to edit and one to comment") {
            self.model.address = "ana@example.com"
            self.model.invitePermission = .edit
            self.model.invite()
            self.model.address = "ben@example.com"
            self.model.invitePermission = .comment
            self.model.invite()
        } until: {
            self.state.collaborators.count == 3 && self.state.collaborators.allSatisfy { $0.status == .joined }
                && self.state.collaborators.first(where: { $0.id == "ben@example.com" })?.permission == .comment
        }
        step("a collaborator's Mac opens it with the same cells") {
            self.ana.join(self.session!.id)
        } until: {
            self.ana.text("A1") == "Budget" && self.ana.text("B2") == "=B1*3" && self.sameAsAna
        }
        step("their typing shows up here") {
            self.ana.type("42", in: "C3")
        } until: {
            self.text("C3") == "42"
        }
        step("typing here reaches them", here: true) {
            self.type("Hello", in: "A5")
        } until: {
            self.ana.text("A5") == "Hello" && self.everythingSent
        }
        step("their formula is worked out here") {
            self.ana.type("=B1*2", in: "D1")
        } until: {
            self.text("D1") == "=B1*2" && self.sheets.sheet[self.address("D1")].value == .number(200)
        }
        step("a picture they put in a cell arrives as the same picture") {
            self.ana.insertImage(Self.testPicture, in: "E1")
        } until: {
            self.holdsTestPicture("E1") && self.sameAsAna
        }
        step("rows inserted here move what they type below them at the same time", here: true) {
            self.select("A3")
            self.sheets.insertRows(above: true)
            self.ana.type("Below", in: "A6")
        } until: {
            self.text("A7") == "Below" && self.ana.text("A7") == "Below" && self.text("A6") == "Hello"
                && self.text("C4") == "42" && self.anaCaughtUp
        }
        step("their rows inserted while this Mac types move its typing too", here: true) {
            self.ana.insertRows(at: 0, count: 2)
            self.type("Mine", in: "F2")
        } until: {
            self.text("F4") == "Mine" && self.ana.text("F4") == "Mine" && self.text("A3") == "Budget" && self.text("B4") == "=B3*3"
                && self.anaCaughtUp
        }
        step("the same cell typed into at once ends the same on both Macs", here: true) {
            self.type("Here", in: "B9")
            self.ana.type("There", in: "B9")
        } until: {
            self.anaCaughtUp && self.text("B9") == self.ana.text("B9") && ["Here", "There"].contains(self.text("B9"))
        }
        step("editing at random at the same time ends the same on both Macs", timeout: 8, here: true) {
            for round in 0..<20 {
                let column = ["G", "H", "I"][round % 3]
                self.type("\(round)", in: "\(column)\(Int.random(in: 11...20, using: &self.random))")
                self.ana.type("a\(round)", in: "\(column)\(Int.random(in: 11...20, using: &self.random))")
                if round % 6 == 0 { self.ana.insertRows(at: Int.random(in: 10...15, using: &self.random), count: 1) }
                if round % 7 == 3 {
                    self.select("A\(Int.random(in: 12...16, using: &self.random))")
                    self.sheets.insertRows(above: true)
                }
            }
        } until: {
            self.anaCaughtUp
        }

        // MARK: Undo

        step("undo takes back this Mac's typing, not theirs", here: true) {
            self.type("MINE", in: "K1")
        } until: {
            self.ana.text("K1") == "MINE" && self.everythingSent
        }
        step("their typing comes in after it") {
            self.ana.type("THEIRS", in: "K2")
        } until: {
            self.text("K2") == "THEIRS"
        }
        step("undo: only this Mac's typing goes") {
            self.sheets.undoManager?.undo()
        } until: {
            self.text("K1").isEmpty && self.text("K2") == "THEIRS" && self.ana.text("K1").isEmpty && self.anaCaughtUp
        }
        step("redo: it comes back for everyone") {
            self.sheets.undoManager?.redo()
        } until: {
            self.text("K1") == "MINE" && self.ana.text("K1") == "MINE" && self.anaCaughtUp
        }
        step("a row inserted here", here: true) {
            self.select("A30")
            self.sheets.insertRows(above: true)
        } until: {
            self.anaCaughtUp
        }
        step("their typing below the new row") {
            self.ana.type("Kept", in: "L32")
        } until: {
            self.text("L32") == "Kept"
        }
        step("undo takes the row out and keeps their typing, moved up") {
            self.sheets.undoManager?.undo()
        } until: {
            self.text("L31") == "Kept" && self.ana.text("L31") == "Kept" && self.anaCaughtUp
        }
        step("the header shows who else is in it, viewing now") {} until: {
            let others = self.state.others
            guard let ana = others.first(where: { $0.id == "ana@example.com" }) else { return false }
            return others.count == 2 && ana.initials == "AL" && self.state.isViewing(ana)
        }
        step("when iCloud doesn't say who people are, the header still names them") {
            self.cloud.hidesIdentities = true
            self.refreshSharing()
        } until: {
            guard self.state.collaborators.contains(where: { $0.id.hasPrefix("hidden-") }) else { return false }
            let others = self.state.others
            guard let ana = others.first(where: { $0.displayName == "Ana Lopez" }) else { return false }
            return ana.initials == "AL" && self.state.isViewing(ana) && !others.contains { $0.displayName == "Someone" }
        }
        step("and iCloud's names come back when it says them") {
            self.cloud.hidesIdentities = false
            self.refreshSharing()
        } until: {
            !self.state.collaborators.contains { $0.id.hasPrefix("hidden-") } && self.state.others.contains { $0.id == "ana@example.com" }
        }

        // MARK: Comments

        step("their comment shows here, on its cell") {
            self.ana.comment("Check this number", on: "B3")
        } until: {
            self.thread("B3")?.comments.first?.text == "Check this number"
        }
        step("a comment here reaches them", here: true) {
            self.sheets.addComment("Which budget?", at: self.address("A3"))
        } until: {
            self.ana.comments.values.contains { $0.thread.comments.first?.text == "Which budget?" && $0.thread.comments.first?.authorID == StandInCloud.me.id }
        }
        step("replies go both ways", here: true) {
            guard let id = self.thread("B3")?.id else { return }
            self.sheets.addComment("It's right.", at: self.address("B3"))
            self.ana.reply("Thanks!", to: id)
        } until: {
            Set(self.thread("B3")?.comments.map(\.text) ?? []) == ["Check this number", "It's right.", "Thanks!"]
        }
        step("rows they insert above a comment carry it along here") {
            self.ana.insertRows(at: 0, count: 1)
        } until: {
            self.thread("B4")?.comments.first?.text == "Check this number" && self.thread("B3") == nil && self.anaCaughtUp
        }
        step("resolving here reaches them", here: true) {
            self.sheets.setCommentResolved(true, at: self.address("B4"))
        } until: {
            self.ana.comments.values.contains { $0.thread.comments.first?.text == "Check this number" && $0.thread.isResolved }
        }
        step("their reply comes in while it's resolved") {
            guard let id = self.thread("B4")?.id else { return }
            self.ana.reply("One more thing", to: id)
        } until: {
            self.thread("B4")?.comments.contains { $0.text == "One more thing" } == true
        }
        step("undo opens it again here and there, and keeps their reply") {
            self.sheets.undoManager?.undo()
        } until: {
            guard let here = self.thread("B4"), let there = self.ana.comments[here.id]?.thread else { return false }
            return !here.isResolved && here.comments.contains { $0.text == "One more thing" }
                && !there.isResolved && there.comments.contains { $0.text == "One more thing" }
        }
        step("their comments can't be edited here, only this person's own") {} until: {
            guard let thread = self.thread("B4"), let theirs = thread.comments.first,
                  let mine = thread.comments.first(where: { $0.text == "It's right." }) else { return false }
            return !self.sheets.mayEditComment(theirs) && self.sheets.mayEditComment(mine) && self.sheets.mayDeleteComment(theirs)
        }

        // MARK: Access

        step("taking them down to commenting stops their edits") {
            guard let ana = self.state.collaborators.first(where: { $0.id == "ana@example.com" }) else { return }
            self.model.setPermission(.comment, for: ana)
        } until: {
            self.ana.sharing?.myPermission == .comment
        }
        step("their changes are turned down, and don't reach this Mac") {
            self.ana.type("NOPE", in: "M1")
        } until: {
            self.ana.refusals > 0 && self.text("M1").isEmpty
        }
        step("but they can still comment") {
            self.ana.comment("Still reading along", on: "A1")
        } until: {
            self.thread("A1")?.comments.first?.text == "Still reading along"
        }

        // MARK: Telling the others

        step("after a quiet spell the others get one summary") {
            self.startedNotices = self.cloud.notices.count
        } until: {
            let fresh = self.cloud.notices.dropFirst(self.startedNotices)
            let toAna = fresh.filter { $0.to == "ana@example.com" }
            guard toAna.count == 1, let notice = toAna.first else { return false }
            return notice.title.hasPrefix("Alex Morgan edited “Collaboration self-test") && notice.body.hasSuffix(".")
                && fresh.contains { $0.to == "ben@example.com" }
        }
        step("the next quiet spell brings a summary of what's new since", here: true) {
            self.startedNotices = self.cloud.notices.count
            self.type("1", in: "N1")
            self.type("2", in: "N2")
            self.type("3", in: "N3")
        } until: {
            let toAna = self.cloud.notices.dropFirst(self.startedNotices).filter { $0.to == "ana@example.com" }
            return toAna.count == 1 && toAna.first?.body == "Edited 3 cells on Sheet1."
        }
        step("a summary of rows inserted and a comment", here: true) {
            self.startedNotices = self.cloud.notices.count
            self.select("A40")
            self.sheets.insertRows(above: true)
            self.sheets.addComment("Added a row for taxes", at: self.address("A40"))
        } until: {
            let toAna = self.cloud.notices.dropFirst(self.startedNotices).filter { $0.to == "ana@example.com" }
            return toAna.count == 1 && toAna.first?.body == "Inserted a row and added a comment."
        }
        // MARK: Offline

        step("when iCloud can't be reached, it can't be changed, and the window says why") {
            self.window.showSidebar(.conditionalFormatting)
            self.cloud.isReachable = false
        } until: {
            guard let mine = self.thread("B4")?.comments.first(where: { $0.text == "It's right." }) else { return false }
            let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "")
            let paste = NSMenuItem(title: "Paste", action: #selector(DocumentWindowController.paste(_:)), keyEquivalent: "")
            let copy = NSMenuItem(title: "Copy", action: #selector(DocumentWindowController.copy(_:)), keyEquivalent: "")
            let comment = NSMenuItem(title: "Comment", action: #selector(SheetCommands.psInsertComment(_:)), keyEquivalent: "")
            let window = self.window
            return window.state.access == .offline && !window.state.isEditable && window.state.accessBadge?.title == "Offline"
                && self.state.statusText.hasPrefix("Offline") && (window.state.banner ?? "").hasPrefix("You’re offline")
                && window.window?.undoManager == nil && !(window.window?.validateUserInterfaceItem(undo) ?? true)
                && !window.validateMenuItem(paste) && window.validateMenuItem(copy)
                // Read-only, comments included: they show, without anything to add, answer or change them.
                && !window.state.canComment && !window.validateMenuItem(comment)
                && !self.sheets.mayEditComment(mine) && !self.sheets.mayDeleteComment(mine)
                // Nor anything else that only changes it: a sidebar that edits closes, the sheet's menu is all disabled.
                && window.state.sidebar == nil && !window.grid.canChange && window.grid.footerButtonRect == nil
                && window.sheetMenu(for: self.sheets.activeSheetID).items.allSatisfy { !$0.isEnabled || $0.isSeparatorItem }
        }
        step("meanwhile typing and commenting change nothing, and nothing waits to be sent", here: true) {
            self.offlineWorkbook = self.sheets.workbook
            self.offlineThreads = self.threadCount
            self.type("Offline?", in: "P1")
            self.sheets.addComment("Offline comment", at: self.address("P2"))
            self.select("A1")
            self.sheets.insertRows(above: true)
            // Someone else comments while this Mac is away.
            self.ana.comment("While you were away", on: "O1")
        } until: {
            Self.same(self.sheets.workbook, self.offlineWorkbook) && self.threadCount == self.offlineThreads
                && self.thread("P2") == nil && self.everythingSent && self.window.state.access == .offline
        }
        step("once iCloud's back, it can be changed again and catches up with what others did", timeout: 12) {
            self.cloud.isReachable = true
        } until: {
            let window = self.window
            return window.state.access == .full && window.state.canComment && !self.state.statusText.hasPrefix("Offline")
                && window.state.banner == nil && window.window?.undoManager === self.document.undoManager
                && self.thread("O1")?.comments.first?.text == "While you were away"
        }
        step("and typing here reaches them again", here: true) {
            self.type("Back online", in: "P1")
        } until: {
            self.ana.text("P1") == "Back online" && self.everythingSent
        }
        step("a change made as the connection drops is kept, and doesn't go while it's down", here: true) {
            self.type("Just in time", in: "Q1")
            self.cloud.isReachable = false
        } until: {
            self.window.state.access == .offline && self.text("Q1") == "Just in time"
        }
        step("it goes, merged, once iCloud's back", timeout: 12) {
            self.ana.comment("Meanwhile", on: "Q2")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.cloud.isReachable = true }
        } until: {
            self.window.state.access == .full && self.ana.text("Q1") == "Just in time" && self.text("Q1") == "Just in time"
                && self.thread("Q2")?.comments.first?.text == "Meanwhile" && self.everythingSent
        }

        step("renaming it here renames it for everyone it's shared with") {
            self.window.rename(to: "Renamed budget")
        } until: {
            self.cloud.documents[self.session?.id ?? UUID()]?.title == "Renamed budget" && self.window.state.title == "Renamed budget"
                && self.window.state.showsCollaborateButton
        }

        // MARK: Stopping

        step("stopping sharing keeps the spreadsheet here, and closes it for the others") {
            self.model.stopSharing()
        } until: {
            !self.state.isShared && self.document.collaboration == nil && self.ana.isGone && self.window.state.access == .full
                && self.text("A4") == "Budget" && self.cloud.documents.isEmpty
        }

        // MARK: A spreadsheet someone else shares

        step("a spreadsheet shared with this person opens in a window of its own") {
            var sheet = Sheet(name: "Numbers")
            sheet[0, 0] = Cell(value: .text("Notes from Ben"))
            sheet[0, 1] = Cell(value: .number(5))
            self.bensSpreadsheet = self.ben.share(title: "Ben’s numbers", workbook: Workbook(sheets: [sheet]), with: [(StandInCloud.me, .comment)])
        } until: {
            guard let id = self.bensSpreadsheet, let entry = CollaborationController.shared.sharedWithMe.first(where: { $0.id == id }) else { return false }
            if self.bensWindow == nil {
                CollaborationController.shared.openShared(entry)
                self.bensWindow = NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
                    .first { $0.spreadsheet?.sharedCopy?.id == id }
            }
            guard let window = self.bensWindow else { return false }
            return window.controller.editText(at: self.address("A1")) == "Notes from Ben" && window.spreadsheet?.collaboration?.phase == .live
        }
        step("it's read-only here, but can be commented on") {
            guard let window = self.bensWindow else { return }
            window.controller.addComment("Thanks for these", at: self.address("B1"))
        } until: {
            guard let window = self.bensWindow else { return false }
            let collaborate = NSMenuItem(title: "Collaborate…", action: #selector(SheetCommands.psCollaborate(_:)), keyEquivalent: "")
            let leave = NSMenuItem(title: "Leave", action: #selector(SheetCommands.psLeaveShared(_:)), keyEquivalent: "")
            let paste = NSMenuItem(title: "Paste", action: #selector(DocumentWindowController.paste(_:)), keyEquivalent: "")
            let insertRow = NSMenuItem(title: "Insert", action: #selector(SheetCommands.psInsertRowsAbove(_:)), keyEquivalent: "")
            return window.state.access == .commentOnly && self.ben.comments.values.contains { $0.thread.comments.first?.text == "Thanks for these" }
                && !window.state.showsCollaborateButton && !window.validateMenuItem(collaborate) && collaborate.isHidden
                && window.validateMenuItem(leave) && !leave.isHidden && !window.validateMenuItem(paste) && !window.validateMenuItem(insertRow)
        }
        step("typing in it changes nothing") {
            guard let window = self.bensWindow else { return }
            self.type("Sneaky", in: "C1", controller: window.controller)
            window.controller.selection = GridSelection(self.address("A1"))
            window.controller.insertRows(above: true)
        } until: {
            guard let window = self.bensWindow else { return false }
            return window.controller.editText(at: self.address("C1")).isEmpty && self.ben.text("C1").isEmpty
                && window.controller.editText(at: self.address("A1")) == "Notes from Ben"
        }
        step("its owner's edits show up live") {
            self.ben.type("Update", in: "A2")
        } until: {
            self.bensWindow?.controller.editText(at: self.address("A2")) == "Update"
        }
        step("a change iCloud passes over while reading still comes, and so do the ones after it", timeout: 12) {
            guard let id = self.bensSpreadsheet else { return }
            self.cloud.skippedRevisions = [(self.cloud.documents[id]?.changes.keys.max() ?? 0) + 1]
            self.ben.type("Skipped?", in: "D1")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.ben.type("After", in: "D2") }
        } until: {
            guard let window = self.bensWindow else { return false }
            return window.controller.editText(at: self.address("D1")) == "Skipped?" && window.controller.editText(at: self.address("D2")) == "After"
        }
        step("its owner's comments show up here as they're made, on their cell") {
            self.cloud.skippedRevisions = []
            self.ben.comment("Dates are in column C", on: "A2")
        } until: {
            self.bensWindow?.controller.sheet.cells[self.address("A2")]?.comment?.comments.first?.text == "Dates are in column C"
        }
        step("a picture its owner puts in a cell shows up here") {
            self.ben.insertImage(Self.testPicture, in: "C2")
        } until: {
            guard let window = self.bensWindow else { return false }
            return self.holdsTestPicture("C2", in: window.controller)
        }
        step("its owner renaming it renames it here") {
            self.ben.rename("Ben’s renamed numbers")
        } until: {
            self.bensWindow?.state.title == "Ben’s renamed numbers" && self.bensWindow?.spreadsheet?.displayName == "Ben’s renamed numbers"
        }
        step("it can still be printed, downloaded and copied") {} until: {
            guard let window = self.bensWindow, let document = window.spreadsheet else { return false }
            let print = NSMenuItem(title: "Print", action: #selector(SheetCommands.psPrint(_:)), keyEquivalent: "")
            let copy = NSMenuItem(title: "Make a copy", action: #selector(NSDocument.duplicate(_:)), keyEquivalent: "")
            let download = NSMenuItem(title: "Download", action: #selector(SheetCommands.psDownload(_:)), keyEquivalent: "")
            return window.validateMenuItem(print) && document.validateUserInterfaceItem(copy) && window.validateMenuItem(download)
                && (try? document.data(ofType: SpreadsheetFileFormat.xlsx.typeIdentifier)) != nil
        }
        step("when its owner stops sharing, it goes, saying so") {
            self.ben.stopSharing()
        } until: {
            guard let window = self.bensWindow?.window else { return true }
            guard let alert = window.attachedSheet,
                  (window.windowController as? DocumentWindowController)?.controller.workbook.sheets.allSatisfy({ $0.cells.isEmpty }) == true else { return false }
            window.endSheet(alert, returnCode: .alertFirstButtonReturn)
            return true
        }
        step("its window closes") {} until: {
            !NSApp.windows.contains { ($0.windowController as? DocumentWindowController)?.spreadsheet?.sharedCopy != nil }
        }

        // MARK: An invitation link pasted in

        step("an invitation link pasted into PuggleSheets opens its spreadsheet") {
            var sheet = Sheet(name: "Open")
            sheet[0, 0] = Cell(value: .text("Anyone with this link can read it."))
            let id = self.cy.share(title: "Cy’s numbers", workbook: Workbook(sheets: [sheet]), with: [], access: .anyoneWithLink)
            self.linkedSpreadsheet = id
            CollaborationController.shared.openInvitationLink(URL(string: "https://share.pugglesoft.invalid/\(id.uuidString.lowercased())")!)
        } until: {
            NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }.contains {
                $0.spreadsheet?.sharedCopy?.id == self.linkedSpreadsheet
                    && $0.controller.editText(at: self.address("A1")) == "Anyone with this link can read it."
                    && $0.state.access == .commentOnly
            } && CollaborationController.shared.sharedWithMe.contains { $0.id == self.linkedSpreadsheet }
        }
        step("a link to a spreadsheet shared only with other people doesn't open") {
            let id = self.cy.share(title: "Cy’s private numbers", workbook: Workbook(), with: [], access: .invited)
            CollaborationController.shared.openInvitationLink(URL(string: "https://share.pugglesoft.invalid/\(id.uuidString.lowercased())")!) { error in
                self.linkRefused = error != nil
            }
        } until: {
            self.linkRefused
        }
    }
}
#endif
