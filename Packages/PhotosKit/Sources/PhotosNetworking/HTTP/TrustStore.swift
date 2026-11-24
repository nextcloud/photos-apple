// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Security
import Synchronization

/// Server certificates the user explicitly trusted, per host (leaf certificate DER equality).
///
/// System trust is always tried first. Extensions use the same store; nothing ever accepts an
/// untrusted certificate without the user having trusted exactly that certificate for that host.
public final class TrustStore: Sendable {
    private let directory: URL?
    private let trusted: Mutex<[String: Data]>
    /// Leaf certificates of recent trust failures, so the UI can show and accept them.
    private let failures = Mutex<[String: Data]>([:])
    /// The leaf certificate each host last presented that was accepted (by the system or the user), in memory only: when the
    /// certificate changes, the dialog shows the one before next to the new one.
    private let accepted = Mutex<[String: Data]>([:])

    /// - Parameter directory: where accepted certificates are stored (`<host>.der`); `nil` keeps them in memory only.
    public init(directory: URL?) {
        self.directory = directory
        var loaded: [String: Data] = [:]
        if let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "der" {
                if let data = try? Data(contentsOf: file) {
                    loaded[file.deletingPathExtension().lastPathComponent] = data
                }
            }
        }
        self.trusted = Mutex(loaded)
    }

    public func trust(certificate: Data, for host: String) throws {
        let host = host.lowercased()
        trusted.withLock { $0[host] = certificate }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try certificate.write(to: directory.appending(path: "\(host).der"), options: .atomic)
        }
    }

    public func removeTrust(for host: String) {
        let host = host.lowercased()
        trusted.withLock { $0[host] = nil }
        if let directory { try? FileManager.default.removeItem(at: directory.appending(path: "\(host).der")) }
    }

    public func lastFailure(for host: String) -> Data? {
        failures.withLock { $0[host.lowercased()] }
    }

    /// The certificate the user trusted for a host, or nil when the host has only ever been trusted by the system.
    public func trustedCertificate(for host: String) -> Data? {
        trusted.withLock { $0[host.lowercased()] }
    }

    /// The certificate the host last presented that was accepted, during this run of the app.
    public func lastAccepted(for host: String) -> Data? {
        accepted.withLock { $0[host.lowercased()] }
    }

    /// Hosts with a certificate the user trusted.
    public var trustedHosts: Set<String> {
        Set(trusted.withLock { Array($0.keys) })
    }

    /// Evaluates a server trust: system evaluation, else equality with a user-trusted leaf certificate.
    func evaluate(_ trust: SecTrust, host: String) -> Bool {
        let host = host.lowercased()
        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
        let der = chain?.first.map { SecCertificateCopyData($0) as Data }
        if SecTrustEvaluateWithError(trust, nil) {
            if let der { accepted.withLock { $0[host] = der } }
            return true
        }
        guard let der else { return false }
        if let pinned = trusted.withLock({ $0[host] }), pinned == der {
            accepted.withLock { $0[host] = der }
            return true
        }
        failures.withLock { $0[host] = der }
        return false
    }

    /// Human readable summary of a DER certificate for the trust dialog.
    public static func summary(of der: Data) -> String {
        var lines: [String] = []
        if let subject = subject(of: der) { lines.append(subject) }
        lines.append("SHA-256: \(fingerprint(of: der))")
        return lines.joined(separator: "\n")
    }

    /// The certificate's subject summary (usually its host name), as the certificate itself states it.
    public static func subject(of der: Data) -> String? {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return SecCertificateCopySubjectSummary(certificate) as String?
    }

    /// SHA-256 fingerprint of a DER certificate, as colon-separated hex (`AB:CD:…`).
    public static func fingerprint(of der: Data) -> String { sha256Hex(der) }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
