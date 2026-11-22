// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Request bodies for WebDAV methods. All values are XML-escaped.
public enum DAVBody {
    static let header = #"<?xml version="1.0" encoding="UTF-8"?>"#

    public static func propfind(_ properties: [QName]) -> Data {
        let props = properties.map(\.emptyElement).joined()
        return Data("\(header)<d:propfind \(XMLNamespace.declarations)><d:prop>\(props)</d:prop></d:propfind>".utf8)
    }

    public enum PropValue: Sendable, Equatable {
        /// Text content, escaped.
        case text(String)
        /// Pre-built XML fragment using the standard prefixes (callers must escape values inside).
        case xml(String)
    }

    public static func proppatch(set: [(QName, PropValue)] = [], remove: [QName] = []) -> Data {
        var body = "\(header)<d:propertyupdate \(XMLNamespace.declarations)>"
        if !set.isEmpty {
            body += "<d:set><d:prop>"
            for (name, value) in set {
                switch value {
                case .text(let text): body += "<\(name.prefixed)>\(XMLEscape.escape(text))</\(name.prefixed)>"
                case .xml(let fragment): body += "<\(name.prefixed)>\(fragment)</\(name.prefixed)>"
                }
            }
            body += "</d:prop></d:set>"
        }
        if !remove.isEmpty {
            body += "<d:remove><d:prop>\(remove.map(\.emptyElement).joined())</d:prop></d:remove>"
        }
        body += "</d:propertyupdate>"
        return Data(body.utf8)
    }

    /// `oc:filter-files` REPORT (favorites / system tag).
    public static func filterFiles(properties: [QName], systemTagIds: [Int] = [], favorite: Bool = false) -> Data {
        var rules = ""
        if favorite { rules += "<oc:favorite>1</oc:favorite>" }
        for id in systemTagIds { rules += "<oc:systemtag>\(id)</oc:systemtag>" }
        let props = properties.map(\.emptyElement).joined()
        return Data(
            "\(header)<oc:filter-files \(XMLNamespace.declarations)><d:prop>\(props)</d:prop><oc:filter-rules>\(rules)</oc:filter-rules></oc:filter-files>"
                .utf8)
    }

    /// `oc:filter-comments` REPORT.
    public static func filterComments(limit: Int, offset: Int) -> Data {
        Data(
            "\(header)<oc:filter-comments \(XMLNamespace.declarations)><oc:limit>\(limit)</oc:limit><oc:offset>\(offset)</oc:offset></oc:filter-comments>"
                .utf8)
    }
}

/// A WebDAV SEARCH (`d:basicsearch`) request (Nextcloud's SearchDAV).
public struct DAVSearch: Sendable, Equatable {
    public indirect enum Condition: Sendable, Equatable {
        case and([Condition])
        case or([Condition])
        case not(Condition)
        case eq(QName, String)
        case gt(QName, String)
        case gte(QName, String)
        case lt(QName, String)
        case lte(QName, String)
        case like(QName, String)
        case isCollection

        var xml: String {
            switch self {
            case .and(let conditions):
                conditions.count == 1 ? conditions[0].xml : "<d:and>\(conditions.map(\.xml).joined())</d:and>"
            case .or(let conditions):
                conditions.count == 1 ? conditions[0].xml : "<d:or>\(conditions.map(\.xml).joined())</d:or>"
            case .not(let condition): "<d:not>\(condition.xml)</d:not>"
            case .eq(let name, let value): Self.compare("eq", name, value)
            case .gt(let name, let value): Self.compare("gt", name, value)
            case .gte(let name, let value): Self.compare("gte", name, value)
            case .lt(let name, let value): Self.compare("lt", name, value)
            case .lte(let name, let value): Self.compare("lte", name, value)
            case .like(let name, let value): Self.compare("like", name, value)
            case .isCollection: "<d:is-collection/>"
            }
        }

        static func compare(_ op: String, _ name: QName, _ value: String) -> String {
            "<d:\(op)><d:prop>\(name.emptyElement)</d:prop><d:literal>\(XMLEscape.escape(value))</d:literal></d:\(op)>"
        }

        /// Number of operators, for the server's 100-operator limit.
        public var operatorCount: Int {
            switch self {
            case .and(let c), .or(let c): 1 + c.reduce(0) { $0 + $1.operatorCount }
            case .not(let c): 1 + c.operatorCount
            default: 1
            }
        }

        /// Escapes `%`, `_` and `\` for use inside a LIKE literal.
        public static func likeEscaped(_ term: String) -> String {
            term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
        }
    }

    public struct Scope: Sendable, Equatable {
        /// Href relative to the DAV root, e.g. `/files/alice/Photos`.
        public var href: String
        public var depth: String

        public init(href: String, depth: String = "infinity") {
            self.href = href
            self.depth = depth
        }
    }

    public struct Order: Sendable, Equatable {
        public var property: QName
        public var descending: Bool

        public init(_ property: QName, descending: Bool = true) {
            self.property = property
            self.descending = descending
        }
    }

    public var select: [QName]
    public var scopes: [Scope]
    public var condition: Condition?
    public var orderBy: [Order]
    public var limit: Int?
    public var offset: Int?

    public init(
        select: [QName],
        scopes: [Scope],
        condition: Condition? = nil,
        orderBy: [Order] = [],
        limit: Int? = nil,
        offset: Int? = nil
    ) {
        self.select = select
        self.scopes = scopes
        self.condition = condition
        self.orderBy = orderBy
        self.limit = limit
        self.offset = offset
    }

    public var body: Data {
        var xml = "\(DAVBody.header)<d:searchrequest \(XMLNamespace.declarations)><d:basicsearch>"
        xml += "<d:select><d:prop>\(select.map(\.emptyElement).joined())</d:prop></d:select>"
        xml += "<d:from>"
        for scope in scopes {
            xml += "<d:scope><d:href>\(XMLEscape.escape(scope.href))</d:href><d:depth>\(scope.depth)</d:depth></d:scope>"
        }
        xml += "</d:from>"
        xml += "<d:where>\(condition?.xml ?? "")</d:where>"
        if !orderBy.isEmpty {
            xml += "<d:orderby>"
            for order in orderBy {
                xml +=
                    "<d:order><d:prop>\(order.property.emptyElement)</d:prop>\(order.descending ? "<d:descending/>" : "<d:ascending/>")</d:order>"
            }
            xml += "</d:orderby>"
        }
        if limit != nil || offset != nil {
            xml += "<d:limit>"
            if let limit { xml += "<d:nresults>\(limit)</d:nresults>" }
            if let offset { xml += "<ns:firstresult>\(offset)</ns:firstresult>" }
            xml += "</d:limit>"
        }
        xml += "</d:basicsearch></d:searchrequest>"
        return Data(xml.utf8)
    }
}
