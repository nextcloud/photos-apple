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

    /// Evaluates a server trust: system evaluation, else equality with a user-trusted leaf certificate.
    func evaluate(_ trust: SecTrust, host: String) -> Bool {
        if SecTrustEvaluateWithError(trust, nil) { return true }
        let host = host.lowercased()
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return false }
        let der = SecCertificateCopyData(leaf) as Data
        if let accepted = trusted.withLock({ $0[host] }), accepted == der { return true }
        failures.withLock { $0[host] = der }
        return false
    }

    /// Human readable summary of a DER certificate for the trust dialog.
    public static func summary(of der: Data) -> String {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return "" }
        var lines: [String] = []
        if let subject = SecCertificateCopySubjectSummary(certificate) as String? { lines.append(subject) }
        let digest = sha256Hex(der)
        lines.append("SHA-256: \(digest)")
        return lines.joined(separator: "\n")
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
