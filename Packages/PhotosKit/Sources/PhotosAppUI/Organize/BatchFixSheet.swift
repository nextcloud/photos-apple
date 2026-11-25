// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// What a batch fix changes (SPEC §16.4).
enum BatchFixMode: String, CaseIterable, Identifiable {
    case date, location, rename, track
    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: String(localized: "Date", bundle: .module, comment: "Batch fix tab: capture date and time.")
        case .location: String(localized: "Place", bundle: .module, comment: "Batch fix tab: location.")
        case .rename: String(localized: "Name", bundle: .module, comment: "Batch fix tab: file names.")
        case .track: String(localized: "GPS Track", bundle: .module, comment: "Batch fix tab: locations from a GPX/KML file.")
        }
    }

    var menuTitle: String {
        switch self {
        case .date:
            PlatformWording.title(
                mac: LocalizedStringResource("Adjust Date and Time…", bundle: .module),
                other: LocalizedStringResource("Adjust date and time…", bundle: .module))
        case .location:
            PlatformWording.title(
                mac: LocalizedStringResource("Set Location…", bundle: .module),
                other: LocalizedStringResource("Set location…", bundle: .module))
        case .rename:
            PlatformWording.title(
                mac: LocalizedStringResource("Rename…", bundle: .module), other: LocalizedStringResource("Rename…", bundle: .module))
        case .track:
            PlatformWording.title(
                mac: LocalizedStringResource("Geotag from GPS Track…", bundle: .module),
                other: LocalizedStringResource("Geotag from GPS track…", bundle: .module))
        }
    }

    var systemImage: String {
        switch self {
        case .date: "calendar.badge.clock"
        case .location: "mappin.and.ellipse"
        case .rename: "character.cursor.ibeam"
        case .track: "point.bottomleft.forward.to.point.topright.scurvepath"
        }
    }
}

/// Opens the batch fixes for some photos (an empty list: the GPS track looks through the whole library).
struct BatchFixRequest: Identifiable {
    let id = UUID()
    var items: [MediaItem]
    var mode: BatchFixMode
}

/// Fix many photos at once: shift capture times or give them a time zone, set one place, rename with a pattern, or
/// take places from a GPS track (SPEC §16.4). Every change is previewed first and can be undone afterwards.
struct BatchFixSheet: View {
    let items: [MediaItem]
    @State var mode: BatchFixMode
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var running: (done: Int, total: Int)?
    @State private var result: BatchFixResult?
    @State private var undoing = false
    /// The edits or names the current tab would apply, as it computes them.
    @State private var pendingEdits: [MetadataEdit] = []
    @State private var pendingNames: [FileID: String] = [:]

    init(items: [MediaItem], mode: BatchFixMode = .date) {
        self.items = items
        _mode = State(initialValue: mode)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    BatchFixResultView(result: result, undoing: undoing) { Task { await undo(result) } }
                } else {
                    VStack(spacing: 0) {
                        if !items.isEmpty {
                            Picker(String(localized: "Change", bundle: .module), selection: $mode) {
                                ForEach(BatchFixMode.allCases) { mode in Text(mode.title).tag(mode) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .padding([.horizontal, .top])
                        }
                        content
                    }
                }
            }
            .navigationTitle(title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .disabled(running != nil)
            .overlay {
                if let running {
                    VStack(spacing: 12) {
                        ProgressView(value: Double(running.done), total: Double(max(running.total, 1)))
                        Text("\(running.done) of \(running.total)", bundle: .module).font(.footnote).monospacedDigit()
                    }
                    .padding(24)
                    .frame(maxWidth: 320)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 520, minHeight: 640)
        #endif
    }

    var title: String {
        if items.isEmpty { return String(localized: "Geotag from GPS Track", bundle: .module) }
        return String(localized: "Fix \(AccessibilityText.items(items.count))", bundle: .module)
    }

    @ViewBuilder var content: some View {
        switch mode {
        case .date: DateFixForm(items: items, edits: $pendingEdits)
        case .location: LocationFixForm(items: items, edits: $pendingEdits)
        case .rename: RenameFixForm(items: items, names: $pendingNames)
        case .track: TrackGeotagForm(items: items, edits: $pendingEdits)
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        if result != nil {
            ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done", bundle: .module)) { dismiss() } }
        } else {
            ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", bundle: .module)) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Apply", bundle: .module)) { Task { await apply() } }
                    .disabled(mode == .rename ? pendingNames.isEmpty : pendingEdits.isEmpty)
            }
        }
    }

