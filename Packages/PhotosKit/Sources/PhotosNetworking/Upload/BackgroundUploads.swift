// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// How an upload that was handed to the system ended.
public struct BackgroundUploadEvent: Sendable {
    /// The id the upload was started with.
    public var jobId: String
    /// The server's answer. Its body is only there when the app was running while it arrived; status and headers always are.
    public var response: HTTPResponse?
    /// Set when there is no answer.
    public var error: NetworkError?

    public init(jobId: String, response: HTTPResponse? = nil, error: NetworkError? = nil) {
        self.jobId = jobId
        self.response = response
        self.error = error
    }
}

public enum BackgroundUploadSignal: Sendable {
    case finished(BackgroundUploadEvent)
    /// The system has delivered everything that finished while the app was not running. Answer with `eventsHandled()`
    /// once the events before this one are dealt with.
    case drained
}

/// Uploads that go on while the app is suspended or not running (SPEC §7.18.6). The real one is `BackgroundUploadSession`;
/// tests use a fake.
///
/// An upload is known by the id it was started with, which survives the app. Nothing else does: whoever starts uploads
/// keeps its own record of what an id stands for.
public protocol BackgroundUploading: Sendable {
    /// The name the system knows the session by.
    var identifier: String { get }

    /// What finished, in the order of arrival, for one consumer.
    var signals: AsyncStream<BackgroundUploadSignal> { get }

    /// Hands a file to the system. The file has to stay where it is until the upload has finished.
    func start(jobId: String, request: HTTPRequest, file: URL) async throws

    /// Ids of the uploads the system still works on.
    func activeJobIds() async -> Set<String>

    func cancel(jobIds: Set<String>) async

    /// The completion handler the system passed when it launched or woke the app for finished uploads. It is called when
    /// those are dealt with (`eventsHandled`).
    func setEventsCompletion(_ handler: @escaping @MainActor @Sendable () -> Void)

    /// The consumer has dealt with everything before a `.drained` signal.
    func eventsHandled()
}

/// A background `URLSession` for file uploads, with the app's trust and client certificate handling.
///
/// There is one per process and identifier. After a launch the system delivers what finished meanwhile to the delegate of
/// the session with the same identifier, so the app creates it at launch (and passes the completion handler of
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to `setEventsCompletion`).
public final class BackgroundUploadSession: BackgroundUploading {
    public let identifier: String
    public let signals: AsyncStream<BackgroundUploadSignal>
    private let session: URLSession
    private let delegate: BackgroundSessionDelegate
    private let completion = BackgroundEventsCompletion()

    /// - Parameter sharedContainer: the App Group whose container the session's files are in. An app extension needs it
    ///   (its uploads are finished by the app when the extension has ended), and so does the app when it takes over such a
    ///   session.
    public init(
        identifier: String, sharedContainer: String? = nil, trustStore: TrustStore, clientCredentials: ClientCredentialProvider? = nil
    ) {
        self.identifier = identifier
        let (signals, continuation) = AsyncStream.makeStream(of: BackgroundUploadSignal.self)
        self.signals = signals
        let delegate = BackgroundSessionDelegate(
            trust: SessionDelegate(trustStore: trustStore, clientCredentials: clientCredentials), continuation: continuation)
        self.delegate = delegate
        session = URLSession(
            configuration: Self.configuration(identifier: identifier, sharedContainer: sharedContainer), delegate: delegate,
            delegateQueue: nil)
    }

    /// Lets the uploads that were started finish and then releases the session (its identifier may be used again).
    public func finishAndInvalidate() {
        session.finishTasksAndInvalidate()
    }

    static func configuration(identifier: String, sharedContainer: String? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sharedContainerIdentifier = sharedContainer
        // Wake the app when uploads have finished, so it can hand over the next ones.
        configuration.sessionSendsLaunchEvents = true
        // The user asked for a backup; the system still schedules what is started in the background as it sees fit.
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 3
        // An upload that waits for Wi-Fi is given up after two days; the backup hands it over again.
        configuration.timeoutIntervalForResource = 2 * 24 * 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return configuration
    }

