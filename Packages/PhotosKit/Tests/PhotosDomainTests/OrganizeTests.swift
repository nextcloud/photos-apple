// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

private func item(
    _ id: FileID, _ date: Date = day(2024, 6, 14), path: String? = nil, mime: String = "image/jpeg", favorite: Bool = false,
    place: String? = nil, country: String? = nil, uploaded: Date? = nil, offset: Int? = nil, width: Int = 4000, height: Int = 3000,
    livePeer: FileID? = nil, mountType: String = ""
) -> MediaItem {
    MediaItem(
        fileId: id, path: path ?? "/Photos/IMG_\(id).jpg", mimeType: mime, modifiedAt: date, uploadedAt: uploaded, capturedAt: date,
        captureOffset: offset, width: width, height: height, place: place, placeCountry: country, isFavorite: favorite,
        mountType: mountType, livePhotoPeer: livePeer)
}

// MARK: - Smart rules

@Suite struct SmartRuleTests {
    @Test func roundTripsThroughJSON() throws {
        let rule = SmartRule.all([
            .condition(.person("Anna")),
            .any([.condition(.place("Rome")), .condition(.place("IT"))]),
            .not(.condition(.flag(.reject))),
            .condition(.rating(atLeast: 4)),
            .condition(.focalLength(min: 10, max: nil)),
            .condition(.dateRange(start: day(2024, 1, 1), end: day(2025, 1, 1))),
            .condition(.mediaType(.livePhoto)),
            .condition(.olderThanDays(30)),
        ])
        let data = try JSONEncoder().encode(rule)
        #expect(try JSONDecoder().decode(SmartRule.self, from: data) == rule)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""type":"person""#))
        #expect(text.contains(#""all":["#))
    }

    @Test func keepsConditionsOfANewerVersion() throws {
        let json = #"{"id":"a","name":"Future","modifiedAt":5,"rule":{"all":[{"type":"mood","value":"happy"},{"type":"favorite"}]}}"#
        let album = try JSONDecoder().decode(SmartAlbumDefinition.self, from: Data(json.utf8))
        #expect(album.rule.hasUnsupportedConditions)
        #expect(!SmartRuleEvaluator.matches(album.rule, item(1, favorite: true), in: SmartRuleContext()))
        // Written back unchanged.
        let again = String(decoding: try JSONEncoder().encode(album), as: UTF8.self)
        #expect(again.contains(#""type":"mood""#))
        #expect(again.contains(#""value":"happy""#))
    }

    @Test func savedSearchesBecomeRules() {
        let filters = AlbumFilters(
            dateRanges: [.init(start: day(2024, 6, 1, 0), end: day(2024, 6, 30, 0))], places: ["Rome", "Milan"], names: ["beach"])
        let rule = SmartRule(filters)
        let context = SmartRuleContext()
        #expect(SmartRuleEvaluator.matches(rule, item(1, day(2024, 6, 30, 20), path: "/Photos/beach.jpg", place: "Milan"), in: context))
        #expect(!SmartRuleEvaluator.matches(rule, item(2, day(2024, 7, 1, 1), path: "/Photos/beach.jpg", place: "Milan"), in: context))
        #expect(!SmartRuleEvaluator.matches(rule, item(3, day(2024, 6, 10), path: "/Photos/beach.jpg", place: "Paris"), in: context))
        // Free text also looks at the folder.
        #expect(SmartRuleEvaluator.matches(rule, item(4, day(2024, 6, 10), path: "/Photos/Beach days/a.jpg", place: "Rome"), in: context))
    }

