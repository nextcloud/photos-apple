// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Parts of the names of cache files that come from the server.
public enum CacheFileName {
    /// An ETag as part of a file name.
    ///
    /// The ETag is whatever the server (or a storage behind it) sends: it may contain `/`, `..`, or be very long. A value
    /// of letters, digits, `-` and `_` (every ETag Nextcloud itself makes) is used as it is, so files cached before
    /// this rule existed are still found; anything else is replaced by a hash of it.
    public static func etag(_ etag: String) -> String {
        let bytes = etag.utf8
        if bytes.count <= 64, bytes.allSatisfy(isSafe) { return etag }
        let digest = SHA256.hash(data: Data(bytes))
        return "x" + digest.prefix(16).map { byte in String(byte, radix: 16).leftPadded(to: 2) }.joined()
    }

    private static func isSafe(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default: false
        }
    }
}

extension String {
    fileprivate func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
