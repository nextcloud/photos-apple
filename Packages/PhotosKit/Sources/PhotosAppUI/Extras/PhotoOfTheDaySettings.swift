// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import SwiftUI

/// Settings › Photo of the Day (SPEC §15.8.4): off by default; on asks for permission to notify, and the time is the user's.
struct PhotoOfTheDaySettingsSection: View {
    @Environment(SessionModel.self) private var session
    @AppStorage(PhotoOfTheDaySettings.enabledKey) private var enabled = false
    @AppStorage(PhotoOfTheDaySettings.timeKey) private var minutes = PhotoOfTheDaySettings.defaultTime
    @State private var denied = false

    /// The chosen time as a date today, for the time picker.
    var time: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
            })
    }

    var body: some View {
        Section {
            Toggle(
                String(localized: "Photo of the Day", bundle: .module, comment: "Switch in Settings for the daily photo notification."),
                isOn: $enabled
            )
            .onChange(of: enabled) { _, on in
                Task {
                    if on, !(await PhotoOfTheDayNotifications.requestAuthorization()) {
                        denied = true
                        enabled = false
                    }
                    await session.photoOfTheDaySettingsChanged()
                }
            }
            if enabled {
                DatePicker(
                    String(localized: "Time", bundle: .module, comment: "Time of day of the daily photo notification."), selection: time,
                    displayedComponents: .hourAndMinute
                )
                .onChange(of: minutes) { _, _ in Task { await session.photoOfTheDaySettingsChanged() } }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Every day at this time, a photo taken on this day in an earlier year, or one of your favorites. Archived photos are never shown; with app lock on, the notification doesn't show the photo.",
                    bundle: .module, comment: "Footer of the Photo of the Day setting.")
                if denied {
                    Text(
                        "Notifications are turned off for Nextcloud Photos in System Settings.", bundle: .module,
                        comment: "Shown when turning on Photo of the Day while the app may not notify."
                    )
                    .foregroundStyle(.red)
                }
            }
        }
    }
}
