// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import MapKit
import PhotosCore
import PhotosStore
import SwiftUI

#if os(macOS)
    typealias PlatformViewRepresentable = NSViewRepresentable
    typealias PlatformView = NSView
#else
    typealias PlatformViewRepresentable = UIViewRepresentable
    typealias PlatformView = UIView
#endif

/// The photo map (SPEC MP-1): an `MKMapView`, because SwiftUI's `Map` cannot cluster. One annotation per grid cell of the
/// database (`MapGrid`); annotations that overlap on screen are merged by MapKit into an `MKClusterAnnotation` whose
/// marker shows the newest photo and the photos of all its cells.
struct ClusteredMapView: PlatformViewRepresentable {
    let cells: [MapCell]
    /// A region to show (the photos' area when the map opens); applied once per new value.
    let target: MapTarget?
    let session: SessionModel
    let onRegionChange: (MKCoordinateRegion) -> Void
    /// A marker was chosen: the cells of the marker (one, or the members of a cluster).
    let onSelect: ([MapCell]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    #if os(macOS)
        func makeNSView(context: Context) -> MKMapView { makeMap(context.coordinator) }
        func updateNSView(_ map: MKMapView, context: Context) { context.coordinator.update(map, with: self) }
    #else
        func makeUIView(context: Context) -> MKMapView { makeMap(context.coordinator) }
        func updateUIView(_ map: MKMapView, context: Context) { context.coordinator.update(map, with: self) }
    #endif

    func makeMap(_ coordinator: Coordinator) -> MKMapView {
        let map = MKMapView()
        map.delegate = coordinator
        map.register(PhotoCellAnnotationView.self, forAnnotationViewWithReuseIdentifier: PhotoCellAnnotationView.reuseIdentifier)
        map.register(
            PhotoClusterAnnotationView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        coordinator.parent = self
        return map
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ClusteredMapView?
        /// The annotations on the map by cell; replaced when their cell changed (other count or cover).
        var annotations: [CellKey: PhotoCellAnnotation] = [:]
        var appliedTarget: MapTarget?

        /// A cell of a query: the same cell size, row and column are the same place.
        struct CellKey: Hashable {
            var row: Int
            var column: Int
            var cellLatitude: Double
            var cellLongitude: Double

            init(_ cell: MapCell) {
                row = cell.row
                column = cell.column
                cellLatitude = cell.cellLatitude
                cellLongitude = cell.cellLongitude
            }
        }

        func update(_ map: MKMapView, with parent: ClusteredMapView) {
            self.parent = parent
            if let target = parent.target, target != appliedTarget {
                appliedTarget = target
                map.setRegion(map.regionThatFits(target.region), animated: false)
            }
            var wanted: [CellKey: MapCell] = [:]
            for cell in parent.cells { wanted[CellKey(cell)] = cell }
            var removed: [PhotoCellAnnotation] = []
            for (key, annotation) in annotations where !Self.looksTheSame(wanted[key], annotation.cell) {
                removed.append(annotation)
                annotations[key] = nil
            }
            var added: [PhotoCellAnnotation] = []
            for (key, cell) in wanted where annotations[key] == nil {
                let annotation = PhotoCellAnnotation(cell: cell)
                annotations[key] = annotation
                added.append(annotation)
            }
            if !removed.isEmpty { map.removeAnnotations(removed) }
            if !added.isEmpty { map.addAnnotations(added) }
        }

        /// Whether a marker can stay: the same photos and cover in the same period. The query a cell came from moves with
        /// the camera and does not matter (cells are whole, `MapGrid.query`): markers keep their identity while the map is
        /// moved, so they neither flicker nor have to be clustered again.
        static func looksTheSame(_ new: MapCell?, _ old: MapCell) -> Bool {
            guard let new else { return false }
            return new.count == old.count && new.cover == old.cover && new.latitude == old.latitude && new.longitude == old.longitude
                && new.place == old.place && new.period == old.period
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Not inside SwiftUI's update of the view (`setRegion` in `update` reports the change at once).
            let region = mapView.region
            Task { @MainActor [weak self] in self?.parent?.onRegionChange(region) }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let session = parent?.session else { return nil }
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: cluster)
                (view as? PhotoClusterAnnotationView)?.configure(session: session)
                return view
            }
            guard let cell = annotation as? PhotoCellAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: PhotoCellAnnotationView.reuseIdentifier, for: cell)
            (view as? PhotoCellAnnotationView)?.configure(session: session)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            let cells = PhotoAnnotationContent.cells(of: annotation)
            if !cells.isEmpty { parent?.onSelect(cells) }
        }
    }
}

/// A region the map should show, with an identity so the same region can be asked for again.
struct MapTarget: Equatable {
    var id = UUID()
    var region: MKCoordinateRegion

    static func == (a: MapTarget, b: MapTarget) -> Bool { a.id == b.id }
}

