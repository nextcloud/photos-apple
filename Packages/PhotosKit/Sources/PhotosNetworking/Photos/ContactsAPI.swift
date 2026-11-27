// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Reads vCards (RFC 6350, and the 3.0 cards older clients write) as far as birthdays need.
public enum VCardBirthday {
    /// The birthday of one card; nil when it has no usable `BDAY` or no name.
    public static func parse(_ card: String, fallbackUID: String) -> ContactBirthday? {
        var name: String?
        var structured: [String]?
        var nicknames: [String] = []
        var birthday: (month: Int, day: Int, year: Int?)?
        var uid: String?
        for line in unfolded(card) {
            guard let colon = colonIndex(line) else { continue }
            let head = line[..<colon]
            let value = String(line[line.index(after: colon)...])
            let parts = head.split(separator: ";")
            // A group prefix ("item1.BDAY") is not part of the name.
            let property = (parts.first.map(String.init) ?? "").split(separator: ".").last.map { String($0).uppercased() } ?? ""
            let parameters = parts.dropFirst().map { $0.uppercased() }
            switch property {
            case "FN": name = unescaped(value).trimmingCharacters(in: .whitespaces)
            case "N": structured = value.split(separator: ";", omittingEmptySubsequences: false).map { unescaped(String($0)) }
            case "NICKNAME":
                nicknames += value.split(separator: ",").map { unescaped(String($0)).trimmingCharacters(in: .whitespaces) }.filter {
                    !$0.isEmpty
                }
            case "UID": uid = value.trimmingCharacters(in: .whitespaces)
            case "BDAY":
                // Text birthdays ("VALUE=text:circa 1800") are not dates.
                if parameters.contains("VALUE=TEXT") { continue }
                let omitYear = parameters.contains { $0.hasPrefix("X-APPLE-OMIT-YEAR") }
                birthday = date(value, omitYear: omitYear)
            default: continue
            }
        }
        let given = structured.flatMap { $0.count > 1 ? $0[1].trimmingCharacters(in: .whitespaces) : nil }.flatMap { $0.isEmpty ? nil : $0 }
        let family = structured.flatMap { $0.first?.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let display = (name?.isEmpty == false ? name : nil) ?? [given, family].compactMap { $0 }.joined(separator: " ")
        guard let birthday, !display.isEmpty else { return nil }
        return ContactBirthday(
            uid: uid ?? fallbackUID, name: display, givenName: given, nicknames: nicknames, month: birthday.month, day: birthday.day,
            year: birthday.year)
    }

    /// `19850412`, `1985-04-12`, `--0412`, `--04-12`, `1985-04-12T00:00:00Z`; Apple's "no year" is 1604.
    static func date(_ raw: String, omitYear: Bool) -> (month: Int, day: Int, year: Int?)? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let datePart = text.split(separator: "T").first.map(String.init) ?? text
        let digits = datePart.filter(\.isNumber)
        var year: Int?
        let monthDay: String
        if datePart.hasPrefix("--") {
            monthDay = digits
        } else if digits.count == 8 {
            year = Int(digits.prefix(4))
            monthDay = String(digits.dropFirst(4))
        } else {
            return nil
        }
        guard monthDay.count == 4, let month = Int(monthDay.prefix(2)), let day = Int(monthDay.suffix(2)), (1...12).contains(month),
            (1...31).contains(day)
        else { return nil }
        if omitYear || year == 1604 || year == 0 { year = nil }
        return (month, day, year)
    }

    /// The card's lines, with folded lines (a line break and a space or tab) joined.
    static func unfolded(_ card: String) -> [String] {
        var lines: [String] = []
        for raw in card.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        return lines
    }

    /// The colon that ends the property name and parameters (not one inside a quoted parameter value).
    static func colonIndex(_ line: String) -> String.Index? {
        var quoted = false
        for index in line.indices {
            if line[index] == "\"" { quoted.toggle() }
            if line[index] == ":", !quoted { return index }
        }
        return nil
    }

    static func unescaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

extension PhotosAPI {
    static let cardDAV = "urn:ietf:params:xml:ns:carddav"

    /// The birthdays in the user's address books (SPEC §22.3), read-only over CardDAV: one listing of the address books,
    /// then one `addressbook-query` per book for the cards that have a `BDAY`, with only the name and birthday fields.
    /// The generated books (the server's accounts, recently contacted) are left out. A server without address books
    /// has no birthdays.
    public func contactBirthdays() async throws -> [ContactBirthday] {
        let home = connection.davURL("addressbooks/users/\(connection.userId)/")
        let books = try await dav.propfind(home, depth: 1, properties: [DAVProp.resourceType])
            .filter { resource in
                let name = resource.href.split(separator: "/").last.map(String.init) ?? ""
                return resource.node(DAVProp.resourceType)?.child(QName(Self.cardDAV, "addressbook")) != nil
                    && !name.hasPrefix("z-server-generated") && !name.hasPrefix("z-app-generated")
            }
        var result: [ContactBirthday] = []
        for book in books {
            guard let url = URL(string: book.rawHref, relativeTo: connection.serverURL)?.absoluteURL else { continue }
            let cards = try await dav.report(url, body: Self.birthdayQuery, depth: 1)
            for card in cards {
                guard let text = card.string(QName(Self.cardDAV, "address-data")) else { continue }
                if let birthday = VCardBirthday.parse(text, fallbackUID: card.href) { result.append(birthday) }
            }
        }
        return result
    }

    /// Cards with a birthday, with the fields birthdays need (no photos: they can be large).
    static let birthdayQuery = Data(
        """
        <?xml version="1.0" encoding="utf-8" ?>
        <C:addressbook-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
          <D:prop>
            <C:address-data>
              <C:prop name="UID"/>
              <C:prop name="FN"/>
              <C:prop name="N"/>
              <C:prop name="NICKNAME"/>
              <C:prop name="BDAY"/>
            </C:address-data>
          </D:prop>
          <C:filter>
            <C:prop-filter name="BDAY"/>
          </C:filter>
        </C:addressbook-query>
        """.utf8)
}
