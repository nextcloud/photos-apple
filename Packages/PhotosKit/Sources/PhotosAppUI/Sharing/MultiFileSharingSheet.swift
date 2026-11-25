// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import PhotosNetworking
import SwiftUI

/// Shares of several photos at once (SPEC SH-7). Nextcloud shares one file or folder per share, so every photo gets a
/// share of its own for every recipient, made a few at a time; what failed is listed with the server's reason.
enum ShareBatch {
    struct Job: Hashable, Sendable {
        var path: String
        var recipient: ShareRecipient
    }

    struct Failure: Hashable, Sendable {
        var path: String
        var recipient: String
        var message: String

        /// "IMG_1.jpg · Anna: Path is already shared with this user".
        var text: String { "\((path as NSString).lastPathComponent) · \(recipient): \(message)" }
    }

    struct Outcome: Equatable, Sendable {
        var total = 0
        var shared = 0
        var failures: [Failure] = []

        var isComplete: Bool { failures.isEmpty && shared == total }
    }

    /// Every photo with every recipient.
    static func jobs(paths: [String], recipients: [ShareRecipient]) -> [Job] {
        recipients.flatMap { recipient in paths.map { Job(path: $0, recipient: recipient) } }
    }

    /// Runs the jobs, `parallel` at a time, and reports how many are through after each one.
    @MainActor
    static func run(
        _ jobs: [Job], parallel: Int = 4, create: @escaping @Sendable (Job) async throws -> Void,
        progress: (Int) -> Void = { _ in }
    ) async -> Outcome {
        var outcome = Outcome(total: jobs.count)
        /// The server's reason for each job that failed, by the job's index.
        var errors: [Int: String] = [:]
        await withTaskGroup(of: (Int, String?).self) { group in
            var next = 0
            func start(_ index: Int) {
                let job: Job = jobs[index]
                group.addTask {
                    do {
                        try await create(job)
                        return (index, nil)
                    } catch {
                        return (index, error.localizedDescription)
                    }
                }
            }
            while next < min(max(1, parallel), jobs.count) {
                start(next)
                next += 1
            }
            var done = 0
            for await (index, error) in group {
                if let error { errors[index] = error } else { outcome.shared += 1 }
                done += 1
                progress(done)
                if next < jobs.count {
                    start(next)
                    next += 1
                }
            }
        }
        // In the order the photos were given, not the order the server answered in.
        outcome.failures = errors.keys.sorted().map { index in
            Failure(path: jobs[index].path, recipient: jobs[index].recipient.label, message: errors[index] ?? "")
        }
        return outcome
    }

    /// The recipients offered for several photos: everyone the server allows except email addresses, which would get one
    /// email per photo; a public link (an album) is the way to send several photos by email.
    static func recipientKinds(_ capabilities: SharingCapabilities) -> [ShareKind] {
        capabilities.recipientKinds.filter { $0 != .email }
    }
}

/// Nextcloud's own sharing of several photos (SPEC SH-7): pick people, groups, people on other servers, Teams or Talk
/// conversations and what they may do; every photo is shared with each of them. A public link to all of them is an
/// album with a link (quick share, SH-4), since a Nextcloud link points to one file or folder.
struct MultiFileSharingSheet: View {
    let items: [MediaItem]
    let api: FilesSharingAPI
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var capabilities = SharingCapabilities()
    @State private var loaded = false
    @State private var query = ""
    @State private var results: [ShareRecipient] = []
    @State private var recipients: [ShareRecipient] = []
    @State private var role: ShareRole = .view
    @State private var note = ""
    @State private var done: Int?
    @State private var outcome: ShareBatch.Outcome?
    @State private var link: URL?
    @State private var creatingLink = false
    @State private var error: String?

    var running: Bool { done != nil && outcome == nil }

    var body: some View {
        NavigationStack {
            Form {
                recipientSection
                if !recipients.isEmpty { chosenSection }
                optionsSection
                if let done, outcome == nil {
                    Section {
                        ProgressView(value: Double(done), total: Double(max(1, jobCount))) {
                            Text("Sharing…", bundle: .module)
                        }
                    }
                }
                if let outcome { outcomeSection(outcome) }
                if session.features.has(.photosDAV) { linkSection }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .disabled(running || creatingLink)
            .overlay {
                if !loaded { SkeletonRows(count: 4, thumbnail: 32, circular: true).frame(maxHeight: .infinity, alignment: .top) }
            }
            .navigationTitle(String(localized: "Share \(items.count) photos", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(outcome == nil ? String(localized: "Cancel", bundle: .module) : String(localized: "Done", bundle: .module)) {
                        dismiss()
                    }
                    .disabled(running)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Share", bundle: .module)) { Task { await share() } }
                        .disabled(recipients.isEmpty || running || outcome != nil)
                }
            }
            .task {
                capabilities = (try? await api.capabilities()) ?? SharingCapabilities()
                loaded = true
            }
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                results = await search(query)
            }
        }
        .frame(minWidth: 440, minHeight: 560)
    }

