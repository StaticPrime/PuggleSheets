#if DEBUG
import AppKit
import CloudKit
import PuggleSheetsKit

/// Stands in for iCloud in debug runs (`-PSStandInCloud YES`) and the self-test: shared spreadsheets kept in memory and
/// passed between the people in this process, this Mac's person and simulated ones (`StandInPerson`), each a moment
/// after it's sent, as iCloud would.
final class StandInCloud {
    static let shared = StandInCloud()
    static let me = Collaborator(id: "alex@example.com", name: "Alex Morgan", address: "alex@example.com", isOwner: true)

    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "PSStandInCloud")
            || (UserDefaults.standard.bool(forKey: "PSSelfTest") && UserDefaults.standard.string(forKey: "PSSelfTestSuite") == "collaboration")
    }

    final class Document {
        let id: UUID
        var title: String
        var owner: Collaborator
        /// The owner first.
        var people: [Collaborator]
        var access: LinkAccess
        var linkPermission: CollaboratorPermission
        var snapshot: SyncSnapshot
        var changes: [Int: LoggedChange] = [:]
        var comments: [UUID: (comment: SharedComment, version: Int)] = [:]
        var deletedComments: [(id: String, version: Int)] = []
        var presence: [String: (presence: Presence, version: Int)] = [:]
        var version = 0
        var sharingVersion = 0

        init(id: UUID, title: String, owner: Collaborator, access: LinkAccess, linkPermission: CollaboratorPermission, snapshot: SyncSnapshot) {
            self.id = id
            self.title = title
            self.owner = owner
            people = [owner]
            self.access = access
            self.linkPermission = linkPermission
            self.snapshot = snapshot
        }

        func bump() -> Int {
            version += 1
            return version
        }
    }

    private(set) var documents: [UUID: Document] = [:]
    /// Whether the people in a share go unnamed and unidentified, as iCloud can leave them.
    var hidesIdentities = false
    /// The names of the simulated people, by address, as iCloud would know them.
    var directory: [String: String] = [:]
    /// Notices left for people: who for, and what they said.
    private(set) var notices: [(to: String, title: String, body: String, document: UUID)] = []
    private var channels: [WeakChannel] = []
    private var services: [WeakService] = []
    var latency: TimeInterval = 0.05
    /// Revisions of the log this Mac's reading passes over, as iCloud can when a change's file doesn't come along: they
    /// come only when asked for by name.
    var skippedRevisions: Set<Int> = []
    /// Whether this Mac can reach the stand-in "iCloud". While it can't, everything it asks fails as iCloud's requests
    /// do offline; the simulated people on other Macs carry on.
    var isReachable = true {
        didSet {
            guard isReachable != oldValue else { return }
            for item in channels { item.channel?.fetchSoon() }
        }
    }

    private struct WeakChannel { weak var channel: StandInChannel? }
    private struct WeakService { weak var service: StandInCollaboration? }

    func add(_ document: Document) {
        documents[document.id] = document
        announce()
    }

    func remove(_ id: UUID) {
        documents[id] = nil
        announce()
        changed(id)
    }

    func addNotice(to person: String, title: String, body: String, document: UUID) {
        notices.append((person, title, body, document))
    }

    func register(_ channel: StandInChannel) {
        channels.removeAll { $0.channel == nil }
        channels.append(WeakChannel(channel: channel))
    }

    func register(_ service: StandInCollaboration) {
        services.append(WeakService(service: service))
    }

    /// Something in a spreadsheet changed: everyone in it hears, a moment later.
    func changed(_ id: UUID) {
        for item in channels {
            guard let channel = item.channel, channel.id == id else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + latency) { [weak channel] in channel?.fetchSoon() }
        }
    }

    /// Which spreadsheets are shared with whom changed.
    func announce() {
        for item in services { item.service?.onSharedWithMeChange?() }
    }

    func sharing(of document: Document, for person: String) -> DocumentSharing {
        let me = document.people.first { $0.id == person }
        var people = document.people
        if hidesIdentities {
            people = people.enumerated().map { index, someone in
                someone.id == person ? someone
                    : Collaborator(id: "hidden-\(index)", name: "", isOwner: someone.isOwner, permission: someone.permission, status: someone.status)
            }
        }
        return DocumentSharing(id: document.id, title: document.title, owner: people.first(where: \.isOwner) ?? document.owner, collaborators: people,
                               access: document.access, linkPermission: document.linkPermission,
                               url: URL(string: "https://share.pugglesoft.invalid/\(document.id.uuidString.lowercased())"),
                               myPermission: document.owner.id == person ? .edit : (me?.permission ?? .comment),
                               isMine: document.owner.id == person)
    }
}

