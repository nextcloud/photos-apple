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
        guard let key = try? await services.api.fetchRecognizeKey(companionAPI: features.has(.recognizeKeyAPI)), !key.isEmpty else {
            return nil
        }
        var updated = features
        updated.recognizeAPIKey = key
        updated.recognizeAPIKeyDate = Date()
        setFeatures(updated)
        return key
    }

    func setFeatures(_ updated: ServerFeatures) {
        features = updated
        AccountServices.saveFeatures(updated, for: account.id, layout: services?.layout ?? AppPaths.layout)
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
            (try? await updateServerSmartAlbums({ list in
                if let index = list.firstIndex(where: { $0.id == album.id }) { list[index] = album } else { list.append(album) }
            })) != nil
        {
            return
        }
        // Without the server setting: shared by the user's devices through their Nextcloud (SPEC §16.4).
        if await saveSharedSmartAlbum(album) { return }
        let local = ((try? services?.collections.smartAlbums()) ?? []).filter(\.isLocal).map(\.0)
        try? services?.collections.replaceSmartAlbums(local + [album], isLocal: true)
    }

    public func deleteSmartAlbum(_ album: SmartAlbum) async {
        if features.userConfig.smartAlbums?.contains(where: { $0.id == album.id }) == true {
            try? await updateServerSmartAlbums { list in list.removeAll { $0.id == album.id } }
            return
        }
        let local = ((try? services?.collections.smartAlbums()) ?? []).filter(\.isLocal).map(\.0).filter { $0.id != album.id }
        try? services?.collections.replaceSmartAlbums(local, isLocal: true)
    }

    /// Changes the smart album list on the server.
    ///
    /// The server keeps the list as one value and the cached copy can be an hour old: the list is read again right
    /// before writing and the change (add, replace or remove one album, by id) is applied to that, so albums saved on
    /// another device in the meantime are not overwritten.
    func updateServerSmartAlbums(_ change: (inout [SmartAlbum]) -> Void) async throws {
        guard let services else { throw NetworkError.unauthorized }
        var albums = try await services.api.userConfig().smartAlbums ?? features.userConfig.smartAlbums ?? []
        change(&albums)
        let merged = albums
        try await setUserConfig(.smartAlbums) { $0.smartAlbums = merged }
    }
}
