// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

@testable import PhotosNetworking

/// An in-memory stand-in for the DAV endpoints an upload uses: the user's files (PROPFIND, MKCOL, PUT, DELETE) and the
/// chunking v2 upload collection (`uploads/<user>/<folder>`: MKCOL, PUT of numbered chunks, PROPFIND, MOVE of `.file`,
/// DELETE). Faults can be injected per request. Reached through `UploadStubProtocol`.
final class UploadStubServer: Sendable {
    struct Request: Sendable {
        var method: String
        /// Decoded path below `/remote.php/dav`, e.g. `/files/alice/Photos/a.jpg`.
        var path: String
        var headers: [String: String]
        var body: Data

        var line: String { "\(method) \(path)" }
    }

    enum Outcome: Sendable {
        case status(Int, headers: [String: String] = [:])
        case error(URLError.Code)
    }

    /// Fails matching requests.
    struct Fault: Sendable {
        var matches: @Sendable (Request) -> Bool
        var outcome: Outcome
        /// How many requests it still fails.
        var remaining = 1
        /// The server does what was asked and only the answer gets lost.
        var afterHandling = false
        /// Runs when the fault fires, e.g. to make the upload folder disappear.
        var sideEffect: (@Sendable (inout State) -> Void)?
    }

    struct Upload: Sendable {
        var chunks: [Int: Data] = [:]
        var modified = Date()
    }

    struct State: Sendable {
        /// User path → content.
        var files: [String: Data] = [:]
        var fileIds: [String: Int64] = [:]
        var folders: Set<String> = ["/"]
        /// Upload folder name → chunks.
        var uploads: [String: Upload] = [:]
        var requests: [Request] = []
        var faults: [Fault] = []
        var nextFileId: Int64 = 100
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    let user = "alice"
    let host = "upload-\(UUID().uuidString.lowercased()).test"
    let state = Mutex(State())
    /// Waits recorded instead of slept.
    let sleeps = ValueLog()
    static let servers = Mutex<[String: UploadStubServer]>([:])

    init() {
        Self.servers.withLock { $0[host] = self }
    }

    deinit {
        let host = self.host
        Self.servers.withLock { $0[host] = nil }
    }

    var connection: ServerConnection {
        ServerConnection(
            serverURL: URL(string: "http://\(host)")!, userId: user, loginName: user, appPassword: "secret", userAgent: "tests")
    }

