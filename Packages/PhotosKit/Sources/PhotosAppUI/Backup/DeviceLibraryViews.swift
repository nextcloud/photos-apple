// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVKit
import CoreTransferable
import PhotosBackup
import PhotosCore
import PhotosModel
import PhotosStore
import SwiftUI
import UniformTypeIdentifiers

// The device layer in the Library (SPEC §21.1): device photos that are not on the server yet stand in the timeline with
// a badge, open in the viewer, can be shared, deleted from the device and backed up now; the backup summary says how
// many are left.

// MARK: - Timeline

enum DeviceLibraryTimeline {
    /// The Library's query with the device's photos merged in by capture time, off the main actor. The server's first
    /// result is waited for (the Library never shows device photos alone for a moment); device photos that arrive later
    /// are merged into what is shown.
    @MainActor static func merged(_ upstream: @escaping @Sendable () -> GridStream, layer: DeviceLayerModel, kind: MediaFilter)
        -> @Sendable () -> GridStream
    {
        let snapshots = layer.snapshots()
        layer.refresh()
        return {
            let (stream, continuation) = GridStream.makeStream(bufferingPolicy: .bufferingNewest(1))
            let state = DeviceMergeState()
            let server = Task.detached(priority: .userInitiated) {
                do {
                    for try await items in upstream() {
                        try Task.checkCancellation()
                        continuation.yield(await state.server(items))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let device = Task.detached(priority: .userInitiated) {
                for await snapshot in snapshots {
                    if Task.isCancelled { return }
                    if let merged = await state.device(DeviceTimeline.assets(snapshot, kind: kind)) { continuation.yield(merged) }
                }
            }
            continuation.onTermination = { _ in
                server.cancel()
                device.cancel()
            }
            return stream
        }
    }
}

/// The latest rows of both sides of the merge.
private actor DeviceMergeState {
    var server: [GridMedia]?
    var device: [DeviceAsset] = []

    func server(_ items: [GridMedia]) -> [GridMedia] {
        server = items
        return DeviceTimeline.merge(server: items, device: device)
    }

    /// Nil until the server's rows are there, and when nothing changed.
    func device(_ assets: [DeviceAsset]) -> [GridMedia]? {
        guard assets != device else { return nil }
        device = assets
        guard let server else { return nil }
        return DeviceTimeline.merge(server: server, device: assets)
    }
}

// MARK: - Wording

enum DeviceBackupWording {
    static func badgeText(_ badge: DeviceBackupBadge) -> String {
        switch badge {
        case .waiting:
            String(localized: "Not backed up", bundle: .module, comment: "VoiceOver: a photo of this device that is not on the server yet.")
        case .uploading:
            String(localized: "Backing up", bundle: .module, comment: "VoiceOver: a photo of this device that is being uploaded now.")
        case .failed:
            String(
                localized: "Not backed up, upload failed", bundle: .module,
                comment: "VoiceOver: a photo of this device whose upload failed; it is tried again later.")
        case .onlyInICloud:
            String(
                localized: "Only in iCloud, not backed up", bundle: .module,
                comment: "A photo whose original is only in iCloud while downloads from iCloud are off.")
        }
    }

    /// One line about a device photo in the viewer.
    static func status(_ asset: DeviceAsset?, backedUp: Bool) -> String {
        if backedUp {
            return String(localized: "Backed up", bundle: .module, comment: "Viewer: the device photo shown is on the server now.")
        }
        guard let asset else { return "" }
        if asset.badge == .failed, let failure = asset.failure {
            return String(
                localized: "Not backed up: \(failure)", bundle: .module,
                comment: "Viewer: the device photo shown could not be uploaded. The placeholder is the reason.")
        }
        return badgeText(asset.badge)
    }

    static func summary(_ summary: BackupSummary) -> String? {
        switch summary {
        case .off: nil
        case .checking:
            String(
                localized: "Checking backup…", bundle: .module,
                comment: "Account menu: the device's photos are being compared with the backup.")
        case .allBackedUp:
            String(
                localized: "All backed up", bundle: .module,
                comment: "Account menu and Library: every photo of this device is on the server.")
        case .backingUp(let remaining):
            String(
                localized: "Backing up · \(remaining) left", bundle: .module,
                comment: "Account menu and Library: a backup runs; the number of photos and videos not on the server yet.")
        case .notBackedUp(let count, _):
            String(
                localized: "\(count) not backed up", bundle: .module,
                comment: "Account menu and Library: how many photos and videos of this device are not on the server yet.")
        }
    }

    static func symbol(_ summary: BackupSummary) -> String {
        switch summary {
        case .off, .checking: "icloud"
        case .allBackedUp: "checkmark.icloud"
        case .backingUp: "icloud.and.arrow.up"
        case .notBackedUp(_, let failed): failed > 0 ? "exclamationmark.icloud" : "icloud.slash"
        }
    }

    static var backUpNow: String {
        String(localized: "Back Up Now", bundle: .module, comment: "Menu and viewer action: upload the selected device photos first.")
    }

    @MainActor static var deleteFromDevice: String {
        switch DeviceWording.kind {
        case .iPhone:
            String(
                localized: "Delete from This iPhone", bundle: .module,
                comment: "Action on a device photo that is not backed up: removes it from the iPhone's photo library.")
        case .iPad:
            String(
                localized: "Delete from This iPad", bundle: .module,
                comment: "Action on a device photo that is not backed up: removes it from the iPad's photo library.")
        case .mac:
            String(
                localized: "Delete from Photos Library", bundle: .module,
                comment: "Action on a photo of the Mac's Photos library that is not backed up: removes it there.")
        }
    }

    static var showInLibrary: String {
        String(
            localized: "Show in Library", bundle: .module,
            comment: "Backup option: photos of this device that are not backed up appear in the Library.")
    }

    @MainActor static var showInLibraryFooter: String {
        switch DeviceWording.kind {
        case .iPhone:
            String(
                localized: "Photos on this iPhone that are not on your Nextcloud yet appear in the Library with a cloud badge.",
                bundle: .module, comment: "Footer of the backup option Show in Library (iPhone).")
        case .iPad:
            String(
                localized: "Photos on this iPad that are not on your Nextcloud yet appear in the Library with a cloud badge.",
                bundle: .module, comment: "Footer of the backup option Show in Library (iPad).")
        case .mac:
            String(
                localized:
                    "Photos of this Mac's Photos library that are not on your Nextcloud yet appear in the Library with a cloud badge.",
                bundle: .module, comment: "Footer of the backup option Show in Library (Mac).")
        }
    }
}

// MARK: - Grid actions

@MainActor enum DeviceGridActions {
    /// The context menu for a selection with device photos: what can be done with them, then the server photos' actions
    /// (`serverActions`) for the rest. Nil when there is no device photo in it.
    static func menu(
        for ids: [FileID], session: SessionModel, open: @escaping (FileID) -> Void,
        serverActions: ([FileID]) -> [GridMenuAction]
    ) -> [GridMenuAction]? {
        let device = ids.filter(DeviceMediaID.isDevice)
        guard !device.isEmpty else { return nil }
        let backup = session.backup
        let identifiers = backup.deviceLayer.snapshot.localIdentifiers(of: device)
        var actions: [GridMenuAction] = []
        if ids.count == 1, let id = ids.first {
            actions.append(
                GridMenuAction(
                    id: "open", title: String(localized: "Open", bundle: .module), systemImage: "arrow.up.left.and.arrow.down.right"
                ) { _ in open(id) })
        }
        if backup.settings.isEnabled, !identifiers.isEmpty {
            actions.append(
                GridMenuAction(id: "backUpNow", title: DeviceBackupWording.backUpNow, systemImage: "icloud.and.arrow.up") { _ in
                    Task { await backup.backUpNow(identifiers) }
                })
        }
        var share = GridMenuAction(
            id: "shareDevice", title: String(localized: "Share", bundle: .module), systemImage: "square.and.arrow.up", startsGroup: true
        ) { _ in }
        share.share = { DeviceAssetActions.itemProviders(identifiers) }
        actions.append(share)
        let server = ids.filter { !DeviceMediaID.isDevice($0) }
        if !server.isEmpty {
            var rest = serverActions(server).filter { $0.id != "open" }
            if let first = rest.indices.first { rest[first].startsGroup = true }
            actions += rest
        }
        actions.append(
            GridMenuAction(
                id: "deleteDevice", title: DeviceBackupWording.deleteFromDevice, systemImage: "trash", isDestructive: true,
                startsGroup: true
            ) { _ in
                // The system asks for confirmation; the layer follows the photo library's change.
                Task { _ = try? await DeviceAssetActions.delete(identifiers) }
            })
        return actions
    }
}

// MARK: - Viewer

/// A device photo or video as a page of the viewer (SPEC §21.1): PhotoKit's picture, zoomable like the others, or the
/// video. It keeps showing the photo when it has been backed up meanwhile (it then leaves the layer).
struct DeviceViewerPage: View {
    let fileId: FileID
    let isCurrent: Bool
    var command: ViewerZoomCommand?
    var events = ZoomSurfaceEvents()
    @Environment(SessionModel.self) private var session
    @State private var asset: DeviceAsset?

    var body: some View {
        Group {
            if let asset {
                if asset.item.isVideo {
                    DeviceVideoPage(localIdentifier: asset.localIdentifier, isCurrent: isCurrent)
                } else {
                    ZoomablePhoto(item: DeviceTimeline.mediaItem(asset), isCurrent: isCurrent, command: command, events: events)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(label(asset))
                        .accessibilityAddTraits(.isImage)
                }
            } else {
                Color.clear
            }
        }
        .onChange(of: session.backup.deviceLayer.snapshot[fileId], initial: true) { _, current in
            if let current { asset = current }
        }
    }
}

extension DeviceViewerPage {
    /// "Photo, 26 November 2026 at 21:35, Not backed up".
    func label(_ asset: DeviceAsset) -> String {
        let media: String = AccessibilityText.media(
            isVideo: false, isLivePhoto: asset.item.isLivePhoto, date: asset.item.createdAt, duration: nil,
            isFavorite: asset.item.isFavorite)
        return media + ", " + DeviceBackupWording.badgeText(asset.badge)
    }
}

/// A device video, played from PhotoKit.
private struct DeviceVideoPage: View {
    let localIdentifier: String
    let isCurrent: Bool
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
            }
        }
        .task(id: localIdentifier) {
            guard player == nil, let url = await DeviceAssetActions.videoURL(localIdentifier: localIdentifier) else { return }
            player = AVPlayer(url: url)
        }
        .onChange(of: isCurrent) { _, current in
            if !current { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }
}

/// The viewer's controls for a device photo (SPEC §21.1): its backup state, Back Up Now, Share and Delete from the
/// device. The viewer's own controls are about server files and offer nothing for it.
struct DeviceViewerControls: View {
    let fileId: FileID?
    let isHidden: Bool
    /// The photo left the device (deleted): its page goes.
    var removed: (FileID) -> Void
    @Environment(SessionModel.self) private var session
    @State private var shown: DeviceAsset?
    @State private var requested = false

    var body: some View {
        if let fileId, DeviceMediaID.isDevice(fileId), !isHidden {
            let layer = session.backup.deviceLayer
            let current: DeviceAsset? = layer.snapshot[fileId]
            let asset: DeviceAsset? = current ?? (shown?.id == fileId ? shown : nil)
            let backedUp: Bool = current == nil && layer.isLoaded && asset != nil
            bar(asset, backedUp: backedUp)
                .onChange(of: current, initial: true) { _, value in
                    if let value { shown = value }
                }
                .onChange(of: fileId) { _, _ in requested = false }
        }
    }

    func bar(_ asset: DeviceAsset?, backedUp: Bool) -> some View {
        // One line where it fits; with large text the buttons go under the state.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                status(asset, backedUp: backedUp)
                Spacer(minLength: 0)
                buttons(asset, backedUp: backedUp)
            }
            VStack(alignment: .leading, spacing: 10) {
                status(asset, backedUp: backedUp)
                buttons(asset, backedUp: backedUp)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .modifier(DeviceControlsGlass())
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    func status(_ asset: DeviceAsset?, backedUp: Bool) -> some View {
        Label {
            Text(DeviceBackupWording.status(asset, backedUp: backedUp))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: backedUp ? "checkmark.icloud" : (asset?.badge.systemImage ?? "icloud.slash"))
                .symbolEffect(.pulse, options: .repeating, isActive: asset?.badge == .uploading && !backedUp)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Icons with their titles for VoiceOver, Voice Control and the Large Content Viewer.
    @ViewBuilder func buttons(_ asset: DeviceAsset?, backedUp: Bool) -> some View {
        if let asset, !backedUp {
            HStack(spacing: 22) {
                if session.backup.settings.isEnabled, asset.badge != .uploading {
                    Button {
                        requested = true
                        let backup = session.backup
                        Task { await backup.backUpNow([asset.localIdentifier]) }
                    } label: {
                        Label(DeviceBackupWording.backUpNow, systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(requested)
                    .help(DeviceBackupWording.backUpNow)
                }
                ShareLink(item: DeviceShareFile(localIdentifier: asset.localIdentifier, isVideo: asset.item.isVideo), preview: sharePreview)
                {
                    Label(String(localized: "Share", bundle: .module), systemImage: "square.and.arrow.up")
                }
                .help(String(localized: "Share", bundle: .module))
                Button(role: .destructive) {
                    let id = asset.id
                    let identifier = asset.localIdentifier
                    Task {
                        if (try? await DeviceAssetActions.delete([identifier])) ?? 0 > 0 { removed(id) }
                    }
                } label: {
                    Label(DeviceBackupWording.deleteFromDevice, systemImage: "trash")
                }
                .help(DeviceBackupWording.deleteFromDevice)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
        }
    }

    var sharePreview: SharePreview<Never, Never> {
        SharePreview(String(localized: "Photo", bundle: .module, comment: "Title of a shared device photo in the share sheet."))
    }
}

/// Liquid Glass under the controls; the glass background of Vision Pro's windows there.
private struct DeviceControlsGlass: ViewModifier {
    func body(content: Content) -> some View {
        #if os(visionOS)
            content.glassBackgroundEffect(in: .rect(cornerRadius: 26))
        #else
            content.glassEffect(.regular, in: .rect(cornerRadius: 26))
        #endif
    }
}

/// A device photo or video handed to the share sheet as its file, read from PhotoKit when the receiver asks for it.
struct DeviceShareFile: Transferable {
    let localIdentifier: String
    let isVideo: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { file in
            try await file.export()
        }
        .exportingCondition { $0.isVideo }
        FileRepresentation(exportedContentType: .image) { file in
            try await file.export()
        }
        .exportingCondition { !$0.isVideo }
    }

    func export() async throws -> SentTransferredFile {
        guard let provider = DeviceAssetActions.itemProviders([localIdentifier]).first,
            let type = provider.registeredContentTypes.first
        else { throw CocoaError(.fileNoSuchFile) }
        let url: URL = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
                    return
                }
                // The provider's file goes when the handler returns: a copy of our own is shared.
                let copy = FileManager.default.temporaryDirectory.appending(path: "DeviceShared-\(UUID().uuidString)")
                    .appending(path: url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return SentTransferredFile(url)
    }
}

// MARK: - Backup summary

/// The backup summary in the account menu (SPEC §21.1): "All backed up" or "12 not backed up"; opens the Backup screen.
struct BackupSummaryMenuSection: View {
    @Environment(SessionModel.self) private var session
    @Environment(AppModel.self) private var app
    #if os(macOS)
        @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        let backup = session.backup
        let summary = backup.summary
        if let text = DeviceBackupWording.summary(summary), backup.account?.id == session.account.id {
            Section {
                // Everything is on the server and enough can be freed: "All backed up · Free up 3.2 GB" opens free up
                // (SPEC §22.1).
                if case .allBackedUp = summary, let estimate = backup.freeUpEstimate, estimate.isWorthOffering, backup.canFreeUp {
                    Button {
                        backup.freeUpRequested = true
                        BackupSummaryNavigation.openBackup(app: app, openSettings: settingsOpener)
                    } label: {
                        Label(FreeUpWording.summary(bytes: estimate.bytes), systemImage: DeviceBackupWording.symbol(summary))
                    }
                    .accessibilityIdentifier("backup-summary")
                } else {
                    Button {
                        BackupSummaryNavigation.openBackup(app: app, openSettings: settingsOpener)
                    } label: {
                        Label(text, systemImage: DeviceBackupWording.symbol(summary))
                    }
                    .accessibilityIdentifier("backup-summary")
                }
            }
        }
    }

    var settingsOpener: (() -> Void)? {
        #if os(macOS)
            { openSettings() }
        #else
            nil
        #endif
    }
}

/// A small badge on the account button while something is not backed up (SPEC §21.1).
struct BackupSummaryBadge: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        let summary = session.backup.summary
        if summary.hasRemaining, session.backup.account?.id == session.account.id {
            Image(systemName: DeviceBackupWording.symbol(summary))
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.orange))
                .overlay(Circle().stroke(.background, lineWidth: 1.5))
                .offset(x: 5, y: 5)
                .accessibilityHidden(true)
        }
    }
}

/// The Library's toolbar on the Mac (no account button there): the summary while something is not backed up.
struct BackupSummaryToolbarItem: View {
    @Environment(SessionModel.self) private var session
    @Environment(AppModel.self) private var app
    #if os(macOS)
        @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        #if os(macOS)
            let summary = session.backup.summary
            if summary.hasRemaining, let text = DeviceBackupWording.summary(summary), session.backup.account?.id == session.account.id {
                Button {
                    BackupSummaryNavigation.openBackup(app: app, openSettings: { openSettings() })
                } label: {
                    Label(text, systemImage: DeviceBackupWording.symbol(summary))
                }
                .help(text)
                .accessibilityIdentifier("backup-summary")
            }
        #endif
    }
}

