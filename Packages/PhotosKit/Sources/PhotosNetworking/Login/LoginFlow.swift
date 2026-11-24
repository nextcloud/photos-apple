// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// `status.php`
public struct ServerStatus: Decodable, Sendable {
    public var installed: Bool
    public var maintenance: Bool
    public var needsDbUpgrade: Bool
    public var version: String
    public var versionstring: String
    public var productname: String

    public var serverVersion: ServerVersion? { ServerVersion(parsing: version) }
}

/// Login Flow v2 and other unauthenticated server calls (SPEC §5.1).
///
/// Implemented directly on the app's `HTTPClient` (two requests) so login shares the app's certificate handling.
public struct LoginService: Sendable {
    public let http: HTTPClient
    public let userAgent: String

    public init(http: HTTPClient, userAgent: String) {
        self.http = http
        self.userAgent = userAgent
    }

    public struct Flow: Sendable, Equatable {
        public var loginURL: URL
        public var pollEndpoint: URL
        public var token: String
    }

    public struct Credentials: Sendable, Equatable {
        public var serverURL: URL
        public var loginName: String
        public var appPassword: String

        public init(serverURL: URL, loginName: String, appPassword: String) {
            self.serverURL = serverURL
            self.loginName = loginName
            self.appPassword = appPassword
        }
    }

    /// Normalises user input into a server URL (adds `https://`, strips `index.php`, trailing slashes).
    public static func normalizeServerAddress(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return ServerConnection.normalized(url)
    }

