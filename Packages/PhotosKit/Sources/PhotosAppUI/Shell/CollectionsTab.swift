// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosBackup
import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// Navigation where there is only a tab bar (iPhone, narrow iPad windows; SPEC §6.2): Library, Collections, Search
/// and Settings are tabs, and every other place is listed in the Collections tab and pushed in its stack.
///
/// The app's navigation state stays what it is everywhere — the selected destination and its path. These functions
/// translate between that state and the Collections tab's stack.
enum CompactNavigation {
    struct Section: Identifiable, Equatable {
        enum Kind: Equatable {
            case browse, collections, utilities
        }

        var kind: Kind
        var destinations: [AppDestination]
        var id: Kind.ID { kind.id }
    }

    /// Destinations with a tab of their own.
    static let tabs: [AppDestination] = [.library, .collections, .search, .settings]

    /// An iPhone never has a sidebar, whatever its size class (a large iPhone is "regular" in landscape); an iPad
    /// has none while its window is narrow.
    static func usesCollectionsTab(isPhone: Bool, isCompact: Bool) -> Bool {
        isPhone || isCompact
    }

    /// The tab that is selected while `destination` is shown.
    static func tab(for destination: AppDestination) -> AppDestination {
        tabs.contains(destination) ? destination : .collections
    }

    /// The Collections list itself or a place that is reached through it.
    static func isInCollectionsTab(_ destination: AppDestination) -> Bool {
        tab(for: destination) == .collections
    }

    /// The Collections stack while `destination` is shown with `routes` open in it: the list is the root, the
    /// destination the first screen pushed on it.
    static func path(to destination: AppDestination, routes: [AppRoute]) -> [AppRoute] {
        guard isInCollectionsTab(destination), destination != .collections else { return [] }
        return [.destination(destination.rawValue)] + routes
    }

    /// What a path of the Collections stack shows: the destination and what is open in it. Nil for a path the stack
    /// cannot have (it would not start with one of the listed places).
    static func place(of path: [AppRoute]) -> (destination: AppDestination, routes: [AppRoute])? {
        guard let first = path.first else { return (.collections, []) }
        guard case .destination(let raw) = first, let destination = AppDestination(rawValue: raw), destination != .collections,
            isInCollectionsTab(destination)
        else { return nil }
        return (destination, Array(path.dropFirst()))
    }

    /// The rows of the Collections list: everything the sidebar offers besides the Library, and Backup with the utilities.
    static func sections(visible: (AppDestination) -> Bool) -> [Section] {
        let all: [Section] = [
            Section(kind: .browse, destinations: SidebarLayout.primary.filter { $0 != .library }),
            Section(kind: .collections, destinations: SidebarLayout.collections),
            Section(kind: .utilities, destinations: SidebarLayout.utilities + [.backup]),
        ]
        return all.map { Section(kind: $0.kind, destinations: $0.destinations.filter(visible)) }.filter { !$0.destinations.isEmpty }
    }
}

extension CompactNavigation.Section.Kind: Identifiable {
    var id: Self { self }
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
        case .failed, .notAuthorized: return String(localized: "Needs attention", bundle: .module)
        case .upToDate: return String(localized: "Up to date", bundle: .module)
        case .idle:
            return status.pending > 0
                ? String(localized: "\(status.pending) waiting", bundle: .module) : String(localized: "On", bundle: .module)
        }
    }
}

#if !os(macOS)
    /// Root of the Collections tab.
    struct CollectionsList: View {
        @Environment(SessionModel.self) private var session

        var sections: [CompactNavigation.Section] {
            CompactNavigation.sections { (destination: AppDestination) -> Bool in
                guard let feature = destination.requiredFeature else { return true }
                return session.features.has(feature)
            }
        }

        var body: some View {
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.destinations) { destination in
                            // By value: the stack's path (MainView) knows which place is open.
                            NavigationLink(value: AppRoute.destination(destination.rawValue)) {
                                row(destination)
                            }
                        }
                    } header: {
                        header(section.kind)
                    }
                }
            }
            .navigationTitle(String(localized: "Collections", bundle: .module))
        }

        @ViewBuilder func header(_ kind: CompactNavigation.Section.Kind) -> some View {
            switch kind {
            // The first groups need no title under "Collections".
            case .browse, .collections: EmptyView()
            case .utilities: Text("Utilities", bundle: .module)
            }
        }

        @ViewBuilder func row(_ destination: AppDestination) -> some View {
            let label = Label(String(localized: destination.title), systemImage: destination.systemImage)
            if destination == .backup, let status = backupStatus {
                LabeledContent {
                    Text(status)
                } label: {
                    label
                }
            } else {
                label
            }
        }

        var backupStatus: String? {
            let backup = session.backup
            return BackupRowStatus.text(isAvailable: backup.isAvailable, isEnabled: backup.settings.isEnabled, status: backup.status)
        }
    }
#endif
