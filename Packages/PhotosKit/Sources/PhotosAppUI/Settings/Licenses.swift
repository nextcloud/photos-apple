// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// The licences of the app and of the code it ships with (Settings › About › Licences). The MIT licence asks that its
/// notice is included with every copy of the software: the app shows it here.
struct LicensesView: View {
    var body: some View {
        Form {
            ForEach(Acknowledgement.all) { acknowledgement in
                Section {
                    Text(verbatim: acknowledgement.text)
                        .font(.footnote)
                        .textSelection(.enabled)
                } header: {
                    Text(verbatim: acknowledgement.name)
                } footer: {
                    Link(acknowledgement.url.absoluteString, destination: acknowledgement.url)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Licences", bundle: .module))
    }
}

/// A component and its licence text, quoted verbatim (not translated).
struct Acknowledgement: Identifiable, Sendable {
    var id: String { name }
    var name: String
    var url: URL
    var text: String

    static let all: [Acknowledgement] = [app, grdb]

    static let app = Acknowledgement(
        name: "Nextcloud Photos", url: URL(string: "https://github.com/nextcloud/photos-apple")!,
        text: mit(copyright: "Copyright (c) 2026 Nextcloud"))

    /// The SQLite toolkit the app's database is built on (`Packages/PhotosKit/Package.swift`).
    static let grdb = Acknowledgement(
        name: "GRDB.swift", url: URL(string: "https://github.com/groue/GRDB.swift")!,
        text: mit(copyright: "Copyright (C) 2015-2025 Gwendal Roué"))

    /// The MIT licence with a copyright line, in the wording of the projects' LICENSE files.
    static func mit(copyright: String) -> String {
        """
        \(copyright)

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated \
        documentation files (the "Software"), to deal in the Software without restriction, including without limitation \
        the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to \
        permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of \
        the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO \
        THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF \
        CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS \
        IN THE SOFTWARE.
        """
    }
}
