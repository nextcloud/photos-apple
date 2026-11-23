// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel

@Suite struct CacheFileNameTests {
    /// ETags as Nextcloud makes them are used as they are, so existing cache files are still found.
    @Test func ordinaryETagsAreKept() {
        for etag in ["5f3a9c2b7d1e4", "d41d8cd98f00b204e9800998ecf8427e", "abc", "A-b_9", ""] {
            #expect(CacheFileName.etag(etag) == etag)
        }
    }

    @Test func anythingElseIsHashed() {
        let hostile = ["../../../etc/passwd", "a/b", "..", ".", "a b", "a.b", "W/\"x\"", "é", "a\u{0}b", String(repeating: "a", count: 65)]
        var seen: Set<String> = []
        for etag in hostile {
            let name = CacheFileName.etag(etag)
            #expect(name.count == 33 && name.hasPrefix("x"), "\(etag)")
            #expect(name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }, "\(etag)")
            #expect(name == CacheFileName.etag(etag))
            seen.insert(name)
        }
        #expect(seen.count == hostile.count)
    }
}
