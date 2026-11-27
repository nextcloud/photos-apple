// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Network
import OSLog
import PhotosModel

// Setting up Apple TV from the iPhone (SPEC §22.2).
//
// The TV app shows Apple's device picker (DeviceDiscoveryUI) for the application service `TVSetup.serviceName`; the user
// picks their iPhone or iPad, the system asks there whether to allow it and starts the app, whose listener
// (`TVSetupListener`) takes the connection. The system's connection is end-to-end encrypted and only reaches devices of
// the Apple TV's iCloud account or family. Over it:
//
//   TV → phone   hello(version, device)        "Living Room" wants to be set up
//   phone → TV   account(server, login name)   the account the user chose on the phone
//   TV → phone   login(url)                    the TV started Login Flow v2 on that server: its login page
//   phone        opens the page in the browser; the user (often already logged in there) grants access
//   TV           polls the flow and receives its *own* app password from the server, as with the QR code
//   TV → phone   done(name) / failed(reason)   the phone says so and closes the browser
//
// No password or app password ever crosses the local network: the phone hands over an address and opens a page, the TV
// gets its credentials from the server over HTTPS. A dedicated app password is required (revoking the TV must not sign out
// the phone), and Nextcloud refuses to create one from another app password (`getapppassword` and the Login Flow's grant
// both answer 403 to a client that authenticates with an app password), so the grant goes through the server's page.
// The phone only opens a login page of the server it chose (`TVSetup.isLoginPage`): a TV that sent another server's page
// is refused.

/// The protocol between the TV app and the iPhone app.
public enum TVSetup {
    /// `NSApplicationServiceIdentifier` of both apps' Info.plist (`NSApplicationServices`: the TV browses, the phone advertises).
    public static let serviceName = "NextcloudPhotos-TVSetup"
    /// Debug builds in the simulators, where DeviceDiscoveryUI finds no devices: plain Bonjour on the Mac's network
    /// (`PHOTOS_DEBUG_TV_SETUP=bonjour` in both apps). Not in release builds: that connection is not encrypted.
    public static let debugBonjourType = "_ncphotos-setup._tcp"
    public static let version = 1
    /// Larger frames are refused (a message is a few hundred bytes).
    static let maximumFrame = 64 * 1024

    public enum Message: Codable, Equatable, Sendable {
        case hello(version: Int, device: String)
        case account(serverURL: URL, loginName: String)
        case login(url: URL)
        case done(name: String)
        case failed(reason: String)
        case cancel
    }

    /// One message on the wire: its JSON after a 4-byte big-endian length.
    public static func frame(_ message: Message) throws -> Data {
        let body = try JSONEncoder().encode(message)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Takes the bytes as they arrive and gives back the complete messages.
    public struct FrameDecoder: Sendable {
        private var buffer = Data()

        public init() {}

        public enum Failure: Error, Equatable {
            case tooLarge(Int)
        }

        public mutating func append(_ data: Data) throws -> [Message] {
            buffer.append(data)
            var messages: [Message] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                guard length <= TVSetup.maximumFrame else { throw Failure.tooLarge(length) }
                guard buffer.count >= 4 + length else { break }
                let body = buffer.dropFirst(4).prefix(length)
                buffer = Data(buffer.dropFirst(4 + length))
                messages.append(try JSONDecoder().decode(Message.self, from: Data(body)))
            }
            return messages
        }
    }

