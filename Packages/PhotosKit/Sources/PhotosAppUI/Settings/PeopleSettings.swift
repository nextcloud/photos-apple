// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosStore
import SwiftUI

/// Settings for People on this device and birthdays from Contacts (SPEC §22.3), on the page of the on-device analysis.
struct PeopleSettingsSections: View {
    @Environment(SessionModel.self) private var session
    @AppStorage(DevicePeopleIndexing.enabledKey) private var devicePeople = true
    @AppStorage(ContactBirthdays.enabledKey) private var birthdays = true
    @State private var progress: (scanned: Int, total: Int, faces: Int)?

    var body: some View {
        // With Recognize on the server its people are used, and there is nothing to switch here.
        if !session.features.has(.recognize) {
            Section {
                Toggle(
                    String(localized: "Find people on this device", bundle: .module, comment: "Settings: People without Recognize."),
                    isOn: $devicePeople)
                if devicePeople, let progress {
                    LabeledContent(
                        String(localized: "Photos looked at", bundle: .module),
                        value: String(
                            localized: "\(progress.scanned.formatted()) of \(progress.total.formatted())", bundle: .module,
                            comment: "Progress of the on-device recognition: photos looked at of all photos"))
                }
            } footer: {
                Text(Self.devicePeopleNote)
            }
            .onChange(of: devicePeople) { _, enabled in
                DevicePeopleIndexing.apply(enabled: enabled, services: session.services)
                loadProgress()
            }
            .task { loadProgress() }
        }
        Section {
            Toggle(
                String(
                    localized: "Birthdays from Contacts", bundle: .module, comment: "Settings: birthday memories from Nextcloud Contacts."),
                isOn: $birthdays)
        } footer: {
            Text(
                "Birthdays of the people you named are read from your Nextcloud Contacts, for memories like “Anna's birthday” and a reminder on the day. Your contacts are only read, never changed. Turning this off deletes the birthdays read.",
                bundle: .module, comment: "Settings: footer of Birthdays from Contacts.")
        }
        .onChange(of: birthdays) { _, enabled in
            Task { await ContactBirthdays.apply(enabled: enabled, session: session) }
        }
    }

    func loadProgress() {
        guard let services = session.services else { return }
        progress = try? DeviceFaceStore(database: services.database).progress()
    }

    /// What happens, in the platform's words.
    static var devicePeopleNote: String {
        #if os(macOS)
            String(
                localized:
                    "Your Nextcloud has no face recognition, so your Mac finds the people in your photos itself, with Apple's Vision, from the previews it has, while it is idle. Nothing is uploaded for it. Turning this off deletes the faces found.",
                bundle: .module, comment: "Settings, Mac: People on this device.")
        #else
            String(
                localized:
                    "Your Nextcloud has no face recognition, so this app finds the people in your photos itself, with Apple's Vision, from the previews it has, mostly while charging. Nothing is uploaded for it. Turning this off deletes the faces found.",
                bundle: .module, comment: "Settings, iPhone, iPad and Vision Pro: People on this device.")
        #endif
    }
}
