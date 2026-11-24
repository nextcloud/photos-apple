# Nextcloud Photos for iOS, iPadOS, macOS and visionOS — Specification

Version 1.0 · 2026-11-22 · Status: ready for implementation

> **This is the target, not the state.** The spec describes the app as it is meant to become; parts of it are not built yet
> (for example the log file of §4.5, the MDM keys, the PhotoKit background-upload extension, most of the UI tests of §11).
> What exists today, and how it was verified, is in [STATUS.md](STATUS.md). The layout of the code is in
> [ARCHITECTURE.md](ARCHITECTURE.md).

This document specifies a new native Apple app, **Nextcloud Photos**. It is written for the engineer (human or AI-assisted) who will build it. It records decisions that were already made with the product owner. **Do not re-open the decisions in §2**; if something in this spec turns out to be wrong or impossible, change the spec in the same PR that changes the behaviour and say why.

## 0. Documents in this folder

| File | What it is |
|---|---|
| `SPEC.md` | This document: product, architecture, features, milestones. The source of truth. |
| `SERVER-COMPANION.md` | Optional server-side additions to the Photos server app (nextcloud/photos) that make the client faster and more complete. The app must work without them. |
| `reference/photos-server-api.md` | Exact wire formats of the Photos server app on upstream master (WebDAV trees, SEARCH bodies, properties, previews, faces, tags, version matrix NC33–36). **Read it before writing any networking code.** |
| `reference/photos-extended-api.md` | The API added by ~60 unmerged feature branches (an integration branch that runs on the extended test server), plus the client-side algorithms of the web app with all their constants. |
| `reference/nextcloud-ios-and-nextcloudkit.md` | How the Nextcloud Files iOS app and NextcloudKit do login, accounts, keychain, push, auto upload, previews; identifiers of the Files app. |

The reference files are research notes with file:line pointers into local clones of the Photos app, its integration branch and server core. When this spec and a reference disagree, this spec wins for *behaviour* and the reference wins for *wire format*; fix whichever is wrong.

---

## 1. Product

### 1.1 Goal

A first-class Apple photo app for photos and videos stored in Nextcloud. It does what the Nextcloud Photos web app does — timeline, albums, sharing, places, map, people, tags, memories — and adds what only a native app can do: complete and safe camera-roll backup, offline albums, fast browsing of very large libraries, editing, widgets, Siri/Shortcuts, and deep system integration.

The Nextcloud Files app focuses on file management. Nextcloud Photos focuses on photos: users never need to think in folders unless they want to.

### 1.2 Target users

- People who replace iCloud Photos / Google Photos with their own or their company's Nextcloud.
- Families sharing albums.
- Nextcloud Files users who today use its auto upload and the Photos web app.

### 1.3 Non-goals

- General file management (that is the Files app).
- watchOS, tvOS (not now).
- Editing videos (only metadata of videos is editable).
- End-to-end encrypted folders (Photos server app can't index them either).
- Being a white-label app in v1 (keep branding in one place so it can become one later, see §4.9).

---

## 2. Decisions (final)

| Topic | Decision |
|---|---|
| Identity | Official **Nextcloud Photos** app by Nextcloud GmbH, Nextcloud branding, published under Nextcloud's Apple team (`NKUJUXUJ3B`). Repo **github.com/nextcloud/photos-ios**. |
| Licence | **MIT** for all of the app's own code (the repo's `LICENSE`). REUSE-compliant SPDX headers in every file. Logos are `LicenseRef-NextcloudTrademarks`. The app does **not** link NextcloudKit or any other GPL library, so the distributed app is MIT as well (*decision 2026-11-23, replaces the earlier plan to link NextcloudKit; the dependency was declared but never used and has been removed*). **Never copy code from nextcloud/ios, NextcloudKit or other GPL projects into this repo** — use them only as a reference and write your own implementation. All dependencies must be MIT-compatible (MIT, BSD, Apache-2.0). |
| Platforms | iOS, iPadOS, **macOS as a native SwiftUI target (not Catalyst, not "Designed for iPad")**, **visionOS**. |
| Minimum OS | **27 only** (iOS/iPadOS/macOS/visionOS 27). No availability checks for older OSes. |
| Look | **Native Apple look** (system navigation, Liquid Glass, sidebar on iPad/Mac/visionOS, SF Symbols), with Nextcloud blue as accent and the Nextcloud logo. Do not imitate the web UI. |
| Networking | The app's **own client on `URLSession`** (`HTTPClient` in `PhotosNetworking`): WebDAV, OCS, Login Flow v2, chunked upload, push registration. No NextcloudKit (see Licence and §4.3). |
| Server | **Nextcloud 33 and later.** Core features must work with the Photos app that ships with each of these servers. |
| Feature detection | **At runtime.** Extended features (from the feature branches / future Photos versions) switch on when the server supports them. |
| Server work | The spec may define **optional companion server APIs** (`SERVER-COMPANION.md`). The app uses them when present and falls back otherwise. |
| Backup | **Full automatic camera-roll backup, optional**, with protection against duplicates, in particular when the Nextcloud Files app's auto upload is (or was) also used. |
| Offline | **Cached browsing + offline albums**: the whole library index and recently seen thumbnails are cached; users can pin albums/photos for offline use. |
| Editing | **Basic edits** (crop, rotate, straighten, auto-enhance, filters, light/colour) with Core Image; save as copy or overwrite. Metadata edits (date, location, tags, favorite). |
| Accounts | **Multiple accounts, one active** at a time; backup runs for one chosen account. |
| System integration | Share extension, widgets, App Intents / Siri / Shortcuts / Spotlight, Photos picker, drag & drop, export to the device library. |
| Smart features | **Server first** (Recognize faces & tags, AI captions, Assistant/TaskProcessing) **plus on-device extras** (Live Text, Visual Look Up, on-device OCR fallback, on-device natural-language query parsing). |
| Push | **Yes, via the Nextcloud push proxy** (same mechanism as Files/Talk). |
| Privacy | **Optional app lock** (Face ID / Touch ID / Optic ID / passcode) and **archived ("hidden") photos always require authentication**. |
| Delivery | **Milestones M0–M5** (§13), each shippable and testable. |
| Test servers | **An extended test server** (all extended features) for manual/UI checks and a **local server on upstream master** (and an NC 33 container) for automated integration tests and fallbacks. |

---

## 3. Platforms and technology

- **Swift 6** language mode, strict concurrency. Xcode 27. No Objective-C (except where an Apple API forces a shim).
- **SwiftUI** for all UI. The photo grid is the one exception (see §6.4): it is a platform collection view (`UICollectionView` on iOS/iPadOS/visionOS, `NSCollectionView` on macOS) wrapped in a SwiftUI view, because it must scroll 100 000+ items smoothly with pinch-zoom, drag-selection and section headers.
- **Observation** (`@Observable`) for view models; structured concurrency (`async/await`, actors) everywhere; no Combine in new code.
- **Persistence:** **GRDB** (SQLite, WAL) in the app's App Group container. Chosen over SwiftData for predictable performance with 100k+ rows, FTS5 search, and safe concurrent access from extensions.
- **Networking:** `URLSession` through the app's own `HTTPClient` (certificate trust, client certificates, 401 handling), `XMLParser` for multistatus responses, `Codable` for OCS. NextcloudKit is not a dependency.
- **Media:** PhotoKit (backup, export, picker), AVFoundation/AVKit (video), ImageIO (decoding, thumbnails, metadata), Core Image (editing), VisionKit/Vision (Live Text, OCR), MapKit (places/map), WidgetKit, App Intents, Core Spotlight, LocalAuthentication, UserNotifications, BackgroundTasks, FoundationModels (on-device language model, optional).
- **Third-party dependencies** are limited to: GRDB (MIT). The BlurHash decoder is an own implementation. Anything else needs a reason in the PR and an MIT-compatible licence.
- **Formatting/lint:** `swift-format` with a checked-in `.swift-format`, run in CI with `--strict`.

---

## 4. Architecture

### 4.1 Repository layout

```
photos-ios/
  project.yml               # XcodeGen: the Xcode project, Info.plists and build settings are generated from it
  Config/                   # Base.xcconfig (team, bundle id, version), Local.xcconfig (git-ignored, your own signing)
  App/
    Shared/                 # app entry point, app delegates, background tasks, App Intents
    Resources/              # asset catalog, string catalogs, privacy manifest
    *.entitlements
  Extensions/
    ShareExtension/         # iOS + macOS
    Widgets/                # iOS, macOS, visionOS
    NotificationService/    # iOS + macOS, decrypts push payloads
    BackgroundUpload/       # iOS + macOS, PhotoKit background-upload extension (§7.18.6)
  Packages/PhotosKit/       # one local Swift package; everything else is a target of it
    Sources/
      PhotosModel/          # value types, IDs, feature flags; no I/O
      PhotosDomain/         # pure algorithms: grouping, stacking, memories, duplicates, cleanup, search parsing
      PhotosNetworking/     # HTTP client, DAV/OCS clients, XML builders/parsers, login, feature detection, upload
      PhotosStore/          # GRDB schema, migrations, queries, sync engine, outbox
      PhotosMedia/          # preview cache, image pipeline, video/Live Photo loading, editing pipeline
      PhotosBackup/         # PhotoKit scanning, reconciliation, upload engine
      PhotosCore/           # composition root: accounts, keychain, per-account services, app/session models
      PhotosAppUI/          # SwiftUI screens, grid, viewer (not "PhotosUI": that name is Apple's framework)
    Tests/<target>Tests/    # Swift Testing, fixtures recorded from servers
  UITests/                  # XCUITest smoke tests (need a test server)
  scripts/                  # test server, string catalog helper
  docs/  LICENSE  LICENSES/  REUSE.toml  .swift-format  .github/
```

Not there: platform folders under `App/` (the platform differences live in `PhotosAppUI`). The Xcode project is not
checked in. Targets depend
downwards only, see [ARCHITECTURE.md](ARCHITECTURE.md); `PhotosDomain` depends only on `PhotosModel` and is fully
unit-testable on macOS without a server.

### 4.2 Targets and identifiers

The bundle id is confirmed. The derived group names still need to be provisioned under team NKUJUXUJ3B (see §14); use these unless told otherwise:

| Item | Value |
|---|---|
| App bundle id | `com.nextcloud.photos` |
| Extensions | `com.nextcloud.photos.share`, `.widgets`, `.notification-service`, `.background-upload` |
| App Group (own state) | `group.com.nextcloud.photos` |
| Keychain access group | `$(AppIdentifierPrefix)com.nextcloud.photos` |
| Additional App Groups (read-only use) | `group.com.nextcloud.apps` (shared accounts list), `group.it.twsweb.Crypto-Cloud` (Files app; only for backup coexistence, §7.18.5) |
| URL scheme | `nextcloudphotos://` (deep links, widgets) and handling of `nc://login/…` / `nc://onetime-login/…` QR codes |
| Background task ids | `com.nextcloud.photos.refresh`, `com.nextcloud.photos.processing` |

The app never writes to the Files app's App Group: NextcloudKit (used by Files) stores "unauthorized" markers per account in that group, and a second writer would make the two apps block each other.

### 4.3 Layers

1. **Networking** (`PhotosNetworking`)
   - `ServerConnection` per account holds the `HTTPClient`, the user agent, credentials and the trust/client-certificate delegate.
   - `DAVClient` / `PhotosAPI`: typed requests for everything under `/remote.php/dav` (SEARCH bodies, `files/`, `photos/`, `photospublic/`, `recognize/`, `systemtags*`, `comments/photos_album`, `trashbin`, PROPPATCH of metadata, REPORT), parsed with an own `XMLParser`-based multistatus parser that keeps **all** properties (NextcloudKit drops unknown ones). Handle 401 yourself (§5.1.6).
   - *Implementation decision (M0):* WebDAV, OCS and Login Flow v2 run on the app's own `HTTPClient` (one `URLSession` with the app's certificate trust and client-certificate handling), because NextcloudKit has no generic REPORT/PROPPATCH helpers, drops unknown DAV properties and keeps per-account "unauthorized" state in a shared App Group. Chunked upload (v2) is also implemented on `HTTPClient` (`Uploader`, M2) so uploads share the same trust handling and can set `OC-Checksum`. Push registration (M4) is implemented on the same client (`PhotosCore/PushNotifications.swift`), so NextcloudKit is not used at all and was removed from the package (2026-11-23).
   - `OCSClient`: OCS calls (capabilities, sharees, notifications, push, task processing, Photos OCS routes). Always send `OCS-APIRequest: true` — this is also what makes the classic Photos routes pass the CSRF check (they return 412 without it).
   - XML request bodies are built by small, tested builder functions; every value is XML-escaped (the web app doesn't escape — don't copy that).
