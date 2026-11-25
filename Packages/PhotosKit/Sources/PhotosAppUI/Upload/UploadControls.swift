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

/// Toolbar menu to upload from the Photos library or files, plus the transfer progress indicator (SPEC §7.17).
struct UploadMenu: View {
    var album: Album?
    @Environment(SessionModel.self) private var session
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingPicker = false
    @State private var importing = false
    #if os(iOS)
        @State private var capture: Capture?
    #endif

    var body: some View {
        Menu {
            Button {
                showingPicker = true
            } label: {
                Label(String(localized: "Upload from Photos", bundle: .module), systemImage: "photo.on.rectangle")
            }
            Button {
                importing = true
            } label: {
                Label(String(localized: "Upload files…", bundle: .module), systemImage: "folder")
            }
            #if os(iOS)
                // With the device's own camera, into the same place (SPEC §16.5.3).
                if DeviceCapture.canTakePhoto || DeviceCapture.canScan {
                    Divider()
                }
                if DeviceCapture.canTakePhoto {
                    Button {
                        capture = .photo
                    } label: {
                        Label(DeviceCapture.takePhotoTitle, systemImage: "camera")
                    }
                }
                if DeviceCapture.canScan {
                    Button {
                        capture = .scan
                    } label: {
                        Label(DeviceCapture.scanTitle, systemImage: "doc.viewfinder")
                    }
                }
            #endif
        } label: {
            // Not an arrow out of a box: that is "Share" on Apple platforms, and the Share button sits next to this one.
            Label(String(localized: "Upload", bundle: .module), systemImage: "icloud.and.arrow.up")
        }
        .help(String(localized: "Upload", bundle: .module))
        .photosPicker(
            isPresented: $showingPicker, selection: $pickerItems, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current
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
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            session.transfers.upload(UploadSources.copies(of: urls), album: album)
        }
        #if os(iOS)
            .fullScreenCover(item: $capture) { kind in
                switch kind {
                case .photo:
                    CameraPicker { source in
                        capture = nil
                        if let source { session.transfers.upload([source], album: album) }
                    }
                    .ignoresSafeArea()
                case .scan:
                    DocumentScanner { sources in
                        capture = nil
                        if !sources.isEmpty { session.transfers.upload(sources, album: album) }
                    }
                    .ignoresSafeArea()
                }
            }
        #endif
    }

    #if os(iOS)
        enum Capture: String, Identifiable {
            case photo, scan
            var id: String { rawValue }
        }
    #endif
}

/// What the timeline toolbar shows on which platform.
enum TimelineToolbar {
    /// The All / Photos / Videos / Favorites menu duplicates sidebar rows; it is only offered where there is no sidebar.
    static func showsMediaKindPicker(_ sizeClass: UserInterfaceSizeClass?) -> Bool {
        #if os(iOS)
            sizeClass == .compact
        #else
            false
        #endif
    }
}

/// Shows upload progress; tap for details.
struct TransfersIndicator: View {
    @Environment(SessionModel.self) private var session
    @State private var showing = false

    var body: some View {
        let queue = session.transfers
        if !queue.transfers.isEmpty {
            Button {
                showing = true
            } label: {
                if queue.activeCount > 0 {
                    Gauge(value: queue.overallProgress) { Text("") }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .scaleEffect(0.5)
                        .frame(width: 28, height: 28)
                        .accessibilityLabel(Text("Uploading \(queue.activeCount) items", bundle: .module))
                } else {
                    let failed: Bool = queue.transfers.contains { if case .failed = $0.state { true } else { false } }
                    Image(systemName: failed ? "exclamationmark.icloud" : "checkmark.icloud")
                        .accessibilityLabel(
                            failed ? Text("Some uploads failed", bundle: .module) : Text("Uploads finished", bundle: .module))
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
