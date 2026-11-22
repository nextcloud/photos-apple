// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Security
import Testing

/// The SPKI wrapping must produce a key that Security can import back as a public key.
@Suite struct PushKeyTests {
    @Test func spkiWrappingRoundTrips() throws {
        var error: Unmanaged<CFError>?
        let key = try #require(
            SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, &error) as Data?)
        // Same construction as PushNotifications.publicKeyPEM.
        func derLength(_ length: Int) -> [UInt8] {
            if length < 128 { return [UInt8(length)] }
            var bytes: [UInt8] = []
            var value = length
            while value > 0 {
                bytes.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString = [0x00] + [UInt8](pkcs1)
        let body = algorithm + [0x03] + derLength(bitString.count) + bitString
        let spki = Data([0x30] + derLength(body.count) + body)
        #expect(spki.count == 294)  // standard size of a 2048-bit RSA SPKI
        #expect(spki.prefix(4) == Data([0x30, 0x82, 0x01, 0x22]))
    }
}