2. **Store** (`PhotosStore`): one SQLite database per account (`<AppGroup>/Accounts/<accountId>/library.sqlite`) plus a small global database for accounts and settings. Schema in §5.4.2. All UI reads come from the store; the network only writes to the store (single source of truth, offline for free).
3. **Sync engine**: actor per account, see §5.4.
4. **Outbox**: every user write (favorite, album add/remove, delete, archive, metadata edit, tag change…) is applied optimistically to the store and queued in an `operation` table, then executed by the outbox worker with retries. Works offline.
5. **Media pipeline** (`PhotosMedia`): previews, originals, video, Live Photos, editing (§5.5).
6. **Feature model**: `ServerFeatures` value per account (§5.3) that views and services consult; UI for an unavailable feature is hidden, not disabled, unless the user would otherwise wonder where it is (then show a short explanation, e.g. "People needs the Recognize app on your server").

### 4.4 Concurrency and extensions

- Extensions (widgets, share, notification service, background upload) open the same per-account SQLite files read-only or through GRDB's `DatabasePool` with WAL; writes from extensions go through the outbox table only.
- Long work runs in `BGProcessingTask` (index backfill, preview prefetch, reconciliation) and the PhotoKit background-upload extension (§7.18.6).

### 4.5 Logging and diagnostics

`os.Logger` with subsystems per package (implemented). A rotating log file in the app container that the user can export (implemented: `PhotosCore/DiagnosticsLog.swift`): the app's own entries, redacted when written (no account names, hosts, URLs, paths, file names or tokens), at most 256 KB per file with two older files, written every few minutes and when the app goes to the background, added to "Export diagnostics…". *Deviation:* it is on by default (Settings → Diagnostics → "Keep log across restarts"), because a log of a run that crashed is only useful when it was already being kept; it never leaves the device unless the user exports it. Logs never contain passwords, tokens, full URLs with tokens, or file names. No third-party crash or analytics SDKs.

### 4.6 Error handling

Typed errors per layer (`NetworkError`, `ServerError(status, ocsCode, message)`, `StoreError`). The UI shows human sentences ("The server is in maintenance mode", "You can only add your own photos to a shared album"), with a "Details" disclosure for support. Never silently swallow a failed write: the outbox shows failed operations in a "Couldn't sync" banner with retry/discard.

### 4.7 Settings storage

User-visible settings: global database. Server-side Photos user config (§7.25) is mirrored in the account database and written back via the Photos config API.

### 4.8 Deep links

`nextcloudphotos://<accountId>/<route>` with routes mirroring the web app: `timeline`, `photos`, `videos`, `favorites`, `thisday`, `memories`, `map`, `albums/<name>`, `sharedalbums/<name>`, `places/<name>`, `faces/<name>`, `tags/<name>`, `folders/<path>`, `photo/<fileId>`. Also accept web URLs of the same account's server (`https://<host>/index.php/apps/photos/...`) when shared into the app, and public album links (`…/apps/photos/public/<token>`).

*Decided (round 4):* the account is written as the user and server of the URL: `nextcloudphotos://<userId>@<host>[:port][/<server path>]/<route>` (the account id `"<userId> <serverURL>"` cannot be a URL host); a link without it opens in the account shown. A link for another logged-in account asks before switching; one for an account that is not logged in is explained (nothing is added). A web link of a server with several accounts on the device lets the user pick the account. Also `search/<text>` (the "Search photos" intent). Public album links open the "Open public link" sheet with the link filled in, so the user sees where it leads before anything loads.

### 4.9 Branding

One `Brand` type (modelled on the Files app's `NCBrandOptions`) holds name, accent colour (`#0082C9`), logo assets, push proxy URL, default upload folder, privacy/source/help URLs, and MDM/AppConfig overrides. Optionally use the server's theming colour as accent (setting, default off).

---

## 5. Server integration

### 5.1 Authentication and accounts

1. **Login Flow v2** (reference: `nextcloud-ios-and-nextcloudkit.md` §1.1):
   1. Normalise the URL (add `https://`; never silently downgrade to http; offer "Use http" only after an explicit https failure, with a warning).
   2. `GET status.php` — handle maintenance, untrusted certificate (§5.1.4), not-a-Nextcloud.
   3. Check the server major version: < 33 → "This server is too old (Nextcloud 33 or later is required)".
   4. `POST /index.php/login/v2`, open the login URL in an **ephemeral `ASWebAuthenticationSession`** (callback scheme `nc`), poll the endpoint every second (404 = pending) until it returns `server`, `loginName`, `appPassword`. Fall back to an in-app `WKWebView` when the session fails for client-certificate (mTLS) reasons.
   5. `GET /ocs/v2.php/cloud/user` to get the real user id (may differ from login name) and display name.
   6. Store the app password in the **own** keychain group (accessibility `afterFirstUnlock` — needed for background uploads), never in the database.
   - The login UI is the app's own SwiftUI flow (`NextcloudKitUI`'s `ServerAddressView` is a reference only).
2. **QR codes** `nc://login/server:…&user:…&password:…` and `nc://onetime-login/…` (camera scanner on iOS/iPadOS; paste on macOS).
3. **Server suggestions:** read `group.com.nextcloud.apps/Library/Application Support/NextcloudAccounts/accounts.json` (written by Files/Talk/Notes) to offer "Use an account from Nextcloud Files" — prefill server and user only; still run a fresh Login Flow (each app has its own app password, so revoking one doesn't break the other).
4. **Certificates:** system trust by default. On an untrusted certificate show the certificate details and let the user trust this host's leaf certificate explicitly (store DER per host in the own App Group). Client certificates (PKCS#12 import, stored in the keychain per account) for mTLS. Extensions use exactly the same trust logic (the Files app's extensions accept any certificate — do not copy that).
5. **Multiple accounts:** account id `"<userId> <serverURL>"`. Account switcher in the toolbar/sidebar. One active account per window (on Mac/iPad/visionOS different windows may show different accounts). Backup is bound to one account (§7.18).
6. **401 handling:** on a 401 from a request, re-verify with `cloud/user`. If it is a real 401: call `POST /index.php/core/wipe/check` with the app password; if wipe is requested, delete all local data of the account and confirm with `…/wipe/success`; otherwise mark the account "signed out" and ask the user to log in again (keep the local cache until they remove the account).
7. **Logout / remove account:** unsubscribe push (server + proxy), **revoke the app password** (`DELETE /ocs/v2.php/core/apppassword`), delete keychain items, the account database, caches and offline files.
8. **User agent:** `Mozilla/5.0 (<iOS|iPadOS|macOS|visionOS>) Nextcloud-Photos/<version>`. Before finalising, check the server's client regexes (`lib/public/IRequest.php`, e.g. `USER_AGENT_CLIENT_IOS`) and pick a string that is recognised as a mobile/desktop client where that matters (session naming in "Devices & sessions") but is not mistaken for the Files app.
9. **MDM / AppConfig** (`com.apple.configuration.managed`), keys compatible with the Files app: `serverUrl`, `username`, `disable_multiaccount`, `enforce_passcode_lock`, `disable_log`, plus `disable_backup`. *Decided (round 4):* `serverUrl` fixes the login's address and refuses logins to any other server (QR codes and links too); `username` is proposed on the login page (`?user=`); `disable_multiaccount` allows logging in again to the existing account but no second one; `enforce_passcode_lock` turns app lock on and locks its switch; `disable_log` stops the kept log and diagnostics export; `disable_backup` turns backup off. Applied at launch and live; accounts that exist when a restriction arrives are not removed. `password`/`apppassword` of the Files app are not supported (credentials do not belong in a configuration profile).

### 5.2 Versions and the Photos app on each server

The Photos server app differs per Nextcloud version (details: `photos-server-api.md` §17):

| Nextcloud | Photos | Notable for the client |
|---|---|---|
| 33 | 6.0 | No editing of capture date/GPS. Old folder JSON shape. Recognize 11 always requires the API key. No HEIC EXIF. |
| 34 | 7.0 | As 33 + EXIF time-zone offset. Recognize 12: admin may disable the API key. |
| 35 | 8.0 | Date/GPS editing (`MetadataPropPatchPlugin`), `name` filter, grid density config. Old folder JSON shape. |
| 36+ | 9.x (master) | Everything in `photos-server-api.md`; extended features from `photos-extended-api.md` once merged; companion APIs if implemented. |

The app must never assume a feature from the version number alone when a probe is possible; use the version only as a coarse gate where no probe exists.

### 5.3 Feature detection

`FeatureDetector` builds a `ServerFeatures` value per account at login, on every app foreground (if older than 1 h), and on demand (pull-to-refresh in Settings → Server). Order:

1. **Capabilities** `GET /ocs/v2.php/cloud/capabilities`: server version, `files.undelete` (trash bin), `notifications`, `files_sharing` (public links, sharee search), theming. If the **`photos` capability** (proposed in `SERVER-COMPANION.md` §S1) is present, take everything it declares and skip the probes it covers.
2. **Photos bootstrap** (user config, MIME lists, `.nomedia` paths, Recognize key, which optional apps are enabled):
   1. `GET /ocs/v2.php/apps/photos/api/v1/config` (companion §S1), else
   2. **initial-state scrape**: `GET /index.php/apps/photos/` with the app password and parse the `<input type="hidden" id="initial-state-photos-<key>" value="<base64 JSON>">` elements (`photos-server-api.md` §2.1). Keys: `image-mimes`, `video-mimes`, `photosSourceFolders`, `photosLocation`, `croppedLayout`, `gridDensity`, `nomedia-paths`, `recognize`, `systemtags`, `maps`, `recognizeApiKey`, and on extended servers `trashbin`, `caption-search`, `video-renditions`, `smartAlbums`, `albumsSortOrder`, `albumPhotosSortOrder`, `onThisDayNotifications`. Isolate this in `InitialStateScraper` with fixtures per server version; it is a fallback, expect it to break one day.
   3. Defaults: source folders `["/Photos"]`, upload folder `/Photos`, MIME lists below.
