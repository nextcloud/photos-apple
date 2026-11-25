// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// The editable form of a `SmartRule` (SPEC §16.4): "Match all / any / none of" a list of conditions, each of which can
/// be negated, plus groups with their own match mode — two levels, which covers what people build (Anna AND (beach OR
/// lake) AND NOT rejected) without turning the form into a tree.
struct RuleDraft: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case all, any, none
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All", bundle: .module, comment: "Rule builder: match all of the conditions.")
            case .any: String(localized: "Any", bundle: .module, comment: "Rule builder: match any of the conditions.")
            case .none: String(localized: "None", bundle: .module, comment: "Rule builder: match none of the conditions.")
            }
        }

        func combine(_ rules: [SmartRule]) -> SmartRule {
            switch self {
            case .all: .all(rules)
            case .any: .any(rules)
            case .none: .not(.any(rules))
            }
        }
    }

    struct Row: Identifiable, Equatable {
        var id = UUID()
        var condition: SmartCondition
        var negated = false

        var rule: SmartRule { negated ? .not(.condition(condition)) : .condition(condition) }
    }

    struct Group: Identifiable, Equatable {
        var id = UUID()
        var mode: Mode = .any
        var rows: [Row] = []

        var rule: SmartRule { mode.combine(rows.filter { !$0.condition.isIncomplete }.map(\.rule)) }
    }

    var mode: Mode = .all
    var rows: [Row] = []
    var groups: [Group] = []

    init() {}

    init(_ rule: SmartRule) {
        let (mode, children) = Self.split(rule)
        self.mode = mode
        for child in children {
            if let row = Self.row(child) {
                rows.append(row)
            } else {
                let (groupMode, members) = Self.split(child)
                // Deeper levels are kept as conditions of the group (their own structure is flattened).
                groups.append(
                    Group(mode: groupMode, rows: members.flatMap { member in Self.row(member).map { [$0] } ?? Self.rows(member) }))
            }
        }
    }

    static func split(_ rule: SmartRule) -> (Mode, [SmartRule]) {
        switch rule {
        case .all(let rules): (.all, rules)
        case .any(let rules): (.any, rules)
        case .not(.any(let rules)): (.none, rules)
        case .not, .condition: (.all, [rule])
        }
    }

    static func row(_ rule: SmartRule) -> Row? {
        switch rule {
        case .condition(let condition): Row(condition: condition)
        case .not(.condition(let condition)): Row(condition: condition, negated: true)
        default: nil
        }
    }

    static func rows(_ rule: SmartRule) -> [Row] {
        rule.conditions.map { Row(condition: $0) }
    }

    var rule: SmartRule {
        let groupRules: [SmartRule] = groups.filter { $0.rows.contains { !$0.condition.isIncomplete } }.map(\.rule)
        return mode.combine(rows.filter { !$0.condition.isIncomplete }.map(\.rule) + groupRules)
    }

    /// Nothing filled in yet: there is nothing to save.
    var isEmpty: Bool { rule.isEmpty }
}

/// The kinds of condition the builder offers, in menu order.
enum ConditionKind: String, CaseIterable, Identifiable {
    case person, place, tag, album, rating, flag, mediaType, favorite, dateRange, withinLastDays, olderThanDays, folder, name, text
    case camera, lens, focalLength, aperture, iso

    var id: String { rawValue }

    init(_ condition: SmartCondition) {
        switch condition {
        case .person: self = .person
        case .place: self = .place
        case .tag: self = .tag
        case .album: self = .album
        case .rating: self = .rating
        case .flag: self = .flag
        case .mediaType: self = .mediaType
        case .favorite: self = .favorite
        case .dateRange: self = .dateRange
        case .withinLastDays: self = .withinLastDays
        case .olderThanDays: self = .olderThanDays
        case .folder: self = .folder
        case .name: self = .name
        case .text, .unsupported: self = .text
        case .camera: self = .camera
        case .lens: self = .lens
        case .focalLength: self = .focalLength
        case .aperture: self = .aperture
        case .iso: self = .iso
        }
    }

