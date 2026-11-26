// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Observation
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// Opens the command palette of a window and hands a search from it to the search screen (SPEC §16.2). `MainView`
/// owns one per window.
@MainActor
@Observable
final class CommandPaletteCenter {
    var isPresented = false
    /// The grid or viewer that had the focus when the palette opened: its commands act on its selection.
    var grid: GridActions?
    /// A search the palette asked for, which the search tab takes (the Mac's search field is the window's).
    var pendingSearch: [SearchFilter]?
    /// Debug builds: the words the palette opens with (`PHOTOS_DEBUG_PALETTE`).
    var debugQuery: String?

    func open(grid: GridActions?) {
        self.grid = grid
        isPresented = true
    }

    func close() {
        isPresented = false
    }
}

extension EnvironmentValues {
    @Entry var commandPalette: CommandPaletteCenter? = nil
}

/// The palette's entries remembered per account (newest first), in the account's directory.
enum PaletteRecents {
    static func file(account: AccountID, layout: StorageLayout) -> URL {
        layout.accountDirectory(account).appending(path: "palette-recents.json")
    }

    static func load(account: AccountID, layout: StorageLayout) -> [String] {
        guard let data = try? Data(contentsOf: file(account: account, layout: layout)) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func save(_ ids: [String], account: AccountID, layout: StorageLayout) {
        let url = file(account: account, layout: layout)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(ids).write(to: url, options: .atomic)
    }
}

extension View {
    /// Shows the window's command palette: a floating panel over the window, a sheet on iPhone.
    func commandPaletteHost(_ center: CommandPaletteCenter, actions: MainActions) -> some View {
        modifier(CommandPaletteHost(center: center, actions: actions))
    }
}

private struct CommandPaletteHost: ViewModifier {
    @Bindable var center: CommandPaletteCenter
    let actions: MainActions
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var usesSheet: Bool {
        #if os(iOS)
            sizeClass == .compact
        #else
            false
        #endif
    }

    func body(content: Content) -> some View {
        content
            .environment(\.commandPalette, center)
            .overlay {
                if center.isPresented && !usesSheet {
                    ZStack(alignment: .top) {
                        // Clicking or tapping outside closes it, as Spotlight does.
                        Color.black.opacity(0.12).ignoresSafeArea()
                            .onTapGesture { center.close() }
                            .accessibilityHidden(true)
                        CommandPaletteView(center: center, actions: actions)
                            .frame(maxWidth: 640)
                            .background(.regularMaterial, in: .rect(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
                            .padding(.horizontal, 16)
                            .padding(.top, 64)
                            .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                    }
                }
            }
            .animation(.snappy(duration: 0.18), value: center.isPresented)
            #if DEBUG
                // Screenshots and UI checks: `PHOTOS_DEBUG_PALETTE=<typed words>` opens the palette at launch.
                .task {
                    guard let typed = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_PALETTE"] else { return }
                    try? await Task.sleep(for: .seconds(3))
                    center.debugQuery = typed
                    center.open(grid: nil)
                }
            #endif
            .sheet(isPresented: Binding(get: { center.isPresented && usesSheet }, set: { if !$0 { center.close() } })) {
                CommandPaletteView(center: center, actions: actions, fillsHeight: true)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }
}

/// The palette: a field and the entries for what is typed, best first.
struct CommandPaletteView: View {
    let center: CommandPaletteCenter
    let actions: MainActions
    /// In a sheet: the list fills it, from the top.
    var fillsHeight = false
    @Environment(SessionModel.self) private var session
    #if os(macOS)
        @Environment(\.openSettings) private var openSettings
    #endif
    @State private var query = ""
    @State private var catalog = CommandPaletteCatalog()
    @State private var recents: [String] = []
    @State private var results: [CommandPalette.Item] = []
    @State private var highlighted: String?
    @FocusState private var fieldFocused: Bool

    var grid: GridActions? { center.grid }
    var hasSelection: Bool { (grid?.selectionCount ?? 0) > 0 }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            list
        }
        .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
        .task {
            guard let services = session.services else { return }
            if let typed = center.debugQuery {
                query = typed
                center.debugQuery = nil
            }
            recents = PaletteRecents.load(account: session.account.id, layout: services.layout)
            update()
            catalog = await CommandPaletteCatalog.load(services)
            update()
        }
        .onChange(of: query) { _, _ in update() }
        .onAppear { fieldFocused = true }
        #if os(macOS)
            .onExitCommand { center.close() }
        #endif
    }

    var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(PaletteWording.placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                #endif
                .onSubmit { runHighlighted() }
                .onKeyPress(.downArrow) {
                    move(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(-1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    center.close()
                    return .handled
                }
                .accessibilityLabel(PaletteWording.title)
            if let count = grid?.selectionCount, count > 0 {
                Text(PaletteWording.selection(grid) ?? "")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty && !results.isEmpty {
                        header(
                            recents.isEmpty
                                ? String(
                                    localized: "Suggestions", bundle: .module,
                                    comment: "Command palette: header of the entries shown before typing.")
                                : String(
                                    localized: "Recent", bundle: .module, comment: "Command palette: header of the recently used entries."))
                    }
                    ForEach(results) { (item: CommandPalette.Item) in
                        row(item).id(item.id)
                    }
                }
                .padding(8)
            }
            .overlay {
                if results.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            // As tall as its entries, up to a limit: one entry is a small panel, as in Spotlight.
            .frame(maxHeight: listHeight)
            .onChange(of: highlighted) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) }
            }
        }
    }

