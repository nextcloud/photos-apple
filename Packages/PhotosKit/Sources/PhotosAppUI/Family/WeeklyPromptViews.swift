// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

enum PromptWording {
    static var title: String {
        String(localized: "Weekly Photo Prompts", bundle: .module, comment: "Name of the weekly photo prompts feature.")
    }

    static var pastTitle: String { String(localized: "Past Prompts", bundle: .module, comment: "The history of weekly photo prompts.") }

    static func weekRange(_ prompt: WeeklyPrompt) -> String {
        let last = prompt.week.end.addingTimeInterval(-1)
        return (prompt.week.start..<last).formatted(.interval.day().month(.abbreviated))
    }

    static func added(_ count: Int) -> String {
        String(
            localized: "\(count) photos added", bundle: .module,
            comment: "Weekly prompt: how many of the week's photos are in its album. Plural variations in the catalog.")
    }
}

// MARK: - Card in Memories

/// This week's theme in Memories, with the photos added to it so far; or, while prompts are off, a small invitation.
struct WeeklyPromptCard: View {
    @Environment(SessionModel.self) private var session
    @AppStorage(WeeklyPromptSettings.enabledKey) private var enabled = false
    @AppStorage(WeeklyPromptSettings.invitationDismissedKey) private var invitationDismissed = false
    @State private var week: PromptWeek?
    @State private var thumbnails: [MediaItem] = []
    @State private var adding = false

    var body: some View {
        if enabled {
            let prompt = session.currentPrompt()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(
                        String(localized: "This Week's Prompt", bundle: .module, comment: "Heading of the weekly photo prompt card."),
                        systemImage: "camera.aperture"
                    )
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(PromptWording.weekRange(prompt)).font(.caption).foregroundStyle(.secondary)
                }
                Text(prompt.theme.title).font(.system(.largeTitle, design: .serif, weight: .bold))
                Text(prompt.theme.hint).font(.callout).foregroundStyle(.secondary)
                if !thumbnails.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(thumbnails.prefix(5)) { (item: MediaItem) in
                            PreviewImage(item: item, bucket: 256).aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 6))
                        }
                    }
                    .accessibilityHidden(true)
                    Text(PromptWording.added(week?.photosThisWeek ?? thumbnails.count)).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        adding = true
                    } label: {
                        Label(
                            String(
                                localized: "Add Photos", bundle: .module, comment: "Adds this week's photos to the weekly prompt's album."),
                            systemImage: "plus"
                        )
                        .fixedSize()
                    }
                    .buttonStyle(.borderedProminent)
                    if let album = week?.album {
                        NavigationLink {
                            AlbumDetailScreen(albumId: album.id, initial: album)
                        } label: {
                            Text("Open Album", bundle: .module, comment: "Opens the weekly prompt's album.").fixedSize()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                NavigationLink {
                    PromptHistoryScreen()
                } label: {
                    HStack(spacing: 4) {
                        Text(PromptWording.pastTitle)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.04)], startPoint: .topLeading,
                    endPoint: .bottomTrailing),
                in: .rect(cornerRadius: 16)
            )
            .sheet(isPresented: $adding, onDismiss: { Task { await load(prompt) } }) { PromptPhotoPicker(prompt: prompt) }
            .task(id: prompt.id) { await load(prompt) }
        } else if !invitationDismissed {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "camera.aperture").font(.title).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(PromptWording.title).font(.headline)
                    Text(
                        "A new theme every week — reflections, something blue, hands… Your photos of it go into an album of their own.",
                        bundle: .module, comment: "Invitation to turn on weekly photo prompts, in Memories."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    Button(
                        String(
                            localized: "Turn On", bundle: .module, comment: "Turns on weekly photo prompts from the invitation in Memories."
                        )
                    ) {
                        WeeklyPromptSettings.setEnabled(true)
                        enabled = true
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                Button {
                    invitationDismissed = true
                } label: {
                    // A target of 44 points around the small cross (SPEC §20.3).
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(-10)
                .accessibilityLabel(Text("Not now", bundle: .module, comment: "Hides the weekly prompts invitation."))
            }
            .padding()
            .background(.background.secondary, in: .rect(cornerRadius: 16))
        }
    }

    func load(_ prompt: WeeklyPrompt) async {
        try? await session.refreshAlbums()
        let week = session.promptWeek(prompt)
        self.week = week
        guard let album = week.album, let services = session.services else {
            thumbnails = []
            return
        }
        try? await session.refreshAlbumContent(album)
        self.week = session.promptWeek(prompt)
        thumbnails = ((try? await services.collections.albumMedia(albumId: album.id)) ?? []).filter { prompt.week.contains($0.timestamp) }
    }
}

// MARK: - Adding photos

