import AppKit
import Observation
import PuggleSheetsKit

/// What the header shows about a spreadsheet's sharing: who's in it, who has it open, and how it's keeping up.
@Observable
final class CollaborationState {
    var isShared = false
    var isOwner = true
    var ownerName = ""
    /// What this Mac's person can do.
    var permission: CollaboratorPermission = .edit
    /// Everyone it's shared with, the owner first.
    var collaborators: [Collaborator] = []
    /// Who has it open, as last heard, by iCloud identity.
    var presence: [String: Presence] = [:]
    var meID: String?
    /// Words for how the shared copy is keeping up, in place of the file's save status.
    var statusText = ""
    var statusSymbol = "icloud"
    /// Bumped as time passes, so "last seen" words keep up.
    var clock = Date()

    /// The people other than this Mac's who are in it, the owner first: the round badges in the header. Everyone who
    /// has opened it, named as they name themselves, so they show even when iCloud doesn't say who they are; then
    /// those iCloud lists as joined who haven't, by names not shown already, so nobody shows twice.
    var others: [Collaborator] {
        var people: [Collaborator] = []
        for item in presence.values where item.person != meID {
            var person = collaborators.first { $0.id == item.person }
                ?? Collaborator(id: item.person, name: item.info.name, isOwner: item.info.isOwner ?? false,
                                permission: item.info.permission ?? .comment, status: .joined)
            if person.name.isEmpty { person.name = item.info.name }
            people.append(person)
        }
        for person in collaborators where person.id != meID && person.status == .joined && !people.contains(where: { $0.id == person.id }) {
            guard people.isEmpty || (!person.name.isEmpty && !people.contains { $0.name == person.name }) else { continue }
            people.append(person)
        }
        return people.sorted { ($0.isOwner ? 0 : 1, $0.displayName.lowercased()) < ($1.isOwner ? 0 : 1, $1.displayName.lowercased()) }
    }

    func isViewing(_ person: Collaborator) -> Bool { presence[person.id]?.isActive(now: clock) ?? false }

    func lastSeen(_ person: Collaborator) -> Date? { presence[person.id]?.date }

    func reset() {
        isShared = false
        isOwner = true
        ownerName = ""
        permission = .edit
        collaborators = []
        presence = [:]
        statusText = ""
    }
}

/// What an edit is about to change, as it is, without holding on to the whole workbook (which would make the edit
/// copy every cell of the sheets it changes): the cells it sets and the layout of the sheets whose layout it changes,
/// or, for edits that move rows, columns or sheets, the whole workbook.
struct EditCapture {
    var workbook: Workbook?
    /// The cells, comments included, by sheet.
    var cells: [UUID: [CellAddress: Cell]] = [:]
    /// The sheets, without their cells.
    var layouts: [UUID: Sheet] = [:]
    var names: [UUID: String] = [:]

    init(_ changes: [WorkbookChange], from workbook: Workbook) {
        for change in changes {
            switch change {
            case .workbook, .ops:
                self.workbook = workbook
            case .cells(let id, let changed):
                guard let index = workbook.sheetIndex(id: id) else { continue }
                names[id] = workbook.sheets[index].name
                var old = cells[id] ?? [:]
                for address in changed.keys where old[address] == nil { old[address] = workbook.sheets[index].cells[address] ?? Cell() }
                cells[id] = old
            case .layout(let id, _):
                guard layouts[id] == nil, let index = workbook.sheetIndex(id: id) else { continue }
                let sheet = workbook.sheets[index]
                var layout = Sheet(name: sheet.name, id: sheet.id, rowCount: sheet.rowCount, columnCount: sheet.columnCount)
                SheetLayout(sheet).apply(to: &layout)
                layouts[id] = layout
                names[id] = sheet.name
            }
        }
    }

    /// The cells touched, on sheets of their names: enough to tell what an edit did to them.
    var touchedWorkbook: Workbook {
        let ids = Array(Set(cells.keys).union(layouts.keys))
        guard !ids.isEmpty else { return Workbook() }
        return Workbook(sheets: ids.map { id in
            var sheet = layouts[id] ?? Sheet(name: names[id] ?? "", id: id)
            sheet.setCells((cells[id] ?? [:]).mapValues(\.withoutComment))
            return sheet
        })
    }
}

/// A comment thread an edit here changed, and what undoing it puts back.
private struct CommentStep {
    let id: UUID
    /// The thread before the edit (nil: the edit started it) and after (nil: the edit deleted it).
    let before: CommentThread?
    let after: CommentThread?
    /// Where it was before the edit, else where it is after: where undoing it puts it back.
    var place: (sheet: UUID, address: CellAddress)
}

/// An undo step of this Mac's in a shared spreadsheet: the ops that take it back and the comments to put back as they
/// were, kept following other people's changes as they come in, so undo only ever takes back this person's own edits,
/// wherever they've moved to.
private final class UndoEntry {
    var ops: [WorkbookOp]
    var comments: [CommentStep]
    let actionName: String
    /// The sheet and selection to show again.
    let sheet: UUID
    var selection: GridSelection

    init(ops: [WorkbookOp], comments: [CommentStep], actionName: String, sheet: UUID, selection: GridSelection) {
        self.ops = ops
        self.comments = comments
        self.actionName = actionName
        self.sheet = sheet
        self.selection = selection
    }
}

/// One open spreadsheet's part in sharing: its workbook kept the same as everyone else's through the spreadsheet's
/// log (see `SyncClient`), its comments through the talk zone, who's in it, and the short summaries that tell the
/// others what changed.
///
/// While a spreadsheet is shared, every edit made here (each goes through `SpreadsheetController.perform`) becomes ops
/// for the log, sent one change after another; other people's changes are applied as they come. Undo works on this
/// Mac's own edits, through steps kept here rather than the controller's.
final class SpreadsheetCollaboration: NSObject {
    enum Phase: Equatable {
        /// Waiting for the shared copy to load.
        case connecting
        case live
        case ended
    }

