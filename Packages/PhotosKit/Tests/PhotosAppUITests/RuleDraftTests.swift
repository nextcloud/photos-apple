// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosAppUI
@testable import PhotosModel

/// The rule builder's editable form of a rule (SPEC §16.4).
@Suite struct RuleDraftTests {
    @Test func roundTripsTheShapesTheBuilderMakes() {
        let rule = SmartRule.all([
            .condition(.person("Anna")),
            .not(.condition(.flag(.reject))),
            .any([.condition(.place("Beach")), .condition(.place("Lake"))]),
            .not(.any([.condition(.mediaType(.screenshot)), .condition(.mediaType(.video))])),
        ])
        let draft = RuleDraft(rule)
        #expect(draft.mode == .all)
        #expect(draft.rows.count == 2)
        #expect(draft.rows[1].negated)
        #expect(draft.groups.map(\.mode) == [.any, .none])
        #expect(draft.rule == rule)
    }

    @Test func noneAtTheTopAndSingleConditions() {
        #expect(RuleDraft(.not(.any([.condition(.favorite)]))).mode == .none)
        let single = RuleDraft(.condition(.favorite))
        #expect(single.rule == .all([.condition(.favorite)]))
    }

    @Test func leavesOutWhatIsNotFilledIn() {
        var draft = RuleDraft()
        draft.rows = [RuleDraft.Row(condition: .camera("")), RuleDraft.Row(condition: .favorite)]
        draft.groups = [RuleDraft.Group(mode: .any, rows: [RuleDraft.Row(condition: .lens(" "))])]
        #expect(draft.rule == .all([.condition(.favorite)]))
        draft.rows.removeLast()
        #expect(draft.isEmpty)
    }

    @Test func everyKindMakesAConditionOfItsKind() {
        let vocabulary = RuleVocabulary(people: ["Anna"], places: ["Rome"])
        for kind in ConditionKind.allCases {
            #expect(ConditionKind(kind.makeCondition(vocabulary: vocabulary)) == kind)
        }
        #expect(ConditionKind.sections.flatMap { $0 }.count == ConditionKind.allCases.count)
    }
}
