// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AppIntents
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore
import SwiftUI
import WidgetKit

// MARK: - Photo frame (SPEC §15.4)

/// A photo frame for the Home Screen, StandBy, the Mac's desktop and the walls around a Vision Pro: one photo after another
/// from the favourites, the memories, an album or the library.
struct PhotoFrameWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: AmbientKinds.photoFrame, intent: PhotoFrameConfiguration.self, provider: PhotoFrameProvider()) {
            entry in
            PhotoFrameView(entry: entry)
        }
        .configurationDisplayName(
            String(localized: "Photo Frame", comment: "Widget name: rotating photos for StandBy and the Home Screen.")
        )
        .description(String(localized: "Your photos, one after another. Made for StandBy.", comment: "Widget description."))
        .supportedFamilies(PhotoFrameWidget.families)
        // The photo is the widget: it stays where backgrounds are removed (StandBy).
        .containerBackgroundRemovable(false)
        .contentMarginsDisabled()
        #if os(visionOS)
            // On a wall: a print in a frame.
            .widgetTexture(.paper)
            .supportedMountingStyles([.elevated, .recessed])
        #endif
    }

    static var families: [WidgetFamily] {
        #if os(iOS)
            [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular]
        #else
            [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        #endif
    }
}

enum PhotoFrameSource: String, AppEnum {
    case favorites, memories, album, library

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Photos"
    static let caseDisplayRepresentations: [PhotoFrameSource: DisplayRepresentation] = [
        .favorites: "Favorites", .memories: "Memories", .album: "Album", .library: "Library",
    ]
}

enum PhotoFrameInterval: String, AppEnum {
    case quarterHour, hour, threeHours, day

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Change Photo"
    static let caseDisplayRepresentations: [PhotoFrameInterval: DisplayRepresentation] = [
        .quarterHour: "Every 15 Minutes", .hour: "Every Hour", .threeHours: "Every 3 Hours", .day: "Every Day",
    ]

    var seconds: TimeInterval {
        switch self {
        case .quarterHour: 15 * 60
        case .hour: 60 * 60
        case .threeHours: 3 * 60 * 60
        case .day: 24 * 60 * 60
        }
    }
}

/// An album of the active account, for the frame's configuration.
struct FrameAlbumEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Album"
    static let defaultQuery = FrameAlbumQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: "rectangle.stack"))
    }
}

struct FrameAlbumQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FrameAlbumEntity] {
        let known = Dictionary(albums().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { known[$0] }
    }

    func suggestedEntities() async throws -> [FrameAlbumEntity] { albums() }

    /// Own and shared albums of the active account, from its store. None with app lock on.
    func albums() -> [FrameAlbumEntity] {
        guard !AppLockSettings.isEnabled(), let store = PhotoFrameData.openStore() else { return [] }
        let collections = CollectionStore(database: store.database)
        let all = ((try? collections.albums(.own)) ?? []) + ((try? collections.albums(.shared)) ?? [])
        return all.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { FrameAlbumEntity(id: $0.id, title: $0.title) }
    }
}

struct PhotoFrameConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Photo Frame"
    static let description = IntentDescription("Choose the photos the frame shows and how often they change.")

    @Parameter(title: "Photos", default: .favorites) var source: PhotoFrameSource
    @Parameter(title: "Album") var album: FrameAlbumEntity?
    @Parameter(title: "Change Photo", default: .hour) var interval: PhotoFrameInterval
    @Parameter(title: "Shuffle", default: true) var shuffle: Bool
    /// Off: the photo is shown in StandBy and on the Lock Screen, which is what a photo frame is for. On: it is hidden until
    /// the device is unlocked, as the other widgets do.
    @Parameter(title: "Hide While Locked", default: false) var hideWhileLocked: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$source, .equalTo, .album) {
            Summary("Show \(\.$source) \(\.$album), \(\.$interval)") {
                \.$shuffle
                \.$hideWhileLocked
            }
        } otherwise: {
            Summary("Show \(\.$source), \(\.$interval)") {
                \.$shuffle
                \.$hideWhileLocked
            }
        }
    }

    var ambientSource: AmbientSource {
        switch source {
        case .favorites: .favorites
        case .memories: .memories
        case .library: .library
        case .album: album.map { .album(id: $0.id, title: $0.title) } ?? .favorites
        }
    }
}

struct PhotoFrameEntry: TimelineEntry {
    enum State: Equatable {
        case photo
        case locked
        case signedOut
        case empty
    }

