// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Network
import Testing

@testable import PhotosCore
@testable import PhotosModel
@testable import PhotosNetworking

/// Setting up Apple TV from the iPhone (SPEC §22.2): the messages, the checks the phone makes, and the whole exchange over
/// a real local connection. DeviceDiscoveryUI (the picker and the system's encrypted connection) needs two devices; here
/// the same protocol runs over TCP on the loopback interface.
@Suite struct TVSetupTests {
    let account = Account(
        serverURL: URL(string: "https://cloud.example.com/nextcloud")!, userId: "alice", loginName: "alice@example.com",
        displayName: "Alice")

    @Test func messagesRoundTripThroughFrames() throws {
        let messages: [TVSetup.Message] = [
            .hello(version: 1, device: "Living Room"),
            .account(serverURL: account.serverURL, loginName: "alice@example.com"),
            .login(url: URL(string: "https://cloud.example.com/nextcloud/index.php/login/v2/flow/abc")!),
            .done(name: "Alice"), .failed(reason: "No"), .cancel,
        ]
        let wire = try messages.map(TVSetup.frame).reduce(Data(), +)
        // Delivered in arbitrary pieces, as a stream does.
        var decoder = TVSetup.FrameDecoder()
        var received: [TVSetup.Message] = []
        var index = wire.startIndex
        var size = 1
        while index < wire.endIndex {
            let end = min(index + size, wire.endIndex)
            received += try decoder.append(wire[index..<end])
            index = end
            size = size % 7 + 3
        }
        #expect(received == messages)
    }

    @Test func aFrameThatClaimsToBeHugeIsRefused() {
        var decoder = TVSetup.FrameDecoder()
        var length = UInt32(10_000_000).bigEndian
        let header = Data(bytes: &length, count: 4)
        #expect(throws: TVSetup.FrameDecoder.Failure.tooLarge(10_000_000)) { try decoder.append(header) }
    }

    @Test func thePhoneOpensOnlyTheLoginPageOfTheChosenServer() throws {
        func page(_ text: String) throws -> URL { try #require(URL(string: text)) }
        let server = account.serverURL
        #expect(TVSetup.isLoginPage(try page("https://cloud.example.com/nextcloud/index.php/login/v2/flow/T0k3n"), of: server))
        #expect(TVSetup.isLoginPage(try page("https://CLOUD.example.com:443/nextcloud/login/v2/flow/T0k3n"), of: server))
        // Another server, another path, another port, plain http for an https server, user info, no token, more after it.
        #expect(!TVSetup.isLoginPage(try page("https://evil.example.com/nextcloud/index.php/login/v2/flow/T0k3n"), of: server))
        #expect(!TVSetup.isLoginPage(try page("https://cloud.example.com/other/index.php/login/v2/flow/T0k3n"), of: server))
        #expect(!TVSetup.isLoginPage(try page("https://cloud.example.com:8443/nextcloud/index.php/login/v2/flow/T0k3n"), of: server))
        #expect(!TVSetup.isLoginPage(try page("http://cloud.example.com/nextcloud/index.php/login/v2/flow/T0k3n"), of: server))
        #expect(!TVSetup.isLoginPage(try page("https://x:y@cloud.example.com/nextcloud/index.php/login/v2/flow/T0k3n"), of: server))
        #expect(!TVSetup.isLoginPage(try page("https://cloud.example.com/nextcloud/index.php/login/v2/flow/"), of: server))
        #expect(!TVSetup.isLoginPage(try page("https://cloud.example.com/nextcloud/index.php/login/v2/grant"), of: server))
        #expect(!TVSetup.isLoginPage(try page("https://cloud.example.com/nextcloud/index.php/login/v2/flow/a/b"), of: server))
        #expect(!TVSetup.isLoginPage(try page("javascript:alert(1)"), of: server))
        // An http server (home network) may stay http, and may be upgraded.
        let home = try page("http://nas.local:8080")
        #expect(TVSetup.isLoginPage(try page("http://nas.local:8080/index.php/login/v2/flow/abc"), of: home))
        #expect(!TVSetup.isLoginPage(try page("http://nas.local:8081/index.php/login/v2/flow/abc"), of: home))
    }

    @Test func theLoginPageProposesTheUsersLoginName() throws {
        let url = try #require(URL(string: "https://cloud.example.com/index.php/login/v2/flow/abc?user=mallory"))
        let page = TVSetup.loginPage(url, user: "alice@example.com")
        let items = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items == [URLQueryItem(name: "user", value: "alice@example.com")])
        #expect(TVSetup.loginPage(url, user: "") == url)
    }

