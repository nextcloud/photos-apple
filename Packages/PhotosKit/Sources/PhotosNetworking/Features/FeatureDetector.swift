// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Builds `ServerFeatures` from capabilities, the Photos bootstrap data and probes (SPEC §5.3).
public struct FeatureDetector: Sendable {
    public let dav: DAVClient
    public let ocs: OCSClient

    public init(dav: DAVClient, ocs: OCSClient) {
        self.dav = dav
        self.ocs = ocs
    }

    var connection: ServerConnection { dav.connection }

    /// - Parameter cached: the features of the last detection. When the Photos settings cannot be read this time
    ///   (the request failed; not: the server has no such API), the cached settings are kept instead of defaults:
    ///   wrong timeline folders would make the sync engine rebuild the index for folders the user never chose.
    public func detect(cached: ServerFeatures? = nil) async throws -> ServerFeatures {
        // 1. Capabilities
        let capabilities: JSONValue = try await ocs.request("GET", "ocs/v2.php/cloud/capabilities")
        let versionString = capabilities["version", "string"]?.string ?? capabilities["version", "major"]?.string ?? "0"
        let version =
            ServerVersion(parsing: versionString)
            ?? ServerVersion(major: capabilities["version", "major"]?.int ?? 0, minor: capabilities["version", "minor"]?.int ?? 0)
        var features = ServerFeatures(serverVersion: version)
        features.fingerprint = Self.fingerprint(capabilities)
        let caps = capabilities["capabilities"]
        Self.applyCoreCapabilities(caps, to: &features)

        let photosCapability = caps?["photos"]
        if let photosCapability, photosCapability.isPresent {
            Self.applyPhotosCapability(photosCapability, to: &features)
        }

        // 2. Photos bootstrap: config API, else initial-state scrape, else defaults (no Photos app) or, when the
        // requests failed, what the last detection found.
        var bootstrap = Bootstrap.absent
        if features.has(.configAPI) {
            do {
                for (key, value) in try await fetchConfigAPI() { features.userConfig.apply(key: key, rawValue: value) }
                bootstrap = .configAPI
            } catch {
                bootstrap = Self.isMissingAPI(error) ? .absent : .failed
            }
        }
        if bootstrap != .configAPI {
            do {
                let state = try await InitialStateScraper.fetch(http: dav.http, connection: connection)
                Self.applyInitialState(state, to: &features)
                // A page without any Photos state is not the Photos page (a redirect, an error page answered with 200).
                bootstrap = state.isEmpty ? .failed : .scraped
            } catch {
                if !Self.isMissingAPI(error) { bootstrap = .failed }
            }
        }
        if bootstrap == .failed, let cached { Self.carryOverBootstrap(from: cached, to: &features) }

        // `.nomedia` folders: the scraped page lists them; otherwise one core SEARCH (no Photos API involved).
        if bootstrap != .scraped {
            do {
                features.nomediaPaths = try await PhotosAPI(dav: dav, ocs: ocs).nomediaFolders()
            } catch NetworkError.notFound {
                features.nomediaPaths = []
            } catch {
                features.nomediaPaths = cached?.nomediaPaths ?? []
            }
        }

        // 3. Probes for what is still unknown.
        await probe(into: &features, skipPhotosProbes: photosCapability?.isPresent == true)
        if version.major >= 35 { features.enabled.insert(.metadataEdit) }
        features.detectedAt = Date()
        return features
    }

    // MARK: Change detection

    /// A short summary of the capabilities that changes when the server or its Photos app is upgraded or downgraded:
    /// the Nextcloud version and, when present, the `photos` capability's version and feature list.
    ///
    /// A stock Photos app has no capability, so an upgrade of Photos alone (same Nextcloud version) does not change it;
    /// that case is caught by the hourly detection and by `SessionModel.featureUnavailable(_:)`.
    public static func fingerprint(_ capabilities: JSONValue) -> String {
        let version = capabilities["version", "string"]?.string ?? capabilities["version", "major"].map { "\($0)" } ?? "?"
        guard let photos = capabilities["capabilities", "photos"], photos.isPresent else { return version }
        let photosVersion = photos["version"]?.string ?? "?"
        let names = (photos["features"]?.array ?? []).compactMap(\.string).sorted().joined(separator: ",")
        return "\(version)|photos \(photosVersion)|\(names)"
    }

