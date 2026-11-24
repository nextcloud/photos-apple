// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import PhotosStore
import SwiftUI

/// The copies of a stacked photo in the viewer (SPEC VW-6): a small picture of each with its format ("DNG", "HEIC"),
/// since the copies look alike. The copy shown is marked; another one is shown with a tap or click. VoiceOver reads
/// "Copy 2 of 3 · IMG_1234.DNG" and which one is selected.
struct StackStrip: View {
    let copies: [FileID]
    let shown: FileID
    let choose: (FileID) -> Void
    @Environment(SessionModel.self) private var session
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var items: [FileID: MediaItem] = [:]

    static let side: CGFloat = 44

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(copies.enumerated()), id: \.element) { index, id in
                copyButton(id, index: index)
            }
        }
        .padding(6)
        .background(
            .black.opacity(OverlayLegibility.scrimOpacity(base: 0.55, increased: contrast == .increased || reduceTransparency)),
            in: .rect(cornerRadius: 12)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Copies of this photo", bundle: .module))
        .task(id: copies) {
            guard let library = session.services?.library else { return }
            items = (try? library.items(copies)) ?? [:]
        }
    }

    func copyButton(_ id: FileID, index: Int) -> some View {
        let item: MediaItem? = items[id]
        let selected: Bool = id == shown
        let name: String = item?.name ?? ""
        return Button {
            choose(id)
        } label: {
            VStack(spacing: 3) {
                Group {
                    if let item {
                        PreviewImage(item: item, bucket: 256)
                    } else {
                        Color.white.opacity(0.15)
                    }
                }
                .frame(width: Self.side, height: Self.side)
                .clipShape(.rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(selected ? Color.white : Color.clear, lineWidth: 2)
                }
                Text(Self.format(of: name))
                    .font(.caption2.weight(selected ? .bold : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(MediaViewer.copyPosition(index: index, count: copies.count, name: name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "DNG" for "IMG_1234.dng"; the whole name when it has no extension.
    static func format(of name: String) -> String {
        let ext: String = (name as NSString).pathExtension
        return ext.isEmpty ? name : ext.uppercased()
    }
}