3. **Probes** (only for what 1–2 didn't answer; cache results):

| Feature flag | Probe |
|---|---|
| `photosDAV` | `PROPFIND /remote.php/dav/photos/<uid>/` → 207 |
| `places` | `PROPFIND …/photos/<uid>/places/` Depth 0 → 207 |
| `recognize` | `PROPFIND /remote.php/dav/recognize/<uid>/` → 404 = absent; 403 without key = present |
| `systemtags` | `PROPFIND /remote.php/dav/systemtags/` → 207 |
| `metadataEdit` (date/GPS) | Nextcloud ≥ 35 (no side-effect-free probe) |
| `albumCover`, `albumDescription`, `albumComments` | one `PROPFIND …/albums/` Depth 1 asking `nc:cover nc:description nc:album-id`; 404 propstat = unsupported |
| `albumLastModified` | album `d:getlastmodified` ≠ 0 |
| `placeCountry` | `PROPFIND …/places/` Depth 1 asking `nc:place-country` |
| `timelineDays` | `GET /ocs/v2.php/apps/photos/api/v1/timeline/days?mediaType=all` → 200 vs 404 |
| `taskText2Text`, `taskOCR`, `taskAnalyzeImages` | `GET /ocs/v2.php/taskprocessing/tasktypes` |
| `unifiedSearchPhotos` | `GET /ocs/v2.php/search/providers` contains `photos_albums` |
| `videoRenditions`, `captions`, `albumFilterTags` | only via the `photos` capability or initial state (`video-renditions`, `caption-search`); otherwise treat as unavailable |

**Default MIME lists** when nothing is known: images `image/jpeg, image/png, image/heic, image/heif, image/webp, image/avif`; videos `video/mp4, video/quicktime`. Extended servers add `image/gif, video/webm, video/x-m4v, video/x-matroska`. The app may additionally include `image/tiff` and RAW (`image/x-dcraw`; verify the server's mimetype mapping for `.dng`) in its own SEARCH so Apple ProRAW/RAW uploads are visible (setting "Show RAW files", default on; shown as stack variants, §7.1.6). Server-side features (places, smart filters, day counts) will not include them; that is acceptable.

### 5.4 Local index and sync

The app keeps a **complete local index** of the user's media metadata (not the files). This makes the timeline instant, works offline, and lets Map, Memories, Duplicates and search cover the whole library (the web app only looks at the newest 500–20 000 items).

#### 5.4.1 What is indexed

- **Timeline media**: all files with an allowed MIME type under the user's `photosSourceFolders` (the same scope as the web timeline), plus the archive folder `/.archive` (§7.13), with these properties: `oc:fileid`, href/path, `d:displayname`, `d:getcontenttype`, `oc:size`, `d:getetag`, `d:getlastmodified`, `nc:upload_time`, `oc:favorite`, `oc:permissions`, `nc:mount-type`, `oc:owner-id`, `nc:has-preview`, `nc:hidden`, `nc:metadata-photos-original_date_time`, `nc:metadata-photos-size`, `nc:metadata-photos-gps`, `nc:metadata-photos-place`, `nc:metadata-blurhash`, `nc:metadata-files-live-photo`, and when available `nc:metadata-photos-place-country`, `nc:metadata-photos-caption`. EXIF/IFD0 and face detections are fetched lazily per photo (info panel) and cached.
- **Collections**: albums (own, shared with me), places, people (if Recognize + key), tags, smart albums, and their membership.
- Files under `.nomedia`/`.noimage` folders are excluded (§7.11).

#### 5.4.2 Schema (per account, GRDB)

| Table | Key columns |
|---|---|
| `media` | `fileId` PK, `path`, `name`, `mime`, `kind` (image/video), `size`, `etag`, `mtime`, `uploadTime`, `captureTime` (unix s), `captureOffset` (from EXIF, lazy), `width`, `height`, `lat`, `lon`, `alt`, `place`, `placeCountry`, `favorite`, `permissions`, `mountType`, `ownerId`, `hasPreview`, `blurhash`, `livePhotoPeer`, `isLivePhotoVideo` (nc:hidden), `caption`, `isArchived`, `sourceRoot`, `syncGeneration`, `localStateFlags` |
| `album` | `id` (own: name; shared: name incl. owner suffix), `kind` (own/shared/public), `title`, `ownerId`, `location`, `description`, `coverFileId`, `lastPhotoFileId`, `count`, `dateStart`, `dateEnd`, `filters` (JSON), `collaborators` (JSON), `serverAlbumId`, `lastModified`, `fetchedAt` |
| `albumItem` | `albumId`, `fileId`, `childName` (`<fileid>-<filename>`), `origin` (user/filters), `ownerPath` |
| `place` | `name` PK, `country`, `count`, `coverFileId` |
| `placeItem` | `place`, `fileId` (or derived from `media.place`; keep the server listing as truth because it is home-storage-only) |
| `person` | `name` PK (title or numeric cluster id), `count`, `coverFileId`, `coverBox` |
| `personItem` | `person`, `detectionId`, `fileId`, `childName`, `box` |
| `tag` | `id` PK, `name`, `visible`, `assignable`, `count`, `coverFileId` |
| `tagItem` | `tagId`, `fileId` |
| `smartAlbum` | `id`, `name`, `filters` (JSON), `origin` (server/local) |
| `operation` | outbox: `id`, `kind`, `payload` JSON, `fileId`, `etag` (of the file when queued), `state`, `attempts`, `lockedAttempts`, `lastError`, `createdAt`, `nextAttemptAt` |
| `offlinePin`, `offlineFile` | pinned albums/photos; downloaded originals (`fileId`, `etag`, `localPath`, `bytes`) |
| `previewCache` | `fileId`, `etag`, `bucket`, `bytes`, `lastUsed` (LRU bookkeeping; files on disk) |
| `faceDetections` | `fileId`, JSON, `fetchedAt` |
| `exifCache` | `fileId`, `etag`, JSON |
| `syncState` | per source root: `rootEtag`, `lastFullSync`, `lastDeltaSync`, `generation`, companion `syncToken` |
| `searchIndex` | FTS5 over name, place, country, caption, tag names, person names, album titles, folder path |
| `backup*` | see §7.18.3 |

Indexes on `captureTime DESC`, `(kind, captureTime)`, `favorite`, `place`, `(lat, lon)`, `livePhotoPeer`, `path`.

#### 5.4.3 Initial sync

1. If `timelineDays` is available, fetch day counts first and render a **skeleton timeline** (month sections with placeholder tiles) immediately.
2. Fetch the index with SEARCH (body: `photos-server-api.md` §5.1; one `d:scope` per source folder) ordered by `nc:metadata-photos-original_date_time` descending, in pages of **1000** with minimal props.
   - Prefer **keyset paging** over offset paging (offset paging shifts when files are added during the sync): next page = `original_date_time < lastSeen` plus the tie rule `original_date_time = lastSeen AND fileid < lastFileId`, if the server accepts ordering by `oc:fileid` (verify in `apps/dav/lib/Files/FileSearchBackend.php`; if not, use overlapping time windows and de-duplicate by fileId).
   - The SEARCH operator limit is 100 per query: build the MIME `or` from at most ~15 types and keep filters small.
   - Hidden live-photo videos and `.nomedia` files count toward page sizes; never treat a short page as "end" unless it is empty under keyset paging.
3. Show results progressively (newest first). Target: first screen in < 3 s, 100 000 items indexed in < 10 min on Wi-Fi (§10).
4. Then load collections (albums, places, tags, people) in parallel, lowest priority.

#### 5.4.4 Incremental sync

Triggered on foreground, pull-to-refresh, every 5 min while the app is open and visible, after the app's own uploads, by push notifications, and in `BGAppRefreshTask`.

1. **Companion change feed** (`SERVER-COMPANION.md` §S2) if available: apply added/changed/removed since the stored `syncToken`. Done.
2. Otherwise:
   1. `PROPFIND Depth:0` on each source root for `d:getetag` (it changes when files below are added, changed, moved or deleted — but **not** when a favourite is set or the server fills in place/caption). Read it once, before anything is fetched, and store that value only after the sync is through, so a change made while syncing is seen by the next sync. Unchanged → only the favourites check: one SEARCH for the file ids with `oc:favorite = 1`, compared with the store.
   2. Changed → SEARCH for items with `d:getlastmodified > lastDeltaSync − 10 min` **or** `nc:upload_time > lastDeltaSync − 10 min` (covers new uploads with old mtimes) → upsert.
   3. Metadata that the server fills asynchronously (place, caption, EXIF for files on external storage) arrives later without an mtime change: re-fetch props for items uploaded in the last 48 h whose place is still unknown when they reach a checkpoint (10 min, 1 h, 6 h, 24 h, 47 h after the upload; looked at no more than every 10 minutes), and run a full **reconciliation** (step 4) after a root ETag changed (the delta SEARCH cannot see deletes and moves) but at most every 10 minutes (longer for large libraries: about one request per thousand items, so 150 000 items once an hour) and not while a backup pass uploads, on pull-to-refresh only when the last one is 10 minutes old, at once on "Sync now", and otherwise once a day.
   4. **Reconciliation**: page through all items with props `oc:fileid`, `d:getetag`, `oc:favorite`, `nc:metadata-photos-place`, href (cheap), (and the caption where the server has it) and compare with the store: delete what is gone, fix moved paths, re-fetch full props of items whose etag, favourite flag, place or caption differ. A reconciliation that was requested but interrupted (offline, cancelled, requested during a running sync) stays due, and it is resumable: the rows it has not met yet are kept in a table and its cursor in the sync state, so the next sync goes on from the page it reached; only one page and its stored rows are in memory. A listing that lacks more than half of an index of more than 20 items, or items on mounted storage (external storage, shares, group folders), is not applied at once (a storage that is not mounted looks the same as a mass delete): those items are kept as suspects, and a later listing removes only the suspects it lacks too, at least an hour after the first, and only when a sample of them answers 404 by path. Smaller removals are checked by file id first.
3. **Collections**: album list PROPFIND is expensive on the server (every album resolves all its files). Refresh the album list when the Albums view appears if older than 10 min, after own album writes, and in background daily; refresh one album's content when it is opened. Places/tags/people: when their view appears if older than 30 min. If the companion album change tag (`SERVER-COMPANION.md` §S7) exists, use it to skip unchanged albums.

#### 5.4.5 Conflict rules

Server wins for everything except operations still in the outbox: a sync does not touch the rows of files with queued operations. The outbox runs up to 5 operations at the same time, but never two for the same file: an operation waits for every operation queued before it for its file. A connection problem (offline, timeout, 5xx, 429) pauses the whole queue with exponential backoff up to 1 h; it resumes when the backoff ends or the network comes back. Queued deletes and moves send the path and ETag the index has with `If-Match` (one request); when the server answers 412 or 404 (the file was moved, changed or replaced meanwhile) they look the file up by its id and act on the path the server reports, so a file that was moved meanwhile is found and another file at the old path is not touched; the other operations do the same when their path answers 404, and a completed move rewrites the paths of the operations still queued for that file. 423 (locked) is retried like a transient error, but holds back only the operations for that file, and is given up after 8 answers of 423 (failures for other reasons do not count). Album content read from the server is shown with the album operations still queued applied on top. When rows are read again after a failed or discarded operation, only files the timeline shows (or already has rows for) are written to the index. If an outbox operation fails for good with 403/404/409 (file gone, no permission, already in album), or the user discards it, refresh the affected item so the optimistic change is undone; 409 on album add means "already there" and is a success.

### 5.5 Previews, originals, video

#### 5.5.1 Previews

- Use **`GET /index.php/apps/photos/api/v1/preview/{fileId}?x=N&y=N`** for all authenticated previews (it is the only route that can preview photos in albums shared by others). Use `publicPreview?…&token=` for public albums and `/index.php/apps/files_trashbin/preview?fileId=…` for the trash.
- Request only the bucket sizes **64, 256, 1024, 4096** (the server rounds up to these and pregenerates 64/256/1024 on extended servers). Pick the bucket from tile pixel size (point size × display scale, scale capped at 2, 0.8 tolerance; `photos-extended-api.md` hidpi-aware-previews).
- The server preview is not cropped (aspect-fit). Square tiles crop client-side (centre, or face-aware if detections are cached).
- Show `nc:metadata-blurhash` while loading.
- **Disk cache** keyed by `(account, fileId, etag, bucket)`, LRU, default limit 2 GB (setting: 500 MB – 20 GB). Memory cache sized by the platform. Prefetch around the scroll position (UICollectionView prefetching) and in `BGProcessingTask` for the first screens of the timeline and recently opened albums.
- If `nc:has-preview` is false or the preview request returns 404 (e.g. HEIC on a server without a HEIC preview provider), download the original (images < 50 MB) and make a thumbnail locally with ImageIO (`CGImageSourceCreateThumbnailAtIndex`), cached like a server preview. RAW/DNG likewise.

#### 5.5.2 Full-size viewing

Progressive: blurhash → cached tile preview → 1024 preview → 4096 preview when zoomed past 1.5× or on large displays → **original** when zoomed past the 4096 preview's resolution, when the user chooses "Show original", or for HDR (gain-map HEIC/JPEG) display. Originals load with `GET` on the DAV path (for album/shared items use `nc:photos-collection-file-original-filename`/`nc:realpath`, or the album child's own URL which streams the original) with progress, cached on disk (part of the same LRU, separate cap of 1 GB unless pinned offline). Display HDR originals with high dynamic range on capable screens.

#### 5.5.3 Video

- Play with `AVPlayer`. Prefer a local copy (offline album file, cached original). Otherwise get a temporary URL from the direct-download API (`POST /ocs/v2.php/apps/dav/api/v1/direct` with `fileId`) and feed the player through an `AVAssetResourceLoaderDelegate` that fetches byte ranges with the app's own `HTTPClient` (`PhotosMedia/VideoStreaming.swift`): AVFoundation loading the URL itself would ignore certificates the user trusted in the app and the account's client certificate.
- Formats AVFoundation can't play (WebM, MKV, some AVI): if `videoRenditions` is available, fetch `GET /apps/photos/api/v1/video/{fileId}` (it may 404 while the conversion is queued: show "Preparing video…" and retry with back-off up to 2 min). The rendition currently has `Accept-Ranges: none`, so download it to a temp file before playing (companion §S6 fixes this). Otherwise offer "Download" / "Open in…".
- Grid tiles of videos show the duration (from companion metadata `nc:metadata-photos-duration`, `SERVER-COMPANION.md` §S8, else read lazily when first played and cached; the server has no duration today).

#### 5.5.4 Live Photos

A still whose `nc:metadata-files-live-photo` holds a file id is a Live Photo; the referenced `video/quicktime` file (`nc:hidden = true`) is its motion part and is **never shown as its own item**. In the viewer, download both parts (still preview/original + MOV) and build a `PHLivePhoto` from the two file URLs; play on long-press (iOS) / hover or a "Live" button (Mac, visionOS). Grid shows a Live badge; optional "Play Live Photos in the grid" setting (off by default).

---

## 6. User experience

### 6.1 Principles

- Native: the app should feel like it was made by Apple's Photos team, in Nextcloud blue. System controls, Liquid Glass bars, SF Symbols, standard gestures and keyboard shortcuts, context menus everywhere.
- Fast: everything comes from the local store; network work never blocks the UI.
- Honest: show sync and backup state clearly; never claim something is backed up or shared before the server confirmed it.
- Respect the server's model: albums, folders and paths behave like in the web app so that users can switch between web and app without surprises.

### 6.2 Information architecture

The structure mirrors the web app's navigation (including the extended "Advanced" grouping) and adapts per platform.

**iPhone** — tab bar (`TabView`, Liquid Glass):
1. **Library** — the timeline (All / Photos / Videos / Favorites as a segmented control or filter menu), memories strip at the top, search & filter button.
2. **Collections** — sections: Memories (trips, year recap, On this day), Albums, Shared albums, Smart albums, People, Places (with Map entry), Tags, Folders, Shared with you; at the bottom "Utilities": Archive, Recently deleted, Duplicates, Free up space, Backup status.
3. **Search** (search tab role) — unified search (§7.7).

**iPad, Mac, visionOS** — `NavigationSplitView` with a sidebar:
- Library: All media, Photos, Videos, Favorites, On this day, Memories, Map
- Collections: Albums (expandable list of albums), Shared albums, Smart albums (each smart album as a row), People, Places, Tags
- Advanced (collapsed by default): Folders, Shared with you, Archive (lock icon), Recently deleted, Duplicates, Free up space
- Backup status row at the bottom; account switcher in the sidebar header.

**macOS specifics:** menu bar commands (File: New Album, Upload…, Export…; Edit: Select All, Favorite ⌘., Delete ⌫, Info ⌘I; View: zoom ⌘+/⌘−, Show sidebar, Square Tiles ⌥⌘S; Image: Rotate ⌘R, Edit ↩︎), multiple windows (open album/person/place in new window or tab), space bar quick look in the grid, drag & drop with Finder and other apps, Settings scene, toolbar search field.
Decided in round 4 (as in Photos): Image ▸ Rotate Left ⌘R and Rotate Right ⌥⌘R work on the selection and save like the editor's "Overwrite original" (a new file version; not offered for read-only shares or formats that can't be written back), View ▸ Sync Now is ⇧⌘R; Edit ▸ Copy puts the originals on the pasteboard (image data and file URL; at most 100 items, Export for more); "Add to Album" is a submenu (New Album…, the albums used last in this app, then the most recently changed, All Albums…); the grid's context menu has Copy, Rotate, Share (system share menu/sheet) and the same submenu; an album opens in its own window from File ▸ Open in New Window, its card's context menu or ⌥-click (one window per album, restored with the app; it shows the album only while its account is the active one).