    /// Menu sections: who and where, photo, time, file, camera.
    static let sections: [[ConditionKind]] = [
        [.person, .place, .tag, .album],
        [.rating, .flag, .favorite, .mediaType],
        [.dateRange, .withinLastDays, .olderThanDays],
        [.folder, .name, .text],
        [.camera, .lens, .focalLength, .aperture, .iso],
    ]

    var title: String {
        switch self {
        case .person: String(localized: "Person", bundle: .module)
        case .place: String(localized: "Place", bundle: .module)
        case .tag: String(localized: "Tag", bundle: .module)
        case .album: String(localized: "Album", bundle: .module)
        case .rating: String(localized: "Rating", bundle: .module)
        case .flag: String(localized: "Flag", bundle: .module, comment: "Rule builder condition: pick or reject flag of culling.")
        case .mediaType: String(localized: "Media type", bundle: .module)
        case .favorite: String(localized: "Favorite", bundle: .module)
        case .dateRange: String(localized: "Date range", bundle: .module)
        case .withinLastDays: String(localized: "Taken recently", bundle: .module, comment: "Rule builder: taken within the last N days.")
        case .olderThanDays: String(localized: "Older than", bundle: .module, comment: "Rule builder: taken more than N days ago.")
        case .folder: String(localized: "Folder", bundle: .module)
        case .name: String(localized: "File name", bundle: .module)
        case .text: String(localized: "Any text", bundle: .module, comment: "Rule builder: text in name, place, caption or folder.")
        case .camera: String(localized: "Camera", bundle: .module)
        case .lens: String(localized: "Lens", bundle: .module)
        case .focalLength: String(localized: "Focal length", bundle: .module)
        case .aperture: String(localized: "Aperture", bundle: .module)
        case .iso: String(localized: "ISO", bundle: .module)
        }
    }

    var systemImage: String {
        switch self {
        case .person: "person.crop.circle"
        case .place: "mappin.and.ellipse"
        case .tag: "tag"
        case .album: "rectangle.stack"
        case .rating: "star"
        case .flag: "flag"
        case .mediaType: "photo.on.rectangle"
        case .favorite: "heart"
        case .dateRange: "calendar"
        case .withinLastDays: "clock.arrow.circlepath"
        case .olderThanDays: "clock.badge.exclamationmark"
        case .folder: "folder"
        case .name: "doc.text"
        case .text: "text.magnifyingglass"
        case .camera: "camera"
        case .lens: "camera.aperture"
        case .focalLength: "scope"
        case .aperture: "camera.aperture"
        case .iso: "dial.medium"
        }
    }

    /// A new condition of this kind, with a value that makes sense before the user changes it.
    func makeCondition(vocabulary: RuleVocabulary, now: Date = Date()) -> SmartCondition {
        switch self {
        case .person: .person(vocabulary.people.first ?? "")
        case .place: .place(vocabulary.places.first ?? "")
        case .tag: .tag(vocabulary.tags.first ?? "")
        case .album: .album(vocabulary.albums.first ?? "")
        case .rating: .rating(atLeast: 4)
        case .flag: .flag(.pick)
        case .mediaType: .mediaType(.photo)
        case .favorite: .favorite
        case .dateRange:
            .dateRange(start: Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now, end: now)
        case .withinLastDays: .withinLastDays(30)
        case .olderThanDays: .olderThanDays(30)
        case .folder: .folder(vocabulary.folders.first ?? "/Photos")
        case .name: .name("")
        case .text: .text("")
        case .camera: .camera(vocabulary.cameras.first ?? "")
        case .lens: .lens(vocabulary.lenses.first ?? "")
        case .focalLength: .focalLength(min: 10, max: 35)
        case .aperture: .aperture(min: nil, max: 2.8)
        case .iso: .iso(min: 1600, max: nil)
        }
    }
}

/// What the pickers offer: names from the index.
struct RuleVocabulary: Equatable {
    var people: [String] = []
    var places: [String] = []
    var tags: [String] = []
    var albums: [String] = []
    var folders: [String] = []
    var cameras: [String] = []
    var lenses: [String] = []

