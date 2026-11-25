// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// Creates or edits a smart album from rules, with a live count and the first matching photos (SPEC §16.4).
struct SmartAlbumBuilder: View {
    /// The album being edited; nil for a new one.
    let album: SmartAlbumDefinition?
    var initialRule: SmartRule?
    var onSave: ((SmartAlbumDefinition) -> Void)?

    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var draft = RuleDraft()
    @State private var sort: SmartAlbumDefinition.Sort = .newestFirst
    @State private var limited = false
    @State private var limit = 100
    @State private var vocabulary = RuleVocabulary()
    @State private var count: Int?
    @State private var sample: [MediaItem] = []
    @State private var counting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Name", bundle: .module), text: $name)
                        .font(.title3.weight(.semibold))
                } footer: {
                    Text(
                        "Smart albums fill themselves with the photos that match, and are kept in your Nextcloud so your other devices have them too.",
                        bundle: .module)
                }
                previewSection
                RuleEditor(draft: $draft, vocabulary: vocabulary)
                Section(String(localized: "Order", bundle: .module)) {
                    Picker(String(localized: "Sort", bundle: .module), selection: $sort) {
                        Text("Newest first", bundle: .module).tag(SmartAlbumDefinition.Sort.newestFirst)
                        Text("Oldest first", bundle: .module).tag(SmartAlbumDefinition.Sort.oldestFirst)
                    }
                    Toggle(String(localized: "Limit the number of photos", bundle: .module), isOn: $limited)
                    if limited {
                        Stepper(value: $limit, in: 10...5000, step: 10) {
                            Text("\(limit) photos", bundle: .module)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(
                album == nil
                    ? String(localized: "New Smart Album", bundle: .module) : String(localized: "Edit Smart Album", bundle: .module)
            )
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", bundle: .module)) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", bundle: .module)) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || draft.isEmpty)
                }
            }
            .task {
                if let album {
                    name = album.name
                    draft = RuleDraft(album.rule)
                    sort = album.sort
                    if let value = album.limit {
                        limited = true
                        limit = value
                    }
                } else if let initialRule {
                    draft = RuleDraft(initialRule)
                }
                vocabulary = await RuleVocabulary.load(session: session)
            }
            // Counted again after every change, a moment after the last one, and as camera details arrive.
            .task(id: CountKey(rule: draft.rule, cameraDetails: session.organize?.cameraProgress?.read ?? 0)) { await recount() }
        }
        #if os(macOS)
            .frame(minWidth: 480, minHeight: 640)
        #endif
    }

    var previewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    if let count {
                        Text("^[\(count) photo](inflect: true)", bundle: .module)
                            .font(Typography.figure)
                            .contentTransition(.numericText(value: Double(count)))
                            .animation(.snappy, value: count)
                    } else {
                        Text("Counting…", bundle: .module).font(Typography.figure).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if counting { ProgressView().controlSize(.small) }
                }
                if !sample.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(sample) { item in
                                PreviewImage(
                                    fileId: item.fileId, etag: item.etag, bucket: 256, blurhash: item.blurhash, hasPreview: item.hasPreview,
                                    mimeType: item.mimeType, path: item.path
                                )
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .accessibilityHidden(true)
                }
                CameraDetailsNote(needed: draft.rule.needsCameraDetails)
            }
            .padding(.vertical, 4)
        }
    }

    struct CountKey: Equatable {
        var rule: SmartRule
        var cameraDetails: Int
    }

    func recount() async {
        guard let organize = session.organize else { return }
        // Waits for typing to pause.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        counting = true
        defer { counting = false }
        if let result = try? await organize.preview(of: draft.rule) {
            guard !Task.isCancelled else { return }
            count = result.count
            sample = result.sample
        }
    }

    func save() {
        var saved = album ?? SmartAlbumDefinition(name: name, rule: draft.rule)
        saved.name = name.trimmingCharacters(in: .whitespaces)
        saved.rule = draft.rule
        saved.sort = sort
        saved.limit = limited ? limit : nil
        let result = saved
        Task {
            await session.organize?.save(result)
            onSave?(result)
        }
        dismiss()
    }
}

/// While a rule asks about cameras: how many photos' camera details are read, and reading the rest.
struct CameraDetailsNote: View {
    let needed: Bool
    @Environment(SessionModel.self) private var session

    var body: some View {
        if needed, let organize = session.organize {
            Group {
                if let progress = organize.cameraProgress, progress.read < progress.total {
                    Label {
                        Text(
                            "Reading camera details: \(progress.read.formatted()) of \(progress.total.formatted()) photos. The count grows while this runs.",
                            bundle: .module)
                    } icon: {
                        Image(systemName: "camera.badge.clock")
                    }
                } else if organize.cameraProgress == nil {
                    Label(String(localized: "Reading camera details…", bundle: .module), systemImage: "camera.badge.clock")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .task {
                await organize.refreshCameraProgress()
                organize.readCameraDetails()
            }
            .onChange(of: organize.isReadingCameraDetails) { _, reading in
                if !reading { Task { await organize.refreshCameraProgress() } }
            }
        }
    }
}
