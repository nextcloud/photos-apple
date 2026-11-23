// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Uploads items one after the other and stops at the first failure, so the caller can show it and offer to try the
/// rest again (the share extension, SPEC §7.24).
public enum SequentialUploads {
    public struct Result<Item> {
        /// What was not uploaded, the failed item first.
        public var remaining: [Item]
        public var error: (any Error)?
    }

    /// - Parameters:
    ///   - upload: uploads one item.
    ///   - done: called after each item that was uploaded, before the next one starts.
    @MainActor
    public static func run<Item: Sendable>(
        _ items: [Item], upload: @MainActor (Item) async throws -> Void, done: @MainActor (Item) -> Void
    ) async -> Result<Item> {
        for (index, item) in items.enumerated() {
            do {
                try await upload(item)
            } catch {
                return Result(remaining: Array(items[index...]), error: error)
            }
            done(item)
        }
        return Result(remaining: [], error: nil)
    }
}
