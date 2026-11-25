// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PhotosDomain

/// Draws the two sides of a postcard (SPEC §16.7.1) with Core Graphics, so the same pictures come out on every platform
/// and in the background. The layout (`PostcardLayout`) has its origin at the top left; Core Graphics at the bottom left.
public enum PostcardRenderer {
    /// The handwriting of the message and the name: Bradley Hand where it exists (iOS, iPadOS, macOS, visionOS), else
    /// Noteworthy, else the system's own fallback.
    static let handwritingFonts = ["BradleyHandITCTT-Bold", "Noteworthy-Light", "MarkerFelt-Thin"]
    static let letteringFonts = ["AvenirNextCondensed-Heavy", "Futura-CondensedExtraBold", "Helvetica-Bold"]
    static let serifFonts = ["Georgia", "TimesNewRomanPSMT", "Times-Roman"]

    static let ink = CGColor(srgbRed: 0.12, green: 0.23, blue: 0.45, alpha: 1)
    static let postmarkInk = CGColor(srgbRed: 0.25, green: 0.25, blue: 0.3, alpha: 0.72)
    static let rule = CGColor(srgbRed: 0.8, green: 0.77, blue: 0.7, alpha: 1)
    static let airmailRed = CGColor(srgbRed: 0.82, green: 0.19, blue: 0.18, alpha: 1)
    static let airmailBlue = CGColor(srgbRed: 0.11, green: 0.31, blue: 0.62, alpha: 1)

    static func paper(_ style: PostcardStyle) -> CGColor {
        style == .vintage
            ? CGColor(srgbRed: 0.95, green: 0.91, blue: 0.82, alpha: 1) : CGColor(srgbRed: 0.985, green: 0.97, blue: 0.94, alpha: 1)
    }

    // MARK: Front

