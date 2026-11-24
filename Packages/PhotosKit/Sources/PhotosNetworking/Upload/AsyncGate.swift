// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Synchronization

/// Lets one task at a time through, in the order they came (an async mutex). An actor's work on a chunked upload waits
/// for the network in the middle; without the gate a report of the system and a hand-over could work on two copies of the
/// same upload's state, and one would overwrite the other.
public final class AsyncGate: Sendable {
    private struct State {
        var busy = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// Waits until no other task is inside.
    public func enter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state in
                guard state.busy else {
                    state.busy = true
                    return true
                }
                state.waiting.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Lets the next waiting task in.
    public func leave() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiting.isEmpty else {
                state.busy = false
                return nil
            }
            return state.waiting.removeFirst()
        }
        next?.resume()
    }
}
