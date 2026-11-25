// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import PhotosDomain
import PhotosModel
import PhotosNetworking
import PhotosStore

/// The family library's options (SPEC §16.7.2), kept with the account.
public struct FamilyLibrarySettings: Codable, Hashable, Sendable {
    /// The shared folder the family's photos go into; nil while it is not set up.
    public var folder: SharedFolder?
    /// The family members: named people of Recognize.
    public var members: [String] = []
    /// Copy instead of move: the photos stay in the user's own folders too.
    public var copies = false

    public init(folder: SharedFolder? = nil, members: [String] = [], copies: Bool = false) {
        self.folder = folder
        self.members = members
        self.copies = copies
    }

    public var isSetUp: Bool { folder != nil }

    static let key = "family.settings"

    public static func load(_ database: AccountDatabase) -> FamilyLibrarySettings {
        guard let json = try? database.syncValue(key), let data = json.data(using: .utf8) else { return FamilyLibrarySettings() }
        return (try? JSONDecoder().decode(FamilyLibrarySettings.self, from: data)) ?? FamilyLibrarySettings()
    }

    func save(_ database: AccountDatabase) throws {
        try database.setSyncValue(Self.key, String(decoding: try JSONEncoder().encode(self), as: UTF8.self))
    }
}

/// Where a file goes in the family folder: its own name, or "name 2.jpg" when that is taken.
enum FamilyFileNames {
    static func destination(folder: String, name: String, attempt: Int) -> String {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        guard attempt > 1 else { return "\(base)/\(name)" }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base)/\(stem) \(attempt)" : "\(base)/\(stem) \(attempt).\(ext)"
    }
}

/// The family library (SPEC §16.7.2): suggests the user's own photos that belong in a shared family folder, and moves or
/// copies them there when the user says so. Never anything without the user's confirmation; what was moved, copied or
/// dismissed is not suggested again.
@MainActor
@Observable
public final class FamilyLibraryModel {
    public enum Action: Sendable {
        case move, copy
    }

