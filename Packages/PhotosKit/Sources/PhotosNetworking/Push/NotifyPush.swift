// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog

/// Nextcloud's optional `notify_push` app (SPEC §22.4.3): a WebSocket on which the server says at once that files of
/// the user changed. Without it (most servers) nothing happens and the periodic sync stays as it is.
///
/// Protocol (notify_push 0.6–1.x): connect to the WebSocket endpoint of the capability, send the login name and the app
/// password as two text messages, wait for `authenticated`; `listen notify_file_id` asks for the ids of changed files
/// (servers that do not know it keep sending `notify_file`). Messages: `notify_file`, `notify_file_id [1,2]`,
/// `notify_activity`, `notify_notification`; an error is `err: …`.
public enum NotifyPush {
    /// The WebSocket endpoint the server announces, or nil when the app is not there.
    public static func endpoint(capabilities: JSONValue) -> URL? {
        guard let string = capabilities["capabilities", "notify_push", "endpoints", "websocket"]?.string,
            let url = URL(string: string), ["ws", "wss"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        return url
    }

    /// Reads the capabilities: the endpoint, or nil (no `notify_push`, or the capabilities cannot be read).
    public static func endpoint(ocs: OCSClient) async throws -> URL? {
        let capabilities: JSONValue = try await ocs.request("GET", "ocs/v2.php/cloud/capabilities")
        return endpoint(capabilities: capabilities)
    }

    /// What the server said.
    public enum Event: Sendable, Equatable {
        /// Files changed; the ids when the server sends them (`notify_file_id`), else empty.
        case filesChanged([Int64])
        case activity
        case notification
    }

    /// One message, nil for what the app does not use.
    public static func event(from message: String) -> Event? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "notify_file" { return .filesChanged([]) }
        if text.hasPrefix("notify_file_id") {
            let list = text.dropFirst("notify_file_id".count).trimmingCharacters(in: .whitespaces)
            let ids = (try? JSONDecoder().decode([Int64].self, from: Data(list.utf8))) ?? []
            return .filesChanged(ids)
        }
        if text == "notify_activity" { return .activity }
        if text == "notify_notification" { return .notification }
        return nil
    }
}

/// A WebSocket as the push client uses it; `URLSessionWebSocketTask` in the app, a fake in tests.
public protocol NotifyPushSocket: Sendable {
    func send(_ text: String) async throws
    /// The next text message; nil when the connection was closed.
    func receive() async throws -> String?
    func close()
}

/// `URLSessionWebSocketTask` on the account's session (its trust and client certificate handling).
public final class URLSessionNotifyPushSocket: NotifyPushSocket {
    private let task: URLSessionWebSocketTask

    public init(url: URL, session: URLSession, userAgent: String) {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        task = session.webSocketTask(with: request)
        task.resume()
    }

    public func send(_ text: String) async throws { try await task.send(.string(text)) }

    public func receive() async throws -> String? {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return nil
        }
    }

    public func close() { task.cancel(with: .goingAway, reason: nil) }
}

/// Keeps one `notify_push` connection open while `run` runs, reconnecting after a while when it drops, and reports
/// changes. Gives up for good when the server refuses the credentials.
public struct NotifyPushListener: Sendable {
    public typealias SocketFactory = @Sendable (URL) -> any NotifyPushSocket

    let endpoint: URL
    let loginName: String
    let password: String
    let makeSocket: SocketFactory
    /// The wait before the n-th reconnection (n from 0), at most the last value.
    let backoff: [Duration]
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "push")

    public init(
        endpoint: URL, loginName: String, password: String,
        backoff: [Duration] = [.seconds(5), .seconds(30), .seconds(120), .seconds(600)],
        makeSocket: @escaping SocketFactory
    ) {
        self.endpoint = endpoint
        self.loginName = loginName
        self.password = password
        self.backoff = backoff
        self.makeSocket = makeSocket
    }

    /// How a connection ended.
    public enum End: Sendable, Equatable {
        /// The server refused the login (`err: …` instead of `authenticated`): not tried again.
        case refused(String)
        /// The connection dropped or could not be made: tried again after the backoff.
        case dropped
    }

    /// Connects, reports events, reconnects; returns when the calling task is cancelled or the login is refused.
    public func run(onConnected: @escaping @Sendable () async -> Void = {}, _ onEvent: @escaping @Sendable (NotifyPush.Event) async -> Void)
        async -> End?
    {
        var failures = 0
        while !Task.isCancelled {
            let (end, connected) = await connectOnce(onConnected: onConnected, onEvent)
            if case .refused = end { return end }
            if connected { failures = 0 }
            guard !Task.isCancelled else { return nil }
            let wait = backoff.isEmpty ? Duration.seconds(60) : backoff[min(failures, backoff.count - 1)]
            failures += 1
            logger.info("notify_push: connection dropped, again in \(wait.components.seconds) s")
            try? await Task.sleep(for: wait)
        }
        return nil
    }

    /// One connection: login, then messages until it closes. `connected`: the login went through.
    func connectOnce(onConnected: @Sendable () async -> Void, _ onEvent: @Sendable (NotifyPush.Event) async -> Void) async -> (
        end: End, connected: Bool
    ) {
        let socket = makeSocket(endpoint)
        defer { socket.close() }
        return await withTaskCancellationHandler {
            var connected = false
            do {
                try await socket.send(loginName)
                try await socket.send(password)
                guard let answer = try await socket.receive() else { return (.dropped, false) }
                if answer.hasPrefix("err") {
                    logger.notice("notify_push: login refused (\(answer, privacy: .public))")
                    return (.refused(answer), false)
                }
                guard answer == "authenticated" else { return (.dropped, false) }
                connected = true
                // Ids of the changed files where the server knows the request; older ones ignore it.
                try await socket.send("listen notify_file_id")
                await onConnected()
                while !Task.isCancelled, let message = try await socket.receive() {
                    if let event = NotifyPush.event(from: message) { await onEvent(event) }
                }
                return (.dropped, connected)
            } catch {
                return (.dropped, connected)
            }
        } onCancel: {
            socket.close()
        }
    }
}