/// The photos taken this week; the chosen ones go into the prompt's album.
struct PromptPhotoPicker: View {
    let prompt: WeeklyPrompt
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var photos: [MediaItem] = []
    @State private var inAlbum: Set<FileID> = []
    @State private var chosen: Set<FileID> = []
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(prompt.theme.hint).foregroundStyle(.secondary)
                    if loaded && photos.isEmpty {
                        ContentUnavailableView(
                            String(
                                localized: "No Photos This Week Yet", bundle: .module, comment: "Weekly prompt: no photos taken this week."),
                            systemImage: "camera",
                            description: Text(
                                "Photos you take this week appear here once they are in your Nextcloud.", bundle: .module,
                                comment: "Weekly prompt: empty state."))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90, maximum: 140), spacing: 3)], spacing: 3) {
                        ForEach(photos) { (item: MediaItem) in tile(item) }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                .padding()
            }
            .navigationTitle(prompt.theme.title)
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(String(localized: "Add", bundle: .module)) { Task { await save() } }.disabled(chosen.isEmpty)
                    }
                }
            }
            .task {
                photos = await session.photosForPrompt(prompt)
                if let album = session.promptAlbum(prompt) {
                    inAlbum = Set(((try? session.services?.collections.albumItems(albumId: album.id)) ?? []).map(\.fileId))
                }
                loaded = true
            }
        }
        #if os(macOS)
            .frame(minWidth: 520, minHeight: 480)
        #endif
    }

    func tile(_ item: MediaItem) -> some View {
        let added = inAlbum.contains(item.fileId)
        let selected = chosen.contains(item.fileId)
        return Button {
            if selected { chosen.remove(item.fileId) } else { chosen.insert(item.fileId) }
        } label: {
            PreviewImage(item: item, bucket: 256)
                .aspectRatio(1, contentMode: .fit)
                .opacity(added ? 0.45 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if added || selected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, added ? Color.gray : Color.accentColor)
                            .font(.title3).padding(4)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(added)
        .accessibilityLabel(
            AccessibilityText.media(isVideo: item.kind == .video, isLivePhoto: item.isLivePhoto, date: item.timestamp, place: item.place)
        )
        .accessibilityAddTraits(selected || added ? .isSelected : [])
    }

    func save() async {
        saving = true
        defer { saving = false }
        do {
            try await session.addToPrompt(photos.filter { chosen.contains($0.fileId) }, prompt: prompt)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - History

struct PromptHistoryScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var weeks: [PromptWeek] = []

    var body: some View {
        List {
            if weeks.isEmpty {
                Text("Past weeks' prompts appear here.", bundle: .module, comment: "Weekly prompt history: empty.").foregroundStyle(
                    .secondary)
            }
            ForEach(weeks) { (week: PromptWeek) in
                if let album = week.album {
                    NavigationLink {
                        AlbumDetailScreen(albumId: album.id, initial: album)
                    } label: {
                        row(week)
                    }
                } else {
                    row(week)
                }
            }
        }
        .navigationTitle(PromptWording.pastTitle)
        .task {
            try? await session.refreshAlbums()
            weeks = session.promptHistory()
        }
    }

    func row(_ week: PromptWeek) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(week.prompt.theme.title).font(.headline)
                Text(PromptWording.weekRange(week.prompt)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if week.photosThisWeek > 0 {
                Text(PromptWording.added(week.photosThisWeek)).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Skipped", bundle: .module, comment: "Weekly prompt history: no photos were added that week.").font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Settings

/// Settings › Weekly Photo Prompts: on/off (off by default), the reminder (off by default), the history.
struct WeeklyPromptSettingsSection: View {
    @Environment(SessionModel.self) private var session
    @AppStorage(WeeklyPromptSettings.enabledKey) private var enabled = false
    @AppStorage(WeeklyPromptSettings.remindersKey) private var reminders = false
    @State private var denied = false

    var body: some View {
        Section {
            Toggle(PromptWording.title, isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    WeeklyPromptSettings.setEnabled(on)
                    Task { await session.weeklyPromptSettingsChanged() }
                }
            if enabled {
                Toggle(
                    String(
                        localized: "Weekend Reminder", bundle: .module, comment: "Switch for the weekly photo prompt reminder notification."
                    ), isOn: $reminders
                )
                .onChange(of: reminders) { _, on in
                    Task {
                        if on, !(await PhotoOfTheDayNotifications.requestAuthorization()) {
                            denied = true
                            reminders = false
                        }
                        await session.weeklyPromptSettingsChanged()
                    }
                }
                SettingsPageLink {
                    PromptHistoryScreen()
                } label: {
                    Text(PromptWording.pastTitle)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "A theme for each week in Memories. Photos you add go into an album named after the theme. The reminder comes once, two days before the week ends, unless you added photos already.",
                    bundle: .module, comment: "Settings: footer of the weekly photo prompts.")
                if denied {
                    Text("Notifications are turned off for Nextcloud Photos in System Settings.", bundle: .module).foregroundStyle(.red)
                }
            }
        }
    }
}
