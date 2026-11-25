// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import FoundationModels
import PhotosDomain

/// Words moment titles with the on-device language model (Apple Intelligence), where it is available and speaks the
/// user's language (SPEC §16.1). Nothing leaves the device. Every answer goes through `MomentTitleWording.cleaned`; the
/// rule title stays when the model is not available, refuses, or answers something unusable.
@MainActor
final class MomentTitleWriter {
    static var isAvailable: Bool {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return model.supportsLocale(Locale.current)
    }

    /// The worded title, or nil when the answer is not usable. Throws when the model failed (it is not ready, or not
    /// allowed here): the caller stops asking for this build.
    func title(for facts: MomentFacts) async throws -> String? {
        // Each moment on its own: what came before must not leak into the next title.
        let session = LanguageModelSession(instructions: MomentTitleWording.instructions())
        do {
            let answer = try await session.respond(
                to: MomentTitleWording.prompt(facts), options: GenerationOptions(temperature: 0.5, maximumResponseTokens: 24))
            return MomentTitleWording.cleaned(answer.content, facts: facts)
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            // This moment's facts only: the rule title stays, the next moment is asked.
            return nil
        }
    }
}
