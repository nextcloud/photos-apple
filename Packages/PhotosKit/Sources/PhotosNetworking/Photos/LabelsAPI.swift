// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Light-weight membership listings for the local search index (SPEC SR-3): file ids only, no metadata.
extension PhotosAPI {
    /// The ids of the files that carry a system tag (core `oc:filter-files` REPORT, any file type, any folder).
    public func tagMemberIds(_ tagId: Int) async throws -> Set<FileID> {
        let resources = try await dav.report(
            connection.filesURL("/").appendingTrailingSlashIfNeeded(true),
            body: DAVBody.filterFiles(properties: [DAVProp.fileId], systemTagIds: [tagId]))
        return Set(resources.compactMap { $0.int64(DAVProp.fileId) })
    }

    /// One detection of a person: which photo it is in.
    public struct PersonMember: Sendable, Hashable {
        public var detectionId: Int
        public var childName: String
        public var fileId: FileID

        public init(detectionId: Int, childName: String, fileId: FileID) {
            self.detectionId = detectionId
            self.childName = childName
            self.fileId = fileId
        }
    }

    /// The photos of a person (Recognize), as detections with their file ids only.
    public func personMembers(_ name: String, key: String?) async throws -> [PersonMember] {
        let resources = try await recognize(key).propfind(
            connection.davURL("recognize/\(connection.userId)/faces/\(name)/"), depth: 1, properties: [DAVProp.fileId])
        return resources.compactMap { resource in
            guard !resource.isCollection, let fileId = resource.int64(DAVProp.fileId) else { return nil }
            let childName = resource.lastPathComponent
            guard let detectionId = Int(childName.prefix(while: \.isNumber)) else { return nil }
            return PersonMember(detectionId: detectionId, childName: childName, fileId: fileId)
        }
    }
}
