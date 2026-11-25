// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A folder the user shares with others or that others share with the user, and that the user can add files to: where
/// a family library can live (SPEC §16.7.2). Found with Nextcloud's normal WebDAV and sharing APIs; nothing is created.
public struct SharedFolder: Hashable, Sendable, Identifiable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// Someone shared it with the user (directly, through a group or a Team).
        case received
        /// A group folder (Team folder) of the admin's.
        case groupFolder
        /// The user's own folder, shared with people or groups.
        case own
    }

    public var path: String
    public var kind: Kind
    /// Who owns it (received shares); empty for the user's own and group folders.
    public var ownerDisplayName: String
    /// Who it is shared with (own folders), as far as the server lists it.
    public var sharedWith: [String]

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, kind: Kind, ownerDisplayName: String = "", sharedWith: [String] = []) {
        self.path = path
        self.kind = kind
        self.ownerDisplayName = ownerDisplayName
        self.sharedWith = sharedWith
    }

    enum CodingKeys: String, CodingKey {
        case path, kind, ownerDisplayName, sharedWith
    }

    /// Fields added later may be missing in what was stored.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .own
        ownerDisplayName = try container.decodeIfPresent(String.self, forKey: .ownerDisplayName) ?? ""
        sharedWith = try container.decodeIfPresent([String].self, forKey: .sharedWith) ?? []
    }
}

extension FilesSharingAPI {
    /// The shares the user made (`GET …/shares` without a path).
    public func ownShares() async throws -> [FileShare] {
        let data: JSONValue = try await ocs.request("GET", Self.sharesPath)
        return Self.parseShares(data)
    }
}

extension PhotosAPI {
    static let shareTypes = QName(XMLNamespace.oc, "share-types")
    static let shareType = QName(XMLNamespace.oc, "share-type")

    /// Folders shared with or by the user that the user can add files to: the top level of the user's files (where
    /// received shares and group folders appear by default), received folder shares wherever they were moved, and the
    /// user's own folders shared with people, groups or Teams. Public links alone don't make a family folder.
    public func writableSharedFolders() async throws -> [SharedFolder] {
        let root = try await dav.propfind(
            connection.filesURL("/").appendingTrailingSlashIfNeeded(true), depth: 1,
            properties: [DAVProp.resourceType, DAVProp.permissions, DAVProp.mountType, Self.shareTypes, DAVProp.ownerDisplayName])
        async let received = sharing.sharedWithMe()
        async let own = sharing.ownShares()
        // A server without the sharing app answers the listings with an error; the top level still tells.
        return Self.sharedFolders(
            root: Array(root.dropFirst()), received: (try? await received) ?? [], own: (try? await own) ?? [], connection: connection)
    }

    /// Combines what the listings say, one entry per folder, by name.
    static func sharedFolders(
        root: [DAVResource], received: [FileShare], own: [FileShare], connection: ServerConnection
    ) -> [SharedFolder] {
        var byPath: [String: SharedFolder] = [:]
        for resource in root where resource.isCollection {
            guard let path = connection.userPath(fromHref: resource.href), path != "/" else { continue }
            let name = (path as NSString).lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let permissions = resource.string(DAVProp.permissions) ?? ""
            guard permissions.contains("C") || permissions.contains("K") else { continue }
            let mount = resource.string(DAVProp.mountType) ?? ""
            let types = resource.node(shareTypes)?.children(shareType).compactMap { Int($0.value) } ?? []
            let owner = resource.string(DAVProp.ownerDisplayName) ?? ""
            switch mount {
            case "group":
                byPath[path] = SharedFolder(path: path, kind: .groupFolder)
            case "shared", "shared-root", "federated", "federated-shared":
                byPath[path] = SharedFolder(path: path, kind: .received, ownerDisplayName: owner)
            default:
                // Own folder: only when it is shared with someone (a link alone is no family folder).
                if types.contains(where: { $0 != ShareKind.link.rawValue && $0 != ShareKind.email.rawValue }) {
                    byPath[path] = SharedFolder(path: path, kind: .own)
                }
            }
        }
        for share in received where share.isFolder && share.permissions.contains(.create) {
            let path = share.path.isEmpty ? share.target : share.path
            guard !path.isEmpty, path != "/" else { continue }
            if byPath[path] == nil { byPath[path] = SharedFolder(path: path, kind: .received) }
            if byPath[path]?.ownerDisplayName.isEmpty == true { byPath[path]?.ownerDisplayName = share.ownerDisplayName }
        }
        let recipients: Set<ShareKind> = [.user, .group, .team, .federated, .federatedGroup]
        for share in own where share.isFolder && recipients.contains(share.kind) {
            guard !share.path.isEmpty, share.path != "/" else { continue }
            var folder = byPath[share.path] ?? SharedFolder(path: share.path, kind: .own)
            guard folder.kind == .own else { continue }
            let name = share.shareWithDisplayName.isEmpty ? share.shareWith : share.shareWithDisplayName
            if !name.isEmpty, !folder.sharedWith.contains(name) { folder.sharedWith.append(name) }
            byPath[share.path] = folder
        }
        return byPath.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
