// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Observation
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// "Show in timeline" (SPEC VW-3): opens the Library at the photo's day and highlights its tile, in the window it was
/// chosen in. `MainView` provides it; the viewer and the grid's context menu offer it next to "Show in folder" (not in
/// the Library itself, where the photo already is).
struct ShowInTimelineAction {
    let open: @MainActor (MediaItem) -> Void

    @MainActor func callAsFunction(_ item: MediaItem) { open(item) }

    /// Named after the place it opens, as Apple Photos' "Show in All Photos": title case on the Mac.
    static var title: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Show in Library", bundle: .module),
            other: LocalizedStringResource("Show in library", bundle: .module))
    }

    static let systemImage = "photo.on.rectangle"

    /// Archived photos are not in the Library (the Archive shows them), nor is the video half of a Live Photo.
    static func isOffered(for item: MediaItem) -> Bool {
        !item.isArchived && !item.isLivePhotoVideo
    }
}

/// The photo the Library timeline is asked to show: `MainView` puts it here, the timeline scrolls to it once its grid
/// has the photo, highlights it and clears the request.
@MainActor
@Observable
final class TimelineRevealCenter {
    struct Request: Equatable {
        let id = UUID()
        var fileId: FileID
        var date: Date
    }

    var pending: Request?

    func request(_ item: MediaItem) {
        pending = Request(fileId: item.fileId, date: item.timestamp)
    }

    /// The tile of `request` in a grid's items (the photo, the stack it is in, or the tile closest in time).
    static func target(of request: Request, in items: [GridMedia]) -> TimelineReveal.Target<FileID>? {
        TimelineReveal.target(
            for: request.fileId, date: request.date, in: items.map { (id: $0.fileId, date: $0.timestamp, stack: $0.stack) })
    }
}

extension EnvironmentValues {
    @Entry var showInTimeline: ShowInTimelineAction? = nil
    @Entry var timelineReveal: TimelineRevealCenter? = nil
}

/// A ring that briefly marks a tile the timeline was opened at (iPhone, iPad, Vision Pro; the Mac selects the tile).
struct TileHighlightMark: View {
    let frame: CGRect
    @State private var shown = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.accentColor, lineWidth: 4)
            .frame(width: frame.width + 6, height: frame.height + 6)
            .position(x: frame.midX, y: frame.midY)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { shown = false }
            }
    }
}
