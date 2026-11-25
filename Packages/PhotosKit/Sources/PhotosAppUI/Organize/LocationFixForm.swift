// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import MapKit
import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// One place for many photos, picked on the map or found by name (SPEC §16.4).
struct LocationFixForm: View {
    let items: [MediaItem]
    @Binding var edits: [MetadataEdit]
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var placeName: String?
    @State private var position: MapCameraPosition = .automatic
    @State private var removeLocation = false
    @State private var onlyMissing = false
    @State private var query = ""
    @State private var results: [MKMapItem] = []

    var located: [MediaItem] { items.filter(\.hasLocation) }

    var targets: [MediaItem] { onlyMissing ? items.filter { !$0.hasLocation } : items }

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Remove the location", bundle: .module), isOn: $removeLocation)
            }
            if !removeLocation {
                Section {
                    TextField(String(localized: "Search for a place", bundle: .module), text: $query)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await search() } }
                    ForEach(results, id: \.self) { result in
                        Button {
                            choose(result)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(result.name ?? "")
                                if let address = result.address?.shortAddress ?? result.address?.fullAddress {
                                    Text(address).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    MapReader { proxy in
                        Map(position: $position) {
                            ForEach(located.prefix(200)) { item in
                                if let lat = item.latitude, let lon = item.longitude {
                                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                                        Circle().fill(.secondary).frame(width: 8, height: 8)
                                    }
                                }
                            }
                            if let coordinate {
                                Marker(placeName ?? "", systemImage: "photo.on.rectangle", coordinate: coordinate).tint(Design.accent)
                            }
                        }
                        .onTapGesture { point in
                            if let value = proxy.convert(point, from: .local) {
                                coordinate = value
                                placeName = nil
                            }
                        }
                    }
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } header: {
                    Text("Place", bundle: .module)
                } footer: {
                    Text(
                        "Tap the map or search for a place. Grey dots are where the selected photos are now.", bundle: .module)
                }
                if !located.isEmpty && located.count < items.count {
                    Section {
                        Toggle(String(localized: "Only photos without a location", bundle: .module), isOn: $onlyMissing)
                    }
                }
            }
            Section {
                Text(summary).font(.footnote)
            }
            WhereItIsWritten(items: targets)
        }
        .formStyle(.grouped)
        .onAppear {
            if let first = located.first, let lat = first.latitude, let lon = first.longitude {
                position = .region(
                    MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: lat, longitude: lon), latitudinalMeters: 20_000, longitudinalMeters: 20_000
                    ))
            }
        }
        .onChange(
            of: EditKey(coordinate: coordinate.map { [$0.latitude, $0.longitude] }, remove: removeLocation, onlyMissing: onlyMissing),
            initial: true
        ) { _, key in
            if key.remove {
                edits = targets.filter(\.hasLocation).map { MetadataEdit(fileId: $0.fileId, removeLocation: true) }
            } else if let value = key.coordinate {
                edits = targets.map { MetadataEdit(fileId: $0.fileId, latitude: value[0], longitude: value[1]) }
            } else {
                edits = []
            }
        }
    }

    struct EditKey: Equatable {
        var coordinate: [Double]?
        var remove: Bool
        var onlyMissing: Bool
    }

    var summary: String {
        if removeLocation {
            return String(localized: "Removes the location of \(AccessibilityText.items(located.count)).", bundle: .module)
        }
        guard coordinate != nil else {
            return String(localized: "Choose a place for \(AccessibilityText.items(targets.count)).", bundle: .module)
        }
        let replaced: Int = targets.filter(\.hasLocation).count
        if replaced > 0 {
            return String(
                localized: "Sets the place of \(AccessibilityText.items(targets.count)); \(replaced) of them had another one.",
                bundle: .module)
        }
        return String(localized: "Sets the place of \(AccessibilityText.items(targets.count)).", bundle: .module)
    }

    func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        results = ((try? await MKLocalSearch(request: request).start())?.mapItems ?? []).prefix(5).map { $0 }
    }

    func choose(_ item: MKMapItem) {
        let location = item.location.coordinate
        coordinate = location
        placeName = item.name
        results = []
        position = .region(MKCoordinateRegion(center: location, latitudinalMeters: 5000, longitudinalMeters: 5000))
    }
}
