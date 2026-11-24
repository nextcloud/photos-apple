// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosDomain
import PhotosModel
import SwiftUI

/// What the cards draw with: the review, the photos it shows (loaded before a card is rendered as a picture), and where
/// the faces are in the people's photos.
struct YearCardContent {
    var review: YearInReview
    var images: [FileID: CGImage] = [:]
    var focus: [FileID: FilmCrop] = [:]
}

/// One card of the year in review (SPEC §15.1), designed at 360 × 640 points (a story's shape) and scaled to fit: the
/// same view is shown on screen (numbers count up) and rendered as a 1080 × 1920 picture for sharing and for the video.
struct YearCard: View {
    let card: YearInReview.Card
    let content: YearCardContent
    /// Numbers count up when the card appears (not in the pictures, and not with Reduce Motion).
    var animated = true

    static let design = CGSize(width: 360, height: 640)

    var review: YearInReview { content.review }
    var yearText: String { String(review.year) }

    var body: some View {
        ZStack {
            background
            VStack(alignment: .leading, spacing: 0) {
                Text("\(yearText) in review", bundle: .module, comment: "Year in review title, e.g. 2025 in review: the screen title, the heading of every card and the video file name.")
                    .font(.system(size: 13, weight: .semibold)).textCase(.uppercase).tracking(1.5).opacity(0.85)
                Spacer(minLength: 12)
                main
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .frame(width: Self.design.width, height: Self.design.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    // MARK: Backgrounds

    @ViewBuilder var background: some View {
        switch card {
        case .intro:
            ZStack {
                mosaic(review.bestOf).opacity(0.55)
                LinearGradient(colors: [.black.opacity(0.1), palette.0.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            }
        case .busiestDay, .pets, .firstSnow, .firstBeach:
            ZStack {
                photo(backgroundPhoto)
                LinearGradient(colors: [.clear, .black.opacity(0.15), palette.0.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            }
        default:
            LinearGradient(colors: [palette.0, palette.1], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var backgroundPhoto: FileID? {
        switch card {
        case .busiestDay: review.busiestDay?.cover
        case .pets: review.pets.first?.cover
        case .firstSnow: review.firstSnow?.fileId
        case .firstBeach: review.firstBeach?.fileId
        default: review.cover
        }
    }

    /// Each card its own colours, Nextcloud blue first.
    var palette: (Color, Color) {
        switch card {
        case .intro: (Color(red: 0, green: 0.36, blue: 0.62), Color(red: 0, green: 0.51, blue: 0.79))
        case .busiestDay: (Color(red: 0.55, green: 0.12, blue: 0.32), .black)
        case .topMonth: (Color(red: 0.95, green: 0.45, blue: 0.2), Color(red: 0.75, green: 0.1, blue: 0.35))
        case .streak: (Color(red: 0.36, green: 0.18, blue: 0.75), Color(red: 0.1, green: 0.55, blue: 0.85))
        case .travel: (Color(red: 0.0, green: 0.5, blue: 0.45), Color(red: 0.05, green: 0.25, blue: 0.5))
        case .people: (Color(red: 0.85, green: 0.3, blue: 0.45), Color(red: 0.45, green: 0.15, blue: 0.6))
        case .pets: (Color(red: 0.45, green: 0.3, blue: 0.1), .black)
        case .firstSnow: (Color(red: 0.2, green: 0.35, blue: 0.6), .black)
        case .firstBeach: (Color(red: 0.0, green: 0.45, blue: 0.6), .black)
        case .favorites: (Color(red: 0.9, green: 0.2, blue: 0.35), Color(red: 0.55, green: 0.05, blue: 0.3))
        case .bestOf: (Color(red: 0.08, green: 0.08, blue: 0.12), Color(red: 0.0, green: 0.3, blue: 0.5))
        }
    }

    // MARK: Content

    @ViewBuilder var main: some View {
        switch card {
        case .intro:
            VStack(alignment: .leading, spacing: 8) {
                Text(yearText).font(.system(size: 104, weight: .heavy, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                Text("Your year in photos", bundle: .module, comment: "Year in review, first card: under the big year number.")
                    .font(.system(size: 26, weight: .bold))
                Text(AccessibilityText.join([AccessibilityText.photos(review.photos), review.videos > 0 ? videosText(review.videos) : nil]))
                    .font(.system(size: 17, weight: .medium)).opacity(0.9)
            }
        case .busiestDay:
            if let day = review.busiestDay {
                headline(
                    String(localized: "Your busiest day", bundle: .module, comment: "Year in review card: the day with the most photos."),
                    value: day.count,
                    unit: String(localized: "photos in one day", bundle: .module, comment: "Year in review: under the number of photos of the busiest day."),
                    detail: day.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            }
        case .topMonth:
            if let top = review.topMonth {
                VStack(alignment: .leading, spacing: 16) {
                    headline(
                        String(localized: "Your top month", bundle: .module, comment: "Year in review card: the month with the most photos."),
                        text: Self.monthName(top.month), detail: AccessibilityText.photos(top.count))
                    monthChart(highlight: top.month)
                }
            }
        case .streak:
            if let streak = review.longestStreak {
                headline(
                    String(localized: "Your longest streak", bundle: .module, comment: "Year in review card: most days in a row with photos."),
                    value: streak.days,
                    unit: String(localized: "days in a row with photos", bundle: .module, comment: "Year in review: under the length of the longest streak."),
                    detail: DateRangeLabel.string(from: streak.start, to: streak.end))
            }
        case .travel:
            travel
        case .people:
            people
        case .pets:
            if let pet = review.pets.first {
                headline(
                    String(localized: "Pet of the year", bundle: .module, comment: "Year in review card: the pet seen in the most photos."),
                    value: pet.count, unit: Self.petText(pet.name), detail: nil)
            }
        case .firstSnow:
            if let first = review.firstSnow {
                headline(
                    String(localized: "First snow", bundle: .module, comment: "Year in review card: the first photo of the year with snow."),
                    text: first.date.formatted(.dateTime.day().month(.wide)), detail: nil)
            }
        case .firstBeach:
            if let first = review.firstBeach {
                headline(
                    String(localized: "First beach day", bundle: .module, comment: "Year in review card: the first photo of the year on a beach."),
                    text: first.date.formatted(.dateTime.day().month(.wide)), detail: nil)
            }
        case .favorites:
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "heart.fill").font(.system(size: 56)).symbolRenderingMode(.multicolor)
                headline(
                    String(localized: "Favorites", bundle: .module, comment: "Year in review card: how many photos of the year are favorites."),
                    value: review.favorites,
                    unit: String(localized: "photos you loved", bundle: .module, comment: "Year in review: under the number of favorites."),
                    detail: nil)
            }
        case .bestOf:
            VStack(alignment: .leading, spacing: 14) {
                Text("Best of \(yearText)", bundle: .module, comment: "Year in review: the last card, a grid of the year's best photos.")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                grid(review.bestOf)
            }
        }
    }

    var travel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("On the move", bundle: .module, comment: "Year in review card about places, countries and distance.")
                .font(.system(size: 30, weight: .bold))
            if review.travel.places.count >= 2 {
                stat(review.travel.places.count, String(localized: "places", bundle: .module, comment: "Year in review: number of places photographed."))
            }
            if review.travel.countries.count >= 2 {
                stat(review.travel.countries.count, String(localized: "countries", bundle: .module, comment: "Year in review: number of countries photographed."))
            }
            if review.travel.kilometres >= 50 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Measurement(value: review.travel.kilometres.rounded(), unit: UnitLength.kilometers).formatted(.measurement(width: .abbreviated, usage: .road)))
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                    Text("between the places you photographed, as the crow flies", bundle: .module, comment: "Year in review: under the distance travelled.")
                        .font(.system(size: 15, weight: .medium)).opacity(0.9)
                }
            }
            if !review.travel.places.isEmpty {
                Text(review.travel.places.prefix(3).joined(separator: " · ")).font(.system(size: 15, weight: .semibold)).opacity(0.85)
            }
        }
    }

    var people: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your people", bundle: .module, comment: "Year in review card: the people in the most photos.")
                .font(.system(size: 30, weight: .bold))
            ForEach(review.people, id: \.name) { (person: YearInReview.Count) in
                HStack(spacing: 14) {
                    face(person.cover).frame(width: 56, height: 56).clipShape(.circle)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).font(.system(size: 19, weight: .bold)).lineLimit(1)
                        Text(AccessibilityText.photos(person.count)).font(.system(size: 14, weight: .medium)).opacity(0.85)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    func headline(_ title: String, value: Int, unit: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold))
            CountUp(value: value, animated: animated).font(.system(size: 96, weight: .heavy, design: .rounded))
            Text(unit).font(.system(size: 19, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 16, weight: .medium)).opacity(0.85).padding(.top, 4) }
        }
    }

    func headline(_ title: String, text: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold))
            Text(text).font(.system(size: 56, weight: .heavy, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
            if let detail { Text(detail).font(.system(size: 17, weight: .semibold)).opacity(0.9) }
        }
    }

    func stat(_ value: Int, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CountUp(value: value, animated: animated).font(.system(size: 52, weight: .heavy, design: .rounded))
            Text(label).font(.system(size: 20, weight: .semibold))
        }
    }

    func monthChart(highlight: Int) -> some View {
        let most = max(1, review.months.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(review.months.enumerated()), id: \.offset) { (month: (offset: Int, element: Int)) in
                VStack(spacing: 4) {
                    Capsule()
                        .fill(.white.opacity(month.offset + 1 == highlight ? 1 : 0.4))
                        .frame(height: max(4, 150 * CGFloat(month.element) / CGFloat(most)))
                    Text(Self.monthInitial(month.offset + 1)).font(.system(size: 10, weight: .bold)).opacity(0.8)
                }
            }
        }
        .frame(height: 172, alignment: .bottom)
        .accessibilityHidden(true)
    }

    func grid(_ ids: [FileID]) -> some View {
        let columns = [GridItem](repeating: GridItem(.flexible(), spacing: 4), count: 3)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(ids.prefix(9), id: \.self) { (id: FileID) in
                Color.clear.aspectRatio(1, contentMode: .fit).overlay { photo(id) }.clipShape(.rect(cornerRadius: 6))
            }
        }
    }

