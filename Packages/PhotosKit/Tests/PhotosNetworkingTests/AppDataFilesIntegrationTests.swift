// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel
@testable import PhotosNetworking

/// The shared files of smart albums and folder rules (SPEC §16.4) against a real server. Runs only when
/// PHOTOS_IT_SERVER, PHOTOS_IT_USER and PHOTOS_IT_PASSWORD are set; writes a test file of its own into
/// `/.nextcloud-photos/` and removes it again.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct AppDataFilesIntegrationTests {
    let dav: DAVClient
    let name = "it-test-\(UUID().uuidString.prefix(8)).json"

    init() {
        let env = ProcessInfo.processInfo.environment
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let connection = ServerConnection(
            serverURL: URL(string: env["PHOTOS_IT_SERVER"] ?? "http://localhost")!, userId: user, loginName: user,
            appPassword: env["PHOTOS_IT_PASSWORD"] ?? "", userAgent: "Mozilla/5.0 (macOS) Nextcloud-Photos/tests")
        dav = DAVClient(http: HTTPClient(trustStore: TrustStore(directory: nil)), connection: connection)
    }

    @Test func writesOnlyOverTheVersionItRead() async throws {
        let files = AppDataFiles(dav: dav)
        #expect(try await files.read(name) == nil)
        let first = try await files.write(name, data: Data("[1]".utf8), replacing: nil)
        #expect(!first.isEmpty)
        // A second "new" file with the same name is refused.
        await #expect(throws: NetworkError.preconditionFailed) {
            _ = try await files.write(name, data: Data("[2]".utf8), replacing: nil)
        }
        let second = try await files.write(name, data: Data("[1,2]".utf8), replacing: first)
        // The version read before is out of date now.
        await #expect(throws: NetworkError.preconditionFailed) {
            _ = try await files.write(name, data: Data("[3]".utf8), replacing: first)
        }
        let content = try #require(try await files.read(name))
        #expect(content.etag == second)
        #expect(String(decoding: content.data, as: UTF8.self) == "[1,2]")
        try await files.delete(name, expected: nil)
    }

    /// Two writers at once: `update` reads again and applies its change to what the other wrote.
    @Test func updateMergesWithAConcurrentWriter() async throws {
        let files = AppDataFiles(dav: dav)
        try await files.write(name, data: Data("a".utf8), replacing: nil)
        let written = try await files.update(name) { current in
            let text = String(decoding: current?.data ?? Data(), as: UTF8.self)
            return Data((text + "+mine").utf8)
        }
        #expect(String(decoding: try #require(written).data, as: UTF8.self) == "a+mine")
        // Another device writes between our read and our write: the first attempt fails, the second builds on it.
        let attempts = Counter()
        let racing = try await files.update(name) { current in
            let count = attempts.next()
            if count == 1 {
                // Simulates the other device.
                let other = current!.etag
                Task.detached { [dav, name] in
                    _ = try? await AppDataFiles(dav: dav).write(name, data: Data("theirs".utf8), replacing: other)
                }
                Thread.sleep(forTimeInterval: 1)
            }
            return Data((String(decoding: current?.data ?? Data(), as: UTF8.self) + "+again").utf8)
        }
        #expect(attempts.value == 2)
        #expect(String(decoding: try #require(racing).data, as: UTF8.self) == "theirs+again")
        try await files.delete(name, expected: nil)
    }

    @Test func readsCameraDetailsInBulk() async throws {
        let api = PhotosAPI(dav: dav, ocs: OCSClient(http: dav.http, connection: dav.connection))
        let search = DAVSearch(
            select: [DAVProp.fileId], scopes: [DAVSearch.Scope(href: dav.connection.filesHref("/Photos"))],
            condition: .like(DAVProp.contentType, "image/jpeg"), limit: 20)
        let ids = try await dav.search(search).compactMap { $0.int64(DAVProp.fileId) }
        try #require(!ids.isEmpty)
        let details = try await api.cameraDetails(fileIds: ids, sourceFolders: ["/Photos"])
        #expect(Set(details.keys) == Set(ids))
    }
}

/// Counts calls from a `@Sendable` closure.
private final class Counter: @unchecked Sendable {
    // Guarded by `lock`.
    private var count = 0
    private let lock = NSLock()

    func next() -> Int {
        lock.withLock {
            count += 1; return count
        }
    }
    var value: Int { lock.withLock { count } }
}
