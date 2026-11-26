// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosBackup
import PhotosModel
import PhotosStore
import Testing

@testable import PhotosAppUI
@testable import PhotosCore

/// The chrome's decisions (SPEC §17.3): what the tab bar's accessory shows, when it ends, and the status symbols.
@Suite struct ChromeMotionTests {
    // MARK: Uploads

    func transfer(_ state: Transfer.State) -> Transfer {
        Transfer(fileName: "IMG.jpg", state: state)
    }

    @Test func uploadsCountOnlyTheRunningBatch() {
        let earlier = transfer(.done(FileID(1)))
        let baseline = ChromeActivities.uploadBaseline([earlier])
        let batch = [earlier, transfer(.done(FileID(2))), transfer(.uploading(0.5)), transfer(.waiting)]
        let activity = ChromeActivities.upload(batch, baseline: baseline)
        #expect(activity?.state == .working)
        #expect(activity?.done == 1)
        #expect(activity?.total == 3)
        #expect(abs((activity?.fraction ?? 0) - 0.5) < 0.0001)
    }

    @Test func noUploadActivityBetweenBatches() {
        let finished = [transfer(.done(FileID(1))), transfer(.failed("x"))]
        #expect(ChromeActivities.upload(finished, baseline: ChromeActivities.uploadBaseline(finished)) == nil)
        #expect(ChromeActivities.upload([], baseline: []) == nil)
    }

    @Test func aFinishedBatchReportsFailures() {
        let ok = ChromeActivities.upload([transfer(.done(FileID(1)))], baseline: [])
        #expect(ok?.state == .done)
        let failed = ChromeActivities.upload([transfer(.done(FileID(1))), transfer(.failed("Offline"))], baseline: [])
        #expect(failed?.state == .failed)
    }

    // MARK: Backup

    func status(_ phase: BackupStatus.Phase, pending: Int = 0) -> BackupStatus {
        var status = BackupStatus()
        status.phase = phase
        status.pending = pending
        return status
    }

    @Test func backupShowsOnlyWhileItUploads() {
        // Looking for new photos at every start would make the accessory flicker.
        #expect(ChromeActivities.backup(status(.scanning), isEnabled: true, wasUploading: false) == nil)
        #expect(ChromeActivities.backup(status(.reconciling(checked: 3, total: 9)), isEnabled: true, wasUploading: false) == nil)
        let uploading = ChromeActivities.backup(status(.uploading(done: 3, total: 12, current: "a")), isEnabled: true, wasUploading: false)
        #expect(uploading?.state == .working)
        #expect(uploading?.done == 3)
        #expect(uploading?.total == 12)
        #expect(ChromeActivities.backup(status(.uploading(done: 3, total: 12, current: "a")), isEnabled: false, wasUploading: true) == nil)
    }

    @Test func backupKeepsShowingBetweenRoundsOfAPass() {
        let between = ChromeActivities.backup(status(.scanning), isEnabled: true, wasUploading: true)
        #expect(between?.state == .working)
    }

    @Test func backupOutcomeAfterAPassThatUploaded() {
        #expect(ChromeActivities.backup(status(.upToDate), isEnabled: true, wasUploading: true)?.state == .done)
        #expect(ChromeActivities.backup(status(.upToDate), isEnabled: true, wasUploading: false) == nil)
        #expect(ChromeActivities.backup(status(.incomplete(failed: 2)), isEnabled: true, wasUploading: true)?.state == .failed)
        #expect(ChromeActivities.backup(status(.idle), isEnabled: true, wasUploading: true)?.state == .done)
        // Paused or waiting for more: no outcome.
        #expect(ChromeActivities.backup(status(.paused("Wi-Fi")), isEnabled: true, wasUploading: true)?.state == .idle)
        #expect(ChromeActivities.backup(status(.idle, pending: 4), isEnabled: true, wasUploading: true)?.state == .idle)
    }

    // MARK: Imports

    @Test func libraryImportWhileRunningAndAfter() {
        var progress = ImportProgress()
        progress.total = 10
        progress.processed = 4
        let running = ChromeActivities.libraryImport(isRunning: true, isFinished: false, progress: progress)
        #expect(running?.state == .working)
        #expect(running?.done == 4)
        progress.phase = .finished
        #expect(ChromeActivities.libraryImport(isRunning: false, isFinished: true, progress: progress)?.state == .done)
        progress.phase = .stopped("Full")
        #expect(ChromeActivities.libraryImport(isRunning: false, isFinished: true, progress: progress)?.state == .failed)
        #expect(ChromeActivities.libraryImport(isRunning: false, isFinished: false, progress: progress) == nil)
    }

    @Test func cardImportNamesItsDevice() {
        var progress = CardImportProgress()
        progress.totalFiles = 8
        progress.processedFiles = 2
        let activity = ChromeActivities.cardImport(progress, device: "EOS R5")
        #expect(activity?.state == .working)
        #expect(activity?.source == "EOS R5")
        progress.phase = .cancelled
        #expect(ChromeActivities.cardImport(progress, device: "EOS R5") == nil)
        #expect(ChromeActivities.cardImport(nil, device: nil) == nil)
    }

