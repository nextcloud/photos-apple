// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosStore
import SwiftUI

/// "Anna's birthday" in Memories (SPEC §22.3): the named people whose birthdays are in the user's Nextcloud Contacts,
/// their photos around the day over the years, the next birthday first. On the day a card says so on top. Nothing is
/// shown without contacts, birthdays or named people.
struct BirthdaysRow: View {
    @Environment(SessionModel.self) private var session
    @AppStorage(ContactBirthdays.enabledKey) private var enabled = true
    @State private var memories: [(birthday: PersonBirthday, memory: Memory)] = []
    /// A memory zooms out of its card (SPEC §17.4).
    @Namespace private var zoom

    var today: [(birthday: PersonBirthday, memory: Memory)] {
        memories.filter { Birthdays.isToday($0.birthday.contact, now: Date(), calendar: .current) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if enabled, !memories.isEmpty {
                ForEach(today, id: \.memory.id) { entry in todayCard(entry.birthday, entry.memory) }
                Text("Birthdays", bundle: .module, comment: "Memories: heading of the people's birthday memories.")
                    .font(Typography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 16)], spacing: 16) {
                    ForEach(memories, id: \.memory.id) { entry in
                        NavigationLink {
                            MemoryScreen(memory: entry.memory).cardTransitionDestination(id: entry.memory.id, in: zoom)
                        } label: {
                            MemoryCard(memory: entry.memory).cardTransitionSource(id: entry.memory.id, in: zoom, cornerRadius: 14)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text(Self.nextLine(entry.birthday)))
                    }
                }
            }
        }
        .task(id: enabled) { await load() }
    }

    /// "Today is Anna's birthday", with their birthdays to look back at.
    func todayCard(_ birthday: PersonBirthday, _ memory: Memory) -> some View {
        NavigationLink {
            MemoryScreen(memory: memory)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "gift").font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.todayTitle(birthday)).font(.headline)
                    Text(
                        "Look back at their birthdays and send them a photo.", bundle: .module,
                        comment: "Memories: the card on a person's birthday."
                    )
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding()
            .background(.tint.opacity(0.12), in: .rect(cornerRadius: 16))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    static func todayTitle(_ birthday: PersonBirthday) -> String {
        if let age = Birthdays.age(birthday.contact, in: Calendar.current.component(.year, from: Date())) {
            return String(
                localized: "\(birthday.person) turns \(age) today", bundle: .module,
                comment: "Memories: card on a person's birthday when the year of birth is known, e.g. Anna turns 7 today.")
        }
        return String(
            localized: "Today is \(birthday.person)'s birthday", bundle: .module, comment: "Memories: card on a person's birthday.")
    }

    /// "Next birthday: 12 April", for VoiceOver.
    static func nextLine(_ birthday: PersonBirthday) -> String {
        guard let next = Birthdays.next(birthday.contact, after: Date(), calendar: .current) else { return "" }
        return String(
            localized: "Next birthday: \(next.formatted(.dateTime.day().month(.wide)))", bundle: .module,
            comment: "VoiceOver hint of a birthday memory: when the person's next birthday is.")
    }

    /// A person's date of birth from Contacts, when the contact has the year (Through the years shows the age).
    static func dateOfBirth(of person: String, session: SessionModel) -> Date? {
        guard ContactBirthdays.isEnabled(), let services = session.services,
            let contact = (try? ContactBirthdayStore(database: services.database).personBirthdays())?.first(where: { $0.person == person })?
                .contact,
            let year = contact.year
        else { return nil }
        return Birthdays.date(of: contact, in: year, calendar: .current)
    }

    func load() async {
        guard enabled, let services = session.services else {
            memories = []
            return
        }
        let database = services.database
        memories = await Task.detached(priority: .utility) {
            (try? ContactBirthdayStore(database: database).memories()) ?? []
        }.value
    }
}
