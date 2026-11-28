// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel
@testable import PhotosNetworking

/// Birthdays read from vCards (SPEC §22.3).
@Suite struct VCardBirthdayTests {
    @Test func readsTheFormsClientsWrite() throws {
        let card = """
            BEGIN:VCARD\r
            VERSION:4.0\r
            UID:abc-1\r
            FN:Anna Schmidt\r
            N:Schmidt;Anna;;;\r
            NICKNAME:Anni,Annchen\r
            BDAY:19850412\r
            END:VCARD\r
            """
        let anna = try #require(VCardBirthday.parse(card, fallbackUID: "x"))
        #expect(
            anna
                == ContactBirthday(
                    uid: "abc-1", name: "Anna Schmidt", givenName: "Anna", nicknames: ["Anni", "Annchen"], month: 4, day: 12, year: 1985))
        #expect(VCardBirthday.date("1985-04-12", omitYear: false)! == (4, 12, 1985))
        #expect(VCardBirthday.date("--0412", omitYear: false)! == (4, 12, nil))
        #expect(VCardBirthday.date("--04-12", omitYear: false)! == (4, 12, nil))
        #expect(VCardBirthday.date("1985-04-12T00:00:00Z", omitYear: false)! == (4, 12, 1985))
        // Apple's "no year".
        #expect(VCardBirthday.date("1604-04-12", omitYear: true)! == (4, 12, nil))
        #expect(VCardBirthday.date("1985-13-12", omitYear: false) == nil)
        #expect(VCardBirthday.date("circa 1800", omitYear: false) == nil)
    }

    @Test func foldedLinesGroupsAndParametersAreUnderstood() throws {
        let card = """
            BEGIN:VCARD
            VERSION:3.0
            FN:Benjamin
              Müller
            item1.BDAY;X-APPLE-OMIT-YEAR=1604;VALUE=date:1604-11-27
            END:VCARD
            """
        let ben = try #require(VCardBirthday.parse(card, fallbackUID: "/remote.php/dav/addressbooks/users/u/contacts/ben.vcf"))
        #expect(ben.name == "Benjamin Müller")
        #expect(ben.uid == "/remote.php/dav/addressbooks/users/u/contacts/ben.vcf")
        #expect(ben.month == 11 && ben.day == 27 && ben.year == nil)
        // No birthday, or a text one: nothing.
        #expect(VCardBirthday.parse("BEGIN:VCARD\nFN:Carla\nEND:VCARD", fallbackUID: "c") == nil)
        #expect(VCardBirthday.parse("BEGIN:VCARD\nFN:Carla\nBDAY;VALUE=text:circa 1800\nEND:VCARD", fallbackUID: "c") == nil)
        // No FN: the name from N.
        let dora = VCardBirthday.parse("BEGIN:VCARD\nN:Weber;Dora;;;\nBDAY:2001-02-03\nEND:VCARD", fallbackUID: "d")
        #expect(dora?.name == "Dora Weber")
    }
}

/// Reading the birthdays over CardDAV from a real server. Runs only when PHOTOS_IT_SERVER, PHOTOS_IT_USER and
/// PHOTOS_IT_PASSWORD are set; adds a contact of its own (UID `r12-people-…`) to the default address book and removes it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct ContactBirthdaysIntegrationTests {
    let api: PhotosAPI
    let dav: DAVClient
    let uid = "r12-people-\(UUID().uuidString.prefix(8))"

    init() {
        let env = ProcessInfo.processInfo.environment
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let connection = ServerConnection(
            serverURL: URL(string: env["PHOTOS_IT_SERVER"] ?? "http://localhost")!, userId: user, loginName: user,
            appPassword: env["PHOTOS_IT_PASSWORD"] ?? "", userAgent: "Mozilla/5.0 (macOS) Nextcloud-Photos/tests")
        dav = DAVClient(http: HTTPClient(trustStore: TrustStore(directory: nil)), connection: connection)
        api = PhotosAPI(dav: dav, ocs: OCSClient(http: dav.http, connection: connection))
    }

    @Test func readsTheBirthdaysOfTheAddressBooks() async throws {
        let url = dav.connection.davURL("addressbooks/users/\(dav.connection.userId)/contacts/\(uid).vcf")
        let card =
            "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:\(uid)\r\nFN:R12 Test Person\r\nN:Person;R12 Test;;;\r\nBDAY:2019-11-27\r\nEND:VCARD\r\n"
        _ = try await dav.put(url, data: Data(card.utf8), headers: ["Content-Type": "text/vcard; charset=utf-8"])
        do {
            let birthdays = try await api.contactBirthdays()
            let found = try #require(birthdays.first { $0.uid == uid })
            #expect(found.name == "R12 Test Person")
            #expect(found.month == 11 && found.day == 27 && found.year == 2019)
        } catch {
            try? await dav.delete(url)
            throw error
        }
        try await dav.delete(url)
        #expect(try await api.contactBirthdays().contains { $0.uid == uid } == false)
    }
}
