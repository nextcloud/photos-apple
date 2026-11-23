// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking

/// A temporary app container with its own secret store. Nothing in these tests touches the real container or keychain.
struct Sandbox {
    let root: URL
    let layout: StorageLayout
    let keychain: Keychain
    let secrets: URL

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "photos-core-tests-\(UUID().uuidString)")
        layout = StorageLayout(container: root.appending(path: "Container"))
        secrets = root.appending(path: "Secrets")
        keychain = Keychain(service: "tests", fileStore: secrets)
        try? FileManager.default.createDirectory(at: layout.container, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Paths of all files below the container, relative to it.
    func files() -> [String] { Self.files(in: layout.container) }

    /// Number of items in the secret store.
    func secretCount() -> Int { Self.files(in: secrets).count }

    static func files(in directory: URL) -> [String] {
        let base = directory.resolvingSymlinksInPath().path(percentEncoded: false)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var result: [String] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            result.append(String(url.resolvingSymlinksInPath().path(percentEncoded: false).dropFirst(base.count)))
        }
        return result.sorted()
    }

    func write(_ text: String = "x", to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Everything an account can leave behind, written by hand.
    /// - Parameter liveDatabase: the account is in use and has a real database; don't overwrite it.
    func populate(_ account: Account, trustStore: TrustStore? = nil, liveDatabase: Bool = false) throws {
        let id = account.id
        if !liveDatabase { try write(to: layout.database(id)) }
        try write(to: layout.featuresFile(id))
        try write(to: layout.offline(id).appending(path: "1-etag.jpg"))
        try write(to: layout.previews(id).appending(path: "01/1-etag-256.jpg"))
        try write(to: layout.originals(id).appending(path: "1-etag.jpg"))
        try keychain.set("secret", for: Keychain.passwordKey(id.rawValue))
        try keychain.set(Data([1, 2, 3]), for: Keychain.pushPrivateKeyKey(id.rawValue))
        try seedPushRegistration(account, deviceIdentifier: "device")
        let host = account.serverURL.host()!.lowercased()
        try keychain.set(Data([4, 5, 6]), for: Keychain.clientCertificateKey(host))
        try keychain.set("p12-password", for: Keychain.clientCertificatePasswordKey(host))
        if let trustStore {
            try trustStore.trust(certificate: Data([7, 8, 9]), for: host)
        } else {
            try write(to: layout.certificates.appending(path: "\(host).der"))
        }
    }

    func seedPushRegistration(_ account: Account, deviceIdentifier: String) throws {
        let registration = PushNotifications.Registration(
            deviceIdentifier: deviceIdentifier, signature: "signature", publicKey: "user-public-key", tokenHash: "hash")
        try keychain.set(try JSONEncoder().encode(registration), for: Keychain.pushRegistrationKey(account.id.rawValue))
    }
}

func makeAccount(_ user: String, server: String) -> Account {
    Account(serverURL: URL(string: server)!, userId: user, loginName: user, displayName: user.capitalized)
}

/// A fake Nextcloud server (and push proxy) behind `URLProtocol`. Each test uses its own host name, so tests can run in
/// parallel; requests to the push proxy are matched by the device identifier in their body, which is the host name.
final class StubServer: Sendable {
    struct Request: Sendable, Equatable {
        var method: String
        var host: String
        var path: String
        var body: String

        var line: String { "\(method) \(path)" }
    }

    struct State: Sendable {
        var requests: [Request] = []
        /// The app password stopped working.
        var unauthorized = false
        var wipeRequested = false
        var downloads: [String: Data] = [:]
        /// Canned answers by request line ("PROPFIND /remote.php/dav/…"): status and body.
        var responses: [String: Stub] = [:]
    }

    struct Stub: Sendable {
        var status: Int
        var body: String
    }

    let host: String
    let state = Mutex(State())
    static let registry = Mutex<[String: StubServer]>([:])

    init() {
        host = "t\(UUID().uuidString.prefix(8).lowercased()).test"
        Self.registry.withLock { $0[host] = self }
    }

    deinit { Self.registry.withLock { $0[host] = nil } }

    var url: URL { URL(string: "https://\(host)")! }

    var configuration: URLSessionConfiguration {
        let configuration = HTTPClient.defaultConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    func http(trustStore: TrustStore = TrustStore(directory: nil)) -> HTTPClient {
        HTTPClient(trustStore: trustStore, configuration: configuration)
    }

    var requests: [Request] { state.withLock { $0.requests } }

    /// Request lines ("DELETE /ocs/v2.php/core/apppassword") matching any of the given path fragments, in order of arrival.
    func lines(containing fragments: String...) -> [String] {
        requests.filter { request in fragments.contains { request.path.contains($0) } }.map(\.line)
    }

    func set(_ change: @Sendable (inout State) -> Void) { state.withLock { change(&$0) } }

    static func ocs(_ data: String = "[]") -> Data {
        Data(#"{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":\#(data)}}"#.utf8)
    }

    func respond(to request: Request) -> (Int, Data) {
        let state = state.withLock { state in
            state.requests.append(request)
            return state
        }
        if request.host == "push-notifications.nextcloud.com" { return (200, Data()) }
        if let stub = state.responses[request.line] { return (stub.status, Data(stub.body.utf8)) }
        switch (request.method, request.path) {
        case ("GET", "/status.php"):
            let status =
                #"{"installed":true,"maintenance":false,"needsDbUpgrade":false,"version":"33.0.0.1","versionstring":"33.0.0","productname":"Nextcloud"}"#
            return (200, Data(status.utf8))
        case ("POST", "/index.php/core/wipe/check"):
            return state.wipeRequested ? (200, Data(#"{"wipe":true}"#.utf8)) : (404, Data())
        case ("POST", "/index.php/core/wipe/success"):
            return (200, Data())
        default: break
        }
        if state.unauthorized { return (401, Data()) }
        switch (request.method, request.path) {
        case ("GET", "/ocs/v2.php/cloud/user"):
            return (200, Self.ocs(#"{"id":"alice","displayname":"Alice"}"#))
        case ("POST", "/ocs/v2.php/apps/notifications/api/v2/push"):
            return (201, Self.ocs(#"{"publicKey":"user-public-key","deviceIdentifier":"\#(host)","signature":"signature"}"#))
        case ("DELETE", "/ocs/v2.php/apps/notifications/api/v2/push"):
            return (202, Self.ocs())
        case ("DELETE", "/ocs/v2.php/core/apppassword"):
            return (200, Self.ocs())
        case ("GET", let path):
            if let data = state.downloads[path] { return (200, data) }
            return (404, Data())
        default:
            return (404, Data())
        }
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.body(of: request)
        let recorded = StubServer.Request(
            method: request.httpMethod ?? "GET", host: host, path: url.path(percentEncoded: false), body: body)
        let server = StubServer.registry.withLock { registry in
            registry[host] ?? registry.values.first { body.contains($0.host) }
        }
        let (status, data) = server?.respond(to: recorded) ?? (404, Data())
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Polls until a condition holds (for work that finishes on another task).
@MainActor
func eventually(timeout: Duration = .seconds(10), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
