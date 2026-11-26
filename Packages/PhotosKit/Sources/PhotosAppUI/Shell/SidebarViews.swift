// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// Up to two letters for an account's round badge: the first letters of the first two words of its name ("Frank
/// Karlitschek" → "FK", "admin" → "A", "jane.doe@example.com" → "JD"). Shared by the sidebar's account row and the
/// account button (SPEC §19.1, §19.2).
enum AccountInitials {
    /// The initials, or "" when the name has no letters (the account button then shows a person symbol).
    static func initials(of name: String) -> String {
        let words: [Substring] = name.split { (character: Character) in
            character.isWhitespace || character == "." || character == "_" || character == "-" || character == "@"
        }
        let letters: [Character] = words.prefix(2).compactMap { (word: Substring) in word.first(where: \.isLetter) }
        return String(letters).uppercased()
    }

    /// The initials, or "?" when the name has no letters (the sidebar's badge).
    static func of(_ name: String) -> String {
        let letters: String = initials(of: name)
        return letters.isEmpty ? "?" : letters
    }
}

/// A round badge with the account's initials, in the accent colour.
struct AccountBadge: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        Text(verbatim: AccountInitials.of(name))
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Design.accent.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

/// The accounts to switch to (the shown one with a check mark) and "Add account…".
struct AccountSwitchItems: View {
    @Binding var addingAccount: Bool
    @Environment(AppModel.self) private var app
    @Environment(SessionModel.self) private var session

    var body: some View {
        ForEach(app.accounts) { account in
            Button {
                app.switchTo(account.id)
            } label: {
                // A name and a server: nothing to translate.
                let title = "\(account.displayName) – \(account.hostDisplayName)"
                if account.id == session.account.id {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(verbatim: title)
                }
            }
        }
        if app.canAddAccount {
            Divider()
            Button(
                PlatformWording.title(
                    mac: LocalizedStringResource("Add Account…", bundle: .module),
                    other: LocalizedStringResource("Add account…", bundle: .module))
            ) {
                addingAccount = true
            }
        }
    }
}