/// One person's view of the stand-in "iCloud".
final class StandInCollaboration: CollaborationService {
    let me: Collaborator
    let cloud: StandInCloud
    var onStatus: (() -> Void)?
    var onSharedWithMeChange: (() -> Void)?
    var onChangesAvailable: (() -> Void)?

    init(me: Collaborator, cloud: StandInCloud) {
        self.me = me
        self.cloud = cloud
        cloud.register(self)
    }

    var status: CollaborationStatus { .ready(me: me) }
    var invitesThroughSystem: Bool { false }

    var sharedWithMe: [SharedDocumentEntry] {
        cloud.documents.values.filter { document in
            document.owner.id != me.id && document.people.contains { $0.id == me.id && $0.status == .joined }
        }.map { SharedDocumentEntry(id: $0.id, title: $0.title, ownerName: $0.owner.name, ownerID: $0.owner.id) }
            .sorted { $0.title < $1.title }
    }

    func start() {}

    private func later(_ work: @escaping () -> Void) {
        nonisolated(unsafe) let work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cloud.latency) { work() }
    }

    private func change(_ id: UUID, _ completion: @escaping (Result<DocumentSharing, Error>) -> Void,
                        _ change: @escaping (StandInCloud.Document) -> Void) {
        later { [self] in
            guard let document = cloud.documents[id] else { return completion(.failure(CollaborationError.notShared)) }
            change(document)
            document.sharingVersion += 1
            cloud.changed(id)
            cloud.announce()
            completion(.success(cloud.sharing(of: document, for: me.id)))
        }
    }

    func share(_ id: UUID, title: String, snapshot: SyncSnapshot, comments: [SharedComment], access: LinkAccess,
               permission: CollaboratorPermission, completion: @escaping (Result<DocumentSharing, Error>) -> Void) {
        let document = StandInCloud.Document(id: id, title: title, owner: Collaborator(id: me.id, name: me.name, address: me.address, isOwner: true),
                                             access: access, linkPermission: permission, snapshot: snapshot)
        for comment in comments { document.comments[comment.thread.id] = (comment, document.bump()) }
        later { [self] in
            cloud.add(document)
            completion(.success(cloud.sharing(of: document, for: me.id)))
        }
    }

    func setAccess(_ access: LinkAccess, permission: CollaboratorPermission, of id: UUID,
                   completion: @escaping (Result<DocumentSharing, Error>) -> Void) {
        change(id, completion) { document in
            document.access = access
            document.linkPermission = permission
        }
    }

    func setPermission(_ permission: CollaboratorPermission, for person: Collaborator, in id: UUID,
                       completion: @escaping (Result<DocumentSharing, Error>) -> Void) {
        change(id, completion) { document in
            if let index = document.people.firstIndex(where: { $0.id == person.id && !$0.isOwner }) { document.people[index].permission = permission }
        }
    }

    func remove(_ person: Collaborator, from id: UUID, completion: @escaping (Result<DocumentSharing, Error>) -> Void) {
        change(id, completion) { document in document.people.removeAll { $0.id == person.id && !$0.isOwner } }
    }

    /// Someone invited joins a moment later.
    func invite(_ address: String, permission: CollaboratorPermission, to id: UUID,
                completion: @escaping (Result<DocumentSharing, Error>) -> Void) {
        let local = address.split(separator: "@").first.map(String.init) ?? address
        let name = cloud.directory[address.lowercased()] ?? local.prefix(1).uppercased() + local.dropFirst()
        let person = Collaborator(id: address.lowercased(), name: name, address: address, permission: permission, status: .invited)
        change(id, completion) { document in
            if !document.people.contains(where: { $0.id == person.id }) { document.people.append(person) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            guard let document = cloud.documents[id], let index = document.people.firstIndex(where: { $0.id == person.id }) else { return }
            document.people[index].status = .joined
            document.sharingVersion += 1
            cloud.changed(id)
            cloud.announce()
        }
    }

    func showInvitation(for id: UUID, relativeTo view: NSView) {}

    func stopSharing(_ id: UUID, completion: @escaping (Error?) -> Void) {
        later { [self] in
            cloud.remove(id)
            completion(nil)
        }
    }

    func leave(_ id: UUID, completion: @escaping (Error?) -> Void) {
        later { [self] in
            guard let document = cloud.documents[id] else { return completion(nil) }
            document.people.removeAll { $0.id == me.id }
            document.sharingVersion += 1
            cloud.changed(id)
            cloud.announce()
            completion(nil)
        }
    }

    /// The stand-in's links end in the spreadsheet's identifier. Anyone with the link joins a spreadsheet shared that way.
    func open(link url: URL, completion: @escaping (Result<SharedDocumentEntry, Error>) -> Void) {
        later { [self] in
            guard let id = UUID(uuidString: url.lastPathComponent), let document = cloud.documents[id] else {
                return completion(.failure(CollaborationError.failed("That link isn’t to a spreadsheet shared from PuggleSheets.")))
            }
            if !document.people.contains(where: { $0.id == me.id }) {
                guard document.access == .anyoneWithLink else {
                    return completion(.failure(CollaborationError.failed("That link doesn’t open for the Apple ID this Mac is signed in to iCloud with.")))
                }
                document.people.append(Collaborator(id: me.id, name: me.name, address: me.address, permission: document.linkPermission, status: .joined))
                document.sharingVersion += 1
                cloud.changed(id)
                cloud.announce()
            }
            completion(.success(SharedDocumentEntry(id: id, title: document.title, ownerName: document.owner.name, ownerID: document.owner.id)))
        }
    }

    func connect(_ id: UUID, owner: String?, delegate: CollaborationChannelDelegate) -> CollaborationChannel {
        StandInChannel(cloud: cloud, me: me, id: id, delegate: delegate)
    }
}

