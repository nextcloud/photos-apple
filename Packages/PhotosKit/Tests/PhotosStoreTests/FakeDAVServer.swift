// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// An in-memory stand-in for the DAV endpoints the sync engine and the outbox use (PROPFIND of a root, the index /
/// delta / by-id / favourites SEARCHes, PROPPATCH of the favourite flag, DELETE, MOVE), reached through `StubURLProtocol`.
final class FakeDAVServer: Sendable {
    struct File: Sendable {
        var id: FileID
        var path: String
        var etag: String
        var modified: Double
        var captured: Double?
        var uploaded: Double?
        var favorite = false
        var place: String?
        var caption: String?
        var mime = "image/jpeg"
    }

    enum Kind: Sendable, Equatable {
        case propfind
        /// Index page ordered by capture time (initial sync) or modification time (reconciliation).
        case indexByCapture, indexByModified
        case changed
        case byIds([FileID])
        case favorites
        case proppatch, delete, move
        case other
    }

    struct Request: Sendable {
        var method: String
        /// Path below the user's files root for file requests, else the URL path.
        var path: String
        var body: String
        var kind: Kind
    }

    struct State: Sendable {
        var files: [FileID: File] = [:]
        /// The recursive ETag every existing root reports.
        var rootETag = "root-1"
        var folders: Set<String> = ["/Photos"]
        var requests: [Request] = []
        /// When true, every request fails as if the device were offline.
        var offline = false
        var generation = 1
    }

    let user = "alice"
    let host = "stub-\(UUID().uuidString.lowercased()).test"
    let state = Mutex(State())
    /// Runs before a request is answered; can suspend to hold a request back.
    let gate = Mutex<(@Sendable (Request) async -> Void)?>(nil)
    /// Runs after a response was computed (the response does not include what it changes).
    let afterResponse = Mutex<(@Sendable (Request, inout State) -> Void)?>(nil)

    init() {
        StubURLProtocol.servers.withLock { $0[host] = self }
    }

    deinit {
        // No `self` here: the registry only needs the key.
        let host = self.host
        StubURLProtocol.servers.withLock { $0[host] = nil }
    }

    var connection: ServerConnection {
        ServerConnection(
            serverURL: URL(string: "http://\(host)")!, userId: user, loginName: user, appPassword: "secret", userAgent: "tests")
    }

