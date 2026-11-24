// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Large files that the system uploads in chunks (SPEC §7.18.6), and "Most compatible" videos (§7.18.2).
extension BackgroundBackupTests {
    /// Chunk requests "the system" has and has not reported yet.
    var pendingChunks: [FakeTransport.Started] {
        transport.started.filter { $0.request.url.path().contains("/uploads/") && transport.active.contains($0.jobId) }
    }

    func reportChunk(_ engine: BackupEngine, _ job: FakeTransport.Started, status code: Int = 201, error: NetworkError? = nil) async {
        transport.deactivate(job.jobId)
        await engine.backgroundUploadFinished(
            BackgroundUploadEvent(jobId: job.jobId, response: error == nil ? HTTPResponse(status: code) : nil, error: error))
    }

    @Test func aLargeFileWaitsInTheContainerAndGoesInChunksAFewAtATime() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001", .video, size: 1050))
        let engine = await makeEngine(maxFileSize: 100)
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { pendingChunks.count == 8 })
        // The export waits in the container, and next to it a copy of each chunk that is with the system.
        let staged = stagedFiles
        #expect(staged.contains("IMG_0001.MOV"))
        #expect(staged.count == 9)
        #expect(transport.started.allSatisfy { $0.fileExisted })
        // Videos wait for Wi-Fi by default: the system must not send their chunks over a cellular connection.
        #expect(transport.started.allSatisfy { !$0.request.allowsExpensiveNetwork })
        #expect(try await entry(engine, "0001")?.state == BackupItemState.pending.rawValue)

        await completeChunked(engine)
        await pass.value
        // 11 chunks of 100 bytes and the MOVE.
        #expect(transport.started.map(\.request.method).filter { $0 == "PUT" }.count == 11)
        #expect(transport.started.last?.request.method == "MOVE")
        #expect(try await entry(engine, "0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(try await entry(engine, "0001")?.serverPath?.hasSuffix("/IMG_0001.mov") == true)
        #expect(status.phase == .upToDate)
        #expect(stagedFiles.isEmpty)
        #expect(await engine.chunkedJobs.isEmpty)
    }

    /// The app ends while the system has some chunks; a later launch gets their reports and hands over the rest.
    @Test func aChunkedUploadGoesOnInTheNextLaunch() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001", .video, size: 1050))
        let first = await makeEngine(maxFileSize: 100)
        let pass = Task { await first.run(settings) }
        #expect(await eventually { pendingChunks.count == 8 })
        // The background time runs out: the pass is interrupted, the system keeps the chunks.
        await first.interrupt()
        await pass.value
        #expect(transport.cancelled.isEmpty)
        let handedOver = pendingChunks

        // The next launch (the system woke the app for the finished chunks).
        let later = await makeEngine(maxFileSize: 100)
        #expect(await later.chunkedJobs.count == 1)
        for job in handedOver { await reportChunk(later, job) }
        // The next three chunks went to the system right away, without a pass.
        #expect(pendingChunks.count == 3)
        #expect(await later.chunkedJobs.first?.value.upload.sent.count == 8)
        await completeChunked(later)
        #expect(try await entry(later, "0001")?.state == BackupItemState.uploaded.rawValue)
        // Exported once, every chunk sent once.
        #expect(library.exports == ["IMG_0001.MOV"])
        #expect(transport.started.filter { $0.request.method == "PUT" }.count == 11)
        #expect(stagedFiles.isEmpty)
    }

    /// A pass that finds a chunked upload of an earlier one does not export the file again, and continues it when the
    /// system has lost its chunks.
    @Test func aPassContinuesAChunkedUploadTheSystemLost() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001", .video, size: 350))
        let first = await makeEngine(maxFileSize: 100)
        let pass = Task { await first.run(settings) }
        #expect(await eventually { pendingChunks.count == 4 })
        await reportChunk(first, pendingChunks[0])
        await first.interrupt()
        await pass.value
        // The system was reset: it knows nothing of the other chunks and never reports them.
        for job in pendingChunks { transport.deactivate(job.jobId) }

        let later = await makeEngine(maxFileSize: 100)
        await later.setMissingCheckInterval(0.05)
        let next = Task { await later.run(settings) }
        // Found lost twice, the three chunks are handed over again; the one the server has is not.
        #expect(await eventually { pendingChunks.count == 3 })
        await completeChunked(later)
        await next.value
        #expect(library.exports == ["IMG_0001.MOV"])
        #expect(transport.started.filter { $0.request.method == "PUT" }.count == 4 + 3)
        #expect(try await entry(later, "0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(status.phase == .upToDate)
    }

    /// The user's pause takes the chunks back; the next pass sends only what the server does not have.
    @Test func thePauseTakesTheChunksBackAndTheNextPassGoesOn() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001", .video, size: 350))
        let engine = await makeEngine(maxFileSize: 100)
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { pendingChunks.count == 4 })
        await reportChunk(engine, pendingChunks[0])
        await engine.cancel()
        await pass.value
        #expect(await eventually { transport.cancelled.count == 3 })
        for job in pendingChunks { await reportChunk(engine, job, error: .cancelled) }
        // Nothing new was handed over while paused, and the export still waits.
        #expect(pendingChunks.isEmpty)
        #expect(stagedFiles.contains("IMG_0001.MOV"))

        let next = Task { await engine.run(settings) }
        #expect(await eventually { pendingChunks.count == 3 })
        await completeChunked(engine)
        await next.value
        #expect(transport.started.filter { $0.request.method == "PUT" }.count == 4 + 3)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(library.exports == ["IMG_0001.MOV"])
    }

    @Test func aRefusedChunkFailsTheFileAndStopsThePass() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001", .video, size: 350))
        let engine = await makeEngine(maxFileSize: 100)
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { pendingChunks.count == 4 })
        await reportChunk(engine, pendingChunks[1], status: 507)
        await pass.value
        #expect(status.blocker == .insufficientStorage)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.failed.rawValue)
        #expect(remote.state.withLock { $0.chunkedRequests.contains { $0.hasPrefix("DELETE") } })
        #expect(await engine.chunkedJobs.isEmpty)
        #expect(!stagedFiles.contains("IMG_0001.MOV"))
    }

    @Test func turningBackupOffRemovesTheLargeFilesThatWait() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001", .video, size: 350))
        let engine = await makeEngine(maxFileSize: 100)
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { pendingChunks.count == 4 })
        await engine.cancel()
        await pass.value
        var off = settings
        off.isEnabled = false
        await engine.settingsChanged(off)
        #expect(await engine.chunkedJobs.isEmpty)
        #expect(stagedFiles.isEmpty)
        #expect(await eventually { remote.state.withLock { $0.chunkedRequests.contains { $0.hasPrefix("DELETE") } } })
    }

    /// A chunked upload of the same file under the same name counts as the file (layer 5 before the chunks).
    @Test func aLargeFileThatIsOnTheServerIsNotSentInChunks() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001", .video, size: 350))
        let folder = BackupNaming.folder(base: settings.folder, subfolders: settings.subfolders, date: t0)
        remote.state.withLock {
            $0.files = [
                RemoteCandidate(
                    fileId: 7, path: "\(folder)/IMG_0001.mov", kind: .video, size: 350, capturedAt: nil, modifiedAt: t0 - 99_999)
            ]
        }
        let engine = await makeEngine(maxFileSize: 100)
        await engine.run(settings)
        #expect(transport.started.isEmpty)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(try await entry(engine, "0001")?.serverFileId == 7)
        #expect(stagedFiles.isEmpty)
    }

    // MARK: Most compatible (SPEC §7.18.2)

    func makeConvertingEngine(converted: ConversionLog) async -> BackupEngine {
        var background = BackgroundUploads(transport: transport, directory: directory)
        background.maxFileSize = 1000
        let engine = BackupEngine(
            library: library, remote: remote, database: database, accountId: AccountID(rawValue: "test"), background: background,
            convert: { file, resource in
                // Like the real conversion: a new file next to the export, the export removed.
                let target = file.deletingLastPathComponent().appending(path: "converted.\(resource.mediaKind == .video ? "mov" : "jpg")")
                try Data(repeating: 1, count: 7).write(to: target)
                try FileManager.default.removeItem(at: file)
                converted.add(resource.originalName, directory: file.deletingLastPathComponent())
                return target
            })
        let statuses = statuses
        await engine.setStatusHandler { status in statuses.values.withLock { $0.append(status) } }
        return engine
    }

    @Test func mostCompatibleConvertsVideosAndPhotosButNotRawFiles() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(
            resource("0001", .video, name: "IMG_0001.MOV"), resource("0002", at: 3600),
            resource("0003", .raw, name: "IMG_0003.DNG", at: 7200))
        var settings = settings
        settings.format = .mostCompatible
        let log = ConversionLog()
        let engine = await makeConvertingEngine(converted: log)
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 3 })
        #expect(log.names == ["IMG_0001.MOV", "IMG_0002.HEIC"])
        #expect(Set(transport.started.map(\.request.url.lastPathComponent)) == ["IMG_0001.mov", "IMG_0002.jpg", "IMG_0003.dng"])
        // A converted file is found again on the server by its name and capture time, not its bytes.
        #expect(remote.state.withLock { $0.conflicts["IMG_0001.mov"] } == .skipIfSameSizeOrTime(t0))
        #expect(remote.state.withLock { $0.conflicts["IMG_0003.dng"] } == .skipIfSameSize)
        for job in transport.started { await report(engine, job.request.url.lastPathComponent) }
        await pass.value
        #expect(status.phase == .upToDate)
        // Nothing of the exports and conversions is left.
        #expect(stagedFiles.isEmpty)
        for directory in log.directories { #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false))) }
    }

    /// The conversion is not the same bytes every time: a converted copy that is on the server under its name with the
    /// capture time is this file, not a reason for "IMG_0001 (2).mov".
    @Test func aConvertedCopyOnTheServerIsFoundByNameAndCaptureTime() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        add(resource("0001", .video, name: "IMG_0001.MOV"))
        var settings = settings
        settings.format = .mostCompatible
        let folder = BackupNaming.folder(base: settings.folder, subfolders: settings.subfolders, date: t0)
        // Uploaded by an earlier attempt whose answer got lost: another size, the same capture time. The pass knows the
        // server was asked recently, so it goes straight to the upload (layer 5).
        remote.state.withLock {
            $0.files = [RemoteCandidate(fileId: 9, path: "\(folder)/IMG_0001.mov", kind: .video, size: 99, capturedAt: nil, modifiedAt: t0)]
        }
        let engine = await makeConvertingEngine(converted: ConversionLog())
        try await engine.prepareLedger(pending: [resource("0001", .video, name: "IMG_0001.MOV")], touched: [])
        try await engine.recordCheck(matches: [], notFound: [resource("0001", .video, name: "IMG_0001.MOV")])
        await engine.run(settings)
        #expect(transport.started.isEmpty)
        #expect(try await entry(engine, "0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(try await entry(engine, "0001")?.serverFileId == 9)
    }
}

/// What the fake conversion converted, and where.
final class ConversionLog: Sendable {
    private let log = Mutex<(names: [String], directories: [URL])>(([], []))
    var names: [String] { log.withLock { $0.names } }
    var directories: [URL] { log.withLock { $0.directories } }
    func add(_ name: String, directory: URL) {
        log.withLock {
            $0.names.append(name); $0.directories.append(directory)
        }
    }
}
