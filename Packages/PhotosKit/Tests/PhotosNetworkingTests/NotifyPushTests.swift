// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Network
import Synchronization
import Testing

@testable import PhotosNetworking

/// The `notify_push` client (SPEC §22.4.3): what it reads from the capabilities and the messages, the login, the
/// reconnection, and a real WebSocket against a local stand-in of the push server.
@Suite(.timeLimit(.minutes(1))) struct NotifyPushTests {
    @Test func endpointComesFromTheCapabilities() throws {
        func capabilities(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }
        let with = try capabilities(
            #"{"capabilities":{"notify_push":{"type":["files","activities","notifications"],"endpoints":{"websocket":"wss://cloud.example.com/push/ws","pre_auth":"https://cloud.example.com/apps/notify_push/pre_auth"}}}}"#
        )
        #expect(NotifyPush.endpoint(capabilities: with) == URL(string: "wss://cloud.example.com/push/ws"))
        #expect(NotifyPush.endpoint(capabilities: try capabilities(#"{"capabilities":{"files":{}}}"#)) == nil)
        #expect(
            NotifyPush.endpoint(
                capabilities: try capabilities(#"{"capabilities":{"notify_push":{"endpoints":{"websocket":"https://x/push/ws"}}}}"#))
                == nil)
    }

    @Test func messages() {
        #expect(NotifyPush.event(from: "notify_file") == .filesChanged([]))
        #expect(NotifyPush.event(from: "notify_file_id [12,345]") == .filesChanged([12, 345]))
        #expect(NotifyPush.event(from: "notify_file_id garbage") == .filesChanged([]))
        #expect(NotifyPush.event(from: "notify_activity") == .activity)
        #expect(NotifyPush.event(from: "notify_notification") == .notification)
        #expect(NotifyPush.event(from: "authenticated") == nil)
    }

    /// A socket that plays a script: what the server answers, and what the client sent.
    final class ScriptedSocket: NotifyPushSocket {
        let incoming: Mutex<[String]>
        let sent = Mutex<[String]>([])
        let closed = Mutex(false)
        init(_ incoming: [String]) { self.incoming = Mutex(incoming) }
        func send(_ text: String) async throws { sent.withLock { $0.append(text) } }
        func receive() async throws -> String? {
            incoming.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }
        func close() { closed.withLock { $0 = true } }
    }

    @Test func logsInListensAndReportsChanges() async {
        let socket = ScriptedSocket(["authenticated", "notify_activity", "notify_file_id [7]", "notify_file"])
        let events = Mutex<[NotifyPush.Event]>([])
        let listener = NotifyPushListener(endpoint: URL(string: "wss://x/push/ws")!, loginName: "alice", password: "app-password") { _ in
            socket
        }
        let (end, connected) = await listener.connectOnce(onConnected: {}) { event in events.withLock { $0.append(event) } }
        #expect(end == .dropped)
        #expect(connected)
        #expect(socket.sent.withLock { $0 } == ["alice", "app-password", "listen notify_file_id"])
        #expect(events.withLock { $0 } == [.activity, .filesChanged([7]), .filesChanged([])])
        #expect(socket.closed.withLock { $0 })
    }

    /// Wrong credentials: given up for good, no reconnection.
    @Test func refusedLoginIsNotTriedAgain() async {
        let made = Mutex(0)
        let listener = NotifyPushListener(
            endpoint: URL(string: "wss://x/push/ws")!, loginName: "alice", password: "wrong", backoff: [.milliseconds(1)]
        ) { _ in
            made.withLock { $0 += 1 }
            return ScriptedSocket(["err: Invalid credentials"])
        }
        let end = await listener.run { _ in }
        #expect(end == .refused("err: Invalid credentials"))
        #expect(made.withLock { $0 } == 1)
    }

    /// A dropped connection is made again after the backoff, until the task is cancelled.
    @Test func droppedConnectionIsMadeAgain() async {
        let made = Mutex(0)
        let listener = NotifyPushListener(
            endpoint: URL(string: "wss://x/push/ws")!, loginName: "alice", password: "pw", backoff: [.milliseconds(5)]
        ) { _ in
            made.withLock { $0 += 1 }
            return ScriptedSocket(["authenticated"])
        }
        let task = Task { await listener.run { _ in } }
        let deadline = Date().addingTimeInterval(5)
        while made.withLock({ $0 }) < 3, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        #expect(await task.value == nil)
        #expect(made.withLock { $0 } >= 3)
    }

    /// The real transport (`URLSessionWebSocketTask`) against a local WebSocket server speaking the push protocol.
    @Test func realWebSocketAgainstALocalPushServer() async throws {
        let server = try LocalPushServer(password: "app-password", afterLogin: ["notify_file_id [41,42]", "notify_file"])
        let port = try await server.start()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        let events = Mutex<[NotifyPush.Event]>([])
        let listener = NotifyPushListener(
            endpoint: URL(string: "ws://127.0.0.1:\(port)/push/ws")!, loginName: "alice", password: "app-password"
        ) { url in URLSessionNotifyPushSocket(url: url, session: session, userAgent: "tests") }
        let task = Task {
            await listener.run { event in events.withLock { $0.append(event) } }
        }
        let deadline = Date().addingTimeInterval(10)
        while events.withLock({ $0.count }) < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()
        _ = await task.value
        #expect(events.withLock { $0 } == [.filesChanged([41, 42]), .filesChanged([])])
        #expect(server.received.withLock { $0 } == ["alice", "app-password", "listen notify_file_id"])
    }
}

/// A WebSocket server on the loopback interface that answers like `notify_push`: login, then the scripted messages.
final class LocalPushServer: Sendable {
    let listener: NWListener
    let password: String
    let afterLogin: [String]
    let received = Mutex<[String]>([])
    private let queue = DispatchQueue(label: "local-push-server")

    init(password: String, afterLogin: [String]) throws {
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.password = password
        self.afterLogin = afterLogin
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.withLock({
                        let first = !$0; $0 = true; return first
                    }) {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    if resumed.withLock({
                        let first = !$0; $0 = true; return first
                    }) {
                        continuation.resume(throwing: error)
                    }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [self] content, _, _, error in
            guard error == nil, let content else { return }
            let text = String(decoding: content, as: UTF8.self)
            let count = received.withLock { list in
                list.append(text)
                return list.count
            }
            if count == 2 { send(text == password ? "authenticated" : "err: Invalid credentials", on: connection) }
            if count == 3 { for message in afterLogin { send(message, on: connection) } }
            receive(connection)
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }
}
