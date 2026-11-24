// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

/// Fixtures follow the formats as documented by real exports (SPEC §15.7 lists the sources): Apple's iCloud Photos
/// data export (Oct 2026), Facebook's and Instagram's JSON "Download your information" (2018–2026 layouts).
enum ImportFixtures {
    static func json(_ text: String) -> Data { Data(text.utf8) }

    /// A small real JPEG without any metadata (what Facebook and Instagram hand out), or with the given properties.
    static func jpeg(width: Int = 40, height: Int = 30, properties: [CFString: Any] = [:]) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Apple: two parts, details per part, a deleted photo, a photo listed without its file (Advanced Data Protection), a
    /// Live Photo video renamed for a clash, album lists in the last part, a shared album.
    static func iCloud(_ fixture: TakeoutFixture) throws {
        let part1 = "iCloud Photos Part 1 of 2"
        let part2 = "iCloud Photos Part 2 of 2"
        try fixture.write("\(part1)/Photos/IMG_0001.HEIC", Data(repeating: 1, count: 1000))
        try fixture.write("\(part1)/Photos/IMG_0002.JPG", Data(repeating: 2, count: 1100))
        try fixture.write("\(part1)/Photos/IMG_0003.MOV", Data(repeating: 3, count: 3000))
        try fixture.write("\(part1)/Photos/IMG_0861.HEIC", Data(repeating: 4, count: 900))
        try fixture.write("\(part1)/Photos/IMG_0861-1.MOV", Data(repeating: 5, count: 2000))
        try fixture.write(
            "\(part1)/Photos/Photo Details.csv",
            json(
                """
                imgName,fileChecksum,favorite,hidden,deleted,originalCreationDate,viewCount,importDate
                IMG_0001.HEIC,AaLN71BK/IQ7+GPvj62bFnuAJotI,yes,no,no,"Tuesday November 19,2024 8:31 AM GMT",0,"Tuesday November 19,2024 8:31 AM GMT"
                IMG_0002.JPG,AXWXC0XOUPQt5Gsk/6Jb93Avjm3b,no,yes,no,"Friday June 7,2024 1:12 PM GMT",6,"Friday June 7,2024 1:12 PM GMT"
                IMG_0003.MOV,AQ,no,no,no,"Saturday January 2,2021 3:54 PM GMT",0,"Saturday January 2,2021 3:54 PM GMT"
                IMG_0861.HEIC,AQ,no,no,no,"Monday September 26,2022 6:48 PM GMT",0,"Monday September 26,2022 6:48 PM GMT"
                IMG_0861.MOV,AQ,no,no,no,"Monday September 26,2022 6:48 PM GMT",0,"Monday September 26,2022 6:48 PM GMT"
                IMG_0004.HEIC,AQ,no,no,yes,"Monday September 26,2022 6:50 PM GMT",0,"Monday September 26,2022 6:50 PM GMT"
                IMG_0999.HEIC,AQ,no,no,no,"Monday September 26,2022 6:52 PM GMT",0,"Monday September 26,2022 6:52 PM GMT"

                """))
        try fixture.write("\(part1)/Recently Deleted/IMG_0004.HEIC", Data(repeating: 6, count: 800))
        try fixture.write(
            "\(part1)/iCloud Shared Albums/iCloud Shared Albums/My Albums/Family/07D058F8-0F82-45C1-BB5D-868D1.jpg",
            Data(repeating: 7, count: 700))
        // The camera's counter repeats: another IMG_0001 in the second part, with its own row.
        try fixture.write("\(part2)/Photos/IMG_0001.HEIC", Data(repeating: 8, count: 1200))
        try fixture.write(
            "\(part2)/Photos/Photo Details-1.csv",
            json(
                """
                imgName,fileChecksum,favorite,hidden,deleted,originalCreationDate,viewCount,importDate
                IMG_0001.HEIC,AQ,no,no,no,"Thursday March 5,2015 9:05 AM GMT",0,"Thursday March 5,2015 9:05 AM GMT"

                """))
        try fixture.write("\(part2)/Albums/Trip ✈️.csv", json("Images\nIMG_0002.JPG\n"))
        try fixture.write("\(part2)/Albums/Favorites.csv", json("Images\nIMG_0001.HEIC\n"))
        try fixture.write("\(part2)/Memories/1 June 2020.csv", json("Images\nIMG_0003.MOV\n"))
    }

