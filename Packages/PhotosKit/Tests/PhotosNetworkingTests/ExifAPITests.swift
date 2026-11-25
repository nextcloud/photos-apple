// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosModel
@testable import PhotosNetworking

/// EXIF of many photos from a SEARCH, as Insights reads it (SPEC §16.5.1).
@Suite struct ExifAPITests {
    /// What a stock Nextcloud 33 answered: one photo with EXIF, one whose metadata the server has not got (404 propstat),
    /// one with a list-valued tag.
    static let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
        <d:response><d:href>/remote.php/dav/files/admin/Photos/a.jpg</d:href><d:propstat><d:prop><oc:fileid>2752</oc:fileid>
        <d:getetag>&quot;54638eb7&quot;</d:getetag><nc:metadata-photos-original_date_time>1299303494</nc:metadata-photos-original_date_time>
        <nc:metadata-photos-exif><ExposureTime>1/1000</ExposureTime><FNumber>2/1</FNumber><ISOSpeedRatings>125</ISOSpeedRatings>
        <DateTimeOriginal>2011:03:05 05:38:14</DateTimeOriginal><ComponentsConfiguration></ComponentsConfiguration><FocalLength>350/10</FocalLength>
        <Model>ignored by IFD0</Model></nc:metadata-photos-exif>
        <nc:metadata-photos-ifd0><Make>NIKON CORPORATION</Make><Model>NIKON D700</Model><Artist>Someone</Artist></nc:metadata-photos-ifd0>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/remote.php/dav/files/admin/Photos/b.jpg</d:href><d:propstat><d:prop><oc:fileid>2757</oc:fileid>
        <d:getetag>&quot;0990&quot;</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat><d:propstat><d:prop>
        <nc:metadata-photos-exif/><nc:metadata-photos-ifd0/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
        <d:response><d:href>/remote.php/dav/files/admin/Photos/c.jpg</d:href><d:propstat><d:prop><oc:fileid>2760</oc:fileid>
        <d:getetag>&quot;c&quot;</d:getetag><nc:metadata-photos-exif><ISOSpeedRatings><value>800</value><value>800</value></ISOSpeedRatings>
        </nc:metadata-photos-exif></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/remote.php/dav/files/admin/Photos/</d:href><d:propstat><d:prop><oc:fileid>1</oc:fileid>
        <d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """

    @Test func readsTheTagsOfEachPhoto() throws {
        let records = try MultiStatus.parse(Data(Self.xml.utf8)).compactMap(PhotosAPI.exifRecord(from:))
        #expect(records.map(\.fileId) == [2752, 2757, 2760])
        let first = records[0]
        #expect(first.etag == "54638eb7")
        #expect(first.capturedAt == 1_299_303_494)
        #expect(first.tags["Make"] == "NIKON CORPORATION")
        #expect(first.tags["FocalLength"] == "350/10")
        #expect(first.tags["ComponentsConfiguration"] == nil)
        // The EXIF IFD is read after IFD0 and wins.
        #expect(first.tags["Model"] == "ignored by IFD0")
        #expect(records[1].tags.isEmpty && records[1].etag == "0990")
        #expect(records[2].tags["ISOSpeedRatings"] == "800")
    }
}
