// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Decides what folder rules do in one run (SPEC §16.4). Pure: the runner (`FolderRuleRunner`, PhotosCore) reads the
/// index, holds the lease, performs the actions through the outbox and records them.
public enum FolderRulePlanner {
    public struct Step: Hashable, Sendable {
        public var rule: FolderRule
        public var fileIds: [FileID]
    }

    /// The most photos one rule acts on in a run; the rest follow in the next runs, so a rule that matches thousands
    /// of photos does not flood the outbox.
    public static let maxPerRun = 500

    /// The photos each runnable rule acts on now: matching, not handled before, new enough (unless the rule includes
    /// existing photos), and not already in the state the action makes.
    public static func plan(
        rules: [FolderRule], items: [MediaItem], context: SmartRuleContext, state: FolderRuleState
    ) -> [Step] {
        var steps: [Step] = []
        for rule in rules where rule.isRunnable {
            let handled = Set(state.handled[rule.id] ?? [])
            var fileIds: [FileID] = []
            for item in items {
                guard !handled.contains(item.fileId), !item.isLivePhotoVideo, !item.isArchived else { continue }
                if !rule.includesExisting, (item.uploadedAt ?? item.modifiedAt) < rule.createdAt { continue }
                guard !isDone(rule.action, item, context: context) else { continue }
                guard canAct(rule.action, on: item) else { continue }
                guard SmartRuleEvaluator.matches(rule.rule, item, in: context) else { continue }
                fileIds.append(item.fileId)
                if fileIds.count >= maxPerRun { break }
            }
            if !fileIds.isEmpty { steps.append(Step(rule: rule, fileIds: fileIds)) }
        }
        return steps
    }

    /// The photo already is as the action would make it.
    static func isDone(_ action: FolderRule.Action, _ item: MediaItem, context: SmartRuleContext) -> Bool {
        switch action {
        case .favorite: item.isFavorite
        case .archive: item.isArchived
        case .addToAlbum(let name): context.albumMembers[SmartRuleContext.fold(name)]?.contains(item.fileId) ?? false
        case .addTag(let name): context.tagMembers[SmartRuleContext.fold(name)]?.contains(item.fileId) ?? false
        }
    }

    /// Only the user's own files can go into albums or the archive (SPEC AL-4, §7.13).
    static func canAct(_ action: FolderRule.Action, on item: MediaItem) -> Bool {
        switch action {
        case .addToAlbum, .archive: item.isOwnStorage
        case .favorite, .addTag: !item.isCollectionChild
        }
    }
}
