// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosModel
import SwiftUI
import UIKit
import WidgetKit

/// The watch face complication and Smart Stack widget (SPEC §15.3): the photo of the day the iPhone sent. It reads the
/// watch app's App Group only; nothing is loaded from anywhere.
@main
struct PhotosWatchWidgets: WidgetBundle {
    var body: some Widget {
        PhotoOfTheDayComplication()
    }
}

struct PhotoOfTheDayEntry: TimelineEntry {
    var date: Date
    var image: UIImage?
    var title: String
    var place: String?
    var isLocked = false
}

struct PhotoOfTheDayProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhotoOfTheDayEntry {
        PhotoOfTheDayEntry(date: Date(), image: nil, title: String(localized: "Photo of the Day", comment: "Complication: title."))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (PhotoOfTheDayEntry) -> Void) {
        completion(Self.entry(now: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<PhotoOfTheDayEntry>) -> Void) {
        // The watch app reloads the timeline when the phone sends a new day; the next midnight as a fallback.
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
        let next = midnight ?? Date().addingTimeInterval(86_400)
        completion(Timeline(entries: [Self.entry(now: Date())], policy: .after(next)))
    }

    static var directory: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PhotosAppGroup") as? String,
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appending(path: WatchDigest.directoryName)
    }

    static func entry(now: Date) -> PhotoOfTheDayEntry {
        let title = String(localized: "Photo of the Day", comment: "Complication: title.")
        guard let directory, let data = try? Data(contentsOf: directory.appending(path: WatchDigest.fileName)),
            let digest = try? JSONDecoder().decode(WatchDigest.self, from: data)
        else { return PhotoOfTheDayEntry(date: now, image: nil, title: title) }
        if digest.isLocked { return PhotoOfTheDayEntry(date: now, image: nil, title: title, isLocked: true) }
        guard let photo = digest.photoOfTheDayEntry else { return PhotoOfTheDayEntry(date: now, image: nil, title: title) }
        let image = UIImage(contentsOfFile: directory.appending(path: photo.file).path(percentEncoded: false))
        let years = WatchDigest.yearsAgo(photo.date, day: digest.day)
        let when =
            years > 0
            ? String(localized: "\(years) years ago", comment: "Complication: how long ago the photo was taken; plural variations.")
            : photo.date.formatted(date: .abbreviated, time: .omitted)
        return PhotoOfTheDayEntry(date: now, image: image, title: when, place: photo.place)
    }
}

struct PhotoOfTheDayView: View {
    let entry: PhotoOfTheDayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label {
                Text(entry.place.map { "\(entry.title) · \($0)" } ?? entry.title)
            } icon: {
                Image(systemName: "photo")
            }
        case .accessoryCircular:
            photo
                .clipShape(.circle)
                .widgetLabel { Text(entry.title) }
        case .accessoryCorner:
            photo
                .clipShape(.circle)
                .widgetLabel { Text(entry.title) }
        default:
            HStack(spacing: 8) {
                photo
                    .frame(width: 52, height: 52)
                    .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Photo of the Day", comment: "Complication: title.")
                        .font(.caption2.bold())
                        .widgetAccentable()
                    Text(entry.title).font(.headline).lineLimit(1)
                    if let place = entry.place { Text(place).font(.caption2).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder var photo: some View {
        if let image = entry.image, !entry.isLocked {
            Image(uiImage: image)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .scaledToFill()
                .accessibilityLabel(Text(entry.title))
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: entry.isLocked ? "lock.fill" : "photo").font(.title3)
            }
        }
    }
}

struct PhotoOfTheDayComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "photoOfTheDay", provider: PhotoOfTheDayProvider()) { entry in
            PhotoOfTheDayView(entry: entry)
                .containerBackground(.clear, for: .widget)
                .widgetURL(URL(string: "nextcloudphotos://photoOfTheDay"))
        }
        .configurationDisplayName(String(localized: "Photo of the Day", comment: "Complication: name in the face editor."))
        .description(
            String(
                localized: "A photo from this day in earlier years or one of your favourites.",
                comment: "Complication: description in the face editor.")
        )
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}
