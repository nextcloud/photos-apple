// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// An XML qualified name (namespace URI + local name).
public struct QName: Hashable, Sendable, CustomStringConvertible {
    public var namespace: String
    public var name: String

    public init(_ namespace: String, _ name: String) {
        self.namespace = namespace
        self.name = name
    }

    public var description: String { "{\(namespace)}\(name)" }
}

public enum XMLNamespace {
    public static let dav = "DAV:"
    public static let oc = "http://owncloud.org/ns"
    public static let nc = "http://nextcloud.org/ns"
    public static let ocs = "http://open-collaboration-services.org/ns"
    public static let searchDAV = "https://github.com/icewind1991/SearchDAV/ns"

    /// Prefixes declared on every request body.
    static let prefixes: [(prefix: String, uri: String)] = [
        ("d", dav), ("oc", oc), ("nc", nc), ("ocs", ocs), ("ns", searchDAV),
    ]

    static func prefix(for uri: String) -> String? { prefixes.first { $0.uri == uri }?.prefix }

    static var declarations: String {
        prefixes.map { "xmlns:\($0.prefix)=\"\($0.uri)\"" }.joined(separator: " ")
    }
}

/// A parsed XML element.
public final class XMLNode: Sendable, CustomStringConvertible {
    public let name: QName
    public let attributes: [String: String]
    public let text: String
    public let children: [XMLNode]

    init(name: QName, attributes: [String: String], text: String, children: [XMLNode]) {
        self.name = name
        self.attributes = attributes
        self.text = text
        self.children = children
    }

    /// Trimmed text content.
    public var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func child(_ name: QName) -> XMLNode? { children.first { $0.name == name } }

    /// First child with this local name, ignoring the namespace (Photos uses un-namespaced children in some props).
    public func child(named localName: String) -> XMLNode? { children.first { $0.name.name == localName } }

    public func children(_ name: QName) -> [XMLNode] { children.filter { $0.name == name } }

    public func descendants(_ name: QName) -> [XMLNode] {
        var result: [XMLNode] = []
        for child in children {
            if child.name == name { result.append(child) }
            result.append(contentsOf: child.descendants(name))
        }
        return result
    }

    public var description: String {
        children.isEmpty ? "<\(name.name)>\(value)</\(name.name)>" : "<\(name.name)>\(children.map(\.description).joined())</\(name.name)>"
    }
}

/// Builds an `XMLNode` tree with namespace processing.
public final class XMLTreeParser: NSObject, XMLParserDelegate {
    private final class Builder {
        let name: QName
        let attributes: [String: String]
        var text = ""
        var children: [XMLNode] = []
        init(name: QName, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }
    }

    private var stack: [Builder] = []
    private var root: XMLNode?
    private var parseError: (any Error)?

    public static func parse(_ data: Data) throws -> XMLNode {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let delegate = XMLTreeParser()
        parser.delegate = delegate
        if !parser.parse() || delegate.root == nil {
            let reason = delegate.parseError?.localizedDescription ?? parser.parserError?.localizedDescription ?? "no root element"
            throw NetworkError.invalidResponse("XML: \(reason)")
        }
        return delegate.root!
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        stack.append(Builder(name: QName(namespaceURI ?? "", elementName), attributes: attributeDict))
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { stack.last?.text += string }
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let builder = stack.popLast() else { return }
        let node = XMLNode(name: builder.name, attributes: builder.attributes, text: builder.text, children: builder.children)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        self.parseError = parseError
    }
}

public enum XMLEscape {
    /// Escapes text for use in XML element content and attribute values.
    public static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for character in string {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }
}

extension QName {
    /// `prefix:name` using the standard prefixes declared on request bodies.
    var prefixed: String {
        if let prefix = XMLNamespace.prefix(for: namespace) { return "\(prefix):\(name)" }
        return name
    }

    /// Element string `<p:name/>`.
    var emptyElement: String { "<\(prefixed)/>" }
}
