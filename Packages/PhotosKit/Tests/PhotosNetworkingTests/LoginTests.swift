// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
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

    @Test func addressesTheServerNamesKeepHttpsWhenItWasTyped() throws {
        let typed = try #require(URL(string: "https://cloud.example.com:8443/nextcloud"))
        func kept(_ url: String) -> String { LoginService.keepingEncryption(URL(string: url)!, of: typed).absoluteString }
        // A proxy that terminates TLS without overwriteprotocol: the server names itself with http://.
        #expect(
            kept("http://cloud.example.com/nextcloud/index.php/login/v2/poll")
                == "https://cloud.example.com:8443/nextcloud/index.php/login/v2/poll")
        #expect(kept("http://cloud.example.com:80/login/v2/flow/abc") == "https://cloud.example.com:8443/login/v2/flow/abc")
        #expect(kept("http://login.example.com/flow") == "https://login.example.com/flow")
        #expect(kept("https://cloud.example.com/poll") == "https://cloud.example.com/poll")
        // Typed with http://: nothing to keep.
        let plain = try #require(URL(string: "http://cloud.example.com"))
        let unchanged = LoginService.keepingEncryption(URL(string: "http://cloud.example.com/poll")!, of: plain)
        #expect(unchanged.absoluteString == "http://cloud.example.com/poll")
    }

    @Test func theAccountStaysOnHttpsForTheTypedHost() throws {
        let typed = try #require(URL(string: "https://cloud.example.com"))
        let same = LoginService.securedServerURL(URL(string: "http://cloud.example.com")!, typed: typed)
        #expect(same.absoluteString == "https://cloud.example.com")
        #expect(
            LoginService.securedServerURL(URL(string: "http://CLOUD.example.com/nextcloud")!, typed: typed).absoluteString
                == "https://CLOUD.example.com/nextcloud")
        // Another host keeps what the server said; the login screen refuses it when it is plain http.
        let other = LoginService.securedServerURL(URL(string: "http://other.example.com")!, typed: typed)
        #expect(LoginService.isUnencrypted(other))
    }

    @Test func theFlowAndTheRevocationNeverUsePlainHttp() async throws {
        let host = "login-\(UUID().uuidString.prefix(8).lowercased()).test"
        LoginStub.responses.withLock {
            $0[host] = [
                "POST /index.php/login/v2": (
                    200,
                    #"{"poll":{"token":"t0k3n","endpoint":"http://\#(host)/index.php/login/v2/poll"},"login":"http://\#(host)/index.php/login/v2/flow/abc"}"#
                ),
                "DELETE /ocs/v2.php/core/apppassword": (200, #"{"ocs":{"meta":{"status":"ok","statuscode":200},"data":[]}}"#),
            ]
        }
        let configuration = HTTPClient.defaultConfiguration()
        configuration.protocolClasses = [LoginStub.self]
        let http = HTTPClient(trustStore: TrustStore(directory: nil), configuration: configuration)
        let service = LoginService(http: http, userAgent: "test")
        let typed = try #require(URL(string: "https://\(host)"))

        let flow = try await service.startFlow(serverURL: typed)
        #expect(flow.pollEndpoint.absoluteString == "https://\(host)/index.php/login/v2/poll")
        #expect(flow.loginURL.scheme == "https")

        // The app refused the server the login named: the granted password is revoked over the typed https address.
        let granted = LoginService.Credentials(serverURL: URL(string: "http://elsewhere.test")!, loginName: "alice", appPassword: "granted")
        await service.revoke(granted, at: typed)
        let requests = LoginStub.requests.withLock { $0.filter { $0.url?.host() == host } }
        #expect(requests.allSatisfy { $0.url?.scheme == "https" })
        let revocation = try #require(requests.first { $0.httpMethod == "DELETE" })
        #expect(revocation.url?.path() == "/ocs/v2.php/core/apppassword")
        #expect(revocation.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("alice:granted".utf8).base64EncodedString())
    }
}

/// Canned answers per host and request line, for the login requests.
final class LoginStub: URLProtocol, @unchecked Sendable {
    static let responses = Mutex<[String: [String: (Int, String)]]>([:])
    static let requests = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        Self.requests.withLock { $0.append(request) }
        let line = "\(request.httpMethod ?? "GET") \(url.path())"
        let (status, body) = Self.responses.withLock { $0[host]?[line] } ?? (404, "")
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
