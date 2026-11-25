// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import ImageIO
import OSLog
import Observation
import PhotosBackup
import PhotosModel
import SwiftUI
import Synchronization

#if os(macOS) || os(iOS)
    import ImageCaptureCore
#endif
#if os(macOS)
    import AppKit
#endif

/// A camera, memory card or folder to import from (SPEC §15.2).
@MainActor
protocol CardDevice: AnyObject {
    var id: String { get }
    var name: String { get }
    var symbol: String { get }
    /// The files are being listed (or their dates read).
    var isLoading: Bool { get }
    var items: [CardItem] { get }
    var problem: String? { get }
    var canEject: Bool { get }
    var canDelete: Bool { get }
    var source: any CardImportSource { get }
    func load()
    func thumbnail(for item: CardItem, maxPixels: Int) async -> CGImage?
    func eject() async throws
    /// Stops using the device (the sheet closed and no import runs).
    func close()
}

// MARK: - Folders: mounted cards (Mac) and folders chosen in Files (iPad)

/// A folder read in place: the DCIM folder of a mounted card, or one the user chose (an external drive in Files).
@MainActor
@Observable
final class FolderCardDevice: CardDevice {
    let id: String
    let name: String
    let symbol: String
    let root: URL
    /// The volume to eject (a mounted card); nil for a folder.
    let volume: URL?
    /// A folder from the document picker: access must be started and stopped.
    let isSecurityScoped: Bool
    private(set) var isLoading = false
    private(set) var items: [CardItem] = []
    private(set) var problem: String?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var accessing = false

    init(root: URL, name: String, volume: URL?, isSecurityScoped: Bool) {
        self.root = root
        self.name = name
        self.volume = volume
        self.isSecurityScoped = isSecurityScoped
        id = "folder:" + root.standardizedFileURL.path
        symbol = volume != nil ? "sdcard" : "folder"
    }

    var canEject: Bool { volume != nil }
    var canDelete: Bool { FileManager.default.isDeletableFile(atPath: root.path) }
    var source: any CardImportSource { FolderCardSource(root: root, isSecurityScoped: isSecurityScoped) }

    func load() {
        guard loading == nil else { return }
        if isSecurityScoped, !accessing { accessing = root.startAccessingSecurityScopedResource() }
        isLoading = true
        let root = root
        loading = Task { [weak self] in
            let (listed, denied) = await Task.detached(priority: .userInitiated) { FolderCardSource.list(root) }.value
            CardDeviceBrowser.logger.info("card import: \(listed.count) files in a folder")
            self?.items = listed
            self?.isLoading = false
            if denied && listed.isEmpty {
                self?.problem = CardImportPermission.deniedMessage
            } else if listed.isEmpty {
                self?.problem = String(
                    localized: "There are no photos or videos in this folder.", bundle: .module,
                    comment: "Import from a card or folder: nothing to import.")
            }
        }
    }

    func thumbnail(for item: CardItem, maxPixels: Int) async -> CGImage? {
        let url = root.appending(path: item.id)
        return await Task.detached(priority: .utility) { await CardThumbnails.thumbnail(of: url, kind: item.kind, maxPixels: maxPixels) }
            .value
    }

    func eject() async throws {
        #if os(macOS)
            guard let volume else { return }
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
        #endif
    }

    func close() {
        loading?.cancel()
        if accessing { root.stopAccessingSecurityScopedResource() }
        accessing = false
    }
}

/// Reads a folder's media files in place.
struct FolderCardSource: CardImportSource {
    let root: URL
    let isSecurityScoped: Bool

