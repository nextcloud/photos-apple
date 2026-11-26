// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore

/// Everything the command palette can go to, from the local index (SPEC §16.2). Loaded off the main thread each time
/// the palette opens; small (a few thousand entries for a large library).
struct CommandPaletteCatalog: Sendable {
    var albums: [Album] = []
    var people: [String] = []
    var places: [String] = []
    var tags: [String] = []
    var years: [(year: Int, count: Int)] = []
    /// Words photos are known to show (for reading searches).
    var labels: [String] = []

    static func load(_ services: AccountServices) async -> CommandPaletteCatalog {
        var catalog = CommandPaletteCatalog()
        let collections = services.collections
        catalog.albums = ((try? collections.albums(.own)) ?? []) + ((try? collections.albums(.shared)) ?? [])
        let labels = LabelStore(database: services.database)
        catalog.people = ((try? labels.personNames()) ?? []).filter { $0.contains(where: \.isLetter) }
        catalog.tags = ((try? labels.tags()) ?? []).filter { $0.itemCount != 0 && CullingTags.meaning(of: $0.name) == nil }.map(\.name)
        catalog.places = (try? await services.library.placeNames()) ?? []
        catalog.years = (try? await services.library.years()) ?? []
        catalog.labels = (try? PhotoDescriptionStore(database: services.database).knownLabels(limit: 500)) ?? []
        return catalog
    }

    var vocabulary: NaturalSearch.Vocabulary {
        NaturalSearch.Vocabulary(
            places: places, people: people, tags: [], albums: albums.map { ($0.id, $0.title) }, labels: labels)
    }

    /// The entries of the catalog (not the commands, which depend on the window).
    func items() -> [CommandPalette.Item] {
        var items: [CommandPalette.Item] = []
        for album in albums {
            items.append(
                CommandPalette.Item(
                    id: "album:\(album.id)", title: album.title,
                    subtitle: album.kind == .shared
                        ? String(localized: "Shared album", bundle: .module, comment: "Command palette: what an entry is.")
                        : String(localized: "Album", bundle: .module),
                    systemImage: album.kind == .shared ? "rectangle.stack.badge.person.crop" : "rectangle.stack",
                    keywords: [album.location].filter { !$0.isEmpty }, kind: .album, action: .openAlbum(id: album.id)))
        }
        for person in people {
            items.append(
                CommandPalette.Item(
                    id: "person:\(person)", title: person, subtitle: String(localized: "Person", bundle: .module),
                    systemImage: "person.crop.circle",
                    kind: .person, action: .openPerson(person)))
        }
        for place in places {
            items.append(
                CommandPalette.Item(
                    id: "place:\(place)", title: place, subtitle: String(localized: "Place", bundle: .module),
                    systemImage: "mappin.and.ellipse",
                    kind: .place, action: .openPlace(place)))
        }
        for tag in tags {
            items.append(
                CommandPalette.Item(
                    id: "tag:\(tag)", title: tag, subtitle: String(localized: "Tag", bundle: .module), systemImage: "tag", kind: .tag,
                    action: .openTag(tag)))
        }
        let context = SearchDates.Context()
        for (year, count) in years {
            guard let range = SearchDates.yearRange(year, context: context) else { continue }
            items.append(
                CommandPalette.Item(
                    id: "year:\(year)", title: String(year), subtitle: AccessibilityText.photos(count), systemImage: "calendar",
                    kind: .year,
                    action: .search([.dateRange(start: range.lowerBound, end: range.upperBound, label: String(year))])))
        }
        return items
    }
}

