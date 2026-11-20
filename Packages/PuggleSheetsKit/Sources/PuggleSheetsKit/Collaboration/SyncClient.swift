import Foundation

/// A change to a shared workbook: ops to apply one after another (see `WorkbookOp`).
public struct SharedChange: Sendable {
    public var ops: [WorkbookOp]

    public init(_ ops: [WorkbookOp] = []) {
        self.ops = ops
    }

    public var isEmpty: Bool { ops.isEmpty }

    /// This change followed by `later`, as one.
    public func compose(_ later: SharedChange) -> SharedChange { SharedChange(ops + later.ops) }

    /// Whether it only sets values by key, moving nothing.
    var isKeyed: Bool { ops.allSatisfy(\.isKeyed) }

    func removing(_ keys: Set<OpKey>) -> SharedChange {
        guard !keys.isEmpty else { return self }
        return SharedChange(ops.compactMap { $0.removing(keys) })
    }

    /// The change as bytes, to keep or send: compressed JSON.
    public var encoded: Data { SyncCompression.compress(SyncCoding.encode(ops)) }

    public init(encoded data: Data) throws {
        ops = try SyncCoding.decode([WorkbookOp].self, from: try SyncCompression.decompress(data))
    }
}

/// One change in a shared workbook's log, at its revision: the log is the workbook's history, one revision after
/// another, the same on every Mac.
public struct LoggedChange: Sendable {
    public var revision: Int
    /// Tells this change from every other, so a Mac knows its own change when it comes back.
    public var id: String
    /// Who made it: their iCloud identity.
    public var author: String
    public var authorName: String
    public var change: SharedChange

    public init(revision: Int, id: String = UUID().uuidString, author: String, authorName: String, change: SharedChange) {
        self.revision = revision
        self.id = id
        self.author = author
        self.authorName = authorName
        self.change = change
    }
}

/// What a Mac does with the workbook it shows when changes come in from the log.
public enum SyncEffect {
    /// Make these changes, as they are: nothing of this Mac's was in their way.
    case apply(SharedChange)
    /// Show this workbook instead: the log's, with this Mac's changes that aren't in yet made again after the one
    /// that came in. `moved` is the change that came in as it would apply to the workbook shown until now, for moving
    /// places (comments, undo steps, the selection) from it into the new one.
    case replace(Workbook, moved: [WorkbookOp])
}

/// One Mac's side of editing a shared workbook along with others, through its log.
///
/// Changes made here go into the log one at a time, each claiming the revision after the last one known here. Changes
/// others got into the log first come in and are applied here. The workbook here is always the log's (`confirmed`)
/// with this Mac's changes that aren't in yet made on top, so every Mac's workbook is the log's once their changes are
/// in. When a change comes in that only sets cells and layout parts while this Mac's waiting changes do too, it's
/// applied as it is, minus whatever this Mac's own changes set (they come later in the log, so they stand). Otherwise
/// (rows inserted, a sheet renamed…) this Mac's waiting changes are rewritten to follow it and the workbook is made
/// afresh from the log's.
public final class SyncClient {
    public let author: String
    public var authorName: String
    /// The last revision of the log that's been applied here.
    public private(set) var revision: Int
    /// The change of this Mac's that's claiming the next revision (or about to).
    public private(set) var outstanding: LoggedChange?
    /// Changes made here since `outstanding`, to go once it's in.
    public private(set) var buffer: SharedChange?
    /// `outstanding`'s id while it's being sent.
    public private(set) var sending: String?
    /// The workbook as the log has it at `revision`, without comments: what every Mac agrees on.
    public private(set) var confirmed: Workbook
    /// Changes that came ahead of the ones before them.
    private var early: [Int: LoggedChange] = [:]
    /// What moved cells in each revision of the log, as far back as it's kept: for following comments' places.
    private var history: [Int: [WorkbookOp]] = [:]
    public var historyLimit = 5_000

    public init(revision: Int, workbook: Workbook, author: String, authorName: String) {
        self.revision = revision
        self.author = author
        self.authorName = authorName
        confirmed = workbook.withoutComments
    }

    /// Whether changes made here aren't all in the log yet.
    public var hasPending: Bool { outstanding != nil || buffer != nil }