    @Test func whatTheTVSaysMovesThePhoneOn() throws {
        let page = try #require(URL(string: "https://cloud.example.com/nextcloud/index.php/login/v2/flow/abc"))
        #expect(
            TVSetupPhoneFlow.step(after: .login(url: page), account: account)
                == .grantInBrowser(TVSetup.loginPage(page, user: "alice@example.com")))
        let other = try #require(URL(string: "https://evil.example.com/index.php/login/v2/flow/abc"))
        #expect(TVSetupPhoneFlow.step(after: .login(url: other), account: account) == .failed(TVSetupWording.wrongServer))
        #expect(TVSetupPhoneFlow.step(after: .done(name: "Alice"), account: account) == .done(name: "Alice"))
        #expect(TVSetupPhoneFlow.step(after: .failed(reason: "x"), account: account) == .failed("x"))
        #expect(TVSetupPhoneFlow.step(after: .cancel, account: account) == .failed(TVSetupWording.cancelledOnTV))
        #expect(TVSetupPhoneFlow.step(after: .hello(version: 1, device: "TV"), account: account) == nil)
    }

    /// TV and phone over a real connection: hello, the account, the login page, done.
    @MainActor @Test(.timeLimit(.minutes(1))) func theTVAndThePhoneTalkOverTheNetwork() async throws {
        let pair = try await LoopbackPair.make()
        defer { pair.close() }
        let tv = TVSetupTVFlow(channel: pair.tv)
        let begun = Task { try await tv.begin(device: "Living Room") }
        // The phone: the listener's part (hello), then the sheet's (`TVSetupPhoneFlow`).
        pair.phone.start()
        var iterator = pair.phone.messages.makeAsyncIterator()
        #expect(try await pair.phone.next(in: &iterator) == .hello(version: TVSetup.version, device: "Living Room"))
        let flow = TVSetupPhoneFlow(request: TVSetupRequest(device: "Living Room", channel: pair.phone))
        flow.choose(account)
        let chosen = try await begun.value
        #expect(chosen.serverURL == account.serverURL)
        #expect(chosen.loginName == "alice@example.com")
        let page = try #require(URL(string: "https://cloud.example.com/nextcloud/index.php/login/v2/flow/abc"))
        await tv.send(.login(url: page))
        try await waitUntil { flow.step == .grantInBrowser(TVSetup.loginPage(page, user: "alice@example.com")) }
        await tv.send(.done(name: "Alice"))
        try await waitUntil { flow.step == .done(name: "Alice") }
    }

    /// The phone refuses a login page of another server and tells the TV.
    @MainActor @Test(.timeLimit(.minutes(1))) func aLoginPageOfAnotherServerIsRefused() async throws {
        let pair = try await LoopbackPair.make()
        defer { pair.close() }
        let tv = TVSetupTVFlow(channel: pair.tv)
        let begun = Task { try await tv.begin(device: "TV") }
        pair.phone.start()
        var iterator = pair.phone.messages.makeAsyncIterator()
        _ = try await pair.phone.next(in: &iterator)
        let flow = TVSetupPhoneFlow(request: TVSetupRequest(device: "TV", channel: pair.phone))
        flow.choose(account)
        _ = try await begun.value
        let gaveUp = Task { await tv.phoneGaveUp() }
        await tv.send(.login(url: try #require(URL(string: "https://evil.example.com/index.php/login/v2/flow/abc"))))
        try await waitUntil { flow.step == .failed(TVSetupWording.wrongServer) }
        #expect(await gaveUp.value == .phone(TVSetupWording.wrongServer))
    }

    /// Cancel on the phone sends the TV back.
    @MainActor @Test(.timeLimit(.minutes(1))) func cancelOnThePhoneReachesTheTV() async throws {
        let pair = try await LoopbackPair.make()
        defer { pair.close() }
        let tv = TVSetupTVFlow(channel: pair.tv)
        let begun = Task { try await tv.begin(device: "TV") }
        pair.phone.start()
        var iterator = pair.phone.messages.makeAsyncIterator()
        _ = try await pair.phone.next(in: &iterator)
        let flow = TVSetupPhoneFlow(request: TVSetupRequest(device: "TV", channel: pair.phone))
        flow.choose(account)
        _ = try await begun.value
        let gaveUp = Task { await tv.phoneGaveUp() }
        try await Task.sleep(for: .milliseconds(100))
        flow.cancel()
        let reason = await gaveUp.value
        #expect(reason == .cancelled || reason == .connectionLost)
        #expect(flow.step == .failed(TVSetupWording.cancelled))
    }
}

/// The whole set-up against a test server: the TV starts Login Flow v2, the phone gets its page, "the browser" grants
/// access (here: the test with the server's password, as the user would log in on the page), and the TV receives its own
/// app password, which the test revokes. Needs PHOTOS_IT_SERVER and the account's real password in PHOTOS_IT_PASSWORD
/// (an app password cannot grant a flow: the server answers 403).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct TVSetupIntegrationTests {
    @MainActor @Test(.timeLimit(.minutes(2))) func theTVGetsItsOwnAppPasswordThroughThePhone() async throws {
        let env = ProcessInfo.processInfo.environment
        let server = try #require(URL(string: env["PHOTOS_IT_SERVER"] ?? ""))
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let password = try #require(env["PHOTOS_IT_PASSWORD"])
        let phoneAccount = Account(serverURL: server, userId: user, loginName: user, displayName: user)
        let http = HTTPClient(trustStore: TrustStore(directory: nil))
        let login = LoginService(http: http, userAgent: "Mozilla/5.0 (tvOS) Nextcloud-Photos/tests r12-continuity")

        let pair = try await LoopbackPair.make()
        defer { pair.close() }
        let tv = TVSetupTVFlow(channel: pair.tv)
        // The TV: waits for the account, starts the flow on its server, sends its page, polls, says done.
        let tvSide = Task { () -> LoginService.Credentials in
            let chosen = try await tv.begin(device: "r12-continuity TV")
            let flow = try await login.startFlow(serverURL: chosen.serverURL)
            await tv.send(.login(url: flow.loginURL))
            let credentials = try await login.waitForGrant(flow)
            await tv.send(.done(name: credentials.loginName))
            return credentials
        }
        // The phone.
        pair.phone.start()
        var iterator = pair.phone.messages.makeAsyncIterator()
        _ = try await pair.phone.next(in: &iterator)
        let flow = TVSetupPhoneFlow(request: TVSetupRequest(device: "r12-continuity TV", channel: pair.phone))
        flow.choose(phoneAccount)
        try await waitUntil(seconds: 30) { if case .grantInBrowser = flow.step { true } else { false } }
        guard case .grantInBrowser(let page) = flow.step else { return }
        let items = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "user", value: user)))
        try await BrowserGrant.grant(page: page, user: user, password: password)
        let credentials = try await tvSide.value
        try await waitUntil(seconds: 10) { flow.step == .done(name: user) }
        // The TV's own app password: it works, and it is not the phone's.
        #expect(credentials.appPassword != password)
        #expect(credentials.appPassword.count >= 32)
        let profile = try await AccountAPI(
            ocs: OCSClient(
                http: http,
                connection: ServerConnection(
                    serverURL: credentials.serverURL, userId: user, loginName: credentials.loginName, appPassword: credentials.appPassword,
                    userAgent: "tests"))
        ).profile()
        #expect(profile.id == user)
        await login.revoke(credentials, at: server)
    }
}

