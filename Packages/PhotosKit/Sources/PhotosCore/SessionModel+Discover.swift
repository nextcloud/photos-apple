// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosNetworking

extension SessionModel {
    /// A valid Recognize API key (24 h), fetched when missing or old (SPEC PE-1). `nil` when the server needs none or offers none.
    public func recognizeKey() async -> String? {
        if let key = features.validRecognizeKey() { return key }
        guard let services, features.has(.recognize) else { return nil }
        guard let key = try? await services.api.fetchRecognizeKey(), !key.isEmpty else { return nil }
        var updated = features
        updated.recognizeAPIKey = key
        updated.recognizeAPIKeyDate = Date()
        setFeatures(updated)
        return key
    }

    func setFeatures(_ updated: ServerFeatures) {
        features = updated
        AccountServices.saveFeatures(updated, for: account.id)
    }
}

// MARK: Smart albums (SPEC SR-5)

extension SessionModel {
    /// Saved smart albums: from the server config when it exists there, else stored on this device.
    public func smartAlbums() -> [(SmartAlbum, isLocal: Bool)] {
        let server = (features.userConfig.smartAlbums ?? []).map { ($0, false) }
        let local = ((try? services?.collections.smartAlbums()) ?? []).filter(\.isLocal)
        return server + local
    }

    public func saveSmartAlbum(_ album: SmartAlbum) async {
        if features.userConfig.smartAlbums != nil,
            (try? await setUserConfig(.smartAlbums, { $0.smartAlbums = ($0.smartAlbums ?? []) + [album] })) != nil
        {
            return
        }
        let local = ((try? services?.collections.smartAlbums()) ?? []).filter(\.isLocal).map(\.0)
        try? services?.collections.replaceSmartAlbums(local + [album], isLocal: true)
    }

    public func deleteSmartAlbum(_ album: SmartAlbum) async {
        if features.userConfig.smartAlbums?.contains(where: { $0.id == album.id }) == true {
            try? await setUserConfig(.smartAlbums) { $0.smartAlbums?.removeAll { $0.id == album.id } }
            return
        }
        let local = ((try? services?.collections.smartAlbums()) ?? []).filter(\.isLocal).map(\.0).filter { $0.id != album.id }
        try? services?.collections.replaceSmartAlbums(local, isLocal: true)
    }
}