    /// The fingerprint of the server as it is now (one capabilities request).
    public func currentFingerprint() async throws -> String {
        let capabilities: JSONValue = try await ocs.request("GET", "ocs/v2.php/cloud/capabilities")
        return Self.fingerprint(capabilities)
    }

    /// What to use after `detect()` failed: `nil` keeps the cached features (the server could not be reached, so nothing
    /// will be called anyway, and the offline app keeps its albums and places); a server that answered with an error
    /// keeps only what every Photos version has, so no API of a newer Photos version is used until detection succeeds.
    public static func fallback(after error: any Error, cached: ServerFeatures) -> ServerFeatures? {
        switch error as? NetworkError {
        case .offline, .timedOut, .cancelled, .transport, .unauthorized, .untrustedCertificate, .clientCertificateRequired,
            .maintenance, .rateLimited:
            return nil
        default:
            if error is CancellationError { return nil }
            return cached.coreOnly
        }
    }

    /// Whether an error from an optional API means the server does not have that API (an older or stock Photos app):
    /// unknown OCS routes and DAV collections answer 404, unknown config keys 400, unknown methods 405 or 501.
    public static func isMissingAPI(_ error: any Error) -> Bool {
        switch error as? NetworkError {
        case .notFound, .conflict: true
        case .http(let status, _): status == 400 || status == 501
        default: false
        }
    }

    /// The feature a server-side user config key belongs to, for keys only newer Photos versions accept.
    public static func feature(for key: PhotosUserConfig.Key) -> ServerFeature? {
        switch key {
        case .smartAlbums, .albumsSortOrder, .albumPhotosSortOrder: .configAPI
        case .onThisDayNotifications: .onThisDayNotifications
        case .croppedLayout, .gridDensity, .photosLocation, .photosSourceFolders: nil
        }
    }

    // MARK: Capabilities

    static func applyCoreCapabilities(_ caps: JSONValue?, to features: inout ServerFeatures) {
        guard let caps else { return }
        if caps["files", "undelete"]?.bool == true { features.enabled.insert(.trashbin) }
        if caps["notifications"]?.isPresent == true { features.enabled.insert(.notifications) }
        if caps["files", "comments"]?.bool == true || caps["comments"]?.isPresent == true { features.enabled.insert(.comments) }
        if caps["files_sharing", "public", "enabled"]?.bool == true { features.enabled.insert(.publicLinks) }
        if let count = caps["files", "chunked_upload", "max_parallel_count"]?.int, count > 0 { features.maxParallelChunkUploads = count }
        if let color = caps["theming", "color"]?.string { features.themingColor = color }
    }

    static func applyPhotosCapability(_ photos: JSONValue, to features: inout ServerFeatures) {
        features.enabled.insert(.photosCapability)
        features.enabled.insert(.photosDAV)
        features.photosAppVersion = photos["version"]?.string
        let map: [String: ServerFeature] = [
            "config-api": .configAPI, "timeline-days": .timelineDays, "album-cover": .albumCover, "album-description": .albumDescription,
            "album-comments": .albumComments, "album-sort-lastmodified": .albumLastModified, "album-filter-tags": .albumFilterTags,
            "album-change-tag": .albumChangeTag, "place-country": .placeCountry, "metadata-edit": .metadataEdit,
            "on-this-day-notifications": .onThisDayNotifications, "unified-search": .unifiedSearchPhotos,
            "folder-previews": .folderPreviews, "sync-feed": .syncFeed, "content-hash": .contentHash,
            "recognize-key": .recognizeKeyAPI, "video-renditions": .videoRenditions, "media-duration": .mediaDuration,
        ]
        for item in photos["features"]?.array ?? [] {
            if let name = item.string, let feature = map[name] { features.enabled.insert(feature) }
        }
        if let images = photos["mimetypes", "image"]?.array?.compactMap(\.string), !images.isEmpty { features.imageMimeTypes = images }
        if let videos = photos["mimetypes", "video"]?.array?.compactMap(\.string), !videos.isEmpty { features.videoMimeTypes = videos }
        if photos["places", "enabled"]?.bool != false { features.enabled.insert(.places) }
        if photos["captions", "enabled"]?.bool == true { features.enabled.insert(.captions) }
        if photos["captions", "searchable"]?.bool == true { features.enabled.insert(.captionsSearchable) }
        if photos["videoRenditions", "enabled"]?.bool == true { features.enabled.insert(.videoRenditions) }
        let apps = photos["apps"]
        if apps?["recognize"]?.bool == true { features.enabled.insert(.recognize) }
        if apps?["systemtags"]?.bool == true { features.enabled.insert(.systemtags) }
    }

