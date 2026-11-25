// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// Automations that run after each sync (SPEC §16.4): "new in /Camera/Drone → album Drone", "screenshots older than 30
/// days → archive", "★★★★★ → album Best of". Shared by the user's devices; one device at a time runs them.
struct FolderRulesScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var editing: EditRequest?
    @State private var deleting: FolderRule?
    @State private var lastRun: Int?

    struct EditRequest: Identifiable {
        let id = UUID()
        var rule: FolderRule?
    }

    var rules: [FolderRule] { session.organize?.folderRules ?? [] }

    var body: some View {
        List {
            Section {
                ForEach(rules) { rule in
                    FolderRuleRow(rule: rule) { editing = EditRequest(rule: rule) }
                        .swipeActions {
                            Button(String(localized: "Delete", bundle: .module), role: .destructive) { deleting = rule }
                        }
                        .contextMenu {
                            Button(String(localized: "Edit…", bundle: .module), systemImage: "slider.horizontal.3") {
                                editing = EditRequest(rule: rule)
                            }
                            Button(String(localized: "Delete…", bundle: .module), systemImage: "trash", role: .destructive) {
                                deleting = rule
                            }
                        }
                }
                Button {
                    editing = EditRequest()
                } label: {
                    Label(String(localized: "New Rule…", bundle: .module), systemImage: "plus.circle.fill")
                }
                Menu {
                    ForEach(FolderRuleTemplate.allCases) { template in
                        Button(template.title) { editing = EditRequest(rule: template.rule) }
                    }
                } label: {
                    Label(String(localized: "Start from an Example", bundle: .module), systemImage: "sparkles")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
            } footer: {
                Text(
                    "Rules run after each sync, on one of your devices at a time, and act on new photos. They are kept in your Nextcloud, so all your devices share them.",
                    bundle: .module)
            }
            if !rules.isEmpty {
                Section {
                    Button {
                        Task { lastRun = await session.organize?.runRules(force: true) }
                    } label: {
                        HStack {
                            Label(String(localized: "Run Rules Now", bundle: .module), systemImage: "play.circle")
                            Spacer()
                            if session.organize?.isRunningRules == true { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(session.organize?.isRunningRules == true)
                    if let lastRun {
                        Text("^[\(lastRun) item](inflect: true) handled just now.", bundle: .module).font(.footnote).foregroundStyle(
                            .secondary)
                    }
                }
            }
            let log: [FolderRuleState.LogEntry] = session.organize?.ruleLog ?? []
            if !log.isEmpty {
                Section(String(localized: "Log", bundle: .module)) {
                    ForEach(log.prefix(50)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.ruleName).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(entry.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = entry.error {
                                Text(error).font(.footnote).foregroundStyle(.red)
                            } else {
                                Text("^[\(entry.count) item](inflect: true) · \(entry.device)", bundle: .module).font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Folder Rules", bundle: .module))
        .sheet(item: $editing) { request in FolderRuleEditor(rule: request.rule) }
        .confirmationDialog(
            String(localized: "Delete the rule “\(deleting?.name ?? "")”?", bundle: .module),
            isPresented: Binding(get: { deleting != nil }, set: { shown in if !shown { deleting = nil } }), titleVisibility: .visible,
            presenting: deleting
        ) { (rule: FolderRule) in
            Button(String(localized: "Delete Rule", bundle: .module), role: .destructive) {
                Task { await session.organize?.delete(rule) }
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: { _ in
            Text("It stops on all your devices. What it already did stays.", bundle: .module)
        }
        .task { await session.organize?.sync() }
        .refreshable { await session.organize?.sync(force: true) }
    }
}

/// A rule in the list: its name, what it does, and its switch.
struct FolderRuleRow: View {
    let rule: FolderRule
    let edit: () -> Void
    @Environment(SessionModel.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rule.action.systemImage)
                .font(.title3)
                .foregroundStyle(rule.isEnabled ? Design.accent : .secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name).font(.body.weight(.medium))
                    Text(rule.action.summary).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Toggle(
                String(localized: "Enabled", bundle: .module),
                isOn: Binding(
                    get: { rule.isEnabled },
                    set: { value in
                        var changed = rule
                        changed.isEnabled = value
                        Task { await session.organize?.save(changed) }
                    })
            )
            .labelsHidden()
        }
    }
}

extension FolderRule.Action {
    var systemImage: String {
        switch self {
        case .addToAlbum: "rectangle.stack.badge.plus"
        case .archive: "archivebox"
        case .favorite: "heart"
        case .addTag: "tag"
        }
    }

    var summary: String {
        switch self {
        case .addToAlbum(let name): String(localized: "Add to the album “\(name)”", bundle: .module)
        case .archive: String(localized: "Archive", bundle: .module)
        case .favorite: String(localized: "Add to favorites", bundle: .module)
        case .addTag(let name): String(localized: "Tag with “\(name)”", bundle: .module)
        }
    }
}

/// Ready-made rules to start from.
enum FolderRuleTemplate: String, CaseIterable, Identifiable {
    case drone, screenshots, bestOf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drone: String(localized: "New in a folder → album", bundle: .module)
        case .screenshots: String(localized: "Screenshots older than 30 days → archive", bundle: .module)
        case .bestOf: String(localized: "★★★★★ → album “Best of”", bundle: .module)
        }
    }

    var rule: FolderRule {
        switch self {
        case .drone:
            FolderRule(
                name: String(localized: "Drone photos", bundle: .module), rule: .all([.condition(.folder("/Photos/Camera/Drone"))]),
                action: .addToAlbum(String(localized: "Drone", bundle: .module)))
        case .screenshots:
            FolderRule(
                name: String(localized: "Tidy up screenshots", bundle: .module),
                rule: .all([.condition(.mediaType(.screenshot)), .condition(.olderThanDays(30))]), action: .archive,
                includesExisting: true)
        case .bestOf:
            FolderRule(
                name: String(localized: "Best of", bundle: .module), rule: .all([.condition(.rating(atLeast: 5))]),
                action: .addToAlbum(String(localized: "Best of", bundle: .module)), includesExisting: true)
        }
    }
}

/// Creates or edits a folder rule: when (the same conditions as smart albums), what, and a preview of what it would do now.
struct FolderRuleEditor: View {
    let rule: FolderRule?
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var draft = RuleDraft()
    @State private var actionKind = ActionKind.addToAlbum
    @State private var target = ""
    @State private var includesExisting = false
    @State private var isEnabled = true
    @State private var vocabulary = RuleVocabulary()
    @State private var preview: [MediaItem]?

    enum ActionKind: String, CaseIterable, Identifiable {
        case addToAlbum, archive, favorite, addTag
        var id: String { rawValue }

        var title: String {
            switch self {
            case .addToAlbum: String(localized: "Add to album", bundle: .module)
            case .archive: String(localized: "Archive", bundle: .module)
            case .favorite: String(localized: "Add to favorites", bundle: .module)
            case .addTag: String(localized: "Add tag", bundle: .module)
            }
        }
    }

    var action: FolderRule.Action {
        switch actionKind {
        case .addToAlbum: .addToAlbum(target.trimmingCharacters(in: .whitespaces))
        case .archive: .archive
        case .favorite: .favorite
        case .addTag: .addTag(target.trimmingCharacters(in: .whitespaces))
        }
    }

    var edited: FolderRule {
        var value = rule ?? FolderRule(name: name, rule: draft.rule, action: action)
        value.name = name.trimmingCharacters(in: .whitespaces)
        value.rule = draft.rule
        value.action = action
        value.includesExisting = includesExisting
        value.isEnabled = isEnabled
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Name", bundle: .module), text: $name).font(.title3.weight(.semibold))
                    Toggle(String(localized: "Enabled", bundle: .module), isOn: $isEnabled)
                }
                RuleEditor(draft: $draft, vocabulary: vocabulary, header: String(localized: "When a photo matches", bundle: .module))
                Section {
                    Picker(String(localized: "Action", bundle: .module), selection: $actionKind) {
                        ForEach(ActionKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    if actionKind == .addToAlbum || actionKind == .addTag {
                        HStack {
                            TextField(
                                actionKind == .addToAlbum
                                    ? String(localized: "Album name", bundle: .module) : String(localized: "Tag name", bundle: .module),
                                text: $target
                            )
                            .autocorrectionDisabled()
                            let options: [String] = actionKind == .addToAlbum ? vocabulary.albums : vocabulary.tags
                            if !options.isEmpty {
                                Menu {
                                    ForEach(options.prefix(60), id: \.self) { option in Button(option) { target = option } }
                                } label: {
                                    Image(systemName: "chevron.up.chevron.down")
                                }
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                        }
                    }
                    Toggle(String(localized: "Also photos that are already there", bundle: .module), isOn: $includesExisting)
                } header: {
                    Text("Then", bundle: .module, comment: "Folder rule editor: the action section, after the conditions.")
                } footer: {
                    Text(
                        "Albums and tags that don't exist yet are created. A photo is handled once: if you take it out of the album again, the rule leaves it alone.",
                        bundle: .module)
                }
                Section(String(localized: "Preview", bundle: .module)) {
                    if let preview {
                        Text("Would act on ^[\(preview.count) item](inflect: true) now.", bundle: .module)
                        if !preview.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(preview.prefix(12)) { item in
                                        PreviewImage(
                                            fileId: item.fileId, etag: item.etag, bucket: 256, blurhash: item.blurhash,
                                            hasPreview: item.hasPreview,
                                            mimeType: item.mimeType, path: item.path
                                        )
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                            .accessibilityHidden(true)
                        }
                    } else {
                        Text("Counting…", bundle: .module).foregroundStyle(.secondary)
                    }
                    CameraDetailsNote(needed: draft.rule.needsCameraDetails)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(rule == nil ? String(localized: "New Rule", bundle: .module) : name)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", bundle: .module)) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", bundle: .module)) {
                        let value = edited
                        Task { await session.organize?.save(value) }
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .task {
                if let rule {
                    name = rule.name
                    draft = RuleDraft(rule.rule)
                    includesExisting = rule.includesExisting
                    isEnabled = rule.isEnabled
                    switch rule.action {
                    case .addToAlbum(let value):
                        actionKind = .addToAlbum
                        target = value
                    case .archive: actionKind = .archive
                    case .favorite: actionKind = .favorite
                    case .addTag(let value):
                        actionKind = .addTag
                        target = value
                    }
                }
                vocabulary = await RuleVocabulary.load(session: session)
            }
            .task(id: PreviewKey(rule: draft.rule, action: action, includesExisting: includesExisting)) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let organize = session.organize else { return }
                var candidate = edited
                candidate.isEnabled = true
                // A rule being made counts from now: new photos only, unless it includes the existing ones.
                if rule == nil { candidate.createdAt = Date() }
                preview = draft.isEmpty ? [] : (try? await organize.preview(of: candidate)) ?? []
            }
        }
        #if os(macOS)
            .frame(minWidth: 480, minHeight: 640)
        #endif
    }

    struct PreviewKey: Equatable {
        var rule: SmartRule
        var action: FolderRule.Action
        var includesExisting: Bool
    }

    var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !draft.isEmpty else { return false }
        switch actionKind {
        case .addToAlbum, .addTag: return !target.trimmingCharacters(in: .whitespaces).isEmpty
        case .archive, .favorite: return true
        }
    }
}