/// One person's line to one spreadsheet in the stand-in "iCloud".
final class StandInChannel: CollaborationChannel {
    let id: UUID
    private let cloud: StandInCloud
    private let me: Collaborator
    private weak var delegate: CollaborationChannelDelegate?
    private var isRunning = false
    private var delivered: Set<Int> = []
    private var seenVersion = 0
    private var seenSharing = -1
    private var gone = false
    private var seenTitle: String?
    var pollInterval: TimeInterval = 15

    init(cloud: StandInCloud, me: Collaborator, id: UUID, delegate: CollaborationChannelDelegate) {
        self.cloud = cloud
        self.me = me
        self.id = id
        self.delegate = delegate
    }

    private var document: StandInCloud.Document? { cloud.documents[id] }

    func start() {
        isRunning = true
        cloud.register(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + cloud.latency) { [weak self] in
            guard let self, let document else {
                self?.fetchSoon()
                return
            }
            seenSharing = document.sharingVersion
            seenTitle = document.title
            delegate?.channel(self, sharingChanged: cloud.sharing(of: document, for: me.id))
            delegate?.channel(self, loaded: document.snapshot, info: SharedDocumentInfo(title: document.title, ownerName: document.owner.name,
                                                                                          snapshotRevision: document.snapshot.revision))
            fetchSoon()
        }
    }

    func stop() { isRunning = false }

    /// This Mac, while the self-test has it offline.
    private var isCutOff: Bool { me.id == StandInCloud.me.id && !cloud.isReachable }

