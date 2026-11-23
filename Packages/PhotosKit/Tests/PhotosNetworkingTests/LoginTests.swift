// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosNetworking

@Suite struct LoginTests {
    func isUnencrypted(_ address: String) throws -> Bool {
        LoginService.isUnencrypted(try #require(LoginService.normalizeServerAddress(address)))
    }

    @Test func plainHttpNeedsConfirmation() throws {
        #expect(try isUnencrypted("http://cloud.example.com"))
        #expect(try isUnencrypted("HTTP://Cloud.Example.com/nextcloud"))
        #expect(try isUnencrypted("http://192.168.1.10:8080"))
        #expect(try isUnencrypted("http://localhost.example.com"))
    }

    @Test func httpsAndThisDeviceDoNot() throws {
        #expect(try !isUnencrypted("cloud.example.com"))
        #expect(try !isUnencrypted("https://cloud.example.com"))
        #expect(try !isUnencrypted("http://localhost:8089"))
        #expect(try !isUnencrypted("http://LOCALHOST"))
        #expect(try !isUnencrypted("http://127.0.0.1:8089"))
        #expect(try !isUnencrypted("http://[::1]:8089"))
    }

    @Test func loginLinksAreChecked() throws {
        let link = try #require(LoginService.parseLoginURL("nc://login/server:http://cloud.example.com&user:alice&password:secret"))
        #expect(LoginService.isUnencrypted(link.serverURL))
        let local = try #require(LoginService.parseLoginURL("nc://login/server:http://localhost:8089&user:admin&password:admin"))
        #expect(!LoginService.isUnencrypted(local.serverURL))
    }
}