    /// True when logging in to this server sends the password and every photo unencrypted: plain `http://` to anything
    /// but this device itself. The login screen asks for confirmation first.
    public static func isUnencrypted(_ serverURL: URL) -> Bool {
        guard serverURL.scheme?.lowercased() == "http" else { return false }
        let host = (serverURL.host() ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return !["localhost", "127.0.0.1", "::1"].contains(host)
    }

    public func status(serverURL: URL) async throws -> ServerStatus {
        let url = serverURL.appending(path: "status.php")
        let response = try await http.send(
            HTTPRequest(url: url, headers: ["User-Agent": userAgent, "Accept": "application/json"], timeout: 30))
        guard response.isSuccess else {
            if response.status == 503 { throw NetworkError.maintenance }
            throw NetworkError.unsupportedServer(String(localized: "No Nextcloud server was found at this address.", bundle: .module))
        }
        guard let status = try? JSONDecoder().decode(ServerStatus.self, from: response.data) else {
            throw NetworkError.unsupportedServer(String(localized: "No Nextcloud server was found at this address.", bundle: .module))
        }
        if status.maintenance { throw NetworkError.maintenance }
        guard let version = status.serverVersion, version.isSupported else {
            throw NetworkError.unsupportedServer(
                String(
                    localized: "This server is too old. Nextcloud \(ServerVersion.minimumSupportedMajor) or later is required.",
                    bundle: .module))
        }
        return status
    }

    public func startFlow(serverURL: URL) async throws -> Flow {
        let url = serverURL.appending(path: "index.php/login/v2")
        let response = try await http.send(
            HTTPRequest(method: "POST", url: url, headers: ["User-Agent": userAgent, "Accept": "application/json"], timeout: 30))
        guard response.isSuccess else {
            throw NetworkError.from(status: response.status, data: response.data) ?? .http(status: response.status, message: nil)
        }
        struct Body: Decodable {
            struct Poll: Decodable {
                var token: String
                var endpoint: String
            }
            var poll: Poll
            var login: String
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: response.data),
            let login = URL(string: body.login), let endpoint = URL(string: body.poll.endpoint)
        else { throw NetworkError.invalidResponse("login/v2") }
        return Flow(
            loginURL: Self.keepingEncryption(login, of: serverURL), pollEndpoint: Self.keepingEncryption(endpoint, of: serverURL),
            token: body.poll.token)
    }

    /// A URL the server named for itself, upgraded to `https://` when the address the user typed is `https://`.
    ///
    /// A server behind a proxy that terminates TLS, without `overwriteprotocol`, names its own addresses with `http://`. The
    /// browser login and the poll (whose answer carries the app password) must not fall back to plain http because of that:
    /// the server answered the typed `https://` address, so it is reachable that way. The port of the typed address is
    /// used when the server named the same host on the default http port.
    public static func keepingEncryption(_ url: URL, of typed: URL) -> URL {
        guard typed.scheme?.lowercased() == "https", url.scheme?.lowercased() == "http",
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        if components.port == nil, url.host()?.lowercased() == typed.host()?.lowercased() { components.port = typed.port }
        return components.url ?? url
    }

    /// The account address a finished login uses: the one the server returned, upgraded to `https://` when it is the same
    /// host the user typed with `https://` (the misconfigured-proxy case of `keepingEncryption`). Another host keeps the
    /// address the server named; the login screen then decides whether plain http is acceptable.
    public static func securedServerURL(_ returned: URL, typed: URL) -> URL {
        guard returned.host()?.lowercased() == typed.host()?.lowercased() else { return returned }
        return ServerConnection.normalized(keepingEncryption(returned, of: typed))
    }

    /// Revokes an app password that was granted but will not be used (the login was refused afterwards). Sent to `serverURL`,
    /// which must be the encrypted address the login ran on: the password never travels over plain http for this.
    public func revoke(_ credentials: Credentials, at serverURL: URL) async {
        let connection = ServerConnection(
            serverURL: serverURL, userId: credentials.loginName, loginName: credentials.loginName,
            appPassword: credentials.appPassword, userAgent: userAgent)
        try? await AccountAPI(ocs: OCSClient(http: http, connection: connection)).revokeAppPassword()
    }

    /// One poll. Returns `nil` while the user hasn't granted access yet (HTTP 404).
    public func poll(_ flow: Flow) async throws -> Credentials? {
        let body = Data(OCSClient.formEncode(["token": flow.token]).utf8)
        let response = try await http.send(
            HTTPRequest(
                method: "POST", url: flow.pollEndpoint,
                headers: ["User-Agent": userAgent, "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
                body: body, timeout: 30))
        if response.status == 404 { return nil }
        guard response.isSuccess else {
            throw NetworkError.from(status: response.status, data: response.data) ?? .http(status: response.status, message: nil)
        }
        struct Result: Decodable {
            var server: String
            var loginName: String
            var appPassword: String
        }
        guard let result = try? JSONDecoder().decode(Result.self, from: response.data), let server = URL(string: result.server) else {
            throw NetworkError.invalidResponse("login/v2/poll")
        }
        return Credentials(serverURL: ServerConnection.normalized(server), loginName: result.loginName, appPassword: result.appPassword)
    }

    /// Polls every second until granted, cancelled, or 20 minutes passed (the server's flow lifetime).
    public func waitForGrant(_ flow: Flow) async throws -> Credentials {
        let deadline = Date().addingTimeInterval(20 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                if let credentials = try await poll(flow) { return credentials }
            } catch let error as NetworkError where error.isTransient {
                // keep polling through short network hiccups
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw NetworkError.timedOut
    }

    /// Parses `nc://login/server:<url>&user:<user>&password:<pw>` QR codes / callbacks.
    public static func parseLoginURL(_ string: String) -> Credentials? {
        guard string.hasPrefix("nc://login/") else { return nil }
        let rest = String(string.dropFirst("nc://login/".count))
        var server: String?
        var user: String?
        var password: String?
        for part in rest.components(separatedBy: "&") {
            if part.hasPrefix("server:") { server = String(part.dropFirst(7)) }
            if part.hasPrefix("user:") { user = String(part.dropFirst(5)).removingPercentEncoding }
            if part.hasPrefix("password:") { password = String(part.dropFirst(9)).removingPercentEncoding }
        }
        guard let server, let serverURL = URL(string: server), let user, let password else { return nil }
        return Credentials(serverURL: ServerConnection.normalized(serverURL), loginName: user, appPassword: password)
    }

    /// Parses `nc://onetime-login/server:<url>&user:<user>&password:<onetime-token>` QR codes.
    public static func parseOnetimeLoginURL(_ string: String) -> Credentials? {
        guard string.hasPrefix("nc://onetime-login/") else { return nil }
        return parseLoginURL("nc://login/" + string.dropFirst("nc://onetime-login/".count))
    }

    /// Exchanges a one-time token for an app password (`ocs/v2.php/core/getapppassword-onetime`).
    public func exchangeOnetimeToken(_ credentials: Credentials) async throws -> Credentials {
        let connection = ServerConnection(
            serverURL: credentials.serverURL, userId: credentials.loginName, loginName: credentials.loginName,
            appPassword: credentials.appPassword, userAgent: userAgent)
        let ocs = OCSClient(http: http, connection: connection)
        struct Body: Decodable { var apppassword: String }
        let body: Body = try await ocs.request("GET", "ocs/v2.php/core/getapppassword-onetime")
        return Credentials(serverURL: credentials.serverURL, loginName: credentials.loginName, appPassword: body.apppassword)
    }
}

/// Authenticated account-level calls: profile, app password revocation, remote wipe.
public struct AccountAPI: Sendable {
    public let ocs: OCSClient

    public init(ocs: OCSClient) { self.ocs = ocs }

    public struct Profile: Decodable, Sendable {
        public var id: String
        public var displayname: String?
        public var email: String?
    }

    public func profile() async throws -> Profile {
        try await ocs.request("GET", "ocs/v2.php/cloud/user")
    }

    /// Revokes the app password on the server (`DELETE ocs/v2.php/core/apppassword`).
    public func revokeAppPassword() async throws {
        _ = try await ocs.raw("DELETE", "ocs/v2.php/core/apppassword")
    }

    /// `POST index.php/core/wipe/check` → true when the server asks to wipe this device's data.
    public func remoteWipeRequested() async throws -> Bool {
        let connection = ocs.connection
        let body = Data(OCSClient.formEncode(["token": connection.appPassword]).utf8)
        let response = try await ocs.http.send(
            HTTPRequest(
                method: "POST", url: connection.url("index.php/core/wipe/check"),
                headers: [
                    "User-Agent": connection.userAgent, "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json",
                ],
                body: body))
        guard response.isSuccess else { return false }
        struct Wipe: Decodable { var wipe: Bool }
        return (try? JSONDecoder().decode(Wipe.self, from: response.data).wipe) ?? false
    }

    public func confirmRemoteWipe() async throws {
        let connection = ocs.connection
        let body = Data(OCSClient.formEncode(["token": connection.appPassword]).utf8)
        _ = try await ocs.http.send(
            HTTPRequest(
                method: "POST", url: connection.url("index.php/core/wipe/success"),
                headers: ["User-Agent": connection.userAgent, "Content-Type": "application/x-www-form-urlencoded"], body: body))
    }
}
