// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What a share gives its recipient (`permissions` of the OCS Files Sharing API).
public struct SharePermissions: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let read = SharePermissions(rawValue: 1)
    public static let update = SharePermissions(rawValue: 2)
    public static let create = SharePermissions(rawValue: 4)
    public static let delete = SharePermissions(rawValue: 8)
    public static let share = SharePermissions(rawValue: 16)

    /// View only.
    public static let viewOnly: SharePermissions = [.read]
    /// Everything a recipient may do with a file: view, change, share again.
    public static let fileEdit: SharePermissions = [.read, .update, .share]
    /// Everything a recipient may do with a folder.
    public static let folderEdit: SharePermissions = [.read, .update, .create, .delete, .share]
    /// A public link that lets visitors view and upload into a folder.
    public static let linkUpload: SharePermissions = [.read, .update, .create, .delete]
    /// A public link that only takes uploads ("file drop").
    public static let linkFileDrop: SharePermissions = [.create]
}

/// Who or what a share goes to (`share_type`).
public enum ShareKind: Hashable, Sendable {
    case user, group, link, email, federated, team, talkRoom, federatedGroup
    /// A type this app does not know (Deck, ScienceMesh …): listed, not edited.
    case other(Int)

    public init(rawValue: Int) {
        switch rawValue {
        case 0: self = .user
        case 1: self = .group
        case 3: self = .link
        case 4: self = .email
        case 6: self = .federated
        case 7: self = .team
        case 9: self = .federatedGroup
        case 10: self = .talkRoom
        default: self = .other(rawValue)
        }
    }

    public var rawValue: Int {
        switch self {
        case .user: 0
        case .group: 1
        case .link: 3
        case .email: 4
        case .federated: 6
        case .team: 7
        case .federatedGroup: 9
        case .talkRoom: 10
        case .other(let value): value
        }
    }

    /// Shares whose recipient can open the file without an account on this server (a link, an email).
    public var isPublic: Bool { self == .link || self == .email }
}

