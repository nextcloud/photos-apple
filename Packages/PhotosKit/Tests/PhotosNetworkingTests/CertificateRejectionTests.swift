// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Security
import Testing

@testable import PhotosNetworking

/// A server whose certificate is refused: every request that the refusal cancels reports the certificate.
@Suite struct CertificateRejectionTests {
    static let host = "cloud.example.test"
    static let url = URL(string: "https://cloud.example.test/remote.php/dav/files/alice/")!

    /// A self-signed certificate for `cloud.example.test` (nothing trusts it).
    static let certificate = Data(
        base64Encoded: """
            MIIC+zCCAeOgAwIBAgITIddj7L1kEEXD3TphHcuu4suGMDANBgkqhkiG9w0BAQsFADAdMRswGQYDVQQDDBJjbG91ZC5leGFtcGxlLnRlc3QwIB\
            cNMjYxMTIzMjEzNjU0WhgPMjEyNjEwMzAyMTM2NTRaMB0xGzAZBgNVBAMMEmNsb3VkLmV4YW1wbGUudGVzdDCCASIwDQYJKoZIhvcNAQEBBQAD\
            ggEPADCCAQoCggEBAM9BXGVie628p0nfNBHUoXLIhAsT+nz4TB/m7dk6zdF5JmY6c8c0NuC47JGQnX5Xu2jA72p7cOs6Hcez4l8ZbXt5QT603Q\
            Cq3p9O4yx64heEKWfJi7dvu42K0gu+SkQkeJ5HGYIQsji/RJ9BwqLfuS88cO8vNuLqLRlPEsIoCUNOnvepn0ntMI7EgDC+kEiPA1aCb4buoKHg\
            jTEOMQSbtmYBgCTDYDqr+3ZTORo4fArxCUZSgDtxSRUMkcs6UglwQXVkY4BnmRiAHPXRWI55pYcIFVl4XtvaPWKuXwQKg23Nn0vf+OfQpoRFLB\
            H2ZRkbKa57dXHa5xB1rHP8AJTnUtkCAwEAAaMyMDAwHQYDVR0OBBYEFGOGNdZrdlV3u7OrDWCheBCcirsyMA8GA1UdEwEB/wQFMAMBAf8wDQYJ\
            KoZIhvcNAQELBQADggEBAINh9nSnEnFNwx6iEmi75URO8/S+SsVOCigM+hIyWaUMGPQvNbWcQizLwYta9pCB5ckZSIgHptb2/ki8c6E06JY3GP\
            ozeH5czqkRhqyXvGJrDvYBHTH585OoyQ4fudonZrPvBS2RK5VgBmQsiS4tUHEH9NCST3Bx/JUfbTi4Y0RhgcSkuQaOGHoS6citd5nxkyJZm1SE\
            cf6MtXZT+qCIDxi/ft9pOKo22aLdT6PEybmExJSUM5qFqgBxZhmLCEvmykTdFQTQc8ljTuL4cB6KeaX+npqZwL16oCuCO9AnwjeDsQNT0Q/QtC\
            8vpPCxBaeVQK+TNJnPZPk/OvadliYvom8=
            """)!

    /// What the server presents in the TLS handshake.
    static func serverTrust() throws -> SecTrust {
        let certificate = try #require(SecCertificateCreateWithData(nil, Self.certificate as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, Self.host as CFString), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    @Test func everyRequestCancelledByTheRefusalReportsTheCertificate() async throws {
        let delegate = SessionDelegate(trustStore: TrustStore(directory: nil), clientCredentials: nil)
        #expect(delegate.networkError(for: URLError(.cancelled), url: Self.url) == .cancelled)

        // One handshake is refused; the connection it belongs to carries many requests (HTTP/2), which all end as cancelled.
        #expect(try !delegate.accepts(Self.serverTrust(), host: "Cloud.Example.Test"))
        let errors: [NetworkError] = await withTaskGroup(of: NetworkError.self) { group in
            for _ in 0..<24 {
                group.addTask { delegate.networkError(for: URLError(.cancelled), url: Self.url) }
            }
            var all: [NetworkError] = []
            for await error in group { all.append(error) }
            return all
        }
        #expect(errors.count == 24)
        #expect(errors.allSatisfy { $0 == .untrustedCertificate(host: Self.host, certificate: Self.certificate) })
        // Also the ones that come a little later; another host is not affected.
        #expect(delegate.networkError(for: URLError(.cancelled), url: Self.url) != .cancelled)
        #expect(delegate.networkError(for: URLError(.cancelled), url: URL(string: "https://other.example.test/")!) == .cancelled)
    }