    var api: PhotosAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let http = HTTPClient(trustStore: TrustStore(directory: nil), configuration: configuration)
        return PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
    }

    // MARK: Changes "made elsewhere"

    /// Adds or replaces files. A changed file tree changes the root ETag, like on a real server.
    func put(_ files: File...) {
        state.withLock { state in
            for file in files { state.files[file.id] = file }
            Self.bumpRoot(&state)
        }
    }

    /// Favourites change no ETag at all (verified against Nextcloud 36).
    func setFavorite(_ id: FileID, _ value: Bool) {
        state.withLock { $0.files[id]?.favorite = value }
    }

    /// Place and caption are filled in by background jobs, without an ETag change.
    func setMetadata(_ id: FileID, place: String?, caption: String?) {
        state.withLock {
            $0.files[id]?.place = place
            $0.files[id]?.caption = caption
        }
    }

    func delete(_ id: FileID, changingRootETag: Bool = true) {
        state.withLock { state in
            state.files[id] = nil
            if changingRootETag { Self.bumpRoot(&state) }
        }
    }

    func move(_ id: FileID, to path: String) {
        state.withLock { state in
            state.files[id]?.path = path
            Self.bumpRoot(&state)
        }
    }

    func setOffline(_ offline: Bool) { state.withLock { $0.offline = offline } }

    var requests: [Request] { state.withLock { $0.requests } }

    func requests(_ kind: Kind) -> [Request] { requests.filter { $0.kind == kind } }

    func clearRequests() { state.withLock { $0.requests = [] } }

    func file(_ id: FileID) -> File? { state.withLock { $0.files[id] } }

    static func bumpRoot(_ state: inout State) {
        state.generation += 1
        state.rootETag = "root-\(state.generation)"
    }

    // MARK: Request handling

    enum Response: Sendable {
        case http(status: Int, body: String)
        case failure(URLError.Code)
    }

    func handle(method: String, url: URL, headers: [String: String], body: String) async -> Response {
        let filesPrefix = "/remote.php/dav/files/\(user)"
        let urlPath = url.path(percentEncoded: false)
        var path = urlPath.hasPrefix(filesPrefix) ? String(urlPath.dropFirst(filesPrefix.count)) : urlPath
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/" }
        let request = Request(method: method, path: path, body: body, kind: Self.kind(method: method, body: body))
        state.withLock { $0.requests.append(request) }
        if let gate = gate.withLock({ $0 }) { await gate(request) }
        let after = afterResponse.withLock { $0 }
        return state.withLock { state in
            if state.offline { return .failure(.notConnectedToInternet) }
            let response = respond(to: request, headers: headers, state: &state)
            after?(request, &state)
            return response
        }
    }

    static func kind(method: String, body: String) -> Kind {
        switch method {
        case "PROPFIND": return .propfind
        case "PROPPATCH": return .proppatch
        case "DELETE": return .delete
        case "MOVE": return .move
        case "SEARCH":
            if body.contains("<d:eq><d:prop><oc:favorite/></d:prop><d:literal>1</d:literal></d:eq>") { return .favorites }
            let ids = body.matches(of: /<d:eq><d:prop><oc:fileid\/><\/d:prop><d:literal>(\d+)<\/d:literal><\/d:eq>/).compactMap {
                FileID($0.1)
            }
            if !ids.isEmpty { return .byIds(ids) }
            if body.contains("<d:gt><d:prop><d:getlastmodified/>") { return .changed }
            if body.contains("<d:orderby><d:order><d:prop><d:getlastmodified/>") { return .indexByModified }
            if body.contains("<d:getlastmodified/></d:prop><d:literal>") { return .indexByModified }  // boundary completion
            return .indexByCapture
        default: return .other
        }
    }

    private func respond(to request: Request, headers: [String: String], state: inout State) -> Response {
        switch request.kind {
        case .propfind:
            guard state.folders.contains(request.path) else { return .http(status: 404, body: "") }
            let body =
                "<d:response><d:href>/remote.php/dav/files/\(user)\(request.path)/</d:href><d:propstat><d:prop><d:getetag>&quot;\(state.rootETag)&quot;</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            return .http(status: 207, body: Self.multistatus(body))
        case .proppatch:
            guard let id = state.files.values.first(where: { $0.path == request.path })?.id else { return .http(status: 404, body: "") }
            if request.body.contains("<oc:favorite>1</oc:favorite>") { state.files[id]?.favorite = true }
            if request.body.contains("<oc:favorite>0</oc:favorite>") { state.files[id]?.favorite = false }
            let body =
                "<d:response><d:href>/remote.php/dav/files/\(user)\(request.path)</d:href><d:propstat><d:prop><oc:favorite/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            return .http(status: 207, body: Self.multistatus(body))
        case .delete:
            guard let id = state.files.values.first(where: { $0.path == request.path })?.id else { return .http(status: 404, body: "") }
            state.files[id] = nil
            Self.bumpRoot(&state)
            return .http(status: 204, body: "")
        case .move:
            guard let id = state.files.values.first(where: { $0.path == request.path })?.id,
                let destination = headers["Destination"].flatMap(URL.init(string:))?.path(percentEncoded: false),
                let range = destination.range(of: "/files/\(user)")
            else { return .http(status: 404, body: "") }
            state.files[id]?.path = String(destination[range.upperBound...])
            Self.bumpRoot(&state)
            return .http(status: 201, body: "")
        case .favorites:
            return search(request, state: state) { $0.favorite }
        case .byIds(let ids):
            return search(request, state: state) { ids.contains($0.id) }
        case .changed:
            let iso = request.body.firstMatch(of: /<d:gt><d:prop><d:getlastmodified\/><\/d:prop><d:literal>([^<]+)</)?.1
            let since = iso.flatMap { ISO8601DateFormatter().date(from: String($0)) }?.timeIntervalSince1970 ?? 0
            return search(request, state: state) { $0.modified > since || ($0.uploaded ?? 0) > since }
        case .indexByCapture, .indexByModified:
            let byModified = request.kind == .indexByModified
            func value(_ file: File) -> Double? { byModified ? file.modified : file.captured }
            func literal(_ op: String) -> Double? {
                let property = byModified ? "d:getlastmodified" : "nc:metadata-photos-original_date_time"
                guard let regex = try? Regex("<d:\(op)><d:prop><\(property)/></d:prop><d:literal>([^<]+)</d:literal></d:\(op)>"),
                    let match = request.body.firstMatch(of: regex), let text = match.output[1].substring
                else { return nil }
                return byModified ? ISO8601DateFormatter().date(from: String(text))?.timeIntervalSince1970 : Double(text)
            }
            let before = literal("lt")
            let from = literal("gte")
            let limit = request.body.firstMatch(of: /<d:nresults>(\d+)<\/d:nresults>/).flatMap { Int($0.1) }
            return search(request, state: state, limit: limit, order: value) { file in
                guard let value = value(file) else { return false }
                if let before, value >= before { return false }
                if let from, value < from { return false }
                return true
            }
        case .other:
            return .http(status: 405, body: "")
        }
    }

    private func search(
        _ request: Request, state: State, limit: Int? = nil, order: ((File) -> Double?)? = nil, where include: (File) -> Bool
    ) -> Response {
        let scopes = request.body.matches(of: /<d:scope><d:href>([^<]*)<\/d:href>/).map { String($0.1.dropFirst("/files/\(user)".count)) }
        var files = state.files.values.filter { file in
            include(file) && scopes.contains { $0.isEmpty || file.path.hasPrefix($0 + "/") }
        }
        files.sort { (order?($0) ?? $0.modified, $0.id) > (order?($1) ?? $1.modified, $1.id) }
        if let limit { files = Array(files.prefix(limit)) }
        return .http(status: 207, body: Self.multistatus(files.map(xml).joined()))
    }

    private func xml(_ file: File) -> String {
        var props = "<oc:fileid>\(file.id)</oc:fileid><d:getcontenttype>\(file.mime)</d:getcontenttype><oc:size>1000</oc:size>"
        props += "<d:getetag>&quot;\(file.etag)&quot;</d:getetag>"
        props += "<d:getlastmodified>\(HTTPDate.format(Date(timeIntervalSince1970: file.modified)))</d:getlastmodified>"
        props += "<oc:favorite>\(file.favorite ? 1 : 0)</oc:favorite><oc:permissions>RGDNVW</oc:permissions>"
        if let uploaded = file.uploaded { props += "<nc:upload_time>\(Int(uploaded))</nc:upload_time>" }
        if let captured = file.captured {
            props += "<nc:metadata-photos-original_date_time>\(Int(captured))</nc:metadata-photos-original_date_time>"
        }
        if let place = file.place { props += "<nc:metadata-photos-place>\(place)</nc:metadata-photos-place>" }
        if let caption = file.caption { props += "<nc:metadata-photos-caption>\(caption)</nc:metadata-photos-caption>" }
        return
            "<d:response><d:href>/remote.php/dav/files/\(user)\(file.path)</d:href><d:propstat><d:prop>\(props)</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }

    static func multistatus(_ responses: String) -> String {
        "<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\" xmlns:s=\"http://sabredav.org/ns\" xmlns:oc=\"http://owncloud.org/ns\" xmlns:nc=\"http://nextcloud.org/ns\">\(responses)</d:multistatus>"
    }
}