    @MainActor static func load(session: SessionModel) async -> RuleVocabulary {
        guard let services = session.services else { return RuleVocabulary() }
        var vocabulary = RuleVocabulary()
        let labels = LabelStore(database: services.database)
        let organize = OrganizeStore(database: services.database)
        vocabulary.people = ((try? labels.personNames()) ?? []).filter { Int($0) == nil }.sorted(by: Self.order)
        vocabulary.places = ((try? await services.library.placeNames()) ?? []).sorted(by: Self.order)
        vocabulary.tags = ((try? labels.tags()) ?? []).filter(\.isUserVisible).map(\.name).sorted(by: Self.order)
        vocabulary.albums = ((try? services.collections.albums(.own)) ?? []).map(\.title).sorted(by: Self.order)
        vocabulary.folders = (try? await organize.folders()) ?? []
        if let cameras = try? await organize.cameraVocabulary() {
            vocabulary.cameras = cameras.cameras
            vocabulary.lenses = cameras.lenses
        }
        return vocabulary
    }

    static func order(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }

    func suggestions(for kind: ConditionKind) -> [String] {
        switch kind {
        case .person: people
        case .place: places
        case .tag: tags
        case .album: albums
        case .folder: folders
        case .camera: cameras
        case .lens: lenses
        default: []
        }
    }
}

/// The conditions of a rule as form sections. Used by the smart album builder and the folder rule editor.
struct RuleEditor: View {
    @Binding var draft: RuleDraft
    let vocabulary: RuleVocabulary
    /// "Photos match", "Photos that match" — the sentence the mode picker completes.
    var header: String = String(localized: "Include photos that match", bundle: .module)