#if os(macOS)
    /// What a row of the Mac sidebar stands for: a destination, or one of the albums listed under Albums.
    enum SidebarItem: Hashable {
        case destination(AppDestination)
        case album(String)
    }

    /// The compact account row at the bottom of the Mac sidebar (SPEC §19.1): the account's initials, name and server; a
    /// click opens a menu to switch or add an account and to open Settings — like the account button of Mail or Music.
    struct SidebarAccountButton: View {
        @Environment(SessionModel.self) private var session
        @State private var addingAccount = false

        var body: some View {
            Menu {
                AccountSwitchItems(addingAccount: $addingAccount)
                Divider()
                SettingsLink {
                    Text("Settings…", bundle: .module, comment: "Mac sidebar account menu: opens the Settings window.")
                }
            } label: {
                HStack(spacing: 8) {
                    AccountBadge(name: session.account.displayName, size: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.account.displayName).font(.callout.weight(.medium)).lineLimit(1)
                        Text(session.account.hostDisplayName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
                // One control, not one per badge and line of text.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    Text("Account \(session.account.displayName) on \(session.account.hostDisplayName)", bundle: .module))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityHint(
                Text(
                    "Switch or add an account, or open Settings", bundle: .module,
                    comment: "VoiceOver hint of the Mac sidebar's account button.")
            )
            .help(
                String(
                    localized: "Switch or add an account, or open Settings", bundle: .module,
                    comment: "VoiceOver hint of the Mac sidebar's account button.")
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .sheet(isPresented: $addingAccount) { AddAccountSheet() }
        }
    }

    /// The albums listed under Albums in the Mac sidebar (`SidebarAlbums`), each a row that opens the album (its menu pins
    /// it there or opens it in a window of its own), then "All Albums".
    struct SidebarAlbumRows: View {
        /// The ids of the listed albums, for the sidebar's highlight.
        @Binding var listed: [String]
        @Environment(SessionModel.self) private var session
        @AppStorage private var pinnedStored: String
        @State private var albums: [Album] = []
        @State private var used: [String] = []

        init(listed: Binding<[String]>, account: String) {
            _listed = listed
            _pinnedStored = AppStorage(wrappedValue: "", SidebarAlbums.storageKey(account: account))
        }

        var pinned: [String] { SidebarAlbums.decode(pinnedStored) }
        var shown: [Album] { SidebarAlbums.pick(albums, pinned: pinned, used: used) }

        var body: some View {
            ForEach(shown) { album in
                Label {
                    Text(album.title).lineLimit(1)
                } icon: {
                    Image(systemName: pinned.contains(album.id) ? "pin" : "rectangle.stack")
                }
                .tag(SidebarItem.album(album.id))
            }
            // "All Albums" ends the list; it carries the loading, which a list without albums would never start.
            Label(SidebarWording.allAlbums, systemImage: AppDestination.albums.systemImage)
                .tag(SidebarItem.destination(.albums))
                .onChange(of: shown.map(\.id), initial: true) { _, ids in listed = ids }
                .task(id: session.account.id) {
                    guard let services = session.services else { return }
                    used = RecentAlbumsStore.used(session.account.id)
                    // The sidebar lists albums before the Albums screen was opened once (at most every ten minutes).
                    Task { try? await session.refreshAlbums() }
                    do {
                        for try await value in services.collections.observeAlbums(.own) {
                            albums = value
                            // An album was just added to: it moves up.
                            used = RecentAlbumsStore.used(session.account.id)
                        }
                    } catch {}
                }
        }
    }

    /// The menu of an album listed under Albums: pin it there, or open it in a window of its own.
    struct SidebarAlbumMenu: View {
        let albumId: String
        @AppStorage private var pinnedStored: String
        @Environment(SessionModel.self) private var session
        @Environment(\.openWindow) private var openWindow

        init(albumId: String, account: String) {
            self.albumId = albumId
            _pinnedStored = AppStorage(wrappedValue: "", SidebarAlbums.storageKey(account: account))
        }

        var body: some View {
            let pinned = SidebarAlbums.decode(pinnedStored)
            Button(pinned.contains(albumId) ? SidebarWording.unpin : SidebarWording.pin) {
                pinnedStored = SidebarAlbums.encode(SidebarAlbums.toggling(albumId, in: pinned))
            }
            Button(String(localized: "Open in New Window", bundle: .module)) {
                openWindow(id: AlbumWindowValue.sceneId, value: AlbumWindowValue(account: session.account.id.rawValue, albumId: albumId))
            }
        }
    }

    /// View ▸ Edit Sidebar… and the rows' "Edit Sidebar…": the first group's rows in their order (drag to reorder), which
    /// rows are shown, pin and unpin, and Restore Defaults.
    struct EditSidebarSheet: View {
        @Binding var customization: SidebarCustomization
        /// What the server offers; rows it does not offer are not listed.
        let visible: (AppDestination) -> Bool
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(spacing: 0) {
                List {
                    Section {
                        ForEach(customization.pinned.filter(visible)) { row in
                            rowView(row)
                        }
                        .onMove { source, destination in move(source, to: destination) }
                    } header: {
                        Text("Pinned", bundle: .module, comment: "Edit Sidebar: the first group of rows, which the user can reorder.")
                    } footer: {
                        Text("Drag to change the order.", bundle: .module, comment: "Edit Sidebar: how to reorder the pinned rows.")
                    }
                    Section {
                        ForEach(SidebarLayout.albumRows(visible: visible)) { row in
                            rowView(row == .sharedWithYou ? .sharedAlbums : row, title: row.rowTitle)
                        }
                    } header: {
                        Text("Albums", bundle: .module)
                    }
                    Section {
                        ForEach(customization.utilities.filter(visible)) { row in
                            rowView(row)
                        }
                    } header: {
                        Text("Utilities", bundle: .module)
                    }
                }
                Divider()
                HStack {
                    Button(
                        String(localized: "Restore Defaults", bundle: .module, comment: "Edit Sidebar: back to the app's standard sidebar.")
                    ) {
                        customization = .standard
                    }
                    .disabled(customization.isStandard)
                    Spacer()
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
            }
            .frame(minWidth: 360, idealWidth: 380, minHeight: 480, idealHeight: 560)
            .navigationTitle(SidebarWording.editTitle)
        }

        /// Reorders the shown rows; rows the server does not offer keep their place at the end.
        func move(_ source: IndexSet, to destination: Int) {
            var reordered = customization.pinned.filter(visible)
            reordered.move(fromOffsets: source, toOffset: destination)
            let rest = customization.pinned.filter { !visible($0) }
            customization = SidebarCustomization(pinned: reordered + rest, hidden: customization.hidden)
        }

        func rowView(_ row: AppDestination, title: LocalizedStringResource? = nil) -> some View {
            HStack {
                Toggle(
                    isOn: Binding(
                        get: { !customization.isHidden(row) },
                        set: { shown in customization.setHidden(row, !shown) })
                ) {
                    Label(String(localized: title ?? row.rowTitle), systemImage: row.systemImage)
                }
                .disabled(!customization.canHide(row))
                Spacer()
                if customization.canUnpin(row) {
                    Button(SidebarWording.unpin) { customization.unpin(row) }
                        .buttonStyle(.link)
                } else if customization.canPin(row) {
                    Button(SidebarWording.pin) { customization.pin(row) }
                        .buttonStyle(.link)
                }
            }
        }
    }
#endif

/// Wording of the sidebar's editing (Mac: title case).
enum SidebarWording {
    static var pin: String {
        String(localized: "Pin", bundle: .module, comment: "Sidebar: move a row or album up to the pinned rows.")
    }

    static var unpin: String {
        String(
            localized: "Unpin", bundle: .module,
            comment: "Sidebar: move a pinned row back to Utilities, or an album off the top of the list.")
    }

    static var hide: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Hide from Sidebar", bundle: .module, comment: "Sidebar row menu: hide the row (Edit Sidebar shows it again)."),
            other: LocalizedStringResource(
                "Hide from sidebar", bundle: .module, comment: "Sidebar row menu: hide the row (Edit Sidebar shows it again)."))
    }

    static var editTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Edit Sidebar…", bundle: .module, comment: "Menu item: choose, order and pin the sidebar's rows."),
            other: LocalizedStringResource(
                "Edit sidebar…", bundle: .module, comment: "Menu item: choose, order and pin the sidebar's rows."))
    }

    static var restore: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Restore Default Sidebar", bundle: .module, comment: "Menu item: back to the app's standard sidebar rows."),
            other: LocalizedStringResource(
                "Restore default sidebar", bundle: .module, comment: "Menu item: back to the app's standard sidebar rows."))
    }

    static var allAlbums: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "All Albums", bundle: .module, comment: "Last row under Albums in the sidebar: the Albums screen."),
            other: LocalizedStringResource(
                "All albums", bundle: .module, comment: "Last row under Albums in the sidebar: the Albums screen."))
    }
}