/// Routes requests of a stubbed `URLSession` to the `FakeDAVServer` registered for the request's host.
///
/// `@unchecked Sendable`: `URLProtocol` is not Sendable, but an instance is only touched by the URL loading system
/// (`startLoading` / `stopLoading`) and by the one task it starts; `work` is guarded by a mutex.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let servers = Mutex<[String: FakeDAVServer]>([:])
    private let work = Mutex<Task<Void, Never>?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        guard let url = request.url, let server = Self.servers.withLock({ $0[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let body = String(decoding: Self.body(of: request), as: UTF8.self)
        let work = Task {
            let response = await server.handle(
                method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: body)
            guard !Task.isCancelled else { return }
            switch response {
            case .failure(let code):
                self.client?.urlProtocol(self, didFailWithError: URLError(code))
            case .http(let status, let body):
                let http = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/xml"])!
                self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data(body.utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        self.work.withLock { $0 = work }
    }

    override func stopLoading() {
        work.withLock { $0?.cancel() }
    }

    /// A request body reaches a `URLProtocol` as a stream.
    static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Polls until a condition holds (a throwing condition counts as "not yet"); returns false on timeout.
@discardableResult
func eventually(timeout: TimeInterval = 5, _ condition: @Sendable () async throws -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if (try? await condition()) == true { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return (try? await condition()) == true
}
