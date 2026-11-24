// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import PhotosNetworking
import PhotosStore

/// Partner sharing (SPEC SH-8): folders other people shared with the user, shown in the user's timeline with a badge.
///
/// Uses only Nextcloud's normal sharing. The partner shares a folder (for example their backup folder); the user picks it
/// here. The app indexes it with the timeline folders and marks its photos; the server and the web app are not changed.
@MainActor
@Observable
public final class PartnerTimelineModel {
    public private(set) var settings: PartnerSettings
    /// Folders shared with the user that can be added (users and groups of this server; shares from other servers are
    /// not searchable on the server).
    public private(set) var candidates: [FileShare] = []
    public private(set) var loaded = false
    public private(set) var working = false
    public private(set) var error: String?
    @ObservationIgnored private let services: AccountServices
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "partner")

    init(services: AccountServices) {
        self.services = services
        settings = PartnerSettings.load(services.database)
    }

    public var hasPartners: Bool { !settings.folders.isEmpty }

    /// Folders to leave out of the timeline while partner photos are hidden.
    public var hiddenFolders: [String] { settings.showInTimeline ? [] : settings.folders.map(\.path) }

    /// The partner whose folder holds a photo, for the viewer and the badge's description.
    public func partner(containing path: String) -> PartnerFolder? { settings.partner(containing: path) }

    public func isIncluded(_ share: FileShare) -> Bool {
        settings.folders.contains { $0.path == Self.path(of: share) }
    }

    /// Where a received share is in the user's files.
    public static func path(of share: FileShare) -> String {
        share.path.isEmpty ? share.target : share.path
    }

    /// Reads the folders shared with the user.
    public func loadCandidates() async {
        do {
            candidates = Self.folderShares(try await services.api.sharing.sharedWithMe())
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// Received folder shares from people and groups of this server, one per folder, by owner name.
    static func folderShares(_ shares: [FileShare]) -> [FileShare] {
        var seen: Set<String> = []
        return
            shares
            .filter { $0.isFolder && ($0.kind == .user || $0.kind == .group || $0.kind == .team) }
            .filter { seen.insert(path(of: $0)).inserted }
            .sorted { $0.ownerDisplayName.localizedStandardCompare($1.ownerDisplayName) == .orderedAscending }
    }

    /// Adds a received folder to the timeline or removes it. Adding reads that folder's photos at once.
    public func setIncluded(_ share: FileShare, _ included: Bool) async {
        let path = Self.path(of: share)
        var folders = settings.folders.filter { $0.path != path }
        if included {
            folders.append(PartnerFolder(path: path, ownerId: share.ownerId, ownerDisplayName: share.ownerDisplayName))
        }
        await apply(folders)
    }

    /// Removes a partner folder that is no longer shared (or was moved).
    public func remove(_ folder: PartnerFolder) async {
        await apply(settings.folders.filter { $0.path != folder.path })
    }

    private func apply(_ folders: [PartnerFolder]) async {
        working = true
        defer { working = false }
        settings.folders = folders
        services.partnerPaths.set(folders.map(\.path))
        do {
            try await services.sync.setPartnerFolders(folders)
            error = nil
        } catch {
            logger.error("partner folders: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
        settings = PartnerSettings.load(services.database)
    }

    /// Shows or hides partner photos in the timeline (they stay indexed).
    public func setShownInTimeline(_ shown: Bool) {
        settings.showInTimeline = shown
        try? settings.save(services.database)
    }
}