    private static var offline: Error { CKError(.networkUnavailable) }

    func fetchSoon() {
        guard isRunning, !gone else { return }
        if isCutOff {
            delegate?.channel(self, reachable: false)
            return
        }
        defer { if isRunning, !gone { delegate?.channel(self, reachable: true) } }
        guard let document, document.people.contains(where: { $0.id == me.id }) else {
            gone = true
            isRunning = false
            delegate?.channel(self, becameUnavailable: .stopped)
            return
        }
        if document.sharingVersion != seenSharing {
            seenSharing = document.sharingVersion
            delegate?.channel(self, sharingChanged: cloud.sharing(of: document, for: me.id))
        }
        if let seenTitle, seenTitle != document.title {
            self.seenTitle = document.title
            delegate?.channel(self, retitled: document.title)
        }
        let fresh = document.changes.values.filter { !delivered.contains($0.revision) }
        fresh.forEach { delivered.insert($0.revision) }
        let read = fresh.filter { me.id != StandInCloud.me.id || !cloud.skippedRevisions.contains($0.revision) }
        if !read.isEmpty { delegate?.channel(self, received: read) }
        let comments = document.comments.values.filter { $0.version > seenVersion }.map(\.comment)
        let deleted = document.deletedComments.filter { $0.version > seenVersion }.map(\.id)
        if !comments.isEmpty || !deleted.isEmpty { delegate?.channel(self, receivedComments: comments, deleted: deleted) }
        let presence = document.presence.values.filter { $0.version > seenVersion }.map(\.presence)
        if !presence.isEmpty { delegate?.channel(self, receivedPresence: presence) }
        seenVersion = document.version
    }

    private func later(_ work: @escaping () -> Void) {
        nonisolated(unsafe) let work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cloud.latency) { work() }
    }

    func fetchChanges(_ revisions: ClosedRange<Int>) {
        later { [self] in
            guard isRunning, !isCutOff, let document else { return }
            let found = revisions.compactMap { document.changes[$0] }
            if !found.isEmpty { delegate?.channel(self, received: found) }
            guard found.count < revisions.count else { return }
            delegate?.channel(self, loaded: document.snapshot, info: SharedDocumentInfo(title: document.title, ownerName: document.owner.name,
                                                                                      snapshotRevision: document.snapshot.revision))
        }
    }

    func claim(_ change: LoggedChange, completion: @escaping (ClaimResult) -> Void) {
        later { [self] in
            guard !isCutOff else { return completion(.failed(Self.offline)) }
            guard let document else { return completion(.failed(CollaborationError.notShared)) }
            let permission = document.owner.id == me.id ? .edit : document.people.first { $0.id == me.id }?.permission
            guard permission == .edit else { return completion(.notAllowed) }
            if let existing = document.changes[change.revision] { return completion(.taken(existing)) }
            document.changes[change.revision] = change
            delivered.insert(change.revision)
            cloud.changed(id)
            completion(.claimed)
        }
    }

    func saveSnapshot(_ snapshot: SyncSnapshot, title: String) {
        guard !isCutOff, let document, snapshot.revision > document.snapshot.revision else { return }
        document.snapshot = snapshot
    }

    func setTitle(_ title: String) {
        guard !isCutOff, let document, document.title != title else { return }
        document.title = title
        seenTitle = title
        cloud.changed(id)
        cloud.announce()
    }

    func save(_ comment: SharedComment, base: CommentThread?, completion: @escaping (Result<SharedComment, Error>) -> Void) {
        later { [self] in
            guard !isCutOff else { return completion(.failure(Self.offline)) }
            guard let document else { return completion(.failure(CollaborationError.notShared)) }
            var saved = comment
            if let server = document.comments[comment.thread.id]?.comment, server.thread != base, base != nil {
                saved = SharedComment(thread: SharedComment.merge(local: comment.thread, base: base, server: server.thread),
                                      anchor: SharedComment.later(comment.anchor, server.anchor))
            }
            document.comments[comment.thread.id] = (saved, document.bump())
            seenVersion = max(seenVersion, document.version)
            cloud.changed(id)
            completion(.success(saved))
        }
    }

    func deleteComment(_ id: String) {
        guard !isCutOff, let document, let thread = UUID(uuidString: id) else { return }
        document.comments[thread] = nil
        document.deletedComments.append((id, document.bump()))
        cloud.changed(self.id)
    }

    func setPresence(viewing: Bool, isOwner: Bool, permission: CollaboratorPermission) {
        guard !isCutOff, let document else { return }
        let info = PresenceInfo(name: me.name, isViewing: viewing, inboxURL: nil, isOwner: isOwner, permission: permission)
        document.presence[me.id] = (Presence(person: me.id, info: info, date: Date()), document.bump())
        cloud.changed(id)
    }

    func sendNotice(title: String, body: String, to people: [String]) {
        for person in people { cloud.addNotice(to: person, title: title, body: body, document: id) }
    }
}

