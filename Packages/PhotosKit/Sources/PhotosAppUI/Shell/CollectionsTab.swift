// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosBackup
import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// Navigation where there is only a tab bar (iPhone, narrow iPad windows; SPEC §6.2): Library, Collections and Search
/// are tabs, every other place is in the Collections tab and pushed in its stack, and Settings is a sheet from the
/// account button (SPEC §19.2).
///
/// The app's navigation state stays what it is everywhere — the selected destination and its path. These functions
/// translate between that state and the Collections tab's stack.
enum CompactNavigation {
    /// A shelf of the Collections tab (SPEC §20.4): a title that opens the place, and its covers in a row.
    enum Shelf: Hashable, Identifiable {
        case albums, memories, people, places, shared

        var id: Self { self }
    }

    /// Destinations with a tab of their own.
    static let tabs: [AppDestination] = [.library, .collections, .search]

    /// Destinations shown as a sheet over the window instead of a tab or a row (the account button opens them).
    static let sheets: Set<AppDestination> = [.settings]

    /// An iPhone never has a sidebar, whatever its size class (a large iPhone is "regular" in landscape); an iPad
    /// has none while its window is narrow.
    static func usesCollectionsTab(isPhone: Bool, isCompact: Bool) -> Bool {
        isPhone || isCompact
    }

    /// The tab that is selected while `destination` is shown.
    static func tab(for destination: AppDestination) -> AppDestination {
        tabs.contains(destination) ? destination : .collections
    }

    /// The Collections tab itself or a place that is reached through it.
    static func isInCollectionsTab(_ destination: AppDestination) -> Bool {
        tab(for: destination) == .collections
    }

    /// The Collections stack while `destination` is shown with `routes` open in it: the tab's overview is the root,
    /// the destination the first screen pushed on it. An album, person or place opened from a shelf of the overview is
    /// pushed on the overview itself (`destination` is `.collections` then).
    static func path(to destination: AppDestination, routes: [AppRoute]) -> [AppRoute] {
        guard isInCollectionsTab(destination) else { return [] }
        if destination == .collections { return routes }
        return [.destination(destination.rawValue)] + routes
    }

    /// What a path of the Collections stack shows: the destination and what is open in it. A path that starts with an
    /// album, a person… was opened from a shelf of the overview. Nil for a path the stack cannot have (a destination
    /// with a tab of its own, or one the app does not know).
    static func place(of path: [AppRoute]) -> (destination: AppDestination, routes: [AppRoute])? {
        guard let first = path.first else { return (.collections, []) }
        guard case .destination(let raw) = first else { return (.collections, path) }
        guard let destination = AppDestination(rawValue: raw), destination != .collections, isInCollectionsTab(destination)
        else { return nil }
        return (destination, Array(path.dropFirst()))
    }

    /// The shelves of the overview, in this order: albums (with Favorites), memories, people, places, shared. `visible`
    /// says what the server offers. Albums are always there: without the server's albums the shelf is Favorites alone.
    static func shelves(visible: (AppDestination) -> Bool) -> [Shelf] {
        var shelves: [Shelf] = [.albums, .memories]
        if visible(.people) { shelves.append(.people) }
        if visible(.places) { shelves.append(.places) }
        if sharedRow(visible: visible) != nil { shelves.append(.shared) }
        return shelves
    }

    /// The place a shelf's title opens.
    static func destination(of shelf: Shelf, visible: (AppDestination) -> Bool) -> AppDestination {
        switch shelf {
        case .albums: visible(.albums) ? .albums : .favorites
        case .memories: .memories
        case .people: .people
        case .places: .places
        case .shared: sharedRow(visible: visible) ?? .sharedWithYou
        }
    }

    /// Shared albums, or "Shared with you" alone where the server has no shared albums (as in the sidebar, SPEC §19.1).
    static func sharedRow(visible: (AppDestination) -> Bool) -> AppDestination? {
        SidebarLayout.albumRows(visible: visible).first { $0 != .albums }
    }

    /// The compact list under the shelves: the sidebar's Utilities and Backup. `listed` says what the server offers and
    /// what the Advanced features switch shows (SPEC §20.4).
    static func utilities(listed: (AppDestination) -> Bool) -> [AppDestination] {
        (SidebarLayout.utilities + [.backup]).filter(listed)
    }

    /// Every place the overview leads to, for the tests: the shelves' titles, Favorites and the utilities.
    static func reachable(visible: (AppDestination) -> Bool, listed: (AppDestination) -> Bool) -> Set<AppDestination> {
        var result = Set(shelves(visible: visible).map { destination(of: $0, visible: visible) })
        result.insert(.favorites)
        result.formUnion(utilities(listed: listed))
        return result
    }
}

