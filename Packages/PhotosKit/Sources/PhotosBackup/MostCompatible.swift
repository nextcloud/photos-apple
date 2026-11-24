// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

@preconcurrency import AVFoundation
import Foundation
import OSLog

/// The "Most compatible" format of the backup (SPEC §7.18.2): HEIC/HEIF photos are uploaded as JPEG, HEVC videos as H.264
/// (in a QuickTime file, as the camera's own "Most Compatible" setting records them). RAW files and everything that is
/// already JPEG or H.264 are uploaded as they are.
///
/// How a converted file is found again (SPEC §7.18.4): the ledger records the upload by asset and resource, whatever was
/// uploaded. On the server a converted copy has the original's name with another extension and the capture time as its
/// modification time (`X-OC-MTime`), but not the original's size: the reconciliation finds it by capture second and the
/// number in the name ("Probable") or by its pixel size ("Probable (converted)"), and the check of the destination before
/// an upload (layer 5) takes a file of the same name and capture time for this one (`Uploader.ConflictPolicy
/// .skipIfSameSizeOrTime`), because a conversion does not give the same bytes each time.
enum MostCompatible {
    private static let logger = Logger(subsystem: "com.nextcloud.photos", category: "backup")

    /// Whether the resource may be uploaded in another format than it has.
    static func mayConvert(_ resource: BackupResource, settings: BackupSettings) -> Bool {
        settings.format == .mostCompatible && resource.kind != .raw
    }

    /// The room an export of the resource needs on the device: a video is there twice while it is converted.
    static func spaceNeeded(_ resource: BackupResource, settings: BackupSettings) -> Int64? {
        guard let size = resource.byteSize else { return nil }
        return mayConvert(resource, settings: settings) && resource.mediaKind == .video ? 2 * size : size
    }

    /// The file to upload for an exported resource with "Most compatible": the converted file next to it (the export is
    /// removed then), or the export itself when it needs no conversion. A conversion that fails leaves nothing behind and
    /// the original is uploaded: a photo or video that is backed up in its own format is better than one that is not
    /// backed up. A full device and cancellation are thrown.
    static func convert(_ file: URL, resource: BackupResource) async throws -> URL {
        switch resource.mediaKind {
        case .image:
            return resource.kind == .raw ? file : try PhotoLibrarySource.convertToJPEG(file)
        case .video:
            do {
                return try await convertToH264(file)
            } catch {
                if error is CancellationError || BackupPolicy.isOutOfDeviceSpace(error) { throw error }
                logger.error(
                    "converting a video to H.264 failed, the original is uploaded: \(error.localizedDescription, privacy: .public)")
                return file
            }
        }
    }

    /// Re-encodes an HEVC video as H.264, keeping its metadata (capture date, location, the Live Photo pairing). Returns the
    /// file unchanged when no video track is HEVC. On success the source is removed; on failure the partial output is.
    static func convertToH264(_ file: URL) async throws -> URL {
        let asset = AVURLAsset(url: file)
        guard try await isHEVC(asset) else { return file }
        let target = file.deletingLastPathComponent()
            .appending(path: file.deletingPathExtension().lastPathComponent + "-compatible")
            .appendingPathExtension("mov")
        try? FileManager.default.removeItem(at: target)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.shouldOptimizeForNetworkUse = true
        session.metadata = try await asset.load(.metadata)
        do {
            try await session.export(to: target, as: .mov)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        try? FileManager.default.removeItem(at: file)
        return target
    }

    /// Whether a video track of the asset is HEVC (with or without alpha).
    static func isHEVC(_ asset: AVAsset) async throws -> Bool {
        for track in try await asset.loadTracks(withMediaType: .video) {
            let formats = try await track.load(.formatDescriptions)
            if formats.contains(where: {
                [kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha].contains(CMFormatDescriptionGetMediaSubType($0))
            }) {
                return true
            }
        }
        return false
    }
}