/// The places of the app as palette entries, with words people may use for them.
enum PaletteDestinations {
    static func items(available: [AppDestination]) -> [CommandPalette.Item] {
        var destinations = available.filter { $0 != .collections && $0 != .search && $0 != .onThisDay }
        #if os(macOS)
            // Backup and Settings are pages of the Settings window on the Mac.
            destinations.removeAll { $0 == .backup || $0 == .settings }
        #endif
        var items = destinations.map { destination in
            CommandPalette.Item(
                id: "go:\(destination.rawValue)", title: String(localized: destination.title), subtitle: PaletteWording.goTo,
                systemImage: destination.systemImage, keywords: keywords(destination), kind: .destination, action: .go(destination.rawValue)
            )
        }
        #if os(macOS)
            items += MacSettingsPage.allCases.map { page in
                CommandPalette.Item(
                    id: "settings:\(page.rawValue)", title: page.paletteTitle, subtitle: String(localized: "Settings", bundle: .module),
                    systemImage: page.systemImage, keywords: ["settings", "preferences"] + page.keywords, kind: .settings,
                    action: .settings(page.rawValue))
            }
        #endif
        return items
    }

    /// Other words for a place (English, as typed; the titles are matched in the user's language).
    static func keywords(_ destination: AppDestination) -> [String] {
        switch destination {
        case .library: ["all photos", "timeline", "home"]
        case .photos: ["pictures", "images"]
        case .videos: ["movies", "clips"]
        case .favorites: ["favourites", "loved", "hearts"]
        case .memories: ["for you", "on this day", "trips"]
        case .map: ["world", "places", "locations"]
        case .albums: ["collections"]
        case .sharedAlbums: ["shared"]
        case .smartAlbums: ["saved searches", "filters"]
        case .people: ["faces", "persons"]
        case .places: ["locations", "cities", "countries"]
        case .tags: ["labels", "keywords"]
        case .folders: ["files", "directories"]
        case .sharedWithYou: ["received"]
        case .archive: ["hidden", "archived"]
        case .recentlyDeleted: ["trash", "bin", "deleted", "restore"]
        case .duplicates: ["copies", "clean up", "same"]
        case .freeSpace: ["storage", "clean up", "screenshots", "large videos"]
        case .backup: ["settings", "upload", "camera roll", "auto upload", "sync"]
        case .settings: ["preferences", "options", "account"]
        case .stickers: ["sticker book"]
        default: []
        }
    }
}

#if os(macOS)
    /// The tabs of the Mac's Settings window, which the palette can open (`MacSettingsView`).
    enum MacSettingsPage: String, CaseIterable {
        case general, accounts, backup, storage, privacy, desktop, advanced, about

        /// `@AppStorage` key of the selected tab.
        static let storageKey = "macSettingsTab"

        /// The tab `stored` names; Server, a tab of earlier versions, is part of Accounts now (SPEC §20.4).
        init(stored: String) {
            self = stored == "server" ? .accounts : MacSettingsPage(rawValue: stored) ?? .general
        }

        /// The Settings page the tab shows.
        var page: SettingsPage {
            switch self {
            case .general: .general
            case .accounts: .accounts
            case .backup: .backup
            case .storage: .storage
            case .privacy: .privacy
            case .desktop: .desktop
            case .advanced: .advanced
            case .about: .about
            }
        }

        var paletteTitle: String {
            switch self {
            case .general:
                String(localized: "General Settings", bundle: .module, comment: "Command palette: opens Settings › General (Mac).")
            case .accounts:
                String(localized: "Accounts Settings", bundle: .module, comment: "Command palette: opens Settings › Accounts (Mac).")
            case .backup: String(localized: "Backup Settings", bundle: .module, comment: "Command palette: opens Settings › Backup (Mac).")
            case .storage:
                String(localized: "Storage Settings", bundle: .module, comment: "Command palette: opens Settings › Storage (Mac).")
            case .desktop:
                String(localized: "Desktop Settings", bundle: .module, comment: "Command palette: opens Settings › Desktop (Mac).")
            case .privacy:
                String(localized: "Privacy Settings", bundle: .module, comment: "Command palette: opens Settings › Privacy (Mac).")
            case .advanced:
                String(localized: "Advanced Settings", bundle: .module, comment: "Command palette: opens Settings › Advanced (Mac).")
            case .about:
                String(localized: "About Nextcloud Photos", bundle: .module, comment: "Command palette: opens Settings › About (Mac).")
            }
        }

        var systemImage: String { page.systemImage }

        var keywords: [String] {
            switch self {
            case .general: ["library", "folders", "notifications", "appearance", "partner", "family"]
            case .accounts: ["login", "logout", "sign in", "sign out", "server", "features", "nextcloud", "sync"]
            case .backup: ["upload", "camera roll", "auto upload"]
            case .storage: ["cache", "offline", "space"]
            case .desktop: ["wallpaper", "desktop picture"]
            case .privacy: ["app lock", "touch id", "password", "search", "descriptions", "similar"]
            case .advanced: ["advanced features", "stickers", "insights", "folder rules", "diagnostics", "log", "menu bar"]
            case .about: ["version", "licences", "licenses"]
            }
        }
    }