/// One grid cell of the database on the map.
final class PhotoCellAnnotation: NSObject, MKAnnotation {
    let cell: MapCell
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(cell: MapCell) {
        self.cell = cell
        coordinate = CLLocationCoordinate2D(latitude: cell.latitude, longitude: cell.longitude)
        title = AccessibilityText.mapMarker(place: cell.place, count: cell.count, newest: cell.cover.timestamp)
    }
}

/// What a marker shows and says, for a cell or a cluster of cells.
enum PhotoAnnotationContent {
    static func cells(of annotation: any MKAnnotation) -> [MapCell] {
        if let cell = annotation as? PhotoCellAnnotation { return [cell.cell] }
        if let cluster = annotation as? MKClusterAnnotation {
            return cluster.memberAnnotations.compactMap { ($0 as? PhotoCellAnnotation)?.cell }
        }
        return []
    }

    /// The marker of some cells: newest cover, all their photos, and "Lisbon, 12 photos".
    static func marker(of annotation: any MKAnnotation) -> (cover: MapCell, count: Int, label: String)? {
        let merged = MapGrid.merged(cells(of: annotation))
        guard let cover = merged.cover else { return nil }
        return (cover, merged.count, AccessibilityText.mapMarker(place: cover.place, count: merged.count, newest: cover.cover.timestamp))
    }
}

/// The marker of a cell: a thumbnail of its newest photo with the number of photos. Cells that overlap on screen are
/// clustered (`clusteringIdentifier`).
class PhotoCellAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "photo-cell"
    static let side: CGFloat = 52
    private var host: MarkerHost?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.side + 16, height: Self.side + 16)
        collisionMode = .rectangle
        clusteringIdentifier = "photos"
        displayPriority = .defaultHigh
        canShowCallout = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var annotation: (any MKAnnotation)? {
        didSet { refresh() }
    }

    private var session: SessionModel?

    func configure(session: SessionModel) {
        self.session = session
        refresh()
    }

    private func refresh() {
        guard let annotation, let session, let marker = PhotoAnnotationContent.marker(of: annotation) else { return }
        let content = MapMarkerThumbnail(cell: marker.cover, count: marker.count)
        if let host {
            host.update(content, session: session)
        } else {
            let host = MarkerHost(content, session: session)
            host.view.frame = bounds
            addSubview(host.view)
            self.host = host
        }
        #if os(macOS)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(marker.label)
            toolTip = marker.label
        #else
            isAccessibilityElement = true
            accessibilityTraits = .button
            accessibilityLabel = marker.label
        #endif
    }

    /// VoiceOver and Voice Control open the marker like a click.
    private func choose() {
        guard let annotation, let map = superview(of: MKMapView.self) else { return }
        map.selectAnnotation(annotation, animated: false)
    }

    #if os(macOS)
        override func accessibilityPerformPress() -> Bool {
            choose()
            return true
        }
    #else
        override func accessibilityActivate() -> Bool {
            choose()
            return true
        }
    #endif

    private func superview<T>(of type: T.Type) -> T? {
        var view: PlatformView? = superview
        while let current = view {
            if let match = current as? T { return match }
            view = current.superview
        }
        return nil
    }
}

/// The marker of a cluster: the same look, with the newest photo and the photos of all its cells.
final class PhotoClusterAnnotationView: PhotoCellAnnotationView {
    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = nil
        displayPriority = .required
    }
}

/// A SwiftUI marker inside an annotation view.
@MainActor final class MarkerHost {
    #if os(macOS)
        let hosting: NSHostingView<AnyView>
        var view: NSView { hosting }
    #else
        let hosting: UIHostingController<AnyView>
        var view: UIView { hosting.view }
    #endif

    init(_ content: MapMarkerThumbnail, session: SessionModel) {
        let root = AnyView(content.environment(session))
        #if os(macOS)
            hosting = NSHostingView(rootView: root)
        #else
            hosting = UIHostingController(rootView: root)
            hosting.view.backgroundColor = .clear
        #endif
    }

    func update(_ content: MapMarkerThumbnail, session: SessionModel) {
        #if os(macOS)
            hosting.rootView = AnyView(content.environment(session))
        #else
            hosting.rootView = AnyView(content.environment(session))
        #endif
    }
}

/// A map marker: the newest photo of a cell (or cluster) with the number of photos there.
struct MapMarkerThumbnail: View {
    let cell: MapCell
    let count: Int

    var body: some View {
        PreviewImage(
            fileId: cell.cover.fileId, etag: cell.cover.etag, bucket: 256, blurhash: cell.cover.blurhash,
            hasPreview: cell.cover.hasPreview, mimeType: cell.cover.mimeType,
            path: cell.cover.directory == "/" ? "/" + cell.cover.name : cell.cover.directory + "/" + cell.cover.name
        )
        .frame(width: PhotoCellAnnotationView.side, height: PhotoCellAnnotationView.side)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text(count, format: .number).font(.caption2.bold()).padding(4).background(.tint, in: .capsule)
                    .foregroundStyle(.white).offset(x: 6, y: -6)
            }
        }
        .shadow(radius: 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The annotation view speaks for the marker.
        .accessibilityHidden(true)
    }
}
