// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import Synchronization
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

// Review r3, items 22 and 26: passes on a large library look only at what changed, upload what waits without
// asking again, start uploading after the first batch, and write a batch's results in one transaction.

extension BackupEngineTests {
    func trackChanges() { library.state.withLock { $0.tracksChanges = true } }

    @Test func aPassOnlyLooksAtWhatChangedSinceTheLastOne() async throws {
        trackChanges()
        addPhotos(["0001", "0002", "0003"])
        await engine.run(settings)
        #expect(library.lookedAt == ["0001", "0002", "0003"])
        #expect(remote.uploads.count == 3)

        let searches = remote.searches
        await engine.run(settings)
        #expect(library.lookedAt == [])
        #expect(remote.searches == searches)
        #expect(status.phase == .upToDate)

        addPhotos(["0004"])
        await engine.run(settings)
        #expect(library.lookedAt == ["0004"])
        #expect(remote.uploads.count == 4)

        library.state.withLock {
            $0.assets[1].modifiedAt = t0 + 500; $0.assets[1].resources[0].modifiedAt = t0 + 500
        }
        await engine.run(settings)
        #expect(library.lookedAt == ["0002"])
        #expect(library.lastScan == ["0002"])
        #expect(remote.uploads.count == 4)
    }

    @Test func theWholeLibraryIsLookedAtOnceADayAfterTheUploads() async throws {
        trackChanges()
        addPhotos(["0001", "0002"])
        await engine.run(settings)
        await engine.run(settings)
        #expect(library.lookedAt == [])

        clock.advance(BackupPolicy.fullScanInterval + 1)
        addPhotos(["0003"])
        await engine.run(settings)
        let scans = library.state.withLock { $0.lookedAt.suffix(2) }
        // First what changed (and its upload), then everything.
        #expect(Array(scans) == [["0003"], ["0001", "0002", "0003"]])
        #expect(remote.uploads.count == 3)
        await engine.run(settings)
        #expect(library.lookedAt == [])
    }

    @Test func everythingIsLookedAtWhenWhatChangedCannotBeTold() async throws {
        trackChanges()
        addPhotos(["0001", "0002"])
        await engine.run(settings)
        library.state.withLock { $0.historyLost = true }
        await engine.run(settings)
        #expect(library.lookedAt == ["0001", "0002"])
        // What is known completely is not read.
        #expect(library.lastScan == [])
    }

    @Test func anotherSelectionLooksAtEverything() async throws {
        trackChanges()
        addPhotos(["0001", "0002"])
        await engine.run(settings)
        var changed = settings
        changed.includeHidden = true
        await engine.run(changed)
        #expect(library.lookedAt == ["0001", "0002"])
        await engine.run(changed)
        #expect(library.lookedAt == [])
    }

    @Test func aDeletedAssetNoLongerWaitsAlsoWhenOnlyChangesAreLookedAt() async throws {
        trackChanges()
        library.state.withLock {
            $0.assets = [.init(id: "0001", modifiedAt: t0, resources: [resource("0001"), resource("0001", .pairedVideo)])]
        }
        await engine.setNetwork(BackupNetwork(isExpensive: true))
        await engine.run(settings)
        #expect(try await entry("0001", .pairedVideo)?.state == BackupItemState.pending.rawValue)
        await engine.cancel()

        library.state.withLock { $0.assets = [] }
        await engine.run(settings)
        #expect(library.lookedAt == [])
        #expect(try await entry("0001", .pairedVideo) == nil)
        #expect(try await entry("0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(status.phase == .upToDate)
    }

    @Test func entriesWithoutTheirResourceHaveTheirAssetRead() async throws {
        trackChanges()
        library.state.withLock {
            $0.assets = [.init(id: "0001", modifiedAt: t0, resources: [resource("0001"), resource("0001", .pairedVideo)])]
        }
        await engine.setNetwork(BackupNetwork(isExpensive: true))
        await engine.run(settings)
        await engine.cancel()
        // As an earlier version wrote it.
        try await engine.database.writer.write { db in try db.execute(sql: "UPDATE backupAsset SET resource = NULL") }

        await engine.setNetwork(BackupNetwork())
        await engine.run(settings)
        #expect(library.lastScan == ["0001"])
        #expect(remote.uploads == ["IMG_0001.heic", "IMG_0001.mov"])
    }

    @Test func theServerIsNotAskedAgainAboutWhatWaitsUntilItsAnswerIsOld() async throws {
        library.state.withLock {
            $0.assets = [.init(id: "0001", modifiedAt: t0, resources: [resource("0001"), resource("0001", .pairedVideo)])]
        }
        await engine.setNetwork(BackupNetwork(isExpensive: true))
        await engine.run(settings)
        let searches = remote.searches
        #expect(try await entry("0001", .pairedVideo)?.checkedAt != nil)

        await engine.cancel()
        await engine.run(settings)
        await engine.cancel()
        #expect(remote.searches == searches)

        clock.advance(BackupPolicy.serverCheckValidity + 1)
        await engine.run(settings)
        await engine.cancel()
        #expect(remote.searches == searches + 1)

        // The user's "Back up now" asks again.
        await engine.run(settings, retryFailed: true)
        await engine.cancel()
        #expect(remote.searches == searches + 2)
    }

