// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosNetworking
import Synchronization
import Testing

@testable import PhotosMedia

/// A small WebDAV server in memory: files with ETags, `If-Match` / `If-None-Match`, folders, PROPFIND.
final class EditDAVServer: Sendable {
    struct File: Sendable {
        var data: Data
        var etag: String
    }

    struct State: Sendable {
        var files: [String: File] = [:]
        var folders: Set<String> = ["/"]
        var counter = 0
        var offline = false
        /// "METHOD path header" of every request, for the tests to look at.
        var log: [String] = []
    }

    let host = "edits-\(UUID().uuidString.lowercased()).test"
    let state = Mutex(State())

    init() {
        EditDAVProtocol.servers.withLock { $0[host] = self }
    }

    deinit {
        let host = self.host
        EditDAVProtocol.servers.withLock { $0[host] = nil }
    }

    var dav: DAVClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EditDAVProtocol.self]
        let http = HTTPClient(trustStore: TrustStore(directory: nil), configuration: configuration)
        let connection = ServerConnection(
            serverURL: URL(string: "http://\(host)")!, userId: "alice", loginName: "alice", appPassword: "secret", userAgent: "tests")
        return DAVClient(http: http, connection: connection)
    }

    func library(file: URL? = nil) -> EditLibrary { EditLibrary(dav: dav, file: file) }

    static let folder = "/.nextcloud-photos/edits"

    func file(_ fileId: FileID) -> File? { state.withLock { $0.files["\(Self.folder)/\(fileId).json"] } }

    var log: [String] { state.withLock { $0.log } }

    func setOffline(_ offline: Bool) { state.withLock { $0.offline = offline } }

    /// The path below the user's files root, `/a/b`.
    static func userPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard let range = path.range(of: "/files/alice") else { return path }
        var rest = String(path[range.upperBound...])
        while rest.contains("//") { rest = rest.replacingOccurrences(of: "//", with: "/") }
        if rest.count > 1 && rest.hasSuffix("/") { rest.removeLast() }
        return rest.isEmpty ? "/" : rest
    }

    func handle(_ request: URLRequest, body: Data) -> (Int, [String: String], Data) {
        state.withLock { state in
            let method = request.httpMethod ?? "GET"
            let path = Self.userPath(request.url!)
            let ifMatch = request.value(forHTTPHeaderField: "If-Match")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let ifNoneMatch = request.value(forHTTPHeaderField: "If-None-Match")
            state.log.append("\(method) \(path) \(ifMatch.map { "match:\($0)" } ?? "")\(ifNoneMatch.map { "none:\($0)" } ?? "")")
            let parent = (path as NSString).deletingLastPathComponent
            func etagHeader(_ etag: String) -> [String: String] { ["ETag": "\"\(etag)\"", "OC-ETag": "\"\(etag)\""] }
            func touch() {
                state.counter += 1
            }
            switch method {
            case "MKCOL":
                if state.folders.contains(path) { return (405, [:], Data()) }
                guard state.folders.contains(parent) else { return (409, [:], Data()) }
                state.folders.insert(path)
                return (201, [:], Data())
            case "PUT":
                guard state.folders.contains(parent) else { return (409, [:], Data()) }
                let existing = state.files[path]
                if let ifMatch, existing?.etag != ifMatch { return (412, [:], Data()) }
                if ifNoneMatch == "*", existing != nil { return (412, [:], Data()) }
                touch()
                let etag = "e\(state.counter)"
                state.files[path] = File(data: body, etag: etag)
                return (existing == nil ? 201 : 204, etagHeader(etag), Data())
            case "GET":
                guard let file = state.files[path] else { return (404, [:], Data()) }
                return (200, etagHeader(file.etag), file.data)
            case "DELETE":
                guard let existing = state.files[path] else { return (404, [:], Data()) }
                if let ifMatch, existing.etag != ifMatch { return (412, [:], Data()) }
                touch()
                state.files[path] = nil
                return (204, [:], Data())
            case "PROPFIND":
                let depth = request.value(forHTTPHeaderField: "Depth") ?? "1"
                var responses: [(href: String, etag: String, collection: Bool)] = []
                if state.folders.contains(path) {
                    let children = state.files.filter { ($0.key as NSString).deletingLastPathComponent == path }
                    let folderEtag = "f\(state.counter)-\(children.count)"
                    responses.append(("/remote.php/dav/files/alice\(path)/", folderEtag, true))
                    if depth == "1" {
                        for (childPath, file) in children.sorted(by: { $0.key < $1.key }) {
                            responses.append(("/remote.php/dav/files/alice\(childPath)", file.etag, false))
                        }
                    }
                } else if let file = state.files[path] {
                    responses.append(("/remote.php/dav/files/alice\(path)", file.etag, false))
                } else {
                    return (404, [:], Data())
                }
                let xml = responses.map { response in
                    "<d:response><d:href>\(response.href)</d:href><d:propstat><d:prop><d:getetag>\"\(response.etag)\"</d:getetag>"
                        + "<d:resourcetype>\(response.collection ? "<d:collection/>" : "")</d:resourcetype></d:prop>"
                        + "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
                }
                .joined()
                return (
                    207, ["Content-Type": "application/xml"],
                    Data("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">\(xml)</d:multistatus>".utf8)
                )
            default:
                return (405, [:], Data())
            }
        }
    }
}