    /// This Mac's changes that aren't in the log yet, in order.
    public var pendingOps: [WorkbookOp] { (outstanding?.change.ops ?? []) + (buffer?.ops ?? []) }

    /// The workbook as it is here: the log's, with this Mac's changes that aren't in yet.
    public var workbookHere: Workbook { confirmed.applying(pendingOps) }

    /// Whether changes from the log are waiting for one that hasn't come.
    public var isMissingChanges: Bool { !early.isEmpty }

    /// The revisions the changes waiting here need first: from the last one applied to the first that came ahead.
    public var missingRevisions: ClosedRange<Int>? {
        guard let first = early.keys.min(), first > revision + 1 else { return nil }
        return (revision + 1)...(first - 1)
    }

    /// Drops the changes made here that aren't in the log yet, for starting over from a snapshot they can't follow.
    public func discardPending() {
        outstanding = nil
        buffer = nil
        sending = nil
    }

    /// A change made here.
    public func local(_ change: SharedChange) {
        guard !change.isEmpty else { return }
        if outstanding == nil {
            outstanding = LoggedChange(revision: revision + 1, author: author, authorName: authorName, change: change)
        } else {
            buffer = buffer.map { $0.compose(change) } ?? change
        }
    }

    /// The change to send next, if one is waiting and none is already on its way.
    public func nextToSend() -> LoggedChange? {
        guard sending == nil, let outstanding else { return nil }
        sending = outstanding.id
        return outstanding
    }

    /// The change went into the log at the revision it claimed.
    public func sent(_ id: String) {
        if sending == id { sending = nil }
        guard let outstanding, outstanding.id == id else { return }
        confirm(outstanding)
    }

    /// The change couldn't be sent (no connection, say); it's sent again next time.
    public func sendFailed(_ id: String) {
        if sending == id { sending = nil }
    }

    /// Another change took the revision the change claimed. Answers what to do here; the change follows it.
    public func sendTaken(_ id: String, by existing: LoggedChange) -> [SyncEffect] {
        if sending == id { sending = nil }
        return receive([existing])
    }

    /// Changes from the log, in any order. Answers what to do to the workbook here, in order.
    public func receive(_ changes: [LoggedChange]) -> [SyncEffect] {
        for change in changes where change.revision > revision { early[change.revision] = change }
        var effects: [SyncEffect] = []
        while let next = early.removeValue(forKey: revision + 1) {
            if let mine = outstanding, mine.id == next.id {
                if sending == mine.id { sending = nil }
                confirm(next)
                continue
            }
            let pending = pendingOps
            let keyed = pending.isEmpty || (next.change.isKeyed && pending.allSatisfy(\.isKeyed))
            // The log's workbook as it was, only when this Mac's changes have to be rewritten to follow (keeping it
            // otherwise would copy every cell of the sheet the change touches).
            let before = keyed ? nil : confirmed
            confirmed.apply(next.change.ops)
            revision = next.revision
            remember(next.revision, next.change)
            // This Mac's waiting change now claims the revision after it.
            if var mine = outstanding {
                mine.revision = revision + 1
                outstanding = mine
            }
            if pending.isEmpty {
                effects.append(.apply(next.change))
            } else if let before {
                effects.append(rebase(over: next.change, from: before))
            } else {
                // This Mac's changes come after it in the log: where both set something, this Mac's stands.
                effects.append(.apply(next.change.removing(Set(pending.flatMap(\.keys)))))
            }
        }
        return effects
    }

    /// Rewrites this Mac's waiting changes to follow `change`, which came into the log first.
    private func rebase(over change: SharedChange, from before: Workbook) -> SyncEffect {
        let outstandingOps = outstanding?.change.ops ?? []
        let (movedOutstanding, afterOutstanding) = outstandingOps.rebased(over: change.ops, context: before)
        let afterContext = before.skeleton.applying(outstandingOps.compactMap(\.skeletal))
        let (movedBuffer, afterBuffer) = (buffer?.ops ?? []).rebased(over: afterOutstanding, context: afterContext)
        if var mine = outstanding {
            if movedOutstanding.isEmpty {
                // Nothing of it is left to send: what came after it goes next.
                outstanding = movedBuffer.isEmpty ? nil
                    : LoggedChange(revision: revision + 1, author: author, authorName: authorName, change: SharedChange(movedBuffer))
                buffer = nil
            } else {
                mine.change = SharedChange(movedOutstanding)
                mine.revision = revision + 1
                outstanding = mine
                buffer = buffer == nil || movedBuffer.isEmpty ? nil : SharedChange(movedBuffer)
            }
        }
        return .replace(confirmed.applying(movedOutstanding + movedBuffer), moved: afterBuffer)
    }

