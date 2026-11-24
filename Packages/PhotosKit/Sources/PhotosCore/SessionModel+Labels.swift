// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosDomain
import PhotosModel
import PhotosNetworking
import PhotosStore

/// Tags (SPEC §7.10), labels for the search index (SR-3), activity in shared albums (SH-9) and the progress of the first
/// sync. Everything here runs after a sync (`afterSync()`), throttled, and never holds the sync up.
extension SessionModel {
    static let labelsLogger = Logger(subsystem: "com.nextcloud.photos", category: "labels")

    /// How often shared albums are listed to notice new photos in them (seconds). The album listing is the expensive
    /// part of the Photos DAV tree, so this is not done on every sync.
    static let activityCheckInterval: TimeInterval = 15 * 60

    /// Work that follows a sync: tag and people memberships for search, and new photos in shared albums.
    func afterSync() async {
        guard services != nil, !isStopped, !afterSyncRunning else { return }
        afterSyncRunning = true
        defer { afterSyncRunning = false }
        await refreshLabelsIfDue()
        await checkSharedAlbumActivity()
        // After the labels: people come from them.
        await updateSpotlight()
        // Smart offline and the photo of the day follow the library (SPEC §15.8).
        await afterSyncExtras()
    }

    // MARK: Search labels

    /// Copies tag and people memberships into the search index when due (every 30 minutes; changed ones only).
    public func refreshLabelsIfDue() async {
        guard let services else { return }
        let tags = features.has(.systemtags)
        let people = features.has(.recognize)
        guard tags || people else { return }
        let sync = LabelSync(api: services.api, database: services.database)
        guard (try? sync.isDue()) == true else { return }
        let key = people ? await recognizeKey() : nil
        do {
            try await sync.refresh(tags: tags, people: people, peopleKey: key)
        } catch {
            Self.labelsLogger.error("label refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Tags

    /// The tags that can be given to photos: from the server, or the ones known locally when it cannot be reached.
    public func assignableTags() async -> (tags: [SystemTag], isOffline: Bool) {
        guard let services else { return ([], true) }
        do {
            let tags = try await services.api.allTags()
            return (tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, false)
        } catch {
            let local = (try? LabelStore(database: services.database).tags()) ?? []
            let assignable = local.filter { $0.isUserAssignable && $0.canAssign }
            return (assignable.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, true)
        }
    }

    /// How many of the items have each tag. For a small selection the server is asked (and the answer stored); for a
    /// large one, or offline, the local memberships answer.
    public func tagCounts(of items: [MediaItem]) async -> [Int: Int] {
        guard let services else { return [:] }
        let store = LabelStore(database: services.database)
        if items.count <= 20 {
            await withTaskGroup(of: (FileID, [SystemTag]?).self) { group in
                for item in items {
                    group.addTask { (item.fileId, try? await services.api.tags(of: item.fileId)) }
                }
                for await (fileId, tags) in group {
                    if let tags { try? store.setTags(tags, ofFile: fileId) }
                }
            }
        }
        let byFile = (try? store.tagIds(of: items.map(\.fileId))) ?? [:]
        var counts: [Int: Int] = [:]
        for ids in byFile.values {
            for id in ids { counts[id, default: 0] += 1 }
        }
        return counts
    }

    /// Gives the tag to the items that lack it (`assigned`), or takes it from those that have it. Optimistic, through the
    /// outbox: the search index has it at once, the server when the connection allows.
    public func setTag(_ tag: SystemTag, on items: [MediaItem], assigned: Bool) async {
        guard let services else { return }
        let current = (try? LabelStore(database: services.database).tagIds(of: items.map(\.fileId))) ?? [:]
        await enqueue(Self.tagOperations(tag, on: items, assigned: assigned, current: current))
    }

    /// One operation per item whose tag state differs from the wanted one.
    nonisolated static func tagOperations(_ tag: SystemTag, on items: [MediaItem], assigned: Bool, current: [FileID: Set<Int>])
        -> [PendingOperation]
    {
        items.compactMap { item in
            let has = current[item.fileId]?.contains(tag.id) ?? false
            guard has != assigned else { return nil }
            return .tag(TagChange(fileId: item.fileId, tagId: tag.id, tagName: tag.name, assign: assigned))
        }
    }

    /// Creates a tag on the server (needs a connection: the server gives it its id). An existing tag of that name is
    /// returned instead.
    public func createTag(named name: String) async throws -> SystemTag {
        guard let services else { throw NetworkError.unauthorized }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NetworkError.invalidResponse("empty tag name") }
        return try await services.api.createTag(trimmed)
    }

    /// The photos of a tag: from the server (and stored for search), or the indexed ones locally when offline.
    public func tagItems(_ tagId: Int) async throws -> [MediaItem] {
        guard let services else { return [] }
        let store = LabelStore(database: services.database)
        do {
            let items = try await services.api.tagContent(tagId)
            let known = (try? store.tags())?.first { $0.id == tagId }?.itemCount ?? -1
            try? store.setMembers(ofTag: tagId, Set(items.map(\.fileId)), serverCount: known)
            return items
        } catch let error as NetworkError where error == .offline || error == .timedOut {
            return try store.items(withTag: tagId)
        }
    }

    // MARK: Shared albums

    /// Lists the albums when that was not done for a while and announces what is new in shared albums with a notification
    /// when the app is not in front (SPEC SH-9). In front, the "New in shared albums" row shows it.
    func checkSharedAlbumActivity() async {
        guard let services, features.has(.photosDAV) else { return }
        let start = Date()
        do {
            try await refreshAlbums(maxAge: Self.activityCheckInterval)
        } catch {
            return
        }
        guard !ForegroundState.shared.isActive,
            let found = try? AlbumActivityStore(database: services.database).unseen(since: start), !found.isEmpty
        else { return }
        await SharedAlbumNotifications.post(found, account: account.id)
    }

    // MARK: First sync

    /// The number of photos and videos the first sync will find, where the server can tell cheaply: the day counts of
    /// the extended Photos API, kept per month as the timeline's skeleton. Stock servers have no count; the progress then
    /// shows what has arrived so far, and the timeline only what is loaded.
    public func loadInitialSyncTotal() async {
        guard initialSyncTotal == nil, features.has(.timelineDays), let services else { return }
        do {
            let days = try await services.api.timelineDays()
            let skeleton = TimelineSkeleton(days: days)
            let total = skeleton.total
            initialSyncSkeleton = skeleton
            initialSyncTotal = total
            Self.labelsLogger.info("first sync: the server counts \(total) items")
        } catch {
            if FeatureDetector.isMissingAPI(error) { featureUnavailable(.timelineDays) }
        }
    }
}