    /// Facebook 2024–2026: an album (with its cover), a post with a photo, its text and check-in, a missing photo, a video
    /// with its still, a conversation, the trash index (no media).
    static func facebook(_ fixture: TakeoutFixture, jpeg: Data) throws {
        let posts = "your_facebook_activity/posts"
        try fixture.write("\(posts)/media/Lake2023_10160123/412_10160_n.jpg", jpeg)
        try fixture.write("\(posts)/media/your_posts/2_n.jpg", Data(repeating: 2, count: 600))
        try fixture.write("\(posts)/media/videos/3.mp4", Data(repeating: 3, count: 4000))
        try fixture.write("\(posts)/media/videos/thumb_3.jpg", Data(repeating: 4, count: 100))
        try fixture.write(
            "\(posts)/album/0.json",
            json(
                #"""
                {"name":"Lake 2023","photos":[{"uri":"your_facebook_activity/posts/media/Lake2023_10160123/412_10160_n.jpg","creation_timestamp":1693574400,
                  "media_metadata":{"photo_metadata":{"exif_data":[{"taken_timestamp":1693560000,"latitude":47.36,"longitude":8.54,"camera_make":"Apple","original_width":4032,"original_height":3024}]}},
                  "title":"Lake 2023","description":"CafÃ© am See"}],
                 "cover_photo":{"uri":"your_facebook_activity/posts/media/Lake2023_10160123/412_10160_n.jpg","creation_timestamp":1693574400},
                 "last_modified_timestamp":1693600000,"description":""}
                """#))
        try fixture.write(
            "\(posts)/your_posts__check_ins__photos_and_videos_1.json",
            json(
                #"""
                [{"timestamp":1700000000,"data":[{"post":"Sunset!"}],"attachments":[{"data":[
                    {"media":{"uri":"your_facebook_activity/posts/media/your_posts/2_n.jpg","creation_timestamp":1700000000,"media_metadata":{"photo_metadata":{"exif_data":[{"upload_ip":"1.2.3.4","taken_timestamp":-62169958800}]}}}},
                    {"place":{"name":"Zurich","coordinate":{"latitude":47.37,"longitude":8.54}}}]}]},
                 {"timestamp":1700000100,"attachments":[{"data":[{"media":{"uri":"your_facebook_activity/posts/media/your_posts/missing.jpg","creation_timestamp":1700000100}}]}]},
                 {"timestamp":1700000200,"data":[{"post":"Just text"}]}]
                """#))
        try fixture.write(
            "\(posts)/your_videos.json",
            json(
                #"""
                {"videos_v2":[{"uri":"your_facebook_activity/posts/media/videos/3.mp4","creation_timestamp":1700001000,"description":"Clip",
                  "thumbnail":{"uri":"your_facebook_activity/posts/media/videos/thumb_3.jpg"},
                  "media_metadata":{"video_metadata":{"exif_data":[{"upload_ip":"1.2.3.4","upload_timestamp":1700001000}]}}}]}
                """#))
        try fixture.write("\(posts)/trash.json", json(#"[{"timestamp":1700000300,"label_values":[{"label":"x"}],"fbid":"1"}]"#))
        try fixture.write("your_facebook_activity/messages/inbox/anna_123/photos/9.jpg", Data(repeating: 9, count: 300))
        try fixture.write(
            "your_facebook_activity/messages/inbox/anna_123/message_1.json",
            json(#"{"messages":[{"photos":[{"uri":"your_facebook_activity/messages/inbox/anna_123/photos/9.jpg","creation_timestamp":1}]}]}"#))
    }

    /// Instagram 2025–2026: a post with two photos (caption on the post), a single WebP post (caption on the photo), a story,
    /// a profile picture, an archived post, a recently deleted one, a conversation; media at the root next to
    /// `your_instagram_activity`.
    static func instagram(_ fixture: TakeoutFixture, root: String = "instagram-frank-2026-11-20") throws {
        let index = "\(root)/your_instagram_activity/media"
        try fixture.write("\(root)/media/posts/202310/18021506776827159.jpg", Data(repeating: 1, count: 500))
        try fixture.write("\(root)/media/posts/202310/18007808255000483.jpg", Data(repeating: 2, count: 510))
        try fixture.write("\(root)/media/posts/202401/18017863637042829.webp", Data(repeating: 3, count: 520))
        try fixture.write("\(root)/media/stories/202401/s1.mp4", Data(repeating: 4, count: 2000))
        try fixture.write("\(root)/media/other/p1.jpg", Data(repeating: 5, count: 300))
        try fixture.write("\(root)/media/archived_posts/202301/a1.jpg", Data(repeating: 6, count: 310))
        try fixture.write("\(root)/media/recently_deleted/202401/d1.jpg", Data(repeating: 7, count: 320))
        try fixture.write("\(root)/your_instagram_activity/messages/inbox/bob_1/photos/m1.jpg", Data(repeating: 8, count: 330))
        try fixture.write(
            "\(index)/posts_1.json",
            json(
                #"""
                [{"media":[{"uri":"media/posts/202310/18021506776827159.jpg","creation_timestamp":1697847664,"media_metadata":{"photo_metadata":{"exif_data":[{"latitude":-32.9067,"longitude":151.7478},{"date_time_original":"2023:10:07 16:52:20","source_type":"library"}]}},"title":"","cross_post_source":{"source_app":"FB"}},
                           {"uri":"media/posts/202310/18007808255000483.jpg","creation_timestamp":1697847664,"media_metadata":{"camera_metadata":{"has_camera_metadata":false}},"title":""}],
                  "title":"Set times â\u0080\u0094 6pm","creation_timestamp":1697847665},
                 {"media":[{"uri":"media/posts/202401/18017863637042829.webp","creation_timestamp":1704100000,"media_metadata":{},"title":"CafÃ© ð\u009f\u0098\u008a"}]}]
                """#))
        try fixture.write(
            "\(index)/stories.json",
            json(#"{"ig_stories":[{"uri":"media/stories/202401/s1.mp4","creation_timestamp":1704200000,"title":""}]}"#))
        try fixture.write(
            "\(index)/profile_photos.json",
            json(#"{"ig_profile_picture":[{"uri":"media/other/p1.jpg","creation_timestamp":1600000000,"title":""}]}"#))
        try fixture.write(
            "\(index)/archived_posts.json",
            json(#"{"ig_archived_post_media":[{"media":[{"uri":"media/archived_posts/202301/a1.jpg","creation_timestamp":1672600000,"title":"old"}]}]}"#))
        try fixture.write(
            "\(index)/recently_deleted_content.json",
            json(#"{"ig_recently_deleted_media":[{"media":[{"uri":"media/recently_deleted/202401/d1.jpg","creation_timestamp":1704300000,"title":""}]}]}"#))
    }
}

@Suite struct ImportSourceTests {
    func item(_ plan: ImportPlan, _ name: String) -> ImportItem? { plan.items.first { $0.name == name } }

    @Test func readsApplesICloudPhotosExport() throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        try ImportFixtures.iCloud(fixture)
        let plan = try ImportPlanner.plan(try ExportFiles.open([fixture.root]))

        #expect(plan.items.allSatisfy { $0.source == .iCloudPhotos })
        #expect(plan.items.count == 7)
        let first = try #require(plan.items.first { $0.name == "IMG_0001.HEIC" && $0.size == 1000 })
        // "Tuesday November 19,2024 8:31 AM GMT"
        #expect(first.takenAt == Date(timeIntervalSince1970: 1_732_005_060))
        #expect(first.metadata.timeSource == .captureMinute)
        #expect(first.metadata.favorite)
        #expect(first.albums.isEmpty, "the Favorites list is no album")
        let other = try #require(plan.items.first { $0.name == "IMG_0001.HEIC" && $0.size == 1200 })
        #expect(other.takenAt == Date(timeIntervalSince1970: 1_425_546_300), "its own part's row, not the first part's")
        #expect(!other.metadata.favorite)
        let hidden = try #require(item(plan, "IMG_0002.JPG"))
        #expect(hidden.metadata.hidden)
        #expect(hidden.albums == ["Trip ✈️"], "album lists name files of other parts")
        #expect(item(plan, "IMG_0861-1.MOV")?.takenAt == item(plan, "IMG_0861.HEIC")?.takenAt, "renamed Live Photo video")
        #expect(item(plan, "07D058F8-0F82-45C1-BB5D-868D1.jpg")?.albums == ["Family"], "shared album folder")
        #expect(plan.albums.map(\.title).sorted() == ["Family", "Trip ✈️"])
        #expect(plan.skipped[.deleted] == 1)
        #expect(plan.skipped[.listedWithoutFile] == 1)
        #expect(plan.skippedExamples[.listedWithoutFile] == ["IMG_0999.HEIC"])
        #expect(item(plan, "IMG_0004.HEIC") == nil)
    }

    @Test func readsAppleDatesAndCSVQuirks() {
        #expect(AppleICloudExport.date("Tuesday November 19,2024 8:31 AM GMT") == Date(timeIntervalSince1970: 1_732_005_060))
        #expect(AppleICloudExport.date("Tuesday November 19, 2024 8:31 PM GMT") == Date(timeIntervalSince1970: 1_732_048_260))
        #expect(AppleICloudExport.date("Tuesday November 19,2024 8:31\u{202F}AM GMT") == Date(timeIntervalSince1970: 1_732_005_060))
        #expect(AppleICloudExport.date("yesterday") == nil)
        #expect(
            CSV.parse("\u{FEFF}a,b\r\n\"x, y\",\"say \"\"hi\"\"\"\n\"multi\nline\",z") == [
                ["a", "b"], ["x, y", "say \"hi\""], ["multi\nline", "z"],
            ])
        #expect(AppleICloudExport.isPartFolder("iCloud Photos Part 1 of 72"))
        #expect(AppleICloudExport.isPartFolder("iCloud Fotos Teil 1 von 37"))
        #expect(AppleICloudExport.isPartFolder("iCloud-bilder Del 1 av 6"))
        #expect(!AppleICloudExport.isPartFolder("Holiday 2019"))
    }

    @Test func readsFacebooksExport() throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        try ImportFixtures.facebook(fixture, jpeg: ImportFixtures.jpeg())
        let plan = try ImportPlanner.plan(try ExportFiles.open([fixture.root]))

        #expect(plan.items.map(\.name).sorted() == ["2_n.jpg", "3.mp4", "412_10160_n.jpg"], "no video stills, no conversations")
        #expect(plan.items.allSatisfy { $0.source == .facebook })
        let album = try #require(item(plan, "412_10160_n.jpg"))
        #expect(album.albums == ["Lake 2023"])
        #expect(album.metadata.caption == "Café am See", "Meta's escaped UTF-8 is repaired")
        #expect(album.takenAt == Date(timeIntervalSince1970: 1_693_560_000))
        #expect(album.metadata.timeSource == .capture)
        #expect(album.metadata.latitude == 47.36)
        #expect(album.metadata.originalWidth == 4032)
        #expect(plan.duplicatesInExport == 0, "the album's cover is the same photo, not a copy")
        let post = try #require(item(plan, "2_n.jpg"))
        #expect(post.metadata.caption == "Sunset!", "the post's text")
        #expect(post.takenAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(post.metadata.timeSource == .posted, "Facebook's placeholder capture time is ignored")
        #expect(post.metadata.latitude == 47.37, "the post's check-in")
        let video = try #require(item(plan, "3.mp4"))
        #expect(video.kind == .video)
        #expect(video.metadata.caption == "Clip")
        #expect(plan.albums.map(\.title) == ["Lake 2023"])
        #expect(plan.skipped[.missingFile] == 1)
        #expect(plan.skipped[.messages] == 1)
    }

    @Test func readsFacebooksOlderLayoutBelowAPickedFolder() throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        try fixture.write("facebook-frank/photos_and_videos/Trip_9/4.jpg", Data(repeating: 1, count: 100))
        try fixture.write(
            "facebook-frank/photos_and_videos/album/0.json",
            ImportFixtures.json(
                #"""
                {"name":"MÃ¼nchen","photos":[{"uri":"photos_and_videos/Trip_9/4.jpg","creation_timestamp":1500000000,
                  "media_metadata":{"photo_metadata":{"taken_timestamp":1499990000,"latitude":48.1,"longitude":11.5}}}]}
                """#))
        let plan = try ImportPlanner.plan(try ExportFiles.open([fixture.root.appending(path: "facebook-frank")]))
        let photo = try #require(plan.items.first)
        #expect(plan.items.count == 1)
        #expect(photo.albums == ["München"])
        #expect(photo.takenAt == Date(timeIntervalSince1970: 1_499_990_000), "the 2018–2019 flat photo_metadata")
        #expect(photo.metadata.latitude == 48.1)
    }

    @Test func readsInstagramsExport() throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        try ImportFixtures.instagram(fixture)
        let plan = try ImportPlanner.plan(try ExportFiles.open([fixture.root]))

        #expect(plan.items.allSatisfy { $0.source == .instagram })
        #expect(
            plan.items.map(\.name).sorted() == [
                "18007808255000483.jpg", "18017863637042829.webp", "18021506776827159.jpg", "a1.jpg", "p1.jpg", "s1.mp4",
            ])
        let first = try #require(item(plan, "18021506776827159.jpg"))
        #expect(first.metadata.caption == "Set times — 6pm", "the post's caption, repaired")
        #expect(first.metadata.timeSource == .capture)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: first.takenAt!)
        #expect(components == DateComponents(year: 2023, month: 10, day: 7, hour: 16, minute: 52, second: 20))
        #expect(first.metadata.latitude == -32.9067 && first.metadata.longitude == 151.7478, "exif_data elements are merged")
        let second = try #require(item(plan, "18007808255000483.jpg"))
        #expect(second.metadata.caption == "Set times — 6pm")
        #expect(second.metadata.timeSource == .posted)
        #expect(second.takenAt == Date(timeIntervalSince1970: 1_697_847_664))
        #expect(item(plan, "18017863637042829.webp")?.metadata.caption == "Café 😊", "a single photo's own caption")
        #expect(item(plan, "s1.mp4")?.albums == [InstagramExport.storiesAlbum])
        #expect(item(plan, "p1.jpg")?.albums == [InstagramExport.profileAlbum])
        #expect(item(plan, "a1.jpg")?.metadata.hidden == true, "archived posts go to the archive")
        #expect(plan.skipped[.deleted] == 1)
        #expect(plan.skipped[.messages] == 1)
    }

    @Test func readsInstagramsOldestExport() throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        try fixture.write("frank_20190101/photos/201811/abc.jpg", Data(repeating: 1, count: 100))
        try fixture.write("frank_20190101/stories/201812/def.mp4", Data(repeating: 2, count: 200))
        try fixture.write(
            "frank_20190101/media.json",
            ImportFixtures.json(
                #"""
                {"photos":[{"caption":"First!","taken_at":"2018-11-05T20:19:29","path":"photos/201811/abc.jpg"}],
                 "stories":[{"caption":"","taken_at":"2018-12-01T10:00:00+00:00","path":"stories/201812/def.mp4"}],"videos":[],"profile":[]}
                """#))
        let plan = try ImportPlanner.plan(try ExportFiles.open([fixture.root]))
        #expect(plan.items.count == 2)
        #expect(plan.items.allSatisfy { $0.source == .instagram })
        #expect(item(plan, "abc.jpg")?.metadata.caption == "First!")
        #expect(item(plan, "abc.jpg")?.takenAt == Date(timeIntervalSince1970: 1_541_449_169))
        #expect(item(plan, "def.mp4")?.albums == [InstagramExport.storiesAlbum])
    }

    @Test func exportsOfSeveralServicesChosenTogetherStayApart() throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        try fixture.standardExport()
        try ImportFixtures.iCloud(fixture)
        try ImportFixtures.instagram(fixture, root: "")
        try fixture.write("Scans/scan.png", Data(repeating: 1, count: 50))
        try fixture.write("Scans/notes.docx", Data(repeating: 1, count: 50))
        let plan = try ImportPlanner.plan(try ExportFiles.open([fixture.root]))
        let bySource = Dictionary(grouping: plan.items, by: \.source).mapValues(\.count)
        #expect(bySource[.googlePhotos] == 4)
        #expect(bySource[.iCloudPhotos] == 7)
        #expect(bySource[.instagram] == 6)
        #expect(bySource[.files] == 1)
        #expect(plan.skipped[.unsupportedType] == 1)
    }

    @Test func theSamePhotoInTwoExportsIsImportedOnce() throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        // Google keeps the original: the same bytes as Apple's, with a sidecar to the second.
        try fixture.write("Takeout/Google Photos/Photos from 2024/IMG_0001.HEIC", Data(repeating: 1, count: 1000))
        try fixture.sidecar("Takeout/Google Photos/Photos from 2024/IMG_0001.HEIC.json", time: 1_732_005_085, description: "Lake")
        try fixture.write("Takeout/Google Photos/Lake/IMG_0001.HEIC", Data(repeating: 1, count: 1000))
        try fixture.sidecar("Takeout/Google Photos/Lake/IMG_0001.HEIC.json", time: 1_732_005_085)
        try ImportFixtures.iCloud(fixture)
        let plan = try ImportPlanner.plan(try ExportFiles.open([fixture.root]))
        let copies = plan.items.filter { $0.name == "IMG_0001.HEIC" && $0.size == 1000 }
        #expect(copies.count == 1)
        let kept = try #require(copies.first)
        #expect(kept.source == .googlePhotos, "the capture time to the second wins")
        #expect(kept.alsoIn == [.iCloudPhotos])
        #expect(kept.metadata.favorite, "Apple's favourite")
        #expect(kept.metadata.caption == "Lake")
        #expect(kept.albums == ["Lake"])
        #expect(plan.duplicatesAcrossSources == 1)
        #expect(plan.duplicatesInExport == 1)
    }

    @Test func repairsMetasEscapedText() {
        #expect(MetaExport.fixText("Caf\u{00c3}\u{00a9}") == "Café")
        #expect(MetaExport.fixText("\u{00f0}\u{009f}\u{0098}\u{008a}") == "😊")
        #expect(MetaExport.fixText("Café") == "Café", "real Latin-1 text that is no UTF-8 stays")
        #expect(MetaExport.fixText("Grüße 😊") == "Grüße 😊")
        #expect(MetaExport.timestamp(-62_169_958_800) == nil)
    }
}

@Suite struct ImportMatcherTests {
    func item(
        _ name: String, size: UInt64, at seconds: TimeInterval, source: ImportSourceKind, time: ImportMetadata.TimeSource = .capture,
        width: Int? = nil, height: Int? = nil
    ) -> ImportItem {
        var metadata = ImportMetadata(takenAt: Date(timeIntervalSince1970: seconds), timeSource: time)
        metadata.originalWidth = width
        metadata.originalHeight = height
        return ImportItem(
            origin: .file(ExportFiles.File(path: name, size: size)), name: name, size: size, kind: .image, source: source, metadata: metadata)
    }

    func candidate(_ name: String, size: Int64, at seconds: TimeInterval, width: Int? = nil, height: Int? = nil, id: FileID = 1)
        -> RemoteCandidate
    {
        RemoteCandidate(
            fileId: id, path: "/Photos/\(name)", kind: .image, size: size, capturedAt: Date(timeIntervalSince1970: seconds),
            modifiedAt: Date(timeIntervalSince1970: seconds), width: width, height: height)
    }

    func match(_ item: ImportItem, _ candidates: [RemoteCandidate]) -> ImportMatcher.Rule? {
        var index = BackupMatcher.Index(candidates: candidates, locals: [ImportMatcher.resource(for: item)])
        return ImportMatcher.match(item, index: &index, candidates: candidates)?.1
    }

    @Test func applesMinutesFindTheServersSeconds() {
        let apple = item("IMG_0001.HEIC", size: 1000, at: 1_732_005_060, source: .iCloudPhotos, time: .captureMinute)
        #expect(match(apple, [candidate("IMG_0001.HEIC", size: 999, at: 1_732_005_102)]) == .sameMinute, "same name, same minute")
        #expect(match(apple, [candidate("24-11-19 08-31-42.heic", size: 1000, at: 1_732_005_102)]) == .sameMinute, "same size")
        #expect(match(apple, [candidate("IMG_0002.HEIC", size: 5, at: 1_732_005_102)]) == nil)
        #expect(match(apple, [candidate("IMG_0001.HEIC", size: 5, at: 1_732_005_102 + 3600)]) == .sameMinute, "read without offset")
        #expect(match(apple, [candidate("IMG_0001.HEIC", size: 5, at: 1_732_005_102 + 120)]) == nil)
    }

    @Test func theSameNameAndSizeIsTheSameFile() {
        let google = item("IMG_0001.jpg", size: 1000, at: 1_600_000_000, source: .googlePhotos)
        #expect(match(google, [candidate("IMG_0001 (2).jpg", size: 1000, at: 1_600_000_001.9)]) == .nameAndSize)
        #expect(match(google, [candidate("IMG_0001.jpg", size: 1000, at: 1_600_000_000)]) == .backupRules)
    }

    @Test func reducedCopiesAreFoundByTheirCaptureSecondAlone() {
        let facebook = item("412_10160_n.jpg", size: 90_000, at: 1_693_560_000, source: .facebook, width: 4032, height: 3024)
        let original = candidate("IMG_4711.HEIC", size: 2_400_000, at: 1_693_560_000, width: 3024, height: 4032)
        #expect(match(facebook, [original]) == .reducedCopy)
        #expect(match(facebook, [original, candidate("IMG_4712.HEIC", size: 2_500_000, at: 1_693_560_000, id: 2)]) == nil, "a burst")
        #expect(match(facebook, [candidate("IMG_4711.HEIC", size: 1, at: 1_693_560_000, width: 1920, height: 1080)]) == nil)
        var posted = facebook
        posted.metadata.timeSource = .posted
        #expect(match(posted, [original]) == nil, "a posting time says nothing about the photo")
        let google = item("IMG_9.jpg", size: 90_000, at: 1_693_560_000, source: .googlePhotos)
        #expect(match(google, [original]) == nil, "only for services that keep reduced copies")
    }
}

@Suite struct ImportMetadataWriterTests {
    @Test func writesTheMissingDatePlaceAndCaptionIntoAPhoto() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "photo.jpg")
        try ImportFixtures.jpeg().write(to: file)
        #expect(ImportMetadataWriter.present(in: file)?.hasCaptureTime == false)

        let taken = Date(timeIntervalSince1970: 1_693_560_000)
        let metadata = ImportMetadata(takenAt: taken, latitude: -33.5, longitude: 151.25, caption: "Café am See")
        let zone = TimeZone(identifier: "Europe/Zurich")!
        let written = try #require(ImportMetadataWriter.addMissing(to: file, metadata: metadata, in: directory, timeZone: zone))
        let present = try #require(ImportMetadataWriter.present(in: written))
        #expect(present.hasCaptureTime && present.hasLocation && present.hasDescription)
        #expect(present.captureDate == taken, "local time with its offset")
        #expect(present.pixelWidth == 40)
        let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(written as CFURL, nil)!, 0, nil) as! [CFString: Any]
        let gps = properties[kCGImagePropertyGPSDictionary] as! [CFString: Any]
        #expect(gps[kCGImagePropertyGPSLatitudeRef] as? String == "S")
        #expect(gps[kCGImagePropertyGPSLongitude] as? Double == 151.25)
        // Nothing is missing any more, and a posting time is never written as a capture time.
        #expect(ImportMetadataWriter.addMissing(to: written, metadata: metadata, in: directory) == nil)
        let posted = ImportMetadata(takenAt: taken, timeSource: .posted)
        #expect(ImportMetadataWriter.addMissing(to: file, metadata: posted, in: directory) == nil)
    }

    @Test func leavesPhotosWithTheirOwnDetailsAlone() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "camera.jpg")
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"]
        try ImportFixtures.jpeg(properties: [kCGImagePropertyExifDictionary: exif]).write(to: file)
        #expect(ImportMetadataWriter.present(in: file)?.hasCaptureTime == true)
        #expect(ImportMetadataWriter.addMissing(to: file, metadata: ImportMetadata(takenAt: Date()), in: directory) == nil)
        let webp = directory.appending(path: "x.webp")
        try Data(repeating: 1, count: 10).write(to: webp)
        #expect(ImportMetadataWriter.addMissing(to: webp, metadata: ImportMetadata(takenAt: Date()), in: directory) == nil)
        #expect(ImportMetadataWriter.timeZone("+05:30")?.secondsFromGMT() == 19_800)
        #expect(ImportMetadataWriter.offsetString(-12_600) == "-03:30")
    }
}

@Suite struct ImportRunTests {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func importsFacebookWithDetailsWrittenBackAndAWelcomeHomeSummary() async throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        try ImportFixtures.facebook(fixture, jpeg: ImportFixtures.jpeg())
        let files = try ExportFiles.open([fixture.root])
        let plan = try ImportPlanner.plan(files)
        let remote = FakeImportRemote()
        let journal = fixture.root.appending(path: "journal")
        let options = ImportOptions(destination: "/Photos")
        let importer = LibraryImporter(files: files, plan: plan, remote: remote, options: options, journalDirectory: journal, calendar: utc)
        let result = await importer.run { _ in }
        #expect(result.phase == .finished)
        #expect(result.uploaded == 3)
        let uploads = remote.state.withLock { $0.uploads }
        let photo = try #require(uploads.first { $0.name == "412_10160_n.jpg" })
        #expect(photo.folder == "/Photos/Facebook/2023")
        #expect(photo.capturedAt == Date(timeIntervalSince1970: 1_693_560_000))
        #expect(photo.size > ImportFixtures.jpeg().count, "the date, place and caption went into the file")
        #expect(remote.state.withLock { Set($0.comments.values) } == ["Café am See", "Sunset!", "Clip"])
        #expect(remote.state.withLock { $0.albumItems["Lake 2023"] } == ["/Photos/Facebook/2023/412_10160_n.jpg"])

        let summary = ImportSummary.make(plan: plan, journal: await importer.currentJournal, progress: result, options: options)
        #expect(summary.home == 3)
        #expect(summary.photos == 2 && summary.videos == 1)
        #expect(summary.albums == 1)
        #expect(summary.years == 2023...2023)
        #expect(summary.metadataAdded == 1)
        #expect(summary.captions == 3)
        #expect(!summary.nothingLost, "a photo the export names is missing")
        #expect(summary.notImported == 1)
        let report = summary.reportText()
        #expect(report.contains("3 photos and videos · 1 albums · from 2023"))
        #expect(report.contains("missing.jpg"))
        let url = try #require(await importer.writeReport(summary, upload: true))
        #expect(try String(contentsOf: url, encoding: .utf8) == report)
        #expect(remote.state.withLock { $0.uploads.last?.folder } == "/Photos", "the report next to the photos")
    }

    @Test func favouritesHiddenPhotosAndCopiesOnTheServer() async throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        try ImportFixtures.iCloud(fixture)
        let files = try ExportFiles.open([fixture.root])
        let plan = try ImportPlanner.plan(files)
        let remote = FakeImportRemote()
        // The favourite IMG_0001 (8:31 GMT) is on the server, with seconds, from a backup.
        remote.state.withLock {
            $0.candidates = [
                RemoteCandidate(
                    fileId: 7, path: "/Photos/2024/IMG_0001.HEIC", kind: .image, size: 1000,
                    capturedAt: Date(timeIntervalSince1970: 1_732_005_085), modifiedAt: Date())
            ]
        }
        let options = ImportOptions(destination: "/Photos")
        let result = await LibraryImporter(
            files: files, plan: plan, remote: remote, options: options, journalDirectory: fixture.root.appending(path: "j"), calendar: utc
        ).run { _ in }
        #expect(result.phase == .finished)
        #expect(result.duplicates == 1)
        #expect(result.uploaded == 6)
        #expect(remote.state.withLock { $0.favorites } == ["/Photos/2024/IMG_0001.HEIC"], "the server's copy becomes a favourite")
        let hidden = try #require(remote.state.withLock { $0.uploads.first { $0.name == "IMG_0002.JPG" } })
        #expect(hidden.folder == "/.archive/Photos/iCloud Photos/2024")
    }

    @Test func stopsBeforeTheDeviceRunsFull() async throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        try ImportFixtures.instagram(fixture)
        let files = try ExportFiles.open([fixture.root])
        let plan = try ImportPlanner.plan(files)
        let remote = FakeImportRemote()
        let result = await LibraryImporter(
            files: files, plan: plan, remote: remote, options: ImportOptions(destination: "/Photos"),
            journalDirectory: fixture.root.appending(path: "j"), spaceMargin: Int64.max / 4
        ).run { _ in }
        guard case .stopped(let reason) = result.phase else {
            Issue.record("the import should stop, not \(result.phase)")
            return
        }
        #expect(reason.contains("not enough free space"))
        #expect(remote.state.withLock { $0.uploads.isEmpty })
    }
}

/// Imports Apple and Facebook exports into a real server (PHOTOS_IT_SERVER/USER/PASSWORD): dates written back into a
/// Facebook photo, a favourite, a hidden photo in the archive, a caption as a comment, an album; then imports them again
/// without uploading anything, and removes what it created.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct ImportIntegrationTests {
    @Test func bringsAppleAndFacebookHomeAndNothingTwice() async throws {
        let env = ProcessInfo.processInfo.environment
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let http = HTTPClient(trustStore: TrustStore(directory: nil))
        let connection = ServerConnection(
            serverURL: URL(string: env["PHOTOS_IT_SERVER"]!)!, userId: user, loginName: user, appPassword: env["PHOTOS_IT_PASSWORD"] ?? "",
            userAgent: "tests")
        let api = PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
        let run = String(UUID().uuidString.prefix(6))
        let destination = "/Photos/r5-import-\(run)"
        let album = "r5-import-album-\(run)"
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        // Distinct times and pixels per run, so the server has no copy from an earlier run.
        let minute = 1_500_000_000 / 60 * 60 + Int.random(in: 0..<500_000) * 60
        let part = "iCloud Photos Part 1 of 1"
        let width = 40 + Int.random(in: 0..<200)
        try fixture.write("\(part)/Photos/IMG_\(run)_1.JPG", ImportFixtures.jpeg(width: width))
        try fixture.write("\(part)/Photos/IMG_\(run)_2.JPG", ImportFixtures.jpeg(width: width + 1))
        let date = Date(timeIntervalSince1970: TimeInterval(minute))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEEE MMMM d,yyyy h:mm a 'GMT'"
        try fixture.write(
            "\(part)/Photos/Photo Details.csv",
            ImportFixtures.json(
                """
                imgName,fileChecksum,favorite,hidden,deleted,originalCreationDate,viewCount,importDate
                IMG_\(run)_1.JPG,AQ,yes,no,no,"\(formatter.string(from: date))",0,"\(formatter.string(from: date))"
                IMG_\(run)_2.JPG,AQ,no,yes,no,"\(formatter.string(from: date))",0,"\(formatter.string(from: date))"

                """))
        try fixture.write("\(part)/Albums/\(album).csv", ImportFixtures.json("Images\nIMG_\(run)_1.JPG\n"))
        let taken = minute + 3_600_000 + 17
        try fixture.write("your_facebook_activity/posts/media/x/fb_\(run).jpg", ImportFixtures.jpeg(width: width + 2))
        try fixture.write(
            "your_facebook_activity/posts/your_uncategorized_photos.json",
            ImportFixtures.json(
                """
                {"other_photos_v2":[{"uri":"your_facebook_activity/posts/media/x/fb_\(run).jpg","creation_timestamp":\(taken + 999),
                  "media_metadata":{"photo_metadata":{"exif_data":[{"taken_timestamp":\(taken)}]}},"description":"Hello from Facebook"}]}
                """))
        let files = try ExportFiles.open([fixture.root])
        let plan = try ImportPlanner.plan(files)
        #expect(plan.items.count == 3)

        let database = try AccountDatabase.temporary()
        let features = ServerFeatures(serverVersion: ServerVersion(major: 33), enabled: [.comments])
        var options = ImportOptions(destination: destination)
        options.yearSubfolders = false
        defer {
            Task {
                try? await api.dav.delete(connection.filesURL(destination))
                try? await api.dav.delete(connection.filesURL("/.archive" + destination))
                try? await api.deleteAlbum(Album(kind: .own, name: album))
            }
        }
        let first = await LibraryImporter(
            files: files, plan: plan, api: api, database: database, features: features, options: options,
            journalDirectory: fixture.root.appending(path: "journal")
        ).run { _ in }
        #expect(first.phase == .finished, "\(first.failures)")
        #expect(first.uploaded == 3)

        // The Facebook photo has its capture time in its own EXIF now: the server reads it.
        let facebook = "\(destination)/Facebook/fb_\(run).jpg"
        let resource = try #require(
            try await api.dav.propfind(connection.filesURL(facebook), depth: 0, properties: DAVProp.mediaIndex).first)
        let item = try #require(MediaParser.mediaItem(from: resource, connection: connection))
        #expect(item.modifiedAt == Date(timeIntervalSince1970: TimeInterval(taken)))
        let favorite = try #require(
            try await api.dav.propfind(
                connection.filesURL("\(destination)/iCloud Photos/IMG_\(run)_1.JPG"), depth: 0, properties: DAVProp.mediaIndex
            ).first.flatMap { MediaParser.mediaItem(from: $0, connection: connection) })
        #expect(favorite.isFavorite)
        let hidden = try await api.dav.propfind(
            connection.filesURL("/.archive\(destination)/iCloud Photos/IMG_\(run)_2.JPG"), depth: 0, properties: [DAVProp.fileId])
        #expect(hidden.count == 1, "the hidden photo is in the archive")
        let content = try await api.albumContent(Album(kind: .own, name: album))
        #expect(content.map(\.item.name) == ["IMG_\(run)_1.JPG"])

        // A second import (no journal) finds everything on the server.
        let second = await LibraryImporter(
            files: files, plan: plan, api: api, database: database, features: features, options: options,
            journalDirectory: fixture.root.appending(path: "journal2")
        ).run { _ in }
        #expect(second.phase == .finished)
        #expect(second.uploaded == 0)
        #expect(second.duplicates == 3)

        try await api.dav.delete(connection.filesURL(destination))
        try await api.dav.delete(connection.filesURL("/.archive" + destination))
        try await api.deleteAlbum(Album(kind: .own, name: album))
    }
}