    /// Whether `url` is the Login Flow v2 page of `server` (`…/index.php/login/v2/flow/<token>` or without index.php): the
    /// same host, port and path below the server, https if the server is https. The phone opens nothing else.
    public static func isLoginPage(_ url: URL, of server: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443) }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            server.scheme?.lowercased() != "https" || scheme == "https",
            url.host()?.lowercased() == server.host()?.lowercased(), port(url) == port(server),
            url.user == nil, url.password == nil
        else { return false }
        let base = server.pathComponents.filter { $0 != "/" }
        var parts = url.pathComponents.filter { $0 != "/" }
        guard parts.starts(with: base) else { return false }
        parts.removeFirst(base.count)
        if parts.first == "index.php" { parts.removeFirst() }
        return parts.count == 4 && Array(parts.prefix(3)) == ["login", "v2", "flow"] && !parts[3].isEmpty
    }

    /// The login page with the user's login name filled in.
    public static func loginPage(_ url: URL, user: String) -> URL {
        guard !user.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "user" }
        items.append(URLQueryItem(name: "user", value: user))
        components.queryItems = items
        return components.url ?? url
    }

    /// The parameters of the connection: the system's encrypted application service, or plain TCP for the debug fallback.
    public static func parameters(debugBonjour: Bool) -> NWParameters {
        debugBonjour ? .tcp : .applicationService
    }

    /// `PHOTOS_DEBUG_TV_SETUP=bonjour` (debug builds only).
    public static var usesDebugBonjour: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["PHOTOS_DEBUG_TV_SETUP"] == "bonjour"
        #else
            false
        #endif
    }
}

/// A connection between the two apps that sends and receives `TVSetup.Message`s.
public final class TVSetupChannel: Sendable {
    let connection: NWConnection
    public let messages: AsyncThrowingStream<TVSetup.Message, any Error>
    private let continuation: AsyncThrowingStream<TVSetup.Message, any Error>.Continuation
    private static let queue = DispatchQueue(label: "com.nextcloud.photos.tv-setup")

    public enum Failure: Error, Equatable {
        case closed
    }

    public init(_ connection: NWConnection) {
        self.connection = connection
        (messages, continuation) = AsyncThrowingStream.makeStream()
    }

    /// Connects (TV) or accepts (phone), then reads messages until the connection ends.
    public func start() {
        let continuation = continuation
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive(TVSetup.FrameDecoder())
            case .failed(let error): continuation.finish(throwing: error)
            case .cancelled: continuation.finish()
            default: break
            }
        }
        continuation.onTermination = { [connection] _ in connection.cancel() }
        connection.start(queue: Self.queue)
    }

    private func receive(_ decoder: TVSetup.FrameDecoder) {
        let continuation = continuation
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            var decoder = decoder
            if let data, !data.isEmpty {
                do {
                    for message in try decoder.append(data) { continuation.yield(message) }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
            }
            if let error {
                continuation.finish(throwing: error)
            } else if isComplete {
                continuation.finish()
            } else {
                self?.receive(decoder)
            }
        }
    }

    public func send(_ message: TVSetup.Message) async throws {
        let data = try TVSetup.frame(message)
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error { done.resume(throwing: error) } else { done.resume() }
                })
        }
    }

    /// The next message, or `Failure.closed` when the other side went away.
    public func next(in iterator: inout AsyncThrowingStream<TVSetup.Message, any Error>.Iterator) async throws -> TVSetup.Message {
        guard let message = try await iterator.next() else { throw Failure.closed }
        return message
    }

    public func close() {
        continuation.finish()
        connection.cancel()
    }
}

/// An Apple TV that asked to be set up, waiting for the user on the phone.
public struct TVSetupRequest: Identifiable, Sendable {
    public let id = UUID()
    /// The TV's name ("Living Room").
    public let device: String
    public let channel: TVSetupChannel
}

/// The phone's side (iPhone and iPad): the listener the system connects the TV to, started at launch, and the request
/// it received, which the app's sheet shows (`TVSetupSheet`).
@MainActor
@Observable
public final class TVSetupListener {
    public static let shared = TVSetupListener()