    /// How long a run of changes waits for the next before the others are told about it.
    static var noticeDelay: TimeInterval = 120

    let id: UUID
    let isOwner: Bool
    /// For spreadsheets shared with this person, whose iCloud they're in.
    let ownerID: String?
    private unowned let controller: CollaborationController
    private(set) weak var document: SpreadsheetDocument?
    private weak var windowController: DocumentWindowController?
    private(set) var client: SyncClient?
    private var channel: CollaborationChannel?
    private(set) var sharing: DocumentSharing?
    private(set) var phase: Phase = .connecting
    private var info: SharedDocumentInfo?
    /// Changes that came before the snapshot they follow.
    private var earlyChanges: [LoggedChange] = []
    private var isApplyingRemote = false
    private var undoEntries: [UndoEntry] = []
    private var redoEntries: [UndoEntry] = []
    /// Comment threads as iCloud last had them, by id.
    private var serverComments: [UUID: SharedComment] = [:]
    /// Threads from others whose cells wait for their revision of the log to come.
    private var waitingComments: [UUID: SharedComment] = [:]
    /// Threads started here on cells that aren't in the log yet (in rows inserted here), to save once they are.
    private var unanchoredComments: Set<UUID> = []
    /// Where the snapshot this Mac started from says each thread was.
    private var snapshotPlaces: [UUID: CommentAnchor] = [:]
    private var tally = ChangeTally()
    private var noticeWork: DispatchWorkItem?
    private var snapshotWork: DispatchWorkItem?
    private var lastSnapshotRevision = 0
    private var retryDelay: TimeInterval = 1
    private var retryScheduled = false
    /// Why changes can't be saved to iCloud just now, when they can't. Meanwhile the window takes none: nothing made
    /// in a shared spreadsheet is kept to send later.
    private enum Blocked: Equatable {
        /// iCloud can't be reached: the Mac is offline, say.
        case offline
        /// iCloud turned a change down, saying why.
        case refused(String)
    }
    private var blocked: Blocked?
    /// The window's banner as this session last set it, so coming back online takes away only its own.
    private var blockedBanner: String?
    private var heartbeat: Timer?
    /// Looking again for a change of the log that others came ahead of, longer apart each time.
    private var gapCheck: DispatchWorkItem?
    private var gapDelay: TimeInterval = 1

    init(id: UUID, isOwner: Bool, ownerID: String?, controller: CollaborationController, document: SpreadsheetDocument,
         windowController: DocumentWindowController) {
        self.id = id
        self.isOwner = isOwner
        self.ownerID = ownerID
        self.controller = controller
        self.document = document
        self.windowController = windowController
        super.init()
    }

    private var sheets: SpreadsheetController? { windowController?.controller }
    private var state: CollaborationState? { windowController?.state.collaboration }
    var title: String { windowController?.state.title ?? info?.title ?? "Untitled spreadsheet" }
    var me: Collaborator? { controller.status.me }

    var isLive: Bool { phase == .live }

    /// Whether this person may change the cells.
    var canEdit: Bool { isOwner || (sharing?.myPermission ?? .comment) == .edit }

    /// Whether changes made here haven't all reached iCloud.
    var hasUnsentChanges: Bool { phase == .live && (client?.hasPending ?? false) }

    // MARK: Starting and ending