    /// The front: the photo in the style's frame, with the "Greetings from" lettering when there is one.
    public static func front(photo: CGImage, content: PostcardContent, layout: PostcardLayout) -> CGImage? {
        guard let context = makeContext(layout.size) else { return nil }
        let canvas = Canvas(context: context, height: layout.size.height)
        let bounds = CGRect(origin: .zero, size: layout.size)
        let style = content.style
        switch style {
        case .classic, .edgeToEdge, .airmail:
            context.setFillColor(CGColor(gray: 1, alpha: 1))
        case .vintage:
            context.setFillColor(paper(.vintage))
        }
        context.fill(bounds)
        if style == .airmail { drawAirmailStripes(canvas, layout: layout, width: layout.airmailStripeWidth) }
        let photoRect = canvas.flip(layout.photoRect(style))
        context.saveGState()
        if style == .vintage {
            context.addPath(scallopedPath(photoRect, radius: layout.scallopRadius))
            context.clip()
        } else {
            context.clip(to: photoRect)
        }
        context.interpolationQuality = .high
        context.draw(photo, in: filled(photo, in: photoRect))
        if style == .vintage { warmTone(context, rect: photoRect) }
        context.restoreGState()
        if style == .classic || style == .airmail {
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
            context.setLineWidth(max(1, layout.size.width / 900))
            context.stroke(photoRect)
        }
        let greeting = content.greeting.trimmingCharacters(in: .whitespacesAndNewlines)
        if !greeting.isEmpty {
            let rect = layout.greetingRect(style)
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: rect.height * 0.03, height: -rect.height * 0.03), blur: rect.height * 0.08,
                color: CGColor(gray: 0, alpha: 0.6))
            drawText(
                greeting, fonts: letteringFonts, sizes: (rect.height * 0.14)...(rect.height * 0.42), color: CGColor(gray: 1, alpha: 1),
                in: canvas.flip(rect), context: context, alignment: .left, vertical: .bottom, kern: rect.height * 0.004)
            context.restoreGState()
        }
        return context.makeImage()
    }

    // MARK: Back

    /// The back: "POSTCARD", the message in handwriting, the stamp (a small crop of the photo), the postmark with place
    /// and date, and "To:" with the recipient's name.
    public static func back(photo: CGImage, content: PostcardContent, layout: PostcardLayout, locale: Locale = .current) -> CGImage? {
        guard let context = makeContext(layout.size) else { return nil }
        let canvas = Canvas(context: context, height: layout.size.height)
        let bounds = CGRect(origin: .zero, size: layout.size)
        let short = min(layout.size.width, layout.size.height)
        context.setFillColor(paper(content.style))
        context.fill(bounds)
        if content.style == .airmail { drawAirmailStripes(canvas, layout: layout, width: short * 0.022) }

        // Heading
        let heading = PostcardContent.headingText
        drawText(
            heading, fonts: serifFonts, sizes: (layout.headingRect.height * 0.5)...(layout.headingRect.height * 0.8),
            color: CGColor(srgbRed: 0.48, green: 0.43, blue: 0.37, alpha: 1), in: canvas.flip(layout.headingRect), context: context,
            alignment: layout.isPortrait ? .left : .center, vertical: .center, kern: layout.headingRect.height * 0.25)

        // Divider and address lines
        context.setStrokeColor(rule)
        context.setLineWidth(short * 0.003)
        context.move(to: canvas.flip(layout.divider.from))
        context.addLine(to: canvas.flip(layout.divider.to))
        context.strokePath()
        context.setLineWidth(short * 0.0022)
        for line in layout.addressLines {
            context.move(to: canvas.flip(line.from))
            context.addLine(to: canvas.flip(line.to))
        }
        context.strokePath()

        // Recipient on the first address line
        let recipient = content.recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = layout.addressLines.first {
            let to = PostcardContent.toLabel
            let labelHeight = short * 0.035
            let lineHeight = short * 0.09
            let labelRect = CGRect(x: first.from.x, y: first.from.y - labelHeight * 1.5, width: short * 0.1, height: labelHeight * 1.4)
            drawText(
                to, fonts: serifFonts, sizes: (labelHeight * 0.8)...labelHeight, color: CGColor(gray: 0.45, alpha: 1),
                in: canvas.flip(labelRect), context: context, alignment: .left, vertical: .bottom)
            if !recipient.isEmpty {
                let nameRect = CGRect(
                    x: labelRect.maxX, y: first.from.y - lineHeight, width: first.to.x - labelRect.maxX, height: lineHeight * 0.95)
                drawText(
                    recipient, fonts: handwritingFonts, sizes: (lineHeight * 0.3)...(lineHeight * 0.62), color: ink,
                    in: canvas.flip(nameRect), context: context, alignment: .left, vertical: .bottom)
            }
        }

        // Message
        let message = PostcardContent.printedMessage(content.message)
        if !message.isEmpty {
            drawText(
                message, fonts: handwritingFonts, sizes: layout.messageFontRange, color: ink, in: canvas.flip(layout.messageRect),
                context: context, alignment: .left, vertical: .top, lineSpacing: 1.12)
        }

        drawStamp(photo, canvas: canvas, layout: layout, style: content.style)
        drawPostmark(canvas: canvas, layout: layout, place: content.place, date: content.date, locale: locale)
        return context.makeImage()
    }

    /// A JPEG of a side, as it is uploaded and shared.
    public static func jpeg(_ image: CGImage) -> Data? {
        ImageDecoding.jpegData(image, quality: 0.9)
    }

    // MARK: Parts

    /// The stamp: a white perforated rectangle with a small crop of the photo, slightly lifted from the paper.
    static func drawStamp(_ photo: CGImage, canvas: Canvas, layout: PostcardLayout, style: PostcardStyle) {
        let context = canvas.context
        let rect = canvas.flip(layout.stampRect)
        let hole = rect.width * 0.035
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -hole * 0.4), blur: hole * 1.5, color: CGColor(gray: 0, alpha: 0.25))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.restoreGState()
        // Perforation: paper-coloured half circles along the edges.
        context.setFillColor(paper(style))
        let step = hole * 2.7
        for x in stride(from: rect.minX + step / 2, through: rect.maxX, by: step) {
            context.fillEllipse(in: CGRect(x: x - hole, y: rect.minY - hole, width: 2 * hole, height: 2 * hole))
            context.fillEllipse(in: CGRect(x: x - hole, y: rect.maxY - hole, width: 2 * hole, height: 2 * hole))
        }
        for y in stride(from: rect.minY + step / 2, through: rect.maxY, by: step) {
            context.fillEllipse(in: CGRect(x: rect.minX - hole, y: y - hole, width: 2 * hole, height: 2 * hole))
            context.fillEllipse(in: CGRect(x: rect.maxX - hole, y: y - hole, width: 2 * hole, height: 2 * hole))
        }
        let inner = rect.insetBy(dx: rect.width * 0.11, dy: rect.width * 0.11)
        context.saveGState()
        context.clip(to: inner)
        context.interpolationQuality = .medium
        context.draw(photo, in: filled(photo, in: inner))
        context.restoreGState()
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.15))
        context.setLineWidth(max(1, rect.width * 0.008))
        context.stroke(inner)
    }

    /// The postmark: two rings with the place and the date, tilted, and wavy cancellation lines to its left.
    static func drawPostmark(canvas: Canvas, layout: PostcardLayout, place: String, date: Date, locale: Locale) {
        let context = canvas.context
        let center = canvas.flip(layout.postmarkCenter)
        let radius = layout.postmarkRadius
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: 0.2)
        context.setStrokeColor(postmarkInk)
        context.setLineWidth(radius * 0.045)
        context.strokeEllipse(in: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius))
        context.setLineWidth(radius * 0.025)
        let innerRadius = radius * 0.8
        context.strokeEllipse(in: CGRect(x: -innerRadius, y: -innerRadius, width: 2 * innerRadius, height: 2 * innerRadius))
        // Cancellation waves.
        context.setLineWidth(radius * 0.04)
        for index in 0..<4 {
            let y = radius * (-0.45 + 0.3 * CGFloat(index))
            let start = -radius * 3.6
            let end = -radius * 1.05
            context.move(to: CGPoint(x: start, y: y))
            var x = start
            while x < end {
                x += radius * 0.05
                context.addLine(to: CGPoint(x: x, y: y + sin((x - start) / radius * 4.2) * radius * 0.07))
            }
        }
        context.strokePath()
        let dateText = date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale)).uppercased(with: locale)
        let width = innerRadius * 1.6
        drawText(
            dateText, fonts: serifFonts, sizes: (radius * 0.12)...(radius * 0.24), color: postmarkInk,
            in: CGRect(x: -width / 2, y: -radius * 0.2, width: width, height: radius * 0.4), context: context, alignment: .center,
            vertical: .center)
        let placeText = place.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(with: locale)
        if !placeText.isEmpty {
            drawText(
                placeText, fonts: serifFonts, sizes: (radius * 0.1)...(radius * 0.18), color: postmarkInk,
                in: CGRect(x: -width * 0.45, y: radius * 0.22, width: width * 0.9, height: radius * 0.42), context: context,
                alignment: .center, vertical: .center, kern: radius * 0.02)
        }
        context.restoreGState()
    }

    /// Red and blue diagonal stripes in a band of `width` along the card's edge.
    static func drawAirmailStripes(_ canvas: Canvas, layout: PostcardLayout, width: CGFloat) {
        let context = canvas.context
        let bounds = CGRect(origin: .zero, size: layout.size)
        context.saveGState()
        context.addRect(bounds)
        context.addRect(bounds.insetBy(dx: width, dy: width))
        context.clip(using: .evenOdd)
        let stripe = width * 1.3
        let height = layout.size.height
        var x = -height
        var index = 0
        while x < layout.size.width + height {
            context.setFillColor(index % 2 == 0 ? airmailRed : airmailBlue)
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x + stripe, y: 0))
            context.addLine(to: CGPoint(x: x + stripe + height, y: height))
            context.addLine(to: CGPoint(x: x + height, y: height))
            context.closePath()
            context.fillPath()
            x += stripe * 2
            index += 1
        }
        context.restoreGState()
    }

    /// Warm, slightly faded colours and darker corners for the vintage style.
    static func warmTone(_ context: CGContext, rect: CGRect) {
        context.setBlendMode(.multiply)
        context.setFillColor(CGColor(srgbRed: 1, green: 0.88, blue: 0.68, alpha: 0.55))
        context.fill(rect)
        context.setBlendMode(.screen)
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.16, blue: 0.1, alpha: 0.35))
        context.fill(rect)
        context.setBlendMode(.normal)
        let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.35)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0.55, 1]) {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            context.drawRadialGradient(
                gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: hypot(rect.width, rect.height) / 2,
                options: [])
        }
    }

    /// A rectangle whose edges are a row of small half circles, like a deckle-edged print.
    static func scallopedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let inner = rect.insetBy(dx: radius, dy: radius)
        path.addRect(inner)
        let step = radius * 2
        for x in stride(from: inner.minX + radius, through: inner.maxX - radius / 2, by: step) {
            path.addEllipse(in: CGRect(x: x - radius, y: inner.minY - radius, width: step, height: step))
            path.addEllipse(in: CGRect(x: x - radius, y: inner.maxY - radius, width: step, height: step))
        }
        for y in stride(from: inner.minY + radius, through: inner.maxY - radius / 2, by: step) {
            path.addEllipse(in: CGRect(x: inner.minX - radius, y: y - radius, width: step, height: step))
            path.addEllipse(in: CGRect(x: inner.maxX - radius, y: y - radius, width: step, height: step))
        }
        return path
    }

    // MARK: Text

    enum VerticalAlignment {
        case top, center, bottom
    }

    /// The first of `names` that exists, at `size`.
    static func font(_ names: [String], size: CGFloat) -> CTFont {
        for name in names {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            if (CTFontCopyPostScriptName(font) as String) == name { return font }
        }
        return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// The largest font size in `sizes` at which `text` fits `rect` (wrapped at word boundaries), searched in steps.
    static func fittingSize(
        _ text: String, fonts: [String], sizes: ClosedRange<CGFloat>, width: CGFloat, height: CGFloat, kern: CGFloat = 0,
        lineSpacing: CGFloat = 1
    ) -> CGFloat {
        var size = sizes.upperBound
        while size > sizes.lowerBound {
            let attributed = attributedText(
                text, font: font(fonts, size: size), color: CGColor(gray: 0, alpha: 1), kern: kern,
                alignment: .left, lineSpacing: lineSpacing)
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(
                setter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            let longestWord =
                text.split(whereSeparator: \.isWhitespace).map { word -> CGFloat in
                    let line = CTLineCreateWithAttributedString(
                        attributedText(
                            String(word), font: font(fonts, size: size), color: CGColor(gray: 0, alpha: 1), kern: kern,
                            alignment: .left, lineSpacing: lineSpacing))
                    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                }.max() ?? 0
            if fit.height <= height && longestWord <= width { return size }
            size *= 0.94
        }
        return sizes.lowerBound
    }

    static func attributedText(
        _ text: String, font: CTFont, color: CGColor, kern: CGFloat, alignment: CTTextAlignment, lineSpacing: CGFloat
    ) -> NSAttributedString {
        let style = withUnsafeBytes(of: alignment) { alignmentBytes in
            withUnsafeBytes(of: lineSpacing) { spacingBytes in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: alignmentBytes.count, value: alignmentBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: spacingBytes.count, value: spacingBytes.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        return NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTKernAttributeName as String): kern,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            ])
    }

    /// Draws text as large as fits into `rect` (Core Graphics coordinates), wrapped, aligned in it.
    static func drawText(
        _ text: String, fonts: [String], sizes: ClosedRange<CGFloat>, color: CGColor, in rect: CGRect, context: CGContext,
        alignment: CTTextAlignment, vertical: VerticalAlignment, kern: CGFloat = 0, lineSpacing: CGFloat = 1
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        let size = fittingSize(
            text, fonts: fonts, sizes: sizes, width: rect.width, height: rect.height, kern: kern, lineSpacing: lineSpacing)
        let attributed = attributedText(
            text, font: font(fonts, size: size), color: color, kern: kern, alignment: alignment, lineSpacing: lineSpacing)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil, CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
        let height = min(rect.height, ceil(fit.height) + 1)
        let y: CGFloat
        switch vertical {
        case .top: y = rect.maxY - height
        case .center: y = rect.midY - height / 2
        case .bottom: y = rect.minY
        }
        let frame = CTFramesetterCreateFrame(
            setter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(x: rect.minX, y: y, width: rect.width, height: height), transform: nil),
            nil)
        context.saveGState()
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    // MARK: Helpers

    /// Converts the layout's top-left coordinates into the context's bottom-left ones.
    struct Canvas {
        let context: CGContext
        let height: CGFloat

        func flip(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height) }
        func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: height - point.y) }
    }

    static func makeContext(_ size: CGSize) -> CGContext? {
        guard size.width >= 1, size.height >= 1, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// The rectangle that aspect-fills `bounds` with an image, centred.
    static func filled(_ image: CGImage, in bounds: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0 else { return bounds }
        let scale = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
}
