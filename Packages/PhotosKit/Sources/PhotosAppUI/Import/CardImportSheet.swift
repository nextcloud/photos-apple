// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosBackup
import PhotosCore
import PhotosModel
import SwiftUI
import UniformTypeIdentifiers

/// Import from a memory card, a camera or a folder (SPEC §15.2): the shots with thumbnails, "new only" preselected,
/// a destination pattern, RAW + JPEG kept together, optional eject and deletion from the card after a verified upload.
struct CardImportSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var browser = CardDeviceBrowser()
    @State private var center = CardImportCenter.shared
    @State private var selectedDevice: String?
    /// Shots of the device, newest first; RAW + JPEG are one.
    @State private var groups: [CardGroup] = []
    /// Ids of the files already on the server.
    @State private var existing: Set<String> = []
    @State private var checkingExisting = false
    @State private var chosen: Set<String> = []
    @AppStorage(CardImportSettings.newOnlyKey) private var newOnly = true
    @AppStorage(CardImportSettings.patternKey) private var pattern = DestinationPattern.default.pattern
    @AppStorage(CardImportSettings.ejectKey) private var ejectAfter = false
    @AppStorage(CardImportSettings.deleteKey) private var deleteAfter = false
    @State private var confirmDelete = false
    @State private var choosingFolder = false

    var device: (any CardDevice)? {
        browser.devices.first { $0.id == selectedDevice } ?? browser.devices.first
    }

    /// The shots shown: all, or the new ones.
    var shown: [CardGroup] {
        newOnly ? groups.filter { !isExisting($0) } : groups
    }

    /// A shot is on the server when every file of it is.
    func isExisting(_ group: CardGroup) -> Bool { group.items.allSatisfy { existing.contains($0.id) } }

    var selectedGroups: [CardGroup] { shown.filter { chosen.contains($0.id) } }

    /// For "new only": a shot half on the server (the RAW was imported before, the JPEG not) imports what is missing.
    var importGroups: [CardGroup] {
        selectedGroups.map { group in
            var copy = group
            if newOnly { copy.items = group.items.filter { !existing.contains($0.id) } }
            return copy
        }
        .filter { !$0.items.isEmpty }
    }

    var destination: DestinationPattern { DestinationPattern(pattern) }

    var body: some View {
        main
            .onAppear {
                browser.start()
                #if DEBUG
                    // UI checks: `PHOTOS_DEBUG_CARD_IMPORT=<folder>` imports from that folder.
                    if let path = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_CARD_IMPORT"], path.hasPrefix("/") {
                        selectedDevice = browser.addFolder(URL(filePath: path)).id
                    }
                #endif
            }
            .onDisappear {
                if !center.isRunning { browser.stop() }
            }
            .task(id: device?.id) { await loadDevice() }
            .onChange(of: device?.items.count) { _, _ in Task { await refreshGroups() } }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { selectedDevice = browser.addFolder(url).id }
            }
            .confirmationDialog(
                CardImportSheetWording.deleteConfirmationTitle(fileCount), isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                Button(CardImportSheetWording.importAndDelete, role: .destructive) { startImport() }
            } message: {
                Text(CardImportSheetWording.deleteConfirmationMessage)
            }
    }

    // MARK: Parts

    /// Mac: a window-like sheet with the device on top and the buttons at the bottom, as Photos' import. iPad: a
    /// navigation bar with the same controls.
    @ViewBuilder var main: some View {
        #if os(macOS)
            VStack(spacing: 0) {
                header
                Divider()
                if center.isRunning, let job = center.job { runningBanner(job) }
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                options
                Divider()
                footer
            }
            .frame(minWidth: 820, idealWidth: 960, minHeight: 600, idealHeight: 720)
        #else
            NavigationStack {
                VStack(spacing: 0) {
                    if center.isRunning, let job = center.job { runningBanner(job) }
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    options
                }
                .navigationTitle(String(localized: "Import", bundle: .module, comment: "Title of the import from card or camera."))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
            }
        #endif
    }

    /// The device (a menu when there are several) and what is on it.
    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: device?.symbol ?? "sdcard").font(.title2).foregroundStyle(.secondary)
            devicePicker.font(.headline)
            Spacer()
            Button(CardImportSheetWording.chooseFolder) { choosingFolder = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder var devicePicker: some View {
        if browser.devices.count > 1 {
            Picker(selection: Binding(get: { device?.id }, set: { selectedDevice = $0 })) {
                ForEach(browser.devices, id: \.id) { device in
                    Label(device.name, systemImage: device.symbol).tag(Optional(device.id))
                }
            } label: {
                Text("Device", bundle: .module, comment: "Import: which camera or card.")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        } else if let device {
            Text(verbatim: device.name)
        } else {
            Text("Import", bundle: .module)
        }
    }

    var selectAllButton: some View {
        Button(chosen.count == shown.count && !shown.isEmpty ? CardImportSheetWording.selectNone : CardImportSheetWording.selectAll) {
            chosen = chosen.count == shown.count ? [] : Set(shown.map(\.id))
        }
        .disabled(shown.isEmpty)
    }

    var importButton: some View {
        Button(CardImportSheetWording.importTitle(selectedGroups.count)) {
            if deleteAfter && device?.canDelete == true { confirmDelete = true } else { startImport() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(importGroups.isEmpty || center.isRunning || !destination.isValid)
    }

    var closeButton: some View {
        Button(center.isRunning ? CardImportSheetWording.continueInBackground : String(localized: "Cancel", bundle: .module)) {
            dismiss()
        }
        .keyboardShortcut(.cancelAction)
    }

    var footer: some View {
        HStack {
            selectAllButton
            Spacer()
            closeButton
            importButton
        }
        .padding(14)
    }

    @ViewBuilder var content: some View {
        if let device {
            if device.isLoading && device.items.isEmpty {
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text("Reading \(device.name)…", bundle: .module, comment: "Import: the device's files are being listed.")
                }
            } else if let problem = device.problem, device.items.isEmpty {
                ContentUnavailableView {
                    Label(device.name, systemImage: device.symbol)
                } description: {
                    Text(problem)
                } actions: {
                    #if os(macOS)
                        if problem == CardImportPermission.deniedMessage {
                            Button(CardImportSheetWording.openPrivacySettings) { openURL(CardImportPermission.settingsURL) }
                        }
                    #endif
                }
            } else if shown.isEmpty && !groups.isEmpty {
                ContentUnavailableView {
                    Label(CardImportSheetWording.allImportedTitle, systemImage: "checkmark.circle")
                } description: {
                    Text(CardImportSheetWording.allImportedMessage(groups.count))
                } actions: {
                    Button(CardImportSheetWording.showAll) { newOnly = false }
                }
            } else {
                grid
            }
        } else {
            ContentUnavailableView {
                Label(CardImportSheetWording.noDeviceTitle, systemImage: "sdcard")
            } description: {
                Text(CardImportSheetWording.noDeviceMessage)
            } actions: {
                Button(CardImportSheetWording.chooseFolder) { choosingFolder = true }
            }
        }
    }

    var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)], spacing: 10) {
                ForEach(shown) { group in
                    CardShotTile(
                        group: group, device: device, isChosen: chosen.contains(group.id), isExisting: isExisting(group)
                    )
                    .onTapGesture { toggle(group) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toggle(group) }
                }
            }
            .padding(14)
        }
    }

    func toggle(_ group: CardGroup) {
        if chosen.contains(group.id) { chosen.remove(group.id) } else { chosen.insert(group.id) }
    }

    var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Folder", bundle: .module, comment: "Import option: the destination folder pattern.")
                TextField(text: $pattern) {
                    Text("Folder", bundle: .module)
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                Menu {
                    ForEach(DestinationPattern.suggestions, id: \.self) { suggestion in
                        Button(suggestion) { pattern = suggestion }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(Text("Folder suggestions", bundle: .module, comment: "Import: menu of folder patterns."))
            }
            Text(previewText)
                .font(.caption)
                .foregroundStyle(destination.isValid ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            HStack(spacing: 18) {
                Toggle(CardImportSheetWording.newOnly, isOn: $newOnly)
                if device?.canEject == true {
                    Toggle(CardImportSheetWording.ejectAfter, isOn: $ejectAfter)
                }
                if device?.canDelete == true {
                    Toggle(CardImportSheetWording.deleteAfter, isOn: $deleteAfter)
                }
            }
            #if os(macOS)
                .toggleStyle(.checkbox)
            #endif
        }
        .padding(14)
    }

    /// "Photos/2026/2026-11-24 · 312 new of 340 · 2 RAW + JPEG"
    var previewText: String {
        guard destination.isValid else { return CardImportSheetWording.invalidPattern }
        let sample = selectedGroups.first ?? shown.first
        let folder = destination.folder(for: sample?.capturedAt ?? Date(), camera: device?.name)
        let newCount = groups.filter { !isExisting($0) }.count
        var parts = [CardImportSheetWording.goesTo(folder)]
        if !groups.isEmpty {
            parts.append(
                checkingExisting
                    ? CardImportSheetWording.checking
                    : CardImportSheetWording.newCount(newCount, of: groups.count))
        }
        return parts.joined(separator: " · ")
    }

    var fileCount: Int { importGroups.reduce(0) { $0 + $1.items.count } }

    #if os(iOS)
        @ToolbarContentBuilder var toolbar: some ToolbarContent {
            ToolbarItem(placement: .cancellationAction) { closeButton }
            ToolbarItem(placement: .principal) { devicePicker }
            ToolbarItem(placement: .confirmationAction) { importButton }
            ToolbarItemGroup(placement: .bottomBar) {
                Button(CardImportSheetWording.chooseFolder) { choosingFolder = true }
                Spacer()
                selectAllButton
            }
        }
    #endif

    func runningBanner(_ job: CardImportCenter.Job) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: job.progress.fraction).frame(maxWidth: 220)
            Text(CardImportWording.runningTitle(job)).font(.callout).monospacedDigit()
            Spacer()
            Button(String(localized: "Stop Import", bundle: .module)) { center.cancel() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Actions

    func loadDevice() async {
        groups = []
        existing = []
        chosen = []
        device?.load()
        await refreshGroups()
    }

    /// Groups the device's files and asks which are on the server already; "new only" then preselects the rest.
    func refreshGroups() async {
        guard let device, let services = session.services else { return }
        let items = device.items
        guard !items.isEmpty else { return }
        let grouped = CardGroup.groups(items)
        groups = grouped
        checkingExisting = true
        let importer = CardImporter(
            api: services.api, database: services.database, source: device.source, options: CardImportOptions(),
            ledgerURL: CardImportCenter.ledgerURL(session.account.id))
        let found = await importer.alreadyImported(items)
        guard !Task.isCancelled else { return }
        existing = found
        checkingExisting = false
        chosen = Set(grouped.filter { group in !group.items.allSatisfy { found.contains($0.id) } }.map(\.id))
    }

    func startImport() {
        guard let device else { return }
        let options = CardImportOptions(
            destination: destination, cameraName: device.name, deleteAfterVerifiedUpload: deleteAfter && device.canDelete)
        center.start(importGroups, from: device, options: options, ejectAfter: ejectAfter && device.canEject, session: session)
        dismiss()
    }
}

