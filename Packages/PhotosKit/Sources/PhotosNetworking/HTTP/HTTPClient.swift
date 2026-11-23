// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// Provides a client certificate identity for mTLS, per host.
public typealias ClientCredentialProvider = @Sendable (_ host: String) -> URLCredential?

/// The app's HTTP transport: one `URLSession` with the app's trust and client certificate handling.
public final class HTTPClient: Sendable {
    public let session: URLSession
    public let trustStore: TrustStore
    private let delegate: SessionDelegate

    public init(
        trustStore: TrustStore,
        clientCredentials: ClientCredentialProvider? = nil,
        configuration: URLSessionConfiguration = HTTPClient.defaultConfiguration()
    ) {
        self.trustStore = trustStore
        let delegate = SessionDelegate(trustStore: trustStore, clientCredentials: clientCredentials)
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// Sends a request; one with a `retry` policy is sent again after a transient failure.
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let retry = request.retry else { return try await sendOnce(request) }
        return try await retry.run { try await self.sendOnce(request) }
    }

    private func sendOnce(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request.urlRequest)
            return Self.makeResponse(response, data: data)
        } catch {
            throw mapError(error, url: request.url)
        }
    }

    /// Downloads to a file in the temporary directory, returning its location (the caller moves it).
    public func download(_ request: HTTPRequest) async throws -> (URL, HTTPResponse) {
        do {
            let (location, response) = try await session.download(for: request.urlRequest)
            let target = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: target)
            return (target, Self.makeResponse(response, data: Data()))
        } catch let error as NetworkError {
            throw error
        } catch {
            throw mapError(error, url: request.url)
        }
    }

    /// Uploads a file from disk; with a `retry` policy the whole file is sent again after a transient failure.
    public func upload(_ request: HTTPRequest, fromFile file: URL) async throws -> HTTPResponse {
        guard let retry = request.retry else { return try await uploadOnce(request, fromFile: file) }
        return try await retry.run { try await self.uploadOnce(request, fromFile: file) }
    }

    private func uploadOnce(_ request: HTTPRequest, fromFile file: URL) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.upload(for: request.urlRequest, fromFile: file)
            return Self.makeResponse(response, data: data)
        } catch {
            throw mapError(error, url: request.url)
        }
    }

    static func makeResponse(_ response: URLResponse, data: Data) -> HTTPResponse {
        guard let http = response as? HTTPURLResponse else { return HTTPResponse(status: 0, data: data, url: response.url) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, data: data, url: http.url)
    }

    func mapError(_ error: any Error, url: URL) -> NetworkError {
        delegate.networkError(for: error, url: url)
    }
}

final class SessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let trustStore: TrustStore
    let clientCredentials: ClientCredentialProvider?
    private let rejectedHosts = Mutex<Set<String>>([])

    init(trustStore: TrustStore, clientCredentials: ClientCredentialProvider?) {
        self.trustStore = trustStore
        self.clientCredentials = clientCredentials
    }

    func didRejectTrust(for host: String) -> Bool {
        rejectedHosts.withLock { $0.remove(host.lowercased()) != nil }
    }

    /// Maps a failure of a task of this delegate's session to a `NetworkError`.
    func networkError(for error: any Error, url: URL) -> NetworkError {
        if let error = error as? NetworkError { return error }
        let host = url.host() ?? ""
        guard let urlError = error as? URLError else {
            return .transport(code: (error as NSError).code, message: error.localizedDescription)
        }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut: return .timedOut
        case .cancelled:
            if let certificate = trustStore.lastFailure(for: host), didRejectTrust(for: host) {
                return .untrustedCertificate(host: host, certificate: certificate)
            }
            return .cancelled
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .secureConnectionFailed:
            return .untrustedCertificate(host: host, certificate: trustStore.lastFailure(for: host))
        case .clientCertificateRequired, .clientCertificateRejected:
            return .clientCertificateRequired(host: host)
        default:
            return .transport(code: urlError.errorCode, message: urlError.localizedDescription)
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge)
    }

    func handle(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else { return (.performDefaultHandling, nil) }
            if trustStore.evaluate(trust, host: space.host) {
                return (.useCredential, URLCredential(trust: trust))
            }
            _ = rejectedHosts.withLock { $0.insert(space.host.lowercased()) }
            return (.cancelAuthenticationChallenge, nil)
        case NSURLAuthenticationMethodClientCertificate:
            if let credential = clientCredentials?(space.host) { return (.useCredential, credential) }
            return (.performDefaultHandling, nil)
        default:
            // Basic auth is always sent pre-emptively; never answer a 401 challenge with stored credentials.
            return (.performDefaultHandling, nil)
        }
    }
}
