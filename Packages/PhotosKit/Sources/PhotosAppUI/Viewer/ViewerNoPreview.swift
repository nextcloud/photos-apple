// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosMedia
import PhotosModel
import SwiftUI

/// The page of a photo the server has no preview of and that could not be made on the device (a broken or unsupported
/// file, SPEC §20.1): what the file is, its name and "No preview" — not an empty black page.
struct ViewerNoPreview: View {
    let item: MediaItem
    @Environment(SessionModel.self) private var session

    var symbol: String {
        if item.kind == .video { return "video" }
        if item.mimeType.hasPrefix("image/") { return "photo" }
        return "doc"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: item.name)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            Text(GridTileNoPicture.caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            explanation
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    /// Why there is no picture (SPEC §20.1): the server has none and the app could not make one, and when it tries again.
    var explanation: Text {
        switch session.services?.images.noPreviewReason(fileId: item.fileId, etag: item.etag) {
        case .tooLarge(let bytes):
            Text(
                "The server has no preview, and at \(bytes.formatted(.byteCount(style: .file))) the file is too large to make one here.",
                bundle: .module,
                comment:
                    "Viewer: under \"No preview\" on the page of a photo the server has no preview of and whose original is too large to download for one; the argument is its size, e.g. \"72 MB\"."
            )
        case .lowDataMode:
            Text(
                "The server has no preview. One is made from the file when Low Data Mode is off.", bundle: .module,
                comment:
                    "Viewer: under \"No preview\" on the page of a photo the server has no preview of, while Low Data Mode keeps the app from downloading the original to make one."
            )
        case .unreadable:
            Text(
                "Neither the server nor this app can read the file: it may be damaged, or in a format they do not support. It is tried again after the next sync.",
                bundle: .module,
                comment:
                    "Viewer: under \"No preview\" on the page of a broken or unsupported file that neither the server nor the app could make a picture of."
            )
        case nil:
            Text(
                "The server could not make a preview of this file. It is asked again after the next sync.", bundle: .module,
                comment: "Viewer: under \"No preview\" on the page of a broken or unsupported file."
            )
        }
    }
}
