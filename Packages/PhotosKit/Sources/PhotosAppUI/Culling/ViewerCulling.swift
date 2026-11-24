// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import PhotosStore
import SwiftUI

extension View {
    /// Rating and flag keys in the viewer (SPEC §15.2), the mark of the photo shown, and the confirmation after a key.
    ///
    /// - Parameters:
    ///   - ids: the files the page stands for: the photo, or every copy of a stacked tile (rated together, as in the grid).
    ///   - advance: shows the next photo (auto-advance).
    func viewerCulling(_ model: CullingModel, ids: [FileID], chromeHidden: Bool, advance: @escaping () -> Void) -> some View {
        modifier(ViewerCullingModifier(model: model, ids: ids, chromeHidden: chromeHidden, advance: advance))
    }
}

private struct ViewerCullingModifier: ViewModifier {
    let model: CullingModel
    let ids: [FileID]
    let chromeHidden: Bool
    let advance: () -> Void
    @Environment(SessionModel.self) private var session
    @Environment(\.undoManager) private var undoManager
    @State private var marks: [FileID: CullingMark] = [:]

    var mark: CullingMark { ids.first.flatMap { marks[$0] } ?? .none }

    func body(content: Content) -> some View {
        content
            .onKeyPress(characters: CharacterSet(charactersIn: "pxuPXU012345")) { press in
                guard press.modifiers.isDisjoint(with: [.command, .control, .option]), let key = press.characters.first,
                    let command = CullingCommand(key: key)
                else { return .ignored }
                apply(command)
                return .handled
            }
            .overlay(alignment: .bottomLeading) {
                if !mark.isEmpty && !chromeHidden {
                    CullingMarkPill(mark: mark)
                        .padding(16)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: mark)
            .cullingFeedback(model)
            #if DEBUG
                // UI checks without the real keyboard: `PHOTOS_DEBUG_VIEWER_KEYS=3,p` gives these keys, one a second.
                .task {
                    guard let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_VIEWER_KEYS"] else { return }
                    for key in raw.split(separator: ",") {
                        try? await Task.sleep(for: .seconds(2))
                        if let character = key.first, let command = CullingCommand(key: character) { apply(command) }
                    }
                }
            #endif
            .task(id: session.services != nil) {
                guard let services = session.services else { return }
                do {
                    for try await value in CullingStore(database: services.database).observeMarks() { marks = value }
                } catch {}
            }
    }

    func apply(_ command: CullingCommand) {
        model.apply(command, ids: ids, session: session, undoManager: undoManager)
        if CullingSettings.autoAdvance {
            // A moment later: the confirmation is seen on the photo it is about.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                advance()
            }
        }
    }
}

/// The stars and flag of the photo shown, in a corner of the viewer.
struct CullingMarkPill: View {
    let mark: CullingMark

    var body: some View {
        HStack(spacing: 6) {
            if mark.flag != .none {
                Image(systemName: CullingWording.flagSymbol(mark.flag))
                    .foregroundStyle(mark.flag == .pick ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            }
            if mark.rating > 0 {
                HStack(spacing: 1) {
                    ForEach(0..<mark.rating, id: \.self) { _ in Image(systemName: "star.fill") }
                }
                .foregroundStyle(.yellow)
            }
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CullingWording.description(of: mark))
    }
}

/// The Rating and Flag submenus of the viewer's More menu.
struct CullingMenuItems: View {
    var apply: (CullingCommand) -> Void

    var body: some View {
        Menu {
            ForEach([CullingFlag.pick, .reject, .none], id: \.self) { flag in
                Button {
                    apply(.flag(flag))
                } label: {
                    Label(CullingWording.flagTitle(flag), systemImage: CullingWording.flagSymbol(flag))
                }
            }
        } label: {
            Label(CullingWording.flagMenuTitle, systemImage: "flag")
        }
        Menu {
            ForEach((0...CullingTags.maxRating).reversed(), id: \.self) { stars in
                Button {
                    apply(.rate(stars))
                } label: {
                    Label(CullingWording.ratingTitle(stars), systemImage: stars == 0 ? "star.slash" : "star.fill")
                }
            }
        } label: {
            Label(CullingWording.ratingMenuTitle, systemImage: "star")
        }
    }
}
