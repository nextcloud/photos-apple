// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import PhotosNetworking
import SwiftUI

/// A file or folder of the user's Nextcloud that can be shared.
struct SharingTarget: Identifiable, Hashable {
    var id: String { path }
    /// Path below the user's root (`/Photos/IMG_1.jpg`).
    var path: String
    var name: String
    var isFolder: Bool

    init(path: String, isFolder: Bool) {
        self.path = path
        self.isFolder = isFolder
        let name = (path as NSString).lastPathComponent
        self.name = name.isEmpty ? path : name
    }

    init(item: MediaItem) {
        self.init(path: item.path, isFolder: false)
    }
}

/// What a recipient may do, as offered in the sharing screens. Maps to `SharePermissions`.
enum ShareRole: String, CaseIterable, Identifiable, Hashable {
    case view, edit
    /// Public links to folders: visitors may also add files.
    case upload
    /// Public links to folders: visitors may only add files, not see any.
    case fileDrop

    var id: String { rawValue }

    /// The roles offered for a share.
    static func roles(for kind: ShareKind, isFolder: Bool, capabilities: SharingCapabilities) -> [ShareRole] {
        switch kind {
        case .link:
            guard isFolder, capabilities.publicUpload else { return [.view] }
            return [.view, .upload, .fileDrop]
        case .email:
            return isFolder && capabilities.publicUpload ? [.view, .upload] : [.view]
        default:
            return [.view, .edit]
        }
    }

    /// The permissions sent for this role. Re-sharing is only offered for "edit", and only when the server allows it.
    func permissions(isFolder: Bool, resharing: Bool) -> SharePermissions {
        switch self {
        case .view: return .viewOnly
        case .edit:
            var permissions: SharePermissions = isFolder ? .folderEdit : .fileEdit
            if !resharing { permissions.remove(.share) }
            return permissions
        case .upload: return .linkUpload
        case .fileDrop: return .linkFileDrop
        }
    }

    /// The role that describes the permissions a share has now.
    init(permissions: SharePermissions, kind: ShareKind, isFolder: Bool) {
        if kind.isPublic && isFolder {
            if permissions == .linkFileDrop {
                self = .fileDrop
            } else if permissions.contains(.create) {
                self = .upload
            } else {
                self = .view
            }
        } else if permissions.contains(.update) || permissions.contains(.create) || permissions.contains(.delete) {
            self = .edit
        } else {
            self = .view
        }
    }

    var title: String {
        switch self {
        case .view: String(localized: "Can view", bundle: .module)
        case .edit: String(localized: "Can edit", bundle: .module)
        case .upload: String(localized: "Can view and upload", bundle: .module)
        case .fileDrop: String(localized: "Upload only (file drop)", bundle: .module)
        }
    }
}

extension ShareKind {
    var symbol: String {
        switch self {
        case .user: "person"
        case .group: "person.2"
        case .link: "link"
        case .email: "envelope"
        case .federated, .federatedGroup: "globe"
        case .team: "person.3"
        case .talkRoom: "bubble.left.and.bubble.right"
        case .other: "square.and.arrow.up"
        }
    }

    /// What kind of recipient this is, under the name in lists.
    var title: String {
        switch self {
        case .user: String(localized: "Person", bundle: .module)
        case .group: String(localized: "Group", bundle: .module)
        case .link: String(localized: "Public link", bundle: .module)
        case .email: String(localized: "Email", bundle: .module)
        case .federated: String(localized: "Person on another server", bundle: .module)
        case .federatedGroup: String(localized: "Group on another server", bundle: .module)
        case .team: String(localized: "Team", bundle: .module)
        case .talkRoom: String(localized: "Talk conversation", bundle: .module)
        case .other: String(localized: "Other share", bundle: .module)
        }
    }
}