@MainActor enum BackupSummaryNavigation {
    /// The Backup screen: Settings › Backup on the Mac, the Backup place elsewhere.
    static func openBackup(app: AppModel, openSettings: (() -> Void)?) {
        #if os(macOS)
            UserDefaults.standard.set(MacSettingsPage.backup.rawValue, forKey: MacSettingsPage.storageKey)
            openSettings?()
        #else
            app.requestedDestination = "backup"
        #endif
    }
}

// MARK: - Info

/// The backup state of a server photo in its info (SPEC §21.1): uploaded from this device, or found there by the backup.
struct BackupInfoRow: View {
    let item: MediaItem
    @Environment(SessionModel.self) private var session
    @State private var origin: BackupOrigin?

    enum BackupOrigin: Equatable {
        case uploaded, matched
    }

    var body: some View {
        Group {
            if let origin {
                LabeledContent {
                    Text(text(origin))
                } label: {
                    Text("Backup", bundle: .module, comment: "Photo info: the row about the backup of this device.")
                }
            }
        }
        .task(id: item.fileId) { origin = await load() }
    }

    func text(_ origin: BackupOrigin) -> String {
        switch (origin, DeviceWording.kind) {
        case (.uploaded, .iPhone):
            String(
                localized: "Backed up from this iPhone", bundle: .module,
                comment: "Photo info: this file was uploaded by this iPhone's backup.")
        case (.uploaded, .iPad):
            String(
                localized: "Backed up from this iPad", bundle: .module, comment: "Photo info: this file was uploaded by this iPad's backup."
            )
        case (.uploaded, .mac):
            String(
                localized: "Backed up from this Mac", bundle: .module, comment: "Photo info: this file was uploaded by this Mac's backup.")
        case (.matched, _):
            String(
                localized: "Backup of a photo on this device", bundle: .module,
                comment: "Photo info: the backup found this file on the server for a photo of this device and did not upload it again.")
        }
    }

    func load() async -> BackupOrigin? {
        let backup = session.backup
        guard backup.settings.isEnabled, backup.account?.id == session.account.id, !DeviceMediaID.isDevice(item.fileId),
            let database = session.services?.database
        else { return nil }
        let fileId = item.fileId
        let path = item.path
        return await Task.detached(priority: .utility) { () -> BackupOrigin? in
            let state: String? = try? database.writer.read { db in
                try String.fetchOne(
                    db, sql: "SELECT state FROM backupAsset WHERE serverFileId = ? OR serverPath = ? LIMIT 1", arguments: [fileId, path])
            }
            switch state {
            case BackupItemState.uploaded.rawValue: return .uploaded
            case BackupItemState.matched.rawValue: return .matched
            default: return nil
            }
        }.value
    }
}
