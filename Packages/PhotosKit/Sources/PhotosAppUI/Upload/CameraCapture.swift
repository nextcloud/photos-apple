// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import PhotosCore
import PhotosModel
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
    import VisionKit
#endif

/// Photos taken or documents scanned for the album or folder shown (SPEC §16.5.3): on the Mac with an iPhone or iPad
/// nearby (Continuity Camera: File ▸ Import from iPhone or iPad, and the context menu), on iPhone and iPad with their
/// own camera. They are uploaded like a manual upload.
enum CapturedMedia {
    /// "IMG_20261125_140231.jpg" for a photo, "Scan_20261125_140231_2.jpg" for page 2 of a scan: like a camera, so the
    /// files sort by time next to the other photos.
    static func fileName(scan: Bool, date: Date, page: Int? = nil, fileExtension: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d%02d%02d_%02d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0,
            parts.second ?? 0)
        let page = page.map { "_\($0)" } ?? ""
        return "\(scan ? "Scan" : "IMG")_\(stamp)\(page).\(fileExtension)"
    }

    /// The pages of a scanned PDF as JPEG images, the long side at most `maxPixels`.
    static func jpegPages(ofPDF data: Data, maxPixels: CGFloat = 3000, quality: CGFloat = 0.85) -> [Data] {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return [] }
        var result: [Data] = []
        for number in stride(from: 1, through: document.numberOfPages, by: 1) {
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.cropBox)
            guard box.width > 0, box.height > 0 else { continue }
            let scale = min(maxPixels / max(box.width, box.height), 4)
            let width = Int((box.width * scale).rounded())
            let height = Int((box.height * scale).rounded())
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { continue }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            if let image = context.makeImage(), let jpeg = jpeg(image, quality: quality) { result.append(jpeg) }
        }
        return result
    }

    static func jpeg(_ image: CGImage, quality: CGFloat = 0.9) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A captured picture as a file to upload. HEIC, JPEG and PNG stay as they are (with the camera's EXIF); other
    /// formats (TIFF) become JPEG.
    static func photoFile(_ data: Data, type: UTType, date: Date) -> UploadSource? {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Uploads/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes = data
        var fileExtension = type.preferredFilenameExtension ?? "jpg"
        if ![UTType.heic, .jpeg, .png].contains(where: { type.conforms(to: $0) }) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let converted = jpeg(image)
            else { return nil }
            bytes = converted
            fileExtension = "jpg"
        }
        if fileExtension == "jpeg" { fileExtension = "jpg" }
        let url = directory.appending(path: fileName(scan: false, date: date, fileExtension: fileExtension))
        guard (try? bytes.write(to: url)) != nil else { return nil }
        return UploadSource(file: url, capturedAt: CaptureDate.read(url) ?? date)
    }

    /// Scanned pages as JPEG files to upload.
    static func scanFiles(_ pages: [Data], date: Date) -> [UploadSource] {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Uploads/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return pages.enumerated().compactMap { index, data in
            let page: Int? = pages.count > 1 ? index + 1 : nil
            let url = directory.appending(path: fileName(scan: true, date: date, page: page, fileExtension: "jpg"))
            guard (try? data.write(to: url)) != nil else { return nil }
            // One second apart, so the pages keep their order in the timeline.
            return UploadSource(file: url, capturedAt: date.addingTimeInterval(Double(index)))
        }
    }

    /// The types a capture can bring, the most faithful first.
    static let photoTypes: [UTType] = [.heic, .jpeg, .png, .tiff, .image]

    /// Files from what Continuity Camera (or a drop) handed over: a PDF is a scan, anything else a photo.
    @MainActor static func sources(from providers: [NSItemProvider], date: Date = Date()) async -> [UploadSource] {
        var sources: [UploadSource] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier),
                let data = await load(provider, type: .pdf)
            {
                let pages = await Task.detached(priority: .userInitiated) { jpegPages(ofPDF: data) }.value
                sources += scanFiles(pages, date: date)
                continue
            }
            for type in photoTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let data = await load(provider, type: type), let source = photoFile(data, type: type, date: date) {
                    sources.append(source)
                }
                break
            }
        }
        return sources
    }

    @MainActor static func load(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

extension View {
    /// Continuity Camera into this album or folder (Mac): File ▸ Import from iPhone or iPad ▸ Take Photo, Scan
    /// Documents, Add Sketch. Nothing elsewhere: iPhone and iPad take photos with their own camera (`UploadMenu`).
    func continuityCameraImport(folder: String? = nil, album: Album? = nil, isEnabled: Bool = true) -> some View {
        #if os(macOS)
            modifier(ContinuityCameraImport(folder: folder, album: album, isEnabled: isEnabled))
        #else
            self
        #endif
    }
}

#if os(macOS)
    private struct ContinuityCameraImport: ViewModifier {
        let folder: String?
        let album: Album?
        let isEnabled: Bool
        @Environment(SessionModel.self) private var session

        func body(content: Content) -> some View {
            content.importsItemProviders(isEnabled ? [.image, .pdf] : []) { providers in
                guard isEnabled, !providers.isEmpty, !session.isSignedOut else { return false }
                Task {
                    let sources = await CapturedMedia.sources(from: providers)
                    if !sources.isEmpty { session.transfers.upload(sources, to: folder, album: album) }
                }
                return true
            }
        }
    }
#endif

#if os(iOS)
    /// Take Photo and Scan Documents in the upload menu (iPhone, iPad), where the device has a camera.
    enum DeviceCapture {
        @MainActor static var canTakePhoto: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
        @MainActor static var canScan: Bool { VNDocumentCameraViewController.isSupported }

        static var takePhotoTitle: String {
            String(localized: "Take Photo", bundle: .module, comment: "Upload menu: take a photo with the camera and upload it.")
        }

        static var scanTitle: String {
            String(localized: "Scan Documents", bundle: .module, comment: "Upload menu: scan pages with the camera and upload them.")
        }
    }

    /// The system camera; the photo comes back as JPEG with its EXIF.
    struct CameraPicker: UIViewControllerRepresentable {
        let finish: (UploadSource?) -> Void

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.mediaTypes = [UTType.image.identifier]
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

        @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
            let finish: (UploadSource?) -> Void

            init(finish: @escaping (UploadSource?) -> Void) {
                self.finish = finish
            }

            func imagePickerController(
                _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                let image = info[.originalImage] as? UIImage
                let data = image?.jpegData(compressionQuality: 0.92)
                finish(data.flatMap { CapturedMedia.photoFile($0, type: .jpeg, date: Date()) })
            }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }
        }
    }

    /// The document scanner of VisionKit; each page becomes a JPEG.
    struct DocumentScanner: UIViewControllerRepresentable {
        let finish: ([UploadSource]) -> Void

        func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
            let scanner = VNDocumentCameraViewController()
            scanner.delegate = context.coordinator
            return scanner
        }

        func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

        // `@preconcurrency`: VisionKit's delegate protocol is not annotated, but the scanner calls it on the main thread.
        @MainActor final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
            let finish: ([UploadSource]) -> Void

            init(finish: @escaping ([UploadSource]) -> Void) {
                self.finish = finish
            }

            func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
                let pages = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.85) }
                finish(CapturedMedia.scanFiles(pages, date: Date()))
            }

            func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { finish([]) }

            func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) {
                finish([])
            }
        }
    }
#endif
