// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// How the front of a postcard frames the photo (SPEC §16.7.1).
public enum PostcardStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// A white border, as a print from the corner shop.
    case classic
    /// The photo to the edges, with room for the "Greetings from" lettering.
    case edgeToEdge
    /// Red and blue airmail stripes around a white border.
    case airmail
    /// A cream border with scalloped edges and warm, faded colours.
    case vintage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .classic: String(localized: "Classic", bundle: .module, comment: "Postcard style: the photo with a white border.")
        case .edgeToEdge:
            String(localized: "Edge to Edge", bundle: .module, comment: "Postcard style: the photo fills the whole front of the card.")
        case .airmail:
            String(localized: "Airmail", bundle: .module, comment: "Postcard style: red and blue airmail stripes around the photo.")
        case .vintage:
            String(
                localized: "Vintage", bundle: .module, comment: "Postcard style: cream border with scalloped edges and warm, faded colours."
            )
        }
    }
}

/// What a postcard says. Everything is optional except the photo, which the renderer gets on its own.
public struct PostcardContent: Hashable, Sendable {
    public var style: PostcardStyle
    /// The handwritten message on the back.
    public var message: String
    /// "To" on the address side: a name, not an address (the card is sent as a link).
    public var recipient: String
    /// "Greetings from …" lettering on the front; empty for none.
    public var greeting: String
    /// The postmark: where and when the photo was taken (the place may be empty).
    public var place: String
    public var date: Date

    public init(
        style: PostcardStyle = .classic, message: String = "", recipient: String = "", greeting: String = "", place: String = "", date: Date
    ) {
        self.style = style
        self.message = message
        self.recipient = recipient
        self.greeting = greeting
        self.place = place
        self.date = date
    }

    /// The heading on the back.
    public static var headingText: String {
        String(localized: "POSTCARD", bundle: .module, comment: "Heading on the back of a postcard, in capitals.")
    }

    /// The label before the recipient's name on the back.
    public static var toLabel: String {
        String(localized: "To:", bundle: .module, comment: "Label before the recipient's name on the back of a postcard.")
    }

    /// The longest message that still reads well in the handwriting at the smallest size.
    public static let maximumMessageLength = 400

    /// "Greetings from Lisbon", or empty without a place.
    public static func defaultGreeting(place: String) -> String {
        let place = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.isEmpty else { return "" }
        return String(
            localized: "Greetings from \(place)", bundle: .module,
            comment: "Lettering on the front of a postcard; the argument is the place the photo was taken, e.g. Greetings from Lisbon.")
    }