    private func confirm(_ change: LoggedChange) {
        confirmed.apply(change.change.ops)
        revision = change.revision
        remember(change.revision, change.change)
        outstanding = buffer.map { LoggedChange(revision: revision + 1, author: author, authorName: authorName, change: $0) }
        buffer = nil
    }

    private func remember(_ revision: Int, _ change: SharedChange) {
        history[revision] = change.ops.filter(\.isMover)
        if history.count > historyLimit, let oldest = history.keys.min() { history[oldest] = nil }
    }

    /// Starts over from a snapshot of the log, dropping whatever was known before it. Answers the workbook here: the
    /// snapshot's, with this Mac's changes that aren't in yet.
    @discardableResult
    public func reset(to snapshot: SyncSnapshot) -> Workbook {
        revision = snapshot.revision
        confirmed = snapshot.workbook.withoutComments
        history = [:]
        early = early.filter { $0.key > revision }
        if var mine = outstanding {
            mine.revision = revision + 1
            outstanding = mine
        }
        return workbookHere
    }

    // MARK: Places

    /// Where the cell `anchor` names (at its revision of the log) is in the workbook here now; nil when it's been
    /// deleted since, or the changes since aren't known here, or its revision hasn't come yet.
    public func place(of anchor: CommentAnchor) -> CellAddress? {
        guard anchor.revision <= revision else { return nil }
        var address = CellAddress(row: anchor.row, column: anchor.column)
        if anchor.revision < revision {
            for step in (anchor.revision + 1)...revision {
                guard let movers = history[step] else { return nil }
                for op in movers {
                    guard let moved = op.map(address, inSheet: anchor.sheet) else { return nil }
                    address = moved
                }
            }
        }
        for op in pendingOps where op.isMover {
            guard let moved = op.map(address, inSheet: anchor.sheet) else { return nil }
            address = moved
        }
        return address
    }

    /// Where a cell here is in the log at `revision`, before this Mac's changes that aren't in yet; nil for a cell
    /// one of them made (in a row they inserted, say).
    public func logPlace(of address: CellAddress, inSheet sheet: UUID) -> CellAddress? {
        var address = address
        for op in pendingOps.reversed() where op.isMover {
            guard let before = op.unmap(address, inSheet: sheet) else { return nil }
            address = before
        }
        return address
    }
}

/// A shared workbook as a whole at one revision of its log, for a Mac joining it to start from.
public struct SyncSnapshot: Sendable {
    public var revision: Int
    /// The workbook, without comments.
    public var workbook: Workbook
    /// Where each comment thread is at `revision`, by thread.
    public var anchors: [UUID: CommentAnchor]

    public init(revision: Int, workbook: Workbook, anchors: [UUID: CommentAnchor]) {
        self.revision = revision
        self.workbook = workbook.withoutComments
        self.anchors = anchors
    }

    private struct Coded: Codable {
        var revision: Int
        var workbook: Workbook
        var anchors: [String: CommentAnchor]
    }

    public var encoded: Data {
        SyncCompression.compress(SyncCoding.encode(Coded(revision: revision, workbook: workbook,
                                                         anchors: Dictionary(uniqueKeysWithValues: anchors.map { ($0.key.uuidString, $0.value) }))))
    }

    public init(encoded data: Data) throws {
        let coded = try SyncCoding.decode(Coded.self, from: try SyncCompression.decompress(data))
        revision = coded.revision
        workbook = coded.workbook
        anchors = Dictionary(uniqueKeysWithValues: coded.anchors.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }
}

/// zlib, for what travels: spreadsheets repeat themselves a lot.
enum SyncCompression {
    static func compress(_ data: Data) -> Data {
        (try? (data as NSData).compressed(using: .zlib) as Data) ?? data
    }

    static func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .zlib) as Data
    }
}
