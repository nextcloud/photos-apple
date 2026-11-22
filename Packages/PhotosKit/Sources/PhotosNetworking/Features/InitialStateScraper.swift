// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Reads the Photos web app's initial state from `/index.php/apps/photos/` (SPEC §5.3 step 2.2).
///
/// The page embeds `<input type="hidden" id="initial-state-photos-<key>" value="<base64 JSON>">`.
/// This is a fallback for servers without the companion config API; it only reads those inputs.
public enum InitialStateScraper {
    /// Returns `key → decoded JSON` for every `initial-state-photos-*` input in the page.
    public static func parse(html: String) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        let marker = "initial-state-photos-"
        var searchRange = html.startIndex..<html.endIndex
        while let idRange = html.range(of: marker, range: searchRange) {
            searchRange = idRange.upperBound..<html.endIndex
            guard let keyEnd = html[idRange.upperBound...].firstIndex(where: { $0 == "\"" || $0 == "'" }) else { break }
            let key = String(html[idRange.upperBound..<keyEnd])
            // Find the enclosing tag and its value attribute.
            guard let tagStart = html[..<idRange.lowerBound].lastIndex(of: "<"),
                let tagEnd = html[idRange.upperBound...].firstIndex(of: ">")
            else { continue }
            let tag = html[tagStart..<tagEnd]
            guard let valueRange = tag.range(of: "value=\"") ?? tag.range(of: "value='") else { continue }
            let quote = tag[tag.index(before: valueRange.upperBound)]
            guard let valueEnd = tag[valueRange.upperBound...].firstIndex(of: quote) else { continue }
            let base64 = String(tag[valueRange.upperBound..<valueEnd])
            guard let data = Data(base64Encoded: base64), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                continue
            }
            result[key] = value
        }
        return result
    }

    public static func fetch(http: HTTPClient, connection: ServerConnection) async throws -> [String: JSONValue] {
        var headers = connection.standardHeaders
        headers["OCS-APIRequest"] = nil
        headers["Accept"] = "text/html"
        let response = try await http.send(HTTPRequest(url: connection.url("index.php/apps/photos/"), headers: headers, timeout: 30))
        guard response.isSuccess else {
            throw NetworkError.from(status: response.status, data: response.data) ?? .http(status: response.status, message: nil)
        }
        return parse(html: response.text)
    }
}