    func mosaic(_ ids: [FileID]) -> some View {
        let columns = [GridItem](repeating: GridItem(.flexible(), spacing: 0), count: 3)
        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(ids.prefix(9).enumerated()), id: \.offset) { (entry: (offset: Int, element: FileID)) in
                Color.clear.frame(height: Self.design.height / 3).overlay { photo(entry.element) }.clipped()
            }
        }
    }

    @ViewBuilder func photo(_ id: FileID?) -> some View {
        if let id, let image = content.images[id] {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
        } else {
            Color.white.opacity(0.08)
        }
    }

    /// A person's photo cropped round their face (found on the device).
    @ViewBuilder func face(_ id: FileID) -> some View {
        if let image = content.images[id] {
            let focus = content.focus[id].map { KenBurns.square(around: $0, imageAspect: Double(image.width) / Double(image.height)) }
            GeometryReader { proxy in
                let crop = focus ?? KenBurns.square(around: .full, imageAspect: Double(image.width) / Double(image.height))
                Image(decorative: image, scale: 1).resizable()
                    .frame(width: proxy.size.width / crop.width, height: proxy.size.height / crop.height)
                    .offset(x: -crop.x * proxy.size.width / crop.width, y: -crop.y * proxy.size.height / crop.height)
            }
        } else {
            Color.white.opacity(0.15)
        }
    }

    func videosText(_ count: Int) -> String {
        String(localized: "\(count) videos", bundle: .module, comment: "Year in review: number of videos of the year. Plural variations in the catalog.")
    }

    static func petText(_ label: String) -> String {
        switch label {
        case "dog": String(localized: "photos with a dog", bundle: .module, comment: "Year in review: under the number of photos showing a dog.")
        case "cat": String(localized: "photos with a cat", bundle: .module, comment: "Year in review: under the number of photos showing a cat.")
        default: label
        }
    }

    static func monthName(_ month: Int) -> String {
        let calendar = Calendar.current
        return calendar.standaloneMonthSymbols[safe: month - 1] ?? ""
    }

    static func monthInitial(_ month: Int) -> String {
        Calendar.current.veryShortStandaloneMonthSymbols[safe: month - 1] ?? ""
    }

    /// What VoiceOver reads for a card.
    var accessibilityText: String {
        switch card {
        case .intro:
            AccessibilityText.join([yearText, AccessibilityText.photos(review.photos), review.videos > 0 ? videosText(review.videos) : nil])
        case .busiestDay:
            AccessibilityText.join([
                String(localized: "Your busiest day", bundle: .module), review.busiestDay?.date.formatted(date: .complete, time: .omitted),
                review.busiestDay.map { AccessibilityText.photos($0.count) },
            ])
        case .topMonth:
            AccessibilityText.join([
                String(localized: "Your top month", bundle: .module), review.topMonth.map { Self.monthName($0.month) },
                review.topMonth.map { AccessibilityText.photos($0.count) },
            ])
        case .streak:
            AccessibilityText.join([
                String(localized: "Your longest streak", bundle: .module),
                review.longestStreak.map { String(localized: "\($0.days) days", bundle: .module, comment: "Year in review: length of the longest streak, for VoiceOver. Plural variations in the catalog.") },
            ])
        case .travel:
            AccessibilityText.join(
                [String(localized: "On the move", bundle: .module)] + review.travel.places.prefix(3).map { Optional($0) })
        case .people:
            AccessibilityText.join(
                [String(localized: "Your people", bundle: .module)] + review.people.map { "\($0.name), \(AccessibilityText.photos($0.count))" })
        case .pets:
            AccessibilityText.join([
                String(localized: "Pet of the year", bundle: .module), review.pets.first.map { "\($0.count) \(Self.petText($0.name))" },
            ])
        case .firstSnow:
            AccessibilityText.join([String(localized: "First snow", bundle: .module), review.firstSnow?.date.formatted(date: .long, time: .omitted)])
        case .firstBeach:
            AccessibilityText.join([
                String(localized: "First beach day", bundle: .module), review.firstBeach?.date.formatted(date: .long, time: .omitted),
            ])
        case .favorites:
            AccessibilityText.join([String(localized: "Favorites", bundle: .module), AccessibilityText.photos(review.favorites)])
        case .bestOf:
            String(localized: "Best of \(yearText)", bundle: .module)
        }
    }
}

/// A number that counts up from zero when its card comes into view (rolling digits); shown at once when not animated
/// or with Reduce Motion.
struct CountUp: View {
    let value: Int
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Int?

    var body: some View {
        let current = animated && !reduceMotion ? (shown ?? 0) : value
        Text(current.formatted())
            .contentTransition(.numericText(value: Double(current)))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .onChange(of: animated, initial: true) { _, animated in
                // Counts up each time its card comes into view.
                guard animated, !reduceMotion else { return }
                shown = 0
                withAnimation(.smooth(duration: 1.1).delay(0.2)) { shown = value }
            }
    }
}