    @Test func evaluatesGroupsAndConditions() {
        var context = SmartRuleContext(now: day(2024, 12, 1))
        context.personMembers = ["anna": [1, 2]]
        context.tagMembers = [SmartRuleContext.fold("Drône"): [2]]
        context.albumMembers = ["holiday": [3]]
        context.marks = [1: CullingMark(rating: 5, flag: .pick), 2: CullingMark(rating: 2, flag: .reject)]
        context.camera = [
            1: CameraDetails(make: "Canon", model: "Canon EOS R5", lens: "RF 24-70mm", focalLength: 35, aperture: 2.8, iso: 400)
        ]
        let one = item(1, favorite: true, place: "Roma", country: "IT")
        let two = item(2, day(2024, 11, 20), path: "/Photos/Drone/DJI_2.MP4", mime: "video/mp4")
        let three = item(3, day(2020, 1, 1), path: "/Photos/Screenshots/Screenshot 2020-01-01.png", mime: "image/png")
        func check(_ rule: SmartRule, _ expected: [FileID]) {
            let matched = [one, two, three].filter { SmartRuleEvaluator.matches(rule, $0, in: context) }.map(\.fileId)
            #expect(matched == expected, "\(rule)")
        }
        check(.condition(.person("ANNA")), [1, 2])
        check(.condition(.tag("drone")), [2])
        check(.condition(.album("Holiday")), [3])
        check(.condition(.rating(atLeast: 3)), [1])
        check(.condition(.flag(.none)), [3])
        check(.condition(.flag(.reject)), [2])
        check(.condition(.mediaType(.video)), [2])
        check(.condition(.mediaType(.screenshot)), [3])
        check(.condition(.place("it")), [1])
        check(.condition(.favorite), [1])
        check(.condition(.withinLastDays(30)), [2])
        check(.condition(.olderThanDays(365)), [3])
        check(.condition(.folder("/Photos/Drone")), [2])
        check(.condition(.folder("Photos/Dro")), [])
        check(.condition(.camera("eos r5")), [1])
        check(.condition(.lens("24-70")), [1])
        check(.condition(.focalLength(min: 24, max: 50)), [1])
        check(.condition(.aperture(min: nil, max: 2)), [])
        check(.condition(.iso(min: 400, max: 400)), [1])
        check(.all([.condition(.person("Anna")), .not(.condition(.mediaType(.video)))]), [1])
        check(.any([.condition(.album("holiday")), .condition(.favorite)]), [1, 3])
        check(.all([]), [1, 2, 3])
        check(.any([]), [])
    }

    @Test func conditionsWithoutValuesAreIncomplete() {
        #expect(SmartCondition.camera(" ").isIncomplete)
        #expect(SmartCondition.iso(min: nil, max: nil).isIncomplete)
        #expect(!SmartCondition.iso(min: 100, max: nil).isIncomplete)
        #expect(!SmartCondition.favorite.isIncomplete)
    }

    @Test func smartAlbumsSortAndLimit() {
        let items = [item(1, day(2024, 1, 1)), item(2, day(2024, 3, 1)), item(3, day(2024, 2, 1))]
        var album = SmartAlbumDefinition(name: "x", rule: .all([]), sort: .oldestFirst, limit: 2)
        #expect(SmartRuleEvaluator.items(of: album, from: items, in: SmartRuleContext()).map(\.fileId) == [1, 3])
        album.sort = .newestFirst
        album.limit = nil
        #expect(SmartRuleEvaluator.items(of: album, from: items, in: SmartRuleContext()).map(\.fileId) == [2, 3, 1])
    }

    @Test func readsCameraDetailsFromTheServersEXIF() {
        let details = CameraDetails(exif: [
            "Make": "NIKON CORPORATION", "Model": "NIKON D750", "FNumber": "28/10", "FocalLength": "500/10", "ISOSpeedRatings": "1600",
            "LensModel": " ",
        ])
        #expect(details.aperture == 2.8)
        #expect(details.focalLength == 50)
        #expect(details.iso == 1600)
        #expect(details.lens == nil)
        #expect(details.cameraName == "NIKON D750")
        #expect(CameraDetails(make: "Canon", model: "EOS 450D").cameraName == "Canon EOS 450D")
        #expect(CameraDetails.rational("1/0") == nil)
    }
}

// MARK: - Synced lists

@Suite struct SyncedListTests {
    func album(_ id: String, _ name: String, at seconds: Double, deleted: Bool = false) -> SmartAlbumDefinition {
        SmartAlbumDefinition(
            id: id, name: name, rule: .all([]), modifiedAt: Date(timeIntervalSince1970: seconds), isDeleted: deleted)
    }

