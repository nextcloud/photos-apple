// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import PhotosDomain
import Testing

@testable import PhotosMedia

@Suite(.disabled(if: TestEnvironment.isSimulator, TestEnvironment.noGPU), .timeLimit(.minutes(1)))
struct PostcardRendererTests {
    /// A green photo, the given size.
    func photo(width: Int = 900, height: Int = 600) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.7, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// The colour of a pixel, top-left origin, as 0…255 RGB.
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    /// Pixels in a region (top-left origin) that are clearly ink blue.
    func inkPixels(_ image: CGImage, in rect: CGRect) -> Int {
        var count = 0
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 6) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 6) {
                let p = pixel(image, x, y)
                if p.b > p.r + 40 && p.b < 200 { count += 1 }
            }
        }
        return count
    }

    /// Where `PHOTOS_POSTCARD_PREVIEWS` points, the sides are written as JPEGs for a look.
    func keep(_ image: CGImage, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["PHOTOS_POSTCARD_PREVIEWS"] else { return }
        try? PostcardRenderer.jpeg(image)?.write(to: URL(filePath: directory).appending(path: name))
    }

    @Test(arguments: PostcardStyle.allCases) func frontFramesThePhoto(style: PostcardStyle) throws {
        let layout = PostcardLayout(photoAspectRatio: 1.5)
        let content = PostcardContent(style: style, greeting: "Greetings from Lisbon", place: "Lisbon", date: Date())
        let front = try #require(PostcardRenderer.front(photo: photo(), content: content, layout: layout))
        keep(front, "front-\(style.rawValue).jpg")
        #expect(front.width == 1800 && front.height == 1200)
        let middle = pixel(front, 900, 400)
        #expect(middle.g > middle.r && middle.g > middle.b, "the photo is in the middle")
        let corner = pixel(front, 3, 3)
        switch style {
        case .edgeToEdge: #expect(corner.g > corner.r, "the photo reaches the edge")
        case .classic: #expect(corner.r > 240 && corner.g > 240 && corner.b > 240, "a white border")
        case .airmail: #expect(corner.r > 150 && corner.g < 100 || corner.b > 120 && corner.r < 80, "a red or blue stripe")
        case .vintage: #expect(corner.r > 220 && corner.b < corner.r, "a cream border")
        }
    }

    @Test func backHasMessageStampAndPostmark() throws {
        let layout = PostcardLayout(photoAspectRatio: 1.5)
        var content = PostcardContent(
            style: .classic, message: "Dear Grandma,\nthe sea was cold and the ice cream was warm. We miss you!", recipient: "Grandma",
            place: "Lisbon", date: Date(timeIntervalSince1970: 1_795_000_000))
        let back = try #require(PostcardRenderer.back(photo: photo(), content: content, layout: layout))
        keep(back, "back-landscape.jpg")
        #expect(back.width == 1800 && back.height == 1200)
        let paper = pixel(back, 10, 10)
        #expect(paper.r > 240 && paper.g > 235, "paper")
        let stamp = pixel(back, Int(layout.stampRect.midX), Int(layout.stampRect.midY))
        #expect(stamp.g > stamp.r, "the photo is in the stamp")
        #expect(inkPixels(back, in: layout.messageRect) > 20, "the message is written")
        content.message = ""
        let empty = try #require(PostcardRenderer.back(photo: photo(), content: content, layout: layout))
        #expect(inkPixels(empty, in: layout.messageRect) == 0)
    }

    @Test func portraitCardsAndLongMessagesFit() throws {
        let layout = PostcardLayout(photoAspectRatio: 0.66)
        let message = String(repeating: "So many things to tell you about this trip. ", count: 12)
        let content = PostcardContent(style: .airmail, message: message, recipient: "The Smiths", place: "", date: Date())
        let back = try #require(PostcardRenderer.back(photo: photo(width: 600, height: 900), content: content, layout: layout))
        let front = try #require(PostcardRenderer.front(photo: photo(width: 600, height: 900), content: content, layout: layout))
        keep(back, "back-portrait.jpg")
        keep(front, "front-portrait.jpg")
        #expect(back.width == 1200 && back.height == 1800)
        // Nothing of the message runs out of its place: the text was made smaller to fit.
        let below = CGRect(
            x: layout.backMargin, y: layout.messageRect.maxY + 4, width: layout.size.width - 2 * layout.backMargin,
            height: layout.divider.from.y - layout.messageRect.maxY - 8)
        #expect(inkPixels(back, in: below) == 0)
        #expect(PostcardRenderer.jpeg(back).map { $0.count > 10_000 } == true)
    }

    /// With `PHOTOS_POSTCARD_PHOTO` (a JPEG) and `PHOTOS_POSTCARD_PREVIEWS`, every style is drawn with that photo to look at.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_POSTCARD_PHOTO"] != nil)) func previewsWithARealPhoto() throws {
        let url = URL(filePath: ProcessInfo.processInfo.environment["PHOTOS_POSTCARD_PHOTO"]!)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let layout = PostcardLayout(photoAspectRatio: Double(image.width) / Double(image.height))
        for style in PostcardStyle.allCases {
            let content = PostcardContent(
                style: style, message: "Hello from Barcelona! The square was full of music until late. Wish you were here.",
                recipient: "Grandma", greeting: PostcardContent.defaultGreeting(place: "Barcelona"), place: "Barcelona", date: Date())
            keep(try #require(PostcardRenderer.front(photo: image, content: content, layout: layout)), "real-front-\(style.rawValue).jpg")
            keep(try #require(PostcardRenderer.back(photo: image, content: content, layout: layout)), "real-back-\(style.rawValue).jpg")
        }
    }

    @Test func fittingShrinksLongTextButNotBelowTheMinimum() {
        let short = PostcardRenderer.fittingSize("Hi", fonts: PostcardRenderer.handwritingFonts, sizes: 20...80, width: 600, height: 400)
        #expect(short == 80)
        let long = PostcardRenderer.fittingSize(
            String(repeating: "word ", count: 300), fonts: PostcardRenderer.handwritingFonts, sizes: 20...80, width: 600, height: 400)
        #expect(long == 20)
        let medium = PostcardRenderer.fittingSize(
            String(repeating: "word ", count: 40), fonts: PostcardRenderer.handwritingFonts, sizes: 20...80, width: 600, height: 400)
        #expect(medium > 20 && medium < 80)
    }
}
