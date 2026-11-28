// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosBackup

/// How a removal ended.
public struct FreeUpRemoval: Sendable, Equatable {
    /// Moved to Recently Deleted.
    public var removed: Int
    /// What they take on the device.
    public var bytes: Int64
    /// Chosen, but left on the device by the check right before (changed on the device or on the server since).
    public var stayed: Int
    /// The user said no to the system's question.
    public var declined: Bool

    public init(removed: Int, bytes: Int64, stayed: Int, declined: Bool) {
        self.removed = removed
        self.bytes = bytes
        self.stayed = stayed
        self.declined = declined
    }
}

// MARK: - Free up space on this device (SPEC §7.18.8, §22.1)

extension BackupModel {
    /// Free up exists where the backup reads the device's own Photos library and may remove from it: iPhone, iPad and the
    /// Mac. Not on Vision Pro, Apple TV or the Watch.
    public nonisolated static var offersFreeUp: Bool {
        #if os(iOS) || os(macOS)
            true
        #else
            false
        #endif
    }

    /// Free up can run now: backup is set up for an account that is signed in, with access to the whole library (with
    /// access to selected photos only the system would not let the app remove the others, and the counts would mislead).
    public var canFreeUp: Bool {
        Self.offersFreeUp && authorization == .authorized && account != nil
    }

    /// The photos and videos that may be removed from this device, and those that stay with why: each of the offered
    /// ones has every file on the server with the same size, checked now.
    public func freeUpPlan(progress: @escaping @Sendable (FreeUpProgress) -> Void = { _ in }) async throws -> FreeUpPlan {
        guard canFreeUp, let engine = prepareEngine(), let services = backupServices() else { return FreeUpPlan() }
        let ledger = try await engine.ledgerByAsset()
        let settings = settings
        let options = freeUpOptions
        let listing = DAVServerFileListing(api: services.api)
        let plan = try await Task.detached(priority: .userInitiated) {
            try await DeviceCleanup.plan(ledger: ledger, settings: settings, options: options, listing: listing, progress: progress)
        }.value
        // The real check is the better estimate.
        freeUpEstimate = FreeUpEstimate(count: plan.candidates.count, bytes: plan.bytes)
        return plan
    }

    /// Checks the chosen photos against the server once more (sizes, file ids and, where the server keeps them,
    /// checksums of the device's data) and removes those that pass from the device. The system asks the user to
    /// confirm; they go to Recently Deleted.
    public func removeFromDevice(
        _ candidates: [FreeUpCandidate], progress: @escaping @Sendable (FreeUpProgress) -> Void = { _ in }
    ) async throws -> FreeUpRemoval {
        guard canFreeUp, !candidates.isEmpty, let engine = prepareEngine(), let services = backupServices() else {
            return FreeUpRemoval(removed: 0, bytes: 0, stayed: 0, declined: false)
        }
        let ledger = try await engine.ledgerByAsset()
        let settings = settings
        let options = freeUpOptions
        let listing = DAVServerFileListing(api: services.api)
        let checked = try await Task.detached(priority: .userInitiated) {
            try await DeviceCleanup.recheck(
                candidates, ledger: ledger, settings: settings, options: options, listing: listing, progress: progress)
        }.value
        let stayed = candidates.count - checked.candidates.count
        let removed = try await DeviceCleanup.remove(checked.candidates)
        let result = FreeUpRemoval(
            removed: removed, bytes: removed > 0 ? checked.bytes : 0, stayed: stayed, declined: removed == 0 && !checked.candidates.isEmpty)
        await refreshFreeUpEstimate()
        return result
    }

    /// Estimates what free up would offer, from the ledger and the device's library (no server, no file reads), for
    /// the account menu and the Backup screen. Nil where free up is not possible.
    public func refreshFreeUpEstimate() async {
        guard canFreeUp, settings.isEnabled, let engine = prepareEngine(), let ledger = try? await engine.ledgerByAsset() else {
            freeUpEstimate = nil
            return
        }
        let options = freeUpOptions
        freeUpEstimate = await Task.detached(priority: .utility) {
            try? DeviceCleanup.estimate(ledger: ledger, options: options)
        }.value
    }
}