/// One shot in the import sheet: thumbnail, RAW badge, "on your Nextcloud", the check mark.
private struct CardShotTile: View {
    let group: CardGroup
    let device: (any CardDevice)?
    let isChosen: Bool
    let isExisting: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle()
                .fill(.quaternary)
                .frame(maxWidth: .infinity)
                .frame(height: 112)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else {
                        Image(systemName: group.leader.kind == .video ? "video" : "photo").foregroundStyle(.tertiary)
                    }
                }
                .clipShape(.rect(cornerRadius: 6))
                .opacity(isExisting ? 0.45 : 1)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isChosen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.black.opacity(0.25)))
                        .font(.title3)
                        .shadow(radius: 1)
                        .padding(5)
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        if group.hasRaw && group.items.count > 1 { badge("RAW+JPEG") } else if group.hasRaw { badge("RAW") }
                        if isExisting { Image(systemName: "checkmark.icloud.fill").foregroundStyle(.white).shadow(radius: 1) }
                    }
                    .padding(5)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(isChosen ? Color.accentColor : .clear, lineWidth: 2)
                }
            Text(verbatim: group.leader.name).font(.caption).lineLimit(1).truncationMode(.middle)
            if let date = group.capturedAt {
                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .task(id: group.id) {
            image = await device?.thumbnail(for: group.leader, maxPixels: 320)
        }
    }

    func badge(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.black.opacity(0.55), in: .rect(cornerRadius: 3))
            .foregroundStyle(.white)
    }

    var accessibilityLabel: String {
        var parts = [group.leader.name]
        if let date = group.capturedAt { parts.append(date.formatted(date: .long, time: .shortened)) }
        if group.hasRaw { parts.append(group.items.count > 1 ? "RAW + JPEG" : "RAW") }
        if isExisting { parts.append(CardImportSheetWording.onServer) }
        return parts.joined(separator: ", ")
    }
}