/// A simulated person working on a shared spreadsheet in the stand-in "iCloud" from another Mac: the workbook as their
/// Mac has it, kept up through the log like any Mac's, for the self-test to edit and comment as them.
final class StandInPerson: CollaborationChannelDelegate {
    let person: Collaborator
    let service: StandInCollaboration
    private(set) var workbook = Workbook()
    private(set) var client: SyncClient?
    private var channel: CollaborationChannel?
    private(set) var comments: [UUID: SharedComment] = [:]
    private(set) var sharing: DocumentSharing?
    private(set) var isGone = false
    private(set) var refusals = 0
    private(set) var documentID: UUID?

    init(_ person: Collaborator, cloud: StandInCloud = .shared) {
        self.person = person
        service = StandInCollaboration(me: person, cloud: cloud)
        if let address = person.address { cloud.directory[address.lowercased()] = person.name }
    }

    /// Opens a spreadsheet shared with them.
    func join(_ id: UUID) {
        documentID = id
        let channel = service.connect(id, owner: nil, delegate: self)
        self.channel = channel
        channel.start()
        channel.setPresence(viewing: true, isOwner: false, permission: .edit)
    }

    /// Shares a workbook of theirs with `people`, each as they're allowed, and keeps it open.
    func share(title: String, workbook: Workbook, with people: [(Collaborator, CollaboratorPermission)], access: LinkAccess = .invited) -> UUID {
        let id = UUID()
        let snapshot = SyncSnapshot(revision: 0, workbook: workbook, anchors: [:])
        let document = StandInCloud.Document(id: id, title: title, owner: Collaborator(id: person.id, name: person.name, address: person.address, isOwner: true),
                                             access: access, linkPermission: .comment, snapshot: snapshot)
        for (someone, permission) in people {
            document.people.append(Collaborator(id: someone.id, name: someone.name, address: someone.address, permission: permission, status: .joined))
        }
        service.cloud.add(document)
        join(id)
        return id
    }

    /// Renames a spreadsheet of theirs.
    func rename(_ title: String) { channel?.setTitle(title) }

    func stopSharing() {
        guard let documentID else { return }
        channel?.stop()
        service.stopSharing(documentID) { _ in }
    }

    // MARK: Editing

    /// The sheet called `name`, or the first.
    func sheetID(_ name: String? = nil) -> UUID? {
        guard let name else { return workbook.sheets.first?.id }
        return workbook.sheetIndex(named: name).map { workbook.sheets[$0].id }
    }

    /// What a cell holds, as typed: its formula, else its value.
    func text(_ a1: String, sheet: String? = nil) -> String {
        guard let id = sheetID(sheet), let index = workbook.sheetIndex(id: id), let address = CellAddress(a1: a1) else { return "" }
        let cell = workbook.sheets[index][address]
        if let formula = cell.formula { return formula }
        return CellDisplay.text(for: cell.value, pattern: nil).text
    }

    /// Makes an edit as they would, and sends it.
    func edit(_ ops: [WorkbookOp]) {
        guard let client, !ops.isEmpty else { return }
        workbook.apply(ops)
        client.local(SharedChange(ops))
        flush()
    }

