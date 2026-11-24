// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    /// Set when the request may be sent again after a transient failure (it is then repeated by `HTTPClient`).
    public var retry: RetryPolicy?
    /// False keeps the request off cellular connections and personal hotspots.
    public var allowsExpensiveNetwork = true
    /// False keeps the request off connections in Low Data Mode.
    public var allowsConstrainedNetwork = true

    public init(
        method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 60,
        retry: RetryPolicy? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.retry = retry
    }

    var urlRequest: URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        request.allowsExpensiveNetworkAccess = allowsExpensiveNetwork
        request.allowsConstrainedNetworkAccess = allowsConstrainedNetwork
        return request
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    /// Header names lower-cased.
    public var headers: [String: String]
    public var data: Data
    public var url: URL?

    public init(status: Int, headers: [String: String] = [:], data: Data = Data(), url: URL? = nil) {
        self.status = status
        self.headers = headers
        self.data = data
        self.url = url
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public var isSuccess: Bool { (200..<300).contains(status) }

    public var text: String { String(data: data, encoding: .utf8) ?? "" }
}

public enum NetworkError: Error, Sendable, Equatable, LocalizedError {
    case transport(code: Int, message: String)
    case offline
    case timedOut
    case cancelled
    case untrustedCertificate(host: String, certificate: Data?)
    case clientCertificateRequired(host: String)
    case unauthorized
    case forbidden(message: String?)
    case notFound
    case conflict
    case preconditionFailed
    case locked
    case insufficientStorage
    case maintenance
    case rateLimited
    case http(status: Int, message: String?)
    case ocs(statusCode: Int, message: String?)
    case invalidResponse(String)
    case unsupportedServer(String)

    public var errorDescription: String? {
        switch self {
        case .transport(_, let message): message
        case .offline: String(localized: "You are offline.", bundle: .module)
        case .timedOut: String(localized: "The server did not respond in time.", bundle: .module)
        case .cancelled: String(localized: "Cancelled.", bundle: .module)
        case .untrustedCertificate(let host, _):
            String(localized: "The certificate of \(host) is not trusted.", bundle: .module)
        case .clientCertificateRequired(let host):
            String(localized: "\(host) requires a client certificate.", bundle: .module)
        case .unauthorized: String(localized: "Your login is no longer valid. Please sign in again.", bundle: .module)
        case .forbidden(let message): message ?? String(localized: "You don't have permission to do this.", bundle: .module)
        case .notFound: String(localized: "The item no longer exists on the server.", bundle: .module)
        case .conflict: String(localized: "The item already exists or its folder is missing.", bundle: .module)
        case .preconditionFailed: String(localized: "The server rejected the request (precondition failed).", bundle: .module)
        case .locked: String(localized: "The file is locked.", bundle: .module)
        case .insufficientStorage: String(localized: "There is not enough space on the server.", bundle: .module)
        case .maintenance: String(localized: "The server is in maintenance mode.", bundle: .module)
        case .rateLimited: String(localized: "Too many requests. Please try again later.", bundle: .module)
        case .http(let status, let message):
            message.map { "\($0) (\(status))" } ?? String(localized: "The server returned an error (\(status)).", bundle: .module)
        case .ocs(let code, let message):
            message.map { "\($0) (\(code))" } ?? String(localized: "The server returned an error (\(code)).", bundle: .module)
        case .invalidResponse(let detail): String(localized: "The server sent an unexpected response: \(detail)", bundle: .module)
        case .unsupportedServer(let detail): detail
        }
    }

    /// Errors worth retrying later (offline, timeouts, 5xx, a file that is locked right now).
    public var isTransient: Bool {
        switch self {
        case .offline, .timedOut, .transport, .maintenance, .rateLimited, .locked: true
        case .http(let status, _): status >= 500
        default: false
        }
    }

    static func from(status: Int, data: Data) -> NetworkError? {
        let message = Self.serverMessage(in: data)
        switch status {
        case 200..<400: return nil
        case 401: return .unauthorized
        case 403: return .forbidden(message: message)
        case 404: return .notFound
        case 405, 409: return .conflict
        case 412: return .preconditionFailed
        case 423: return .locked
        case 429: return .rateLimited
        case 503: return .maintenance
        case 507: return .insufficientStorage
        default: return .http(status: status, message: message)
        }
    }

    /// Extracts `<s:message>` from a Sabre error body.
    static func serverMessage(in data: Data) -> String? {
        guard let text = String(data: data.prefix(4096), encoding: .utf8),
            let start = text.range(of: "<s:message>"),
            let end = text.range(of: "</s:message>", range: start.upperBound..<text.endIndex)
        else { return nil }
        let message = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }
}