/// Import options remembered on this device.
enum CardImportSettings {
    static let newOnlyKey = "cardImportNewOnly"
    static let patternKey = "cardImportPattern"
    static let ejectKey = "cardImportEject"
    static let deleteKey = "cardImportDelete"
}

enum CardImportSheetWording {
    static var newOnly: String {
        String(localized: "New items only", bundle: .module, comment: "Import option: hide what is already on the server.")
    }

    static var ejectAfter: String {
        String(localized: "Eject after import", bundle: .module, comment: "Import option: eject the card or camera when done.")
    }

    static var deleteAfter: String {
        String(
            localized: "Delete from card after verified upload", bundle: .module,
            comment: "Import option: delete the imported files from the card once they are verified on the server.")
    }

    static func importTitle(_ count: Int) -> String {
        count == 0
            ? String(localized: "Import", bundle: .module, comment: "Import button without a selection.")
            : String(localized: "Import \(count) Items", bundle: .module, comment: "Import button. Plural variations.")
    }

    static var selectAll: String { String(localized: "Select All", bundle: .module, comment: "Import: select every shot.") }
    static var selectNone: String { String(localized: "Select None", bundle: .module, comment: "Import: deselect every shot.") }

    static var chooseFolder: String {
        String(localized: "Choose Folder…", bundle: .module, comment: "Import: pick a folder (an external drive) to import from.")
    }