    public private(set) var settings: FamilyLibrarySettings
    public private(set) var suggestions: [FamilySuggestion] = []
    public private(set) var isLoading = false
    public private(set) var error: String?
    /// Folders the family library can use, read when the setup is opened.
    public private(set) var folders: [SharedFolder] = []
    public private(set) var foldersLoaded = false
    /// Photos done of a move or copy that runs.
    public private(set) var progress: (done: Int, total: Int)?
    @ObservationIgnored private var refreshedAt: Date?
    @ObservationIgnored private let services: AccountServices
    @ObservationIgnored private let excludedFolders: @MainActor () -> [String]
    @ObservationIgnored private let mimeTypes: @MainActor () -> [String]
    @ObservationIgnored private let afterChange: @MainActor () async -> Void
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "family")

    init(
        services: AccountServices, excludedFolders: @escaping @MainActor () -> [String], mimeTypes: @escaping @MainActor () -> [String],
        afterChange: @escaping @MainActor () async -> Void
    ) {
        self.services = services
        self.excludedFolders = excludedFolders
        self.mimeTypes = mimeTypes
        self.afterChange = afterChange
        settings = FamilyLibrarySettings.load(services.database)
    }

    var store: FamilyStore { FamilyStore(database: services.database) }

    /// The first suggestion, for the card in Memories.
    public var topSuggestion: FamilySuggestion? { suggestions.first }

    /// The named people the user can pick as family.
    public func namedPeople() -> [Person] { (try? store.namedPeople()) ?? [] }

    // MARK: Setup

    public func loadFolders() async {
        do {
            folders = try await services.api.writableSharedFolders()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        foldersLoaded = true
    }

    /// Stores new options. Another folder starts over: what was decided for the old one does not hold for the new one.
    public func update(_ change: (inout FamilyLibrarySettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        if updated.folder?.path != settings.folder?.path { try? store.forgetDecisions() }
        settings = updated
        try? updated.save(services.database)
        suggestions = []
        refreshedAt = nil
        Task { await refresh(force: true) }
    }

    /// Turns the family library off; the folder and its photos stay as they are.
    public func turnOff() {
        update { $0 = FamilyLibrarySettings() }
    }

    /// Lets dismissed photos be suggested again.
    public func showDismissedAgain() {
        try? store.forgetDecisions()
        Task { await refresh(force: true) }
    }

    public var dismissedCount: Int { (try? store.decisionCount(.dismissed)) ?? 0 }

    // MARK: Suggestions

    /// Finds the suggestions again (at most every 30 minutes unless forced).
    public func refresh(force: Bool = false) async {
        guard let folder = settings.folder else {
            suggestions = []
            return
        }
        if !force, let refreshedAt, Date().timeIntervalSince(refreshedAt) < 1800 { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        refreshedAt = Date()
        do {
            // What the family folder has: its newest thousand photos tell the days and places the family shared.
            let page = try await services.api.indexPage(
                sourceFolders: [folder.path], mimeTypes: mimeTypes(), properties: DAVProp.mediaIndex, before: nil, limit: 1000)
            let moments = page.items.filter { !$0.isLivePhotoVideo }.map(FamilyFolderMoment.init)
            let calendar = Calendar.current
            let days = Set(moments.map { calendar.startOfDay(for: $0.timestamp) }).compactMap { calendar.dateInterval(of: .day, for: $0) }
            let candidates = try await store.candidates(
                members: settings.members, days: days, familyFolder: folder.path, excludedFolders: excludedFolders())
            let decided = try store.decidedFileIds()
            let members = Set(settings.members)
            suggestions = await Task.detached(priority: .userInitiated) {
                FamilySuggestions.suggestions(candidates: candidates, members: members, folder: moments, decided: decided)
            }.value
            error = nil
        } catch {
            logger.error("family suggestions: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    /// The photos of a suggestion, newest first (those still in the library).
    public func items(of suggestion: FamilySuggestion) -> [MediaItem] {
        suggestion.fileIds.compactMap { try? services.collections.mediaItem(fileId: $0) }
    }

    /// Never suggests these photos again.
    public func dismiss(_ fileIds: [FileID]) {
        try? store.record(.dismissed, for: fileIds)
        remove(fileIds)
    }

    /// Moves or copies photos into the family folder (their Live Photo motion parts along). Returns how many failed.
    @discardableResult
    public func apply(_ action: Action, to items: [MediaItem]) async -> Int {
        guard let folder = settings.folder, progress == nil else { return items.count }
        progress = (0, items.count)
        defer { progress = nil }
        let videos = (try? store.livePhotoVideos(of: items.map(\.fileId))) ?? [:]
        var done: [FileID] = []
        var failed = 0
        for item in items {
            do {
                let target = try await transfer(item, to: folder.path, action: action)
                if let video = videos[item.fileId] {
                    // The motion part keeps the photo's new name, with its own extension.
                    let stem = ((target as NSString).lastPathComponent as NSString).deletingPathExtension
                    let name = stem + "." + (video.name as NSString).pathExtension
                    _ = try? await transfer(video, to: folder.path, action: action, name: name)
                }
                done.append(item.fileId)
            } catch {
                failed += 1
                logger.error("family \(action == .move ? "move" : "copy"): \(error.localizedDescription, privacy: .public)")
            }
            progress = (done.count + failed, items.count)
        }
        try? store.record(action == .move ? .moved : .copied, for: done)
        remove(done)
        await afterChange()
        return failed
    }

    /// Moves or copies one file; a name that is taken in the folder gets a number. Returns the new path.
    func transfer(_ item: MediaItem, to folder: String, action: Action, name: String? = nil) async throws -> String {
        let name = name ?? item.name
        for attempt in 1...20 {
            let target = FamilyFileNames.destination(folder: folder, name: name, attempt: attempt)
            do {
                switch action {
                case .move:
                    try await services.dav.move(services.connection.filesURL(item.path), to: services.connection.filesURL(target))
                case .copy:
                    try await services.dav.copy(services.connection.filesURL(item.path), to: services.connection.filesURL(target))
                }
                return target
            } catch NetworkError.preconditionFailed {
                continue  // a file of that name is there
            }
        }
        throw NetworkError.conflict
    }

    private func remove(_ fileIds: [FileID]) {
        let gone = Set(fileIds)
        suggestions = suggestions.compactMap { suggestion in
            var changed = suggestion
            changed.fileIds.removeAll { gone.contains($0) }
            return changed.fileIds.isEmpty ? nil : changed
        }
    }
}
