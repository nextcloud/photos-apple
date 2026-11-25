// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

// The morph between the Library's zoom levels (SPEC §17.5): the photos on screen on both levels travel and scale from the
// old level to the new one while the rest cross-fades. Years, months and days report where their photos are; the grid
// tells where its tiles are (`GridTileLocator`). The travelling copies are drawn above both levels, the photos they stand
// for are hidden until they land. With Reduce Motion the levels only cross-fade.

/// Where the photos of each summary level are on screen, in the zoom overlay's coordinate space. Nobody observes it:
/// photos report their frames while scrolling without redrawing anything.
@MainActor
final class ZoomPhotoFrames {
    private var frames: [LibraryZoomLevel: [FileID: CGRect]] = [:]
    /// The photos last seen on any level, for drawing their travelling copies.
    private(set) var items: [FileID: GridMedia] = [:]

    func report(_ item: GridMedia, frame: CGRect, on level: LibraryZoomLevel) {
        frames[level, default: [:]][item.fileId] = frame
        items[item.fileId] = item
    }

    func remove(_ id: FileID, on level: LibraryZoomLevel) {
        frames[level]?[id] = nil
        if !frames.values.contains(where: { $0[id] != nil }) { items[id] = nil }
    }

    func frames(on level: LibraryZoomLevel) -> [FileID: CGRect] { frames[level] ?? [:] }

}

/// One photo on its way from one level to the next.
struct ZoomFlight: Identifiable {
    let id: Int
    let source: GridMedia
    let destination: GridMedia
    let from: CGRect
    let to: CGRect
    let fromRadius: CGFloat
    let toRadius: CGFloat
    /// The pictures already decoded in memory (no BlurHash flash at the start of the flight).
    let image: CGImage?
    let destinationImage: CGImage?

    var crossFades: Bool { source.fileId != destination.fileId }
}

/// The flights of one level change, and the grid tiles they stand for (hidden while they fly).
struct ZoomMorph: Identifiable {
    let id = UUID()
    let flights: [ZoomFlight]
    /// Grid tiles covered while their copies fly (a tile cannot be hidden from SwiftUI; it is painted over instead).
    let gridHoles: [CGRect]
}

/// The level a summary photo is shown on, and the model it reports its frame to.
struct ZoomPhotoReporter {
    let model: LibraryZoomModel
    let level: LibraryZoomLevel
}

extension EnvironmentValues {
    @Entry var zoomPhotoReporter: ZoomPhotoReporter? = nil
}

enum LibraryZoomSpace {
    /// The coordinate space of the zoom overlay: the grid, the summary levels and the flights all measure in it.
    nonisolated static let name = "libraryZoomMorph"

    /// The flights' timing: a short spring without bounce, a little longer than the levels' cross-fade, so the photos land
    /// on a settled level.
    static let flight = Animation.smooth(duration: 0.44)
}

extension View {
    /// A summary photo: reports where it is (for the flights) and hides while its copy travels.
    func zoomMorphPhoto(_ item: GridMedia) -> some View {
        modifier(ZoomMorphPhoto(item: item))
    }

    /// Writing on a summary photo (a card's title, "+12"): hidden while the photo's copy travels, faded in when it lands
    /// (the copy flies above it and would otherwise hide it until it pops back).
    func zoomMorphCaption(of id: FileID) -> some View {
        modifier(ZoomMorphCaption(id: id))
    }

    /// The Library's grid: tells the zoom model where its tiles are, in the zoom overlay's coordinate space.
    /// Also keeps the grid's tiles out of VoiceOver's reach while a summary level covers it.
    func libraryZoomGridFrame(_ model: LibraryZoomModel?, locator: GridTileLocator) -> some View {
        onChange(of: model.map { $0.level != .all } ?? false, initial: true) { _, covered in
            locator.isCovered = covered
        }
        .onGeometryChange(for: CGPoint.self) { proxy in
            proxy.frame(in: .named(LibraryZoomSpace.name)).origin
        } action: { origin in
            guard let model else { return }
            model.gridTileFrame = { [locator] id in
                locator.frame(id).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
            }
        }
    }
}

private struct ZoomMorphPhoto: ViewModifier {
    let item: GridMedia
    @Environment(\.zoomPhotoReporter) private var reporter

    func body(content: Content) -> some View {
        if let reporter {
            content
                .opacity(reporter.model.hidden.contains(item.fileId) ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(LibraryZoomSpace.name))
                } action: { frame in
                    reporter.model.photoFrames.report(item, frame: frame, on: reporter.level)
                }
                .onDisappear { reporter.model.photoFrames.remove(item.fileId, on: reporter.level) }
        } else {
            content
        }
    }
}

private struct ZoomMorphCaption: ViewModifier {
    let id: FileID
    @Environment(\.zoomPhotoReporter) private var reporter

    func body(content: Content) -> some View {
        let hidden = reporter?.model.hidden.contains(id) ?? false
        content
            .opacity(hidden ? 0 : 1)
            .animation(hidden ? nil : .easeOut(duration: 0.2), value: hidden)
    }
}

/// The travelling photos, above both levels. They start where they were (as soon as the new level is laid out) and
/// land where they are on the new level; then the level's own photos take their place.
struct ZoomFlightsLayer: View {
    let morph: ZoomMorph
    let finished: (UUID) -> Void
    @State private var landed = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(morph.flights) { flight in
                ZoomFlightView(flight: flight, landed: landed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(LibraryZoomSpace.flight) {
                landed = true
            } completion: {
                finished(morph.id)
            }
        }
    }
}

private struct ZoomFlightView: View {
    let flight: ZoomFlight
    let landed: Bool

    var body: some View {
        let frame = landed ? flight.to : flight.from
        ZStack {
            picture(flight.source, image: flight.image)
            if flight.crossFades {
                picture(flight.destination, image: flight.destinationImage).opacity(landed ? 1 : 0)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(.rect(cornerRadius: landed ? flight.toRadius : flight.fromRadius))
        .position(x: frame.midX, y: frame.midY)
    }

    @ViewBuilder func picture(_ item: GridMedia, image: CGImage?) -> some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: (landed ? flight.to : flight.from).width, height: (landed ? flight.to : flight.from).height)
                .clipped()
        } else {
            SummaryPhoto(item: item, bucket: 256)
        }
    }
}

/// Grid tiles whose copies are travelling, painted over in the grid's background.
struct ZoomGridHoles: View {
    let holes: [CGRect]
    let color: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(holes.enumerated()), id: \.offset) { _, hole in
                Rectangle().fill(color)
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
