// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Testing

@testable import PhotosDomain

/// Colour from the photo (SPEC §16.8.1).
@Suite struct PhotoPaletteTests {
    /// A spread of colours across hues, saturations and lightness, including black, white and greys.
    static let sweep: [PaletteColor] = {
        var colors: [PaletteColor] = [.black, .white, PaletteColor(red: 0.5, green: 0.5, blue: 0.5)]
        for hue in stride(from: 0.0, to: 1.0, by: 1.0 / 24) {
            for saturation in [0.0, 0.2, 0.6, 1.0] {
                for lightness in [0.05, 0.3, 0.5, 0.7, 0.95] {
                    colors.append(PaletteColor(hue: hue, saturation: saturation, lightness: lightness))
                }
            }
        }
        return colors
    }()

    @Test func luminanceAndContrastFollowWCAG() {
        #expect(PaletteColor.white.relativeLuminance == 1)
        #expect(PaletteColor.black.relativeLuminance == 0)
        #expect(abs(PaletteColor.white.contrast(with: .black) - 21) < 0.001)
        #expect(PaletteColor.white.contrast(with: .white) == 1)
        // #767676 is the classic 4.54:1 grey on white.
        let grey = PaletteColor(bytes: 0x76, 0x76, 0x76)
        #expect(abs(grey.contrast(with: .white) - 4.54) < 0.01)
    }

    @Test func hslRoundTrips() {
        for color in Self.sweep {
            let (h, s, l) = color.hsl
            let back = PaletteColor(hue: h, saturation: s, lightness: l)
            #expect(abs(back.red - color.red) < 1e-6 && abs(back.green - color.green) < 1e-6 && abs(back.blue - color.blue) < 1e-6)
        }
        let red = PaletteColor(red: 1, green: 0, blue: 0).hsl
        #expect(red.hue == 0 && red.saturation == 1 && red.lightness == 0.5)
    }

    @Test func luminanceTargetIsReachedKeepingTheHue() {
        let teal = PaletteColor(red: 0.1, green: 0.6, blue: 0.55)
        let dark = teal.withLuminance(0.02)
        #expect(abs(dark.relativeLuminance - 0.02) < 0.001)
        #expect(abs(dark.hsl.hue - teal.hsl.hue) < 0.01)
    }

    @Test func colourfulPixelsWinOverGrey() throws {
        // A red coat on a grey street: a quarter red, the rest grey.
        let grey = PaletteColor(red: 0.45, green: 0.45, blue: 0.47)
        let red = PaletteColor(red: 0.8, green: 0.1, blue: 0.12)
        let pixels = Array(repeating: grey, count: 48) + Array(repeating: red, count: 16)
        let dominant = try #require(PhotoPalette.dominant(pixels))
        #expect(dominant.red > 0.7 && dominant.green < 0.2)
    }

    @Test func greyPhotosStayGrey() throws {
        let pixels = (0..<64).map { index in PaletteColor(red: Double(index) / 64, green: Double(index) / 64, blue: Double(index) / 64) }
        let dominant = try #require(PhotoPalette.dominant(pixels))
        #expect(dominant.hsl.saturation < 0.01)
        #expect(abs(dominant.red - 0.49) < 0.05)
        #expect(PhotoPalette.dominant([]) == nil)
    }

    @Test func aFewSpecksDoNotColourAGreyPhoto() throws {
        let grey = PaletteColor(red: 0.5, green: 0.5, blue: 0.5)
        let blue = PaletteColor(red: 0.1, green: 0.2, blue: 0.9)
        let dominant = try #require(PhotoPalette.dominant(Array(repeating: grey, count: 63) + [blue]))
        #expect(dominant == grey)
    }

    @Test(arguments: PhotoTintRole.allCases)
    func everyToneKeepsItsTextReadable(role: PhotoTintRole) {
        for color in Self.sweep {
            let toned = role.tone(color)
            #expect(toned.contrast(with: role.text) >= 7, "\(role) of \(color)")
        }
    }

    @Test func tonesKeepTheHueOfColourfulPhotos() {
        let orange = PaletteColor(red: 0.95, green: 0.55, blue: 0.1)
        for role in PhotoTintRole.allCases {
            #expect(abs(role.tone(orange).hsl.hue - orange.hsl.hue) < 0.02, "\(role)")
        }
        // Calm, not loud.
        #expect(PhotoTintRole.backdrop.tone(orange).hsl.saturation <= 0.55 + 1e-9)
    }

