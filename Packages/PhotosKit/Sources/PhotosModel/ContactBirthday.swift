// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A birthday from the user's Nextcloud Contacts (SPEC §22.3).
public struct ContactBirthday: Codable, Hashable, Sendable {
    /// The card's UID (or its href when it has none).
    public var uid: String
    /// The formatted name (`FN`).
    public var name: String
    /// The given name (`N`), when the card has one.
    public var givenName: String?
    public var nicknames: [String]
    public var month: Int
    public var day: Int
    /// Nil when only the day is known (`--0412`, or Apple's year 1604).
    public var year: Int?

    public init(uid: String, name: String, givenName: String? = nil, nicknames: [String] = [], month: Int, day: Int, year: Int? = nil) {
        self.uid = uid
        self.name = name
        self.givenName = givenName
        self.nicknames = nicknames
        self.month = month
        self.day = day
        self.year = year
    }
}
