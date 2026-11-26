// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How a server preview is stored on the device (SPEC §18.3.3).
///
/// The server sends JPEG previews of JPEG, HEIC and most other photos, and PNG previews of PNG files (screenshots,
/// graphics). A PNG preview of 2048 px takes 3–9 MB; as HEIC it takes about a tenth and looks better than the server's
/// JPEG previews. JPEG previews are kept as they come: re-encoding them only adds a second generation of artefacts, and
/// at the same fidelity a HEIC copy is not smaller (measured on the test library, see SPEC §18.3.3).
public enum PreviewTranscoding {
    /// HEIC quality for previews of lossless sources: 39.3 dB from the source on average (the server's JPEG previews are
    /// 37.8 dB from their originals), 11.5 % of the PNG's size.
    public static let heicQuality = 0.7
    public static let heicExtension = "heic"

    /// The device can write HEIC (every device the app runs on; some simulators cannot).
    public static let canWriteHEIC: Bool = {
        let types = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return types.contains(UTType.heic.identifier)
    }()

    /// The type of an encoded image (from its content), nil when ImageIO does not read it.
    public static func type(of data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let identifier = CGImageSourceGetType(source) else {
            return nil
        }
        return UTType(identifier as String)
    }

    /// The type of an image file, from its first bytes.
    public static func type(of url: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let identifier = CGImageSourceGetType(source) else {
            return nil
        }
        return UTType(identifier as String)
    }

    /// A preview worth storing as HEIC: a lossless (or uncompressed) still image, not already HEIC, JPEG or another
    /// lossy format, and not animated.
    public static func shouldStoreAsHEIC(_ type: UTType?) -> Bool {
        guard let type else { return false }
        let lossless: [UTType] = [.png, .tiff, .bmp]
        return lossless.contains { type.conforms(to: $0) }
    }

    /// What to write for a preview the server sent: HEIC when that pays (see `shouldStoreAsHEIC`), else the data as it is.
    public static func storage(for data: Data, quality: Double = heicQuality) -> (data: Data, isHEIC: Bool) {
        guard shouldStoreAsHEIC(type(of: data)), let heic = heic(from: data, quality: quality) else { return (data, false) }
        return (heic, true)
    }

    /// The image as HEIC, with its orientation and colour profile (the source's properties are carried over); nil when
    /// HEIC cannot be written here or the result is not smaller.
    public static func heic(from data: Data, quality: Double = heicQuality) -> Data? {
        guard canWriteHEIC, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1 else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImageFromSource(
            destination, source, 0, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0, output.length < data.count else { return nil }
        return output as Data
    }
}