    var date: Date
    var state: State
    var image: CGImage?
    var caption: String = ""
    var detail: String = ""
    var url: URL? = URL(string: "nextcloudphotos://library")
    var hideWhileLocked = false
    var sourceTitle: String = ""
}

struct PhotoFrameProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PhotoFrameEntry {
        PhotoFrameEntry(date: Date(), state: .empty, sourceTitle: String(localized: "Favorites"))
    }

    func snapshot(for configuration: PhotoFrameConfiguration, in context: Context) async -> PhotoFrameEntry {
        let entries = await PhotoFrameData.entries(configuration, family: context.family, size: context.displaySize, now: Date(), count: 1)
        return entries.first ?? placeholder(in: context)
    }

    func timeline(for configuration: PhotoFrameConfiguration, in context: Context) async -> Timeline<PhotoFrameEntry> {
        let now = Date()
        let count = PhotoFrameData.entryCount(context.family)
        let entries = await PhotoFrameData.entries(configuration, family: context.family, size: context.displaySize, now: now, count: count)
        guard let last = entries.last else {
            return Timeline(entries: [placeholder(in: context)], policy: .after(now.addingTimeInterval(3600)))
        }
        // The next timeline continues the rotation where this one ends.
        let next = last.state == .photo ? last.date.addingTimeInterval(configuration.interval.seconds) : now.addingTimeInterval(3600)
        return Timeline(entries: entries, policy: .after(next))
    }
}

/// Builds the frame's entries from the active account's store and preview cache in the App Group.
enum PhotoFrameData {
    /// A few photos per timeline: each is held decoded until WidgetKit has rendered it, and the extension's memory is small.
    static func entryCount(_ family: WidgetFamily) -> Int {
        if isAccessory(family) { return 6 }
        switch family {
        case .systemSmall: return 6
        case .systemMedium: return 4
        default: return 3
        }
    }

    /// The pixel size a photo is decoded to: what the widget shows on a Retina screen, at most 1200.
    static func pixelSize(_ family: WidgetFamily, size: CGSize) -> Int {
        if isAccessory(family) { return 240 }
        let points = max(size.width, size.height)
        return min(1200, max(400, Int(points * 3)))
    }

    /// The Lock Screen's rectangular widget (iPhone, iPad).
    static func isAccessory(_ family: WidgetFamily) -> Bool {
        #if os(iOS)
            family == .accessoryRectangular
        #else
            false
        #endif
    }

    static func openStore() -> (account: Account, database: AccountDatabase)? {
        guard let account = AccountRegistry.load().activeAccount,
            let database = try? AccountDatabase(url: AppPaths.database(account.id), readOnly: true)
        else { return nil }
        return (account, database)
    }

    static func entries(
        _ configuration: PhotoFrameConfiguration, family: WidgetFamily, size: CGSize, now: Date, count: Int
    ) async -> [PhotoFrameEntry] {
        let source = configuration.ambientSource
        let sourceTitle = configuration.source == .album ? (configuration.album?.title ?? "") : title(configuration.source)
        // With app lock on, nothing of the library is read.
        if AppLockSettings.isEnabled() {
            return [PhotoFrameEntry(date: now, state: .locked, sourceTitle: sourceTitle)]
        }
        guard let store = openStore() else {
            return [PhotoFrameEntry(date: now, state: .signedOut, sourceTitle: sourceTitle)]
        }
        let items =
            (try? await AmbientPhotos.items(
                source, library: LibraryStore(database: store.database), collections: CollectionStore(database: store.database), now: now))
            ?? []
        let seed = configuration.shuffle ? AmbientRotation.seed(source.key) : nil
        let schedule = AmbientRotation.timeline(
            now: now, interval: configuration.interval.seconds, count: count, itemCount: items.count, seed: seed)
        guard !schedule.isEmpty else {
            return [
                PhotoFrameEntry(
                    date: now, state: .empty, url: URL(string: "nextcloudphotos://library"), sourceTitle: sourceTitle)
            ]
        }
        let pixels = pixelSize(family, size: size)
        var downloads = 0
        var result: [PhotoFrameEntry] = []
        for slot in schedule {
            let item = items[slot.index]
            var image = cachedImage(item, account: store.account, pixels: pixels)
            // A few photos that are not in the cache yet are fetched; WidgetKit gives the extension little time.
            if image == nil, downloads < 2 {
                downloads += 1
                if await WidgetData.preview(item, account: store.account) != nil {
                    image = cachedImage(item, account: store.account, pixels: pixels)
                }
            }
            result.append(
                PhotoFrameEntry(
                    date: slot.date, state: .photo, image: image, caption: AmbientPhotos.caption(item),
                    detail: item.timestamp.formatted(date: .abbreviated, time: .omitted),
                    url: DeepLink.photo(fileId: item.fileId).url(for: store.account), hideWhileLocked: configuration.hideWhileLocked,
                    sourceTitle: sourceTitle))
        }
        return result
    }