    var body: some View {
        Section {
            Picker(header, selection: $draft.mode) {
                ForEach(RuleDraft.Mode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            ForEach($draft.rows) { $row in
                ConditionRow(row: $row, vocabulary: vocabulary) { draft.rows.removeAll { $0.id == row.id } }
            }
            .onDelete { draft.rows.remove(atOffsets: $0) }
            AddConditionMenu(vocabulary: vocabulary) { condition in draft.rows.append(RuleDraft.Row(condition: condition)) }
        } header: {
            Text("Conditions", bundle: .module)
        } footer: {
            Text(modeExplanation(draft.mode))
        }
        ForEach($draft.groups) { $group in
            Section {
                Picker(
                    String(localized: "Match", bundle: .module, comment: "Rule builder group: match all/any/none of."),
                    selection: $group.mode
                ) {
                    ForEach(RuleDraft.Mode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                ForEach($group.rows) { $row in
                    ConditionRow(row: $row, vocabulary: vocabulary) { group.rows.removeAll { $0.id == row.id } }
                }
                .onDelete { group.rows.remove(atOffsets: $0) }
                AddConditionMenu(vocabulary: vocabulary) { condition in group.rows.append(RuleDraft.Row(condition: condition)) }
                Button(String(localized: "Remove Group", bundle: .module), role: .destructive) {
                    draft.groups.removeAll { $0.id == group.id }
                }
            } header: {
                Text("Group", bundle: .module, comment: "Rule builder: a group of conditions with its own all/any/none.")
            }
        }
        Section {
            Button {
                draft.groups.append(RuleDraft.Group())
            } label: {
                Label(String(localized: "Add Group", bundle: .module), systemImage: "square.stack.3d.down.right")
            }
        } footer: {
            Text("A group combines its own conditions, for example “beach or lake”, and counts as one condition above.", bundle: .module)
        }
    }

    func modeExplanation(_ mode: RuleDraft.Mode) -> String {
        switch mode {
        case .all: String(localized: "A photo is included when every condition is true.", bundle: .module)
        case .any: String(localized: "A photo is included when at least one condition is true.", bundle: .module)
        case .none: String(localized: "A photo is included when no condition is true.", bundle: .module)
        }
    }
}

/// "+ Add Condition" with the kinds in sections.
struct AddConditionMenu: View {
    let vocabulary: RuleVocabulary
    let add: (SmartCondition) -> Void

    var body: some View {
        Menu {
            ForEach(Array(ConditionKind.sections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(section) { kind in
                        Button {
                            add(kind.makeCondition(vocabulary: vocabulary))
                        } label: {
                            Label(kind.title, systemImage: kind.systemImage)
                        }
                    }
                }
            }
        } label: {
            // The whole row opens the menu, as a button row does.
            Label(String(localized: "Add Condition", bundle: .module), systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
    }
}

/// One condition: its kind, "is / is not", and its value. Menus rather than pickers: a picker inside a form row takes
/// the row over on iPhone.
struct ConditionRow: View {
    @Binding var row: RuleDraft.Row
    let vocabulary: RuleVocabulary
    let remove: () -> Void

    var kind: ConditionKind { ConditionKind(row.condition) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(Array(ConditionKind.sections.enumerated()), id: \.offset) { _, section in
                        Section {
                            ForEach(section) { option in
                                Button {
                                    row.condition = option.makeCondition(vocabulary: vocabulary)
                                } label: {
                                    Label(option.title, systemImage: option.systemImage)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: kind.systemImage)
                        Text(kind.title).fontWeight(.semibold)
                    }
                }
                .accessibilityLabel(String(localized: "Condition: \(kind.title)", bundle: .module))
                Menu {
                    Button(positiveWord) { row.negated = false }
                    Button(negativeWord) { row.negated = true }
                } label: {
                    HStack(spacing: 3) {
                        Text(verbatim: row.negated ? negativeWord : positiveWord)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(role: .destructive, action: remove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Remove Condition", bundle: .module))
            }
            .buttonStyle(.borderless)
            ConditionValueEditor(condition: $row.condition, vocabulary: vocabulary)
        }
        .padding(.vertical, 2)
    }

    var positiveWord: String {
        switch kind {
        case .favorite: String(localized: "is a favorite", bundle: .module)
        case .name, .text, .camera, .lens, .folder: String(localized: "contains", bundle: .module, comment: "Rule builder operator.")
        case .dateRange, .focalLength, .aperture, .iso: String(localized: "is within", bundle: .module, comment: "Rule builder operator.")
        default: String(localized: "is", bundle: .module, comment: "Rule builder operator.")
        }
    }

    var negativeWord: String {
        switch kind {
        case .favorite: String(localized: "is not a favorite", bundle: .module)
        case .name, .text, .camera, .lens, .folder:
            String(localized: "does not contain", bundle: .module, comment: "Rule builder operator.")
        case .dateRange, .focalLength, .aperture, .iso: String(localized: "is outside", bundle: .module, comment: "Rule builder operator.")
        default: String(localized: "is not", bundle: .module, comment: "Rule builder operator.")
        }
    }
}

/// The value part of a condition.
struct ConditionValueEditor: View {
    @Binding var condition: SmartCondition
    let vocabulary: RuleVocabulary

    var body: some View {
        switch condition {
        case .person(let value): textField(value, .person) { .person($0) }
        case .place(let value): textField(value, .place) { .place($0) }
        case .tag(let value): textField(value, .tag) { .tag($0) }
        case .album(let value): textField(value, .album) { .album($0) }
        case .folder(let value): textField(value, .folder) { .folder($0) }
        case .name(let value): textField(value, .name) { .name($0) }
        case .text(let value): textField(value, .text) { .text($0) }
        case .camera(let value): textField(value, .camera) { .camera($0) }
        case .lens(let value): textField(value, .lens) { .lens($0) }
        case .rating(let stars): ratingPicker(stars)
        case .flag(let flag): flagPicker(flag)
        case .mediaType(let type): mediaTypePicker(type)
        case .favorite: EmptyView()
        case .dateRange(let start, let end): dateRange(start, end)
        case .withinLastDays(let days): daysStepper(days) { .withinLastDays($0) }
        case .olderThanDays(let days): daysStepper(days) { .olderThanDays($0) }
        case .focalLength(let min, let max): range(min, max, unit: "mm") { .focalLength(min: $0, max: $1) }
        case .aperture(let min, let max): range(min, max, unit: "ƒ/") { .aperture(min: $0, max: $1) }
        case .iso(let min, let max): range(min, max, unit: "ISO") { .iso(min: $0, max: $1) }
        case .unsupported:
            Text("Made with a newer version of the app; it matches nothing here.", bundle: .module).font(.footnote).foregroundStyle(
                .secondary)
        }
    }

    func textField(_ value: String, _ kind: ConditionKind, make: @escaping (String) -> SmartCondition) -> some View {
        let binding: Binding<String> = Binding(get: { value }, set: { condition = make($0) })
        let suggestions: [String] = vocabulary.suggestions(for: kind)
        return HStack {
            TextField(kind.title, text: binding)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions.prefix(60), id: \.self) { suggestion in
                        Button(suggestion) { condition = make(suggestion) }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(String(localized: "Choose \(kind.title)", bundle: .module))
            }
        }
    }

    func ratingPicker(_ stars: Int) -> some View {
        HStack {
            Text("At least", bundle: .module)
            Spacer()
            ForEach(1...CullingTags.maxRating, id: \.self) { value in
                Button {
                    condition = .rating(atLeast: value)
                } label: {
                    Image(systemName: value <= stars ? "star.fill" : "star").foregroundStyle(value <= stars ? Color.yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "\(value) stars", bundle: .module))
            }
        }
    }

    func flagPicker(_ flag: CullingFlag) -> some View {
        let binding: Binding<CullingFlag> = Binding(get: { flag }, set: { condition = .flag($0) })
        return Picker(String(localized: "Flag", bundle: .module), selection: binding) {
            Text("Picked", bundle: .module).tag(CullingFlag.pick)
            Text("Rejected", bundle: .module).tag(CullingFlag.reject)
            Text("Unflagged", bundle: .module).tag(CullingFlag.none)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    func mediaTypePicker(_ type: SmartMediaType) -> some View {
        Menu {
            ForEach(SmartMediaType.allCases, id: \.self) { value in
                Button(value.title) { condition = .mediaType(value) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(type.title)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .buttonStyle(.borderless)
    }

    func dateRange(_ start: Date, _ end: Date) -> some View {
        // The end is stored exclusive; the picker shows the last included day.
        let lastDay: Date = end.addingTimeInterval(-1)
        let from: Binding<Date> = Binding(
            get: { start },
            set: { value in condition = .dateRange(start: Calendar.current.startOfDay(for: value), end: Swift.max(end, value)) })
        let to: Binding<Date> = Binding(
            get: { lastDay },
            set: { value in
                let next: Date = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: value)) ?? value
                condition = .dateRange(start: Swift.min(start, value), end: next)
            })
        return VStack {
            DatePicker(String(localized: "From", bundle: .module), selection: from, displayedComponents: .date)
            DatePicker(String(localized: "To", bundle: .module), selection: to, displayedComponents: .date)
        }
    }

    func daysStepper(_ days: Int, make: @escaping (Int) -> SmartCondition) -> some View {
        let binding: Binding<Int> = Binding(get: { days }, set: { condition = make(Swift.max(1, $0)) })
        return Stepper(value: binding, in: 1...3650) {
            Text("\(days) days", bundle: .module)
        }
    }

    func range(_ low: Double?, _ high: Double?, unit: String, make: @escaping (Double?, Double?) -> SmartCondition) -> some View {
        let lowText: Binding<String> = Binding(
            get: { low.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "" },
            set: { condition = make(Double($0.replacingOccurrences(of: ",", with: ".")), high) })
        let highText: Binding<String> = Binding(
            get: { high.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "" },
            set: { condition = make(low, Double($0.replacingOccurrences(of: ",", with: "."))) })
        return HStack {
            TextField(String(localized: "From", bundle: .module), text: lowText).textFieldStyle(.roundedBorder)
            Text(verbatim: "–")
            TextField(String(localized: "To", bundle: .module), text: highText).textFieldStyle(.roundedBorder)
            Text(verbatim: unit).foregroundStyle(.secondary)
        }
        #if os(iOS) || os(visionOS)
            .keyboardType(.decimalPad)
        #endif
    }
}

extension SmartMediaType {
    var title: String {
        switch self {
        case .photo: String(localized: "Photo", bundle: .module)
        case .video: String(localized: "Video", bundle: .module)
        case .livePhoto: String(localized: "Live Photo", bundle: .module)
        case .screenshot: String(localized: "Screenshot", bundle: .module)
        case .raw: String(localized: "RAW", bundle: .module)
        case .panorama: String(localized: "Panorama", bundle: .module)
        }
    }
}
