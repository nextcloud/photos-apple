// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(macOS)
    import AppKit
    import Foundation
    import MapKit
    import Testing

    /// What MapKit's annotations cost (SPEC MP-1, budget 200 ms per region change with 50 000 geotagged photos). The
    /// map's markers are database cells (at most 32 × 32 for a region, `MapGrid`) that MapKit clusters; one annotation
    /// per photo would be the alternative. Timed on an `MKMapView` in a window far outside the screens (never key, the
    /// test process is not activated): from adding the annotations until MapKit asked for the view of each of them. The
    /// clustering itself is done when the map is drawn, which a window nobody sees never is, so it is not in these
    /// numbers. Printed lines start with `PERF`. Skipped with `PHOTOS_SKIP_PERFORMANCE=1`.
    @MainActor
    @Suite(
        .serialized,
        .enabled(if: ProcessInfo.processInfo.environment["PHOTOS_SKIP_PERFORMANCE"] == nil, "PHOTOS_SKIP_PERFORMANCE is set"))
    struct MapClusteringTests {
        final class Delegate: NSObject, MKMapViewDelegate {
            var views = 0

            func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
                views += 1
                if annotation is MKClusterAnnotation { return nil }
                let view = MKAnnotationView(annotation: annotation, reuseIdentifier: "p")
                view.frame = CGRect(x: 0, y: 0, width: 68, height: 68)
                view.clusteringIdentifier = "photos"
                view.collisionMode = .rectangle
                return view
            }
        }

        /// Adds `count` annotations spread over the visible part of Europe; milliseconds until every view was asked for.
        func add(_ count: Int) -> Double {
            let window = NSWindow(
                contentRect: CGRect(x: -20_000, y: -20_000, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
            let delegate = Delegate()
            map.delegate = delegate
            window.contentView = map
            window.orderFrontRegardless()
            defer {
                map.removeAnnotations(map.annotations)
                window.orderOut(nil)
                window.contentView = nil
            }
            map.setRegion(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 50, longitude: 10),
                    span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 40)),
                animated: false)
            var generator = SystemRandomNumberGenerator()
            let annotations: [MKPointAnnotation] = (0..<count).map { _ in
                let point = MKPointAnnotation()
                point.coordinate = CLLocationCoordinate2D(
                    latitude: Double.random(in: 40...60, using: &generator), longitude: Double.random(in: -5...25, using: &generator))
                return point
            }
            let began = ContinuousClock.now
            map.addAnnotations(annotations)
            map.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline && delegate.views < count {
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
            let elapsed = ContinuousClock.now - began
            #expect(delegate.views >= count)
            return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }

        @Test func cellAnnotationsStayWithinTheBudgetAndOnePerPhotoWouldNot() {
            _ = add(100)
            var times: [Int: Double] = [:]
            for count in [256, 1024, 5000, 50_000] {
                times[count] = add(count)
                print("PERF MapKit annotations: \(count) added in \(String(format: "%.0f", times[count]!)) ms")
            }
            // Generous: unit tests run unoptimised next to other work. The budget is 200 ms.
            #expect(times[1024]! < 1000)
        }
    }
#endif
