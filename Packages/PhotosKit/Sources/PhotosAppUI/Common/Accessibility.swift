// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import SwiftUI

/// What VoiceOver, Voice Control and Switch Control read for elements that show pictures and badges rather than text
/// (SPEC §9). Every part is a localised phrase; the parts are joined with commas so that VoiceOver pauses between them.
enum AccessibilityText {
    /// How an album is shared, as shown by the badge on its card.
    enum Sharing {
        case none
        case link
        case people
    }

    /// "Lisbon 2025, album, 28 items, shared by Anna, Lisbon, shared with a link".
    static func album(title: String, itemCount: Int, owner: String? = nil, location: String = "", sharing: Sharing = .none) -> String {
        var parts = [title, String(localized: "album", bundle: .module, comment: "Accessibility: the kind of a card."), items(itemCount)]
        if let owner, !owner.isEmpty { parts.append(String(localized: "shared by \(owner)", bundle: .module)) }
        if !location.isEmpty { parts.append(location) }
        switch sharing {
        case .none: break
        case .link: parts.append(String(localized: "shared with a link", bundle: .module))
        case .people: parts.append(String(localized: "shared with others", bundle: .module))
        }
        return join(parts)
    }

    /// "Lisbon, place, 28 photos": the cards of places, tags, people and folders.
    static func collection(title: String, kind: String?, detail: String?) -> String {
        join([title, kind, detail])
    }

    /// "3 years ago, memory, 22 Nov – 25 Nov 2023, 28 photos". `dateLine` is nil when the title already is the date.
    static func memory(title: String, dateLine: String?, itemCount: Int) -> String {
        join([
            title, String(localized: "memory", bundle: .module, comment: "Accessibility: the kind of a card."), dateLine, photos(itemCount),
        ])
    }

    /// A photo or video: "Video, 22 November 2026 at 14:03, 1 minute, 5 seconds, Lisbon, with Anna and Ben, Favorite,
    /// A dog on the beach". Kind and date always; the rest when known.
    static func media(
        isVideo: Bool, isLivePhoto: Bool, date: Date, duration: Double? = nil, place: String? = nil, people: [String] = [],
        isFavorite: Bool = false, caption: String? = nil
    ) -> String {
        var parts: [String?] = [kind(isVideo: isVideo, isLivePhoto: isLivePhoto), date.formatted(date: .long, time: .shortened)]
        if isVideo, let duration, duration > 0 { parts.append(spokenDuration(duration)) }
        parts.append(place)
        if !people.isEmpty {
            let names = people.formatted(.list(type: .and))
            parts.append(String(localized: "with \(names)", bundle: .module, comment: "Accessibility: the people in a photo."))
        }
        if isFavorite { parts.append(String(localized: "Favorite", bundle: .module)) }
        parts.append(caption)
        return join(parts)
    }

    static func kind(isVideo: Bool, isLivePhoto: Bool) -> String {
        if isVideo { return String(localized: "Video", bundle: .module) }
        if isLivePhoto { return String(localized: "Live Photo", bundle: .module) }
        return String(localized: "Photo", bundle: .module)
    }

    /// "3 of 120": where the viewer is in its list.
    static func position(index: Int, count: Int) -> String {
        let number = index + 1
        return String(
            localized: "\(number) of \(count)", bundle: .module, comment: "Accessibility: position of the photo shown in the viewer.")
    }

    /// A map marker: "Lisbon, 12 photos"; without a place name the date of its newest photo.
    static func mapMarker(place: String?, count: Int, newest: Date) -> String {
        if let place, !place.isEmpty { return join([place, photos(count)]) }
        let date = newest.formatted(date: .abbreviated, time: .omitted)
        return join([photos(count), String(localized: "newest from \(date)", bundle: .module)])
    }

    /// "1 minute, 5 seconds" (spoken), where the tile shows "1:05".
    static func spokenDuration(_ seconds: Double) -> String {
        Duration.seconds(Int(seconds.rounded())).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// "28 items" (plural forms from the catalog).
    static func items(_ count: Int) -> String {
        String(localized: "\(count) items", bundle: .module)
    }

    /// "28 photos" (plural forms from the catalog).
    static func photos(_ count: Int) -> String {
        String(localized: "\(count) photos", bundle: .module)
    }

    static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Legibility of text and badges drawn over photos.
enum OverlayLegibility {
    /// Opacity of the dark gradient under badges and titles on photos: stronger with Increase Contrast or Reduce
    /// Transparency, where the picture must not show through as much.
    static func scrimOpacity(base: Double, increased: Bool) -> Double {
        increased ? max(base, 0.75) : base
    }
}

/// Short, standard haptics (iPhone and iPad); nothing on the Mac and Vision Pro.
extension View {
    @ViewBuilder func photosHaptic<Trigger: Equatable>(_ feedback: SensoryFeedback, trigger: Trigger) -> some View {
        #if os(iOS)
            sensoryFeedback(feedback, trigger: trigger)
        #else
            self
        #endif
    }

    /// A selection tick when a set of selected items changes while selecting.
    @ViewBuilder func selectionHaptic<Value: Equatable & Collection>(_ selection: Value, isActive: Bool) -> some View {
        #if os(iOS)
            sensoryFeedback(trigger: selection) { old, new in
                isActive && old.count != new.count ? .selection : nil
            }
        #else
            self
        #endif
    }
}
