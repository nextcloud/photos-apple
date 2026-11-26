// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// The test server of `PHOTOS_UITEST_LOGIN`, for tours that bring their own photos instead of relying on what the library
/// holds on the day they run (e.g. photos of "Today"). Everything goes into one folder of its own under `/Photos`, which
/// `removeFolder()` deletes again, also from the trash bin.
struct TestServer {
    let server: URL
    let user: String
    let password: String
    /// The test's own folder, below the timeline folder.
    let folder: String

    /// Reads `nc://login/server:<url>&user:<user>&password:<password>`; nil for another link.
    init?(login: String, folder: String) {
        guard let range = login.range(of: "server:") else { return nil }
        var values: [String: String] = [:]
        for part in login[range.lowerBound...].split(separator: "&") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            values[String(part[..<colon])] = String(part[part.index(after: colon)...])
        }
        guard let address = values["server"], let server = URL(string: address), let user = values["user"],
            let password = values["password"]
        else { return nil }
        self.server = server
        self.user = user
        self.password = password
        self.folder = folder
    }

    private func url(_ path: String) -> URL {
        var url = server.appending(path: "remote.php/dav/files").appending(path: user)
        for part in path.split(separator: "/") { url = url.appending(path: String(part)) }
        return url
    }

    private func request(_ method: String, _ url: URL, body: Data? = nil, headers: [String: String] = [:]) async throws -> (
        Data, Int
    ) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        let credentials = Data("\(user):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// A small JPEG of one colour without EXIF data: the server dates it by its modification time.
    static func jpeg(hue: CGFloat) -> Data {
        let size = CGSize(width: 64, height: 48)
        #if canImport(UIKit)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            return image.jpegData(compressionQuality: 0.8) ?? Data()
        #else
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
                rect.fill()
                return true
            }
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return Data() }
            return bitmap.representation(using: .jpeg, properties: [:]) ?? Data()
        #endif
    }

    /// Creates the folder and uploads `count` photos dated now (`X-OC-MTime`), so that they are the newest of the library.
    func uploadPhotos(_ count: Int, prefix: String) async throws -> [String] {
        let (_, created) = try await request("MKCOL", url(folder))
        // 405: the folder is there already (an earlier run that stopped half-way).
        guard created == 201 || created == 405 else { throw URLError(.badServerResponse) }
        var names: [String] = []
        let now = Int(Date().timeIntervalSince1970)
        for index in 0..<count {
            let name = "\(prefix)-\(index + 1).jpg"
            let (_, status) = try await request(
                "PUT", url("\(folder)/\(name)"), body: Self.jpeg(hue: CGFloat(index) / CGFloat(max(count, 1))),
                headers: ["Content-Type": "image/jpeg", "X-OC-MTime": String(now - index)])
            guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
            names.append(name)
        }
        return names
    }

    /// Creates the folder and uploads one file dated now (`X-OC-MTime`, minus `age` seconds).
    func upload(_ data: Data, name: String, contentType: String, age: Int = 0) async throws {
        let (_, created) = try await request("MKCOL", url(folder))
        guard created == 201 || created == 405 else { throw URLError(.badServerResponse) }
        let (_, status) = try await request(
            "PUT", url("\(folder)/\(name)"), body: data,
            headers: ["Content-Type": contentType, "X-OC-MTime": String(Int(Date().timeIntervalSince1970) - age)])
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
    }

    /// Deletes the folder, then its entries in the trash bin: the folder, and photos of it the test deleted in the app (only
    /// those; never the trash bin itself).
    func removeFolder() async throws {
        _ = try await request("DELETE", url(folder))
        let trash = server.appending(path: "remote.php/dav/trashbin").appending(path: user).appending(path: "trash")
        let body = Data(
            """
            <?xml version="1.0"?>
            <d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
              <d:prop><nc:trashbin-filename/><nc:trashbin-original-location/></d:prop>
            </d:propfind>
            """.utf8)
        let (data, status) = try await request("PROPFIND", trash, body: body, headers: ["Depth": "1", "Content-Type": "application/xml"])
        guard status == 207 else { return }
        for href in TrashListing.hrefs(in: data, folder: folder) {
            guard let entry = URL(string: href, relativeTo: server)?.absoluteURL, entry.path() != trash.path() + "/" else { continue }
            _ = try await request("DELETE", entry)
        }
    }
}

/// The trash bin's PROPFIND answer: the `href` of each entry that is the folder or was in it.
private final class TrashListing: NSObject, XMLParserDelegate {
    private var hrefs: [String] = []
    private var href = ""
    private var location = ""
    private var text = ""
    private let folder: String

    private init(folder: String) { self.folder = folder }

    static func hrefs(in data: Data, folder: String) -> [String] {
        let listing = TrashListing(folder: folder)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = listing
        parser.parse()
        return listing.hrefs
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        text = ""
        if elementName == "response" {
            href = ""
            location = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "href": href = text
        // Where the entry was, relative to the user's files: "Photos/UI test …" or "Photos/UI test …/photo.jpg".
        case "trashbin-original-location": location = text
        case "response" where !href.isEmpty && (location == folder || location.hasPrefix(folder + "/")): hrefs.append(href)
        default: break
        }
    }
}