    func apply() async {
        running = (0, mode == .rename ? pendingNames.count : pendingEdits.count)
        let progress: @MainActor (Int, Int) -> Void = { done, total in running = (done, total) }
        let outcome: BatchFixResult =
            mode == .rename
            ? await session.rename(pendingNames, progress: progress)
            : await session.applyMetadataEdits(pendingEdits, progress: progress)
        running = nil
        result = outcome
        registerUndo(outcome)
    }

    /// Edit ▸ Undo (⌘Z, shake) takes the fix back too.
    func registerUndo(_ outcome: BatchFixResult) {
        guard let undo = outcome.undo, outcome.changed > 0, let undoManager else { return }
        undoManager.registerUndo(withTarget: session) { session in
            Task { @MainActor in _ = await session.undoBatchFix(undo) }
        }
        undoManager.setActionName(mode.title)
    }

    func undo(_ outcome: BatchFixResult) async {
        guard let undo = outcome.undo else { return }
        undoing = true
        _ = await session.undoBatchFix(undo)
        undoing = false
        undoManager?.removeAllActions()
        dismiss()
    }
}

/// What a fix did: how many photos changed, which could not be changed and why, and Undo.
struct BatchFixResultView: View {
    let result: BatchFixResult
    let undoing: Bool
    let undo: () -> Void

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: result.changed > 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(result.changed > 0 ? Color.green : Color.orange)
                        .symbolEffect(.bounce, value: result.changed)
                    Text("^[\(result.changed) item](inflect: true) changed", bundle: .module).font(.title2.weight(.semibold))
                    if result.rewroteFiles && result.changed > 0 {
                        Text(
                            "This server can't store dates and places separately, so they were written into the files. The previous versions stay in the file's version history.",
                            bundle: .module
                        )
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if result.undo != nil && result.changed > 0 {
                        Button(action: undo) {
                            if undoing {
                                ProgressView()
                            } else {
                                Label(String(localized: "Undo", bundle: .module), systemImage: "arrow.uturn.backward")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(undoing)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }
            if !result.problems.isEmpty {
                Section(String(localized: "Not changed", bundle: .module)) {
                    ForEach(Array(result.problems.enumerated()), id: \.offset) { _, problem in
                        VStack(alignment: .leading) {
                            Text(problem.name).font(.body)
                            Text(problem.reason).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Date and time

struct DateFixForm: View {
    let items: [MediaItem]
    @Binding var edits: [MetadataEdit]
    @Environment(SessionModel.self) private var session
    @State private var setFirst = false
    @State private var firstDate = Date()
    @State private var days = 0
    @State private var hours = 0
    @State private var minutes = 0
    @State private var changeZone = false
    @State private var zoneId = TimeZone.current.identifier

    var sorted: [MediaItem] { items.sorted { $0.timestamp < $1.timestamp } }

    var adjustment: DateAdjustment {
        let zone: TimeZone? = changeZone ? TimeZone(identifier: zoneId) : nil
        var adjustment = DateAdjustment(timeZone: zone)
        if setFirst, let first = sorted.first {
            // The first photo after the zone change, moved to the chosen time.
            let zoned: Date = DateAdjustment(timeZone: zone).adjusted(first)
            adjustment.shift = DateAdjustment.shift(from: zoned, to: firstDate)
        } else {
            let seconds: Int = days * 86_400 + hours * 3600 + minutes * 60
            adjustment.shift = TimeInterval(seconds)
        }
        return adjustment
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Adjust", bundle: .module), selection: $setFirst) {
                    Text("Shift by", bundle: .module).tag(false)
                    Text("Set first photo to", bundle: .module).tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if setFirst {
                    DatePicker(String(localized: "First photo", bundle: .module), selection: $firstDate)
                } else {
                    Stepper(value: $days, in: -3650...3650) {
                        Text("Days: \(days.formatted(.number.sign(strategy: .always(includingZero: false))))", bundle: .module)
                    }
                    Stepper(value: $hours, in: -48...48) {
                        Text("Hours: \(hours.formatted(.number.sign(strategy: .always(includingZero: false))))", bundle: .module)
                    }
                    Stepper(value: $minutes, in: -59...59) {
                        Text("Minutes: \(minutes.formatted(.number.sign(strategy: .always(includingZero: false))))", bundle: .module)
                    }
                }
            } header: {
                Text("Camera clock", bundle: .module)
            } footer: {
                Text("The time between the photos stays the same. Use this when the camera's clock was wrong.", bundle: .module)
            }
            Section {
                Toggle(String(localized: "Taken in another time zone", bundle: .module), isOn: $changeZone)
                if changeZone {
                    NavigationLink {
                        TimeZonePicker(selection: $zoneId)
                    } label: {
                        LabeledContent(String(localized: "Time zone", bundle: .module), value: TimeZonePicker.name(zoneId))
                    }
                }
            } header: {
                Text("Time zone", bundle: .module)
            } footer: {
                Text(
                    "Keeps the time the camera showed and says where it was: for photos from a trip that show the time of home.",
                    bundle: .module)
            }
            Section(String(localized: "Preview", bundle: .module)) {
                ForEach(sorted.prefix(30)) { item in
                    BatchPreviewRow(item: item) {
                        let adjusted: Date = adjustment.adjusted(item)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CaptureTime.format(item.timestamp, offset: item.captureOffset)).strikethrough(!adjustment.isEmpty)
                                .foregroundStyle(.secondary)
                            if !adjustment.isEmpty {
                                Text(CaptureTime.format(adjusted, offset: adjustment.adjustedOffset(item)))
                            }
                        }
                        .font(.footnote)
                    }
                }
                if items.count > 30 { Text("and \(items.count - 30) more", bundle: .module).foregroundStyle(.secondary) }
            }
            WhereItIsWritten(items: items)
        }
        .formStyle(.grouped)
        .onAppear { firstDate = sorted.first?.timestamp ?? Date() }
        .onChange(of: adjustment, initial: true) { _, adjustment in
            edits =
                adjustment.isEmpty
                ? []
                : items.map { MetadataEdit(fileId: $0.fileId, capturedAt: adjustment.adjusted($0), offset: adjustment.adjustedOffset($0)) }
        }
    }
}

/// A photo in a preview list, with what changes.
struct BatchPreviewRow<Detail: View>: View {
    let item: MediaItem
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(spacing: 10) {
            PreviewImage(
                fileId: item.fileId, etag: item.etag, bucket: 64, blurhash: item.blurhash, hasPreview: item.hasPreview,
                mimeType: item.mimeType,
                path: item.path
            )
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline).lineLimit(1)
                detail()
            }
        }
    }
}

/// Where a batch fix writes, and what it skips on this server.
struct WhereItIsWritten: View {
    let items: [MediaItem]
    @Environment(SessionModel.self) private var session