**visionOS specifics:** main window with sidebar; viewer opens in its own window that can be enlarged; spatial photos (stereo HEIC) are presented spatially; panoramas may open in an immersive space (M5). *Decided (round 4):* a spatial photo is recognised from the original's stereo pair group (read when a HEIC is viewed on Vision Pro) and shown with `ImagePresentationComponent`; a panorama (≥ 3000 px wide, ≥ 2:1, from the server's size) opens in an immersive space on a cylinder segment (aspect × 60°, at most 360°).

### 6.3 Empty, loading and error states

Every view has: first-load skeleton, empty state with a single helpful action (e.g. "Turn on backup", "Create album"), offline banner when showing cached data, and inline error with retry. Missing server features show an explanation instead of a broken view.

### 6.4 Photo grid

- Square tiles by default; "Aspect ratio" mode shows each photo whole. *Decided (round 4):* as Apple Photos' "Aspect Ratio Grid" the photo is fitted into its square cell (letterboxed), not laid out in the web's justified rows — the grid keeps one layout, its performance budgets, scrubber and keyboard navigation. The setting is per device (Settings › On this device › Square tiles, View ▸ Square Tiles ⌥⌘S) and neither follows nor writes the web's `croppedLayout`: the web defaults to `false` (its justified layout), a client cannot tell that default from a choice, and following it would turn most grids away from square tiles.
- Pinch to change column count (iPhone 3–9 columns, iPad/Mac more); Mac: ⌘+/⌘− and a toolbar slider. Map the density to the server config `gridDensity` (small/medium/large) where available.
- Section headers: **month** (sticky) and **day** headers (local calendar day of the capture time, "Today", "Yesterday", weekday names within the last week), each with a select-all checkbox while selecting.
- **Date scrubber** on the trailing edge with year labels, covering the whole library (from the local index; skeleton from `timelineDays` during the initial sync). *Decided (simulator pass):* on iPhone, iPad and Vision Pro it is not UIKit's section index (which lists every year in a column over the photos, into the tab bar) but the Mac's scrubber: it runs between the bars, appears while the grid scrolls and fades out like Photos' scroll indicator, can be grabbed at the edge only while shown, leaves out year labels that do not fit (the newest and oldest stay), draws each label on a background of its own, and stays for VoiceOver as an adjustable element (a year per swipe).
- Badges: video duration, Live, favourite (heart), stack count, shared-album origin, offline (pinned), cloud-only original state where relevant, archived.
- Selection: tap "Select", then tap or **swipe across tiles to select ranges** (iOS), two-finger pan to multi-select, drag a rectangle / ⇧-click / ⌘-click (Mac), keyboard navigation with arrow keys, ⌘A select all.
- Performance budget in §10.

### 6.5 Design tokens

Centralised in `PhotosUI/Design`: accent colour, tile spacing (1 pt iPhone, 2 pt iPad/Mac), corner radii (0 in grid, system radius for cards), typography (system text styles only, Dynamic Type), materials. Light/dark/increased contrast all supported.

---

## 7. Features

Each feature lists **Requires** (server features) and **Milestone**. Requirement ids (e.g. `TL-3`) are for tests and PR descriptions. Wire formats are in the reference files; constants of client algorithms are in `photos-extended-api.md` §4.3–4.4 — port them exactly and port the web app's unit-test cases as parity tests.

### 7.1 Timeline (Library) — M1

Requires: core.

- **TL-1** Views: All media, Photos only, Videos only, Favorites. Same scope as the web timeline (`photosSourceFolders`, allowed MIME types, hidden live-photo MOVs and `.nomedia` excluded).
- **TL-2** Order by capture time (`original_date_time`, falling back to mtime) descending; group by month and local calendar day (§6.4). Show capture time in the photo's own time zone when the EXIF offset is known (`OffsetTimeOriginal`, parsing rules in `photos-extended-api.md` capture-local-time), else device local time.
- **TL-3** Memories strip at the top of "All media" when no filter is active: "N years ago" cards from the On-this-day query (§7.12), cover = first favourite or middle photo.
- **TL-4** Filter bar / search entry (§7.7) applies to the timeline; "Save as smart album" and "Create album from filters" from an active filter.
- **TL-5** Pull to refresh = incremental sync; sync status in the toolbar (spinner, "Updated just now", offline).
- **TL-6** **Stacks** (setting "Stack similar photos", default on): (a) bursts — consecutive photos ≤ 3 s apart (min. 2) *(decided, round 4: only bursts the camera marked in the file names (`BURST` + number, `COVER` frame shown) are stacked; iPhone bursts need Apple's BurstUUID, which stock servers do not report, and the time rule also stacks quick single shots, which Apple Photos never does)*; (b) shot variants — same folder + same normalised shot name (`IMG_E1234` ↔ `IMG_1234`, `(edited)`, `-edited`, `~2`, RAW+JPEG…; rules and leader ranking in `photos-extended-api.md` stack-same-shot-variants). A stack shows its leader with a count badge; opening it shows all members; actions on a stack apply to all members after confirmation *(decided, round 4: delete, favourite, archive, add to album, tags and date/location apply to all members, the delete confirmation counts them; open, info, edit, share and export use the shown copy, as Apple Photos does with RAW + JPEG)*.
- **TL-7** Source folders: Settings → Library → "Timeline folders" edits `photosSourceFolders` (folder picker over the user's files) and writes the server config; changing it triggers a re-index.

### 7.2 Viewer — M1

- **VW-1** Full-screen pager over the current context (timeline, album, place, person, search result), swipe left/right, pinch and double-tap zoom, swipe down to close (iOS), arrow keys / space (Mac), keep position when returning to the grid (matched geometry transition).
- **VW-2** Progressive loading (§5.5.2), Live Photos (§5.5.4), video playback with standard AVKit controls, AirPlay, Picture in Picture.
- **VW-3** Toolbar: favourite, share, add to album, info, edit, delete; more menu: archive, download/export, edit date & location, tags, extract text, set as album cover (own album), remove from album, "Show in timeline", "Show in folder".
  "Show in timeline" is labelled "Show in library" ("Show in Library" on the Mac), after the place it opens (Apple: "Show in All Photos"); it is not offered in the Library itself or for archived photos, opens the Library at the photo's tile (its stack's tile; else the tile closest in time) and marks it (selected on the Mac, a short ring elsewhere).
- **VW-4** Live Text and Visual Look Up on photos (VisionKit `ImageAnalysisInteraction`/`ImageAnalysisOverlayView`); copy subject (lift subject) where the platform supports it. Only the photo shown is analysed, from its preview, after a short pause; paging cancels it; nothing is analysed while the app is locked or its window is not active.
- **VW-5** Slideshow from any context: crossfade/Ken Burns, interval setting, loop, plays videos; on Mac full screen; AirPlay. Started from the viewer (from the photo shown), a grid's context menu or selection (several selected: those; one: the grid from it) and File › Play Slideshow. Intervals 2/3/5/10/20 s (default 3), Repeat on by default (off: stops on the last photo). Videos play to their end. Mac: a window of its own in full screen. iPhone/iPad: AirPlay button for videos; photos reach a TV by Screen Mirroring.
- **VW-6** Stacks: a strip of stack members in the viewer. A stack is one page; the strip (picture and format of each copy) chooses the copy the page shows and acts on.

### 7.3 Selection actions — M1 (album/tag actions in their milestones)

Favourite / unfavourite, add to album, share (system share sheet with originals, or "Share link" = quick share §7.6.4), export (save to device Photos library — `PHPhotoLibrary` add-only permission — or Files/Finder), delete (to the server trash; confirm with count; explain when the trash bin is disabled that deletion is permanent), archive, edit date & location (§7.16.3), tags, download for offline. All writes go through the outbox with optimistic UI; bulk operations run with at most 5 concurrent requests and report per-item failures.

Undo (Edit › Undo, ⌘Z, shake, and the Undo button of the confirmation) covers favourite, archive, remove from album and delete. A change is registered with the undo manager of the window it was made in; the confirmation's Undo only takes back its own change (a second tap while it runs does nothing), and everything is forgotten when the account is switched or removed. Undoing a delete takes the deletes that have not been sent yet out of the queue and puts their photos back at once (offline too), waits for the ones being sent, and restores only what reached the server from the trash bin (any file type), putting the photos back into the albums they were in (the server takes a deleted file out of every album). A delete the server refused is not reported as "couldn't be restored": nothing was deleted. Deleting a photo shared with the user offers no Undo (it does not land in the user's trash bin).

### 7.4 Info panel — M1 (people/caption parts in M4/M5)

Sheet on iPhone (swipe up in the viewer), inspector on iPad/Mac/visionOS. Shows: file name (rename allowed if the user owns the file), capture date & time with time zone, camera make/model, lens, focal length, aperture, shutter, ISO, flash, dimensions & megapixels, file size & format, map snippet with place and country (MapKit), path in Nextcloud (tap → Folders), owner (for shared files), albums containing it (own albums known locally), tags, people in the photo (face crops from `nc:face-detections`, show only detections with `clusterId ≥ 0` and a title, ordered left to right), AI caption (if present). Layout as an aligned two-column list (label / value), like the extended web dialog.

### 7.5 Albums — M2

Requires: `photosDAV`. Wire formats: `photos-server-api.md` §6, §7; extended props `photos-extended-api.md` §4.1.

- **AL-1** Album list as a grid of covers with title, count and date range; sort by Recently changed / Name / Date of photos (setting synced to `albumsSortOrder` when supported, else local). Cover = `nc:cover` if > 0, else `nc:last-photo`.
- **AL-2** Album view: hero with cover, title, location, description (extended), date range, collaborators; photo grid sorted oldest/newest first (`albumPhotosSortOrder`). No server paging — load all children; render progressively.
- **AL-3** Create (name, location, description) via `MKCOL` + `PROPPATCH`; rename via `MOVE` with `Overwrite: F`; delete via `DELETE` (confirm; photos are not deleted).
- **AL-4** Add photos: from the timeline picker (only the user's own files, `nc:mount-type` = own; explain why shared files can't be added), from a selection anywhere, from drag & drop, from the share extension. `COPY` from `/files/<uid>/<path>` into the album; 409 = already there. Upload-and-add for device photos (§7.17).
- **AL-5** Remove from album (`DELETE` of the child `<fileid>-<filename>`); hide the action for items with origin `filters`.
- **AL-6** Filter-based ("smart filter") albums: edit the album's `nc:filters` (date ranges, places, name; `tags` only if `albumFilterTags`). Items pulled in by filters are marked and cannot be removed.
- **AL-7** Extended: choose cover (`nc:cover`), description (`nc:description`, ≤ 2000 chars), comments (§7.6.5).
- **AL-8** Offline: "Make available offline" on an album (§7.19).

### 7.6 Sharing — M2

- **SH-1** Collaborators on own albums: users and groups via sharee autocomplete (`/ocs/v2.php/core/autocomplete/get?itemType=share-recipients&shareTypes[]=0&shareTypes[]=1`), set by PROPPATCH of the full `nc:collaborators` JSON list. Warn when removing a user: their added photos leave the album.
- **SH-2** Public link: add `{"id":"","type":3}`, read the generated token back, show link `https://<host>/index.php/apps/photos/public/<token>` with Copy, Share, QR code; remove link.
- **SH-3** Shared albums ("Shared with you"): list albums shared with the user or their groups; show title without the `(owner)` suffix plus owner avatar/name; add own photos; remove photos (own); **Leave album** (= DELETE) with a clear warning that their added photos are removed from the album.
- **SH-4** **Quick share** a selection: create album "Shared on <date>" (suffix (2), (3)… if taken), copy the photos in, add a public link, present the share sheet with the link; roll back on failure (`photos-extended-api.md` quick-share-selection).
- **SH-5** Comments on own and shared albums when `albumComments` (comments DAV `/remote.php/dav/comments/photos_album/<albumId>`): list, post, delete own; not for public links.
- **SH-6** **Public album viewer**: open a public link (pasted, from the share sheet, or deep link) anonymously via `/remote.php/dav/photospublic/<token>` with `Authorization: Basic base64("<token>:")`, previews via `publicPreview`; read-only grid, viewer, slideshow, download/export. Does not need an account.
- **SH-7** **Share via Nextcloud** (photo or folder): Nextcloud's own sharing through the OCS Files Sharing API (`/ocs/v2.php/apps/files_sharing/api/v1/shares`, recipients from `…/sharees`), on every server without a Photos change. Recipients: users, groups, users and groups on other servers (federation), email addresses, Teams, Talk conversations (when the `spreed` capability is there); what is offered follows `capabilities.files_sharing`. Public links with password, expiry date (enforced limits respected), permissions (folders: view, view and upload, file drop), hide download, label and note. Existing shares are listed and can be changed or removed. Albums keep SH-1/SH-2: the Photos server shares albums only with users, groups and one public link; the album sharing sheet says that other servers, email and Talk work for photos and folders, not for albums (that would need a server change). All links are shown and copied through one view (`SharedLinkView`, warns for http). Several photos at once: one share per photo and recipient (Nextcloud shares one file per share), email recipients left out (one email per photo); a public link to several photos is an album with a link (SH-4).
- **SH-8** **Partner sharing**: Settings › Partner sharing lists folders shared with the user (received user/group shares); turning one on indexes it with the timeline folders (only that folder is read, no rebuild) and its photos get a partner badge; a toolbar button and a switch hide or show them in the timeline. "Share my photos with a partner…" opens SH-7 for the upload folder. Stored per account on the device; the server and the web app's timeline folders are not changed.
- **SH-9** **Activity in shared albums**, without server changes: every listing of the albums (opening Albums, and after a sync at most every 15 minutes) is compared with the stored one; an album shared with the user, or an own album shared with people, that has more photos than before, and an album newly shared with the user, become an entry of a local activity list ("New in shared albums" row above the albums, list with "Mark all as seen"; opening the album marks it seen). Photos added in this app are not reported (the outbox raises the stored count first). Found by a background refresh while the app is not in front, it is also announced with a local notification (Settings › Shared albums, only if notifications are allowed; opens Shared albums). Instant push ("Anna added 12 photos") needs the server to send it (companion S5); the Photos server reports no adder either.

### 7.7 Search, filters and smart albums — M4 (basic filter bar in M1)

- **SR-1** One search field with suggestion groups: Places, People, Tags, Dates, Albums, plus free text (file name and, when captions are searchable, caption). Diacritic- and case-insensitive substring matching, prefix matches first, max 6 per group; typed years and month names ("jun 2023") become date ranges (rules: `photos-extended-api.md` unified-photo-search). Suggestions come from the local store.
- **SR-2** Selected suggestions become filter chips (AND between kinds, OR within a kind). Filtering runs **locally** on the index; tag and person filters use the cached memberships (fetch the tag/person membership on first use).
- **SR-3** Free-text search also queries the local FTS index (names, places, captions, tags, people, album titles). Album titles are those of own and shared albums whose content was read (not opened public links). Photos that are only known as members of an album (another user's photos in a shared album, own albums' photos outside the timeline folders) are found too, by free text (name, place, caption, album titles) and by the album chip; searches without text or album stay in the library.
- **SR-4** **Ask your photos** (natural language, e.g. "beach photos from summer 2023 in Italy"): turn the sentence into filters, never into an answer text. (a) If `taskText2Text` is available, use the server's TaskProcessing exactly as the web app does (prompt with today's date and the place/tag vocabulary, JSON reply, validation; `photos-extended-api.md` ask-your-photos). (b) Otherwise, if Apple Intelligence is available on the device, use the on-device **Foundation Models** framework with guided generation into the same filter struct. (c) Otherwise hide the feature.
- **SR-5** **Smart albums** (saved filters): "Save as smart album" from active filters; list in Collections/sidebar. Stored in the server user config `smartAlbums` when the companion config read API exists (so it syncs with the web app); otherwise stored locally and labelled "On this device".
- **SR-6** Spotlight & Shortcuts surface search (§7.23).
- **SR-7** **On-device labels** (opt-in, Settings › Search): Vision's image classifier labels the previews already in the cache (no downloads for it) with English words ("dog", "beach"), which go into the FTS index (SR-3). Stored only in the account's database on the device, never uploaded; turning it off deletes them. Runs only when the system grants maintenance time: a `BGProcessingTask` that requires external power on iPhone/iPad, an `NSBackgroundActivityScheduler` activity of background quality on the Mac (deferred in Low Power Mode); not on Vision Pro. Where the extended server's caption search exists it is used as before.