#endif

/// The palette's commands, with their titles in the platform's wording.
enum PaletteCommands {
    static func items(main: MainActions?, grid: GridActions?) -> [CommandPalette.Item] {
        var items: [CommandPalette.Item] = []
        func add(_ command: CommandPalette.Command, _ title: String, _ image: String, _ keywords: [String] = []) {
            items.append(
                CommandPalette.Item(
                    id: "command:\(command.rawValue)", title: title,
                    subtitle: command.needsSelection ? PaletteWording.selection(grid) : nil,
                    systemImage: image, keywords: keywords, kind: .command, action: .command(command)))
        }
        if main != nil {
            add(.newAlbum, PaletteWording.platform("New Album…", "New album…"), "rectangle.stack.badge.plus", ["create album"])
            add(.upload, PaletteWording.platform("Upload Photos…", "Upload photos…"), "square.and.arrow.up", ["add files"])
            add(.openPublicLink, PaletteWording.platform("Open Public Album Link…", "Open public album link…"), "link")
            add(.syncNow, PaletteWording.platform("Sync Now", "Sync now"), "arrow.triangle.2.circlepath", ["refresh", "reload"])
            if main?.importLibrary != nil {
                add(
                    .importLibrary, PaletteWording.platform("Import Library…", "Import library…"), "tray.and.arrow.down",
                    ["google photos", "takeout", "icloud", "facebook"])
            }
            if main?.importCard != nil { add(.importCard, CardImportAvailability.menuTitle, "sdcard", ["camera", "memory card"]) }
        }
        guard let grid else { return items }
        if grid.slideshow != nil { add(.slideshow, SlideshowRequest.menuTitle, "play.rectangle", ["play"]) }
        guard grid.selectionCount > 0 else { return items }
        let favoriteTitle: String =
            grid.allFavorite
            ? PaletteWording.platform("Remove from Favorites", "Remove from favorites")
            : PaletteWording.platform("Add to Favorites", "Add to favorites")
        add(.toggleFavorite, favoriteTitle, grid.allFavorite ? "heart.slash" : "heart", ["favourite", "love", "like", "heart"])
        add(.addToAlbum, PaletteWording.platform("Add to Album…", "Add to album…"), "rectangle.stack.badge.plus")
        if grid.addToNewAlbum != nil {
            add(.addToNewAlbum, PaletteWording.platform("Add to New Album…", "Add to new album…"), "rectangle.stack.badge.plus")
        }
        if grid.open != nil { add(.open, PaletteWording.platform("Open", "Open"), "arrow.up.forward.square") }
        add(.getInfo, PaletteWording.platform("Get Info", "Info"), "info.circle", ["details", "exif", "metadata"])
        if grid.edit != nil { add(.edit, PaletteWording.platform("Edit…", "Edit…"), "slider.horizontal.3", ["adjust", "crop", "filter"]) }
        if grid.editDateAndLocation != nil {
            add(
                .editDateAndLocation, PaletteWording.platform("Edit Date and Location…", "Edit date and location…"), "calendar.badge.clock",
                ["time", "place", "geotag"])
        }
        if grid.rotate != nil {
            add(.rotateLeft, PaletteWording.platform("Rotate Left", "Rotate left"), "rotate.left")
            add(.rotateRight, PaletteWording.platform("Rotate Right", "Rotate right"), "rotate.right")
        }
        if grid.export != nil { add(.export, PhotosCommands.exportTitle, "square.and.arrow.down", ["save", "download"]) }
        if grid.compare != nil { add(.compare, CompareWording.menuTitle, "rectangle.split.2x2") }
        if grid.cull != nil {
            add(.pick, CullingWording.flagTitle(.pick), "flag", ["pick", "flag"])
            add(.reject, CullingWording.flagTitle(.reject), "xmark.circle", ["reject"])
            add(.unflag, CullingWording.flagTitle(.none), "flag.slash", ["unflag"])
        }
        add(.delete, PaletteWording.platform("Delete…", "Delete…"), "trash", ["remove", "trash"])
        return items
    }