    var jobCount: Int { items.count * recipients.count }

    @ViewBuilder var recipientSection: some View {
        Section {
            TextField(String(localized: "Name, group, Talk conversation or user@server", bundle: .module), text: $query)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
            ForEach(results) { recipient in
                Button {
                    recipients.append(recipient)
                    query = ""
                    results = []
                } label: {
                    RecipientLabel(title: recipient.label, kind: recipient.kind, detail: recipient.detail)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Share with", bundle: .module)
        } footer: {
            Text(
                "Each photo is shared on its own, and recipients find the photos in “Shared with you”. To send them by email, create a public link instead.",
                bundle: .module)
        }
        .disabled(outcome != nil)
    }

    var chosenSection: some View {
        Section(String(localized: "Recipients", bundle: .module)) {
            ForEach(recipients) { recipient in
                HStack {
                    RecipientLabel(title: recipient.label, kind: recipient.kind, detail: recipient.detail)
                    Spacer()
                    if outcome == nil {
                        Button {
                            recipients.removeAll { $0.id == recipient.id }
                        } label: {
                            Label(String(localized: "Remove", bundle: .module), systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder var optionsSection: some View {
        let roles: [ShareRole] = ShareRole.roles(for: .user, isFolder: false, capabilities: capabilities)
        Section {
            if roles.count > 1 {
                Picker(String(localized: "Permissions", bundle: .module), selection: $role) {
                    ForEach(roles) { role in Text(role.title).tag(role) }
                }
            }
            TextField(String(localized: "Note to the recipient", bundle: .module), text: $note, axis: .vertical)
        }
        .disabled(outcome != nil)
    }

    func outcomeSection(_ outcome: ShareBatch.Outcome) -> some View {
        Section {
            Label {
                Text("Shares created: \(outcome.shared) of \(outcome.total)", bundle: .module)
            } icon: {
                Image(systemName: outcome.isComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(outcome.isComplete ? .green : .orange)
            }
            ForEach(outcome.failures.prefix(20), id: \.self) { failure in
                Text(failure.text).font(.caption).foregroundStyle(.secondary)
            }
            if outcome.failures.count > 20 {
                Text("And \(outcome.failures.count - 20) more", bundle: .module).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A link to all the photos: a new album "Shared on <date>" with a public link (SH-4). Only own photos can go into it.
    @ViewBuilder var linkSection: some View {
        Section {
            if let link {
                SharedLinkView(url: link, showsQRCode: true)
            } else {
                Button {
                    Task { await createLink() }
                } label: {
                    Label(String(localized: "Create album with public link", bundle: .module), systemImage: "link.badge.plus")
                }
                .disabled(!items.contains(where: \.isOwnStorage))
            }
        } header: {
            Text("Public link", bundle: .module)
        } footer: {
            Text(
                "A Nextcloud link opens one file or folder. For several photos, an album with these photos is created; anyone with its link can see them.",
                bundle: .module)
        }
    }

    func search(_ term: String) async -> [ShareRecipient] {
        let trimmed: String = term.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        let found: [ShareRecipient] =
            (try? await api.searchRecipients(trimmed, isFolder: false, kinds: ShareBatch.recipientKinds(capabilities))) ?? []
        let chosen = Set(recipients.map(\.id))
        return found.filter { !chosen.contains($0.id) }
    }

    func share() async {
        let jobs: [ShareBatch.Job] = ShareBatch.jobs(paths: items.map(\.path), recipients: recipients)
        let api: FilesSharingAPI = api
        let permissions: SharePermissions = role.permissions(isFolder: false, resharing: capabilities.resharing)
        let note: String? = note.isEmpty ? nil : note
        done = 0
        outcome = await ShareBatch.run(
            jobs,
            create: { job in
                _ = try await api.createShare(
                    path: job.path, kind: job.recipient.kind, shareWith: job.recipient.shareWith, permissions: permissions, note: note)
            },
            progress: { count in done = count })
    }

    func createLink() async {
        creatingLink = true
        defer { creatingLink = false }
        do {
            link = try await session.quickShare(items)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
