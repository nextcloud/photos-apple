// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosBackup
@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking

/// A background transfer session under the test's control.
final class StubTransport: BackgroundUploading {
    struct State: Sendable {
        var handled = 0
        var completion: (@MainActor @Sendable () -> Void)?
        var cancelled: Set<String> = []
    }

    let identifier = "tests.backup"
    let signals: AsyncStream<BackgroundUploadSignal>
    let continuation: AsyncStream<BackgroundUploadSignal>.Continuation
    let state = Mutex(State())

    init() {
        (signals, continuation) = AsyncStream.makeStream(of: BackgroundUploadSignal.self)
    }

    func start(jobId: String, request: HTTPRequest, file: URL) async throws {}
    func activeJobIds() async -> Set<String> { [] }
    func cancel(jobIds: Set<String>) async { state.withLock { $0.cancelled.formUnion(jobIds) } }
    func setEventsCompletion(_ handler: @escaping @MainActor @Sendable () -> Void) { state.withLock { $0.completion = handler } }

    func eventsHandled() {
        let completion = state.withLock { state in
            state.handled += 1
            defer { state.completion = nil }
            return state.completion
        }
        if let completion { Task { @MainActor in completion() } }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BackgroundUploadWiringTests {
    let sandbox = Sandbox()
    let server = StubServer()
    let transport = StubTransport()

    func makeApp() -> AppModel {
        let suite = "photos-core-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let transport = transport
        return AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration, backgroundUploads: { _, _ in transport })
    }

    func seedAccount() throws -> Account {
        let account = makeAccount("alice", server: server.url.absoluteString)
        try sandbox.keychain.set("password", for: Keychain.passwordKey(account.id.rawValue))
        try AccountRegistry(accounts: [account], activeAccountID: account.id).save(to: sandbox.layout.accountsFile)
        var settings = BackupSettings()
        settings.isEnabled = true
        settings.accountId = account.id
        try settings.save(to: sandbox.layout.backupSettingsFile)
        return account
    }

    final class Flag: Sendable {
        private let flag = Mutex(false)
        var isSet: Bool { flag.withLock { $0 } }
        func set() { flag.withLock { $0 = true } }
    }

    @Test func aReportFromTheSystemReachesTheLedgerOfTheBackupAccount() async throws {
        defer { sandbox.remove() }
        let account = try seedAccount()
        // An earlier launch handed this upload to the system: its record and its file are in the account's directory.
        let directory = sandbox.layout.accountDirectory(account.id).appending(path: "BackgroundUploads")
        let resource = BackupResource(
            localIdentifier: "asset-1", kind: .photo, mediaKind: .image, originalName: "IMG_0001.HEIC",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: nil, pixelWidth: 0, pixelHeight: 0, byteSize: 3)
        var journal = BackgroundUploadJournal(directory: directory)
        let source = sandbox.root.appending(path: "IMG_0001.HEIC")
        try Data([1, 2, 3]).write(to: source)
        let staged = try journal.stage(source, id: "job-1")
        try journal.add(BackgroundUploadJob(id: "job-1", resource: resource, path: "/Photos/IMG_0001.heic", size: 3, startedAt: Date()))

        let app = makeApp()
        // The engine of the backup account works with the session and finds the record.
        let engine = try #require(app.backup.prepareEngine())
        #expect(engine.background?.directory == directory)
        #expect(await engine.backgroundJobs.keys.sorted() == ["job-1"])

        // The system launched the app for finished uploads: it reports the upload, then that this was all.
        let called = Flag()
        app.handleBackgroundUploadEvents(identifier: transport.identifier) { called.set() }
        let response = HTTPResponse(status: 201, headers: ["oc-fileid": "00000077ocstub"])
        transport.continuation.yield(.finished(BackgroundUploadEvent(jobId: "job-1", response: response)))
        transport.continuation.yield(.drained)
        #expect(await eventually { called.isSet })

        // By then the upload is in the ledger and its file is gone.
        let entries = await app.backup.entries()
        #expect(entries.map(\.localIdentifier) == ["asset-1"])
        #expect(entries.first?.state == BackupItemState.uploaded.rawValue)
        #expect(entries.first?.serverFileId == 77)
        #expect(entries.first?.serverPath == "/Photos/IMG_0001.heic")
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        #expect(app.backup.status.uploaded == 1)
        #expect(transport.state.withLock { $0.handled } == 1)
        await app.session?.shutdown(closeDatabase: true)
    }

    @Test func eventsOfAnotherSessionAreAnsweredAtOnce() async throws {
        defer { sandbox.remove() }
        _ = try seedAccount()
        let app = makeApp()
        let called = Flag()
        app.handleBackgroundUploadEvents(identifier: "someone.else") { called.set() }
        #expect(called.isSet)
        await app.session?.shutdown(closeDatabase: true)
    }

    @Test func withoutASessionTheAppUploadsItself() async throws {
        defer { sandbox.remove() }
        _ = try seedAccount()
        let suite = "photos-core-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let app = AppModel(
            appVersion: "1.0", layout: sandbox.layout, keychain: sandbox.keychain, defaults: defaults,
            httpConfiguration: server.configuration)
        #expect(try #require(app.backup.prepareEngine()).background == nil)
        // No window, no session: on the Mac nothing is handed to the system.
        #if os(macOS)
            #expect(AppModel.systemBackgroundUploads == nil)
        #endif
        await app.session?.shutdown(closeDatabase: true)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SequentialUploadsTests {
    struct Refused: Error {}

    @Test func aFailureKeepsTheRestForAnotherAttempt() async {
        var uploaded: [String] = []
        var failing: Set<String> = ["c"]
        let first = await SequentialUploads.run(["a", "b", "c", "d"]) { item in
            if failing.contains(item) { throw Refused() }
        } done: {
            uploaded.append($0)
        }
        #expect(uploaded == ["a", "b"])
        #expect(first.remaining == ["c", "d"])
        #expect(first.error is Refused)

        // The second attempt only sends what is left.
        failing = []
        let second = await SequentialUploads.run(first.remaining) { _ in
        } done: {
            uploaded.append($0)
        }
        #expect(uploaded == ["a", "b", "c", "d"])
        #expect(second.remaining.isEmpty)
        #expect(second.error == nil)
    }
}
