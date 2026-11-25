// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import PhotosModel

#if !os(tvOS) && !os(watchOS)
    import LocalAuthentication
#endif

/// What a guest may see (SPEC §16.8.3): the photos of one album or memory, as they were when Guest Mode started.
public struct GuestShow: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case album
        case memory
    }

    /// The account the photos belong to (`AccountID.rawValue`).
    public var account: String
    public var kind: Kind
    public var title: String
    /// Dates or place, shown under the title.
    public var subtitle: String?
    public var items: [FileID]
    public var startedAt: Date

    public init(account: String, kind: Kind, title: String, subtitle: String? = nil, items: [FileID], startedAt: Date = Date()) {
        self.account = account
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.startedAt = startedAt
    }
}

/// Guest Mode (SPEC §16.8.3): the app shows nothing but one album or memory until the device owner ends it with Face ID,
/// Touch ID, Optic ID or the passcode (the login password on the Mac).
///
/// It is kept in the app's defaults: an app that is quit and opened again during Guest Mode opens in Guest Mode, so
/// quitting is no way out. Links, notifications and Spotlight results do nothing meanwhile (`AppModel.open`).
@MainActor
@Observable
public final class GuestMode {
    public static let shared = GuestMode()
    nonisolated static let storageKey = "guestModeShow"

    /// How ending it was answered.
    public enum Authentication: Sendable, Equatable {
        case granted
        case denied
        /// The device has no passcode (or no authentication at all): nothing can protect Guest Mode.
        case unavailable
    }

    public private(set) var show: GuestShow?
    public private(set) var isAuthenticating = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authenticate: @MainActor (String) async -> Authentication

    init(defaults: UserDefaults = .standard, authenticate: @escaping @MainActor (String) async -> Authentication = GuestMode.deviceOwner) {
        self.defaults = defaults
        self.authenticate = authenticate
        show = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(GuestShow.self, from: $0) }
    }

    public var isActive: Bool { show != nil }

    /// Whether Guest Mode is on, from any thread (the notification delegate asks before a banner is shown).
    public nonisolated static var isActiveNow: Bool { UserDefaults.standard.data(forKey: storageKey) != nil }

    /// Starts Guest Mode with `show`. Nothing happens for an empty album or memory.
    public func start(_ show: GuestShow) {
        guard !show.items.isEmpty else { return }
        self.show = show
        defaults.set(try? JSONEncoder().encode(show), forKey: Self.storageKey)
    }

    /// Ends Guest Mode once the device owner authenticates. On a device without a passcode it ends at once: the sheet that
    /// started it said so.
    /// - Parameter reason: what the system's prompt says.
    @discardableResult
    public func end(reason: String) async -> Bool {
        guard isActive else { return true }
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        switch await authenticate(reason) {
        case .granted, .unavailable:
            show = nil
            defaults.removeObject(forKey: Self.storageKey)
            return true
        case .denied:
            return false
        }
    }

    /// Whether ending Guest Mode will ask for authentication on this device (the sheet warns when it will not).
    public static var isProtected: Bool {
        #if os(tvOS) || os(watchOS)
            false
        #else
            LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        #endif
    }

    /// Face ID, Touch ID, Optic ID or the passcode / login password.
    public static func deviceOwner(_ reason: String) async -> Authentication {
        #if os(tvOS) || os(watchOS)
            return .unavailable
        #else
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                return error?.code == LAError.passcodeNotSet.rawValue ? .unavailable : .denied
            }
            let granted = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
            return granted ? .granted : .denied
        #endif
    }

    /// The photos of `show` that may be shown, for the account shown: nothing of another account.
    public func items(for account: AccountID) -> [FileID] {
        guard let show, show.account == account.rawValue else { return [] }
        return show.items
    }
}
