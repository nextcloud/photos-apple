// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import SwiftUI

/// Places: the map of every geotagged photo and the places the server knows, one sidebar row (SPEC §19.1). A segmented
/// control switches between them and the choice is remembered; "Map" (Go menu, links, Shortcuts) opens the map. Without
/// the server's places (no Photos places support) Places is the map alone — it is made from the photos' GPS data on
/// this device.
struct PlacesHome: View {
    /// The mode asked for (`.map` for "Map"); nil: the one chosen last.
    var initialMode: PlacesMode?
    @Environment(SessionModel.self) private var session
    @AppStorage(PlacesMode.storageKey) private var storedMode: PlacesMode = .map
    @State private var chosen: PlacesMode?

    var hasList: Bool { session.features.has(.places) }

    var mode: PlacesMode {
        guard hasList else { return .map }
        return chosen ?? initialMode ?? storedMode
    }

    var body: some View {
        Group {
            switch mode {
            case .map: MapScreen(title: String(localized: "Places", bundle: .module))
            case .list: PlacesScreen(showsMapButton: false)
            }
        }
        .toolbar {
            if hasList {
                ToolbarItem(placement: .principal) { picker }
            }
        }
    }

    var picker: some View {
        Picker(
            selection: Binding<PlacesMode>(
                get: { mode },
                set: { (value: PlacesMode) in
                    chosen = value
                    storedMode = value
                })
        ) {
            Text("Map", bundle: .module).tag(PlacesMode.map)
            Text("Grid", bundle: .module, comment: "Places: the places as a grid of tiles (the other choice is Map).").tag(PlacesMode.list)
        } label: {
            Text("Show", bundle: .module)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help(String(localized: "Show the map or the places", bundle: .module, comment: "Places: tooltip of the Map / Grid switch."))
    }
}