    var listHeight: CGFloat {
        if fillsHeight { return .infinity }
        let rows = results.isEmpty && !query.isEmpty ? 5 : results.count + (query.isEmpty ? 1 : 0)
        return min(CGFloat(max(rows, 1)) * 48 + 16, 380)
    }

    func header(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    func row(_ item: CommandPalette.Item) -> some View {
        let isHighlighted = item.id == highlighted
        let kind = PaletteWording.kind(item)
        return Button {
            run(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .frame(width: 22)
                    .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).lineLimit(1)
                    if let subtitle = item.subtitle, item.kind != .album || subtitle != kind {
                        Text(subtitle).font(.caption).foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(kind).font(.caption).foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
            }
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(AccessibilityText.join([item.title, item.subtitle == kind ? nil : item.subtitle, kind])))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        #if os(macOS)
            .onHover { inside in if inside { highlighted = item.id } }
        #endif
    }

    // MARK: Entries

    func update() {
        let typed = query
        var items =
            catalog.items() + PaletteDestinations.items(available: actions.available)
            + PaletteCommands.items(main: actions, grid: grid)
        let extra = PaletteCommands.intentItems(typed, albums: catalog.albums, grid: grid)
        items.removeAll { item in extra.contains { $0.id == item.id } }
        let interpretation: NaturalSearch.Interpretation? =
            typed.trimmingCharacters(in: .whitespaces).isEmpty ? nil : NaturalSearch.interpret(typed, vocabulary: catalog.vocabulary)
        var ranked = CommandPalette.rank(
            typed, items: items, recents: recents, hasSelection: hasSelection, interpretation: interpretation, extra: extra)
        // Last: search the library for the words as they are.
        if let interpretation, !typed.trimmingCharacters(in: .whitespaces).isEmpty {
            let title = String(
                localized: "Search for “\(typed)”", bundle: .module, comment: "Command palette: the last entry, searches the library.")
            let filters = interpretation.isStructured ? interpretation.filters : [.text(typed.trimmingCharacters(in: .whitespaces))]
            let search = CommandPalette.searchItem(filters, title: title)
            if !ranked.contains(where: { $0.id == search.id }) { ranked.append(search) }
        }
        results = ranked
        if highlighted == nil || !ranked.contains(where: { $0.id == highlighted }) || !typed.isEmpty {
            highlighted = ranked.first?.id
        }
    }

    func move(_ step: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == highlighted } ?? -1
        let next = min(max(index + step, 0), results.count - 1)
        highlighted = results[next].id
    }

    func runHighlighted() {
        guard let item = results.first(where: { $0.id == highlighted }) ?? results.first else { return }
        run(item)
    }

    func run(_ item: CommandPalette.Item) {
        if item.kind != .search, let services = session.services {
            recents = CommandPalette.remembering(item.id, in: recents)
            PaletteRecents.save(recents, account: session.account.id, layout: services.layout)
        }
        let grid = self.grid
        let albums = catalog.albums
        center.close()
        // After the palette is gone: a command may open a sheet of its own.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            perform(item.action, grid: grid, albums: albums)
        }
    }

    func perform(_ action: CommandPalette.Action, grid: GridActions?, albums: [Album]) {
        switch action {
        case .go(let raw):
            if let destination = AppDestination(rawValue: raw) { actions.go(destination) }
        case .openAlbum(let id): actions.openLink?(.album(id: id))
        case .openPerson(let name): actions.openLink?(.person(name: name))
        case .openPlace(let name): actions.openLink?(.place(name: name))
        case .openTag(let name): actions.openLink?(.tag(name: name))
        case .search(let filters): actions.search?(filters)
        case .addToAlbum(let id, _):
            if let album = albums.first(where: { $0.id == id }) { grid?.addToRecentAlbum?(album) }
        case .rate(let stars): grid?.cull?(.rate(stars))
        case .settings(let page):
            #if os(macOS)
                UserDefaults.standard.set(page, forKey: MacSettingsPage.storageKey)
                openSettings()
            #else
                _ = page
                actions.go(.settings)
            #endif
        case .command(let command): perform(command, grid: grid)
        }
    }

    func perform(_ command: CommandPalette.Command, grid: GridActions?) {
        switch command {
        case .newAlbum: actions.newAlbum()
        case .upload: actions.upload()
        case .importLibrary: actions.importLibrary?()
        case .importCard: actions.importCard?()
        case .openPublicLink: actions.openPublicLink()
        case .syncNow: actions.syncNow()
        case .toggleFavorite: grid?.toggleFavorite()
        case .addToAlbum: grid?.addToAlbum()
        case .addToNewAlbum: grid?.addToNewAlbum?()
        case .delete: grid?.delete()
        case .export: grid?.export?()
        case .edit: grid?.edit?()
        case .editDateAndLocation: grid?.editDateAndLocation?()
        case .rotateLeft: grid?.rotate?(false)
        case .rotateRight: grid?.rotate?(true)
        case .getInfo: grid?.toggleInfo()
        case .slideshow: grid?.slideshow?()
        case .compare: grid?.compare?()
        case .pick: grid?.cull?(.flag(.pick))
        case .reject: grid?.cull?(.flag(.reject))
        case .unflag: grid?.cull?(.flag(.none))
        case .open: grid?.open?()
        }
    }
}

/// The toolbar button that opens the palette.
struct CommandPaletteButton: View {
    @Environment(\.commandPalette) private var palette
    var grid: GridActions? = nil

    var body: some View {
        if let palette {
            Button {
                palette.open(grid: grid)
            } label: {
                Label(PaletteWording.title, systemImage: "command")
            }
            .help(PaletteWording.title + " (⌘K)")
        }
    }
}