    /// The message as it is printed: trimmed, at most `maximumMessageLength` characters, at most 12 lines.
    public static func printedMessage(_ message: String) -> String {
        var lines = message.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        if lines.count > 12 { lines = Array(lines.prefix(12)) }
        let text = lines.joined(separator: "\n")
        guard text.count > maximumMessageLength else { return text }
        // Cut at the last space before the limit, so no word is cut in half.
        let head = text.prefix(maximumMessageLength - 1)
        let cut = head.lastIndex(where: \.isWhitespace).map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

/// Where everything goes on a postcard. Pure geometry, in pixels with the origin at the top left; the renderer
/// (`PostcardRenderer`) draws it. Both sides have the same size, so the card can be flipped in place.
public struct PostcardLayout: Equatable, Sendable {
    public var size: CGSize
    public var isPortrait: Bool { size.height > size.width }

    /// A card for a photo of this aspect ratio (width / height): 6 × 4 inches at 300 dpi, upright for upright photos.
    public init(photoAspectRatio: Double) {
        size = photoAspectRatio < 0.95 ? CGSize(width: 1200, height: 1800) : CGSize(width: 1800, height: 1200)
    }

    public init(size: CGSize) {
        self.size = size
    }

    var short: CGFloat { min(size.width, size.height) }
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    // MARK: Front

    /// The border around the photo, as a share of the short side.
    public func borderWidth(_ style: PostcardStyle) -> CGFloat {
        switch style {
        case .classic: short * 0.045
        case .edgeToEdge: 0
        case .airmail: short * 0.07
        case .vintage: short * 0.06
        }
    }

    /// The rectangle the photo fills (aspect fill, cropped to it).
    public func photoRect(_ style: PostcardStyle) -> CGRect {
        bounds.insetBy(dx: borderWidth(style), dy: borderWidth(style))
    }

    /// The airmail stripes: the band between the card's edge and the inner white margin.
    public var airmailStripeWidth: CGFloat { short * 0.035 }

    /// The "Greetings from" lettering: the lower part of the photo, with a margin.
    public func greetingRect(_ style: PostcardStyle) -> CGRect {
        let photo = photoRect(style)
        let margin = short * 0.05
        let height = photo.height * 0.26
        return CGRect(x: photo.minX + margin, y: photo.maxY - margin - height, width: photo.width - 2 * margin, height: height)
    }

    /// The radius of the scallops of the vintage edge.
    public var scallopRadius: CGFloat { short * 0.012 }

    // MARK: Back

    /// The paper margin of the back.
    public var backMargin: CGFloat { short * 0.06 }

    /// The stamp, in the top right corner.
    public var stampRect: CGRect {
        let width = short * 0.17
        let height = width * 1.2
        return CGRect(x: size.width - backMargin - width, y: backMargin, width: width, height: height)
    }

    /// The postmark: a circle overlapping the stamp's lower left corner a little, so its words stay readable.
    public var postmarkCenter: CGPoint {
        CGPoint(x: stampRect.minX - postmarkRadius * 0.4, y: stampRect.maxY - short * 0.025)
    }

    public var postmarkRadius: CGFloat { short * 0.095 }

    /// The "POSTCARD" heading at the top.
    public var headingRect: CGRect {
        let height = short * 0.05
        if isPortrait {
            return CGRect(x: backMargin, y: backMargin, width: stampRect.minX - postmarkRadius * 1.3 - backMargin, height: height)
        }
        return CGRect(x: backMargin, y: backMargin, width: size.width / 2 - backMargin, height: height)
    }

    /// The line between message and address (vertical in landscape, horizontal in portrait).
    public var divider: (from: CGPoint, to: CGPoint) {
        if isPortrait {
            let y = size.height * 0.66
            return (CGPoint(x: backMargin, y: y), CGPoint(x: size.width - backMargin, y: y))
        }
        let x = size.width * 0.56
        return (CGPoint(x: x, y: stampRect.maxY * 0.6), CGPoint(x: x, y: size.height - backMargin))
    }

    /// Where the message is written.
    public var messageRect: CGRect {
        let top = headingRect.maxY + short * 0.04
        if isPortrait {
            let bottom = divider.from.y - short * 0.04
            let below = max(stampRect.maxY, postmarkCenter.y + postmarkRadius) + short * 0.04
            return CGRect(x: backMargin, y: max(top, below), width: size.width - 2 * backMargin, height: 0)
                .with(bottom: bottom)
        }
        let right = divider.from.x - short * 0.05
        return CGRect(x: backMargin, y: top, width: right - backMargin, height: size.height - backMargin - top)
    }

    /// The address lines, top to bottom; the first one carries "To:" and the name.
    public var addressLines: [(from: CGPoint, to: CGPoint)] {
        let count = 3
        let left: CGFloat
        let right = size.width - backMargin
        let top: CGFloat
        let bottom = size.height - backMargin - short * 0.04
        if isPortrait {
            left = backMargin
            top = divider.from.y + short * 0.12
        } else {
            left = divider.from.x + short * 0.05
            top = max(stampRect.maxY, postmarkCenter.y + postmarkRadius) + short * 0.12
        }
        let step = (bottom - top) / CGFloat(count - 1)
        return (0..<count).map { index in
            let y = top + CGFloat(index) * step
            return (CGPoint(x: left, y: y), CGPoint(x: right, y: y))
        }
    }

    /// The font size range of the message: as large as fits, never smaller than this.
    public var messageFontRange: ClosedRange<CGFloat> { (short * 0.038)...(short * 0.068) }
}

extension CGRect {
    fileprivate func with(bottom: CGFloat) -> CGRect {
        CGRect(x: minX, y: minY, width: width, height: max(0, bottom - minY))
    }
}

/// Names of what a sent postcard leaves in the user's files: `/Postcards/<day> <place>/` with the two sides
/// (SPEC §16.7.1). The folder `/Postcards` holds a `.nomedia` file, so the cards stay out of the timeline.
public enum PostcardFiles {
    public static let rootFolder = "/Postcards"

    /// "2026-11-25 Lisbon", or "2026-11-25 Postcard" without a place; characters that cannot be in a file name are
    /// replaced. `attempt` > 1 adds a number for a name that is taken.
    public static func folderName(date: Date, place: String, attempt: Int = 1, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
        var name = sanitized(place)
        if name.isEmpty {
            name = String(localized: "Postcard", bundle: .module, comment: "Name of the folder a sent postcard is kept in, after its date.")
        }
        let base = "\(day) \(name)"
        return attempt > 1 ? "\(base) \(attempt)" : base
    }

    /// The file names of the two sides; numbered, so the public page lists the front first.
    public static var frontFileName: String {
        String(localized: "1 Front.jpg", bundle: .module, comment: "File name of a postcard's front. Keep the number and .jpg.")
    }

    public static var backFileName: String {
        String(localized: "2 Back.jpg", bundle: .module, comment: "File name of a postcard's back. Keep the number and .jpg.")
    }

    /// A place as part of a file name: no slashes, colons or control characters, at most 60 characters.
    static func sanitized(_ text: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = text.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(trimmed.prefix(60)).trimmingCharacters(in: .whitespaces)
    }
}