    @Test func aCancellationLongAfterTheRefusalIsACancellation() throws {
        let delegate = SessionDelegate(trustStore: TrustStore(directory: nil), clientCredentials: nil)
        let refusedAt = Date().addingTimeInterval(-SessionDelegate.rejectionWindow - 5)
        #expect(try !delegate.accepts(Self.serverTrust(), host: Self.host, now: refusedAt))
        #expect(delegate.networkError(for: URLError(.cancelled), url: Self.url) == .cancelled)
        // The host is still known as refused: the account shows "certificate changed" until it is trusted.
        #expect(delegate.isRejected(Self.host))
    }

    @Test func trustingTheCertificateEndsTheRefusal() throws {
        let store = TrustStore(directory: nil)
        let client = HTTPClient(trustStore: store)
        #expect(client.rejectedCertificate(for: Self.host) == nil)
        let delegate = try #require(client.session.delegate as? SessionDelegate)
        #expect(try !delegate.accepts(Self.serverTrust(), host: Self.host))
        #expect(client.rejectedCertificate(for: Self.host) == Self.certificate)

        try store.trust(certificate: Self.certificate, for: Self.host)
        // Still refused until the server has presented the now trusted certificate again.
        #expect(client.rejectedCertificate(for: Self.host) == Self.certificate)
        #expect(try delegate.accepts(Self.serverTrust(), host: Self.host))
        #expect(client.rejectedCertificate(for: Self.host) == nil)
        #expect(delegate.networkError(for: URLError(.cancelled), url: Self.url) == .cancelled)
    }

    /// A request that is answered went over a connection with an acceptable certificate, also one that was open before the
    /// refusal and asked no new question: the refusal ends, and the account's "certificate changed" state with it.
    @Test func anAnsweredRequestEndsTheRefusal() throws {
        let delegate = SessionDelegate(trustStore: TrustStore(directory: nil), clientCredentials: nil)
        #expect(try !delegate.accepts(Self.serverTrust(), host: Self.host))
        #expect(delegate.isRejected(Self.host))
        // Plain http and other hosts don't say anything about this host's certificate.
        delegate.didReceiveResponse(from: URL(string: "http://cloud.example.test/status.php")!)
        delegate.didReceiveResponse(from: URL(string: "https://other.example.test/status.php")!)
        #expect(delegate.isRejected(Self.host))
        delegate.didReceiveResponse(from: URL(string: "https://Cloud.Example.Test/remote.php/dav/files/alice/")!)
        #expect(!delegate.isRejected(Self.host))
        #expect(delegate.networkError(for: URLError(.cancelled), url: Self.url) == .cancelled)
    }

    /// The trust dialog compares the certificate the user trusted before with the new one.
    @Test func theStoreKnowsTheCertificateTrustedBefore() throws {
        let store = TrustStore(directory: nil)
        #expect(store.trustedCertificate(for: Self.host) == nil)
        try store.trust(certificate: Data([1, 2, 3]), for: "Cloud.Example.Test")
        #expect(store.trustedCertificate(for: Self.host) == Data([1, 2, 3]))
        #expect(store.trustedHosts == [Self.host])
        // The server now presents another certificate: refused, and both are known.
        #expect(try !store.evaluate(Self.serverTrust(), host: Self.host))
        #expect(store.lastFailure(for: Self.host) == Self.certificate)
        #expect(store.lastAccepted(for: Self.host) == nil)
        try store.trust(certificate: Self.certificate, for: Self.host)
        #expect(try store.evaluate(Self.serverTrust(), host: Self.host))
        #expect(store.lastAccepted(for: Self.host) == Self.certificate)
        #expect(TrustStore.fingerprint(of: Self.certificate).count == 32 * 3 - 1)
        #expect(TrustStore.subject(of: Self.certificate) == Self.host)
    }
}