final class EditDAVProtocol: URLProtocol, @unchecked Sendable {
    static let servers = Mutex<[String: EditDAVServer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host()?.hasPrefix("edits-") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.servers.withLock({ $0[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if server.state.withLock({ $0.offline }) {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, headers, data) = server.handle(request, body: Self.body(of: request))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Edit recipes synced through the user's Nextcloud (SPEC §16.3.1): ETag-safe, newest edit wins, offline-proof.
@Suite(.timeLimit(.minutes(1))) struct EditLibraryTests {
    let server = EditDAVServer()

    static func recipe(exposure: Double, at seconds: TimeInterval) -> EditRecipe {
        var edits = PhotoEdits()
        edits.exposure = exposure
        return EditRecipe(edits: edits, updatedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func aSavedEditReachesTheServerAndAnotherDevice() async throws {
        let phone = server.library()
        let recipe = Self.recipe(exposure: 0.5, at: 1000)
        await phone.save(recipe, for: 12)
        // Shown at once, before the server has it.
        #expect(phone.recipe(for: 12) == recipe)
        await phone.waitUntilIdle()
        let stored = try #require(server.file(12))
        #expect(try EditRecipe.decode(stored.data) == recipe)
        // A new recipe is only created, never written over one the device does not know.
        #expect(server.log.contains { $0.hasPrefix("PUT /.nextcloud-photos/edits/12.json none:*") })
        #expect(server.log.contains("MKCOL /.nextcloud-photos "))
        #expect(await phone.pendingCount() == 0)

        let mac = server.library()
        #expect(mac.recipe(for: 12) == nil)
        await mac.sync()
        #expect(mac.recipe(for: 12) == recipe)

        // A change replaces exactly the version the device knows.
        let changed = Self.recipe(exposure: 1, at: 2000)
        await mac.save(changed, for: 12)
        await mac.waitUntilIdle()
        #expect(server.log.last == "PUT /.nextcloud-photos/edits/12.json match:\(stored.etag)")
        await phone.sync()
        #expect(phone.recipe(for: 12) == changed)
    }

    @Test func revertingRemovesTheEditEverywhere() async throws {
        let phone = server.library()
        let mac = server.library()
        await phone.save(Self.recipe(exposure: 0.5, at: 1000), for: 7)
        await phone.waitUntilIdle()
        await mac.sync()
        #expect(mac.recipe(for: 7) != nil)
        let etag = try #require(server.file(7)).etag

        await mac.revert(7)
        #expect(mac.recipe(for: 7) == nil)
        await mac.waitUntilIdle()
        #expect(server.file(7) == nil)
        #expect(server.log.contains("DELETE /.nextcloud-photos/edits/7.json match:\(etag)"))
        await phone.sync()
        #expect(phone.recipe(for: 7) == nil)
    }

    /// Two devices change the same photo's edit from the same version: the edit made later wins on both, whichever
    /// reaches the server first.
    @Test func theNewerEditWinsAConflict() async throws {
        let phone = server.library()
        let mac = server.library()
        await phone.save(Self.recipe(exposure: 0.1, at: 1000), for: 5)
        await phone.waitUntilIdle()
        await mac.sync()

        // The phone edits later but sends first; the Mac's older edit then meets a newer version (412).
        let newer = Self.recipe(exposure: 0.9, at: 3000)
        let older = Self.recipe(exposure: -0.9, at: 2000)
        await phone.save(newer, for: 5)
        await phone.waitUntilIdle()
        await mac.save(older, for: 5)
        await mac.waitUntilIdle()
        #expect(try EditRecipe.decode(try #require(server.file(5)).data) == newer)
        #expect(mac.recipe(for: 5) == newer)
        #expect(await mac.pendingCount() == 0)

        // The other way round: the later edit replaces the version it now knows.
        let latest = Self.recipe(exposure: 0.3, at: 5000)
        let stale = Self.recipe(exposure: 0.7, at: 4000)
        await phone.save(stale, for: 5)
        await phone.waitUntilIdle()
        await mac.save(latest, for: 5)
        await mac.waitUntilIdle()
        #expect(try EditRecipe.decode(try #require(server.file(5)).data) == latest)
        await phone.sync()
        #expect(phone.recipe(for: 5) == latest)
    }

    @Test func editsMadeOfflineGoOutLater() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "edits-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "recipes.json")
        server.setOffline(true)
        let phone = server.library(file: file)
        let recipe = Self.recipe(exposure: 0.4, at: 1000)
        await phone.save(recipe, for: 3)
        await phone.waitUntilIdle()
        #expect(phone.recipe(for: 3) == recipe)
        #expect(await phone.pendingCount() == 1)
        #expect(server.file(3) == nil)

        // Kept on the device across launches, still waiting.
        let relaunched = server.library(file: file)
        #expect(relaunched.recipe(for: 3) == recipe)
        #expect(await relaunched.pendingCount() == 1)

        server.setOffline(false)
        await relaunched.sync()
        #expect(await relaunched.pendingCount() == 0)
        #expect(try EditRecipe.decode(try #require(server.file(3)).data) == recipe)
    }

    @Test func observersHearOfChanges() async throws {
        let mac = server.library()
        let heard = Mutex<[Set<FileID>]>([])
        await mac.observe { ids in heard.withLock { $0.append(ids) } }
        let phone = server.library()
        await phone.save(Self.recipe(exposure: 0.2, at: 1000), for: 9)
        await phone.waitUntilIdle()
        await mac.sync()
        #expect(heard.withLock { $0 } == [[9]])
        // An unchanged folder is not listed again.
        let requests = server.log.count
        await mac.sync()
        #expect(server.log.count == requests + 1)
    }

    /// A recipe of a newer app version is kept as it is and not applied.
    @Test func aNewerFormatIsKeptButNotShown() async throws {
        let phone = server.library()
        await phone.save(Self.recipe(exposure: 0.2, at: 1000), for: 4)
        await phone.waitUntilIdle()
        server.state.withLock { state in
            let path = "\(EditDAVServer.folder)/4.json"
            state.counter += 1
            state.files[path] = EditDAVServer.File(
                data: Data(#"{"format": "nextcloud-photos-edit", "version": 9}"#.utf8), etag: "e\(state.counter)")
        }
        await phone.sync()
        #expect(phone.recipe(for: 4) == nil)
        #expect(await phone.hasNewerFormat(4))
    }

    @Test func identityRecipesRevert() async throws {
        let phone = server.library()
        await phone.save(Self.recipe(exposure: 0.2, at: 1000), for: 8)
        await phone.waitUntilIdle()
        await phone.save(EditRecipe(), for: 8)
        await phone.waitUntilIdle()
        #expect(phone.recipe(for: 8) == nil)
        #expect(server.file(8) == nil)
    }

    @Test func restoreSetsSeveralAtOnce() async throws {
        let phone = server.library()
        let a = Self.recipe(exposure: 0.2, at: 1000)
        await phone.save(a, for: 1)
        await phone.waitUntilIdle()
        let b = Self.recipe(exposure: 0.6, at: 1000)
        await phone.restore([1: nil, 2: b])
        #expect(phone.recipe(for: 1) == nil)
        #expect(phone.recipe(for: 2)?.edits.exposure == 0.6)
        await phone.waitUntilIdle()
        #expect(server.file(1) == nil)
        #expect(server.file(2) != nil)
    }
}