    var dav: DAVClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadStubProtocol.self]
        return DAVClient(http: HTTPClient(trustStore: TrustStore(directory: nil), configuration: configuration), connection: connection)
    }

    /// A retry policy that records its waits instead of sleeping.
    var retry: RetryPolicy {
        RetryPolicy(sleep: { [sleeps] seconds in sleeps.add(seconds) })
    }

    /// An uploader with tiny chunks: files above 10 bytes go in chunks of 10.
    var uploader: Uploader {
        var uploader = Uploader(dav: dav, retry: retry)
        uploader.chunkThreshold = 10
        uploader.chunkSize = 10
        return uploader
    }

    var requests: [Request] { state.withLock { $0.requests } }
    var lines: [String] { requests.map(\.line) }
    func clearRequests() { state.withLock { $0.requests = [] } }
    func file(_ path: String) -> Data? { state.withLock { $0.files[path] } }
    var uploads: [String: Upload] { state.withLock { $0.uploads } }

    /// Lets a file appear right after the server said its name is free (another client was faster).
    func appear(_ path: String, content: Data, afterLookups: Int = 1) {
        let fault = Fault(
            matches: { $0.method == "PROPFIND" && $0.path.hasSuffix(path) }, outcome: .status(404), remaining: afterLookups,
            afterHandling: true,
            sideEffect: { state in
                guard state.files[path] == nil else { return }
                state.files[path] = content
                state.nextFileId += 1
                state.fileIds[path] = state.nextFileId
            })
        state.withLock { $0.faults.append(fault) }
    }

    func fail(
        _ method: String, suffix: String = "", times: Int = 1, afterHandling: Bool = false, with outcome: Outcome,
        sideEffect: (@Sendable (inout State) -> Void)? = nil
    ) {
        let fault = Fault(
            matches: { $0.method == method && $0.path.hasSuffix(suffix) }, outcome: outcome, remaining: times,
            afterHandling: afterHandling, sideEffect: sideEffect)
        state.withLock { $0.faults.append(fault) }
    }

    // MARK: Request handling

    enum Result: Sendable {
        case response(Response)
        case failure(URLError.Code)
    }

    func handle(method: String, url: URL, headers: [String: String], body: Data) -> Result {
        var path = url.path(percentEncoded: false)
        if path.hasPrefix("/remote.php/dav") { path.removeFirst("/remote.php/dav".count) }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let request = Request(method: method, path: path, headers: headers, body: body)
        return state.withLock { state in
            state.requests.append(request)
            var fault: Fault?
            if let index = state.faults.firstIndex(where: { $0.remaining > 0 && $0.matches(request) }) {
                state.faults[index].remaining -= 1
                fault = state.faults[index]
            }
            if let fault, !fault.afterHandling {
                fault.sideEffect?(&state)
                return Self.result(fault.outcome)
            }
            let response = respond(to: request, state: &state)
            if let fault {
                fault.sideEffect?(&state)
                return Self.result(fault.outcome)
            }
            return .response(response)
        }
    }

    static func result(_ outcome: Outcome) -> Result {
        switch outcome {
        case .status(let status, let headers): .response(Response(status: status, headers: headers))
        case .error(let code): .failure(code)
        }
    }

    private func respond(to request: Request, state: inout State) -> Response {
        let filesPrefix = "/files/\(user)"
        let uploadsPrefix = "/uploads/\(user)"
        if request.path.hasPrefix(uploadsPrefix) {
            let parts = request.path.dropFirst(uploadsPrefix.count).split(separator: "/").map(String.init)
            return respondUpload(to: request, parts: parts, state: &state)
        }
        guard request.path.hasPrefix(filesPrefix) else { return Response(status: 404) }
        var path = String(request.path.dropFirst(filesPrefix.count))
        if path.isEmpty { path = "/" }
        let parent = (path as NSString).deletingLastPathComponent
        switch request.method {
        case "PROPFIND":
            if let data = state.files[path] {
                let props =
                    "<oc:fileid>\(state.fileIds[path] ?? 0)</oc:fileid><oc:size>\(data.count)</oc:size><d:getetag>&quot;e&quot;</d:getetag>"
                return Self.multistatus(Self.entry(href: request.path, props: props))
            }
            guard state.folders.contains(path) else { return Response(status: 404) }
            return Self.multistatus(Self.entry(href: request.path + "/", props: "<d:resourcetype><d:collection/></d:resourcetype>"))
        case "MKCOL":
            if state.folders.contains(path) { return Response(status: 405) }
            guard state.folders.contains(parent) else { return Response(status: 409) }
            state.folders.insert(path)
            return Response(status: 201)
        case "PUT":
            guard state.folders.contains(parent) else { return Response(status: 409) }
            if state.files[path] != nil, request.headers["If-None-Match"] == "*" { return Response(status: 412) }
            return Self.store(request.body, at: path, state: &state)
        case "DELETE":
            guard state.files.removeValue(forKey: path) != nil else { return Response(status: 404) }
            return Response(status: 204)
        default:
            return Response(status: 405)
        }
    }

    private func respondUpload(to request: Request, parts: [String], state: inout State) -> Response {
        guard let folder = parts.first else {
            // The collection of all uploads: "Listing members of this collection is disabled".
            return Response(status: 405)
        }
        if parts.count == 1 {
            switch request.method {
            case "MKCOL":
                if state.uploads[folder] != nil { return Response(status: 405) }
                state.uploads[folder] = Upload()
                return Response(status: 201)
            case "PROPFIND":
                guard let upload = state.uploads[folder] else { return Response(status: 404) }
                let entries = upload.chunks.map { number, data in
                    Self.entry(href: request.path + "/\(number)", props: "<d:getcontentlength>\(data.count)</d:getcontentlength>")
                }
                return Self.multistatus(
                    Self.entry(href: request.path + "/", props: "<d:resourcetype><d:collection/></d:resourcetype>") + entries.joined())
            case "DELETE":
                guard state.uploads.removeValue(forKey: folder) != nil else { return Response(status: 404) }
                return Response(status: 204)
            default:
                return Response(status: 405)
            }
        }
        guard var upload = state.uploads[folder] else { return Response(status: 404) }
        let name = parts[1]
        switch request.method {
        case "PUT":
            guard let number = Int(name) else { return Response(status: 400) }
            upload.chunks[number] = request.body
            upload.modified = Date()
            state.uploads[folder] = upload
            return Response(status: 201)
        case "MOVE":
            guard name == ".file",
                let destination = request.headers["Destination"].flatMap(URL.init(string:))?.path(percentEncoded: false),
                let range = destination.range(of: "/files/\(user)")
            else { return Response(status: 400) }
            let path = String(destination[range.upperBound...])
            if state.files[path] != nil, request.headers["Overwrite"] == "F" { return Response(status: 412) }
            let data = upload.chunks.keys.sorted().reduce(into: Data()) { $0.append(upload.chunks[$1] ?? Data()) }
            guard String(data.count) == request.headers["OC-Total-Length"] else { return Response(status: 400) }
            guard state.folders.contains((path as NSString).deletingLastPathComponent) else { return Response(status: 409) }
            state.uploads[folder] = nil
            return Self.store(data, at: path, state: &state)
        default:
            return Response(status: 405)
        }
    }

    static func store(_ data: Data, at path: String, state: inout State) -> Response {
        let created = state.files[path] == nil
        state.files[path] = data
        if state.fileIds[path] == nil {
            state.nextFileId += 1
            state.fileIds[path] = state.nextFileId
        }
        let id = String(format: "%08d", state.fileIds[path] ?? 0) + "ocstub"
        return Response(status: created ? 201 : 204, headers: ["OC-FileId": id, "OC-ETag": "\"e\""])
    }

    static func entry(href: String, props: String) -> String {
        let encoded = href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? href
        return
            "<d:response><d:href>/remote.php/dav\(encoded)</d:href><d:propstat><d:prop>\(props)</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }

    static func multistatus(_ responses: String) -> Response {
        let body =
            "<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\" xmlns:oc=\"http://owncloud.org/ns\" xmlns:nc=\"http://nextcloud.org/ns\">\(responses)</d:multistatus>"
        return Response(status: 207, headers: ["Content-Type": "application/xml"], body: Data(body.utf8))
    }
}

/// Routes requests of a stubbed `URLSession` to the `UploadStubServer` registered for the request's host.
///
/// `@unchecked Sendable`: `URLProtocol` is not Sendable; an instance is only used by the URL loading system, and it answers
/// synchronously in `startLoading`.
final class UploadStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = UploadStubServer.servers.withLock({ $0[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let result = server.handle(
            method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        switch result {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let response):
            let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// A request body reaches a `URLProtocol` as a stream.
    static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Upload folders remembered in memory.
final class MemoryUploadFolders: UploadFolderRegistry {
    private let folders = Mutex<[String: Date]>([:])
    func touch(_ name: String, at date: Date) { folders.withLock { $0[name] = date } }
    func remove(_ name: String) { folders.withLock { $0[name] = nil } }
    func entries() -> [String: Date] { folders.withLock { $0 } }
}

/// Numbers collected from `@Sendable` closures (waits, progress).
final class ValueLog: Sendable {
    private let log = Mutex<[Double]>([])
    var values: [Double] { log.withLock { $0 } }
    func add(_ value: Double) { log.withLock { $0.append(value) } }
    func clear() { log.withLock { $0 = [] } }
}