### 7.8 Places and Map — M4

Requires: `places` for the Places list; Map works on any server from GPS in the index.

- **PL-1** Places list: grid of place covers with count, grouped by country when `placeCountry` (country name from `Locale.current.localizedString(forRegionCode:)`, "Other" for unknown), else flat and sorted by count. Place content as a timeline-like grid.
- **PL-2** Note: server places only cover images in the user's own storage; the app shows the server's lists as they are (parity) and uses its own index for the Map.
- **MP-1** Map (MapKit) of all photos with GPS in the local index (the whole library — not the web's 500), clustered with `MKClusterAnnotation`, cluster thumbnails; tap a cluster → grid of its photos; "Photos in this area" grid for the visible region; time slider filtering by month range.
  Decided in round 4: an `MKMapView` (SwiftUI's `Map` cannot cluster). Its annotations are not the photos but grid cells the database adds up (power-of-two degrees, a 16th to an 8th of the visible span), which MapKit clusters where they overlap: one annotation per photo costs 1.45 s for 50 000 (budget 200 ms). A cluster shows its newest photo and the photos of all its cells. The map opens on the area of all geotagged photos. The time slider is a panel shown with "Time range" in the toolbar: two month sliders (From, To) from the month of the oldest to that of the newest geotagged photo, the months in its title, "All time" to reset; markers, cluster lists and "Photos in this area" follow it.
- **MP-2** Place/map entry points from the info panel (photo location → map centred there).

### 7.9 People — M4

Requires: `recognize` and a Recognize API key (`photos-server-api.md` §13).

- **PE-1** Getting the key, in this order: companion endpoint (§S4); initial-state scrape `recognizeApiKey` (valid 24 h, refresh after 20 h or on 403); if the admin disabled the key requirement (Recognize ≥ 12), no key is needed. If none works: People shows "Your server doesn't allow apps to access people yet" with a link to admin docs, and the info panel still shows faces (they need no key).
- **PE-2** People list sorted by number of photos, face-cropped covers (`nc:face-preview-image` box, margin factor 1.4); unnamed clusters show as "Add name".
- **PE-3** Person view; rename (`MOVE`), merge into another person (move every detection, then delete the source), remove a photo from a person ("Not this person", `DELETE` the detection child), move photos to another person, create a person (`MKCOL`), delete a person.
- **PE-4** Unassigned faces with assign-to-person flow.
- **PE-5** Detection children are addressed as `<detectionId>-<filename>`; never by bare file name.

### 7.10 Tags — M4

Requires: `systemtags`. List of tags used on images with counts and covers; tag content (REPORT `oc:filter-files`, filter MIME locally); assign / unassign / create tags from the info panel and the selection menu. Tag colours if the server provides them.
Assigning and removing go through the outbox (`PendingOperation.tag`, PUT/DELETE `systemtags-relations/files/<fileId>/<tagId>`), so they work offline and show in search at once; creating a tag needs the server (it assigns the id; an existing tag of the same name is reused). Tag and people memberships are copied into the local store (`LabelSync`: one listing every 30 minutes, the files of a tag or person only when its count changed, everything once a day; never while changes wait in the outbox) for search (SR-3) and for tag/person filters and tag browsing without a connection.

### 7.11 Folders and "Shared with you" — M4

- Browse the user's folders showing only folders that contain media (within 4 levels) and the media in them, like the web Folders view, with a mosaic of up to 4 photos per folder (extended `attributes.previews`, else first photos from the index). Use `GET /apps/photos/api/v1/albums/<path>` / `…/shared/<path>` (handle both JSON shapes, `photos-server-api.md` §8) or `PROPFIND Depth:1`.
- Respect `.nomedia`/`.noimage` markers (0-byte files) by excluding their folders everywhere.
- "Shared with you" = the same for received shares and group folders.
- Upload into the current folder (§7.17).

### 7.12 Memories and On this day — M4

All computed locally over the whole index (constants in `photos-extended-api.md` memories-trip-titles, timeline-memories-strip):

- **ME-1** **On this day**: photos from ±3 days around today in each of the last 20 years, grouped as "1 year ago", "2 years ago"…; view, widget, and notification (§7.21).
- **ME-2** **Trips**: split by gaps > 2 days, keep clusters ≥ 8 photos, cover = photo nearest the middle time, title = most frequent place (+ second place if ≥ half as frequent, "A & B"), else the date range. Newest first.
- **ME-3** **Year recap**: newest year with ≥ 30 photos, 60 highlights (favourites first, then evenly per month).
- **ME-4** Memory player: full-screen slideshow of a memory with title card; share as quick-share link; "Save as album".
  Decided in round 4: a memory's "More" menu has "Save as album" (an own album named after the memory: trip and recap titles, On this day by its dates; " (2)" when the name is taken; a trip's places as location; only the user's own photos, the others are counted in the confirmation), "Share as link…" (an album with a public link named after the memory, SH-4) and "Slideshow music". Music is optional and off by default; the app ships none (no licensed tracks). The user picks an audio file (copied into the app's storage) or, on iPhone and iPad, a song of the Music library (`MPMediaPickerController`, played through the app's queue of the system player); one choice for all memory slideshows. It fades in, pauses and stops with the slideshow and loops; a speaker button in the slideshow turns it off for that slideshow; files play in the `ambient` audio category (mixes, follows the Ring/Silent switch).

### 7.13 Archive and hidden photos — M4

- Archive = move the file to `/.archive/<original path>` with `Overwrite: F` (create parent folders on 409, retry); unarchive moves it back (strip the prefix). Exactly the web app's convention (`photos-extended-api.md` archive) so web and app agree. Only own files with delete permission can be archived. Works on every server version (pure WebDAV).
- Archived items disappear from timeline, memories, map, search, widgets and Spotlight.
- The **Archive view always requires authentication** (Face ID / Touch ID / Optic ID / device passcode) every time it is opened, independent of the app lock, and re-locks when the app goes to background.

### 7.14 Recently deleted — M5

Requires: `files.undelete`. Lists trashed media (`PROPFIND /remote.php/dav/trashbin/<uid>/trash` with trashbin props; only items with a media MIME type), newest deletion first, with days remaining if the server exposes retention; restore (MOVE to `…/restore/<name>`), delete permanently, empty (confirm). Authentication required to open (like Apple Photos).

### 7.15 Duplicates and Free up space — M5

- **Duplicates**: groups by `size + captureTime + width×height` over the whole index (exact copies; `photos-extended-api.md` duplicates-view). Review UI per group: keep the best (largest/oldest path heuristics, user can change), delete the rest; "Merge favourites/albums" is not possible server-side — warn if the deleted copies are in albums. Decided in round 4: the warning uses the album content in the local index only (albums never opened on the device are reported as not checked, no extra server requests), names the albums the kept copy is not in, and offers to add the kept copy to them before deleting (own files only; albums filled by filters are left out).
- **Free up space**: screenshots, screen recordings, large videos (> 100 MiB) heuristics from the web (patterns in `photos-extended-api.md` free-up-space), sorted by size, bulk delete with total size shown.
- Device storage ("Remove backed-up photos from this device") is part of Backup (§7.18.8), not this screen.

### 7.16 Editing — M5

#### 7.16.1 Photo editor

Core Image pipeline (`PhotosMedia/Editing`), non-destructive while editing, rendered at full resolution on save:
- Crop (free, original, square, 4:3, 16:9, …), rotate 90°, straighten (±45°), flip. Free crop: the crop tool shows the whole picture with a frame (corner and edge handles, drag inside to move); a lock keeps the aspect; presets set the largest centred area of their ratio (in the photo's orientation) and lock it; the crop is stored as fractions of the straightened, turned and mirrored picture and turns/mirrors with it. Flip mirrors left to right as the picture is shown.
- Auto-enhance (`CIImage.autoAdjustmentFilters`).
- Filters (system photo effects: Vivid, Vivid Warm/Cool, Dramatic, Mono, Silvertone, Noir…).
- Adjust: exposure, brilliance/highlights/shadows, contrast, brightness, black point, saturation, vibrance, warmth, tint, sharpness, vignette.
- Before/after, undo/redo, reset.
- Works on the original (download first, show progress). Keep EXIF/GPS/capture date; reset orientation; keep HDR gain map when the format allows, otherwise SDR.

#### 7.16.2 Saving

"Save as copy" (default): writes `<name> (edited).<ext>` next to the original (HEIC if the original was HEIC, else JPEG), so the stacking rule groups it with the original; the copy is added to the same own albums. "Overwrite original": PUT over the original; tell the user that the previous version stays in Nextcloud's file versions (if `files_versions` is enabled). Not available for files without write permission. The original keeps its format and name (only formats Image I/O can write: JPEG, HEIC/HEIF, PNG, TIFF; others can only be saved as a copy), and the PUT carries `If-Match` with the ETag the app edited, so a newer version on the server is never replaced.

#### 7.16.3 Metadata editing

Requires: `metadataEdit` (Nextcloud ≥ 35). Capture date & time and location for one or many photos: modes keep / shift by ±days/hours/minutes (keeps intervals) / set absolute; location via map/search picker or remove. PROPPATCH per file (concurrency 4), per-file error report (`photos-server-api.md` §11). On older servers the menu item explains it needs a newer server.

### 7.17 Manual upload — M2

- Sources: Photos picker (`PhotosPicker`, multi-select, videos), Files/Finder document picker, drag & drop onto the window/an album/a folder, the share extension, camera capture (iOS: "Take photo" straight to Nextcloud).
- Destination: the Photos upload folder `photosLocation` (default `/Photos`, created if missing; warn if it is a received share), or the current folder in Folders, plus optional album.
- Upload **originals** with their resources (HEIC/ProRAW/HEVC, Live Photo pairs), set `X-OC-MTime` and `X-OC-CTime` to the capture time, link Live Photo parts (PROPPATCH `nc:metadata-files-live-photo` on both, after both uploads have file ids), and — where `metadataEdit` is available and the server did not extract a capture time/GPS (check after upload) — PROPPATCH them from the PhotoKit asset.
- Chunked upload (v2, own `Uploader`) above 10 MB; parallelism from capability `files.chunked_upload.max_parallel_count`; `X-NC-WebDAV-Auto-Mkcol: 1` for missing parents.
- Name collisions: append " (2)", " (3)" (never overwrite on manual upload).
- Progress in the toolbar and in a transfers view; uploads continue in a background `URLSession`.

### 7.18 Backup (automatic camera-roll upload) — M3

Optional; off by default; on iOS, iPadOS and macOS (PhotoKit library); not on visionOS.

#### 7.18.1 Setup flow

1. Explain what backup does; request PhotoKit access (full recommended; limited works for the selected photos only).
2. Ask: **"Do you already back up photos with the Nextcloud Files app?"** (pre-answered "Yes" if the Files app's accounts list or settings show it is installed and configured for this account):
   - **No** → Photos backup with Photos' defaults.
   - **Yes, switch to Nextcloud Photos** → Photos imports what Files already uploaded (§7.18.5), adopts Files' folder and naming so nothing is uploaded twice, and tells the user to turn off auto upload in Files (deep link `nextcloud://` if possible).
   - **Yes, keep using Files** → Photos backup stays off; the Backup screen shows a read-only **backup status** (which device photos are already on the server, via reconciliation §7.18.4), so the user still sees what is missing.
3. Choose account, folder, options; then a first reconciliation pass runs before any upload, showing "X photos are already on your server, Y will be uploaded".

On iPhone and iPad this flow is offered once, as a full-screen step right after the first login and before the notification permission is asked ("Back up the photos of this iPhone?" · Start backup / Not now). The Files question is only part of it when the Files app is installed or has left data in its App Group. On the Mac, backup is set up in Settings › Backup with the same step; there is no offer after the login. The destination folder is chosen from the server's folders and must be one the timeline shows (`photosSourceFolders` or below); otherwise the app offers to add it to the timeline folders, and warns about an earlier folder outside them.

#### 7.18.2 Options

| Option | Default |
|---|---|
| Account | active account |
| Destination folder | `photosLocation` (default `/Photos`), or Files' folder in "switch" mode |
| Subfolders | Year/Month (`yyyy/MM`); options: none, year, year/month, year/month/day (by capture date, local time) |
| File names | **Original names** (`IMG_1234.HEIC`); option "Like Nextcloud Files" (`yy-MM-dd HH-mm-ss NNNN.ext`, optional "Photo "/"Video " prefix, or Files' custom mask — `reference/nextcloud-ios-and-nextcloudkit.md` §4.2) |
| Formats | **Originals** (HEIC, HEVC, ProRAW DNG); option "Most compatible" (JPEG/H.264): HEIC/HEIF photos become JPEG, HEVC videos (also Live Photo motion parts) H.264 in a QuickTime file (`.mov`, what the camera's own "Most Compatible" records), metadata kept; RAW and what already is JPEG/H.264 stay as they are; a video that cannot be converted is uploaded as it is. The conversion happens next to the export and is removed with it. |
| Edited photos | Original + edited version (edited uploaded as Apple's `IMG_E1234.*` resource name, stacked by the server/app); options: edited only, original only |
| Live Photos | Upload the motion part and link it |
| What | Photos and videos; option per type; whole library or "from date"; all photos or selected device albums; include shared-library photos (on) |
| Network | Wi-Fi only for videos (default), Wi-Fi only for all (off), allow on Low Data Mode (off) |
| Power | Upload in background also on battery (on); pause on Low Power Mode (on) |
| iCloud | Download originals from iCloud when "Optimize Storage" is on (on; Wi-Fi only) |

Deleting a photo on the device never deletes it on the server (backup is additive).

#### 7.18.3 Ledger

`backupAsset(localIdentifier, resourceKind (photo/video/pairedVideo/edited/raw), fingerprint, state, serverPath, serverFileId, serverEtag, matchedBy, attempts, lastError, assetModificationDate)`. States: `pending → reconciling → matched | queued → uploading → uploaded | failed | skipped`. `matchedBy` ∈ `ownUpload | filesLedger | serverHash | serverTimeSize | serverTimeName | user`. A PhotoKit change observer (`PHPhotoLibraryChangeObserver` + persistent change tokens `PHPersistentChangeToken`) finds new and modified assets incrementally.

Incremental passes (a library of 150 000 photos with 40 000 to upload must not spend a background wake on rereading it):
- A pass looks only at the assets the persistent change history names since the token taken before the last scan. The whole library is looked at when there is no usable token (none yet, expired history, too many changes, a change of an album the backup is limited to), when the selection (photos/videos, from date, hidden, albums, limited access) or the resource options change, when the user asks ("Back up now", "Try again"), and once a day — then after the pass has uploaded what it already knew of.
- Of the assets looked at, only those the ledger does not know completely are read (`PHAssetResource` is the expensive part).
- A resource that is not on the server keeps its description in the ledger (`resource`, JSON) and when the server was last asked about it (`checkedAt`). Later passes upload it from the ledger without reading the library, and without asking the server again for 7 days (layer 5 still checks the destination before each upload); the asset changing, or the user's "Back up now", asks again.
- The server is asked a batch (≤ 200 resources) at a time, and what that batch did not find is uploaded before the next batch is asked, so uploads start after one request and an interrupted pass goes on where it stopped. Files larger than the system's background uploads take stay at the end of the pass.

#### 7.18.4 Duplicate protection (the core requirement)

An asset is uploaded only if **none** of these layers finds it already on the server:

1. **Own ledger** — uploaded or matched before (by `localIdentifier` + resource kind). Modified assets (new edit) only upload the new edited resource (overwriting the previous edited file).
2. **Files app ledger** (if the Files app is installed by the same team, §7.18.5) — Files has uploaded this `localIdentifier`.
3. **Server hash** — if the server offers content hashes (companion §S3): SHA-256 of the resource bytes looked up in one batch request. Photos always sends `OC-Checksum: SHA256:<hex>` on its own uploads so these files are hash-findable later.
4. **Server reconciliation by time** — always available: for a batch of up to 200 assets, one SEARCH over the **whole user home** (`/files/<uid>`, depth infinity, media MIME types) for files whose `nc:metadata-photos-original_date_time` **or** `d:getlastmodified` lies within the batch's time span ± 2 s, selecting `oc:fileid`, path, `oc:size`, `nc:metadata-photos-size`, both times. Then match locally:

| Match | Rule | Result |
|---|---|---|
| Exact | same kind, capture second equal (either time field, ±1 s), **same byte size** as the resource that would be uploaded | skip, `serverTimeSize` |
| Probable | same kind, capture second equal, and the 4-digit number of the original file name (`IMG_1234` → 1234) appears in the server name (Files' default naming keeps it) | skip, `serverTimeName` |
| Probable (converted) | same kind, capture second equal, same pixel dimensions (orientation-aware), exactly one candidate on each side (protects bursts, which share seconds) | skip, `serverTimeSize` |
| Shifted EXIF time | as "Probable" but times differ by a whole number of hours (≤ 14 h) and minutes/seconds equal — EXIF local time read without offset by older servers | skip only if the name number also matches |
| Otherwise | — | upload |

5. **Destination check** — before each PUT, `PROPFIND` the destination; if a file with that name exists: same size → mark matched; different → upload as `name (2).ext` (never overwrite in backup). For a resource that may be converted ("Most compatible") a file of that name whose modification time is the capture time (± 1 s, the upload sets `X-OC-MTime`) is also this file: a conversion does not give the same bytes each time.

*Converted files (decision, round 4):* the ledger (layer 1) records the upload per asset and resource whatever format was uploaded. On the server a converted copy has the original's name with another extension and the capture time, but not the original's size, so layer 4 finds it by capture second and name number ("Probable") or pixel size ("Probable (converted)"), and layer 5 by name and capture time. "Free up space" (§7.18.8) never counts a converted copy.

The reconciliation result is shown to the user in the first run and is reviewable ("Already on server: 4 210 · will upload: 312 · see details"). Users can force-upload an individual skipped item from the details list.

#### 7.18.5 Coexistence with the Nextcloud Files app

Same Apple team (`NKUJUXUJ3B`) → the Photos app can join the Files app's App Groups. Read-only, defensive, optional (every read is wrapped; failure just means "no Files data"):

- `group.com.nextcloud.apps/…/NextcloudAccounts/accounts.json`: which accounts Files has (server, user).
- `group.it.twsweb.Crypto-Cloud` UserDefaults (`Preferences_*`): Files' naming options (`fileNameOriginal`, `fileNameType`, `fileNameMask`), `formatCompatibility` (JPEG conversion), `livePhoto`, `AlbumIds_<account>`. Used to mirror Files' scheme in "switch" mode.
- `group.it.twsweb.Crypto-Cloud/Library/Application Support/Nextcloud/nextcloud.sqlite` (GRDB, WAL), opened **read-only** (`SQLITE_OPEN_READONLY`, no migrations): tables `photoLibraryAsset` and `autoUploadResource` → set of `localIdentifier`s Files uploaded.
- **Never open Files' Realm database** (`nextcloud.realm`): opening it with a different model can corrupt it. Its older upload history is covered by the server reconciliation (layer 4), and Files' auto-upload folder/subfolder settings are asked from the user.
- If both apps keep auto-uploading, layer 4 + 5 prevent duplicates from the Photos side; and when Photos uses "Like Nextcloud Files" naming in the same folder and format, Files' own name-exists check skips what Photos uploaded. Recommend in the UI to use only one.

If the identifiers from §4.2 change or Apple rejects the extra App Groups, drop layer 2; layers 3–5 still guarantee no duplicates for the common cases.

#### 7.18.6 Background execution

- Primary: the **PhotoKit background-upload extension** (iOS/iPadOS 27, extension point `com.apple.photos.background-upload`, `PHBackgroundResourceUploadJobExtension`; the Files app's implementation is a reference: `nextcloud-ios-and-nextcloudkit.md` §4.5). The app creates upload jobs only **after** reconciliation, one per resource, with the destination `PUT` request (headers: auth, user agent, `X-OC-MTime`, `X-OC-CTime`, `OC-Checksum`, `X-NC-WebDAV-Auto-Mkcol: 1`). Success = response has `OC-FileId`. Resources > 100 MB are handed back to the app for chunked upload. Check whether the extension point exists on macOS 27; if not, macOS uses the next mechanism.

  *Implementation (round 4):* `Extensions/BackgroundUpload` (ExtensionKit, `EXExtensionPointIdentifier` `com.apple.photos.background-upload`), on iOS/iPadOS **and macOS**: the macOS 27 SDK has the API and macOS 27.3 defines the extension point (`/System/Library/ExtensionKit/ExtensionPoints/com.apple.photos.background-upload.appexpt`: platforms iOS and macOS, `EXRequiredEntitlements` `com.apple.photos.background-upload`). Not on visionOS (no API). The app turns it on with `PHPhotoLibrary.enableUploadJobExtension(with:)` while backup is on with **full** library access (PhotoKit requires it) and the App Group is there, off otherwise; "Wi-Fi only" is `PHAssetResourceUploadJobOptions.preventsExpensiveNetworkAccess`, videos with "Wi-Fi only for videos" and Low Data Mode go per request. Each run (`processJobs`) opens the backup account from the shared container and: records the jobs that ended (file id from `responseHeaderFields`, else the destination with the resource's size; a failed job is retried once under a freshly looked-up name; then it is a failure like any other), acknowledges them, then scans and reconciles exactly like a pass of the app (ledger, Files app, server search) and creates jobs for what is not on the server, oldest first, up to `min(jobLimit, 20)`. Decisions: PhotoKit sends the resource's bytes as they are, so it takes only resources ≤ 100 MB of known size that are not converted ("Most compatible" photos and videos, everything > 100 MB and of unknown size stay with the app); **no `OC-Checksum`** on its jobs (the bytes are not read here; layers 1, 4 and 5 do not need it); PhotoKit downloads from iCloud by itself, so with "Download originals from iCloud" off it creates no jobs; in Low Power Mode (with "pause") none either. The app and PhotoKit never take the same resource: the extension records a job (`<account>/UploadJobs.json`) before creating it and skips what the app's session has; the app skips the resources of that record and keeps their names free; every PUT has `If-None-Match: *`. Unverified: a real device (the entitlement has to be provisioned).
- Files larger than 100 MB go in chunks (chunking v2) through the app's background `URLSession`: the app prepares the upload (name, upload folder — the same one an upload by the app itself would use, so either continues the other), moves the export into its container and hands 8 chunk `PUT`s at a time to the system, each from a file of its own; every report (also to a later launch) hands over the next ones, the final `MOVE` (empty body, `Overwrite: F`) too. One such file at a time. A lost answer to the `MOVE` is settled by looking at the destination. The user's pause takes the chunks back, the next pass sends only what the server does not have; turning backup off removes what waits.
- Fallback / complement: background `URLSession` upload tasks, `BGProcessingTask` (`com.nextcloud.photos.processing`, requires network, prefers power) for reconciliation, hashing, Live Photo linking and metadata fix-ups, and `BGAppRefreshTask` for scanning new assets. No location-change or audio tricks.
- A backup the user starts (the first one, or "Back up now" with many items waiting) runs as a `BGContinuedProcessingTask` on iOS/iPadOS: it shows system progress and goes on when the user leaves the app. Option "Keep screen on while backing up": the idle timer is off only while a pass runs and the app is in front.
- After uploads: link Live Photo parts, PROPPATCH missing capture date/GPS where possible (`metadataEdit`), add to the local index immediately (the file appears in the timeline before the next sync).

#### 7.18.7 Backup UI

Backup status row (sidebar/Collections) and screen: state (Up to date / Uploading 12 of 340 / Paused: waiting for Wi-Fi / Paused: Low Power / Error), progress, current item thumbnail, per-asset status in the device-library view ("Backed up", "Already on server (matched)", "Waiting", "Failed: reason"), pause/resume, "Back up now". Grid badge for device photos not yet backed up is not needed (the timeline shows server content); instead the Backup screen lists them ("Not backed up yet", local thumbnails, with failed / only-in-iCloud marks).

#### 7.18.8 Free up device space (M5)

"Remove backed-up photos from this device": only assets whose every resource is `uploaded` or `matched` with a verified server file (re-check existence and size right before: the server lists the file with exactly the device's size, and the same file id when known; converted or name-only matches never qualify; RAW, edited version and Live Photo motion are required), deletion via `PHAssetChangeRequest.deleteAssets` (system confirmation), never for assets newer than 30 days unless the user chooses.

#### 7.18.9 Mirror device albums (iOS, iPadOS)

Opt-in, for the albums the user picks (Backup › Albums): after each pass, backed-up photos (ledger `uploaded`/`matched`) of a picked device album are added to the Nextcloud album of the same name (created when missing; `/` becomes `-`). The edited rendition is preferred. Only adds: a photo taken out of the device album, or removed from the Nextcloud album, is not touched again (what was added is remembered per album).

#### 7.18.10 Import from Google Takeout (Mac)

File › Import from Google Takeout…: pick the unpacked export, its ZIP parts (read in place, ZIP64, no unpacking) or a folder holding them. JSON sidecars are matched with the server's rules (`TakeoutSidecarService`: truncated names, `(1)` copies, `supplemental-metadata`, edited copies and Live Photo videos); `photoTakenTime` is sent as `X-OC-MTime`, the file itself is uploaded unchanged (EXIF stays), the position is set by PROPPATCH where the file has none (Nextcloud 35+), captions become file comments. Files already on the server are skipped with the backup matcher (§7.18.4); copies in album folders are imported once; album folders become Photos albums; the trash folder is left out. Destination: a folder below a timeline folder (default `<upload folder>/Google Photos/<year>`). Resumable through a journal per export in the account's directory; progress, stop and resume.

### 7.19 Offline — M2

- The whole metadata index and its collections are always available offline (read-only browsing; writes queue in the outbox).
- Thumbnails: whatever is in the preview cache.
- **Offline albums/photos**: "Make available offline" on an album, a person, a place, a smart album or a selection. Downloads originals (setting: originals vs. large previews 4096) into the app container; keeps the album in sync (new photos downloaded, removed ones deleted) on Wi-Fi; badge on tiles and albums.
- Settings → Storage: preview cache size and limit, offline items with size, "Remove all offline files", "Clear cache".

### 7.20 Smart features — M4/M5

| Feature | Source | Fallback / on-device extra |
|---|---|---|
| Faces / People | Recognize (server) | none (no on-device clustering in v1) |
| Object/scene tags | Recognize system tags (server) | — |
| AI captions | `nc:metadata-photos-caption` (server, extended) — shown in info, used as **VoiceOver label** and in search | — |
| Extract text | TaskProcessing `core:image2text:ocr` (server) | **On-device Vision** `RecognizeTextRequest` when the server has no OCR provider; Live Text in the viewer always |
| Ask your photos | TaskProcessing `core:text2text` | On-device Foundation Models (§SR-4) |
| Visual Look Up | — | VisionKit on device |

Server tasks are polled every 2 s with the web app's time-outs and can be cancelled.

### 7.21 Notifications — M4

- Register for push per account via the Nextcloud push proxy (`nextcloud-ios-and-nextcloudkit.md` §5): RSA-2048 key pair in the keychain, `POST /ocs/v2.php/apps/notifications/api/v2/push` (`pushTokenHash` = SHA-512 of the APNs token, `devicePublicKey`, `proxyServer`), then `POST <proxy>/devices`. Unregister on logout.
- Notification Service Extension decrypts the payload (RSA OAEP, PKCS#1 fallback) with the account's private key (Security framework, no OpenSSL), fetches the full notification and shows it.
- **Only Photos-relevant notifications may appear** in this app: `app == "photos"` (On this day, and companion notifications for album shares, new photos in shared albums, comments — §S5). Today the notifications app derives the device's app type from the user agent and sends every non-Talk notification (and Talk ones as fallback) to unknown clients like this one. Preferred: the notifications app recognises the Photos user agent and only pushes `photos` notifications to it (`SERVER-COMPANION.md` §S5/§14); fallback: the `com.apple.developer.usernotifications.filtering` entitlement to drop others in the extension.
- Tapping a notification opens the matching view (On this day for `object_type == "onthisday"` with the day from `object_id`; album for album notifications).
- In-app notification list is not required; Settings → Notifications has toggles: On this day (writes server config `onThisDayNotifications` when supported), shared albums, comments.

### 7.22 Widgets — M4

WidgetKit on iOS (home and lock screen), iPadOS, macOS (desktop/notification centre), visionOS:
- **On this day** (small/medium/large): a photo from N years ago with "3 years ago"; rotates through the day's memories.
- **Featured photos / Album** (configurable with App Intents: choose album, person, place or favourites): rotating photo.
- **Memories**: latest trip card.
- **Backup status** (small, accessory): progress/up to date.

Widgets read the account store (read-only) and the preview cache from the App Group; they may fetch a missing 1024 preview within WidgetKit's time budget. Never show archived photos. Tapping deep-links into the app.

### 7.23 App Intents, Siri, Shortcuts, Spotlight — M5

- **Entities**: `PhotoEntity`, `AlbumEntity`, `PersonEntity`, `PlaceEntity`, `TagEntity` (indexed entities for Spotlight).
- **Intents**: Search photos (place, person, date range, tag, favourites), Open album/person/place, Show On this day, Start slideshow (of album/memory), Add photos to album, Upload photos/files (accepts images from Shortcuts) to the upload folder or an album, Create album, Toggle backup / Back up now, Share album link.
- **App Shortcuts** with Siri phrases ("Show my photos from Paris in Nextcloud Photos", "On this day in Nextcloud Photos").
- **Spotlight**: index albums, people, places and smart albums (not every photo in v1; optional setting to index captions later). Archived content is never indexed. *Decided (round 4):* one Core Spotlight domain per account, removed on logout and remote wipe; nothing is indexed while app lock is on; people hidden on the device and unnamed people are not indexed; a place only while a non-archived photo has it; no thumbnails. Smart albums are not indexed yet.

### 7.24 Share extension, drag & drop, export — M2

- **Share extension** (iOS, macOS): receive images/videos (and Live Photos) from any app → choose account, upload folder (default `photosLocation`), optional own album (create new allowed) → upload in a background session; shows progress and completion.

  *Implementation (round 4):* each share gets a background `URLSession` of its own (`share-upload.<uuid>`, with the App Group as shared container); the copies of the shared files move into the App Group container (`ShareUploads/<session>/`), files up to 100 MB are one PUT, larger ones go in chunks (as backup, §7.18.6). "Continue in Background" closes the sheet while the system goes on. When the extension has ended, the system launches the app for the session's events (iOS) and the app takes the share over from its record (album, chunks, lost requests); at launch the app also continues shares whose extension stopped renewing its claim (45 s), e.g. on the Mac. What still fails is told in a local notification (when notifications are allowed); the files are removed when the share is through.
- **Drag & drop** (iPad, Mac, visionOS): drag photos out of the grid/viewer (file promises — originals download lazily), drop into albums/folders/sidebar albums (upload and/or add), drag between albums (add), reorder is not supported by the server.
- **Export / Save to device Photos library** with add-only permission; keeps capture date and location (create the asset from the original file, Live Photo with both resources).

### 7.25 Settings — M1 (grows per milestone)

- **Library (server, synced with the web app)**: Timeline folders (`photosSourceFolders`), Upload folder (`photosLocation`), Square tiles (`croppedLayout`; *decided, round 4: a setting of this device, see §6.4*), Grid size (`gridDensity`, Nextcloud ≥ 35), Album sort orders (extended), On this day notifications (extended). Written with `PUT /index.php/apps/photos/api/v1/config/<key>` body `{"value":"<string>"}` and `OCS-APIRequest: true`; read via §5.3 step 2.
- **App**: stack similar photos, show RAW files, play Live Photos in the grid, load originals automatically (Wi-Fi/always/never), accent colour from server theme, app lock (+ timeout: immediately, 1, 5, 15 min), Backup (§7.18), Notifications, Storage (§7.19), Accounts, Advanced (logging, re-index library, server features list for support), About (version, licences of dependencies, source code link, privacy).

---

## 8. Security and privacy

- Credentials only in the keychain (own access group); per-account keys for push in the keychain; never in logs, never in the database, never in App Group UserDefaults.
- TLS everywhere; ATS exceptions only for user-approved http/self-signed hosts. *Implementation:* the exception is app-wide (`NSAllowsArbitraryLoads`), because the hosts are typed in by the user and unknown at build time; the app asks before it uses http or trusts an unknown certificate (see [PRIVACY-AND-EXPORT.md](PRIVACY-AND-EXPORT.md)).
- App lock with LocalAuthentication (`deviceOwnerAuthentication`, so passcode fallback works); privacy cover in the app switcher when locked or while viewing the Archive; widgets and notifications never show archived content; optional "Hide photo content in notifications". *Implementation:* while locked nothing of the account is shown in any window (also the Mac Settings window and the share extension), the cover on iPhone/iPad is a window above presentations, links from outside wait for the unlock, and widgets show a placeholder while app lock is on and redact their content on a locked device.
- A changed server certificate is never accepted in two taps: the dialog compares old and new fingerprints; only a certificate that replaces one the user trusted before can be accepted in place (with an explicit confirmation); a server the system trusted needs a new login. Nothing is sent over the new certificate before.
- Login links and QR codes show the server and user before logging in; the Login Flow stays on https when the user typed https, and a granted app password is revoked when the app refuses the server afterwards.
- Keychain items are `…ThisDeviceOnly`; copied share links are local-only (no Universal Clipboard) and expire after 10 minutes on iOS.
- Remote wipe and app-password revocation (§5.1).
- Data protection class `completeUntilFirstUserAuthentication` for databases and caches (background uploads need it); offline originals the same.
- Privacy manifest (`PrivacyInfo.xcprivacy`, one per app/extension bundle and per package target that needs one) declaring required-reason APIs; no tracking, no analytics, no third-party SDKs that phone home.
- Public album access sends no account credentials.
- The initial-state scraper only reads `initial-state-photos-*` inputs and discards the rest of the page.

## 9. Accessibility and localisation

- VoiceOver: every tile has a label (AI caption if available, else "Photo, <date>, <place>"), custom rotor actions (favourite, select, open), grid navigation by month headers; viewer announces position "3 of 120".
- Dynamic Type everywhere except inside the photo grid tiles; Reduce Motion replaces zoom transitions with crossfades and disables Ken Burns; Increase Contrast; full keyboard access on iPad/Mac; Voice Control labels; visionOS gaze/pinch targets ≥ 60 pt.
- Localisation: String Catalogs (`.xcstrings`), English source strings, translations via Nextcloud's Transifex workflow like the other Nextcloud apps; plural rules; RTL layouts; dates and numbers with `FormatStyle`; country names from `Locale`.

## 10. Performance budgets

Measured on iPhone 15 / M1 iPad Air / M1 MacBook Air, 100 000-item library:

| Metric | Budget |
|---|---|
| Cold launch → cached timeline visible | < 1.0 s |
| Timeline scroll | no hitches at 120 Hz (Instruments hitch rate < 1 ms/s), during fast scrubbing tiles show blurhash then preview |
| Tap → viewer shows 1024 preview (cached) | < 150 ms; uncached on Wi-Fi < 600 ms |
| Initial index of 100 000 items on Wi-Fi | first screen < 3 s, complete < 10 min, app usable throughout |
| Incremental sync with no changes | 1 request per source root, < 500 ms |
| Memory while scrolling | < 300 MB (iPhone) |
| Local search/filter over 100 000 items | < 100 ms |
| Map with 50 000 geotagged photos | clustering < 200 ms per region change |

Add XCTest performance tests for the store queries and domain algorithms with a synthetic 100k index.

## 11. Testing

### 11.1 Automated

- **Unit tests** for every package. `PhotosDomain` gets **parity tests** that port the web app's spec cases (e.g. `src/services/memories.spec.ts`, burst/stack/day-grouping/duplicates/cleanup/search-suggestion tests in `src/**/*.spec.ts` of the Photos integration branch) so the same input gives the same groups as the web app.
- **XML tests**: request builders compared against golden bodies from the reference docs; parsers tested with captured responses (fixtures under `Tests/<target>/Fixtures/<server>/`).
- **Integration tests** (opt-in through the `PHOTOS_IT_*` environment variables, see [TESTING.md](TESTING.md); never commit credentials):
  - **Upstream master server** — a local server-core checkout with Photos master, a release archive (`scripts/test-server.sh`) or a Docker `nextcloud` image — to verify all fallbacks (no capability, no extended props).
  - **Nextcloud 33 container** (`nextcloud:33`) for the oldest supported version: login, timeline, albums, sharing, places, upload, initial-state scraping.
  - **The extended test server** (Nextcloud 36-dev with the Photos integration branch = all extended features; a test library of Wikimedia Commons photos with EXIF). It has no Recognize and no Assistant/TaskProcessing provider; test People and AI features on a server that has them.
- **UI tests** (XCUITest, target `NextcloudPhotosUITests`; today three smoke tests: launch, viewer, Albums — see [TESTING.md](TESTING.md)) on iPhone, iPad and Mac. Target: login (with a stub server), timeline scroll & open viewer, create album and add photos, share link, backup first run with a seeded simulator photo library (`xcrun simctl addmedia`), offline mode (network link conditioner / airplane), app lock.
- **Backup dedup tests**: fixtures with burst sequences, Files-style names, JPEG-converted copies, shifted EXIF times; assert no duplicate uploads and no missed uploads.

- **Debug login:** Debug builds sign in without a browser when launched with `PHOTOS_DEBUG_LOGIN='nc://login/server:<url>&user:<user>&password:<app password>'` (used for screenshots and UI tests).

### 11.2 Manual test plan

[test-plan.md](test-plan.md): a checklist for devices covering all platforms, light/dark, VoiceOver, large libraries, slow network, server in maintenance, expired app password, remote wipe.

## 12. Engineering conventions

- Repo **https://github.com/nextcloud/photos-ios** (exists, public, default branch `main`, contains only the MIT `LICENSE` as of 2026-11-22). The copy of this spec in the repo (`docs/SPEC.md`) is the one to update.
- Work in small PRs (one feature or fix each), stacked when they depend on each other; conventional commit subjects (`feat(timeline): …`, `fix(backup): …`); DCO sign-off (`Signed-off-by`); SPDX header in every source file (`SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors`, `SPDX-License-Identifier: MIT`).
- Deliver all work as PRs against `main`; never push to `main` directly.
- CI (GitHub Actions on macOS runners): build all four platforms, unit tests, `swift-format lint --strict`, REUSE lint, string catalog checks; integration tests nightly against a Nextcloud installed on the runner (macOS runners have no Docker).
- Server-side work for `SERVER-COMPANION.md` happens in the Photos server repo following its `AGENTS.md` (one small branch per item; a maintainer opens the PRs).
- The Photos DAV helpers live in this app; offering them upstream as a `NextcloudKit+Photos.swift` is optional and decided later (it would not add a dependency here).

## 13. Milestones

Each milestone ends with: all its requirements implemented on all four platforms (unless marked), tests green, manual test plan done on the extended test server + NC 33, a TestFlight build, and a short demo note with screenshots per platform.

### M0 — Foundation
Repo, project, packages, CI, lint, REUSE, licence files; design tokens; Brand; login (Login Flow v2, QR, self-signed trust, client certificates), accounts (add/switch/remove with revocation, wipe), user agent, MDM keys; feature detection incl. initial-state scraper; networking layer with DAV builders/parsers; store schema & migrations; logging; empty app shell with platform navigation (tabs/sidebar), Settings skeleton.
**Accept:** log in to the extended test server, NC 33 and a self-signed server on iPhone, iPad, Mac, Vision Pro simulator; Settings → Advanced shows the detected server features correctly for each server.

### M1 — Browse and view
Local index (initial + incremental sync + reconciliation), timeline TL-1–TL-7 (stacks may land late in M1), grid with sections, scrubber, zoom, selection, previews & caches, viewer VW-1–VW-6 (Live Text in M5), Live Photos, video, info panel (without people/caption), favourite, delete, export/share, basic filter bar (date/place), Settings library section.
**Accept:** 100k synthetic-index performance tests pass; the test library is browsable offline after the first sync; favourites/deletes made offline sync later.

### M2 — Albums, sharing, upload, offline
Albums AL-1–AL-8, sharing SH-1–SH-6, manual upload §7.17, share extension, drag & drop, export to device library, offline albums §7.19.
**Accept:** create an album on iPhone, see it in the web app, share to a second user and by public link, open the public link in the app without an account; album offline in airplane mode.

### M3 — Backup
§7.18 complete (setup, options, ledger, all dedup layers, Files coexistence, PhotoKit background upload extension + fallbacks, UI).
**Accept:** on a device whose library was partly uploaded by the Files app (JPEG-converted, Files naming) the first run uploads **zero duplicates** and **all missing** photos; Live Photos play in the web app; backup continues with the app in background for ≥ 1 h.

### M4 — Discover
Places & map, people, tags, folders & shared with you, memories & On this day, search & filters & smart albums, archive & app lock, push notifications, widgets.
**Accept:** feature parity with the web app on the extended test server for all these views (side-by-side checklist), graceful hiding on NC 33.

### M5 — Advanced and polish
Editing (§7.16), metadata editing, recently deleted, duplicates, free up space, free up device space, ask your photos, extract text / Live Text / Visual Look Up, captions in UI, video renditions, App Intents/Siri/Spotlight, visionOS spatial/immersive extras, accessibility & localisation audit, App Store assets and review notes.
**Accept:** full parity matrix (Appendix A) green; accessibility audit has no blockers; App Store submission ready.

## 15. M6 — Delight

Round 5 (2026-11-24): features that go beyond the other photo apps. No server changes; everything uses stock
Nextcloud/Photos APIs and on-device frameworks. Each subsection is owned by one work package (name in brackets).

### 15.1 Memory films and Year in Review [memories]

_To be written._

### 15.2 Photographer's Mac: import, culling, compare, external editors [macpro]

_To be written._

### 15.3 New platforms: Apple TV and Apple Watch [tvwatch]

_To be written._

### 15.4 Ambient: wallpaper, StandBy, Live Activity, Controls, Vision Pro memory room [ambient]

_To be written._

### 15.5 Feel and craft: zoom levels, haptics, no spinners, similar photos [feel]

_To be written._

### 15.6 Then and now, travel globe [places]

_To be written._

### 15.7 Bring everything home: imports [import]

_To be written._

### 15.8 Smart offline and fun extras: stickers, collages, photo of the day [extras]

_To be written._

## 14. Prerequisites and open items (need Nextcloud GmbH)

1. ~~Create the GitHub repo~~ (done: https://github.com/nextcloud/photos-ios) and ~~confirm the bundle id~~ (done: `com.nextcloud.photos`). Still open: App Group and keychain group names (§4.2) and the App Store record/name "Nextcloud Photos".
2. Provisioning profiles for the app, extensions and the two Files App Groups under team NKUJUXUJ3B.
3. **Push proxy**: `push-notifications.nextcloud.com` must know the new app's APNs topic (bundle id) — needed before M4 push works.
4. **Notification filtering**: either the notifications app supports an app type for this client (only `photos` notifications) or request Apple's notification filtering entitlement.
5. App icon and App Store artwork (trademarked Nextcloud assets).
6. A test server with Recognize and an Assistant/TaskProcessing provider (the current test servers have neither).
7. Decide which companion server APIs (`SERVER-COMPANION.md`) to build and when; S1 (capability + config read) and S4 (Recognize key) have the highest value per effort.

---

## Appendix A — Web parity matrix

| Web app feature (route) | App | Requires | Milestone |
|---|---|---|---|
| All media `/` , Photos `/photos`, Videos `/videos` | Library timeline | core | M1 |
| Favorites `/favorites` | Library filter / Collections | core | M1 |
| On this day `/thisday` + dashboard widget | On this day view, widget, notification | core (+ ext. notification) | M4 |
| Memories `/memories` (trips, year recap) | Memories | core (local) | M4 |
| Map `/map` (+ clustering, area search, time slider) | Map | core (local GPS) | M4 |
| Albums `/albums`, album content | Albums | photosDAV | M2 |
| Album cover, description, sort order, comments | Albums | ext. | M2 |
| Shared albums `/sharedalbums` | Shared albums | photosDAV | M2 |
| Public album `/public/<token>` (+ slideshow) | Public album viewer | photosDAV | M2 |
| Quick share selection | Quick share | photosDAV | M2 |
| Places `/places` (+ by country) | Places | places (+ ext.) | M4 |
| Faces `/faces`, unassigned faces, people in photo | People, info panel | Recognize + key | M4 |
| Tags `/tags`, filter by tag | Tags, filters | systemtags | M4 |
| Folders `/folders`, Shared `/shared` (+ mosaics) | Folders, Shared with you | core (+ ext.) | M4 |
| Timeline filters (date, place, name, tags), unified search, smart albums | Search & filters, smart albums | core (+ ext.) | M4 |
| Ask your photos | Ask your photos | TaskProcessing or on-device | M5 |
| Archive, Recently deleted, Duplicates, Free up space | Same | WebDAV / trashbin | M4/M5 |
| Edit date & location (single, bulk) | Metadata edit | NC ≥ 35 | M5 |
| Extract text | Extract text + Live Text | TaskProcessing or on-device | M5 |
| AI captions | Info, VoiceOver, search | ext. | M5 |
| Live photo playback, video compat | Live Photos, video renditions | core / ext. | M1/M5 |
| Day headers, scrubber with years, full-library scrubber, stacks, bursts | Grid | core (local) | M1 |
| Upload (picker, folders) | Upload, share extension, drag & drop | core | M2 |
| Viewer info sidebar, metadata dialog | Info panel | core | M1 |
| Settings (source folders, upload location, cropped layout, grid density) | Settings → Library | core | M1 |
| Download selection (zip) | Export / save to device | core | M1 |
| Keyboard navigation, range/drag selection, select all | Grid selection | — | M1 |
| — (native only) | Backup, offline albums, editing, widgets, App Intents, Spotlight, Live Text, app lock, push | — | M2–M5 |
