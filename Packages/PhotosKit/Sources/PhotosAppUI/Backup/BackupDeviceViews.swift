// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Observation
import Photos
import PhotosBackup
import PhotosCore
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// The device side of the backup on the Backup screen: photos that are not on the server yet (round-3 item 37) and
/// removing backed-up photos from the device (SPEC §7.18.8, §22.1; iPhone, iPad and the Mac).
struct BackupDeviceSection: View {
    @Environment(SessionModel.self) private var session
    /// Nil while they are counted.
    let notBackedUp: [NotBackedUpAsset]?

    var body: some View {
        let backup = session.backup
        let hasAccess = backup.authorization == .authorized || backup.authorization == .limited
        if hasAccess {
            Section {
                NavigationLink {
                    NotBackedUpView(assets: notBackedUp ?? [])
                } label: {
                    LabeledContent {
                        if let notBackedUp {
                            Text(notBackedUp.count.formatted())
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    } label: {
                        Label(DeviceWording.notBackedUpTitle, systemImage: "icloud.slash")
                    }
                }
                .disabled(notBackedUp == nil)
                if BackupModel.offersFreeUp, backup.authorization == .authorized {
                    // Free up space (SPEC §7.18.8, §22.1), with what it would free when that is known.
                    NavigationLink {
                        FreeUpSpaceView()
                    } label: {
                        LabeledContent {
                            if let estimate = backup.freeUpEstimate, estimate.count > 0 {
                                Text(Formatters.bytes(estimate.bytes))
                            }
                        } label: {
                            Label(DeviceWording.freeUpTitle, systemImage: "arrow.up.trash")
                        }
                    }
                    .accessibilityIdentifier("freeUp.row")
                }
                if backup.settings.isEnabled {
                    // Device photos that are not backed up in the Library (SPEC §21.1).
                    Toggle(
                        DeviceBackupWording.showInLibrary,
                        isOn: Binding(
                            get: { backup.settings.showsDeviceInLibrary },
                            set: { value in backup.update { $0.showsDeviceInLibrary = value } }))
                }
            } header: {
                Text(DeviceWording.sectionTitle)
            } footer: {
                if backup.settings.isEnabled { Text(DeviceBackupWording.showInLibraryFooter) }
            }
        }
    }
}

/// The photos and videos of this device that are not on the server yet, as local thumbnails (PhotoKit).
struct NotBackedUpView: View {
    @Environment(SessionModel.self) private var session
    let assets: [NotBackedUpAsset]
    @ScaledMetric(relativeTo: .body) private var tileSize = 96.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !assets.isEmpty {
                    Text(DeviceWording.notBackedUpSummary(assets.count))
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize), spacing: 2)], spacing: 2) {
                    ForEach(assets) { asset in
                        LocalAssetThumbnail(localIdentifier: asset.localIdentifier)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(alignment: .bottomTrailing) { badge(asset.reason) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(Self.reasonText(asset.reason)))
                    }
                }
            }
            .padding(.vertical)
        }
        .overlay {
            if assets.isEmpty {
                ContentUnavailableView(
                    DeviceWording.everythingBackedUp, systemImage: "checkmark.icloud",
                    description: Text(
                        "Every photo and video that backup covers is on your Nextcloud.", bundle: .module,
                        comment: "Empty state of the list of photos that are not backed up yet."))
            }
        }
        .navigationTitle(DeviceWording.notBackedUpTitle)
        .toolbar {
            if session.backup.settings.isEnabled && !assets.isEmpty {
                Button(String(localized: "Back up now", bundle: .module)) {
                    let backup = session.backup
                    Task { await backup.startBackup(retryFailed: true) }
                }
            }
        }
    }

    @ViewBuilder func badge(_ reason: NotBackedUpAsset.Reason) -> some View {
        let symbol: String? =
            switch reason {
            case .waiting: nil
            case .failed: "exclamationmark.triangle.fill"
            case .onlyInICloud: "icloud.and.arrow.down"
            }
        if let symbol {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(4)
                .background(.black.opacity(0.55), in: .circle)
                .padding(4)
        }
    }

    static func reasonText(_ reason: NotBackedUpAsset.Reason) -> String {
        switch reason {
        case .waiting:
            String(localized: "Waiting to be backed up", bundle: .module, comment: "VoiceOver label of a photo that is not backed up yet.")
        case .failed(let message):
            message.map {
                String(
                    localized: "Upload failed: \($0)", bundle: .module,
                    comment: "VoiceOver label of a photo whose upload failed. The placeholder is the reason.")
            } ?? String(localized: "Upload failed", bundle: .module, comment: "VoiceOver label of a photo whose upload failed.")
        case .onlyInICloud:
            String(
                localized: "Only in iCloud, not backed up", bundle: .module)
        }
    }
}

