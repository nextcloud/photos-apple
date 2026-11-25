// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI

// Placeholders that have the shape of what is coming (SPEC §15.5 "no spinners"): a screen that waits for the server
// shows its layout in grey right away, softly pulsing, instead of a spinner on an empty page.

extension View {
    /// A slow pulse of the opacity, as the grid's skeleton has; still with Reduce Motion.
    func skeletonPulse() -> some View {
        modifier(SkeletonPulse())
    }
}

struct SkeletonPulse: ViewModifier {
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.45 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}

/// Rows of a list that is still loading: an optional square (a cover, an avatar) and two lines of text.
struct SkeletonRows: View {
    var count = 6
    /// Side of the leading square; 0: none.
    var thumbnail: CGFloat = 44
    var circular = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 12) {
                    if thumbnail > 0 {
                        if circular {
                            Circle().frame(width: thumbnail, height: thumbnail)
                        } else {
                            RoundedRectangle(cornerRadius: 6).frame(width: thumbnail, height: thumbnail)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).frame(width: index.isMultiple(of: 2) ? 160 : 120, height: 13)
                        RoundedRectangle(cornerRadius: 4).frame(width: 80, height: 10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .foregroundStyle(.quaternary)
        .skeletonPulse()
        .accessibilityHidden(true)
    }
}

/// Covers of a collection that is still loading (albums, people, places): grey cards with a caption line.
struct SkeletonCovers: View {
    var count = 8
    var minimum: CGFloat = 150
    var circular = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 16)], spacing: 18) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    if circular {
                        Circle().aspectRatio(1, contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: Design.coverCornerRadius).aspectRatio(1, contentMode: .fit)
                    }
                    RoundedRectangle(cornerRadius: 4).frame(width: 90, height: 12)
                }
            }
        }
        .padding()
        .foregroundStyle(.quaternary)
        .skeletonPulse()
        .accessibilityHidden(true)
    }
}

/// A spinner that only appears when the wait turns out to be long (`delay`), for the few waits where nothing better can
/// be shown: most of them are over before it appears, and nothing flashes.
struct DelayedSpinner: View {
    var delay: Duration = .milliseconds(900)
    var tint: Color?
    var large = false
    @State private var shown = false

    var body: some View {
        ZStack {
            if shown {
                ProgressView()
                    .controlSize(large ? .large : .regular)
                    .tint(tint)
                    .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: delay)
            withAnimation(.easeIn(duration: 0.2)) { shown = true }
        }
    }
}