    // MARK: Bootstrap

    /// Where the Photos settings (timeline folders, MIME types, `.nomedia` folders) of a detection came from.
    enum Bootstrap: Equatable {
        case configAPI, scraped
        /// The server has neither source (no Photos app): defaults apply.
        case absent
        /// A source exists or may exist, but could not be read this time.
        case failed
    }

    /// Keeps the settings of the last detection after a failed bootstrap. MIME types the capabilities already gave
    /// stay; values of features this detection did not find are dropped like `ServerFeatures.removing(_:)` does.
    static func carryOverBootstrap(from cached: ServerFeatures, to features: inout ServerFeatures) {
        features.userConfig = cached.userConfig
        if !features.has(.configAPI) {
            features.userConfig.smartAlbums = nil
            features.userConfig.albumsSortOrder = nil
            features.userConfig.albumPhotosSortOrder = nil
        }
        if !features.has(.onThisDayNotifications) { features.userConfig.onThisDayNotifications = nil }
        if !features.has(.photosCapability) {
            features.imageMimeTypes = cached.imageMimeTypes
            features.videoMimeTypes = cached.videoMimeTypes
        }
    }

    func fetchConfigAPI() async throws -> [String: String] {
        let config: JSONValue = try await ocs.request("GET", "ocs/v2.php/apps/photos/api/v1/config")
        var result: [String: String] = [:]
        for (key, value) in config.object ?? [:] {
            if let string = value.string {
                result[key] = string
            } else if let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) {
                result[key] = string
            }
        }
        return result
    }

    static func applyInitialState(_ state: [String: JSONValue], to features: inout ServerFeatures) {
        features.enabled.insert(.photosDAV)
        if let images = state["image-mimes"]?.array?.compactMap(\.string), !images.isEmpty { features.imageMimeTypes = images }
        if let videos = state["video-mimes"]?.array?.compactMap(\.string), !videos.isEmpty { features.videoMimeTypes = videos }
        for key in PhotosUserConfig.Key.allCases {
            guard let value = state[key.rawValue] else { continue }
            if let string = value.string {
                features.userConfig.apply(key: key.rawValue, rawValue: string)
            } else if let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) {
                features.userConfig.apply(key: key.rawValue, rawValue: string)
            }
        }
        if let paths = state["nomedia-paths"]?.array?.compactMap(\.string) { features.nomediaPaths = paths }
        if state["recognize"]?.bool == true { features.enabled.insert(.recognize) }
        if state["systemtags"]?.bool == true { features.enabled.insert(.systemtags) }
        if let key = state["recognizeApiKey"]?.string, !key.isEmpty {
            features.recognizeAPIKey = key
            features.recognizeAPIKeyDate = Date()
        }
        if state["trashbin"]?.bool == true { features.enabled.insert(.trashbin) }
        if state["caption-search"]?.bool == true { features.enabled.formUnion([.captions, .captionsSearchable]) }
        if state["video-renditions"]?.bool == true { features.enabled.insert(.videoRenditions) }
        if state["smartAlbums"] != nil { features.enabled.insert(.configAPI) }  // smartAlbums key exists → extended config keys accepted
        if state["onThisDayNotifications"] != nil { features.enabled.insert(.onThisDayNotifications) }
    }

    // MARK: Probes

    func probe(into features: inout ServerFeatures, skipPhotosProbes: Bool) async {
        let uid = connection.userId
        let photosHome = connection.davURL("photos/\(uid)/")

        if !skipPhotosProbes {
            if (try? await dav.propfind(photosHome, depth: 0, properties: [DAVProp.resourceType])) != nil {
                features.enabled.insert(.photosDAV)
            }
            if features.has(.photosDAV) {
                if (try? await dav.propfind(connection.davURL("photos/\(uid)/places/"), depth: 0, properties: [DAVProp.resourceType]))
                    != nil
                {
                    features.enabled.insert(.places)
                }
                // Extended album props: ask for them on the children of the albums home, or of the shared albums home
                // when the user has no album of their own (the props only exist on albums).
                var sample: DAVResource?
                for home in ["albums", "sharedalbums"] where sample == nil {
                    sample = try? await dav.propfind(
                        connection.davURL("photos/\(uid)/\(home)/"), depth: 1,
                        properties: [DAVProp.cover, DAVProp.albumDescription, DAVProp.albumId, DAVProp.lastModified]
                    ).dropFirst().first
                }
                if let album = sample {
                    // Unsupported props come back in a 404 propstat (`DAVResource.missing`), not as an error.
                    if album.properties[DAVProp.cover] != nil { features.enabled.insert(.albumCover) }
                    if album.properties[DAVProp.albumDescription] != nil { features.enabled.insert(.albumDescription) }
                    if album.properties[DAVProp.albumId] != nil { features.enabled.insert(.albumComments) }
                    if let modified = album.httpDate(DAVProp.lastModified), modified.timeIntervalSince1970 > 0 {
                        features.enabled.insert(.albumLastModified)
                    }
                }
                if features.has(.places),
                    let places = try? await dav.propfind(
                        connection.davURL("photos/\(uid)/places/"), depth: 1, properties: [DAVProp.placeCountry]),
                    places.dropFirst().contains(where: { $0.properties[DAVProp.placeCountry] != nil })
                {
                    features.enabled.insert(.placeCountry)
                }
            }
            if (try? await ocs.raw(
                "GET", "ocs/v2.php/apps/photos/api/v1/timeline/days", query: [URLQueryItem(name: "mediaType", value: "all")])) != nil
            {
                features.enabled.insert(.timelineDays)
            }
        }

        if !features.has(.systemtags),
            (try? await dav.propfind(connection.davURL("systemtags/"), depth: 0, properties: [DAVProp.resourceType])) != nil
        {
            features.enabled.insert(.systemtags)
        }
        if !features.has(.recognize) {
            do {
                _ = try await dav.propfind(connection.davURL("recognize/\(uid)/"), depth: 0, properties: [DAVProp.resourceType])
                features.enabled.insert(.recognize)
            } catch NetworkError.forbidden {
                features.enabled.insert(.recognize)  // present, key required
            } catch {}
        }

        if let types: JSONValue = try? await ocs.request("GET", "ocs/v2.php/taskprocessing/tasktypes") {
            let available = Set((types["types"]?.object ?? [:]).keys)
            if available.contains("core:text2text") { features.enabled.insert(.taskText2Text) }
            if available.contains("core:image2text:ocr") { features.enabled.insert(.taskOCR) }
            if available.contains("core:analyze-images") { features.enabled.insert(.taskAnalyzeImages) }
        }

        if !skipPhotosProbes, let providers: JSONValue = try? await ocs.request("GET", "ocs/v2.php/search/providers") {
            if providers.array?.contains(where: { $0["id"]?.string == "photos_albums" }) == true {
                features.enabled.insert(.unifiedSearchPhotos)
            }
        }
    }
}
