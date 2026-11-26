// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import GRDB
import OSLog
import Photos
import PhotosModel
import PhotosNetworking
import PhotosStore

extension BackupEngine {
    // MARK: Rounds

    /// How a pass's work went.
    enum Outcome {
        /// Something stops the pass until conditions change (Wi-Fi, Low Power Mode…).
        case stopped(Waiting)
        /// Through. `held`: videos or iCloud originals wait for Wi-Fi. `toUpload`: there was something to upload (a
        /// dry run does not upload it).
        case done(held: Waiting?, toUpload: Bool)
    }

    func setServerCheckChunk(_ size: Int) { serverCheckChunk = size }

    /// Checks the work against the server and uploads it, in rounds: what needs no check goes first, then a chunk at a
    /// time is checked and uploaded, so the uploads start after one request, and an interrupted pass leaves every
    /// checked resource checked (`BackupLedgerEntry.checkedAt`).
    ///
    /// Larger files than the system takes are kept for the end of the pass, as within a round (`BackupPolicy.uploadOrder`).
    func process(_ work: Work, settings: BackupSettings, dryRun: Bool, held: Waiting? = nil) async throws -> Outcome {
        var ready = work.ready
        var unchecked = work.unchecked[...]
        var held = held
        var toUpload = false
        var large: [BackupResource] = []
        let total = unchecked.count
        var checked = 0
        repeat {
            try Task.checkCancellation()
            let chunk = dryRun ? unchecked : unchecked.prefix(serverCheckChunk)
            unchecked = unchecked.dropFirst(chunk.count)
            let notOnServer = try await reconcile(Array(chunk), checkedBefore: checked, total: total)
            checked += chunk.count
            let round = (ready + notOnServer).sorted(by: BackupPolicy.isOlder)
            ready = []
            toUpload = toUpload || !round.isEmpty
            if dryRun { continue }
            let order = BackupPolicy.uploadOrder(round, backgroundLimit: background?.maxFileSize)
            large += order.last
            let isLast = unchecked.isEmpty
            let batch = isLast ? order.first + large : order.first
            // The last round waits for what the system still uploads for this pass.
            guard !batch.isEmpty || (isLast && cleanedUp && activeBackgroundUploads > 0) else { continue }
            if !cleanedUp {
                cleanedUp = true
                await remote.removeStaleUploads()
            }
            passUploads.later = isLast ? 0 : unchecked.count
            guard let waiting = try await upload(batch, settings: settings, drain: isLast) else { continue }
            // Videos and iCloud originals that wait for Wi-Fi do not stop the others.
            guard waiting.videosOnly || waiting.reason == .iCloud else { return .stopped(waiting) }
            held = Self.merge(held, waiting)
        } while !unchecked.isEmpty
        return .done(held: held, toUpload: toUpload)
    }

    static func merge(_ a: Waiting?, _ b: Waiting) -> Waiting {
        guard let a else { return b }
        let needsICloud = a.needsICloud || b.needsICloud
        if a.videosOnly { return Waiting(reason: a.reason, videosOnly: true, needsICloud: needsICloud) }
        if b.videosOnly { return Waiting(reason: b.reason, videosOnly: true, needsICloud: needsICloud) }
        return Waiting(reason: .iCloud, needsICloud: needsICloud)
    }

    // MARK: Reconciliation (SPEC §7.18.4 layer 4)

    /// Returns the resources that are not on the server yet; records the matched ones, and when the server was asked
    /// about the others, one transaction per batch.
    func reconcile(_ work: [BackupResource], checkedBefore: Int = 0, total: Int? = nil) async throws -> [BackupResource] {
        // Batches of ≤ 200 resources spanning ≤ 7 days, so each SEARCH stays small.
        var batches: [[BackupResource]] = []
        for resource in work {
            if let first = batches.last?.first, batches[batches.count - 1].count < 200,
                resource.createdAt.timeIntervalSince(first.createdAt) <= 7 * 86_400
            {
                batches[batches.count - 1].append(resource)
            } else {
                batches.append([resource])
            }
        }
        var remaining: [BackupResource] = []
        var checked = checkedBefore
        for batch in batches {
            try Task.checkCancellation()
            guard let first = batch.first?.createdAt, let last = batch.last?.createdAt else { continue }
            let candidates = try await remote.candidates(from: first.addingTimeInterval(-2), to: last.addingTimeInterval(2))
            var index = BackupMatcher.Index(candidates: candidates, locals: batch.map(\.local))
            var matches: [Match] = []
            var notFound: [BackupResource] = []
            for resource in batch {
                // The system reported this upload while the server was asked: it is recorded, and the file the server
                // just listed is that very upload.
                if settled.contains(LedgerKey(resource)) { continue }
                if let (candidate, reason) = index.match(resource.local) {
                    matches.append(Match(resource: resource, candidate: candidate, reason: reason))
                } else {
                    notFound.append(resource)
                }
            }
            try recordCheck(matches: matches, notFound: notFound)
            remaining += notFound
            checked += batch.count
            publish(.reconciling(checked: checked, total: total ?? work.count))
        }
        return remaining
    }

    /// A resource the reconciliation found on the server.
    struct Match {
        var resource: BackupResource
        var candidate: RemoteCandidate
        var reason: MatchReason
    }
}