/// A share of a file or folder (`GET /ocs/v2.php/apps/files_sharing/api/v1/shares`).
public struct FileShare: Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: ShareKind
    public var ownerId: String
    public var ownerDisplayName: String
    /// Path of the shared node as the requesting user sees it.
    public var path: String
    /// Where the share appears for the recipient (`file_target`).
    public var target: String
    public var isFolder: Bool
    public var permissions: SharePermissions
    /// User id, group id, email address, federated cloud id or room token; empty for a link.
    public var shareWith: String
    public var shareWithDisplayName: String
    /// The day the share ends (`YYYY-MM-DD`), when it has one.
    public var expirationDay: String?
    /// A link or email share that is protected by a password (the server never sends the password itself).
    public var hasPassword: Bool
    public var token: String?
    public var url: URL?
    public var label: String
    public var note: String
    public var hideDownload: Bool
    public var canEdit: Bool
    public var canDelete: Bool
    public var createdAt: Date?

    public init(
        id: String, kind: ShareKind, ownerId: String = "", ownerDisplayName: String = "", path: String, target: String = "",
        isFolder: Bool = false, permissions: SharePermissions = .viewOnly, shareWith: String = "", shareWithDisplayName: String = "",
        expirationDay: String? = nil, hasPassword: Bool = false, token: String? = nil, url: URL? = nil, label: String = "",
        note: String = "", hideDownload: Bool = false, canEdit: Bool = true, canDelete: Bool = true, createdAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.ownerId = ownerId
        self.ownerDisplayName = ownerDisplayName
        self.path = path
        self.target = target
        self.isFolder = isFolder
        self.permissions = permissions
        self.shareWith = shareWith
        self.shareWithDisplayName = shareWithDisplayName
        self.expirationDay = expirationDay
        self.hasPassword = hasPassword
        self.token = token
        self.url = url
        self.label = label
        self.note = note
        self.hideDownload = hideDownload
        self.canEdit = canEdit
        self.canDelete = canDelete
        self.createdAt = createdAt
    }

    /// Reads one entry of `ocs.data`. Numbers may come as strings (older servers), and fields a share type lacks are absent.
    init?(json: JSONValue) {
        guard let id = json["id"]?.string, let type = json["share_type"]?.int else { return nil }
        self.id = id
        kind = ShareKind(rawValue: type)
        ownerId = json["uid_owner"]?.string ?? ""
        ownerDisplayName = json["displayname_owner"]?.string ?? ownerId
        path = json["path"]?.string ?? ""
        target = json["file_target"]?.string ?? ""
        isFolder = json["item_type"]?.string == "folder"
        permissions = SharePermissions(rawValue: json["permissions"]?.int ?? 1)
        // A link share carries its (redacted) password hash in `share_with`; that is no recipient.
        shareWith = kind == .link ? "" : (json["share_with"]?.string ?? "")
        shareWithDisplayName = kind == .link ? "" : (json["share_with_displayname"]?.string ?? shareWith)
        expirationDay = json["expiration"]?.string.flatMap(Self.day(fromExpiration:))
        hasPassword = (json["password"]?.string).map { !$0.isEmpty } ?? false
        token = json["token"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        url = json["url"]?.string.flatMap(URL.init(string:))
        label = json["label"]?.string ?? ""
        note = json["note"]?.string ?? ""
        hideDownload = json["hide_download"]?.bool ?? false
        canEdit = json["can_edit"]?.bool ?? true
        canDelete = json["can_delete"]?.bool ?? true
        createdAt = json["stime"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// `2026-12-31 23:59:59` or `2026-12-31` → `2026-12-31`.
    static func day(fromExpiration value: String) -> String? {
        let day = String(value.prefix(10))
        return day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil ? nil : day
    }

    /// The expiration day as a date at the start of that day in `calendar`'s time zone.
    public func expirationDate(calendar: Calendar = .current) -> Date? {
        expirationDay.flatMap { FilesSharingAPI.date(fromDay: $0, calendar: calendar) }
    }
}

/// Someone or something a file can be shared with, found by the sharee search.
public struct ShareRecipient: Hashable, Sendable, Identifiable {
    public var id: String { "\(kind.rawValue):\(shareWith)" }
    public var kind: ShareKind
    public var shareWith: String
    public var label: String
    /// Extra text the server offers (email address, server of a federated user).
    public var detail: String

    public init(kind: ShareKind, shareWith: String, label: String, detail: String = "") {
        self.kind = kind
        self.shareWith = shareWith
        self.label = label
        self.detail = detail
    }
}

/// What the server allows for sharing (`capabilities.files_sharing`, and Talk's presence).
public struct SharingCapabilities: Hashable, Sendable {
    public var apiEnabled = true
    public var resharing = true
    public var groupSharing = true
    public var publicLinks = false
    public var publicPasswordEnforced = false
    public var publicExpiryEnforced = false
    /// Days a public link may stay valid when the expiry is enforced.
    public var publicExpiryDays: Int?
    public var publicUpload = false
    public var email = false
    public var emailPasswordEnforced = false
    public var federationOutgoing = false
    public var talk = false
    public var teams = false
    public var defaultPermissions: SharePermissions = [.read, .update, .create, .delete, .share]

    public init() {}

    /// Reads `ocs.data.capabilities`.
    public init(capabilities caps: JSONValue) {
        let sharing = caps["files_sharing"]
        apiEnabled = sharing?["api_enabled"]?.bool ?? (sharing != nil)
        resharing = sharing?["resharing"]?.bool ?? true
        groupSharing = sharing?["group_sharing"]?.bool ?? true
        publicLinks = sharing?["public", "enabled"]?.bool ?? false
        publicPasswordEnforced = sharing?["public", "password", "enforced"]?.bool ?? false
        publicExpiryEnforced = sharing?["public", "expire_date", "enforced"]?.bool ?? false
        publicExpiryDays = sharing?["public", "expire_date", "days"]?.int
        publicUpload = sharing?["public", "upload"]?.bool ?? false
        email = sharing?["sharebymail", "enabled"]?.bool ?? false
        emailPasswordEnforced = sharing?["sharebymail", "password", "enforced"]?.bool ?? false
        federationOutgoing = sharing?["federation", "outgoing"]?.bool ?? false
        // Talk and Teams publish capabilities of their own; their share types work whenever the apps are there.
        talk = caps["spreed"]?.isPresent ?? false
        teams = caps["circles"]?.isPresent ?? false
        if let permissions = sharing?["default_permissions"]?.int { defaultPermissions = SharePermissions(rawValue: permissions) }
    }

    /// The share types the sharee search is asked for.
    public var recipientKinds: [ShareKind] {
        var kinds: [ShareKind] = [.user]
        if groupSharing { kinds.append(.group) }
        if federationOutgoing { kinds += [.federated, .federatedGroup] }
        if email { kinds.append(.email) }
        if teams { kinds.append(.team) }
        if talk { kinds.append(.talkRoom) }
        return kinds
    }
}

/// Changes to an existing share (`PUT …/shares/<id>`). Fields left nil stay as they are.
public struct ShareUpdate: Hashable, Sendable {
    public var permissions: SharePermissions?
    /// A new password; an empty string removes it.
    public var password: String?
    /// A day `YYYY-MM-DD`; an empty string removes the expiration.
    public var expirationDay: String?
    public var label: String?
    public var note: String?
    public var hideDownload: Bool?

    public init(
        permissions: SharePermissions? = nil, password: String? = nil, expirationDay: String? = nil, label: String? = nil,
        note: String? = nil, hideDownload: Bool? = nil
    ) {
        self.permissions = permissions
        self.password = password
        self.expirationDay = expirationDay
        self.label = label
        self.note = note
        self.hideDownload = hideDownload
    }

    var form: [String: String] {
        var form: [String: String] = [:]
        if let permissions { form["permissions"] = String(permissions.rawValue) }
        if let password { form["password"] = password }
        if let expirationDay { form["expireDate"] = expirationDay }
        if let label { form["label"] = label }
        if let note { form["note"] = note }
        if let hideDownload { form["hideDownload"] = hideDownload ? "true" : "false" }
        return form
    }

    public var isEmpty: Bool { form.isEmpty }
}

/// Nextcloud's own sharing of files and folders (OCS Files Sharing API), which every server offers without the Photos app:
/// users, groups, other servers, email addresses, Talk conversations, Teams and public links (SPEC SH-7).
public struct FilesSharingAPI: Sendable {
    public let ocs: OCSClient

    public init(ocs: OCSClient) { self.ocs = ocs }

    static let sharesPath = "ocs/v2.php/apps/files_sharing/api/v1/shares"
    static let shareesPath = "ocs/v2.php/apps/files_sharing/api/v1/sharees"

    /// What the server allows; read when sharing starts, so a changed setting is seen without a new feature detection.
    public func capabilities() async throws -> SharingCapabilities {
        let data: JSONValue = try await ocs.request("GET", "ocs/v2.php/cloud/capabilities")
        return SharingCapabilities(capabilities: data["capabilities"] ?? .null)
    }

    /// Every share of a file or folder the user can see: their own and, with `reshares`, those others made of it.
    public func shares(path: String, reshares: Bool = true) async throws -> [FileShare] {
        let data: JSONValue = try await ocs.request(
            "GET", Self.sharesPath,
            query: [URLQueryItem(name: "path", value: path), URLQueryItem(name: "reshares", value: reshares ? "true" : "false")])
        return Self.parseShares(data)
    }

    /// Shares other users made with this user (received shares).
    public func sharedWithMe() async throws -> [FileShare] {
        let data: JSONValue = try await ocs.request(
            "GET", Self.sharesPath, query: [URLQueryItem(name: "shared_with_me", value: "true")])
        return Self.parseShares(data)
    }

    static func parseShares(_ data: JSONValue) -> [FileShare] {
        (data.array ?? []).compactMap(FileShare.init(json:))
    }

    /// Creates a share. `recipient` is nil for a public link.
    ///
    /// - Parameters:
    ///   - password: for links and email shares.
    ///   - expirationDay: `YYYY-MM-DD`.
    public func createShare(
        path: String, kind: ShareKind, shareWith: String? = nil, permissions: SharePermissions? = nil, password: String? = nil,
        expirationDay: String? = nil, label: String? = nil, note: String? = nil
    ) async throws -> FileShare {
        var form = ["path": path, "shareType": String(kind.rawValue)]
        if let shareWith { form["shareWith"] = shareWith }
        if let permissions { form["permissions"] = String(permissions.rawValue) }
        if let password, !password.isEmpty { form["password"] = password }
        if let expirationDay, !expirationDay.isEmpty { form["expireDate"] = expirationDay }
        if let label, !label.isEmpty { form["label"] = label }
        if let note, !note.isEmpty { form["note"] = note }
        let data: JSONValue = try await ocs.request("POST", Self.sharesPath, form: form, serverMessages: true)
        guard let share = FileShare(json: data) else { throw NetworkError.invalidResponse("share without id") }
        return share
    }

    /// Changes a share and returns it as the server has it now.
    ///
    /// Servers before Nextcloud 27 take one field per request; each field is therefore sent on its own, permissions first
    /// (a password or expiry may only be allowed for the new permissions).
    public func updateShare(id: String, _ update: ShareUpdate) async throws -> FileShare {
        var latest: FileShare?
        let order = ["permissions", "password", "expireDate", "label", "note", "hideDownload"]
        let form = update.form
        for key in order {
            guard let value = form[key] else { continue }
            let data: JSONValue = try await ocs.request("PUT", "\(Self.sharesPath)/\(id)", form: [key: value], serverMessages: true)
            latest = FileShare(json: data) ?? latest
        }
        if let latest { return latest }
        return try await share(id: id)
    }

    public func share(id: String) async throws -> FileShare {
        let data: JSONValue = try await ocs.request("GET", "\(Self.sharesPath)/\(id)")
        // One share comes as a list of one.
        guard let share = Self.parseShares(data).first ?? FileShare(json: data) else { throw NetworkError.notFound }
        return share
    }

    public func deleteShare(id: String) async throws {
        _ = try await ocs.raw("DELETE", "\(Self.sharesPath)/\(id)", serverMessages: true)
    }

    /// Searches people, groups, other servers' users, email addresses, Teams and Talk conversations to share with.
    ///
    /// Exact matches come first. The user's own account is left out.
    public func searchRecipients(_ term: String, isFolder: Bool, kinds: [ShareKind], limit: Int = 25) async throws -> [ShareRecipient] {
        var query = [
            URLQueryItem(name: "search", value: term), URLQueryItem(name: "itemType", value: isFolder ? "folder" : "file"),
            URLQueryItem(name: "perPage", value: String(limit)), URLQueryItem(name: "lookup", value: "false"),
        ]
        query += kinds.map { URLQueryItem(name: "shareType[]", value: String($0.rawValue)) }
        let data: JSONValue = try await ocs.request("GET", Self.shareesPath, query: query)
        return Self.parseRecipients(data, ownUserId: ocs.connection.userId)
    }

    static let recipientGroups = ["users", "groups", "remotes", "remote_groups", "emails", "circles", "rooms"]

    static func parseRecipients(_ data: JSONValue, ownUserId: String) -> [ShareRecipient] {
        var seen: Set<String> = []
        var result: [ShareRecipient] = []
        for source in [data["exact"], data] {
            for group in recipientGroups {
                for entry in source?[group]?.array ?? [] {
                    guard let type = entry["value", "shareType"]?.int, let shareWith = entry["value", "shareWith"]?.string else { continue }
                    let kind = ShareKind(rawValue: type)
                    if kind == .user && shareWith == ownUserId { continue }
                    let label = entry["label"]?.string ?? shareWith
                    var detail = entry["subline"]?.string ?? entry["shareWithDescription"]?.string ?? ""
                    if detail.isEmpty, kind == .federated || kind == .federatedGroup {
                        detail = entry["value", "server"]?.string ?? ""
                    }
                    if detail.isEmpty, kind == .email, label != shareWith { detail = shareWith }
                    let recipient = ShareRecipient(kind: kind, shareWith: shareWith, label: label, detail: detail)
                    if seen.insert(recipient.id).inserted { result.append(recipient) }
                }
            }
        }
        return result
    }

    // MARK: Days

    /// `YYYY-MM-DD` of a date in `calendar`'s time zone.
    public static func day(of date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    public static func date(fromDay day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

extension PhotosAPI {
    /// Nextcloud's file and folder sharing for this account.
    public var sharing: FilesSharingAPI { FilesSharingAPI(ocs: ocs) }
}
