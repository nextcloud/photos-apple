// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import SwiftUI

/// Settings › Organize: folder rules, smart albums and geotagging from a GPS track (SPEC §16.4).
struct OrganizeSettingsSection: View {
    @Environment(SessionModel.self) private var session
    @State private var geotagging = false

    var body: some View {
        Section {
            NavigationLink {
                FolderRulesScreen()
            } label: {
                LabeledContent {
                    Text(verbatim: "\(session.organize?.folderRules.filter(\.isEnabled).count ?? 0)")
                } label: {
                    Label(String(localized: "Folder Rules", bundle: .module), systemImage: "gearshape.2")
                }
            }
            NavigationLink {
                SmartAlbumsLibraryScreen()
            } label: {
                Label(String(localized: "Smart albums", bundle: .module), systemImage: "wand.and.stars")
            }
            Button {
                geotagging = true
            } label: {
                Label(
                    PlatformWording.title(
                        mac: LocalizedStringResource("Geotag Photos from a GPS Track…", bundle: .module),
                        other: LocalizedStringResource("Geotag photos from a GPS track…", bundle: .module)),
                    systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
            }
            .sheet(isPresented: $geotagging) { BatchFixSheet(items: [], mode: .track) }
        } header: {
            Text("Organize", bundle: .module)
        } footer: {
            Text("Folder rules and smart albums are kept in your Nextcloud, so all your devices share them.", bundle: .module)
        }
    }
}
