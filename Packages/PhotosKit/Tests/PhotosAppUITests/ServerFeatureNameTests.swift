// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import Testing

@testable import PhotosAppUI

/// The feature names under Settings › Server features are localisable.
@Suite struct ServerFeatureNameTests {
    @Test func everyFeatureHasItsOwnNameInTheStringCatalog() throws {
        let catalog = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/PhotosAppUI/Resources/Localizable.xcstrings").standardized
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any]
        let keys = Set((json?["strings"] as? [String: Any] ?? [:]).keys)

        let names = ServerFeature.allCases.map(\.localizedName)
        #expect(Set(names).count == ServerFeature.allCases.count)
        for name in names { #expect(keys.contains(name), "\(name) is not in the PhotosAppUI string catalog") }
    }
}