    /// The media files below `root` (camera folders, at most 6 levels deep), with the capture time from their EXIF data.
    /// Ids are the paths relative to `root`.
    static func list(_ root: URL) -> (items: [CardItem], denied: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        let denied = Mutex(false)
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, error in
                    CardDeviceBrowser.logger.error("card import: cannot read a folder: \(error.localizedDescription, privacy: .public)")
                    if (error as NSError).code == CocoaError.fileReadNoPermission.rawValue { denied.withLock { $0 = true } }
                    return true
                })
        else { return ([], false) }
        let base = root.standardizedFileURL.path
        var items: [CardItem] = []
        for case let url as URL in enumerator {
            if enumerator.level > 6 {
                enumerator.skipDescendants()
                continue
            }
            guard CardItem.isMedia(name: url.lastPathComponent),
                let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            let relative: String =
                path.hasPrefix(base) ? String(String(path.dropFirst(base.count)).trimmingPrefix("/")) : url.lastPathComponent
            let kind = CardItem.kind(ofName: url.lastPathComponent)
            let fileDate = values.contentModificationDate ?? values.creationDate
            let captured = kind == .image ? (CardThumbnails.captureDate(of: url) ?? fileDate) : fileDate
            items.append(
                CardItem(
                    id: String(relative), name: url.lastPathComponent, folder: (String(relative) as NSString).deletingLastPathComponent,
                    size: Int64(values.fileSize ?? 0), capturedAt: captured, kind: kind))
        }
        return (items, denied.withLock { $0 })
    }

    func localFile(for item: CardItem, in temporary: URL) async throws -> (url: URL, isTemporary: Bool) {
        (root.appending(path: item.id), false)
    }

    func delete(_ items: [CardItem]) async throws {
        let accessing = isSecurityScoped && root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        var firstError: (any Error)?
        for item in items {
            do {
                try FileManager.default.removeItem(at: root.appending(path: item.id))
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }
}

/// macOS asks before an app reads a memory card (Privacy & Security › Files and Folders › Removable Volumes).
enum CardImportPermission {
    static var deniedMessage: String {
        #if os(macOS)
            String(
                localized:
                    "Nextcloud Photos is not allowed to read memory cards. Allow it in System Settings › Privacy & Security › Files and Folders, then open the import again.",
                bundle: .module, comment: "Import (Mac): reading the card was refused by the system's privacy settings.")
        #else
            String(
                localized: "Nextcloud Photos is not allowed to read this folder. Choose it again in Files.", bundle: .module,
                comment: "Import (iPad): reading the chosen folder was refused.")
        #endif
    }

    #if os(macOS)
        /// System Settings at Files and Folders.
        static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
    #endif
}

/// Thumbnails and capture dates of card files, read with Image I/O (the embedded EXIF thumbnail where there is one:
/// fast even for RAW files) and AVFoundation.
enum CardThumbnails {
    nonisolated static func thumbnail(of url: URL, kind: MediaKind, maxPixels: Int) async -> CGImage? {
        if kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            return try? await generator.image(at: .zero).image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// EXIF `DateTimeOriginal` in this device's time zone (cameras write local time without an offset).
    nonisolated static func captureDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let text = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String else {
            return nil
        }
        return exifDate(text)
    }

    nonisolated static func exifDate(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: String(text.prefix(19)))
    }
}

// MARK: - Cameras (ImageCaptureCore)