    static var openPrivacySettings: String {
        String(localized: "Open Privacy Settings", bundle: .module, comment: "Import (Mac): opens System Settings at Files and Folders.")
    }

    static var continueInBackground: String {
        String(localized: "Close", bundle: .module, comment: "Import sheet while an import runs: closes it, the import goes on.")
    }

    static var noDeviceTitle: String {
        String(localized: "Connect a Camera or Card", bundle: .module, comment: "Import: nothing connected.")
    }

    static var noDeviceMessage: String {
        #if os(macOS)
            String(
                localized: "Connect a camera with its USB cable or insert a memory card. You can also import from a folder.",
                bundle: .module, comment: "Import: nothing connected (Mac).")
        #else
            String(
                localized: "Connect a camera, or a card reader or drive and choose its folder in Files.", bundle: .module,
                comment: "Import: nothing connected (iPad, iPhone).")
        #endif
    }

    static var allImportedTitle: String {
        String(localized: "Everything Is Imported", bundle: .module, comment: "Import: every shot of the card is on the server.")
    }

    static func allImportedMessage(_ count: Int) -> String {
        String(
            localized: "All \(count) shots on this card are already on your Nextcloud.", bundle: .module,
            comment: "Import: every shot is already on the server. Plural variations.")
    }

    static var showAll: String { String(localized: "Show All", bundle: .module, comment: "Import: show the shots already imported too.") }

    static var onServer: String {
        String(localized: "On your Nextcloud", bundle: .module, comment: "Import: the shot is already on the server (accessibility).")
    }

    static var checking: String {
        String(localized: "Checking what is new…", bundle: .module, comment: "Import: comparing the card with the server.")
    }

    static func newCount(_ new: Int, of total: Int) -> String {
        String(localized: "\(new) new of \(total)", bundle: .module, comment: "Import: shots not yet on the server, of all shots.")
    }

    static func goesTo(_ folder: String) -> String {
        String(localized: "To \(folder)", bundle: .module, comment: "Import: the folder the photos go to, e.g. To /Photos/2026/2026-11-24.")
    }

    static var invalidPattern: String {
        String(
            localized: "Use a folder with date parts such as {yyyy}, {MM}, {dd} or {yyyy-MM-dd}, and {camera}.", bundle: .module,
            comment: "Import: the folder pattern is not valid. Do not translate the parts in braces.")
    }

    static func deleteConfirmationTitle(_ count: Int) -> String {
        String(
            localized: "Delete \(count) files from the card after the import?", bundle: .module,
            comment: "Confirmation before an import that deletes from the card. Plural variations.")
    }

    static var deleteConfirmationMessage: String {
        String(
            localized:
                "Each file is deleted only after it is verified on your Nextcloud. Files that fail to upload or verify stay on the card. This cannot be undone.",
            bundle: .module, comment: "Confirmation before an import that deletes from the card.")
    }

    static var importAndDelete: String {
        String(localized: "Import and Delete", bundle: .module, comment: "Confirms an import that deletes from the card afterwards.")
    }
}

/// Where the card import is offered: the Mac and iPad (cameras and card readers), not iPhone and Vision Pro.
enum CardImportAvailability {
    @MainActor static var isAvailable: Bool {
        #if os(macOS)
            true
        #elseif os(iOS)
            UIDevice.current.userInterfaceIdiom == .pad
        #else
            false
        #endif
    }

    static var menuTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Import from Camera or Card…", bundle: .module, comment: "File menu: import photos from a camera or memory card (⇧⌘I)."),
            other: LocalizedStringResource(
                "Import from camera or card…", bundle: .module, comment: "Import photos from a camera, memory card or drive."))
    }
}
