// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosCore
@testable import PhotosModel

/// The shared folder rule state and the undo of batch fixes (SPEC §16.4).
@Suite struct OrganizeCoreTests {
    @Test func statesOfTwoDevicesMerge() throws {
        var mac = FolderRuleState()
        mac.record(
            .init(id: "m", date: Date(timeIntervalSince1970: 200), ruleId: "r", ruleName: "R", count: 2, device: "Mac"), handled: [1, 2])
        var phone = FolderRuleState()
        phone.record(
            .init(id: "p", date: Date(timeIntervalSince1970: 300), ruleId: "r", ruleName: "R", count: 1, device: "iPhone"), handled: [2, 3])
        let merged = OrganizeModel.merge(mac, phone)
        #expect(merged.handled["r"] == [1, 2, 3])
        #expect(merged.log.map(\.id) == ["p", "m"])
        // Dates are Unix seconds in the shared file.
        let json = String(decoding: try OrganizeModel.stateEncoder.encode(merged), as: UTF8.self)
        #expect(json.contains(#""date":300"#))
        #expect(try OrganizeModel.stateDecoder.decode(FolderRuleState.self, from: Data(json.utf8)) == merged)
    }

    @Test func theUndoOfAnEditPutsBackWhatWasThere() {
        let located = MediaItem(
            fileId: 1, path: "/a.jpg", mimeType: "image/jpeg", capturedAt: Date(timeIntervalSince1970: 100), captureOffset: 3600,
            latitude: 48, longitude: 11)
        let plain = MediaItem(fileId: 2, path: "/b.jpg", mimeType: "image/jpeg", capturedAt: Date(timeIntervalSince1970: 200))
        let edit = MetadataEdit(fileId: 1, capturedAt: Date(timeIntervalSince1970: 500), latitude: 1, longitude: 2)
        let undo = edit.inverse(of: located)
        #expect(undo.capturedAt == Date(timeIntervalSince1970: 100))
        #expect(undo.offset == 3600)
        #expect(undo.latitude == 48 && undo.longitude == 11 && !undo.removeLocation)
        // A photo that had no place loses it again; the date is left alone when only the place changed.
        let placeOnly = MetadataEdit(fileId: 2, latitude: 1, longitude: 2).inverse(of: plain)
        #expect(placeOnly.removeLocation)
        #expect(placeOnly.capturedAt == nil)
    }
}