/// A thumbnail of a photo of this device, from PhotoKit. Nothing is downloaded from iCloud.
struct LocalAssetThumbnail: View {
    let localIdentifier: String
    @State private var image: Image?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    image.resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: localIdentifier) {
                image = await Self.load(localIdentifier, side: 160 * displayScale)
            }
    }

    static func load(_ localIdentifier: String, side: CGFloat) async -> Image? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        // One answer: the best image that is on the device.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: options
            ) { image, _ in
                #if canImport(UIKit)
                    continuation.resume(returning: image.map { Image(uiImage: $0) })
                #else
                    continuation.resume(returning: image.map { Image(nsImage: $0) })
                #endif
            }
        }
    }
}

/// Texts that name this device (on the main actor: they ask UIDevice, which is the main actor's).
@MainActor enum DeviceWording {
    enum Kind { case iPhone, iPad, mac }

    static var kind: Kind {
        #if os(macOS)
            .mac
        #else
            UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #endif
    }

    static var sectionTitle: String {
        switch kind {
        case .iPhone:
            String(
                localized: "On this iPhone", bundle: .module,
                comment: "Header of the Backup screen's section about the device's own photos.")
        case .iPad:
            String(
                localized: "On this iPad", bundle: .module,
                comment: "Header of the Backup screen's section about the device's own photos.")
        case .mac:
            String(
                localized: "On this Mac", bundle: .module,
                comment: "Header of the Backup screen's section about the Mac's Photos library.")
        }
    }

    static var notBackedUpTitle: String {
        String(
            localized: "Not backed up yet", bundle: .module,
            comment: "Row and screen title: the device's photos that are not on the server yet.")
    }

    static var everythingBackedUp: String {
        String(
            localized: "Everything is backed up", bundle: .module,
            comment: "Title of the empty list of photos that are not backed up yet.")
    }

    static func notBackedUpSummary(_ count: Int) -> String {
        switch kind {
        case .iPhone:
            String(
                localized: "\(count) photos and videos on this iPhone are not on your Nextcloud yet.", bundle: .module,
                comment: "Above the list of photos that are not backed up yet (iPhone).")
        case .iPad:
            String(
                localized: "\(count) photos and videos on this iPad are not on your Nextcloud yet.", bundle: .module,
                comment: "Above the list of photos that are not backed up yet (iPad).")
        case .mac:
            String(
                localized: "\(count) photos and videos in the Photos library of this Mac are not on your Nextcloud yet.", bundle: .module,
                comment: "Above the list of photos that are not backed up yet (macOS).")
        }
    }

    // Free up space (SPEC §7.18.8, §22.1): iPhone, iPad and the Mac.

    static var freeUpTitle: String {
        switch kind {
        case .iPhone:
            String(
                localized: "Free up space on this iPhone", bundle: .module,
                comment: "Row and screen title: remove backed-up photos from the iPhone.")
        case .iPad:
            String(
                localized: "Free up space on this iPad", bundle: .module,
                comment: "Row and screen title: remove backed-up photos from the iPad.")
        case .mac:
            String(
                localized: "Free up space on this Mac", bundle: .module,
                comment: "Row and screen title: remove backed-up photos from the Photos library of the Mac.")
        }
    }

    static var removeButton: String {
        switch kind {
        case .iPhone:
            String(
                localized: "Remove from this iPhone", bundle: .module,
                comment: "Free up space: button that removes the backed-up photos from the iPhone.")
        case .iPad:
            String(
                localized: "Remove from this iPad", bundle: .module,
                comment: "Free up space: button that removes the backed-up photos from the iPad.")
        case .mac:
            String(
                localized: "Remove from this Mac", bundle: .module,
                comment: "Free up space: button that removes the backed-up photos from the Photos library of the Mac.")
        }
    }

    static func confirmTitle(_ count: Int) -> String {
        switch kind {
        case .iPhone:
            String(
                localized: "Remove \(count) photos and videos from this iPhone?", bundle: .module,
                comment: "Free up space: confirmation title (iPhone). The placeholder is the number of items.")
        case .iPad:
            String(
                localized: "Remove \(count) photos and videos from this iPad?", bundle: .module,
                comment: "Free up space: confirmation title (iPad). The placeholder is the number of items.")
        case .mac:
            String(
                localized: "Remove \(count) photos and videos from this Mac?", bundle: .module,
                comment: "Free up space: confirmation title (Mac). The placeholder is the number of items.")
        }
    }
}
