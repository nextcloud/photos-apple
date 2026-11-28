// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Photos
import PhotosCore
import Testing

@testable import PhotosAppUI

/// The first run in three steps and the tips that replace everything else it used to ask (SPEC §22.2).
@Suite struct FirstRunTests {
    @Test func accessToThePhotosTurnsBackupOnInTheSameTap() {
        #expect(FirstRun.afterAccess(.authorized, filesApp: .none) == .turnOn)
        #expect(FirstRun.afterAccess(.limited, filesApp: .none) == .turnOn)
        // With the Files app there, its question comes first (photos it uploaded are not uploaded twice).
        #expect(FirstRun.afterAccess(.authorized, filesApp: .installed) == .askAboutFilesApp)
        #expect(FirstRun.afterAccess(.authorized, filesApp: .usedForThisAccount) == .askAboutFilesApp)
        #expect(FirstRun.afterAccess(.denied, filesApp: .none) == .explainDenied)
        #expect(FirstRun.afterAccess(.restricted, filesApp: .none) == .explainDenied)
        #expect(FirstRun.afterAccess(.notDetermined, filesApp: .none) == .explainDenied)
    }

    @MainActor @Test func theFirstRunHasThreeStepsWhereBackupIsOffered() {
        #if os(iOS)
            #expect(FirstRun.stepCount(backupAvailable: true) == 3)
        #else
            #expect(FirstRun.stepCount(backupAvailable: true) == 2)
        #endif
        #expect(FirstRun.stepCount(backupAvailable: false) == 2)
    }

    @Test func noTipComesOnTheFirstLaunch() {
        for kind in TipPlan.Kind.allCases {
            #expect(TipPlan.fromLaunch(kind) >= 2, "\(kind)")
        }
        // Every tip is in the Library's order exactly once.
        #expect(Set(TipPlan.order) == Set(TipPlan.Kind.allCases))
        #expect(TipPlan.order.count == TipPlan.Kind.allCases.count)
        // What the first run no longer asks comes first.
        #expect(TipPlan.order.prefix(2) == [.backup, .notifications])
    }

    @Test func eachPlatformGetsTheTipsItHas() {
        #expect(TipPlan.isOffered(.menuBar, on: .mac))
        #expect(!TipPlan.isOffered(.menuBar, on: .phone))
        #expect(!TipPlan.isOffered(.menuBar, on: .pad))
        #expect(!TipPlan.isOffered(.backup, on: .vision))
        for platform: TipPlan.Platform in [.phone, .pad, .mac, .vision] {
            #expect(TipPlan.isOffered(.notifications, on: platform))
            #expect(TipPlan.isOffered(.importLibrary, on: platform))
            #expect(TipPlan.isOffered(.cleanUp, on: platform))
            #expect(TipPlan.isOffered(.advancedFeatures, on: platform))
        }
    }

    @Test func launchesAreCounted() throws {
        let defaults = try #require(UserDefaults(suiteName: "FirstRunTests-\(UUID().uuidString)"))
        #expect(AppTips.countLaunch(defaults) == 1)
        #expect(AppTips.countLaunch(defaults) == 2)
        #expect(defaults.integer(forKey: AppTips.launchesKey) == 2)
    }
}
