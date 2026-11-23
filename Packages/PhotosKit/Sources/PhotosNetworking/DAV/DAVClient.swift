// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Typed WebDAV requests for one account.
public struct DAVClient: Sendable {
    public let http: HTTPClient
    public let connection: ServerConnection
    /// Extra headers, e.g. `X-Recognize-Api-Key` for the Recognize tree.
    public var extraHeaders: [String: String]
    /// Called with `.unauthorized` errors so the app can re-verify the account (SPEC §5.1.6).
    public var onUnauthorized: (@Sendable () -> Void)?
    /// Repeats requests after transient failures. Off by default: only callers whose requests are safe to send twice
    /// set it (the uploader).
    public var retry: RetryPolicy?

    public init(
        http: HTTPClient, connection: ServerConnection, extraHeaders: [String: String] = [:], onUnauthorized: (@Sendable () -> Void)? = nil
    ) {
        self.http = http
        self.connection = connection
        self.extraHeaders = extraHeaders
        self.onUnauthorized = onUnauthorized
    }

    func headers(_ more: [String: String] = [:]) -> [String: String] {
        connection.standardHeaders.merging(extraHeaders) { $1 }.merging(more) { $1 }
    }

    /// Sends a request and maps HTTP errors. Accepts any 2xx (and 207).
    @discardableResult
    public func send(_ method: String, _ url: URL, headers more: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 60)
        async throws
        -> HTTPResponse
    {
        let request = HTTPRequest(method: method, url: url, headers: headers(more), body: body, timeout: timeout, retry: retry)
        let response = try await http.send(request)
        if let error = NetworkError.from(status: response.status, data: response.data) {
            if error == .unauthorized { onUnauthorized?() }
            throw error
        }
        return response
    }

    public func propfind(_ url: URL, depth: Int, properties: [QName]) async throws -> [DAVResource] {
        let response = try await send(
            "PROPFIND", url,
            headers: ["Depth": depth == 0 ? "0" : "1", "Content-Type": "application/xml; charset=utf-8"],
            body: DAVBody.propfind(properties)
        )
        return try MultiStatus.parse(response.data)
    }

    public func search(_ search: DAVSearch, timeout: TimeInterval = 120) async throws -> [DAVResource] {
        let response = try await send(
            "SEARCH", connection.davRoot.appendingTrailingSlashIfNeeded(true),
            headers: ["Content-Type": "text/xml; charset=utf-8"],
            body: search.body, timeout: timeout
        )
        return try MultiStatus.parse(response.data)
    }

    public func report(_ url: URL, body: Data, depth: Int? = nil) async throws -> [DAVResource] {
        var headers = ["Content-Type": "application/xml; charset=utf-8"]
        if let depth { headers["Depth"] = String(depth) }
        let response = try await send("REPORT", url, headers: headers, body: body, timeout: 180)
        return try MultiStatus.parse(response.data)
    }

    /// PROPPATCH; throws `.forbidden` if any property update was rejected.
    public func proppatch(_ url: URL, set: [(QName, DAVBody.PropValue)] = [], remove: [QName] = []) async throws {
        let response = try await send(
            "PROPPATCH", url,
            headers: ["Content-Type": "application/xml; charset=utf-8"],
            body: DAVBody.proppatch(set: set, remove: remove)
        )
        guard response.status == 207, let resources = try? MultiStatus.parse(response.data) else { return }
        // A propstat with a non-2xx status means the update was rejected.
        if let failed = resources.first(where: { !$0.missing.isEmpty }) {
            throw NetworkError.forbidden(
                message: "Property update rejected: \(failed.missing.map(\.name).sorted().joined(separator: ", "))")
        }
    }

    public func mkcol(_ url: URL) async throws {
        try await send("MKCOL", url)
    }

    /// Creates every missing folder of a user path (`/a/b/c`), ignoring existing ones.
    public func mkcolRecursive(userPath: String) async throws {
        var current = ""
        for component in userPath.split(separator: "/") {
            current += "/\(component)"
            do {
                try await mkcol(connection.filesURL(current))
            } catch NetworkError.conflict {
                continue  // 405: exists
            }
        }
    }

    public func delete(_ url: URL) async throws {
        try await send("DELETE", url)
    }

    public func move(_ source: URL, to destination: URL, overwrite: Bool = false) async throws {
        try await send("MOVE", source, headers: ["Destination": destination.absoluteString, "Overwrite": overwrite ? "T" : "F"])
    }

    public func copy(_ source: URL, to destination: URL, overwrite: Bool = false) async throws {
        try await send("COPY", source, headers: ["Destination": destination.absoluteString, "Overwrite": overwrite ? "T" : "F"])
    }

    public func get(_ url: URL, headers more: [String: String] = [:]) async throws -> HTTPResponse {
        try await send("GET", url, headers: more, timeout: 300)
    }

    public func head(_ url: URL) async throws -> HTTPResponse {
        try await send("HEAD", url)
    }

    public func download(_ url: URL) async throws -> (URL, HTTPResponse) {
        let (file, response) = try await http.download(HTTPRequest(url: url, headers: headers(), timeout: 600))
        if let error = NetworkError.from(status: response.status, data: Data()) {
            try? FileManager.default.removeItem(at: file)
            if error == .unauthorized { onUnauthorized?() }
            throw error
        }
        return (file, response)
    }

    public func put(_ url: URL, file: URL, headers more: [String: String] = [:]) async throws -> HTTPResponse {
        let request = HTTPRequest(method: "PUT", url: url, headers: headers(more), timeout: 3600, retry: retry)
        let response = try await http.upload(request, fromFile: file)
        if let error = NetworkError.from(status: response.status, data: response.data) {
            if error == .unauthorized { onUnauthorized?() }
            throw error
        }
        return response
    }

    public func put(_ url: URL, data: Data, headers more: [String: String] = [:]) async throws -> HTTPResponse {
        try await send("PUT", url, headers: more, body: data, timeout: 600)
    }
}
