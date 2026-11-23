// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Repeats a request that failed for a reason that may be gone a moment later: a timeout, a lost connection, a 5xx, or a
/// 429/503 that says when to come back (`Retry-After`). Waits grow exponentially.
///
/// A request only gets a policy when repeating it is safe (`HTTPRequest.retry`); the uploader sets one for its PUTs and
/// lookups (SPEC §7.17).
public struct RetryPolicy: Sendable {
    /// Attempts in total, the first one included.
    public var maxAttempts: Int
    /// Wait before the second attempt; doubled for each further one.
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// The longest `Retry-After` that is waited for. A server that asks for more (maintenance mode says 120 s and means
    /// "much later") gets no further attempt: the request fails and the caller decides when to come back.
    public var maxRetryAfter: TimeInterval
    /// Tests replace the wait.
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        maxAttempts: Int = 4, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 30, maxRetryAfter: TimeInterval = 60,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxRetryAfter = maxRetryAfter
        self.sleep = sleep
    }

    /// For uploads: four attempts, 1 s, 2 s and 4 s apart.
    public static let uploads = RetryPolicy()

    /// How long to wait after the given attempt (1-based) failed, or nil when there is no further attempt.
    public func delay(afterAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        let backoff = min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
        guard let retryAfter else { return backoff }
        guard retryAfter <= maxRetryAfter else { return nil }
        return max(backoff, retryAfter)
    }

    /// Failures without an answer from the server that are worth another attempt.
    public static func isRetryable(_ error: NetworkError) -> Bool {
        switch error {
        case .timedOut, .offline, .transport, .maintenance, .rateLimited: true
        case .http(let status, _): isRetryable(status: status)
        default: false
        }
    }

    /// Answers that are worth another attempt: request timeout, too many requests, and the server-side errors that do not
    /// say "never" (501 and 507 do).
    public static func isRetryable(status: Int) -> Bool {
        switch status {
        case 408, 429, 500, 502, 503, 504: true
        default: false
        }
    }

    /// `Retry-After` in seconds; the header carries seconds or an HTTP date.
    public static func retryAfter(_ response: HTTPResponse, now: Date = Date()) -> TimeInterval? {
        guard let value = response.header("retry-after")?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        return HTTPDate.parse(value).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Runs `attempt` until it succeeds, fails for good or the attempts are used up. The last answer or error is passed on
    /// unchanged, so callers map it as they always do.
    func run(_ attempt: () async throws -> HTTPResponse) async throws -> HTTPResponse {
        var number = 1
        while true {
            let wait: TimeInterval
            do {
                let response = try await attempt()
                guard Self.isRetryable(status: response.status),
                    let delay = delay(afterAttempt: number, retryAfter: Self.retryAfter(response))
                else { return response }
                wait = delay
            } catch let error as NetworkError {
                guard Self.isRetryable(error), let delay = delay(afterAttempt: number) else { throw error }
                wait = delay
            }
            do {
                try await sleep(wait)
            } catch {
                throw NetworkError.cancelled
            }
            number += 1
        }
    }
}
