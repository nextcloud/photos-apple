// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import TVServices

/// The Top Shelf of Nextcloud Photos on Apple TV (SPEC §15.3): the recent memories as a full-screen carousel with Play and
/// "Show Memory". It only reads what the app left in the App Group (`TopShelfManifest`): no account, password or network.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        completionHandler(Self.content())
    }

    /// The carousel of the memories in the manifest; nil (the app's static image) without any.
    static func content() -> (any TVTopShelfContent)? {
        guard let directory,
            let data = try? Data(contentsOf: directory.appending(path: TopShelfManifest.fileName)),
            let manifest = try? JSONDecoder().decode(TopShelfManifest.self, from: data), !manifest.items.isEmpty
        else { return nil }
        let items = manifest.items.map { entry in
            let item = TVTopShelfCarouselItem(identifier: entry.id)
            item.title = entry.title
            item.contextTitle = String(localized: "Memories", comment: "Top Shelf: small title above a memory in the carousel.")
            if let subtitle = entry.subtitle { item.summary = subtitle }
            item.setImageURL(directory.appending(path: entry.imageFile), for: [.screenScale1x, .screenScale2x])
            item.displayAction = TVTopShelfAction(url: entry.link)
            item.playAction = TVTopShelfAction(url: entry.playLink)
            return item
        }
        return TVTopShelfCarouselContent(style: .actions, items: items)
    }

    /// The Top Shelf's folder in the App Group the app shares with this extension.
    static var directory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PhotosAppGroup") as? String,
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appending(path: TopShelfManifest.directoryName)
    }
}
