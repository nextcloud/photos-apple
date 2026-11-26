// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreTransferable
import ImageIO
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A file received from the Photos picker, copied to a temporary location.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let directory = FileManager.default.temporaryDirectory.appending(path: "Uploads/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedFile(url: target)
        }
    }
}

enum CaptureDate {
    /// EXIF `DateTimeOriginal` (local time with optional `OffsetTimeOriginal`) of an image file.
    static func read(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String, let seconds = CaptureTime.parseOffset(offset) {
            formatter.timeZone = TimeZone(secondsFromGMT: seconds)
        }
        return formatter.date(from: value)
    }
}

/// Where an upload starts from (SPEC §7.17). The menu items are in the account menu and the Collections tab's "+"
/// (iPhone, iPad, Vision Pro; SPEC §19.2); the Mac has File ▸ Upload Photos… and drag and drop.
enum UploadStart: String, Identifiable {
    case photos, files
    #if os(iOS)
        /// With the device's own camera, into the same place (SPEC §16.5.3).
        case camera, scan
    #endif

    var id: String { rawValue }

    static var menuTitle: String { String(localized: "Upload", bundle: .module) }

    /// Not an arrow out of a box: that is "Share" on Apple platforms.
    static let systemImage = "icloud.and.arrow.up"
}

/// The upload menu's items: from the Photos library, from files, and on iPhone and iPad from the camera or scanner.
struct UploadMenuItems: View {
    var start: (UploadStart) -> Void

    var body: some View {
        Button {
            start(.photos)
        } label: {
            Label(String(localized: "Upload from Photos", bundle: .module), systemImage: "photo.on.rectangle")
        }
        Button {
            start(.files)
        } label: {
            Label(String(localized: "Upload files…", bundle: .module), systemImage: "folder")
        }
        #if os(iOS)
            if DeviceCapture.canTakePhoto || DeviceCapture.canScan {
                Divider()
            }
            if DeviceCapture.canTakePhoto {
                Button {
                    start(.camera)
                } label: {
                    Label(DeviceCapture.takePhotoTitle, systemImage: "camera")
                }
            }
            if DeviceCapture.canScan {
                Button {
                    start(.scan)
                } label: {
                    Label(DeviceCapture.scanTitle, systemImage: "doc.viewfinder")
                }
            }
        #endif
    }
}

extension View {
    /// The pickers of an upload chosen in `UploadMenuItems`. On the view that holds the menu, not inside it: a menu's
    /// items are gone once it closes, and with them anything they would present.
    func uploadPresenter(_ start: Binding<UploadStart?>, album: Album? = nil) -> some View {
        modifier(UploadPresenter(start: start, album: album))
    }
}

/// Presents the Photos picker, the file importer, the camera or the scanner and uploads what was chosen.
private struct UploadPresenter: ViewModifier {
    @Binding var start: UploadStart?
    var album: Album?
    @Environment(SessionModel.self) private var session
    @State private var pickerItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: isPresented(.photos), selection: $pickerItems, matching: .any(of: [.images, .videos]),
                preferredItemEncoding: .current
            )
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                pickerItems = []
                Task {
                    var sources: [UploadSource] = []
                    for item in items {
                        if let picked = try? await item.loadTransferable(type: PickedFile.self) {
                            sources.append(UploadSource(file: picked.url, capturedAt: CaptureDate.read(picked.url)))
                        }
                    }
                    session.transfers.upload(sources, album: album)
                }
            }
            .fileImporter(isPresented: isPresented(.files), allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) {
                result in
                guard case .success(let urls) = result else { return }
                session.transfers.upload(UploadSources.copies(of: urls), album: album)
            }
            #if os(iOS)
                .fullScreenCover(item: capture) { (kind: UploadStart) in
                    switch kind {
                    case .camera:
                        CameraPicker { source in
                            start = nil
                            if let source { session.transfers.upload([source], album: album) }
                        }
                        .ignoresSafeArea()
                    default:
                        DocumentScanner { sources in
                            start = nil
                            if !sources.isEmpty { session.transfers.upload(sources, album: album) }
                        }
                        .ignoresSafeArea()
                    }
                }
            #endif
    }

    func isPresented(_ kind: UploadStart) -> Binding<Bool> {
        Binding<Bool>(
            get: { () -> Bool in start == kind },
            set: { (shown: Bool) in if !shown, start == kind { start = nil } })
    }

    #if os(iOS)
        /// The camera and the scanner are full-screen covers.
        var capture: Binding<UploadStart?> {
            Binding<UploadStart?>(
                get: { () -> UploadStart? in start == .camera || start == .scan ? start : nil },
                set: { (value: UploadStart?) in if value == nil, start == .camera || start == .scan { start = nil } })
        }
    #endif
}

