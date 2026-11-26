// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosNetworking
import Testing

@testable import PhotosAppUI

/// What the sharing screens offer and send (SPEC SH-7).
@Suite struct FileSharingRoleTests {
    var caps: SharingCapabilities {
        var caps = SharingCapabilities()
        caps.publicLinks = true
        caps.publicUpload = true
        return caps
    }

    @Test func rolesPerShareKind() {
        #expect(ShareRole.roles(for: .user, isFolder: false, capabilities: caps) == [.view, .edit])
        #expect(ShareRole.roles(for: .talkRoom, isFolder: true, capabilities: caps) == [.view, .edit])
        #expect(ShareRole.roles(for: .link, isFolder: false, capabilities: caps) == [.view], "a photo's link only shows it")
        #expect(ShareRole.roles(for: .link, isFolder: true, capabilities: caps) == [.view, .upload, .fileDrop])
        #expect(ShareRole.roles(for: .email, isFolder: true, capabilities: caps) == [.view, .upload])
        var noUpload = caps
        noUpload.publicUpload = false
        #expect(ShareRole.roles(for: .link, isFolder: true, capabilities: noUpload) == [.view])
    }

    @Test func permissionsRoundTrip() {
        for (role, kind, folder) in [
            (ShareRole.view, ShareKind.user, false), (.edit, .user, false), (.edit, .group, true), (.view, .link, true),
            (.upload, .link, true), (.fileDrop, .link, true), (.upload, .email, true),
        ] {
            let permissions = role.permissions(isFolder: folder, resharing: true)
            #expect(ShareRole(permissions: permissions, kind: kind, isFolder: folder) == role, "\(role) \(kind)")
        }
        #expect(ShareRole.edit.permissions(isFolder: false, resharing: true) == [.read, .update, .share])
        #expect(
            ShareRole.edit.permissions(isFolder: false, resharing: false) == [.read, .update], "no re-sharing when the server forbids it")
        #expect(ShareRole.view.permissions(isFolder: true, resharing: true) == .read)
        // Shares made elsewhere with other combinations still read as one of the roles.
        #expect(ShareRole(permissions: [.read, .share], kind: .user, isFolder: true) == .view)
        #expect(ShareRole(permissions: [.read, .create], kind: .user, isFolder: true) == .edit)
    }

    @MainActor @Test func editorSendsOnlyChanges() {
        let link = FileShare(
            id: "3", kind: .link, path: "/a", isFolder: true, permissions: .read, expirationDay: "2026-12-31", hasPassword: true,
            label: "Family")
        let unchanged = ShareEditorSheet.changes(
            from: link, role: .view, isFolder: true, resharing: true, password: .keep, expirationDay: "2026-12-31", label: "Family",
            note: "", hideDownload: false)
        #expect(unchanged.isEmpty)

        let changed = ShareEditorSheet.changes(
            from: link, role: .upload, isFolder: true, resharing: true, password: .remove, expirationDay: nil, label: "Friends",
            note: "Hi", hideDownload: true)
        #expect(changed.permissions == .linkUpload)
        #expect(changed.password == "", "an empty password removes it")
        #expect(changed.expirationDay == "", "an empty day removes the expiration")
        #expect(changed.label == "Friends")
        #expect(changed.note == "Hi")
        #expect(changed.hideDownload == true)

        let user = FileShare(id: "4", kind: .user, path: "/b.jpg", permissions: .read, shareWith: "bob")
        let edit = ShareEditorSheet.changes(
            from: user, role: .edit, isFolder: false, resharing: true, password: .keep, expirationDay: "2027-01-01", label: "", note: "",
            hideDownload: nil)
        #expect(edit.permissions == [.read, .update, .share])
        #expect(edit.password == nil)
        #expect(edit.expirationDay == "2027-01-01")
        #expect(edit.hideDownload == nil)
    }

    @MainActor @Test func linksOverHTTPAreFlagged() throws {
        #expect(SharedLinkView.isUnencrypted(try #require(URL(string: "http://cloud.example.org/s/abc"))))
        #expect(!SharedLinkView.isUnencrypted(try #require(URL(string: "https://cloud.example.org/s/abc"))))
    }

    @Test func sharingTargetNames() {
        #expect(SharingTarget(path: "/Photos/2026", isFolder: true).name == "2026")
        #expect(SharingTarget(path: "/", isFolder: true).name == "/")
    }
}