    public func start(jobId: String, request: HTTPRequest, file: URL) async throws {
        guard FileManager.default.isReadableFile(atPath: file.path(percentEncoded: false)) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: file])
        }
        let task = session.uploadTask(with: request.urlRequest, fromFile: file)
        task.taskDescription = jobId
        task.resume()
    }

    public func activeJobIds() async -> Set<String> {
        Set(await session.allTasks.filter { $0.state != .completed }.compactMap(\.taskDescription))
    }

    public func cancel(jobIds: Set<String>) async {
        for task in await session.allTasks where jobIds.contains(task.taskDescription ?? "") { task.cancel() }
    }

    public func setEventsCompletion(_ handler: @escaping @MainActor @Sendable () -> Void) {
        completion.set(handler)
    }

    public func eventsHandled() {
        completion.eventsHandled()
    }
}

/// Keeps the completion handler the system passes with `handleEventsForBackgroundURLSession` until the reports it
/// announced are dealt with. The handler is called exactly once, on the main actor.
final class BackgroundEventsCompletion: Sendable {
    struct State {
        var handler: (@MainActor @Sendable () -> Void)?
        /// When the reports were dealt with before the handler was known.
        var handledAt: Date?
    }

    private let state = Mutex(State())
    /// The handler is called after this time even when no `.drained` signal came, so the system is never left waiting.
    let limit: TimeInterval
    /// Reports that were dealt with this long ago or less count for a handler that arrives afterwards.
    let memory: TimeInterval

    init(limit: TimeInterval = 20, memory: TimeInterval = 10) {
        self.limit = limit
        self.memory = memory
    }

    func set(_ handler: @escaping @MainActor @Sendable () -> Void) {
        let callNow = state.withLock { state in
            // The session exists from the launch on, so the reports may have been delivered and dealt with before the
            // system told the app about them.
            if let handledAt = state.handledAt, Date().timeIntervalSince(handledAt) < memory {
                state.handledAt = nil
                return true
            }
            state.handler = handler
            return false
        }
        if callNow {
            Task { @MainActor in handler() }
            return
        }
        let limit = limit
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            self?.call()
        }
    }

    func eventsHandled() {
        if !call() { state.withLock { $0.handledAt = Date() } }
    }

    @discardableResult
    private func call() -> Bool {
        let handler = state.withLock { state in
            defer { state.handler = nil }
            return state.handler
        }
        guard let handler else { return false }
        Task { @MainActor in handler() }
        return true
    }
}

/// Turns the delegate callbacks of the background session into signals.
final class BackgroundSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    let trust: SessionDelegate
    let continuation: AsyncStream<BackgroundUploadSignal>.Continuation
    /// Answer bodies by task identifier (error messages; a successful PUT has none worth keeping).
    private let bodies = Mutex<[Int: Data]>([:])
    static let maxBody = 64 * 1024

    init(trust: SessionDelegate, continuation: AsyncStream<BackgroundUploadSignal>.Continuation) {
        self.trust = trust
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        trust.handle(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        trust.handle(challenge)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bodies.withLock { bodies in
            let room = Self.maxBody - (bodies[dataTask.taskIdentifier]?.count ?? 0)
            if room > 0 { bodies[dataTask.taskIdentifier, default: Data()].append(data.prefix(room)) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let body = bodies.withLock { $0.removeValue(forKey: task.taskIdentifier) } ?? Data()
        // Not one of ours (no id): nothing to report.
        guard let jobId = task.taskDescription else { return }
        continuation.yield(
            .finished(
                Self.event(jobId: jobId, response: task.response, body: body, error: error, url: task.originalRequest?.url, trust: trust)))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        continuation.yield(.drained)
    }

    static func event(jobId: String, response: URLResponse?, body: Data, error: (any Error)?, url: URL?, trust: SessionDelegate)
        -> BackgroundUploadEvent
    {
        if let error {
            let mapped = trust.networkError(for: error, url: url ?? URL(fileURLWithPath: "/"))
            return BackgroundUploadEvent(jobId: jobId, error: mapped)
        }
        guard let response else { return BackgroundUploadEvent(jobId: jobId, error: .invalidResponse("no response")) }
        return BackgroundUploadEvent(jobId: jobId, response: HTTPClient.makeResponse(response, data: body))
    }
}
