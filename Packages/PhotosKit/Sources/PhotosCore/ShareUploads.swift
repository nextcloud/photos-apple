// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosModel
import PhotosNetworking
import Synchronization

#if canImport(UserNotifications)
    import UserNotifications
#endif

/// What the uploads of a share ask the server. The real one is `ServerShareUploadRemote`; tests use a fake.
protocol ShareUploadRemote: Sendable {
    func prepare(file: URL, fileName: String, folder: String, capturedAt: Date?, conflict: Uploader.ConflictPolicy, reserved: Set<String>)
        async throws -> Uploader.Prepared
    func prepareChunked(
        file: URL, fileName: String, folder: String, capturedAt: Date?, conflict: Uploader.ConflictPolicy, reserved: Set<String>
    ) async throws -> Uploader.PreparedChunked
    var chunkedServer: any ChunkedUploadServer { get }
    func finish(path: String, response: HTTPResponse) async throws -> UploadedFile
    func existingFile(at path: String, size: Int64) async throws -> UploadedFile?
    func addToAlbum(_ album: Album, path: String) async throws
}

struct ServerShareUploadRemote: ShareUploadRemote {
    let uploader: Uploader
    let api: PhotosAPI

    func prepare(file: URL, fileName: String, folder: String, capturedAt: Date?, conflict: Uploader.ConflictPolicy, reserved: Set<String>)
        async throws -> Uploader.Prepared
    {
        try await uploader.prepare(
            file: file, fileName: fileName, folder: folder, capturedAt: capturedAt, conflict: conflict, reserved: reserved)
    }

    func prepareChunked(
        file: URL, fileName: String, folder: String, capturedAt: Date?, conflict: Uploader.ConflictPolicy, reserved: Set<String>
    ) async throws -> Uploader.PreparedChunked {
        try await uploader.prepareChunked(
            file: file, fileName: fileName, folder: folder, capturedAt: capturedAt, conflict: conflict, reserved: reserved)
    }

    var chunkedServer: any ChunkedUploadServer { uploader }

    func finish(path: String, response: HTTPResponse) async throws -> UploadedFile {
        try await uploader.finish(path: path, response: response)
    }

    func existingFile(at path: String, size: Int64) async throws -> UploadedFile? {
        try await uploader.existingFile(at: path, size: size)
    }

    func addToAlbum(_ album: Album, path: String) async throws {
        try await api.addToAlbum(album, userPath: path)
    }
}

/// One shared file on its way.
struct ShareUploadItem: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        /// Waits to be handed to the system (new, failed and to be tried again, or lost by the system).
        case waiting
        /// With the system: one PUT (`jobId`) or in chunks (`chunked`).
        case sending
        case done
        case failed
    }

    var id: String
    /// The copy's name in the item's directory; the uploaded file gets the same name (or "name (2)").
    var name: String
    var folder: String
    var size: Int64
    var capturedAt: Date?
    /// A second attempt: a file of the same name and size at the destination is this one (the first attempt's answer
    /// got lost), instead of a reason for "name (2)".
    var sameSizeIsThisFile = false
    var state: State = .waiting
    var path: String?
    var jobId: String?
    var chunked: ChunkedUpload?
    var failure: String?
}

/// What a share's uploads are, kept in the shared container so the app can finish them when the share extension has ended.
struct ShareUploadRecord: Codable, Sendable {
    var accountId: AccountID
    var album: Album?
    var items: [ShareUploadItem] = []
    /// The share extension is alive until then (it renews this while it runs); afterwards the app may take the uploads over.
    var aliveUntil: Date?
}