    /// Shares the spreadsheet for the first time, as it is now, then carries on live.
    func startSharing(access: LinkAccess, permission: CollaboratorPermission, completion: @escaping (Error?) -> Void) {
        guard let sheets else { return }
        let workbook = sheets.workbook
        let snapshot = SyncSnapshot(revision: 0, workbook: workbook, anchors: Self.anchors(in: workbook, revision: 0))
        let comments = workbook.commentPlaces.values.map {
            SharedComment(thread: $0.thread, anchor: CommentAnchor(revision: 0, sheet: $0.sheet, address: $0.address))
        }
        controller.service.share(id, title: title, snapshot: snapshot, comments: comments, access: access, permission: permission) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(sharing):
                self.sharing = sharing
                for comment in comments { serverComments[comment.thread.id] = comment }
                client = SyncClient(revision: 0, workbook: snapshot.workbook, author: me?.id ?? "me", authorName: me?.name ?? NSFullUserName())
                lastSnapshotRevision = 0
                info = SharedDocumentInfo(title: title, ownerName: me?.name ?? "")
                updateState()
                goLive()
                connectChannel()
                completion(nil)
            case let .failure(error):
                completion(error)
            }
        }
    }

    /// Opens the shared copy: until it's here, the window shows what it has, and nothing can be changed.
    func connect() {
        phase = .connecting
        windowController?.setAccess(.locked)
        updateState()
        connectChannel()
    }

    private func connectChannel() {
        let channel = controller.service.connect(id, owner: isOwner ? nil : ownerID, delegate: self)
        self.channel = channel
        channel.start()
    }

    private func goLive() {
        guard phase != .ended else { return }
        phase = .live
        document?.undoManager?.removeAllActions()
        applyPermission()
        announcePresence(viewing: true)
        // A file of this person's renamed while it was closed: everyone gets its new name.
        titleChanged()
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.announcePresence(viewing: true)
                self.state?.clock = Date()
            }
        }
        updateState()
        flush()
    }

    /// Stops taking part: the channel closes, and undo goes back to the controller's own.
    func end(saying presenceEnds: Bool = true) {
        guard phase != .ended else { return }
        sendNotice()
        if presenceEnds { announcePresence(viewing: false) }
        phase = .ended
        channel?.stop()
        channel = nil
        heartbeat?.invalidate()
        heartbeat = nil
        snapshotWork?.cancel()
        noticeWork?.cancel()
        gapCheck?.cancel()
        gapCheck = nil
        undoEntries = []
        redoEntries = []
        document?.undoManager?.removeAllActions()
    }

    /// The owner renamed the spreadsheet: its name in iCloud follows, and with it the name everyone else sees.
    func titleChanged() {
        guard isOwner, phase == .live else { return }
        channel?.setTitle(title)
    }

    /// Tells the others whether this person has the spreadsheet open, and who they are in it.
    private func announcePresence(viewing: Bool) {
        channel?.setPresence(viewing: viewing, isOwner: isOwner, permission: isOwner ? .edit : (sharing?.myPermission ?? .comment))
    }

    /// The window is closing: everyone's told this person has gone.
    func close() {
        end()
        controller.unregister(self)
    }

    private func applyPermission() {
        switch phase {
        case .connecting: windowController?.setAccess(.locked)
        case .ended: break
        case .live: windowController?.setAccess(blocked != nil ? .offline : (canEdit ? .full : .commentOnly))
        }
    }

    // MARK: Edits made here

    /// An edit made here: its ops go to the others, its comments to the talk zone, and what takes it back to undo.
    /// `capture` holds what the edit touched as it was; `after` is the workbook now.
    func recorded(_ changes: [WorkbookChange], capture: EditCapture, after: Workbook, actionName: String,
                  selections: (before: (UUID, GridSelection), after: (UUID, GridSelection))) {
        guard phase == .live, !isApplyingRemote, let client else { return }
        var ops: [WorkbookOp]
        var undo: [WorkbookOp]
        let comments: [CommentStep]
        let before: Workbook
        if let whole = capture.workbook {
            // Rows, columns or sheets moved: worked out from the whole workbook, before and after.
            comments = Self.commentSteps(before: whole.commentPlaces, after: after.commentPlaces)
            ops = canEdit ? Self.ops(for: changes, before: whole, after: after) : []
            undo = ops.isEmpty ? [] : WorkbookOp.inverse(of: ops, before: whole, after: after)
            before = whole
        } else {
            (ops, undo, comments) = Self.keyedOps(capture, after: after)
            before = capture.touchedWorkbook
            // Someone who may only comment never changes the cells; anything else made here stays here.
            if !canEdit {
                ops = []
                undo = []
            }
        }
        guard !ops.isEmpty || !comments.isEmpty else { return }
        if !ops.isEmpty {
            client.local(SharedChange(ops))
            tally.record(ops, before: before)
        }
        save(comments, movedByEdit: changes.contains { if case .ops = $0 { false } else { true } })
        registerUndo(undo, comments: comments, actionName: actionName, shown: selections.before)
        noteLocalAction()
        flush()
    }

    /// The ops of an edit that moved rows, columns or sheets, or replaced the workbook: its own ops (checked against
    /// what it did), or what turns the workbook before it into the one after.
    private static func ops(for changes: [WorkbookChange], before: Workbook, after: Workbook) -> [WorkbookOp] {
        let explicit = changes.flatMap { change -> [WorkbookOp] in
            if case .ops(let ops) = change { ops.map(\.withoutComments) } else { [] }
        }
        if explicit.isEmpty { return WorkbookOp.changes(from: before, to: after) }
        return WorkbookOp.checked(explicit, from: before, to: after)
    }

    /// The ops of an edit that only set cells and layout parts, what takes them back, and the comments it changed.
    private static func keyedOps(_ capture: EditCapture, after: Workbook) -> (ops: [WorkbookOp], undo: [WorkbookOp], comments: [CommentStep]) {
        var ops: [WorkbookOp] = []
        var undo: [WorkbookOp] = []
        var oldThreads: [UUID: (sheet: UUID, address: CellAddress, thread: CommentThread)] = [:]
        var newThreads: [UUID: (sheet: UUID, address: CellAddress, thread: CommentThread)] = [:]
        for (id, old) in capture.cells {
            guard let index = after.sheetIndex(id: id) else { continue }
            var set: [CellAddress: Cell] = [:]
            var back: [CellAddress: Cell] = [:]
            for (address, was) in old {
                let now = after.sheets[index].cells[address] ?? Cell()
                if !was.withoutComment.hasSameContent(as: now.withoutComment) {
                    set[address] = now.withoutComment
                    back[address] = was.withoutComment
                }
                if let thread = was.comment { oldThreads[thread.id] = (id, address, thread) }
                if let thread = now.comment { newThreads[thread.id] = (id, address, thread) }
            }
            if !set.isEmpty {
                ops.append(.cells(sheet: id, cells: set))
                undo.append(.cells(sheet: id, cells: back))
            }
        }
        for (id, layout) in capture.layouts {
            guard let index = after.sheetIndex(id: id) else { continue }
            let patch = SheetLayoutPatch.diff(from: layout, to: after.sheets[index])
            guard !patch.isEmpty else { continue }
            ops.append(.layout(sheet: id, patch: patch))
            undo.append(.layout(sheet: id, patch: SheetLayoutPatch.current(patch.entries.keys, of: layout)))
        }
        return (ops, undo, commentSteps(before: oldThreads, after: newThreads))
    }

    /// Sends the next change, if one's waiting and none is on its way.
    func flush() {
        guard phase == .live, let client, let channel else { return }
        guard let next = client.nextToSend() else {
            updateState()
            return
        }
        updateState()
        channel.claim(next) { [weak self] result in
            guard let self, let client = self.client else { return }
            switch result {
            case .claimed:
                client.sent(next.id)
                markOnline()
                afterConfirm()
            case let .taken(existing):
                apply(client.sendTaken(next.id, by: existing))
                lookForGap()
                markOnline()
            case .notAllowed:
                client.sendFailed(next.id)
                lostEditing()
                return
            case let .failed(error):
                client.sendFailed(next.id)
                markOffline(because: error)
                return
            }
            flush()
        }
    }

    /// A change went in: whatever kept the window from being changed is over.
    private func markOnline() {
        retryDelay = 1
        guard blocked != nil else { return }
        blocked = nil
        cameBack()
    }

    /// Sending failed: the window stops taking changes, saying why, and the change is tried again in a while, longer
    /// each time. (It was made while iCloud could still be reached; it goes in, merged, once it can be again.)
    private func markOffline(because error: Error) {
        block(isConnectionProblem(error) ? .offline : .refused(error.localizedDescription))
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self else { return }
            retryScheduled = false
            flush()
        }
        retryDelay = min(retryDelay * 2, 30)
    }

    /// Changes can't be saved to iCloud: the window stops taking any, and says why, until they can again. It's still
    /// looked at for others' changes, more often, so it knows as soon as iCloud's back.
    private func block(_ reason: Blocked) {
        guard blocked != reason else { return }
        blocked = reason
        channel?.pollInterval = 5
        applyPermission()
        updateState()
        explainOffline()
    }

    /// Says in the window why it can't be changed just now (again, when someone tries).
    func explainOffline() {
        guard let blocked else { return }
        let banner = switch (blocked, phase) {
        case (.offline, .connecting):
            "You’re offline, so “\(title)” can’t be opened from iCloud yet. It opens as soon as iCloud can be reached."
        case (.offline, _):
            "You’re offline, so changes to “\(title)” can’t be saved. You can still read it, print it or save a copy, and editing comes back as soon as iCloud can be reached."
        case let (.refused(reason), _):
            "Changes to “\(title)” can’t be saved to iCloud right now (\(reason)). You can still read it, print it or save a copy."
        }
        blockedBanner = banner
        windowController?.state.banner = banner
    }

    /// Changes can be saved again: the window takes them, catches up with what others did meanwhile, and its own
    /// message about it goes.
    private func cameBack() {
        if let banner = windowController?.state.banner, banner == blockedBanner { windowController?.state.banner = nil }
        blockedBanner = nil
        applyPermission()
        updateState()
        titleChanged()
        channel?.fetchSoon()
        flush()
    }

    /// iCloud turned a change down: this person may no longer edit.
    private func lostEditing() {
        windowController?.state.banner = "You can no longer edit “\(title)”, only comment on it. Your latest changes weren’t kept."
        channel?.fetchSoon()
    }

    // MARK: Changes from others

    private func apply(_ effects: [SyncEffect]) {
        guard !effects.isEmpty, let sheets else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        for effect in effects {
            switch effect {
            case .apply(let change):
                let movers = change.ops.filter(\.isMover)
                if movers.isEmpty {
                    // Not keeping the workbook as it was: that would copy every cell of the sheet the change touches.
                    let changes = Self.remoteChanges(change.ops, to: sheets.workbook)
                    sheets.applyRemote(changes)
                } else {
                    let before = sheets.workbook
                    sheets.applyRemote(Self.remoteChanges(change.ops, to: before))
                    moveUndo(through: movers, context: before)
                    sheets.moveSelections(through: movers)
                }
            case .replace(let workbook, let moved):
                let before = sheets.workbook
                var replacement = workbook
                Self.carryComments(from: before, into: &replacement, through: moved)
                sheets.applyRemote([.workbook(replacement)])
                moveUndo(through: moved, context: before)
                sheets.moveSelections(through: moved)
            }
        }
        anchorWaitingComments()
    }

    /// The file was read again (another app changed it): the workbook here goes back to the log's, with this Mac's
    /// changes that aren't in yet, keeping the comments where they are.
    func restoreFromLog() {
        guard phase == .live, let client, let sheets else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        var workbook = client.workbookHere
        Self.carryComments(from: sheets.workbook, into: &workbook, through: [])
        sheets.applyRemote([.workbook(workbook)])
        windowController?.state.banner = "“\(title)” changed on disk, but it’s shared, so its shared copy in iCloud is the one that counts."
    }

    /// The controller's changes for ops from the log. Cells and layout parts are set where they are, keeping the
    /// comments here; anything that moves cells goes as ops, which move comments with their cells.
    private static func remoteChanges(_ ops: [WorkbookOp], to current: Workbook) -> [WorkbookChange] {
        guard ops.allSatisfy({ if case .cells = $0 { true } else if case .layout = $0 { true } else { false } }) else { return [.ops(ops)] }
        // Sheets whose layout changes, without their cells, so nothing copies them.
        var layouts: [UUID: Sheet] = [:]
        var changes: [WorkbookChange] = []
        for op in ops {
            switch op {
            case .cells(let id, let cells):
                guard let index = current.sheetIndex(id: id) else { continue }
                let existing = current.sheets[index].cells
                var merged: [CellAddress: Cell] = [:]
                merged.reserveCapacity(cells.count)
                for (address, cell) in cells {
                    var cell = cell
                    cell.comment = existing[address]?.comment
                    merged[address] = cell
                }
                changes.append(.cells(sheet: id, merged))
            case .layout(let id, let patch):
                guard let index = current.sheetIndex(id: id) else { continue }
                var sheet = layouts[id] ?? {
                    let source = current.sheets[index]
                    var layout = Sheet(name: source.name, id: source.id, rowCount: source.rowCount, columnCount: source.columnCount)
                    SheetLayout(source).apply(to: &layout)
                    return layout
                }()
                patch.apply(to: &sheet)
                layouts[id] = sheet
                changes.append(.layout(sheet: id, SheetLayout(sheet)))
            default:
                break
            }
        }
        return changes
    }

    /// Puts the comments of the workbook shown until now on their cells in the one replacing it.
    private static func carryComments(from old: Workbook, into new: inout Workbook, through moved: [WorkbookOp]) {
        for place in old.commentPlaces.values {
            var address: CellAddress? = place.address
            for op in moved { address = address.flatMap { op.map($0, inSheet: place.sheet) } }
            guard let address, let index = new.sheetIndex(id: place.sheet) else { continue }
            var cell = new.sheets[index][address]
            cell.comment = place.thread
            new.sheets[index][address] = cell
        }
    }

    // MARK: Undo

    private func registerUndo(_ inverse: [WorkbookOp], comments: [CommentStep], actionName: String, shown: (UUID, GridSelection)) {
        guard let undoManager = document?.undoManager, undoManager.isUndoRegistrationEnabled else { return }
        let undoing = undoManager.isUndoing
        let redoing = undoManager.isRedoing
        let entry = UndoEntry(ops: inverse, comments: comments, actionName: actionName, sheet: shown.0, selection: shown.1)
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.perform(entry) }
        }
        undoManager.setActionName(actionName)
        if undoing {
            redoEntries.append(entry)
        } else if redoing {
            undoEntries.append(entry)
        } else {
            undoEntries.append(entry)
            redoEntries.removeAll()
        }
        if undoEntries.count > 500 { undoEntries.removeFirst(undoEntries.count - 500) }
    }

    #if DEBUG
    /// What undo holds, for the self-test.
    var undoDescription: String {
        "undo \(undoEntries.count) redo \(redoEntries.count) manager canUndo \(document?.undoManager?.canUndo ?? false) "
            + "name \(document?.undoManager?.undoActionName ?? "")"
    }
    #endif

    /// Takes a step back: made like any edit here, so it goes to the others, and what takes it back again is
    /// registered for Redo.
    private func perform(_ entry: UndoEntry) {
        undoEntries.removeAll { $0 === entry }
        redoEntries.removeAll { $0 === entry }
        guard phase == .live, let sheets else { return }
        var changes: [WorkbookChange] = []
        var simulated = sheets.workbook
        if !entry.ops.isEmpty, canEdit {
            let keyed = Self.remoteChanges(entry.ops, to: simulated)
            changes += keyed
            simulated.apply(entry.ops)
        }
        // Comments go back as they were, field by field, keeping what others have added since.
        var commentCells: [UUID: [CellAddress: Cell]] = [:]
        let places = simulated.commentPlaces
        for step in entry.comments {
            let current = places[step.id]
            let target = Self.revert(current?.thread, from: step.after, to: step.before)
            let place = current.map { ($0.sheet, $0.address) } ?? step.place
            guard let index = simulated.sheetIndex(id: place.0) else { continue }
            var cell = commentCells[place.0]?[place.1] ?? simulated.sheets[index][place.1]
            if let target {
                // One thread to a cell.
                if let other = cell.comment, other.id != target.id { continue }
                cell.comment = target
            } else if cell.comment?.id == step.id {
                cell.comment = nil
            }
            commentCells[place.0, default: [:]][place.1] = cell
        }
        changes += commentCells.map { WorkbookChange.cells(sheet: $0.key, $0.value) }
        guard !changes.isEmpty else { return }
        let selection = simulated.sheetIndex(id: entry.sheet) != nil ? entry.selection : nil
        sheets.perform(changes, actionName: entry.actionName, selection: selection, showing: selection == nil ? nil : entry.sheet)
    }

    /// The thread `current` with what an edit did (`from` → `to`, as the edit saw it) taken back: its first comment's
    /// words and the resolution, if no one changed them since, and comments it added or removed. Nil: the thread goes.
    private static func revert(_ current: CommentThread?, from: CommentThread?, to: CommentThread?) -> CommentThread? {
        guard let to else { return nil }
        guard var thread = current, let from else { return to }
        if thread.isResolved == from.isResolved { thread.isResolved = to.isResolved }
        let added = Set(from.comments.map(\.id)).subtracting(to.comments.map(\.id))
        thread.comments.removeAll { added.contains($0.id) }
        for comment in to.comments {
            if let index = thread.comments.firstIndex(where: { $0.id == comment.id }) {
                if thread.comments[index] == from.comments.first(where: { $0.id == comment.id }) { thread.comments[index] = comment }
            } else if from.comments.contains(where: { $0.id == comment.id }) == false {
                thread.comments.append(comment)
            }
        }
        let first = to.comments.first?.id
        thread.comments.sort { ($0.id == first ? 0 : 1, $0.date) < ($1.id == first ? 0 : 1, $1.date) }
        return thread.comments.isEmpty ? nil : thread
    }

    /// Others' change came in: each undo step of this Mac's is rewritten to follow it.
    private func moveUndo(through movers: [WorkbookOp], context: Workbook) {
        let movers = movers.filter(\.isMover)
        guard !movers.isEmpty else { return }
        for entry in undoEntries + redoEntries {
            entry.ops = entry.ops.rebased(over: movers, context: context).ops
            for index in entry.comments.indices {
                var place = entry.comments[index].place
                for op in movers { place.address = op.map(place.address, inSheet: place.sheet) ?? place.address }
                entry.comments[index].place = place
            }
        }
    }

    // MARK: Snapshots

    /// Where each thread is, at `revision`.
    private static func anchors(in workbook: Workbook, revision: Int) -> [UUID: CommentAnchor] {
        workbook.commentPlaces.mapValues { CommentAnchor(revision: revision, sheet: $0.sheet, address: $0.address) }
    }

    /// After changes go in: now and then, when everything here is in, a snapshot for people joining to start from.
    private func afterConfirm() {
        updateState()
        saveUnanchoredComments()
        guard canEdit, let client, !client.hasPending, client.revision > lastSnapshotRevision else { return }
        snapshotWork?.cancel()
        if client.revision - lastSnapshotRevision >= 100 {
            saveSnapshot()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.saveSnapshot() }
        snapshotWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func saveSnapshot() {
        guard phase == .live, canEdit, let client, !client.hasPending, client.revision > lastSnapshotRevision, let sheets else { return }
        lastSnapshotRevision = client.revision
        let snapshot = SyncSnapshot(revision: client.revision, workbook: client.confirmed,
                                    anchors: Self.anchors(in: sheets.workbook, revision: client.revision))
        channel?.saveSnapshot(snapshot, title: title)
    }

    /// Starts from a snapshot: the workbook becomes iCloud's, and changes go on from its revision.
    private func load(_ snapshot: SyncSnapshot) {
        guard let sheets else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        let workbook: Workbook
        if let client {
            workbook = client.reset(to: snapshot)
        } else {
            let client = SyncClient(revision: snapshot.revision, workbook: snapshot.workbook, author: me?.id ?? "me",
                                    authorName: me?.name ?? NSFullUserName())
            self.client = client
            workbook = client.workbookHere
        }
        snapshotPlaces = snapshot.anchors
        // Comments come from iCloud too: the ones a file of this person's kept may be out of date.
        var replacement = workbook
        for comment in serverComments.values {
            guard let anchor = snapshot.anchors[comment.thread.id], let address = client?.place(of: anchor),
                  let index = replacement.sheetIndex(id: anchor.sheet) else { continue }
            replacement.sheets[index][address].comment = comment.thread
        }
        sheets.applyRemote([.workbook(replacement)])
        lastSnapshotRevision = snapshot.revision
        undoEntries = []
        redoEntries = []
        document?.undoManager?.removeAllActions()
    }

    // MARK: Comments

    /// The comment threads an edit started, changed, moved or deleted, from where they were before and after it.
    private static func commentSteps(before old: [UUID: (sheet: UUID, address: CellAddress, thread: CommentThread)],
                                     after new: [UUID: (sheet: UUID, address: CellAddress, thread: CommentThread)]) -> [CommentStep] {
        var steps: [CommentStep] = []
        for (id, now) in new {
            let was = old[id]
            if was?.thread != now.thread || was?.sheet != now.sheet || was?.address != now.address {
                steps.append(CommentStep(id: id, before: was?.thread, after: now.thread,
                                         place: was.map { ($0.sheet, $0.address) } ?? (now.sheet, now.address)))
            }
        }
        for (id, was) in old where new[id] == nil {
            steps.append(CommentStep(id: id, before: was.thread, after: nil, place: (was.sheet, was.address)))
        }
        return steps
    }

    /// Saves the threads an edit changed to the talk zone, and takes out the ones it deleted. A thread that moved only
    /// because rows or columns did moves the same way everywhere; one moved by an edit (cut and paste) is saved with
    /// its new place.
    private func save(_ steps: [CommentStep], movedByEdit: Bool) {
        guard let channel, let sheets else { return }
        let places = sheets.workbook.commentPlaces
        for step in steps {
            guard let thread = step.after else {
                serverComments[step.id] = nil
                unanchoredComments.remove(step.id)
                channel.deleteComment(step.id.uuidString)
                continue
            }
            if let previous = step.before {
                let known = Set(previous.comments.map(\.id))
                for comment in thread.comments.dropFirst() where !known.contains(comment.id) { tally.recordReply(comment.text) }
                if thread.isResolved, !previous.isResolved { tally.recordResolved() }
            } else if let first = thread.comments.first {
                tally.recordComment(first.text)
            }
            let moved = step.before != nil && (places[step.id].map { ($0.sheet, $0.address) }).map { $0.0 != step.place.sheet || $0.1 != step.place.address } == true
            var anchor = serverComments[step.id]?.anchor
            if anchor == nil || (moved && movedByEdit) {
                guard let place = places[step.id], let fresh = logAnchor(sheet: place.sheet, address: place.address) else {
                    unanchoredComments.insert(step.id)
                    continue
                }
                anchor = fresh
            }
            let comment = SharedComment(thread: thread, anchor: anchor)
            serverComments[step.id] = comment
            save(comment, base: step.before, using: channel)
        }
    }

    /// Where a cell here is in the log, as an anchor; nil while it's in rows or columns made here that aren't in yet.
    private func logAnchor(sheet: UUID, address: CellAddress) -> CommentAnchor? {
        guard let client, let place = client.logPlace(of: address, inSheet: sheet) else { return nil }
        return CommentAnchor(revision: client.revision, sheet: sheet, address: place)
    }

    /// Threads started on cells that weren't in the log yet, now they are.
    private func saveUnanchoredComments() {
        guard !unanchoredComments.isEmpty, let channel, let sheets else { return }
        let places = sheets.workbook.commentPlaces
        for id in unanchoredComments {
            guard let place = places[id] else {
                unanchoredComments.remove(id)
                continue
            }
            guard let anchor = logAnchor(sheet: place.sheet, address: place.address) else { continue }
            unanchoredComments.remove(id)
            let comment = SharedComment(thread: place.thread, anchor: anchor)
            serverComments[id] = comment
            save(comment, base: nil, using: channel)
        }
    }

    /// Saves a thread to iCloud, trying again a few times, further apart, while it can't be reached.
    private func save(_ comment: SharedComment, base: CommentThread?, using channel: CollaborationChannel, attempt: Int = 0) {
        channel.save(comment, base: base) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(saved):
                // Someone else changed the thread meanwhile: theirs and ours, merged.
                if saved.thread != comment.thread { received([saved], deleted: []) }
            case .failure where attempt < 6:
                DispatchQueue.main.asyncAfter(deadline: .now() + pow(2, Double(attempt))) { [weak self] in
                    guard let self, phase == .live, let channel = self.channel,
                          sheets?.workbook.commentPlaces[comment.thread.id]?.thread == comment.thread else { return }
                    save(comment, base: base, using: channel, attempt: attempt + 1)
                }
            case let .failure(error):
                windowController?.state.banner = "A comment couldn’t be saved to iCloud: \(error.localizedDescription)"
            }
        }
    }

    /// Threads from the talk zone: changed in place, moved where their record says they were moved, or put on their
    /// cells for the first time.
    private func received(_ comments: [SharedComment], deleted: [String]) {
        guard let sheets, let client else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        let workbook = sheets.workbook
        let places = workbook.commentPlaces
        var updates: [UUID: [CellAddress: Cell]] = [:]
        func set(_ thread: CommentThread?, sheet: UUID, address: CellAddress) {
            guard let index = workbook.sheetIndex(id: sheet) else { return }
            var cell = updates[sheet]?[address] ?? workbook.sheets[index][address]
            cell.comment = thread
            updates[sheet, default: [:]][address] = cell
        }
        func occupant(_ sheet: UUID, _ address: CellAddress) -> CommentThread? {
            if let pending = updates[sheet]?[address] { return pending.comment }
            return workbook.sheetIndex(id: sheet).flatMap { workbook.sheets[$0].cells[address]?.comment }
        }
        for comment in comments {
            let id = comment.thread.id
            let previous = serverComments[id]
            serverComments[id] = comment
            waitingComments[id] = nil
            if let place = places[id] {
                if let anchor = comment.anchor, let old = previous?.anchor, anchor.revision > old.revision,
                   anchor.sheet != old.sheet || anchor.address != old.address, let target = client.place(of: anchor),
                   target != place.address || anchor.sheet != place.sheet {
                    // Moved by an edit on another Mac.
                    set(nil, sheet: place.sheet, address: place.address)
                    set(comment.thread, sheet: anchor.sheet, address: target)
                } else if place.thread != comment.thread {
                    set(comment.thread, sheet: place.sheet, address: place.address)
                }
                continue
            }
            let anchor = snapshotPlaces[id] ?? comment.anchor
            guard let anchor else { continue }
            if anchor.revision > client.revision {
                waitingComments[id] = comment
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.placeWaiting(id) }
                continue
            }
            guard let address = client.place(of: anchor) else { continue }
            // One thread to a cell: where two meet, the one whose identity sorts first stays, on every Mac.
            if let other = occupant(anchor.sheet, address), other.id != id, other.id.uuidString < id.uuidString { continue }
            set(comment.thread, sheet: anchor.sheet, address: address)
        }
        for name in deleted {
            guard let id = UUID(uuidString: name) else { continue }
            serverComments[id] = nil
            waitingComments[id] = nil
            if let place = places[id] { set(nil, sheet: place.sheet, address: place.address) }
        }
        guard !updates.isEmpty else { return }
        sheets.applyRemote(updates.map { WorkbookChange.cells(sheet: $0.key, $0.value) })
    }

    private func anchorWaitingComments() {
        guard !waitingComments.isEmpty else { return }
        received(Array(waitingComments.values), deleted: [])
    }

    /// A thread whose revision of the log is slow to come: shown meanwhile on the cell its anchor names.
    private func placeWaiting(_ id: UUID) {
        guard phase == .live, let comment = waitingComments[id], let anchor = comment.anchor, let sheets else { return }
        waitingComments[id] = nil
        let workbook = sheets.workbook
        guard workbook.commentPlaces[id] == nil, let index = workbook.sheetIndex(id: anchor.sheet) else { return }
        var cell = workbook.sheets[index][anchor.address]
        if let other = cell.comment, other.id != id, other.id.uuidString < id.uuidString { return }
        cell.comment = comment.thread
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        sheets.applyRemote([.cells(sheet: anchor.sheet, [anchor.address: cell])])
    }

    /// After starting over from a snapshot: the comment threads as iCloud last had them, back on their cells.
    private func restoreComments() {
        guard !serverComments.isEmpty else { return }
        received(Array(serverComments.values), deleted: [])
    }

    // MARK: Telling the others

    private func noteLocalAction() {
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendNotice() }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeDelay, execute: work)
    }

    /// Sends what's changed since the others were last told, to everyone else who's joined.
    func sendNotice() {
        noticeWork?.cancel()
        noticeWork = nil
        defer { tally = ChangeTally() }
        guard let me, let notice = tally.notice(author: me.name, documentTitle: title) else { return }
        let others = (sharing?.collaborators ?? []).filter { $0.id != me.id && $0.status == .joined }.map(\.id)
        guard !others.isEmpty else { return }
        channel?.sendNotice(title: notice.title, body: notice.body, to: others)
        controller.noticeSent(title: notice.title, body: notice.body, document: id, to: others)
    }

    // MARK: The header

    private func updateState() {
        guard let state else { return }
        state.isShared = phase != .ended
        state.isOwner = isOwner
        state.meID = me?.id
        if let sharing {
            let people = named(sharing.collaborators)
            state.collaborators = people
            state.permission = sharing.myPermission
            state.ownerName = people.first(where: \.isOwner)?.displayName ?? sharing.owner.displayName
        } else if let info {
            state.ownerName = info.ownerName
        }
        switch phase {
        case .connecting:
            if blocked == .offline {
                state.statusText = "Offline · It opens when iCloud can be reached"
                state.statusSymbol = "icloud.slash"
            } else {
                state.statusText = "Opening the shared copy from iCloud…"
                state.statusSymbol = "icloud.and.arrow.down"
            }
        case .ended:
            state.statusText = "No longer shared"
            state.statusSymbol = "icloud.slash"
        case .live:
            if let blocked {
                state.statusText = blocked == .offline ? "Offline · Changes can’t be saved until iCloud can be reached"
                    : "Changes can’t be saved to iCloud right now"
                state.statusSymbol = blocked == .offline ? "icloud.slash" : "exclamationmark.icloud"
            } else if client?.hasPending == true {
                state.statusText = "Saving to iCloud…"
                state.statusSymbol = "arrow.triangle.2.circlepath.icloud"
            } else if !canEdit {
                state.statusText = isOwner ? "Saved in iCloud" : "Shared by \(state.ownerName) · You can comment"
                state.statusSymbol = "icloud"
            } else {
                state.statusText = isOwner ? "Saved in iCloud" : "Shared by \(state.ownerName) · Saved in iCloud"
                state.statusSymbol = "checkmark.icloud"
            }
        }
    }

    /// The people in the share, named where iCloud doesn't say who they are: the owner as the spreadsheet names them,
    /// anyone else as they name themselves when they open it.
    private func named(_ people: [Collaborator]) -> [Collaborator] {
        let presence = state?.presence ?? [:]
        var people = people
        for index in people.indices where people[index].name.isEmpty {
            if let seen = presence[people[index].id] {
                people[index].name = seen.info.name
            } else if people[index].isOwner, let owner = info?.ownerName, !owner.isEmpty {
                people[index].name = owner
            }
        }
        // One person iCloud says nothing about, and one person who opened it whom iCloud lists under no identity of
        // theirs: the same person.
        let listed = Set(people.map(\.id))
        let unlisted = presence.values.filter { $0.person != me?.id && !listed.contains($0.person) }
        let nameless = people.indices.filter {
            people[$0].name.isEmpty && people[$0].address == nil && people[$0].id != me?.id && people[$0].status == .joined
        }
        if nameless.count == 1, unlisted.count == 1, let only = unlisted.first { people[nameless[0]].name = only.info.name }
        return people
    }

    /// The owner changed how it's shared, from the sharing sheet.
    func sharingUpdated(_ sharing: DocumentSharing) {
        self.sharing = sharing
        applyPermission()
        updateState()
    }
}