    /// The TV that asked; one at a time.
    public private(set) var request: TVSetupRequest?
    /// Whether an account is logged in to set the TV up with (the app sets it; without one the TV hears so).
    public var hasAccount: @MainActor () -> Bool = { true }
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "tv-setup")

    /// Starts listening (once). In the simulators `PHOTOS_DEBUG_TV_SETUP=bonjour` listens with Bonjour instead.
    public func start() {
        guard listener == nil else { return }
        let bonjour = TVSetup.usesDebugBonjour
        do {
            let listener = try NWListener(using: TVSetup.parameters(debugBonjour: bonjour))
            listener.service =
                bonjour
                ? NWListener.Service(name: "Nextcloud Photos", type: TVSetup.debugBonjourType)
                : NWListener.Service(applicationService: TVSetup.serviceName)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [logger] state in
                logger.notice("tv setup listener: \(String(describing: state), privacy: .public)")
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            logger.error("tv setup listener: \(error.localizedDescription, privacy: .public)")
        }
    }

    func accept(_ connection: NWConnection) {
        let channel = TVSetupChannel(connection)
        guard request == nil else {
            // One TV at a time: the second one hears that the phone is busy.
            channel.start()
            Task {
                try? await channel.send(.failed(reason: TVSetupWording.busy))
                channel.close()
            }
            return
        }
        channel.start()
        Task {
            var iterator = channel.messages.makeAsyncIterator()
            guard case .hello(let version, let device)? = try? await iterator.next() else {
                channel.close()
                return
            }
            guard version == TVSetup.version else {
                try? await channel.send(.failed(reason: TVSetupWording.otherVersion))
                channel.close()
                return
            }
            guard hasAccount() else {
                try? await channel.send(.failed(reason: TVSetupWording.noAccount))
                channel.close()
                return
            }
            logger.notice("tv setup: an Apple TV asks to be set up")
            request = TVSetupRequest(device: device, channel: channel)
        }
    }

    /// The sheet ended (done, cancelled, failed).
    public func finish() {
        request = nil
    }

    #if DEBUG
        /// Screenshots of the sheet without a TV (`PHOTOS_DEBUG_TV_SETUP_SHEET=<name>`).
        public func showForDebugging(device: String) {
            let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            request = TVSetupRequest(device: device, channel: TVSetupChannel(connection))
        }
    #endif
}

/// The phone's steps once the user chose an account (`TVSetupSheet` shows them).
@MainActor
@Observable
public final class TVSetupPhoneFlow {
    public enum Step: Equatable, Sendable {
        /// Which account, Continue or Cancel.
        case choosing
        /// The account went to the TV; it starts its login.
        case waitingForTV
        /// The TV's login page, to be opened in the browser for the user to grant access.
        case grantInBrowser(URL)
        case done(name: String)
        case failed(String)
    }

    public private(set) var step = Step.choosing
    public let request: TVSetupRequest
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(request: TVSetupRequest) {
        self.request = request
    }

    /// Sends the account and follows the TV until it is signed in or gives up.
    public func choose(_ account: Account) {
        guard step == .choosing else { return }
        step = .waitingForTV
        let channel = request.channel
        task = Task {
            do {
                try await channel.send(.account(serverURL: account.serverURL, loginName: account.loginName))
                var iterator = channel.messages.makeAsyncIterator()
                following: while !Task.isCancelled {
                    let message = try await channel.next(in: &iterator)
                    guard let next = Self.step(after: message, account: account) else { continue }
                    step = next
                    switch (message, next) {
                    case (_, .grantInBrowser):
                        continue following
                    case (.login, .failed):
                        // A login page of another server: the TV hears why nothing happens.
                        try? await channel.send(.failed(reason: TVSetupWording.wrongServer))
                    default:
                        break
                    }
                    break following
                }
            } catch {
                if !Task.isCancelled { step = .failed(TVSetupWording.connectionLost) }
            }
            channel.close()
        }
    }

    /// What a message from the TV means for the phone (nil: nothing changes).
    nonisolated static func step(after message: TVSetup.Message, account: Account) -> Step? {
        switch message {
        case .login(let url):
            TVSetup.isLoginPage(url, of: account.serverURL)
                ? .grantInBrowser(TVSetup.loginPage(url, user: account.loginName)) : .failed(TVSetupWording.wrongServer)
        case .done(let name): .done(name: name)
        case .failed(let reason): .failed(reason)
        case .cancel: .failed(TVSetupWording.cancelledOnTV)
        case .hello, .account: nil
        }
    }