/// The uploads of one share (SPEC §7.24), sent by a background transfer session of their own in the App Group container, so
/// that a large file goes on when the share extension is closed or ended: the system then launches the app for the
/// session's events, and the app takes the share over (`ShareUploads`). Files up to 100 MB are one PUT, larger ones go in
/// chunks (`ChunkedUploadDriver`), all without overwriting anything (`If-None-Match: *`, `Overwrite: F`).
///
/// The files wait in `<container>/Library/Application Support/ShareUploads/<session>/<item>/`; `batch.json` next to them
/// says what they are. Everything is removed when the share is through.
actor ShareUploadBatch {
    let identifier: String
    let directory: URL
    let transport: any BackgroundUploading
    let remote: any ShareUploadRemote
    private(set) var record: ShareUploadRecord
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "share")
    private var events: Task<Void, Never>?
    private var progressHandler: (@Sendable (ShareUploadProgress) -> Void)?
    /// Requests the system did not know at the last look: given up when they are still missing at the next one.
    private var missing: Set<String> = []
    /// The share is through (or cancelled) and its directory is gone: nothing is written any more.
    private var removed = false
    /// One piece of work at a time: the work waits for the network in the middle, and a report must not overtake a
    /// hand-over of the same file (they would work on two copies of its state).
    private let gate = AsyncGate()

    /// Files up to this size are one PUT; larger ones go in chunks.
    let maxSingleSize: Int64
    static let recordFile = "batch.json"

    init(
        identifier: String, directory: URL, record: ShareUploadRecord, transport: any BackgroundUploading, remote: any ShareUploadRemote,
        maxSingleSize: Int64 = 100 * 1024 * 1024
    ) {
        self.identifier = identifier
        self.directory = directory
        self.record = record
        self.transport = transport
        self.remote = remote
        self.maxSingleSize = maxSingleSize
    }

    /// Starts handling what the system reports. Called once.
    func listen() {
        guard events == nil else { return }
        let transport = transport
        events = Task { [weak self] in
            for await signal in transport.signals {
                switch signal {
                case .finished(let event): await self?.handle(event)
                case .drained: transport.eventsHandled()
                }
            }
        }
    }

    func setProgressHandler(_ handler: @escaping @Sendable (ShareUploadProgress) -> Void) {
        progressHandler = handler
        handler(progress)
    }

    var progress: ShareUploadProgress {
        let total = record.items.count
        let done = record.items.count { $0.state == .done }
        let failed = record.items.filter { $0.state == .failed }
        let sentBytes = record.items.reduce(Int64(0)) { sum, item in
            switch item.state {
            case .done: sum + item.size
            case .sending: sum + (item.chunked?.sentBytes ?? 0)
            case .waiting, .failed: sum
            }
        }
        let bytes = record.items.reduce(Int64(0)) { $0 + $1.size }
        return ShareUploadProgress(
            total: total, done: done, failed: failed.count, lastFailure: failed.last?.failure,
            fraction: bytes > 0 ? Double(sentBytes) / Double(bytes) : (total > 0 ? Double(done) / Double(total) : 1))
    }

    var isThrough: Bool { record.items.allSatisfy { $0.state == .done || $0.state == .failed } }

    // MARK: Adding and handing over

    /// Moves the shared files into the batch's directory and records them.
    func add(_ files: [(file: URL, capturedAt: Date?, sameSizeIsThisFile: Bool)], folder: String) throws {
        for (file, capturedAt, sameSize) in files {
            let id = UUID().uuidString
            let target = directory.appending(path: "\(id)/\(file.lastPathComponent)")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: target)
            let size = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            record.items.append(
                ShareUploadItem(
                    id: id, name: file.lastPathComponent, folder: folder, size: size, capturedAt: capturedAt, sameSizeIsThisFile: sameSize))
        }
        try save()
        publish()
    }

    /// Gives the waiting files to the system (after the lookups of their names), and the next chunks of large ones.
    /// Returns the first error that stopped it (no connection, invalid login); single files that failed are marked.
    @discardableResult
    func handOver() async -> (any Error)? {
        await gate.enter()
        defer { gate.leave() }
        return await handOverUnlocked()
    }

    private func handOverUnlocked() async -> (any Error)? {
        for index in record.items.indices {
            switch record.items[index].state {
            case .waiting:
                do {
                    try await start(index)
                } catch let error as NetworkError where error.isTransient || error == .unauthorized || error == .cancelled {
                    publish()
                    return error
                } catch {
                    fail(index, error)
                }
            case .sending where record.items[index].chunked != nil:
                await advanceChunked(index)
            case .sending, .done, .failed:
                continue
            }
        }
        try? save()
        publish()
        finishIfThrough()
        return nil
    }

    /// Lets the failed files be tried again: a file of the same name and size counts as uploaded then.
    func retryFailed() async -> (any Error)? {
        await gate.enter()
        defer { gate.leave() }
        for index in record.items.indices where record.items[index].state == .failed {
            record.items[index].state = .waiting
            record.items[index].failure = nil
            record.items[index].sameSizeIsThisFile = true
            record.items[index].path = nil
            record.items[index].chunked = nil
        }
        return await handOverUnlocked()
    }

    private func file(of item: ShareUploadItem) -> URL { directory.appending(path: "\(item.id)/\(item.name)") }

    private var reservedPaths: Set<String> {
        Set(record.items.filter { $0.state == .sending }.compactMap(\.path))
    }

    private func start(_ index: Int) async throws {
        let item = record.items[index]
        let file = file(of: item)
        let conflict: Uploader.ConflictPolicy = item.sameSizeIsThisFile ? .skipIfSameSize : .rename
        if item.size > maxSingleSize {
            switch try await remote.prepareChunked(
                file: file, fileName: item.name, folder: item.folder, capturedAt: item.capturedAt, conflict: conflict,
                reserved: reservedPaths)
            {
            case .existing(let uploaded):
                await done(index, uploaded)
            case .chunked(let upload):
                record.items[index].state = .sending
                record.items[index].path = upload.path
                record.items[index].chunked = upload
                try save()
                await advanceChunked(index)
            }
            return
        }
        switch try await remote.prepare(
            file: file, fileName: item.name, folder: item.folder, capturedAt: item.capturedAt, conflict: conflict, reserved: reservedPaths)
        {
        case .existing(let uploaded):
            await done(index, uploaded)
        case .put(let path, let request):
            let jobId = UUID().uuidString
            record.items[index].state = .sending
            record.items[index].path = path
            record.items[index].jobId = jobId
            // Recorded before it starts: whoever gets the report has to understand it.
            try save()
            do {
                try await transport.start(jobId: jobId, request: request, file: file)
            } catch {
                record.items[index].state = .waiting
                record.items[index].jobId = nil
                try? save()
                throw error
            }
        }
    }

    private func files(of item: ShareUploadItem) -> ChunkedUploadDriver.Files {
        ChunkedUploadDriver.Files(file: file(of: item), chunks: directory.appending(path: "\(item.id)/chunks"))
    }

    private var driver: ChunkedUploadDriver { ChunkedUploadDriver(transport: transport, uploader: remote.chunkedServer) }

    private func advanceChunked(_ index: Int) async {
        guard var upload = record.items[index].chunked else { return }
        let item = record.items[index]
        let progress = await driver.advance(&upload, files: files(of: item)) { self.update(item.id, $0) }
        update(item.id, upload)
        await ended(item.id, progress)
    }

    private func update(_ id: String, _ upload: ChunkedUpload) {
        guard let index = record.items.firstIndex(where: { $0.id == id }) else { return }
        record.items[index].chunked = upload
        try? save()
    }

    private func ended(_ id: String, _ progress: ChunkedUploadDriver.Progress) async {
        guard let index = record.items.firstIndex(where: { $0.id == id }) else { return }
        switch progress {
        case .running: return
        case .finished(let uploaded): await done(index, uploaded)
        case .failed(let error):
            // The name was taken after the lookup, or an earlier launch stopped it: once more, with a new lookup (the
            // same file under the same name counts as uploaded then).
            if let error = error as? NetworkError, error == .preconditionFailed || error == .cancelled {
                record.items[index].sameSizeIsThisFile = record.items[index].sameSizeIsThisFile || error == .cancelled
                record.items[index].state = .waiting
                record.items[index].chunked = nil
                record.items[index].path = nil
                try? save()
                _ = await handOverUnlocked()
            } else {
                fail(index, error)
            }
        }
    }

    // MARK: Reports

    /// The system reports a request of this batch.
    func handle(_ event: BackgroundUploadEvent) async {
        await gate.enter()
        defer { gate.leave() }
        missing.remove(event.jobId)
        if let index = record.items.firstIndex(where: { $0.jobId == event.jobId && $0.state == .sending }) {
            await singleFinished(index, event: event)
        } else if let index = record.items.firstIndex(where: { $0.chunked?.running[event.jobId] != nil }) {
            guard var upload = record.items[index].chunked else { return }
            let item = record.items[index]
            let progress = await driver.report(event, upload: &upload, files: files(of: item)) { self.update(item.id, $0) }
            update(item.id, upload)
            if let progress { await ended(item.id, progress) }
        }
        publish()
        finishIfThrough()
    }

    private func singleFinished(_ index: Int, event: BackgroundUploadEvent) async {
        let item = record.items[index]
        do {
            if let error = event.error { throw error }
            guard let response = event.response, let path = item.path else { throw NetworkError.invalidResponse("no answer") }
            await done(index, try await remote.finish(path: path, response: response))
        } catch NetworkError.preconditionFailed {
            // Another file took the name after the lookup: nothing was overwritten. Once more, with a new look.
            record.items[index].state = .waiting
            record.items[index].jobId = nil
            record.items[index].path = nil
            try? save()
            _ = await handOverUnlocked()
        } catch {
            if let error = error as? NetworkError, error == .cancelled {
                record.items[index].state = .waiting
                record.items[index].jobId = nil
                try? save()
                return
            }
            // The answer may be lost although the file arrived.
            if let path = item.path, let uploaded = try? await remote.existingFile(at: path, size: item.size) {
                await done(index, uploaded)
            } else {
                fail(index, error)
            }
        }
    }

    private func done(_ index: Int, _ uploaded: UploadedFile) async {
        let item = record.items[index]
        if let album = record.album {
            do {
                try await remote.addToAlbum(album, path: uploaded.path)
            } catch {
                logger.error("share: adding an upload to the album failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        record.items[index].state = .done
        record.items[index].path = uploaded.path
        record.items[index].chunked = nil
        try? FileManager.default.removeItem(at: directory.appending(path: item.id))
        try? save()
    }

    private func fail(_ index: Int, _ error: any Error) {
        logger.error("share: an upload failed: \(error.localizedDescription, privacy: .public)")
        record.items[index].state = .failed
        record.items[index].failure = error.localizedDescription
        record.items[index].jobId = nil
        try? save()
    }

    /// Requests the system no longer knows and never reported (it was reset): seen twice, they are handed over again.
    func checkLost() async {
        await gate.enter()
        defer { gate.leave() }
        let active = await transport.activeJobIds()
        var gone = Set<String>()
        for index in record.items.indices where record.items[index].state == .sending {
            if let jobId = record.items[index].jobId, !active.contains(jobId) {
                gone.insert(jobId)
                if missing.contains(jobId) {
                    record.items[index].state = .waiting
                    record.items[index].jobId = nil
                    // The first attempt may have arrived: the same file under the same name is this one.
                    record.items[index].sameSizeIsThisFile = true
                }
            }
            if var upload = record.items[index].chunked {
                let lost = Set(upload.running.keys).subtracting(active)
                gone.formUnion(lost)
                upload.lost(lost.intersection(missing))
                record.items[index].chunked = upload
            }
        }
        missing = gone.subtracting(missing)
        try? save()
        _ = await handOverUnlocked()
    }

    // MARK: Ending

    /// Nothing waits any more: the copies are gone; the record stays while something failed (the extension shows it), and
    /// the session is released.
    private func finishIfThrough() {
        guard isThrough, record.items.allSatisfy({ $0.state == .done }) else { return }
        removed = true
        try? FileManager.default.removeItem(at: directory)
        (transport as? BackgroundUploadSession)?.finishAndInvalidate()
    }

    /// The user cancelled: what the system has is taken back, and the copies are removed.
    func cancelAll() async {
        await gate.enter()
        defer { gate.leave() }
        let ids = Set(record.items.compactMap(\.jobId)).union(record.items.flatMap { $0.chunked?.running.keys.map { $0 } ?? [] })
        await transport.cancel(jobIds: ids)
        for item in record.items where item.state == .sending {
            if let upload = item.chunked { await remote.chunkedServer.abandon(upload, after: nil) }
        }
        removed = true
        try? FileManager.default.removeItem(at: directory)
        (transport as? BackgroundUploadSession)?.finishAndInvalidate()
    }

    /// Forgets the share (the app has told the user what failed).
    func discard() {
        removed = true
        try? FileManager.default.removeItem(at: directory)
        (transport as? BackgroundUploadSession)?.finishAndInvalidate()
    }

    /// The share extension is alive for a while longer (see `ShareUploadRecord.aliveUntil`).
    func keepAlive(until date: Date?) {
        record.aliveUntil = date
        try? save()
    }

    private func save() throws {
        guard !removed else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
        try JSONEncoder().encode(record).write(to: directory.appending(path: Self.recordFile), options: .atomic)
    }

    private func publish() {
        progressHandler?(progress)
    }
}

/// How far a share's uploads are.
public struct ShareUploadProgress: Sendable, Equatable {
    public var total: Int
    public var done: Int
    public var failed: Int
    public var lastFailure: String?
    /// 0…1 by bytes.
    public var fraction: Double

    public var isThrough: Bool { done + failed == total }
}

/// The share extension's uploads that go on in the background, and the app's part in them (SPEC §7.24).
public enum ShareUploads {
    private static let logger = Logger(subsystem: "com.nextcloud.photos", category: "share")
    /// Identifiers of the background sessions of shares start with this.
    static let sessionPrefix = "share-upload."
    /// The share extension renews its claim on a share this often, for this long.
    static let heartbeat: TimeInterval = 15
    static let aliveFor: TimeInterval = 45

    static func directory(_ layout: StorageLayout) -> URL {
        layout.container.appending(path: "Library/Application Support/ShareUploads")
    }

    /// Batches this process works on, by session identifier.
    private static let batches = Mutex<[String: ShareUploadBatch]>([:])

    /// This process works on the share's uploads (tests).
    static func isAttached(_ identifier: String) -> Bool { batches.withLock { $0[identifier] != nil } }

    /// Whether a background session belongs to a share (the app was launched for its events).
    public static func owns(_ identifier: String) -> Bool { identifier.hasPrefix(sessionPrefix) }

    static func remote(for account: Account, layout: StorageLayout, keychain: Keychain) -> ServerShareUploadRemote? {
        guard let password = keychain.string(for: Keychain.passwordKey(account.id.rawValue)) else { return nil }
        let http = AppModel.makeHTTPClient(layout: layout, keychain: keychain)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let connection = ServerConnection(
            serverURL: account.serverURL, userId: account.userId, loginName: account.loginName, appPassword: password,
            userAgent: UserAgent.make(appVersion: version))
        let dav = DAVClient(http: http, connection: connection)
        return ServerShareUploadRemote(
            uploader: Uploader(dav: dav), api: PhotosAPI(dav: dav, ocs: OCSClient(http: http, connection: connection)))
    }

    static func session(_ identifier: String, layout: StorageLayout, keychain: Keychain) -> BackgroundUploadSession {
        BackgroundUploadSession(
            identifier: identifier, sharedContainer: AppPaths.usesAppGroup ? AppPaths.appGroup : nil,
            trustStore: TrustStore(directory: layout.certificates),
            clientCredentials: { host in AppModel.clientCredential(host: host, keychain: keychain) })
    }

    // MARK: Share extension

    /// A new share's uploads, in a session of their own (the extension never uses another's).
    public final class Share: Sendable {
        let batch: ShareUploadBatch
        private let heartbeat: Task<Void, Never>

        init(batch: ShareUploadBatch) {
            self.batch = batch
            heartbeat = Task { [batch] in
                while !Task.isCancelled {
                    await batch.keepAlive(until: Date().addingTimeInterval(ShareUploads.aliveFor))
                    try? await Task.sleep(for: .seconds(ShareUploads.heartbeat))
                }
            }
        }

        deinit { heartbeat.cancel() }

        /// Moves the copies of the shared files into the shared container, looks up their names and gives them to the system.
        /// Returns what stopped the hand-over (no connection, invalid login), if anything.
        public func upload(_ files: [(file: URL, capturedAt: Date?, sameSizeIsThisFile: Bool)], folder: String) async throws -> (
            any Error
        )? {
            try await batch.add(files, folder: folder)
            return await batch.handOver()
        }

        public func retryFailed() async -> (any Error)? { await batch.retryFailed() }

        /// How far the uploads are, whenever that changes (until the share is through).
        public func progressUpdates() async -> AsyncStream<ShareUploadProgress> {
            let (stream, continuation) = AsyncStream.makeStream(of: ShareUploadProgress.self, bufferingPolicy: .bufferingNewest(1))
            await batch.setProgressHandler { continuation.yield($0) }
            return stream
        }

        /// The user cancelled the share.
        public func cancel() async {
            heartbeat.cancel()
            await batch.cancelAll()
        }

        /// The extension closes while the system still uploads: the app finishes the rest.
        public func leaveToApp() async {
            heartbeat.cancel()
            await batch.keepAlive(until: nil)
        }
    }

    /// Starts a share's uploads for an account (in the share extension).
    public static func start(account: Account, album: Album?, layout: StorageLayout = AppPaths.layout, keychain: Keychain = Keychain())
        async throws -> Share
    {
        guard let remote = remote(for: account, layout: layout, keychain: keychain) else { throw NetworkError.unauthorized }
        let identifier = sessionPrefix + UUID().uuidString
        let batch = ShareUploadBatch(
            identifier: identifier, directory: directory(layout).appending(path: identifier),
            record: ShareUploadRecord(accountId: account.id, album: album, aliveUntil: Date().addingTimeInterval(aliveFor)),
            transport: session(identifier, layout: layout, keychain: keychain), remote: remote)
        await batch.listen()
        batches.withLock { $0[identifier] = batch }
        return Share(batch: batch)
    }

    // MARK: App

    /// The system launched or woke the app for a share's session: the share extension has ended. The app creates the
    /// session (which delivers the reports), finishes the uploads and hands over the next chunks. `completion` is the
    /// system's handler; it is called once the reports are recorded.
    public static func takeOver(
        _ identifier: String, completion: @escaping @MainActor @Sendable () -> Void, layout: StorageLayout = AppPaths.layout,
        keychain: Keychain = Keychain()
    ) {
        if let batch = batches.withLock({ $0[identifier] }) {
            batch.transport.setEventsCompletion(completion)
            return
        }
        guard let batch = load(identifier, layout: layout, keychain: keychain) else {
            Task { @MainActor in completion() }
            return
        }
        batch.transport.setEventsCompletion(completion)
        Task {
            await batch.listen()
            // Reports first; what the system lost is handed over again on the second look.
            try? await Task.sleep(for: .seconds(5))
            await batch.checkLost()
            try? await Task.sleep(for: .seconds(20))
            await batch.checkLost()
            await notifyFailures(batch)
        }
    }

    /// At launch: takes over the shares whose extension has ended without the system launching the app for them (nothing
    /// had been handed over yet, or everything ended while the app was running).
    public static func resumeAbandoned(layout: StorageLayout = AppPaths.layout, keychain: Keychain = Keychain(), now: Date = Date()) {
        let root = directory(layout)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        for identifier in names where owns(identifier) {
            guard batches.withLock({ $0[identifier] == nil }),
                let record = loadRecord(root.appending(path: identifier)), (record.aliveUntil ?? .distantPast) < now
            else { continue }
            logger.notice("share: an upload of an ended share goes on in the app")
            takeOver(identifier, completion: {}, layout: layout, keychain: keychain)
        }
    }

    static func loadRecord(_ directory: URL) -> ShareUploadRecord? {
        guard let data = try? Data(contentsOf: directory.appending(path: ShareUploadBatch.recordFile)) else { return nil }
        return try? JSONDecoder().decode(ShareUploadRecord.self, from: data)
    }

    private static func load(_ identifier: String, layout: StorageLayout, keychain: Keychain) -> ShareUploadBatch? {
        let directory = directory(layout).appending(path: identifier)
        guard let record = loadRecord(directory) else { return nil }
        guard let account = AccountRegistry.load(from: layout.accountsFile).accounts.first(where: { $0.id == record.accountId }),
            let remote = remote(for: account, layout: layout, keychain: keychain)
        else {
            // The account is gone: so is what it shared.
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        let batch = ShareUploadBatch(
            identifier: identifier, directory: directory, record: record,
            transport: session(identifier, layout: layout, keychain: keychain),
            remote: remote)
        batches.withLock { $0[identifier] = batch }
        return batch
    }

    /// Shared files that could not be uploaded after the extension had ended: the user is told once, and the copies go.
    private static func notifyFailures(_ batch: ShareUploadBatch) async {
        guard await batch.isThrough else { return }
        let failed = await batch.progress.failed
        batches.withLock { $0[batch.identifier] = nil }
        await batch.discard()
        guard failed > 0 else { return }
        logger.error("share: \(failed, privacy: .public) shared items could not be uploaded")
        await ShareUploadNotice.post(failed: failed)
    }
}

#if canImport(UserNotifications)
    /// Tells the user that shared items could not be uploaded after the share extension had closed.
    enum ShareUploadNotice {
        static func post(failed: Int) async {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Shared items were not uploaded", bundle: .module)
            content.body = String(
                localized: "\(failed) items you shared to Nextcloud Photos could not be uploaded. Share them again to try once more.",
                bundle: .module)
            try? await center.add(
                UNNotificationRequest(identifier: "share-upload-failed-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }
#else
    enum ShareUploadNotice {
        static func post(failed: Int) async {}
    }
#endif