    @Test func ambientFieldKeepsWhiteTextReadableAndFollowsBrightness() {
        let toned = AmbientField.tone(Self.sweep)
        for color in toned { #expect(color.contrast(with: .white) >= 7) }
        let field = AmbientField.tone([PaletteColor(red: 0.9, green: 0.9, blue: 0.3), PaletteColor(red: 0.1, green: 0.1, blue: 0.03)])
        #expect(field[0].relativeLuminance > field[1].relativeLuminance)
    }

    @Test func mixingIsLinearAndClamped() {
        let mixed = PaletteColor.black.mixed(with: .white, amount: 0.25)
        #expect(mixed == PaletteColor(red: 0.25, green: 0.25, blue: 0.25))
        #expect(PaletteColor.black.mixed(with: .white, amount: 2) == .white)
        #expect(PaletteColor(red: 2, green: -1, blue: .nan) == PaletteColor(red: 1, green: 0, blue: 0))
    }
}

/// Album cover choices and the depth layout (SPEC §16.8.2).
@Suite struct AlbumLookTests {
    let early = Date(timeIntervalSince1970: 1_000_000)
    let late = Date(timeIntervalSince1970: 2_000_000)

    @Test func laterChoiceWinsAlbumByAlbum() {
        var ours = AlbumLookBook()
        ours.set(AlbumLook(coverFileId: 1, effect: .depth, updatedAt: late), for: "own:A")
        ours.set(AlbumLook(coverFileId: 2, effect: .still, updatedAt: early), for: "own:B")
        var theirs = AlbumLookBook()
        theirs.set(AlbumLook(coverFileId: 9, effect: .automatic, updatedAt: early), for: "own:A")
        theirs.set(AlbumLook(coverFileId: 8, effect: .depth, updatedAt: late), for: "own:B")
        theirs.set(AlbumLook(coverFileId: 7, updatedAt: early), for: "shared:C (anna)")
        let merged = ours.merged(with: theirs)
        #expect(merged.albums["own:A"]?.coverFileId == 1)
        #expect(merged.albums["own:B"]?.coverFileId == 8)
        #expect(merged.albums["shared:C (anna)"]?.coverFileId == 7)
        // Merging is order-independent when times differ.
        #expect(theirs.merged(with: ours) == merged)
    }

    @Test func aTieKeepsOurChoice() {
        var ours = AlbumLookBook()
        ours.set(AlbumLook(coverFileId: 1, updatedAt: late), for: "own:A")
        var theirs = AlbumLookBook()
        theirs.set(AlbumLook(coverFileId: 2, updatedAt: late), for: "own:A")
        #expect(ours.merged(with: theirs).albums["own:A"]?.coverFileId == 1)
    }

    @Test func aResetIsKeptSoItReachesOtherDevices() {
        var book = AlbumLookBook()
        book.set(AlbumLook(coverFileId: 1, effect: .depth, updatedAt: early), for: "own:A")
        var reset = book
        reset.set(AlbumLook(updatedAt: late), for: "own:A")
        #expect(reset.look(for: "own:A") == nil)
        #expect(book.merged(with: reset).look(for: "own:A") == nil)
    }

    @Test func renameMovesTheChoice() {
        var book = AlbumLookBook()
        book.set(AlbumLook(coverFileId: 5, effect: .depth, updatedAt: early), for: "own:Old")
        book.rename(from: "own:Old", to: "own:New", at: late)
        #expect(book.look(for: "own:New")?.coverFileId == 5)
        #expect(book.look(for: "own:New")?.effect == .depth)
        #expect(book.look(for: "own:Old") == nil)
        #expect(book.albums["own:Old"]?.updatedAt == late)
    }

    @Test func fileRoundTripsWithStableBytes() throws {
        var book = AlbumLookBook()
        book.set(AlbumLook(coverFileId: 5, effect: .depth, updatedAt: early), for: "own:B")
        book.set(AlbumLook(coverFileId: nil, effect: .still, updatedAt: late), for: "own:A")
        let data = try book.encoded()
        #expect(try AlbumLookBook.decode(data) == book)
        #expect(try book.encoded() == data)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"cover\" : 5"))
        #expect(text.range(of: "own:A")!.lowerBound < text.range(of: "own:B")!.lowerBound)
    }