    static func cachedImage(_ item: MediaItem, account: Account, pixels: Int) -> CGImage? {
        let cache = PreviewCache(directory: AppPaths.previews(account.id), memoryLimitBytes: 1)
        for bucket in pixels <= 256 ? [256, 1024] : [1024, 256] {
            if let image = cache.diskImage(fileId: item.fileId, etag: item.etag, bucket: bucket, maxPixelSize: pixels) { return image }
        }
        return nil
    }

    static func title(_ source: PhotoFrameSource) -> String {
        switch source {
        case .favorites: String(localized: "Favorites")
        case .memories: String(localized: "Memories")
        case .album: String(localized: "Album")
        case .library: String(localized: "Library")
        }
    }
}

struct PhotoFrameView: View {
    let entry: PhotoFrameEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// Hidden while the device is locked, when the frame is set so.
    var isHidden: Bool { entry.hideWhileLocked && redactionReasons.contains(.privacy) }

    var showsPhoto: Bool { entry.state == .photo && entry.image != nil && !isHidden }

    var body: some View {
        Group {
            if PhotoFrameData.isAccessory(family) {
                rectangular
            } else {
                frame
            }
        }
        .widgetURL(entry.url)
    }

    // The photo fills the widget; place and day sit on it, small, in the corner.
    var frame: some View {
        ZStack(alignment: .bottomLeading) {
            if !showsPhoto {
                message.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if renderingMode == .fullColor, !isLuminanceReduced, family != .systemSmall || entry.caption.count < 24 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.caption).font(.caption.weight(.semibold)).lineLimit(1)
                    if family != .systemSmall { Text(entry.detail).font(.caption2) }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 3)
                .padding(family == .systemSmall ? 10 : 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .containerBackground(for: .widget) {
            if showsPhoto, let image = entry.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .widgetAccentedRenderingMode(.accentedDesaturated)
                    .scaledToFill()
                    // A soft shade at the bottom keeps the caption readable on bright photos.
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                    }
                    // At night (StandBy) and on an always-on screen the photo is dimmed.
                    .overlay(Color.black.opacity(isLuminanceReduced ? 0.45 : 0))
            } else {
                Color.secondary.opacity(0.15)
            }
        }
    }

    @ViewBuilder var message: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2)
            Text(messageText).font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding()
    }

    var symbol: String {
        switch entry.state {
        case .locked: "lock.fill"
        case .signedOut: "person.crop.circle.badge.questionmark"
        case .empty: "photo.on.rectangle.angled"
        case .photo: isHidden ? "lock.fill" : "photo"
        }
    }

    var messageText: String {
        switch entry.state {
        case .locked: String(localized: "Locked")
        case .signedOut: String(localized: "Open the app to log in")
        case .empty:
            String(localized: "No photos in \(entry.sourceTitle) yet", comment: "Photo frame widget: the chosen source has no photos.")
        case .photo: isHidden ? String(localized: "Locked") : entry.caption
        }
    }

    /// The Lock Screen: a small picture next to its place and day.
    var rectangular: some View {
        HStack(spacing: 8) {
            if showsPhoto, let image = entry.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .widgetAccentedRenderingMode(.accentedDesaturated)
                    .scaledToFill()
                    .frame(width: 46, height: 46)
                    .clipShape(.rect(cornerRadius: 8))
                    .privacySensitive(entry.hideWhileLocked)
            } else {
                Image(systemName: symbol).font(.title3).frame(width: 46, height: 46)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.sourceTitle).font(.headline).widgetAccentable().lineLimit(1)
                if showsPhoto {
                    Text(entry.caption).font(.caption).lineLimit(1)
                    Text(entry.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(messageText).font(.caption).lineLimit(2)
                }
            }
            .privacySensitive(entry.hideWhileLocked)
            Spacer(minLength: 0)
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}
