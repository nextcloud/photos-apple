// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One `d:response` of a multistatus.
public struct DAVResource: Sendable {
    /// Percent-decoded href path, e.g. `/remote.php/dav/files/alice/Photos/a b.jpg`.
    public var href: String
    /// Raw href as sent by the server (percent-encoded).
    public var rawHref: String
    /// Properties from `200 OK` propstats.
    public var properties: [QName: XMLNode]
    /// Properties the server reported as `404 Not Found` (unsupported or unset).
    public var missing: Set<QName>
    /// Response-level status for responses without propstat.
    public var status: Int?

    public init(href: String, rawHref: String, properties: [QName: XMLNode], missing: Set<QName>, status: Int?) {
        self.href = href
        self.rawHref = rawHref
        self.properties = properties
        self.missing = missing
        self.status = status
    }

    public var isCollection: Bool { properties[DAVProp.resourceType]?.child(DAVProp.collection) != nil || href.hasSuffix("/") }

    public func node(_ name: QName) -> XMLNode? { properties[name] }

    public func string(_ name: QName) -> String? {
        guard let node = properties[name] else { return nil }
        let value = node.value
        return value.isEmpty ? nil : XMLEntities.decode(value)
    }

    public func int(_ name: QName) -> Int? { string(name).flatMap { Int($0) ?? Double($0).map { Int($0) } } }

    public func int64(_ name: QName) -> Int64? { string(name).flatMap { Int64($0) ?? Double($0).map { Int64($0) } } }

    public func double(_ name: QName) -> Double? { string(name).flatMap(Double.init) }

    public func bool(_ name: QName) -> Bool? {
        guard let value = string(name)?.lowercased() else { return nil }
        return value == "1" || value == "true"
    }

    /// RFC 1123 date (`getlastmodified`).
    public func httpDate(_ name: QName) -> Date? { string(name).flatMap(HTTPDate.parse) }

    /// Unix seconds (possibly fractional).
    public func unixDate(_ name: QName) -> Date? { double(name).map { Date(timeIntervalSince1970: $0) } }

    /// Last path segment of the href (decoded), ignoring a trailing slash.
    public var lastPathComponent: String {
        let trimmed = href.hasSuffix("/") ? String(href.dropLast()) : href
        return trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? trimmed
    }
}

public enum MultiStatus {
    public static func parse(_ data: Data) throws -> [DAVResource] {
        let root = try XMLTreeParser.parse(data)
        guard root.name == QName(XMLNamespace.dav, "multistatus") else {
            throw NetworkError.invalidResponse("expected multistatus, got \(root.name.name)")
        }
        return root.children(QName(XMLNamespace.dav, "response")).compactMap(resource(from:))
    }

    static func resource(from response: XMLNode) -> DAVResource? {
        guard let rawHref = response.child(QName(XMLNamespace.dav, "href"))?.value else { return nil }
        var properties: [QName: XMLNode] = [:]
        var missing: Set<QName> = []
        for propstat in response.children(QName(XMLNamespace.dav, "propstat")) {
            let status = propstat.child(QName(XMLNamespace.dav, "status")).map { statusCode($0.value) } ?? 200
            guard let prop = propstat.child(QName(XMLNamespace.dav, "prop")) else { continue }
            for child in prop.children {
                if (200..<300).contains(status) {
                    properties[child.name] = child
                } else {
                    missing.insert(child.name)
                }
            }
        }
        let status = response.child(QName(XMLNamespace.dav, "status")).map { statusCode($0.value) }
        let href = rawHref.removingPercentEncoding ?? rawHref
        return DAVResource(href: href, rawHref: rawHref, properties: properties, missing: missing, status: status)
    }

    /// `HTTP/1.1 404 Not Found` → 404.
    static func statusCode(_ line: String) -> Int {
        let parts = line.split(separator: " ")
        return parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    }
}

/// Some Photos props (JSON in XML) arrive HTML-entity encoded, e.g. `&quot;`.
public enum XMLEntities {
    public static func decode(_ string: String) -> String {
        guard string.contains("&") else { return string }
        return
            string
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

public enum HTTPDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
    private static let lock = NSLock()

    public static func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: string)
    }

    public static func format(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}