/// Two ends of a TCP connection on the loopback interface, as `TVSetupChannel`s.
struct LoopbackPair {
    let tv: TVSetupChannel
    let phone: TVSetupChannel
    let listener: NWListener

    static func make() async throws -> LoopbackPair {
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { connection in accepted.continuation.yield(connection) }
        let ready = AsyncStream<NWEndpoint.Port?>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.yield(listener.port) }
            if case .failed = state { ready.continuation.yield(nil) }
        }
        listener.start(queue: DispatchQueue(label: "loopback-listener"))
        var readiness = ready.stream.makeAsyncIterator()
        guard let port = await readiness.next() ?? nil else { throw TVSetupChannel.Failure.closed }
        let tv = TVSetupChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        var connections = accepted.stream.makeAsyncIterator()
        // The TV's side starts first (it connects); the phone's connection exists once the listener accepted it.
        let connecting = Task { tv.start() }
        await connecting.value
        guard let connection = await connections.next() else { throw TVSetupChannel.Failure.closed }
        return LoopbackPair(tv: tv, phone: TVSetupChannel(connection), listener: listener)
    }

    func close() {
        tv.close()
        phone.close()
        listener.cancel()
    }
}

@MainActor
func waitUntil(seconds: Double = 5, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("condition not met within \(seconds) s")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// What the user's browser does on the server's login page: logs in (here with Basic authentication and the password) and
/// presses "Grant access".
enum BrowserGrant {
    final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }

    struct Failure: Error {
        var step: String
    }

    static func grant(page: URL, user: String, password: String) async throws {
        let session = URLSession(configuration: .ephemeral)
        let authorization = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url)
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse else { throw Failure(step: "response") }
            return (data, http)
        }
        // A browser that is logged in to the server already (a session), as the phone's browser often is.
        let text = page.absoluteString
        if let range = text.range(of: "/index.php/login/v2/") ?? text.range(of: "/login/v2/"),
            let login = URL(string: String(text[..<range.lowerBound]) + "/index.php/login")
        {
            _ = try await get(login)
        }
        // The flow's page → its landing page → the grant page.
        var url = page
        var html = Data()
        for _ in 0..<4 {
            let (data, response) = try await get(url)
            if let location = response.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url) {
                url = next.absoluteURL
                continue
            }
            html = data
            break
        }
        let body = String(decoding: html, as: UTF8.self)
        guard let state = Self.value(after: "initial-state-core-loginFlowGrant\" value=\"", in: body),
            let json = Data(base64Encoded: state),
            let grant = try JSONSerialization.jsonObject(with: json) as? [String: Any], let stateToken = grant["stateToken"] as? String,
            let action = (grant["actionUrl"] as? String).flatMap(URL.init(string:)),
            let requestToken = Self.value(after: "data-requesttoken=\"", in: body)
        else { throw Failure(step: "grant page \(url.absoluteString)") }
        var request = URLRequest(url: action)
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(requestToken, forHTTPHeaderField: "requesttoken")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "stateToken", value: stateToken)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (_, response) = try await session.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else { throw Failure(step: "grant") }
    }

    static func value(after marker: String, in text: String) -> String? {
        guard let start = text.range(of: marker)?.upperBound, let end = text[start...].firstIndex(of: "\"") else { return nil }
        return String(text[start..<end])
    }
}