    /// Entries for what the typed words ask of the selection: an album to add it to, a rating.
    static func intentItems(_ query: String, albums: [Album], grid: GridActions?) -> [CommandPalette.Item] {
        guard let grid, grid.selectionCount > 0, let intent = CommandPalette.intent(query) else { return [] }
        switch intent {
        case .addToAlbum(let name):
            return CommandPalette.albumTargets(name, albums: albums.map { ($0.id, $0.title) }) { id, title in
                CommandPalette.Item(
                    id: "addto:\(id)",
                    title: String(
                        localized: "Add to “\(title)”", bundle: .module, comment: "Command palette: adds the selection to this album."),
                    subtitle: PaletteWording.selection(grid), systemImage: "rectangle.stack.badge.plus", keywords: ["add to \(title)"],
                    kind: .command, action: .addToAlbum(id: id, title: title))
            }
        case .rate(let stars):
            guard grid.cull != nil else { return [] }
            let title: String = CullingWording.ratingTitle(stars)
            return [
                CommandPalette.Item(
                    id: "rate:\(stars)", title: title, subtitle: PaletteWording.selection(grid), systemImage: "star", keywords: [query],
                    kind: .command, action: .rate(stars))
            ]
        }
    }
}

enum PaletteWording {
    /// Title case on the Mac, sentence case elsewhere (`PlatformWording`), from this module's catalog.
    static func platform(_ mac: String.LocalizationValue, _ other: String.LocalizationValue) -> String {
        PlatformWording.title(mac: LocalizedStringResource(mac, bundle: .module), other: LocalizedStringResource(other, bundle: .module))
    }

    static var goTo: String {
        String(localized: "Go to", bundle: .module, comment: "Command palette: an entry that opens a place of the app.")
    }

    /// "3 selected" or "This photo".
    static func selection(_ grid: GridActions?) -> String? {
        guard let count = grid?.selectionCount, count > 0 else { return nil }
        return String(localized: "\(count) selected", bundle: .module, comment: "Command palette: the command acts on the selected photos.")
    }

    static var placeholder: String {
        String(
            localized: "Go to, search or do…", bundle: .module,
            comment: "Placeholder of the command palette's field: an album, person, place, year, search or command.")
    }

    static var title: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Quick Actions…", bundle: .module, comment: "Go menu (Mac): opens the command palette (⌘K)."),
            other: LocalizedStringResource("Quick actions", bundle: .module, comment: "Button and title of the command palette (⌘K)."))
    }

    static func kind(_ item: CommandPalette.Item) -> String {
        switch item.kind {
        case .search: String(localized: "Search", bundle: .module)
        case .command: String(localized: "Command", bundle: .module, comment: "Command palette: what an entry is.")
        case .destination: String(localized: "Go to", bundle: .module, comment: "Command palette: an entry that opens a place of the app.")
        case .album: item.subtitle ?? String(localized: "Album", bundle: .module)
        case .person: String(localized: "Person", bundle: .module)
        case .place: String(localized: "Place", bundle: .module)
        case .tag: String(localized: "Tag", bundle: .module)
        case .year: String(localized: "Year", bundle: .module, comment: "Command palette: what an entry is.")
        case .settings: String(localized: "Settings", bundle: .module)
        }
    }
}