/// What the toolbar shows of the uploads (SPEC §19.2): their progress while they run and, until they are cleared, that
/// some failed. Finished uploads leave the toolbar.
enum TransfersIndicatorState: Equatable {
    case hidden, running, failed

    static func state(activeCount: Int, hasFailures: Bool) -> TransfersIndicatorState {
        if activeCount > 0 { return .running }
        return hasFailures ? .failed : .hidden
    }
}

/// Shows upload progress while uploads run, or that some failed; tap for details.
struct TransfersIndicator: View {
    @Environment(SessionModel.self) private var session
    /// The tab bar's accessory shows the uploads already (iPhone, SPEC §17.3).
    @Environment(\.activityAccessoryKinds) private var accessoryKinds
    @State private var showing = false

    var body: some View {
        let queue = session.transfers
        let failed: Bool = queue.transfers.contains { if case .failed = $0.state { true } else { false } }
        let state: TransfersIndicatorState = TransfersIndicatorState.state(activeCount: queue.activeCount, hasFailures: failed)
        if state != .hidden && !accessoryKinds.contains(.upload) {
            Button {
                showing = true
            } label: {
                if state == .running {
                    Gauge(value: queue.overallProgress) { Text("") }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .scaleEffect(0.5)
                        .frame(width: 28, height: 28)
                        .accessibilityLabel(Text("Uploading \(queue.activeCount) items", bundle: .module))
                } else {
                    Image(systemName: "exclamationmark.icloud")
                        .accessibilityLabel(Text("Some uploads failed", bundle: .module))
                }
            }
            .help(String(localized: "Uploads", bundle: .module))
            .popover(isPresented: $showing) {
                TransfersList().frame(minWidth: 320, minHeight: 240)
            }
        }
    }
}

struct TransfersList: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        NavigationStack {
            List(session.transfers.transfers) { transfer in
                HStack {
                    Text(verbatim: transfer.fileName).lineLimit(1)
                    Spacer()
                    switch transfer.state {
                    case .waiting: Text("Waiting", bundle: .module).foregroundStyle(.secondary)
                    case .uploading(let value):
                        ProgressView(value: value).frame(width: 80).accessibilityLabel(Text("Uploading", bundle: .module))
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .accessibilityLabel(Text("Uploaded", bundle: .module))
                    case .failed(let message):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(message)
                            .accessibilityLabel(Text("Failed: \(message)", bundle: .module))
                    }
                }
            }
            .navigationTitle(String(localized: "Uploads", bundle: .module))
            .toolbar {
                Button(String(localized: "Clear", bundle: .module)) { session.transfers.clearFinished() }
            }
        }
    }
}

enum UploadSources {
    /// Copies security-scoped files (file importer, Finder) to temporary files for upload.
    static func copies(of urls: [URL]) -> [UploadSource] {
        var sources: [UploadSource] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let copy = FileManager.default.temporaryDirectory.appending(path: "Uploads/\(UUID().uuidString)/\(url.lastPathComponent)")
            try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(at: url, to: copy)) != nil {
                sources.append(UploadSource(file: copy, capturedAt: CaptureDate.read(copy)))
            }
        }
        return sources
    }
}