    @Test func theNewerRecordWinsAndMergingIsCommutative() {
        let now = Date(timeIntervalSince1970: 1_000)
        let phone = SyncedList(records: [album("a", "Dogs", at: 100), album("b", "Beach", at: 300)])
        let mac = SyncedList(records: [album("a", "Dogs and cats", at: 200), album("c", "Snow", at: 50)])
        let one = phone.merged(with: mac, now: now)
        let two = mac.merged(with: phone, now: now)
        #expect(Set(one.records) == Set(two.records))
        #expect(one.records.first { $0.id == "a" }?.name == "Dogs and cats")
        #expect(one.records.map(\.id) == ["a", "b", "c"])
    }

    @Test func deletionsStayDeletedUntilTheyAreOld() {
        let now = Date(timeIntervalSince1970: 200 * 86_400)
        let offline = SyncedList(records: [album("a", "Dogs", at: 100)])
        let server = SyncedList(records: [album("a", "Dogs", at: 150 * 86_400, deleted: true)])
        let merged = offline.merged(with: server, now: now)
        #expect(merged.records.first?.isDeleted == true)
        #expect(merged.live.isEmpty)
        // 90 days later the tombstone is dropped.
        #expect(server.merged(with: SyncedList(), now: now.addingTimeInterval(91 * 86_400)).records.isEmpty)
    }

    @Test func aChangeIsAlwaysNewerThanWhatItChanges() {
        var list = SyncedList(records: [album("a", "Dogs", at: 5_000)])
        var changed = list.records[0]
        changed.name = "Cats"
        // The clock of this device is behind the one that wrote the record.
        list.upsert(changed, now: Date(timeIntervalSince1970: 10))
        #expect(list.records[0].modifiedAt > Date(timeIntervalSince1970: 5_000))
        list.delete(id: "a", now: Date(timeIntervalSince1970: 10))
        #expect(list.records[0].isDeleted)
        #expect(list.records[0].modifiedAt > Date(timeIntervalSince1970: 5_000))
    }

    @Test func unreadableRecordsAreSkippedNotFatal() throws {
        let json = #"{"version":1,"items":[{"id":"a","name":"Ok","modifiedAt":1,"rule":{"all":[]}},{"name":"no id"}]}"#
        let list = try SyncedList<SmartAlbumDefinition>.decoded(Data(json.utf8))
        #expect(list.records.map(\.id) == ["a"])
        let roundTrip = try SyncedList<SmartAlbumDefinition>.decoded(try list.encoded())
        #expect(roundTrip == list)
    }
}

// MARK: - Batch fixes

@Suite struct BatchFixTests {
    @Test func shiftsAndTimeZones() throws {
        let photo = item(1, day(2024, 6, 14, 9))
        #expect(DateAdjustment(shift: 3600).adjusted(photo) == day(2024, 6, 14, 10))
        // Recorded 09:00 (read as UTC by the server), taken in Tokyo: 00:00 UTC.
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let adjustment = DateAdjustment(timeZone: tokyo)
        #expect(adjustment.adjusted(photo) == day(2024, 6, 14, 0))
        #expect(adjustment.adjustedOffset(photo) == 9 * 3600)
        // A photo that already says +02:00: the same wall clock (09:00) in Tokyo.
        let paris = item(2, day(2024, 6, 14, 7), offset: 7200)
        #expect(adjustment.adjusted(paris) == day(2024, 6, 14, 0))
        // Summer and winter time: the zone's offset on that day.
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        #expect(DateAdjustment(timeZone: berlin).adjusted(item(3, day(2024, 1, 10, 9))) == day(2024, 1, 10, 8))
        #expect(DateAdjustment(timeZone: berlin).adjusted(item(4, day(2024, 7, 10, 9))) == day(2024, 7, 10, 7))
        #expect(DateAdjustment.shift(from: day(2024, 6, 14, 9), to: day(2024, 6, 15, 9)) == 86_400)
        #expect(DateAdjustment().isEmpty)
    }