    @Test func newerFilesAreReadTolerantly() throws {
        let json = """
            {"version": 3, "future": true, "albums": {
              "own:A": {"cover": 4, "effect": "sparkles", "updated": "2026-11-25T10:00:00Z", "extra": 1},
              "own:B": {"effect": "depth"}
            }}
            """
        let book = try AlbumLookBook.decode(Data(json.utf8))
        #expect(book.version == 3)
        #expect(book.look(for: "own:A")?.effect == .automatic)
        #expect(book.look(for: "own:A")?.coverFileId == 4)
        #expect(book.look(for: "own:B")?.effect == .depth)
        #expect(book.albums["own:B"]?.updatedAt == .distantPast)
        #expect(try AlbumLookBook.decode(Data("{}".utf8)).albums.isEmpty)
    }

    @Test func coverShowsTheCentreOfTheImage() {
        let wide = DepthCoverLayout.visibleRect(imageWidth: 400, imageHeight: 200)
        #expect(wide == CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        let tall = DepthCoverLayout.visibleRect(imageWidth: 300, imageHeight: 600)
        #expect(tall == CGRect(x: 0, y: 0.25, width: 1, height: 0.5))
        #expect(DepthCoverLayout.visibleRect(imageWidth: 0, imageHeight: 10) == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// A mask whose subject fills the image from row `top` down.
    func mask(width: Int, height: Int, subjectFromRow top: Int) -> [UInt8] {
        (0..<(width * height)).map { $0 / width >= top ? 255 : 0 }
    }

    @Test func subjectBelowTheTitleStandsInFrontOfIt() {
        let square = CGRect(x: 0, y: 0, width: 1, height: 1)
        // The subject starts in the lower half: the title band (8 %…38 %) is free.
        let low = DepthCoverLayout.coverage(
            alpha: mask(width: 100, height: 100, subjectFromRow: 50), width: 100, height: 100, visible: square)
        #expect(low == 0)
        #expect(DepthCoverLayout.placement(coverage: low) == .behindSubject)
        // The subject reaches up into the lower part of the title: still in front of it.
        let some = DepthCoverLayout.coverage(
            alpha: mask(width: 100, height: 100, subjectFromRow: 30), width: 100, height: 100, visible: square)
        #expect(some > 0.2 && some < 0.3)
        #expect(DepthCoverLayout.placement(coverage: some) == .behindSubject)
        // A subject that fills the picture would hide the title: the title goes in front.
        let all = DepthCoverLayout.coverage(
            alpha: mask(width: 100, height: 100, subjectFromRow: 0), width: 100, height: 100, visible: square)
        #expect(all == 1)
        #expect(DepthCoverLayout.placement(coverage: all) == .inFront)
        #expect(DepthCoverLayout.placement(coverage: nil) == .inFront)
    }

    @Test func coverageLooksOnlyAtThePartTheCoverShows() {
        // A wide image whose left and right quarters (cut off on a square cover) are all subject.
        let width = 200
        let height = 100
        let alpha: [UInt8] = (0..<(width * height)).map { index in
            let x = index % width
            return x < 50 || x >= 150 ? 255 : 0
        }
        let visible = DepthCoverLayout.visibleRect(imageWidth: width, imageHeight: height)
        #expect(DepthCoverLayout.coverage(alpha: alpha, width: width, height: height, visible: visible) == 0)
        #expect(DepthCoverLayout.coverage(alpha: [], width: width, height: height, visible: visible) == 0)
    }
}

@Suite struct PhotoToneTests {
    @Test func greyPhotosKeepTheBackdropNearBlack() {
        let grey = PhotoTintRole.backdrop.tone(PaletteColor(red: 0.5, green: 0.5, blue: 0.5))
        let teal = PhotoTintRole.backdrop.tone(PaletteColor(red: 0.1, green: 0.6, blue: 0.55))
        #expect(grey.relativeLuminance < teal.relativeLuminance / 2)
        // Light roles are not darkened.
        let light = PhotoTintRole.headerLight.tone(PaletteColor(red: 0.5, green: 0.5, blue: 0.5))
        #expect(light.relativeLuminance > 0.6)
    }
}

@Suite struct DepthPlacementTests {
    /// Measured on the Mac with Vision: a cat whose head reaches into the title (43 %) stands in front of it; a portrait
    /// filling the picture (84 %) would hide it.
    @Test func lockScreenLikeOcclusion() {
        #expect(DepthCoverLayout.placement(coverage: 0.43) == .behindSubject)
        #expect(DepthCoverLayout.placement(coverage: 0.84) == .inFront)
    }
}
