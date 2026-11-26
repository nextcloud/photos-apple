// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosDomain
import PhotosModel
import SwiftUI

// A link (widget, Shortcut, notification, another app) to a screen this server cannot fill — People without Recognize,
// Tags without the tags app, Recently Deleted without the trash bin — says so instead of doing nothing (SPEC §20.2).

extension AppDestination {
    /// The screen a link opens, as far as a server feature decides whether it can (albums, people, tags and the named
    /// destinations); `nil` for links that open something else (a photo, a folder, a search, a place).
    static func screen(of link: DeepLink) -> AppDestination? {
        switch link {
        case .destination(let raw): AppDestination(rawValue: raw)
        case .album(let id): id.hasPrefix("\(AlbumKind.shared.rawValue):") ? .sharedAlbums : .albums
        case .person: .people
        case .tag: .tags
        case .photo, .place, .folder, .search: nil
        }
    }

    /// The screen of a link that this server cannot show because it lacks the screen's feature, if so.
    static func unavailableScreen(of link: DeepLink, has: (ServerFeature) -> Bool) -> AppDestination? {
        guard let screen = screen(of: link), let feature = screen.requiredFeature, !has(feature) else { return nil }
        return screen
    }
}

extension View {
    /// Explains why a link to `screen` did not open (the server lacks what the screen needs).
    func unavailableLinkAlert(_ screen: Binding<AppDestination?>) -> some View {
        modifier(UnavailableLinkAlert(screen: screen))
    }
}

private struct UnavailableLinkAlert: ViewModifier {
    @Binding var screen: AppDestination?

    func body(content: Content) -> some View {
        let isPresented: Binding<Bool> = Binding(get: { screen != nil }, set: { if !$0 { screen = nil } })
        let title: String =
            screen.map {
                String(
                    localized: "\(String(localized: $0.title)) Isn't Available", bundle: .module,
                    comment: "Alert title when a link opens a screen the server cannot fill. Placeholder: the screen (People, Tags…).")
            } ?? ""
        let feature: String = screen?.requiredFeature?.localizedName ?? ""
        return content.alert(title, isPresented: isPresented) {
            Button(String(localized: "OK", bundle: .module)) { screen = nil }
        } message: {
            Text(
                String(
                    localized: "This needs “\(feature)” on your Nextcloud server. Your administrator can enable it.", bundle: .module,
                    comment:
                        "Alert text when a link opens a screen the server cannot fill. Placeholder: a server feature (Recognize (faces), Tags…)."
                ))
        }
    }
}