    @Test func renamesWithPatterns() {
        let items = [
            item(1, day(2024, 6, 14, 9), path: "/Photos/Trip/IMG_0001.JPG", place: "Rome"),
            item(2, day(2024, 6, 13, 18), path: "/Photos/Trip/IMG_0002.heic", place: "Rome"),
            item(3, day(2024, 6, 15, 7), path: "/Photos/Trip/DSC_9.jpg"),
        ]
        let names = RenamePattern("{date} {place} {counter}").names(for: items)
        // The counter follows the capture time.
        #expect(names[2] == "2024-06-13 Rome 001.heic")
        #expect(names[1] == "2024-06-14 Rome 002.JPG")
        #expect(names[3] == "2024-06-15 003.jpg")
        let padded = RenamePattern("Trip_{counter:2}_{name}", start: 9).names(for: items)
        #expect(padded[2] == "Trip_09_IMG_0002.heic")
        #expect(padded[3] == "Trip_11_DSC_9.jpg")
    }

    @Test func avoidsCollisionsAndForbiddenCharacters() {
        let items = [item(1, path: "/Photos/a.jpg"), item(2, path: "/Photos/b.jpg"), item(3, path: "/Other/c.jpg")]
        let names = RenamePattern("Holiday").names(for: items, existing: ["/Photos": ["holiday.jpg", "a.jpg", "b.jpg"]])
        #expect(names[1] == "Holiday (2).jpg")
        #expect(names[2] == "Holiday (3).jpg")
        // Another folder: no collision.
        #expect(names[3] == "Holiday.jpg")
        // A file may keep its own name.
        #expect(RenamePattern("{name}").names(for: [items[0]], existing: ["/Photos": ["a.jpg"]])[1] == "a.jpg")
        #expect(RenamePattern("a/b: {unknown}?").names(for: [items[0]])[1] == "a-b- {unknown}.jpg")
        #expect(RenamePattern("   ").names(for: [items[0]])[1] == "a.jpg")
    }

    @Test func usesTheRecordedTimeForNames() {
        // 23:30 UTC on the 14th is 01:30 on the 15th in +02:00.
        let photo = item(1, day(2024, 6, 14, 23).addingTimeInterval(1800), offset: 7200)
        #expect(RenamePattern("{date}_{time}").render(photo, counter: 1) == "2024-06-15_01-30-00")
    }
}

// MARK: - GPX and KML

@Suite struct GeoTrackTests {
    static let gpx = """
        <?xml version="1.0"?>
        <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Morning walk</name></metadata>
          <trk><name>Track</name><trkseg>
            <trkpt lat="48.0" lon="11.0"><ele>500</ele><time>2024-06-14T09:00:00Z</time></trkpt>
            <trkpt lat="48.1" lon="11.2"><ele>520</ele><time>2024-06-14T09:10:00Z</time></trkpt>
            <trkpt lat="48.2" lon="11.4"><time>2024-06-14T10:00:00.500Z</time></trkpt>
            <trkpt lat="1" lon="2"></trkpt>
          </trkseg></trk>
        </gpx>
        """

