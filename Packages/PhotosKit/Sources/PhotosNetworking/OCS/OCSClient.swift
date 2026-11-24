// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// OCS API calls (`/ocs/v2.php/...`) returning `ocs.data`.
public struct OCSClient: Sendable {
    public let http: HTTPClient
    public let connection: ServerConnection
    public var onUnauthorized: (@Sendable () -> Void)?

    public init(http: HTTPClient, connection: ServerConnection, onUnauthorized: (@Sendable () -> Void)? = nil) {
        self.http = http
        self.connection = connection
        self.onUnauthorized = onUnauthorized
    }

    struct Envelope<T: Decodable>: Decodable {
        struct OCS: Decodable {
            struct Meta: Decodable {
                var status: String?
                var statuscode: Int?
                var message: String?
            }
            var meta: Meta
            var data: T
        }
        var ocs: OCS
    }

    struct MetaOnly: Decodable {
        struct OCS: Decodable { var meta: Envelope<JSONValue>.OCS.Meta }
        var ocs: OCS
    }

    /// Sends an OCS request and decodes `ocs.data`.
    public func request<T: Decodable>(
        _ method: String = "GET",
        _ path: String,
        query: [URLQueryItem] = [],
        json: (any Encodable & Sendable)? = nil,
        form: [String: String]? = nil,
        as type: T.Type = T.self,
        serverMessages: Bool = false
    ) async throws -> T {
        let response = try await raw(method, path, query: query, json: json, form: form, serverMessages: serverMessages)
        do {
            return try JSONDecoder().decode(Envelope<T>.self, from: response.data).ocs.data
        } catch {
            throw NetworkError.invalidResponse("OCS \(path): \(error)")
        }
    }

    /// Sends an OCS request and returns the raw response after status checks.
    ///
    /// - Parameter serverMessages: a 404 that carries the server's own message is thrown as `NetworkError.ocs` with that
    ///   message instead of `.notFound` (the sharing API answers 404 for "no such user", not only for a missing route).
    public func raw(
        _ method: String = "GET",
        _ path: String,
        query: [URLQueryItem] = [],
        json: (any Encodable & Sendable)? = nil,
        form: [String: String]? = nil,
        serverMessages: Bool = false
    ) async throws -> HTTPResponse {
        var items = query
        if !items.contains(where: { $0.name == "format" }) { items.append(URLQueryItem(name: "format", value: "json")) }
        var headers = connection.standardHeaders
        headers["Accept"] = "application/json"
        var body: Data?
        if let json {
            headers["Content-Type"] = "application/json"
            body = try JSONEncoder().encode(json)
        } else if let form {
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            body = Data(OCSClient.formEncode(form).utf8)
        }
        let request = HTTPRequest(method: method, url: connection.url(path, query: items), headers: headers, body: body)
        let response = try await http.send(request)
        if response.status == 401 {
            onUnauthorized?()
            throw NetworkError.unauthorized
        }
        if !response.isSuccess {
            let meta = try? JSONDecoder().decode(MetaOnly.self, from: response.data).ocs.meta
            if serverMessages, response.status == 404, let message = meta?.message, !message.isEmpty, let code = meta?.statuscode {
                throw NetworkError.ocs(statusCode: code, message: message)
            }
            if response.status == 404 { throw NetworkError.notFound }
            if response.status == 503 { throw NetworkError.maintenance }
            if let code = meta?.statuscode { throw NetworkError.ocs(statusCode: code, message: meta?.message) }
            throw NetworkError.from(status: response.status, data: response.data) ?? .http(status: response.status, message: nil)
        }
        return response
    }

    public static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map {
                "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
            }
            .joined(separator: "&")
    }
}

/// Arbitrary JSON, `Sendable`.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    /// Path lookup, e.g. `value["capabilities", "files", "undelete"]`.
    public subscript(path: String...) -> JSONValue? {
        var current: JSONValue? = self
        for key in path { current = current?[key] }
        return current
    }

    public var string: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): ["true", "1", "yes"].contains(value.lowercased())
        default: nil
        }
    }

    public var int: Int? {
        switch self {
        case .number(let value): Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isPresent: Bool {
        if case .null = self { return false }
        return true
    }
}
