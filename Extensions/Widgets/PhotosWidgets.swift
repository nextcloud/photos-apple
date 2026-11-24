// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosMedia
import PhotosModel
import PhotosNetworking
import PhotosStore
import SwiftUI
import WidgetKit

/// Widgets: On this day and favourite photos (SPEC §7.22).
///
/// Privacy (SPEC §8): with app lock on they show a placeholder; on a locked device (lock screen, StandBy) the photo, place
/// and date are redacted; the app reloads them when an account is added, switched, removed or wiped, and when app lock
/// is switched.
@main
struct PhotosWidgets: WidgetBundle {
    var body: some Widget {
        OnThisDayWidget()
        FavoritesWidget()
    }
}

struct PhotoEntry: TimelineEntry {
    var date: Date
    var image: CGImage?
    var title: String
    var subtitle: String
    var destination: String
    /// App lock is on: the widget shows no photo, place or date (SPEC §8).
    var isLocked = false
}

/// Reads the active account's index and preview cache from the App Group; fetches a missing preview when it can.
enum WidgetData {
    static func entry(kind: String, now: Date) async -> PhotoEntry {
        // With app lock on, nothing of the library is read, let alone shown: the app reloads the widgets when the setting
        // changes.
        if AppLockSettings.isEnabled() {
            return PhotoEntry(
                date: now, image: nil, title: String(localized: "Nextcloud Photos"), subtitle: String(localized: "Locked"),
                destination: "library", isLocked: true)
        }
        let registry = AccountRegistry.load()
        guard let account = registry.activeAccount, let database = try? AccountDatabase(url: AppPaths.database(account.id), readOnly: true)
        else {
            return PhotoEntry(
                date: now, image: nil, title: String(localized: "Nextcloud Photos"), subtitle: String(localized: "Open the app to log in"),
                destination: "library")
        }
        let library = LibraryStore(database: database)
        let items: [MediaItem]
        if kind == "onThisDay" {
            items = (try? library.onThisDayItems(now: now)) ?? []
        } else {
            items = (try? library.favoriteImages()) ?? []
        }
        guard !items.isEmpty else {
            return PhotoEntry(
                date: now, image: nil, title: kind == "onThisDay" ? String(localized: "On this day") : String(localized: "Favorites"),
                subtitle: String(localized: "No photos yet"), destination: kind == "onThisDay" ? "onThisDay" : "favorites")
        }
        // Rotate through the items during the day.
        let index = Calendar.current.component(.hour, from: now) % items.count
        let item = items[index]
        let image = await preview(item, account: account)
        let years = Calendar.current.dateComponents([.year], from: item.timestamp, to: now).year ?? 0
        return PhotoEntry(
            date: now, image: image,
            title: kind == "onThisDay"
                ? String(localized: "\(years) years ago", comment: "Widget title; plural variations in the catalog.")
                : item.place ?? String(localized: "Favorites"),
            subtitle: item.timestamp.formatted(date: .abbreviated, time: .omitted),
            destination: kind == "onThisDay" ? "onThisDay" : "favorites")
    }

    static func preview(_ item: MediaItem, account: Account) async -> CGImage? {
        let cache = PreviewCache(directory: AppPaths.previews(account.id), memoryLimitBytes: 8 * 1024 * 1024)
        for bucket in [1024, 256] {
            if let image = cache.diskImage(fileId: item.fileId, etag: item.etag, bucket: bucket) { return image }
        }
        guard let password = Keychain().string(for: Keychain.passwordKey(account.id.rawValue)) else { return nil }
        let http = HTTPClient(trustStore: TrustStore(directory: AppPaths.certificates))
        let connection = ServerConnection(
            serverURL: account.serverURL, userId: account.userId, loginName: account.loginName, appPassword: password,
            userAgent: "Mozilla/5.0 (iOS) Nextcloud-Photos/widget")
        let api = PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
        guard let data = try? await api.preview(fileId: item.fileId, size: 1024, etag: item.etag) else { return nil }
        return cache.store(data, fileId: item.fileId, etag: item.etag, bucket: 1024)
    }
}

struct PhotoProvider: TimelineProvider {
    let kind: String

    func placeholder(in context: Context) -> PhotoEntry {
        PhotoEntry(date: Date(), image: nil, title: String(localized: "On this day"), subtitle: "", destination: "onThisDay")
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (PhotoEntry) -> Void) {
        Task { completion(await WidgetData.entry(kind: kind, now: Date())) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<PhotoEntry>) -> Void) {
        Task {
            let entry = await WidgetData.entry(kind: kind, now: Date())
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3600))))
        }
    }
}

struct PhotoWidgetView: View {
    let entry: PhotoEntry
    /// `.privacy` while the device is locked (lock screen, StandBy, iPad lock screen): the photo, place and date are left out.
    @Environment(\.redactionReasons) private var redactionReasons

    /// The photo is shown: there is one, app lock is off and the device is not locked.
    var showsPhoto: Bool { entry.image != nil && !entry.isLocked && !redactionReasons.contains(.privacy) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if !showsPhoto {
                Group {
                    if entry.isLocked || entry.image != nil {
                        Image(systemName: "lock.fill").font(.title2).accessibilityLabel(Text("Locked"))
                    } else {
                        Text(entry.subtitle).font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.headline).lineLimit(1)
                if showsPhoto { Text(entry.subtitle).font(.caption) }
            }
            // The place in the title and the date are private too.
            .privacySensitive(entry.image != nil)
            .foregroundStyle(showsPhoto ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .shadow(radius: showsPhoto ? 3 : 0)
            .padding(12)
        }
        .containerBackground(for: .widget) {
            if showsPhoto, let image = entry.image {
                Image(decorative: image, scale: 1).resizable().scaledToFill().privacySensitive()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .widgetURL(URL(string: "nextcloudphotos://\(entry.destination)"))
    }
}

struct OnThisDayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "onThisDay", provider: PhotoProvider(kind: "onThisDay")) { PhotoWidgetView(entry: $0) }
            .configurationDisplayName(String(localized: "On this day"))
            .description(String(localized: "Photos from this day in past years."))
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct FavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "favorites", provider: PhotoProvider(kind: "favorites")) { PhotoWidgetView(entry: $0) }
            .configurationDisplayName(String(localized: "Favorites"))
            .description(String(localized: "Your favourite photos."))
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