/// The short backup state next to the Backup row.
enum BackupRowStatus {
    static func text(isAvailable: Bool, isEnabled: Bool, status: BackupStatus) -> String? {
        guard isAvailable else { return nil }
        guard isEnabled else { return String(localized: "Off", bundle: .module) }
        switch status.phase {
        case .uploading(let done, let total, _):
            return String(localized: "\(done) of \(total)", bundle: .module, comment: "Backup progress: uploaded files of all files.")
        case .scanning, .reconciling: return String(localized: "Checking…", bundle: .module)
        case .paused: return String(localized: "Paused", bundle: .module)
        case .failed, .notAuthorized, .incomplete: return String(localized: "Needs attention", bundle: .module)
        case .upToDate: return String(localized: "Up to date", bundle: .module)
        case .idle:
            return status.pending > 0
                ? String(localized: "\(status.pending) waiting", bundle: .module) : String(localized: "On", bundle: .module)
        }
    }
}

#if !os(macOS)
    /// Root of the Collections tab (SPEC §20.4): shelves of covers — albums, memories, people, places, shared — like a
    /// photo app, then a compact list of the utilities. Each shelf's title opens the whole place.
    struct CollectionsList: View {
        @Environment(SessionModel.self) private var session
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @AppStorage(AdvancedFeatures.storageKey) private var advancedFeatures = AdvancedFeatures.defaultValue
        /// Kept while the tab is alive, so the covers are there at once when the user comes back.
        @State private var model = CollectionsOverviewModel()

        func visible(_ destination: AppDestination) -> Bool {
            guard let feature = destination.requiredFeature else { return true }
            return session.features.has(feature)
        }

        func listed(_ destination: AppDestination) -> Bool {
            visible(destination) && AdvancedFeatures.lists(destination, isOn: advancedFeatures)
        }

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(CompactNavigation.shelves(visible: visible)) { (shelf: CompactNavigation.Shelf) in
                        CollectionsShelfView(
                            shelf: shelf, destination: CompactNavigation.destination(of: shelf, visible: visible),
                            showsAlbums: visible(.albums), model: model)
                    }
                    utilities
                }
                .padding(.vertical, 12)
            }
            .navigationTitle(String(localized: "Collections", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .primaryAction) { CollectionsAddMenu() }
                ToolbarItem(placement: AccountMenuButton.placement) { AccountMenuButton() }
            }
            .task(id: CollectionsOverview.LoadKey(session.syncStatus, account: session.account.id.rawValue)) {
                await model.load(session: session, people: visible(.people))
            }
            .task(id: session.account.id.rawValue) { await model.observeAlbums(session: session) }
        }

        /// The places without a shelf, as compact rows (SPEC §19.1's Utilities, and Backup).
        var utilities: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Utilities", bundle: .module)
                    .font(Typography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal)
                VStack(spacing: 0) {
                    let rows: [AppDestination] = CompactNavigation.utilities(listed: listed)
                    ForEach(rows) { (destination: AppDestination) in
                        // By value: the stack's path (MainView) knows which place is open.
                        NavigationLink(value: AppRoute.destination(destination.rawValue)) {
                            row(destination)
                                .padding(.horizontal)
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if destination != rows.last {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
        }

        func row(_ destination: AppDestination) -> some View {
            HStack(spacing: 12) {
                // While the backup runs its icon breathes (SPEC §17.3).
                let running: Bool = destination == .backup && session.backup.status.isRunning
                Image(systemName: destination.systemImage)
                    .symbolEffect(.breathe.pulse.byLayer, options: .repeat(.continuous), isActive: running && !reduceMotion)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                Text(destination.rowTitle)
                Spacer(minLength: 8)
                if destination == .backup, let status = backupStatus {
                    Text(status).foregroundStyle(.secondary)
                        .rollingNumber(BackupStatusSymbol.progressValue(session.backup.status.phase))
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
        }

        var backupStatus: String? {
            let backup = session.backup
            return BackupRowStatus.text(isAvailable: backup.isAvailable, isEnabled: backup.settings.isEnabled, status: backup.status)
        }
    }

    /// The Collections tab's "+": a new album, or an upload (SPEC §19.2).
    struct CollectionsAddMenu: View {
        @Environment(SessionModel.self) private var session
        @State private var creatingAlbum = false
        @State private var upload: UploadStart?

        var body: some View {
            Menu {
                if session.features.has(.photosDAV) {
                    Button {
                        creatingAlbum = true
                    } label: {
                        Label(String(localized: "New album…", bundle: .module), systemImage: "rectangle.stack.badge.plus")
                    }
                }
                Menu {
                    UploadMenuItems { (start: UploadStart) in upload = start }
                } label: {
                    Label(UploadStart.menuTitle, systemImage: UploadStart.systemImage)
                }
            } label: {
                Label(
                    String(localized: "Add", bundle: .module, comment: "The Collections tab's + menu: new album, upload."),
                    systemImage: "plus")
            }
            .accessibilityIdentifier("collections-add")
            .uploadPresenter($upload)
            .sheet(isPresented: $creatingAlbum) { AlbumEditor(album: nil) }
        }
    }
#endif