    /// Types a number, some text or a formula into a cell.
    func type(_ text: String, in a1: String, sheet: String? = nil) {
        guard let id = sheetID(sheet), let address = CellAddress(a1: a1) else { return }
        let cell: Cell
        if text.hasPrefix("=") {
            cell = Cell(formula: text)
        } else if let number = Double(text) {
            cell = Cell(value: .number(number))
        } else {
            cell = Cell(value: text.isEmpty ? .empty : .text(text))
        }
        edit([.cells(sheet: id, cells: [address: cell])])
    }

    /// Puts a picture in a cell, the way a Mac pasting one does.
    func insertImage(_ data: Data, in a1: String, sheet: String? = nil) {
        guard let id = sheetID(sheet), let address = CellAddress(a1: a1), let image = ImageData(data: data) else { return }
        edit([.cells(sheet: id, cells: [address: Cell(image: CellImage(image: image))])])
    }

    func insertRows(at row: Int, count: Int, sheet: String? = nil) {
        guard let id = sheetID(sheet) else { return }
        edit([.structure(sheet: id, change: .insertRows(at: row, count: count))])
    }

    /// Comments on a cell.
    func comment(_ text: String, on a1: String, sheet: String? = nil) {
        guard let client, let channel, let id = sheetID(sheet), let address = CellAddress(a1: a1),
              let place = client.logPlace(of: address, inSheet: id) else { return }
        let thread = CommentThread(comments: [Comment(author: person.name, authorID: person.id, text: text)])
        let comment = SharedComment(thread: thread, anchor: CommentAnchor(revision: client.revision, sheet: id, address: place))
        comments[thread.id] = comment
        channel.save(comment, base: nil) { _ in }
    }

    func reply(_ text: String, to threadID: UUID) {
        guard let channel, var comment = comments[threadID] else { return }
        let base = comment.thread
        comment.thread.comments.append(Comment(author: person.name, authorID: person.id, text: text))
        comments[threadID] = comment
        channel.save(comment, base: base) { _ in }
    }

    private func flush() {
        guard let client, let channel, let next = client.nextToSend() else { return }
        channel.claim(next) { [weak self] result in
            guard let self else { return }
            switch result {
            case .claimed:
                client.sent(next.id)
            case let .taken(existing):
                apply(client.sendTaken(next.id, by: existing))
            case .notAllowed:
                client.sendFailed(next.id)
                refusals += 1
                return
            case .failed:
                client.sendFailed(next.id)
                return
            }
            flush()
        }
    }

    private func apply(_ effects: [SyncEffect]) {
        for effect in effects {
            switch effect {
            case .apply(let change): workbook.apply(change.ops)
            case .replace(let replacement, _): workbook = replacement
            }
        }
    }

    func channel(_ channel: CollaborationChannel, loaded snapshot: SyncSnapshot, info: SharedDocumentInfo) {
        guard client == nil else { return }
        workbook = snapshot.workbook
        client = SyncClient(revision: snapshot.revision, workbook: snapshot.workbook, author: person.id, authorName: person.name)
    }

    func channel(_ channel: CollaborationChannel, received changes: [LoggedChange]) {
        guard let client else { return }
        apply(client.receive(changes))
        flush()
    }

    func channel(_ channel: CollaborationChannel, receivedComments comments: [SharedComment], deleted: [String]) {
        for comment in comments { self.comments[comment.thread.id] = comment }
        for id in deleted.compactMap(UUID.init(uuidString:)) { self.comments[id] = nil }
    }

    func channel(_ channel: CollaborationChannel, receivedPresence presence: [Presence]) {}

    func channel(_ channel: CollaborationChannel, sharingChanged sharing: DocumentSharing) { self.sharing = sharing }

    func channel(_ channel: CollaborationChannel, retitled title: String) {}

    func channel(_ channel: CollaborationChannel, becameUnavailable reason: UnavailableReason) { isGone = true }
}
#endif