    @Test func uploadsStartAfterTheFirstChunkIsChecked() async throws {
        await engine.setServerCheckChunk(2)
        addPhotos(["0001", "0002", "0003", "0004", "0005"])
        await engine.run(settings)
        // One request per chunk, each after the uploads of the one before.
        #expect(remote.state.withLock { $0.uploadsAtSearch } == [0, 2, 4])
        #expect(remote.uploads.count == 5)
        #expect(status.phase == .upToDate)
        #expect(status.uploadedThisPass == 5)
    }

    @Test func anInterruptedPassGoesOnWhereItStopped() async throws {
        await engine.setServerCheckChunk(2)
        addPhotos(["0001", "0002", "0003", "0004", "0005"])
        let engine = engine
        remote.beforeCandidates.withLock {
            $0 = { [remote] in
                // The system takes the time away while the server is asked about the second chunk.
                if remote.searches == 1 { await engine.interrupt() }
            }
        }
        await engine.run(settings)
        #expect(status.isInterrupted)
        #expect(remote.uploads.count == 2)
        #expect(remote.searches == 2)

        remote.beforeCandidates.withLock { $0 = nil }
        await engine.run(settings)
        // The second chunk was answered: only the fifth photo is asked about.
        #expect(remote.searches == 3)
        #expect(library.lastScan == [])
        #expect(remote.uploads == ["IMG_0001.heic", "IMG_0002.heic", "IMG_0003.heic", "IMG_0004.heic", "IMG_0005.heic"])
        #expect(status.phase == .upToDate)
    }

    @Test func aNewEditIsNotForgottenWhenThePassIsInterrupted() async throws {
        trackChanges()
        library.state.withLock {
            $0.assets = [
                .init(
                    id: "0001", modifiedAt: t0,
                    resources: [resource("0001"), resource("0001", .edited, name: "IMG_E0001.HEIC", size: 20)])
            ]
        }
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0001.heic", "IMG_E0001.heic"])

        // A new edit; the system takes the time away while it is being uploaded.
        library.state.withLock { state in
            state.assets[0].modifiedAt = t0 + 300
            for index in state.assets[0].resources.indices { state.assets[0].resources[index].modifiedAt = t0 + 300 }
            state.assets[0].resources[1].byteSize = 25
        }
        let engine = engine
        remote.beforeUpload.withLock {
            $0 = { [remote] _ in
                remote.state.withLock { $0.uploadError = .cancelled }
                await engine.interrupt()
            }
        }
        await engine.run(settings)
        #expect(status.isInterrupted)
        #expect(try await entry("0001", .edited)?.state == BackupItemState.pending.rawValue)

        // The asset did not change since: the edit is still uploaded.
        remote.beforeUpload.withLock { $0 = nil }
        remote.state.withLock { $0.uploadError = nil }
        await engine.run(settings)
        #expect(library.lookedAt == [])
        #expect(remote.uploads.count == 3)
        #expect(try await entry("0001", .edited)?.state == BackupItemState.uploaded.rawValue)
        #expect(status.phase == .upToDate)
    }
}

// MARK: - One transaction per batch

/// Counts the transactions that changed the ledger.
final class LedgerCommits: TransactionObserver, Sendable {
    let state = Mutex((changed: false, commits: 0))
    var commits: Int { state.withLock { $0.commits } }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { eventKind.tableName == "backupAsset" }

    func databaseDidChange(with event: DatabaseEvent) { state.withLock { $0.changed = true } }

    func databaseDidCommit(_ db: Database) {
        state.withLock { state in
            if state.changed { state.commits += 1 }
            state.changed = false
        }
    }

    func databaseDidRollback(_ db: Database) { state.withLock { $0.changed = false } }
}

extension BackupEngineTests {
    @Test func matchesAreWrittenOneTransactionPerBatch() async throws {
        let ids = (1...300).map { String(format: "%04d", $0) }
        addPhotos(ids)
        // Everything is on the server already (same second, same size).
        remote.state.withLock { state in
            state.files = library.state.withLock { $0.assets }.enumerated().map { index, asset in
                let resource = asset.resources[0]
                return RemoteCandidate(
                    fileId: Int64(index + 1), path: "/Other/\(resource.originalName)", kind: .image, size: resource.byteSize ?? 0,
                    capturedAt: resource.createdAt, modifiedAt: resource.createdAt)
            }
        }
        await engine.setServerCheckChunk(1000)
        let observer = LedgerCommits()
        await engine.database.writer.add(transactionObserver: observer, extent: .observerLifetime)
        await engine.run(settings)
        #expect(status.matched == 300)
        #expect(remote.uploads.isEmpty)
        // New entries in one, then one per batch of ≤ 200 resources within 7 days (300 photos an hour apart: 2).
        #expect(remote.searches == 2)
        #expect(observer.commits == 3)
    }
}