#if os(macOS) || os(iOS)
    /// A camera connected by USB (or a card ImageCaptureCore offers that is not mounted as a volume).
    @MainActor
    @Observable
    final class CameraCardDevice: NSObject, CardDevice, ICCameraDeviceDelegate {
        let camera: ICCameraDevice
        let id: String
        private(set) var name: String
        private(set) var isLoading = true
        private(set) var items: [CardItem] = []
        private(set) var problem: String?
        @ObservationIgnored private(set) var files: [String: ICCameraFile] = [:]
        @ObservationIgnored private var sessionOpen = false

        init(camera: ICCameraDevice) {
            self.camera = camera
            id = "camera:" + (camera.uuidString ?? UUID().uuidString)
            name = camera.name ?? String(localized: "Camera", bundle: .module, comment: "Import: a camera without a name.")
            super.init()
        }

        var symbol: String { mountPoint != nil ? "sdcard" : "camera" }

        /// Where the camera's card is mounted as a volume (Mac); nil for a camera.
        var mountPoint: String? {
            #if os(macOS)
                camera.mountPoint
            #else
                nil
            #endif
        }
        var canEject: Bool { camera.isEjectable }
        var canDelete: Bool { camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue) && !camera.isLocked }
        var source: any CardImportSource { CameraCardSource(device: self) }

        func load() {
            guard !sessionOpen else { return }
            camera.delegate = self
            camera.requestOpenSession()
        }

        func close() {
            if sessionOpen { camera.requestCloseSession() }
            sessionOpen = false
        }

        /// The files of the camera as card items; ids are the camera's object handles (stable while it is connected).
        func catalog() {
            var map: [String: ICCameraFile] = [:]
            var list: [CardItem] = []
            for case let file as ICCameraFile in camera.mediaFiles ?? [] {
                guard let name = file.name, CardItem.isMedia(name: name) else { continue }
                let id = "\(file.ptpObjectHandle)-\(name)"
                map[id] = file
                list.append(
                    CardItem(
                        id: id, name: name, folder: file.parentFolder?.name ?? "", size: Int64(file.fileSize),
                        capturedAt: file.exifCreationDate ?? file.creationDate ?? file.fileCreationDate,
                        kind: CardItem.kind(ofName: name)))
            }
            files = map
            items = list
            isLoading = false
            if list.isEmpty {
                problem = String(
                    localized: "There are no photos or videos on this camera.", bundle: .module,
                    comment: "Import from a camera: nothing to import.")
            }
        }

        func thumbnail(for item: CardItem, maxPixels: Int) async -> CGImage? {
            guard let file = files[item.id] else { return nil }
            let data: Data? = await withCheckedContinuation { continuation in
                file.requestThumbnailData(options: [ICCameraItemThumbnailOption.imageSourceThumbnailMaxPixelSize: maxPixels]) {
                    data, _ in
                    continuation.resume(returning: data)
                }
            }
            guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }

        func eject() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                camera.requestEject { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }

        // MARK: ICCameraDeviceDelegate (called on the main thread)

        nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
            let message = error?.localizedDescription
            MainActor.assumeIsolated {
                sessionOpen = message == nil
                if let message {
                    problem = message
                    isLoading = false
                }
            }
        }

        nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
            MainActor.assumeIsolated { catalog() }
        }

        nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
            MainActor.assumeIsolated { if !isLoading { catalog() } }
        }

        nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
            MainActor.assumeIsolated { if !isLoading { catalog() } }
        }

        nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
            MainActor.assumeIsolated { sessionOpen = false }
        }

        nonisolated func didRemove(_ device: ICDevice) {}
        nonisolated func deviceDidBecomeReady(_ device: ICDevice) {}
        nonisolated func device(_ device: ICDevice, didEncounterError error: (any Error)?) {}
        nonisolated func cameraDevice(
            _ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?
        ) {}
        nonisolated func cameraDevice(
            _ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?
        ) {}
        nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
        nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
        nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
        nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
        nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    }

    /// Downloads each file from the camera before it is uploaded; deletes with the camera's own delete.
    struct CameraCardSource: CardImportSource {
        let device: CameraCardDevice

        func localFile(for item: CardItem, in temporary: URL) async throws -> (url: URL, isTemporary: Bool) {
            let name = try await MainActor.run { () -> String in
                guard device.files[item.id] != nil else { throw CocoaError(.fileNoSuchFile) }
                return UUID().uuidString + "-" + item.name
            }
            try await download(item, to: temporary, as: name)
            return (temporary.appending(path: name), true)
        }

        @MainActor
        private func download(_ item: CardItem, to folder: URL, as name: String) async throws {
            guard let file = device.files[item.id] else { throw CocoaError(.fileNoSuchFile) }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                _ = file.requestDownload(
                    options: [.downloadsDirectoryURL: folder, .saveAsFilename: name, .overwrite: true]
                ) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }

        func delete(_ items: [CardItem]) async throws {
            try await deleteOnCamera(items)
        }

        @MainActor
        private func deleteOnCamera(_ items: [CardItem]) async throws {
            let files = items.compactMap { device.files[$0.id] }
            guard !files.isEmpty else { return }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                _ = device.camera.requestDeleteFiles(files, deleteFailed: { _ in }) { result, error in
                    let failed = result[.failed]?.count ?? 0
                    if let error {
                        continuation.resume(throwing: error)
                    } else if failed > 0 {
                        continuation.resume(throwing: CocoaError(.fileWriteNoPermission))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
#endif

// MARK: - Browser

/// The cameras, cards and folders to import from, kept up to date while the import sheet is open (SPEC §15.2).
@MainActor
@Observable
final class CardDeviceBrowser: NSObject {
    nonisolated static let logger = Logger(subsystem: "com.nextcloud.photos", category: "card-import")
    private(set) var devices: [any CardDevice] = []
    @ObservationIgnored private var cameras: [String: any CardDevice] = [:]
    @ObservationIgnored private var volumes: [String: any CardDevice] = [:]
    @ObservationIgnored private var folders: [any CardDevice] = []
    @ObservationIgnored private var started = false
    #if os(macOS) || os(iOS)
        @ObservationIgnored private let browser = ICDeviceBrowser()
    #endif
    #if os(macOS)
        @ObservationIgnored private var mountObservers: [any NSObjectProtocol] = []
    #endif

    func start() {
        guard !started else { return }
        started = true
        #if os(macOS) || os(iOS)
            browser.delegate = self
            browser.browsedDeviceTypeMask =
                ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue) ?? .camera
            browser.start()
        #endif
        #if os(macOS)
            scanVolumes()
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
                mountObservers.append(
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scanVolumes() }
                    })
            }
        #endif
    }

    func stop() {
        guard started else { return }
        started = false
        #if os(macOS) || os(iOS)
            browser.stop()
        #endif
        #if os(macOS)
            for observer in mountObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            mountObservers = []
        #endif
        for device in devices { device.close() }
    }

    /// A folder chosen in the file picker (iPad: an external drive or card reader in Files; Mac: any folder).
    @discardableResult
    func addFolder(_ url: URL) -> any CardDevice {
        let device = FolderCardDevice(root: url, name: url.lastPathComponent, volume: nil, isSecurityScoped: true)
        folders.removeAll { $0.id == device.id }
        folders.append(device)
        publish()
        return device
    }

    private func publish() {
        let mounted = Set(volumes.keys)
        // A card ImageCaptureCore also offers as a camera is read as the mounted volume: in place, faster.
        let cameraList = cameras.values.filter { device in
            #if os(macOS) || os(iOS)
                if let camera = device as? CameraCardDevice, let mount = camera.mountPoint {
                    return !mounted.contains(URL(filePath: mount).standardizedFileURL.path)
                }
            #endif
            return true
        }
        devices =
            cameraList.sorted { $0.name < $1.name } + volumes.values.sorted { $0.name < $1.name } + folders
    }

    #if os(macOS)
        /// Removable volumes with a DCIM folder (memory cards in a reader, cameras that mount as a disk).
        func scanVolumes() {
            let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeLocalizedNameKey]
            let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
            var found: [String: any CardDevice] = [:]
            for volume in mounted {
                let dcim = volume.appending(path: "DCIM")
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dcim.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                // The sandbox may not let the app read the card (no folder chosen): then ImageCaptureCore offers it.
                guard (try? FileManager.default.contentsOfDirectory(atPath: dcim.path)) != nil else { continue }
                let key = volume.standardizedFileURL.path
                if let existing = volumes[key] {
                    found[key] = existing
                } else {
                    let name =
                        (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? volume.lastPathComponent
                    found[key] = FolderCardDevice(root: dcim, name: name, volume: volume, isSecurityScoped: false)
                }
            }
            for (key, device) in volumes where found[key] == nil { device.close() }
            volumes = found
            publish()
        }
    #endif
}

#if os(macOS) || os(iOS)
    extension CardDeviceBrowser: @MainActor ICDeviceBrowserDelegate {
        // ImageCaptureCore calls its delegates on the main thread: an isolated conformance.
        func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
            guard let camera = device as? ICCameraDevice else { return }
            let wrapped = CameraCardDevice(camera: camera)
            cameras[wrapped.id] = wrapped
            publish()
        }

        func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
            guard let camera = device as? ICCameraDevice else { return }
            let gone = cameras.filter { ($0.value as? CameraCardDevice)?.camera === camera }.map(\.key)
            for key in gone { cameras[key] = nil }
            publish()
        }
    }
#endif
