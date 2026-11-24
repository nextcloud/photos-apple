// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosBackup
import PhotosStore

/// Mirroring device albums into Nextcloud albums (SPEC §7.18.9). The options live in the backup account's database, so
/// they go with the account; the mirror runs after each backup pass.
extension BackupModel {
    /// The mirror options of the backup account; nil while no backup account is available.
    public func albumMirrorSettings() -> AlbumMirrorSettings? {
        guard let account, let services = services(for: account) else { return nil }
        return AlbumMirrorSettings.load(services.database)
    }

    /// Stores the options and, when the mirror is on, mirrors the albums now (the photos already backed up).
    public func setAlbumMirror(_ settings: AlbumMirrorSettings) {
        guard let account, let services = services(for: account) else { return }
        try? settings.save(services.database)
        guard settings.isEnabled, self.settings.isEnabled, !isPassRunning else { return }
        Task { await mirrorAlbums() }
    }

    /// Adds what the last pass backed up to the Nextcloud albums of the picked device albums. Best effort: a failure is
    /// logged, and the next pass tries again.
    func mirrorAlbums() async {
        guard let account, let services = services(for: account) else { return }
        guard AlbumMirrorSettings.load(services.database).isEnabled else { return }
        let logger = Logger(subsystem: "com.nextcloud.photos", category: "backup")
        do {
            let result = try await AlbumMirror.run(api: services.api, database: services.database)
            if result.added > 0 || result.failed > 0 {
                logger.info("album mirror: \(result.added) added, \(result.albumsCreated) albums created, \(result.failed) failed")
            }
        } catch {
            logger.error("album mirror: \(error.localizedDescription, privacy: .public)")
        }
    }
}