// MARK: - The channel

extension SpreadsheetCollaboration: CollaborationChannelDelegate {
    func channel(_ channel: CollaborationChannel, loaded snapshot: SyncSnapshot, info: SharedDocumentInfo) {
        self.info = info
        if !isOwner, let document, document.sharedCopy?.title != info.title {
            document.sharedCopy?.title = info.title
            windowController?.synchronizeWindowTitleWithDocumentName()
        }
        // A Mac that's following the log needs no snapshot; one starting, or one so far behind that the changes it's
        // missing are gone, starts from it.
        if let client, phase == .live, client.revision >= snapshot.revision || !client.isMissingChanges { return }
        let catchingUp = phase == .live
        if catchingUp, let client, client.hasPending {
            // What's waiting to go was made on a workbook the snapshot moves past, so it can't follow.
            client.discardPending()
            windowController?.state.banner = "Your latest changes to “\(title)” couldn’t be kept while it caught up with iCloud."
        }
        load(snapshot)
        if catchingUp { restoreComments() }
        let early = earlyChanges
        earlyChanges = []
        // With the changes that came ahead of the ones the snapshot now covers.
        if let client { apply(client.receive(early)) }
        if phase == .connecting { goLive() }
        lookForGap()
    }

    func channel(_ channel: CollaborationChannel, received changes: [LoggedChange]) {
        guard let client, phase == .live else {
            earlyChanges += changes
            return
        }
        apply(client.receive(changes))
        lookForGap()
        afterConfirm()
        flush()
    }