    var body: some View {
        let skipped: Int = items.filter { session.metadataProblem($0) != nil }.count
        Section {
            if session.writesMetadataIntoFiles {
                Label(
                    String(
                        localized:
                            "This server can't store dates and places separately: they are written into the photos, and the previous versions stay in the version history.",
                        bundle: .module), systemImage: "doc.badge.gearshape"
                )
                .font(.footnote)
            }
            if skipped > 0 {
                Label(
                    String(localized: "\(AccessibilityText.items(skipped)) can't be changed and will be skipped.", bundle: .module),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
    }
}

/// A searchable list of time zones.
struct TimeZonePicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    static func name(_ identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return identifier }
        let city = identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
        let offset = zone.secondsFromGMT()
        let hours = offset / 3600
        let minutes = abs(offset % 3600) / 60
        let gmt = minutes == 0 ? String(format: "UTC%+d", hours) : String(format: "UTC%+d:%02d", hours, minutes)
        return "\(city) (\(gmt))"
    }

    var zones: [String] {
        let all: [String] = TimeZone.knownTimeZoneIdentifiers
        guard !query.isEmpty else { return all }
        return all.filter { Self.name($0).localizedCaseInsensitiveContains(query) || $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(zones, id: \.self) { identifier in
            Button {
                selection = identifier
                dismiss()
            } label: {
                HStack {
                    Text(Self.name(identifier))
                    Spacer()
                    if identifier == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
            .buttonStyle(.plain)
        }
        .searchable(text: $query)
        .navigationTitle(String(localized: "Time zone", bundle: .module))
    }
}

// MARK: - Rename

struct RenameFixForm: View {
    let items: [MediaItem]
    @Binding var names: [FileID: String]
    @Environment(SessionModel.self) private var session
    @AppStorage("batchRenamePattern") private var pattern = "{date} {place} {counter}"
    @State private var start = 1
    @State private var existing: [String: Set<String>] = [:]
    @State private var camera: [FileID: CameraDetails] = [:]

    static let tokenTitles: [(String, LocalizedStringResource)] = [
        ("{date}", LocalizedStringResource("Date", bundle: .module)),
        ("{time}", LocalizedStringResource("Time", bundle: .module)),
        ("{place}", LocalizedStringResource("Place", bundle: .module)),
        ("{counter}", LocalizedStringResource("Counter", bundle: .module)),
        ("{name}", LocalizedStringResource("Original name", bundle: .module)),
        ("{camera}", LocalizedStringResource("Camera", bundle: .module)),
        ("{country}", LocalizedStringResource("Country", bundle: .module)),
        ("{year}", LocalizedStringResource("Year", bundle: .module)),
    ]

    var renamable: [MediaItem] { items.filter { $0.permissions.canRename && !$0.isCollectionChild } }

    var computed: [FileID: String] {
        RenamePattern(pattern, start: start).names(for: renamable, camera: camera, existing: existing)
    }

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "Pattern", bundle: .module), text: $pattern)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Self.tokenTitles, id: \.0) { token, title in
                            Button(String(localized: title)) { pattern += pattern.hasSuffix(" ") || pattern.isEmpty ? token : " \(token)" }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                Stepper(value: $start, in: 0...99_999) { Text("Counter starts at \(start)", bundle: .module) }
            } header: {
                Text("New names", bundle: .module)
            } footer: {
                Text(
                    "The counter follows the capture time. Names that are taken get “(2)”. The extension stays; a Live Photo's video gets the same name.",
                    bundle: .module)
            }
            Section(String(localized: "Preview", bundle: .module)) {
                let names: [FileID: String] = computed
                ForEach(items.sorted { $0.timestamp < $1.timestamp }.prefix(40)) { item in
                    BatchPreviewRow(item: item) {
                        if let name = names[item.fileId] {
                            Text(name).font(.footnote.monospaced()).foregroundStyle(name == item.name ? .secondary : .primary)
                        } else {
                            Text("Can't be renamed", bundle: .module).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                }
                if items.count > 40 { Text("and \(items.count - 40) more", bundle: .module).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task {
            guard let services = session.services else { return }
            let store = OrganizeStore(database: services.database)
            existing = (try? store.fileNames(inFolders: Set(items.map(\.directory)))) ?? [:]
            if pattern.contains("{camera}") { camera = (try? store.cameraDetails(of: items.map(\.fileId))) ?? [:] }
        }
        .onChange(of: pattern) { _, value in
            guard value.contains("{camera}"), camera.isEmpty, let services = session.services else { return }
            camera = (try? OrganizeStore(database: services.database).cameraDetails(of: items.map(\.fileId))) ?? [:]
        }
        .onChange(of: computed, initial: true) { _, value in
            names = value.filter { id, name in items.first { $0.fileId == id }?.name != name }
        }
    }
}