    // MARK: What is shown

    @Test func theRunningActivityWithTheHighestPriorityIsShown() {
        let backup = ChromeActivity(kind: .backup, state: .working, done: 1, total: 9)
        let upload = ChromeActivity(kind: .upload, state: .working, done: 1, total: 2)
        let card = ChromeActivity(kind: .cardImport, state: .done)
        #expect(ChromeActivities.shown([backup, upload, card], ended: nil)?.kind == .upload)
        #expect(ChromeActivities.othersRunning([backup, upload, card], shown: upload) == 1)
        // Nothing runs: the one that has just ended, else nothing.
        #expect(ChromeActivities.shown([card], ended: card) == card)
        #expect(ChromeActivities.shown([card], ended: nil) == nil)
    }

    @Test func anActivityEndsWithItsOutcome() {
        let running = ChromeActivity(kind: .upload, state: .working, done: 1, total: 2, fraction: 0.5)
        let failed = ChromeActivity(kind: .upload, state: .failed, done: 2, total: 2, fraction: 1)
        #expect(ChromeActivities.ended(previous: [running], current: [failed]) == failed)
        // Gone without an outcome: done.
        let gone = ChromeActivities.ended(previous: [running], current: [])
        #expect(gone?.state == .done)
        #expect(gone?.done == 2)
        // Still running, or never ran: nothing ended.
        #expect(ChromeActivities.ended(previous: [running], current: [running]) == nil)
        #expect(ChromeActivities.ended(previous: [], current: [failed]) == nil)
        // Paused: no check mark.
        let paused = ChromeActivity(kind: .backup, state: .idle)
        let backup = ChromeActivity(kind: .backup, state: .working, done: 1, total: 4)
        #expect(ChromeActivities.ended(previous: [backup], current: [paused]) == nil)
    }

    @Test func accessoryWording() {
        let activity = ChromeActivity(kind: .cardImport, state: .working, done: 2, total: 8, source: "EOS R5")
        #expect(ChromeActivityWording.title(activity).contains("EOS R5"))
        #expect(ChromeActivityWording.count(activity) != nil)
        // No count once it is done, or while the total is unknown.
        #expect(ChromeActivityWording.count(ChromeActivity(kind: .backup, state: .done, done: 3, total: 3)) == nil)
        #expect(ChromeActivityWording.count(ChromeActivity(kind: .backup, state: .working, done: 3, total: 0)) == nil)
        for kind in ChromeActivity.Kind.allCases {
            for state in [ChromeSymbolState.working, .done, .failed] {
                #expect(!ChromeActivityWording.title(ChromeActivity(kind: kind, state: state)).isEmpty)
            }
            #expect(!ChromeActivityWording.hint(kind).isEmpty)
        }
    }

    // MARK: Symbols

    @MainActor @Test func statusSymbolsEndInACheckMark() {
        for kind in [ChromeStatusSymbol.Kind.upload, .backup, .sync, .importing] {
            #expect(ChromeStatusSymbol.symbolName(kind, .done) == "checkmark.circle.fill")
            #expect(ChromeStatusSymbol.symbolName(kind, .working) == ChromeStatusSymbol.symbolName(kind, .idle))
        }
        #expect(ChromeStatusSymbol.symbolName(.upload, .working) == "icloud.and.arrow.up")
    }

    @Test func backupScreenSymbolIsOneImageForEveryPhase() {
        #expect(BackupStatusSymbol.name(.uploading(done: 1, total: 2, current: "")) == "arrow.triangle.2.circlepath.icloud")
        #expect(BackupStatusSymbol.name(.scanning) == BackupStatusSymbol.name(.reconciling(checked: 1, total: 2)))
        #expect(BackupStatusSymbol.name(.upToDate) == "checkmark.icloud.fill")
        #expect(BackupStatusSymbol.progressValue(.uploading(done: 7, total: 9, current: "")) == 7)
        #expect(BackupStatusSymbol.progressValue(.idle) == 0)
    }

    @Test func syncRowTurnsIntoACheckMark() {
        #expect(SyncStatusRow(.syncing).symbol == .working)
        #expect(SyncStatusRow(.reconciling(itemsChecked: 42)).count == 42)
        #expect(SyncStatusRow(.initialSync(itemsFetched: 7)).count == 7)
        #expect(SyncStatusRow(.idle(lastSync: Date())).symbol == .done)
        #expect(SyncStatusRow(.idle(lastSync: nil)).symbol == .idle)
        #expect(SyncStatusRow(.offline(lastSync: Date())).symbol == .idle)
    }

    @Test func selectionBarButtonsAreNotRepeatedInMore() {
        #expect(SelectionBarLayout.ownButtons == ["delete", "favorite", "album"])
    }
}