    /// Changes came ahead of one that hasn't (iCloud passed over it while reading, say). If it still hasn't a moment
    /// later, it's asked for by name, and failing that the spreadsheet starts again from its latest snapshot; until then
    /// nothing after it can be shown.
    private func lookForGap() {
        guard phase == .live, client?.missingRevisions != nil else {
            gapCheck?.cancel()
            gapCheck = nil
            gapDelay = 1
            return
        }
        guard gapCheck == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            gapCheck = nil
            guard phase == .live, let missing = client?.missingRevisions else { return lookForGap() }
            collaborationLog.notice("Asking again for changes \(missing.lowerBound)–\(missing.upperBound)")
            channel?.fetchChanges(missing)
            gapDelay = min(gapDelay * 2, 60)
            lookForGap()
        }
        gapCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + gapDelay, execute: work)
    }

    func channel(_ channel: CollaborationChannel, retitled title: String) {
        info?.title = title
        guard !isOwner, let document, document.sharedCopy?.title != title else { return }
        document.sharedCopy?.title = title
        windowController?.synchronizeWindowTitleWithDocumentName()
    }

    func channel(_ channel: CollaborationChannel, receivedComments comments: [SharedComment], deleted: [String]) {
        received(comments, deleted: deleted)
    }

    func channel(_ channel: CollaborationChannel, receivedPresence presence: [Presence]) {
        guard let state else { return }
        for item in presence { state.presence[item.person] = item }
        state.clock = Date()
        updateState()
        let othersActive = state.presence.values.contains { $0.person != me?.id && $0.isActive() }
        channel.pollInterval = othersActive ? 2 : 15
    }

    func channel(_ channel: CollaborationChannel, sharingChanged sharing: DocumentSharing) {
        let couldEdit = canEdit
        self.sharing = sharing
        if phase == .live {
            applyPermission()
            if couldEdit != canEdit { announcePresence(viewing: true) }
            if couldEdit != canEdit, !isOwner {
                windowController?.state.banner = canEdit
                    ? "\(sharing.owner.displayName) changed your access: you can now edit “\(title)”."
                    : "\(sharing.owner.displayName) changed your access: you can now comment on “\(title)”, but not change it."
            }
        }
        updateState()
    }

    func channel(_ channel: CollaborationChannel, reachable: Bool) {
        if reachable {
            // iCloud answers again. (A change it turned down is over only when one goes in.)
            if blocked == .offline { markOnline() }
        } else {
            block(.offline)
        }
    }

    func channel(_ channel: CollaborationChannel, becameUnavailable reason: UnavailableReason) {
        guard phase != .ended else { return }
        let ownerName = sharing?.owner.displayName ?? info?.ownerName ?? "The owner"
        end(saying: false)
        updateState()
        if isOwner {
            controller.sharingEnded(self)
        } else {
            controller.documentWentAway(self, ownerName: ownerName, reason: reason)
        }
    }
}
