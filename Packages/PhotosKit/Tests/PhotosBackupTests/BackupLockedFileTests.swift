// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

// Review r3, item 5: a file the server reports as locked (423) fails on its own; the pass goes on.

extension BackupEngineTests {
    @Test func aLockedFileBacksOffAndTheOthersGoOn() async throws {
        addPhotos(["0001", "0002", "0003"])
        remote.state.withLock { $0.uploadErrors["IMG_0001.heic"] = .locked }
        await engine.run(settings)
        #expect(remote.uploads == ["IMG_0002.heic", "IMG_0003.heic"])
        #expect(status.blocker == nil)
        #expect(status.phase == .incomplete(failed: 1))
        #expect(status.lastFailure == NetworkError.locked.localizedDescription)
        #expect(try await entry("0001")?.state == BackupItemState.failed.rawValue)
        #expect(try await entry("0001")?.attempts == 1)

        // The next pass does not start with it again: it waits for its next attempt.
        await engine.run(settings)
        #expect(remote.attempts.filter { $0 == "IMG_0001.heic" }.count == 1)
        #expect(status.phase == .incomplete(failed: 1))

        remote.state.withLock { $0.uploadErrors = [:] }
        clock.advance(BackupPolicy.retryBase + 1)
        await engine.run(settings)
        #expect(try await entry("0001")?.state == BackupItemState.uploaded.rawValue)
        #expect(status.phase == .upToDate)
    }
}

extension BackgroundBackupTests {
    @Test func aLockedFileReportedByTheSystemBacksOffAndTheOthersGoOn() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        addPhotos(["0001", "0002", "0003"])
        let engine = await makeEngine(maxJobs: 1)
        let pass = Task { await engine.run(settings) }
        #expect(await eventually { transport.started.count == 1 })
        await report(engine, "IMG_0001.heic", status: 423)
        #expect(await eventually { transport.started.count == 2 })
        await report(engine, "IMG_0002.heic")
        #expect(await eventually { transport.started.count == 3 })
        await report(engine, "IMG_0003.heic")
        await pass.value
        #expect(status.blocker == nil)
        #expect(status.phase == .incomplete(failed: 1))
        #expect(try await entry(engine, "0001")?.state == BackupItemState.failed.rawValue)
        #expect(try await entry(engine, "0001")?.attempts == 1)
        #expect(try await entry(engine, "0003")?.state == BackupItemState.uploaded.rawValue)
    }
}

@Suite struct BackupFailureRuleTests {
    @Test func onlyFailuresEveryFileWouldMeetEndThePass() {
        #expect(!BackupPolicy.endsPass(.locked))
        #expect(BackupPolicy.endsPass(.offline))
        #expect(BackupPolicy.endsPass(.timedOut))
        #expect(BackupPolicy.endsPass(.maintenance))
        #expect(BackupPolicy.endsPass(.rateLimited))
        #expect(BackupPolicy.endsPass(.http(status: 502, message: nil)))
        #expect(!BackupPolicy.endsPass(.http(status: 415, message: nil)))
        // The outbox still retries a locked file: the shared rule is unchanged.
        #expect(NetworkError.locked.isTransient)
    }
}
