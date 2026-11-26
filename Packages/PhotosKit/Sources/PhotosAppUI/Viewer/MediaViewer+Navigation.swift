// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

extension MediaViewer {
    /// The viewer's plain keys. On iPhone and iPad the rating keys are among them: the viewer is not focusable there, so
    /// the `onKeyPress` of `viewerCulling` does not get them (see `hardwareKeys`).
    static var hardwareKeys: [KeyEquivalent] {
        var keys: [KeyEquivalent] = [.leftArrow, .rightArrow, .escape, .space] + deleteKeys
        #if os(iOS)
            keys += "pxu012345".map { KeyEquivalent($0) }
        #endif
        return keys
    }

    /// A rating or flag key (iPhone and iPad), as `viewerCulling` handles it on the Mac.
    func cullingKey(_ key: KeyEquivalent) {
        guard session.features.has(.systemtags), let command = CullingCommand(key: key.character) else { return }
        culling.apply(command, ids: cullingIds, session: session, undoManager: undoManager)
        if CullingSettings.autoAdvance {
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                step(1)
            }
        }
    }

    static func viewerKey(_ key: KeyEquivalent) -> ViewerNavigation.Key? {
        switch key {
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        case .escape: .escape
        case .space: .space
        default: nil
        }
    }

    func perform(_ key: ViewerNavigation.Key) {
        let isVideo = currentItem?.kind == .video
        switch ViewerNavigation.command(for: key, isVideo: isVideo, rightToLeft: layoutDirection == .rightToLeft) {
        case .previous: step(-1)
        case .next: step(1)
        case .close: dismiss()
        case .togglePlayback: playbackToggle += 1
        }
    }

    /// The edge whose previous/next button the pointer is close enough to reveal.
    static func edge(under phase: HoverPhase, width: CGFloat) -> HorizontalEdge? {
        guard case .active(let location) = phase, width > 0 else { return nil }
        let zone = min(140, width / 4)
        if location.x < zone { return .leading }
        if location.x > width - zone { return .trailing }
        return nil
    }

    /// Previous/next buttons at the edges: shown under the pointer (Mac, iPad with a pointer), always there for accessibility.
    var stepButtons: some View {
        HStack {
            ViewerStepButton(delta: -1, isVisible: hoverEdge == .leading, isEnabled: canStep(-1)) { step(-1) }
            Spacer(minLength: 0)
            ViewerStepButton(delta: 1, isVisible: hoverEdge == .trailing, isEnabled: canStep(1)) { step(1) }
        }
        .padding(.horizontal, 12)
    }

    func canStep(_ delta: Int) -> Bool {
        ViewerNavigation.canStep(in: shownIds, from: current, delta: delta)
    }
}

/// Round previous/next button at an edge of the viewer.
private struct ViewerStepButton: View {
    let delta: Int
    let isVisible: Bool
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var increasedContrast: Bool { contrast == .increased || reduceTransparency }

    var title: String {
        delta < 0 ? String(localized: "Previous", bundle: .module) : String(localized: "Next", bundle: .module)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: delta < 0 ? "chevron.backward" : "chevron.forward")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(OverlayLegibility.scrimOpacity(base: 0.45, increased: increasedContrast)), in: .circle)
                .contentShape(.circle)
                // Only the artwork fades: a button with zero opacity would also vanish for VoiceOver and keyboard users.
                .opacity(isVisible && isEnabled ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isVisible)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isVisible)
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
    }
}