    /// The user closed the browser or the sheet: the TV goes back to its start.
    public func cancel() {
        let channel = request.channel
        task?.cancel()
        Task {
            try? await channel.send(.cancel)
            channel.close()
        }
        if case .done = step { return }
        step = .failed(TVSetupWording.cancelled)
    }
}

/// The TV's side: what it says and hears once the user picked a device (`TVLoginView`).
public final class TVSetupTVFlow: Sendable {
    public let channel: TVSetupChannel
    /// False for a channel whose connection is already started (tests).
    private let startsChannel: Bool

    public init(endpoint: NWEndpoint, debugBonjour: Bool = TVSetup.usesDebugBonjour) {
        channel = TVSetupChannel(NWConnection(to: endpoint, using: TVSetup.parameters(debugBonjour: debugBonjour)))
        startsChannel = true
    }

    /// Over a channel that is already started.
    init(channel: TVSetupChannel) {
        self.channel = channel
        startsChannel = false
    }

    /// Says hello and waits for the account the user chose on the phone.
    public func begin(device: String) async throws -> (serverURL: URL, loginName: String) {
        if startsChannel { channel.start() }
        try await channel.send(.hello(version: TVSetup.version, device: device))
        var iterator = channel.messages.makeAsyncIterator()
        while true {
            switch try await channel.next(in: &iterator) {
            case .account(let serverURL, let loginName): return (serverURL, loginName)
            case .failed(let reason): throw TVSetupFailure.phone(reason)
            case .cancel: throw TVSetupFailure.cancelled
            default: continue
            }
        }
    }

    /// Waits until the phone gives up (Cancel, the browser closed, the connection lost); returns then.
    public func phoneGaveUp() async -> TVSetupFailure {
        var iterator = channel.messages.makeAsyncIterator()
        while true {
            do {
                switch try await channel.next(in: &iterator) {
                case .cancel: return .cancelled
                case .failed(let reason): return .phone(reason)
                default: continue
                }
            } catch {
                return .connectionLost
            }
        }
    }

    public func send(_ message: TVSetup.Message) async {
        try? await channel.send(message)
    }

    public func close() {
        channel.close()
    }
}

public enum TVSetupFailure: Error, Equatable, Sendable {
    case phone(String)
    case cancelled
    case connectionLost
}

/// What the phone tells the TV or the user (shown on either side).
public enum TVSetupWording {
    public static var busy: String {
        String(
            localized: "The iPhone is already setting up another Apple TV.", bundle: .module,
            comment: "TV set-up: a second Apple TV asked while one is being set up.")
    }

    public static var otherVersion: String {
        String(
            localized: "Update Nextcloud Photos on both devices, then try again.", bundle: .module,
            comment: "TV set-up: the TV and the phone run versions of the app that do not understand each other.")
    }

    public static var wrongServer: String {
        String(
            localized: "Apple TV asked to log in to another server than the one chosen. Nothing was opened.", bundle: .module,
            comment: "TV set-up: the TV sent a login page of another server; the phone refused it.")
    }

    public static var cancelledOnTV: String {
        String(localized: "The set-up was cancelled on Apple TV.", bundle: .module, comment: "TV set-up: the TV went back.")
    }

    public static var cancelled: String {
        String(localized: "The set-up was cancelled.", bundle: .module, comment: "TV set-up: the user cancelled it.")
    }

    public static var connectionLost: String {
        String(
            localized: "The connection to Apple TV was lost. Try again from Apple TV.", bundle: .module,
            comment: "TV set-up: the local connection between the devices ended.")
    }

    public static var noAccount: String {
        String(
            localized: "Log in to Nextcloud Photos on your iPhone first.", bundle: .module,
            comment: "TV set-up: the phone the user picked has no account in the app.")
    }
}