    static let kml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
        <Document><name>Day</name>
          <Placemark><gx:Track>
            <when>2024-06-14T09:00:00Z</when><when>2024-06-14T09:10:00+02:00</when>
            <gx:coord>11.0 48.0 500</gx:coord><gx:coord>11.2 48.1 520</gx:coord>
          </gx:Track></Placemark>
          <Placemark><TimeStamp><when>2024-06-14T12:00:00Z</when></TimeStamp><Point><coordinates>12.5,41.9,20</coordinates></Point></Placemark>
        </Document></kml>
        """

    @Test func readsGPX() throws {
        let track = try GeoTrack.parse(Data(Self.gpx.utf8))
        #expect(track.points.count == 3)
        #expect(track.name == "Morning walk")
        #expect(track.points[0].altitude == 500)
        #expect(track.end == day(2024, 6, 14, 10).addingTimeInterval(0.5))
    }

    @Test func readsKML() throws {
        let track = try GeoTrack.parse(Data(Self.kml.utf8))
        #expect(track.points.count == 3)
        // Sorted by time: 07:10Z (the +02:00 one) first.
        #expect(track.points[0].time == day(2024, 6, 14, 7).addingTimeInterval(600))
        #expect(track.points[0].longitude == 11.2)
        #expect(track.points[2].latitude == 41.9)
    }

    @Test func refusesFilesWithoutTimes() {
        #expect(throws: GeoTrack.ParseError.self) { try GeoTrack.parse(Data("<gpx><wpt lat=\"1\" lon=\"2\"/></gpx>".utf8)) }
        #expect(throws: GeoTrack.ParseError.self) { try GeoTrack.parse(Data("not xml".utf8)) }
    }

    @Test func matchesByTime() throws {
        let track = try GeoTrack.parse(Data(Self.gpx.utf8))
        let photos = [
            item(1, day(2024, 6, 14, 9).addingTimeInterval(300)),  // between the first two: interpolated
            item(2, day(2024, 6, 14, 9).addingTimeInterval(1200)),  // 10 min after point 2, 40 min gap: nearest within 15 min?
            item(3, day(2024, 6, 14, 11)),  // an hour after the end
            item(4, day(2024, 6, 14, 8).addingTimeInterval(3420)),  // 3 minutes before the start
        ]
        let matches = Dictionary(uniqueKeysWithValues: GeoTagger.match(photos, track: track, tolerance: 5 * 60).map { ($0.fileId, $0) })
        let first = try #require(matches[1])
        #expect(first.interpolated)
        #expect(abs(first.latitude - 48.05) < 0.0001)
        #expect(abs(first.longitude - 11.1) < 0.0001)
        #expect(first.altitude == 510)
        // 10 minutes from the nearest point, the next one 40 minutes away: not interpolated, outside the tolerance.
        #expect(matches[2] == nil)
        #expect(matches[3] == nil)
        #expect(matches[4]?.latitude == 48.0)
        #expect(matches[4]?.interpolated == false)
        // With a 15 minute tolerance the second photo takes the nearer point.
        let wide = GeoTagger.match([photos[1]], track: track, tolerance: 15 * 60)
        #expect(wide.first?.latitude == 48.1)
    }

    @Test func correctsTheCameraClock() throws {
        let track = try GeoTrack.parse(Data(Self.gpx.utf8))
        // The camera was set to UTC+2 and the server read its times as UTC: two hours late.
        let photos = [item(1, day(2024, 6, 14, 11).addingTimeInterval(300)), item(2, day(2024, 6, 14, 11).addingTimeInterval(400))]
        #expect(GeoTagger.match(photos, track: track).isEmpty)
        let offset = try #require(GeoTagger.suggestedOffset(for: photos, track: track))
        #expect(offset == -7200)
        #expect(GeoTagger.match(photos, track: track, offset: offset).count == 2)
    }

    @Test func interpolatesAcrossTheDateLine() {
        #expect(
            abs(GeoTagger.interpolateLongitude(179, -179, 0.5) - 180) < 0.0001
                || abs(GeoTagger.interpolateLongitude(179, -179, 0.5) + 180) < 0.0001)
        #expect(abs(GeoTagger.interpolateLongitude(170, -170, 0.25) - 175) < 0.0001)
    }
}

// MARK: - Folder rules

@Suite struct FolderRuleTests {
    let created = day(2024, 6, 1)

    func rule(_ action: FolderRule.Action, _ rule: SmartRule, existing: Bool = false) -> FolderRule {
        // A fixed modification time: "now" does not survive the JSON round trip bit for bit (seconds since 1970).
        FolderRule(
            id: "r", name: "Drone", rule: rule, action: action, includesExisting: existing, createdAt: created, modifiedAt: created)
    }

    @Test func actsOnNewMatchingPhotosOnce() {
        let drone = rule(.addToAlbum("Drone"), .condition(.folder("/Camera/Drone")))
        let items = [
            item(1, path: "/Camera/Drone/a.jpg", uploaded: day(2024, 6, 2)),
            item(2, path: "/Camera/Drone/b.jpg", uploaded: day(2024, 5, 1)),  // before the rule
            item(3, path: "/Camera/c.jpg", uploaded: day(2024, 6, 2)),
            item(4, path: "/Camera/Drone/d.jpg", uploaded: day(2024, 6, 3)),  // already in the album
            item(5, path: "/Camera/Drone/e.jpg", uploaded: day(2024, 6, 3)),  // handled before (removed again by the user)
            item(6, path: "/Camera/Drone/f.jpg", uploaded: day(2024, 6, 3), mountType: "shared"),  // not own: cannot be added
        ]
        let context = SmartRuleContext(albumMembers: ["drone": [4]])
        let state = FolderRuleState(handled: ["r": [5]])
        let steps = FolderRulePlanner.plan(rules: [drone], items: items, context: context, state: state)
        #expect(steps.map(\.fileIds) == [[1]])
        var existing = drone
        existing.includesExisting = true
        #expect(FolderRulePlanner.plan(rules: [existing], items: items, context: context, state: state).first?.fileIds == [1, 2])
    }

    @Test func screenshotsOlderThanThirtyDaysAreArchived() {
        let archive = rule(.archive, .all([.condition(.mediaType(.screenshot)), .condition(.olderThanDays(30))]), existing: true)
        let items = [
            item(1, day(2024, 1, 1), path: "/Photos/Screenshot 2024-01-01.png", mime: "image/png"),
            item(2, day(2024, 6, 20), path: "/Photos/Screenshot 2024-06-20.png", mime: "image/png"),
            item(3, day(2024, 1, 1), path: "/Photos/IMG_3.jpg"),
        ]
        let steps = FolderRulePlanner.plan(
            rules: [archive], items: items, context: SmartRuleContext(now: day(2024, 6, 25)), state: FolderRuleState())
        #expect(steps.first?.fileIds == [1])
    }

    @Test func rulesThatCannotRunDoNothing() {
        let items = [item(1, uploaded: day(2024, 7, 1))]
        var disabled = rule(.favorite, .condition(.mediaType(.photo)))
        disabled.isEnabled = false
        let empty = rule(.favorite, .all([]))
        let noAlbum = rule(.addToAlbum("  "), .condition(.mediaType(.photo)))
        #expect(
            FolderRulePlanner.plan(rules: [disabled, empty, noAlbum], items: items, context: SmartRuleContext(), state: FolderRuleState())
                .isEmpty)
        #expect(
            FolderRulePlanner.plan(
                rules: [rule(.favorite, .condition(.favorite))], items: [item(2, favorite: true, uploaded: day(2024, 7, 1))],
                context: SmartRuleContext(), state: FolderRuleState()
            ).isEmpty)
    }

    @Test func aRunIsLimited() {
        let items = (1...(FolderRulePlanner.maxPerRun + 10)).map { item(FileID($0), uploaded: day(2024, 7, 1)) }
        let steps = FolderRulePlanner.plan(
            rules: [rule(.favorite, .condition(.mediaType(.photo)))], items: items, context: SmartRuleContext(), state: FolderRuleState())
        #expect(steps.first?.fileIds.count == FolderRulePlanner.maxPerRun)
    }

    @Test func leasesExpire() {
        let now = Date(timeIntervalSince1970: 1_000)
        let other = FolderRuleLease(holder: "mac", device: "Mac", expiresAt: now.addingTimeInterval(60))
        #expect(FolderRuleLease.canAcquire(nil, holder: "phone", now: now))
        #expect(!FolderRuleLease.canAcquire(other, holder: "phone", now: now))
        #expect(FolderRuleLease.canAcquire(other, holder: "mac", now: now))
        #expect(FolderRuleLease.canAcquire(other, holder: "phone", now: now.addingTimeInterval(61)))
    }

    @Test func theStateRemembersAndForgets() {
        var state = FolderRuleState()
        for index in 0..<(FolderRuleState.maxLogEntries + 5) {
            state.record(
                .init(date: Date(timeIntervalSince1970: Double(index)), ruleId: "r", ruleName: "R", count: 1, device: "Mac"),
                handled: [1, 2])
        }
        #expect(state.log.count == FolderRuleState.maxLogEntries)
        #expect(state.log.first?.date == Date(timeIntervalSince1970: Double(FolderRuleState.maxLogEntries + 4)))
        #expect(state.handled["r"] == [1, 2])
        state.prune(keeping: [])
        #expect(state.handled.isEmpty)
    }

    @Test func rulesRoundTripAndUnknownActionsDisableThem() throws {
        let original = rule(.addTag("Best of"), .condition(.rating(atLeast: 5)))
        let decoded = try JSONDecoder().decode(FolderRule.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        let future = #"{"id":"x","name":"Print","enabled":true,"action":"print","rule":{"type":"favorite"},"createdAt":1,"modifiedAt":1}"#
        let rule = try JSONDecoder().decode(FolderRule.self, from: Data(future.utf8))
        #expect(!rule.isRunnable)
    }
}