/// Loads and changes the shares of one file or folder.
@MainActor
@Observable
final class FileSharingModel {
    let target: SharingTarget
    let api: FilesSharingAPI
    private(set) var capabilities = SharingCapabilities()
    private(set) var shares: [FileShare] = []
    private(set) var loaded = false
    private(set) var working = false
    var error: String?

    init(target: SharingTarget, api: FilesSharingAPI) {
        self.target = target
        self.api = api
    }

    /// Shares with people, groups, other servers, email addresses, Teams and Talk conversations.
    var recipientShares: [FileShare] { shares.filter { $0.kind != .link } }
    var linkShares: [FileShare] { shares.filter { $0.kind == .link } }

    func load() async {
        do {
            capabilities = try await api.capabilities()
            shares = try await api.shares(path: target.path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    func search(_ term: String) async -> [ShareRecipient] {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        let found = (try? await api.searchRecipients(trimmed, isFolder: target.isFolder, kinds: capabilities.recipientKinds)) ?? []
        // Already shared with: not offered again.
        let existing = Set(recipientShares.map { "\($0.kind.rawValue):\($0.shareWith)" })
        return found.filter { !existing.contains($0.id) }
    }

    @discardableResult
    func add(_ recipient: ShareRecipient, role: ShareRole = .view) async -> Bool {
        await perform {
            let share = try await self.api.createShare(
                path: self.target.path, kind: recipient.kind, shareWith: recipient.shareWith,
                permissions: role.permissions(isFolder: self.target.isFolder, resharing: self.capabilities.resharing))
            self.shares.append(share)
        }
    }

    @discardableResult
    func createLink(role: ShareRole, password: String?, expirationDay: String?, label: String?) async -> FileShare? {
        var created: FileShare?
        _ = await perform {
            let share = try await self.api.createShare(
                path: self.target.path, kind: .link,
                permissions: role.permissions(isFolder: self.target.isFolder, resharing: false), password: password,
                expirationDay: expirationDay, label: label)
            self.shares.append(share)
            created = share
        }
        return created
    }

    @discardableResult
    func update(_ share: FileShare, _ update: ShareUpdate) async -> Bool {
        guard !update.isEmpty else { return true }
        return await perform {
            let changed = try await self.api.updateShare(id: share.id, update)
            if let index = self.shares.firstIndex(where: { $0.id == share.id }) { self.shares[index] = changed }
        }
    }

    @discardableResult
    func remove(_ share: FileShare) async -> Bool {
        await perform {
            try await self.api.deleteShare(id: share.id)
            self.shares.removeAll { $0.id == share.id }
        }
    }

    private func perform(_ work: @MainActor () async throws -> Void) async -> Bool {
        working = true
        defer { working = false }
        do {
            try await work()
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

/// Nextcloud's own sharing for a photo or a folder (SPEC SH-7): people and groups, people on other Nextcloud servers,
/// email addresses, Teams, Talk conversations (when the server has Talk), and public links with password, expiry date
/// and permissions. Lists the existing shares; each can be changed or removed.
struct FileSharingSheet: View {
    @State private var model: FileSharingModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ShareRecipient] = []
    @State private var editing: FileShare?
    @State private var creatingLink = false

    init(target: SharingTarget, api: FilesSharingAPI) {
        _model = State(initialValue: FileSharingModel(target: target, api: api))
    }

    var body: some View {
        NavigationStack {
            Form {
                recipientSection
                if !model.recipientShares.isEmpty { existingSection }
                linkSection
                if let error = model.error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .disabled(model.working)
            .overlay {
                if !model.loaded { SkeletonRows(count: 4, thumbnail: 32, circular: true).frame(maxHeight: .infinity, alignment: .top) }
            }
            .navigationTitle(String(localized: "Share “\(model.target.name)”", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
            }
            .task { await model.load() }
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                results = await model.search(query)
            }
            .sheet(item: $editing) { share in
                ShareEditorSheet(model: model, share: share)
            }
            .sheet(isPresented: $creatingLink) {
                ShareEditorSheet(model: model, share: nil)
            }
        }
        .sheetMinimumSize(width: 440, height: 560)
    }

    @ViewBuilder var recipientSection: some View {
        Section {
            TextField(searchPrompt, text: $query)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
            ForEach(results) { recipient in
                Button {
                    Task {
                        if await model.add(recipient) {
                            query = ""
                            results = []
                        }
                    }
                } label: {
                    RecipientLabel(title: recipient.label, kind: recipient.kind, detail: recipient.detail)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Share with", bundle: .module)
        } footer: {
            Text(recipientFooter)
        }
    }

    /// What can be typed into the search field, from what the server offers.
    var searchPrompt: String {
        let caps = model.capabilities
        if caps.talk {
            return String(localized: "Name, email, Talk conversation or user@server", bundle: .module)
        }
        if caps.email && caps.federationOutgoing {
            return String(localized: "Name, email address or user@server", bundle: .module)
        }
        if caps.email { return String(localized: "Name or email address", bundle: .module) }
        return String(localized: "Name or group", bundle: .module)
    }

    var recipientFooter: String {
        var parts = [String(localized: "People and groups on this server", bundle: .module)]
        if model.capabilities.federationOutgoing {
            parts.append(String(localized: "people on other Nextcloud servers (user@server)", bundle: .module))
        }
        if model.capabilities.email { parts.append(String(localized: "anyone by email", bundle: .module)) }
        if model.capabilities.teams { parts.append(String(localized: "Teams", bundle: .module)) }
        if model.capabilities.talk { parts.append(String(localized: "Talk conversations", bundle: .module)) }
        let list = parts.formatted(.list(type: .or))
        return String(localized: "You can share with \(list). The file stays on your server; nothing is uploaded again.", bundle: .module)
    }

    @ViewBuilder var existingSection: some View {
        Section(String(localized: "Shared with", bundle: .module)) {
            ForEach(model.recipientShares) { share in
                Button {
                    editing = share
                } label: {
                    HStack {
                        RecipientLabel(
                            title: share.shareWithDisplayName.isEmpty ? share.shareWith : share.shareWithDisplayName, kind: share.kind,
                            detail: ShareSummary.text(for: share))
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!share.canEdit && !share.canDelete)
            }
        }
    }

    @ViewBuilder var linkSection: some View {
        if model.capabilities.publicLinks || !model.linkShares.isEmpty {
            Section {
                ForEach(model.linkShares) { share in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(share.label.isEmpty ? String(localized: "Public link", bundle: .module) : share.label)
                                .font(.headline)
                            Spacer()
                            Button(String(localized: "Edit", bundle: .module)) { editing = share }
                                .buttonStyle(.borderless)
                                .disabled(!share.canEdit && !share.canDelete)
                        }
                        Text(ShareSummary.text(for: share)).font(.caption).foregroundStyle(.secondary)
                        if let url = share.url { SharedLinkView(url: url) }
                    }
                    .padding(.vertical, 4)
                }
                if model.capabilities.publicLinks {
                    Button {
                        creatingLink = true
                    } label: {
                        Label(String(localized: "Create public link…", bundle: .module), systemImage: "link.badge.plus")
                    }
                }
            } header: {
                Text("Public links", bundle: .module)
            } footer: {
                Text(
                    "Anyone with a link can open it without an account. Protect it with a password or let it expire.", bundle: .module)
            }
        }
    }
}

/// Name, kind and one line of detail of a recipient or share.
struct RecipientLabel: View {
    let title: String
    let kind: ShareKind
    var detail: String = ""

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail.isEmpty ? kind.title : "\(kind.title) · \(detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: kind.symbol)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One line about a share: what the recipient may do, password, expiry.
enum ShareSummary {
    static func text(for share: FileShare, calendar: Calendar = .current) -> String {
        var parts = [ShareRole(permissions: share.permissions, kind: share.kind, isFolder: share.isFolder).title]
        if share.hasPassword { parts.append(String(localized: "password", bundle: .module)) }
        if let date = share.expirationDate(calendar: calendar) {
            let day = date.formatted(date: .abbreviated, time: .omitted)
            parts.append(String(localized: "until \(day)", bundle: .module))
        }
        return parts.joined(separator: " · ")
    }
}

/// Changes an existing share, or creates a public link (`share == nil`).
struct ShareEditorSheet: View {
    let model: FileSharingModel
    let share: FileShare?
    @Environment(\.dismiss) private var dismiss
    @State private var role: ShareRole = .view
    @State private var expires = false
    @State private var expiration = Date().addingTimeInterval(7 * 24 * 3600)
    @State private var usesPassword = false
    @State private var password = ""
    @State private var label = ""
    @State private var note = ""
    @State private var hideDownload = false
    @State private var confirmRemove = false

    var kind: ShareKind { share?.kind ?? .link }
    var isFolder: Bool { model.target.isFolder }
    var caps: SharingCapabilities { model.capabilities }
    var roles: [ShareRole] { ShareRole.roles(for: kind, isFolder: isFolder, capabilities: caps) }
    var passwordEnforced: Bool { kind == .link ? caps.publicPasswordEnforced : kind == .email && caps.emailPasswordEnforced }
    var expiryEnforced: Bool { kind == .link && caps.publicExpiryEnforced }
    /// Only links and email shares have passwords.
    var offersPassword: Bool { kind.isPublic }
    var canEdit: Bool { share?.canEdit ?? true }

    var body: some View {
        NavigationStack {
            Form {
                if let share, kind != .link {
                    Section {
                        RecipientLabel(
                            title: share.shareWithDisplayName.isEmpty ? share.shareWith : share.shareWithDisplayName, kind: share.kind)
                    }
                }
                if roles.count > 1 {
                    Section(String(localized: "Permissions", bundle: .module)) {
                        Picker(String(localized: "Permissions", bundle: .module), selection: $role) {
                            ForEach(roles) { role in Text(role.title).tag(role) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                Section {
                    if offersPassword { passwordRows }
                    Toggle(String(localized: "Set expiration date", bundle: .module), isOn: $expires)
                        .disabled(expiryEnforced)
                    if expires || expiryEnforced {
                        DatePicker(
                            String(localized: "Expires on", bundle: .module), selection: $expiration, in: expiryRange,
                            displayedComponents: .date)
                    }
                    if kind == .link {
                        Toggle(String(localized: "Hide download", bundle: .module), isOn: $hideDownload)
                    }
                } footer: {
                    if expiryEnforced, let days = caps.publicExpiryDays {
                        Text("Your server lets public links stay valid for at most \(days) days.", bundle: .module)
                    }
                }
                Section {
                    if kind == .link {
                        TextField(String(localized: "Label (only you see it)", bundle: .module), text: $label)
                    }
                    TextField(String(localized: "Note to the recipient", bundle: .module), text: $note, axis: .vertical)
                }
                if let share, share.canDelete {
                    Section {
                        Button(stopTitle, role: .destructive) { confirmRemove = true }
                    }
                }
                if let error = model.error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .disabled(model.working || !canEdit)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(share == nil ? String(localized: "Create", bundle: .module) : String(localized: "Save", bundle: .module)) {
                        Task { await save() }
                    }
                    .disabled(!isValid || model.working)
                }
            }
            .confirmationDialog(stopTitle + "?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button(stopTitle, role: .destructive) {
                    Task {
                        if let share, await model.remove(share) { dismiss() }
                    }
                }
            } message: {
                Text(
                    kind == .link
                        ? String(localized: "The link stops working for everyone who has it.", bundle: .module)
                        : String(localized: "The recipient no longer sees this item.", bundle: .module))
            }
            .onAppear(perform: fill)
        }
        .sheetMinimumSize(width: 420, height: 520)
    }

    @ViewBuilder var passwordRows: some View {
        Toggle(String(localized: "Protect with password", bundle: .module), isOn: $usesPassword)
            .disabled(passwordEnforced)
        if usesPassword || passwordEnforced {
            SecureField(
                share?.hasPassword == true
                    ? String(localized: "New password (leave empty to keep it)", bundle: .module)
                    : String(localized: "Password", bundle: .module),
                text: $password)
        }
    }

    var title: String {
        guard let share else { return String(localized: "New public link", bundle: .module) }
        return share.kind == .link ? String(localized: "Public link", bundle: .module) : String(localized: "Share", bundle: .module)
    }

    var stopTitle: String {
        kind == .link ? String(localized: "Delete link", bundle: .module) : String(localized: "Stop sharing", bundle: .module)
    }

    /// From tomorrow; at most the server's limit when it enforces one.
    var expiryRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        let days = expiryEnforced ? (caps.publicExpiryDays ?? 3650) : 3650
        let end = calendar.date(byAdding: .day, value: max(1, days), to: calendar.startOfDay(for: Date())) ?? start
        return start...max(start, end)
    }

    var isValid: Bool {
        let needsPassword = passwordEnforced || usesPassword
        let hasPassword = !password.isEmpty || share?.hasPassword == true
        return !needsPassword || hasPassword
    }

    func fill() {
        guard let share else {
            role = .view
            usesPassword = passwordEnforced
            expires = expiryEnforced
            if expiryEnforced, let days = caps.publicExpiryDays {
                expiration = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? expiration
            }
            return
        }
        role = ShareRole(permissions: share.permissions, kind: share.kind, isFolder: share.isFolder)
        usesPassword = share.hasPassword
        if let date = share.expirationDate() {
            expires = true
            expiration = date
        }
        label = share.label
        note = share.note
        hideDownload = share.hideDownload
    }

    func save() async {
        let day: String? = (expires || expiryEnforced) ? FilesSharingAPI.day(of: expiration) : nil
        guard let share else {
            let created = await model.createLink(
                role: role, password: usesPassword || passwordEnforced ? password : nil, expirationDay: day,
                label: label.isEmpty ? nil : label)
            if let created, hideDownload || !note.isEmpty {
                await model.update(created, ShareUpdate(note: note.isEmpty ? nil : note, hideDownload: hideDownload ? true : nil))
            }
            if created != nil, model.error == nil { dismiss() }
            return
        }
        let passwordChange: PasswordChange
        if !offersPassword {
            passwordChange = .keep
        } else if usesPassword || passwordEnforced {
            passwordChange = password.isEmpty ? .keep : .set(password)
        } else {
            passwordChange = share.hasPassword ? .remove : .keep
        }
        let update = ShareEditorSheet.changes(
            from: share, role: role, isFolder: isFolder, resharing: caps.resharing, password: passwordChange, expirationDay: day,
            label: label, note: note, hideDownload: kind == .link ? hideDownload : nil)
        if await model.update(share, update) { dismiss() }
    }

    enum PasswordChange: Equatable {
        case keep, remove
        case set(String)
    }

    /// What differs between a share and the edited values.
    static func changes(
        from share: FileShare, role: ShareRole, isFolder: Bool, resharing: Bool, password: PasswordChange, expirationDay: String?,
        label: String, note: String, hideDownload: Bool?
    ) -> ShareUpdate {
        var update = ShareUpdate()
        if ShareRole(permissions: share.permissions, kind: share.kind, isFolder: share.isFolder) != role {
            update.permissions = role.permissions(isFolder: isFolder, resharing: resharing && share.kind != .link)
        }
        switch password {
        case .keep: break
        case .remove: update.password = ""
        case .set(let value): update.password = value
        }
        if expirationDay != share.expirationDay { update.expirationDay = expirationDay ?? "" }
        if label != share.label { update.label = label }
        if note != share.note { update.note = note }
        if let hideDownload, hideDownload != share.hideDownload { update.hideDownload = hideDownload }
        return update
    }
}
