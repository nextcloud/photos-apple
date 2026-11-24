// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosModel
import SwiftUI

/// Nextcloud Photos on Apple Watch (SPEC §15.3): the photo of the day, this day in earlier years and favourites, sent by
/// the iPhone app. Small on purpose: a glance at a memory, not a library.
@main
struct NextcloudPhotosWatchApp: App {
    @State private var store = WatchStore.shared

    init() {
        WatchStore.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environment(store)
        }
    }
}

struct WatchHomeView: View {
    @Environment(WatchStore.self) private var store
    @State private var page = WatchHomeView.initialPage

    /// The first page; DEBUG builds take `PHOTOS_DEBUG_WATCH_PAGE` (0 photo of the day, 1 On this day, 2 favourites) for
    /// screenshots.
    static var initialPage: Int {
        #if DEBUG
            Int(ProcessInfo.processInfo.environment["PHOTOS_DEBUG_WATCH_PAGE"] ?? "") ?? 0
        #else
            0
        #endif
    }

    var body: some View {
        NavigationStack {
            if let digest = store.digest, !digest.isLocked, !digest.photos.isEmpty {
                TabView(selection: $page) {
                    if let photo = digest.photoOfTheDayEntry {
                        WatchPhotoOfTheDay(photo: photo, digest: digest).tag(0)
                    }
                    let today = digest.photos(in: .onThisDay)
                    if !today.isEmpty {
                        WatchPhotoGrid(title: onThisDayTitle(digest), photos: today).tag(1)
                    }
                    let favorites = digest.photos(in: .favorites)
                    if !favorites.isEmpty {
                        let title = String(localized: "Favorites", comment: "Watch: title of the favourites page.")
                        WatchPhotoGrid(title: title, photos: favorites).tag(2)
                    }
                }
                .tabViewStyle(.verticalPage)
            } else {
                WatchEmptyView(isLocked: store.digest?.isLocked == true)
            }
        }
    }

    func onThisDayTitle(_ digest: WatchDigest) -> String {
        digest.onThisDayTitle
            ?? String(localized: "On This Day", comment: "Watch: title of the page with photos of this day in earlier years.")
    }
}

/// The photo of the day, full screen, with where and when.
struct WatchPhotoOfTheDay: View {
    let photo: WatchDigest.Photo
    let digest: WatchDigest

    var body: some View {
        NavigationLink {
            WatchPhotoPager(photos: digest.photos, selection: photo.id)
        } label: {
            WatchPhotoImage(photo: photo)
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Photo of the Day", comment: "Watch: caption of the photo chosen for today.")
                            .font(.caption2.bold())
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.85))
                        Text(WatchText.yearsAgo(photo.date, day: digest.day))
                            .font(.headline)
                        if let place = photo.place {
                            Text(place).font(.caption2).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 6)
                    .padding(10)
                }
                .clipShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .containerBackground(.black.gradient, for: .tabView)
    }
}

/// A page of thumbnails; a tap opens them one by one.
struct WatchPhotoGrid: View {
    let title: String
    let photos: [WatchDigest.Photo]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(photos) { photo in
                    NavigationLink {
                        WatchPhotoPager(photos: photos, selection: photo.id)
                    } label: {
                        WatchPhotoImage(photo: photo)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(title)
        .containerBackground(.indigo.gradient, for: .tabView)
    }
}

/// Photos one at a time: swipe or turn the Digital Crown.
struct WatchPhotoPager: View {
    let photos: [WatchDigest.Photo]
    @State var selection: FileID

    var body: some View {
        TabView(selection: $selection) {
            ForEach(photos) { photo in
                WatchPhotoImage(photo: photo, contentMode: .fit)
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 0) {
                            Text(photo.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2.bold())
                            if let place = photo.place { Text(place).font(.caption2).lineLimit(1) }
                        }
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 4)
                        .padding(.bottom, 4)
                    }
                    .tag(photo.id)
            }
        }
        .tabViewStyle(.verticalPage)
        .ignoresSafeArea(edges: .bottom)
    }
}

/// A photo the phone sent, or a placeholder while it is still on its way.
struct WatchPhotoImage: View {
    let photo: WatchDigest.Photo
    var contentMode = ContentMode.fill
    @Environment(WatchStore.self) private var store

    var body: some View {
        // Read again when files arrive.
        let _ = store.filesVersion
        GeometryReader { proxy in
            if let url = store.image(for: photo), let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else {
                Rectangle().fill(.gray.opacity(0.3))
                    .overlay { ProgressView() }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(WatchText.label(photo))
    }
}

struct WatchEmptyView: View {
    var isLocked: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isLocked ? "lock.fill" : "iphone")
                .font(.title2)
                .foregroundStyle(.tint)
            if isLocked {
                Text("Nextcloud Photos is locked on your iPhone.", comment: "Watch: app lock is on in the iPhone app; nothing is shown.")
            } else {
                Text(
                    "Open Nextcloud Photos on your iPhone: today's photos appear here.",
                    comment: "Watch: shown before the iPhone has sent any photos.")
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .padding()
    }
}

enum WatchText {
    /// "3 years ago" for a photo of this day in an earlier year, else its date.
    static func yearsAgo(_ date: Date, day: Date) -> String {
        let years = WatchDigest.yearsAgo(date, day: day)
        guard years > 0 else { return date.formatted(date: .abbreviated, time: .omitted) }
        return String(localized: "\(years) years ago", comment: "Watch: how long ago the photo of the day was taken; plural variations.")
    }

    static func label(_ photo: WatchDigest.Photo) -> Text {
        let date = photo.date.formatted(date: .long, time: .omitted)
        if let place = photo.place {
            return Text("Photo, \(date), \(place)", comment: "Watch: VoiceOver label of a photo; placeholders: date, place.")
        }
        return Text("Photo, \(date)", comment: "Watch: VoiceOver label of a photo; the placeholder is its date.")
    }
}
