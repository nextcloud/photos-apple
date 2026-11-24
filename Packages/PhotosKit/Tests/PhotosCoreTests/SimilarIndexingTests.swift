// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosCore

/// When the indexing for "Show Similar" may run in the foreground (SPEC §15.5).
@Suite struct SimilarIndexingTests {
    func conditions(lowPower: Bool = false, thermal: ProcessInfo.ThermalState = .nominal, battery: Float? = nil, charging: Bool = false)
        -> SimilarIndexing.Conditions
    {
        SimilarIndexing.Conditions(isLowPowerMode: lowPower, thermalState: thermal, batteryLevel: battery, isCharging: charging)
    }

    @Test func foregroundWorkFollowsPowerAndHeat() {
        #expect(conditions().allowsForegroundWork)
        #expect(conditions(thermal: .fair).allowsForegroundWork)
        #expect(!conditions(lowPower: true).allowsForegroundWork)
        #expect(!conditions(thermal: .serious).allowsForegroundWork)
        #expect(!conditions(lowPower: true, charging: true).allowsForegroundWork)
        // On battery: only above a third.
        #expect(conditions(battery: 0.8).allowsForegroundWork)
        #expect(!conditions(battery: 0.2).allowsForegroundWork)
        #expect(conditions(battery: 0.2, charging: true).allowsForegroundWork)
        // Unknown level (-1 from UIKit): allowed.
        #expect(conditions(battery: -1).allowsForegroundWork)
    }

    @Test func onByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "similar-\(UUID().uuidString)"))
        #expect(SimilarIndexing.isEnabled(defaults))
        defaults.set(false, forKey: SimilarIndexing.enabledKey)
        #expect(!SimilarIndexing.isEnabled(defaults))
    }
}
