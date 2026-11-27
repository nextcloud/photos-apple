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
| Identity | Official **Nextcloud Photos** app by Nextcloud GmbH, Nextcloud branding, published under Nextcloud's Apple team (`NKUJUXUJ3B`). Repo **github.com/nextcloud/photos-apple** (named photos-ios until 2026-11-27: the app is for every Apple platform). |
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
| On-device AI | **Only what Apple's frameworks provide** (Vision, VisionKit, Core Image, Natural Language, Foundation Models / Apple Intelligence). The app never ships, downloads or runs machine-learning models of its own (*decision 2026-11-27 by the owner*; see §21). |
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
photos-apple/
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

Triggered at launch, on foreground, pull-to-refresh, every 5 min while the app is open and visible (on the Mac: while a window of it is on screen, also behind another app), after the app's own uploads, by push notifications, and in `BGAppRefreshTask`.

1. **Companion change feed** (`SERVER-COMPANION.md` §S2) if available: apply added/changed/removed since the stored `syncToken`. Done.
2. Otherwise:
   1. `PROPFIND Depth:0` on each source root for `d:getetag` (it changes when files below are added, changed, moved or deleted — but **not** when a favourite is set or the server fills in place/caption). Read it once, before anything is fetched, and store that value only after the sync is through, so a change made while syncing is seen by the next sync. Unchanged → only the favourites check: one SEARCH for the file ids with `oc:favorite = 1`, compared with the store.
   2. Changed → SEARCH for items with `d:getlastmodified > lastDeltaSync − 10 min` **or** `nc:upload_time > lastDeltaSync − 10 min` (covers new uploads with old mtimes) → upsert.
   3. Metadata that the server fills asynchronously (place, caption, EXIF for files on external storage) arrives later without an mtime change: re-fetch props for items uploaded in the last 48 h whose place is still unknown when they reach a checkpoint (10 min, 1 h, 6 h, 24 h, 47 h after the upload; looked at no more than every 10 minutes), and run a full **reconciliation** (step 4) after a root ETag changed (the delta SEARCH cannot see deletes and moves) but at most every 10 minutes (longer for large libraries: about one request per thousand items, so 150 000 items once an hour) and not while a backup pass uploads; **at once, without that interval, in the first sync after a launch or after a return to the app (at most every 5 minutes) and on pull-to-refresh when a root ETag changed since the last one** — a file or folder deleted elsewhere is gone after one sync when the app is opened, also when the app ran a few minutes before (the interval alone kept it for up to 10 minutes through any number of launches); on pull-to-refresh also without a change when the last one is 10 minutes old, at once on "Sync now", and otherwise once a day.
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
- **Disk cache** keyed by `(account, fileId, etag, bucket)`, LRU, default limit 2 GB (setting: 500 MB – 20 GB). Memory cache sized by the platform. Prefetch around the scroll position (UICollectionView prefetching) and in the background for the first screens of the timeline, today's memories and recently opened albums (§18.3.2).
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
1. **Library** — the timeline (All / Photos / Videos / Favorites in its filter menu, §19.2), memories strip at the top; top bar: filter menu, Select and the account button (Settings, Upload, accounts).
2. **Collections** — the sidebar's rows (§19.1): Favorites, Memories, People, Places (map and places); Albums (with the smart albums), Shared (shared albums and "Shared with you"); at the bottom "Utilities": Folders, Tags, Archive, Recently deleted, Clean up, Insights, Stickers, Backup status. Its top bar has "+" (New album…, Upload) and the account button.
3. **Search** (search tab role) — unified search (§7.7).

**iPad, Mac, visionOS** — `NavigationSplitView` with a sidebar:
- *Superseded by §19.1 (round 9), the slim sidebar:* Library, Favorites, Memories, People, Places; Albums (the top albums
  listed on the Mac, then All Albums) and Shared; Utilities (collapsed): Folders, Tags, Archive, Recently deleted, Clean up,
  Insights, Stickers. Photos and Videos are Library filters, the map is part of Places. The Mac's account is a compact row at
  the bottom of the sidebar; iPad and Vision Pro have the same account row at the bottom of their sidebar (since
  2026-11-27; before, it was the sidebar's header).

**macOS specifics:** menu bar commands (File: New Album, Upload…, Export…; Edit: Select All, Favorite ⌘., Delete ⌫, Info ⌘I; View: zoom ⌘+/⌘−, Show sidebar, Square Tiles ⌥⌘S; Image: Rotate ⌘R, Edit ↩︎), multiple windows (open album/person/place in new window or tab), space bar quick look in the grid, drag & drop with Finder and other apps, Settings scene, toolbar search field.
Decided in round 4 (as in Photos): Image ▸ Rotate Left ⌘R and Rotate Right ⌥⌘R work on the selection and save like the editor's "Overwrite original" (a new file version; not offered for read-only shares or formats that can't be written back), View ▸ Sync Now is ⇧⌘R; Edit ▸ Copy puts the originals on the pasteboard (image data and file URL; at most 100 items, Export for more); "Add to Album" is a submenu (New Album…, the albums used last in this app, then the most recently changed, All Albums…); the grid's context menu has Copy, Rotate, Share (system share menu/sheet) and the same submenu; an album opens in its own window from File ▸ Open in New Window, its card's context menu or ⌥-click (one window per album, restored with the app; it shows the album only while its account is the active one). On iPad, a photo dragged from a grid onto an album (another window) is added to it — the same file, not an uploaded copy; files from other apps dropped there are uploaded into it.

**visionOS specifics:** main window with sidebar; viewer opens in its own window that can be enlarged; spatial photos (stereo HEIC) are presented spatially; panoramas may open in an immersive space (M5). *Decided (round 4):* a spatial photo is recognised from the original's stereo pair group (read when a HEIC is viewed on Vision Pro) and shown with `ImagePresentationComponent`; a panorama (≥ 3000 px wide, ≥ 2:1, from the server's size) opens in an immersive space on a cylinder segment (aspect × 60°, at most 360°).

### 6.3 Empty, loading and error states

Every view has: first-load skeleton, empty state with a single helpful action (e.g. "Turn on backup", "Create album"), offline banner when showing cached data, and inline error with retry. Missing server features show an explanation instead of a broken view.

### 6.4 Photo grid

- Square tiles by default; "Aspect ratio" mode shows each photo whole. *Decided (round 4):* as Apple Photos' "Aspect Ratio Grid" the photo is fitted into its square cell (letterboxed), not laid out in the web's justified rows — the grid keeps one layout, its performance budgets, scrubber and keyboard navigation. The setting follows the user to their other devices since round 12 (Settings › Library display › Square tiles, View ▸ Square Tiles ⌥⌘S; §22.5.2) and neither follows nor writes the web's `croppedLayout`: the web defaults to `false` (its justified layout), a client cannot tell that default from a choice, and following it would turn most grids away from square tiles.
- Pinch to change column count (iPhone 3–9 columns, iPad/Mac more); Mac: ⌘+/⌘− and View ▸ Zoom In/Out (the toolbar slider was removed in M10, §19.2). Map the density to the server config `gridDensity` (small/medium/large) where available.
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
- **TL-6** **Stacks** (setting "Stack similar photos", default on): (a) bursts — consecutive photos ≤ 3 s apart (min. 2) *(decided, round 4: only bursts the camera marked in the file names (`BURST` + number, `COVER` frame shown) are stacked; iPhone bursts need Apple's BurstUUID, which stock servers do not report, and the time rule also stacks quick single shots, which Apple Photos never does)* *(revised, round 11, §21.4: also PhotoKit bursts by `burstIdentifier`, and quick runs of alike photos — ≥ 3 frames, ≥ 2 a second, sketches alike — once this device compared them; a burst shows its best shot)*; (b) shot variants — same folder + same normalised shot name (`IMG_E1234` ↔ `IMG_1234`, `(edited)`, `-edited`, `~2`, RAW+JPEG…; rules and leader ranking in `photos-extended-api.md` stack-same-shot-variants). A stack shows its leader with a count badge; opening it shows all members; actions on a stack apply to all members after confirmation *(decided, round 4: delete, favourite, archive, add to album, tags and date/location apply to all members, the delete confirmation counts them; open, info, edit, share and export use the shown copy, as Apple Photos does with RAW + JPEG)*.
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
- **SH-8** **Partner sharing**: Settings › Partner sharing lists folders shared with the user (received user/group shares); turning one on indexes it with the timeline folders (only that folder is read, no rebuild) and its photos get a partner badge; "Hide partner photos" in the Library's filter menu (§19.2) and a switch hide or show them in the timeline. "Share my photos with a partner…" opens SH-7 for the upload folder. Stored per account on the device; the server and the web app's timeline folders are not changed.
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
- Since M10 both screens are reached from one Clean up screen (§19.3), with similar shots, large videos and the device's
  free-up row beside them; their destinations and links open Clean up at their section.

### 7.16 Editing — M5

#### 7.16.1 Photo editor

Core Image pipeline (`PhotosMedia/Editing`), non-destructive while editing, rendered at full resolution on save:
- Crop (free, original, square, 4:3, 16:9, …), rotate 90°, straighten (±45°), flip. Free crop: the crop tool shows the whole picture with a frame (corner and edge handles, drag inside to move); a lock keeps the aspect; presets set the largest centred area of their ratio (in the photo's orientation) and lock it; the crop is stored as fractions of the straightened, turned and mirrored picture and turns/mirrors with it. Flip mirrors left to right as the picture is shown.
- Auto-enhance (`CIImage.autoAdjustmentFilters`).
- Filters (system photo effects: Vivid, Vivid Warm/Cool, Dramatic, Mono, Silvertone, Noir…).
- Adjust: exposure, brilliance/highlights/shadows, contrast, brightness, black point, saturation, vibrance, warmth, tint, sharpness, vignette.
- Before/after, undo/redo, reset.
- Works on the original (download first, show progress). Keep EXIF/GPS/capture date; reset orientation; keep HDR gain map when the format allows, otherwise SDR.
- Presentation (decided in the round-4 simulator pass, as in Photos): full screen on iPad, a sheet on iPhone and the Mac.

#### 7.16.2 Saving

Since M7 the editor saves non-destructively (an edit recipe, §16.3.1); the two file saves below stay in its More menu.

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

Backup status row (sidebar/Collections) and screen: state (Up to date / Uploading 12 of 340 / Paused: waiting for Wi-Fi / Paused: Low Power / Error), progress, current item thumbnail, per-asset status in the device-library view ("Backed up", "Already on server (matched)", "Waiting", "Failed: reason"), pause/resume, "Back up now". The Backup screen lists the photos that are not backed up ("Not backed up yet", local thumbnails, with failed / only-in-iCloud marks).

_Changed in round 11 (§21.1):_ this section first said a grid badge for device photos was "not needed" because the timeline shows server content. The owner now wants them in the Library, like Google Photos: without them a photo taken today is missing from the Library until its upload is through, and nothing in the Library says what is not safe yet. So device photos that are not backed up stand in the timeline with a badge, and the Library and the account menu carry a backup summary; see §21.1.

#### 7.18.8 Free up device space (M5)

"Remove backed-up photos from this device": only assets whose every resource is `uploaded` or `matched` with a verified server file (re-check existence and size right before: the server lists the file with exactly the device's size, and the same file id when known; converted or name-only matches never qualify; RAW, edited version and Live Photo motion are required), deletion via `PHAssetChangeRequest.deleteAssets` (system confirmation), never for assets newer than 30 days unless the user chooses.

#### 7.18.9 Mirror device albums (iOS, iPadOS)

Opt-in, for the albums the user picks (Backup › Albums): after each pass, backed-up photos (ledger `uploaded`/`matched`) of a picked device album are added to the Nextcloud album of the same name (created when missing; `/` becomes `-`). The edited rendition is preferred. Only adds: a photo taken out of the device album, or removed from the Nextcloud album, is not touched again (what was added is remembered per album).

#### 7.18.10 Import from Google Takeout (Mac)

_Round 5: part of Import Library… (§15.7), on every platform; the rules below still apply to Google exports._


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

*Status (round 10, see §20.6 and [PERFORMANCE.md](PERFORMANCE.md)):* store budgets met on the synthetic 100 000-item
index; viewer and memory met in the simulator; cold launch to the cached timeline measured 0.9 s on an idle Mac (Debug)
and 3.1 s in the iPhone simulator, of which 1.8–2.2 s is the simulator's dyld before `main` — the 1 s budget is judged on
a device (DEVICE-TEST-PLAN D8); scroll hitches need a device.

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

- Repo **https://github.com/nextcloud/photos-apple** (public, default branch `main`; created as photos-ios on 2026-11-22 and renamed on 2026-11-27, GitHub redirects the old name). The copy of this spec in the repo (`docs/SPEC.md`) is the one to update.
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

**MF-1 Memory films.** Every memory (On this day, trips, year recaps, and whatever the memory engine adds later) plays
as a film instead of a slideshow ("Play slideshow" in the memory's toolbar and context menus, "Play film" in the year in
review). Decided:
- *Plan* (`FilmPlan`, shared by player and export): a title card first (title, date line, a trip's places; serif type
  sized to the frame) over the cover photo, then at most 60 pictures (favourites first, the rest spread evenly, in the
  order taken). A picture lasts 2/4/8/16 beats, whichever is closest to 3.4 s; favourites twice as long (≤ 7 s); videos
  play inline for their length (2–10 s, whole beats); Live Photos play their motion (muted) at the start of their shot.
  The last picture stays while the film fades to black.
- *Rhythm*: with music the cuts land on the music's beats (`BeatDetection`: onset envelope, autocorrelation with a mild
  preference for 120 BPM, period refined together with the phase; on the device, first 150 s decoded at 11 kHz). Within a
  day/stop shots cut on the beat; a new day or stop dissolves in over one beat. Without music, or when the music has no
  clear beat (correlation < 0.2), or when it is an Apple Music song (DRM: it plays but cannot be read), a steady rhythm:
  3.2 s per picture with 0.8 s dissolves. The music starts with the film and follows scrubbing; it loops after its end.
- *Camera* (`KenBurns`): a picture fills the frame when that keeps ≥ 55 % of it, else it is shown whole over a blurred
  copy of itself. The move alternates zoom in / pull back / pan (factor 1.15, pans 1.08), always towards the faces
  (Vision face rectangles, the larger ones, with room around them) or else the most salient region (attention-based
  saliency); computed on the device when the picture loads and fixed before the shot appears. Videos are not moved.
- *Trips*: the photos' coordinates are grouped into stops (`TravelRoute`, 25 km); before the first photo of a new stop
  ≥ 30 km away (at most 6 times) the film flies over the map: a satellite map with labels (MapKit snapshot of the region
  of both stops, like the Places map; only the region is sent to Apple Maps; the standard muted map where satellite imagery
  is missing), the camera starts over the first stop, pulls back and comes down over the second while the route is drawn
  as an arc, caption "A to B". Without any map (offline, or where MapKit cannot draw one, as in the iOS simulator): the
  same flight over a night-blue grid with the stops placed by their coordinates.
- *Controls*: tap shows/hides them (they hide after 3.5 s while playing); Close, Mute (music and the videos' sound),
  Export; Previous/Play-Pause/Next and a scrubber with elapsed/total time; at the end "Play Again" and Export. Keyboard:
  ← → (segments), Space, M (mute), Esc. With VoiceOver the film starts paused and each segment is described (title, place
  caption, or the photo's kind, date and place). Reduce Motion: no camera moves, the map does not fly (dissolves stay).
  The film pauses when the app leaves the foreground and keeps the display awake while playing.
- *Privacy*: archived photos are left out (also when archived after the memory was computed); everything is computed on
  the device; the films are inside the app and so behind the app lock.

**MF-2 Export as video.** From the film's toolbar, its end card and the memory's More menu ("Export video…"). 1080p
(1920 × 1080; year in review 1080 × 1920), 30 fps, H.264 (default, "most compatible") or HEVC ("smaller"), the choice
remembered. The frames are rendered with Core Image from the same plan (same camera moves, title and captions rendered from
the same SwiftUI views), at 4096-px previews; videos and Live Photo motion come from the originals cache. Sound: the chosen
music *file* (or a non-protected Music-library song), looped and faded in/out; Apple Music songs cannot go into a video —
the sheet says so before export and the video has no music; without music, the videos' own sound. Progress with Cancel;
then Share… (system share sheet: Messages, Save Video, Files…), Save to Nextcloud… (folder picker, uploaded through the
transfer queue from a copy of its own) and on the Mac Save to Mac…. Temporary files: one folder per export, removed when
the sheet closes, on failure and on cancel; leftovers older than an hour are removed at the next export.

**MF-3 Year in Review.** Swipeable story-shaped cards (360 × 640 pt design, scaled to fit; paging scroll, ← → keys,
page dots) computed on the device from the index (`YearInReview`): intro (year, photos and videos over a mosaic of the
best photos), busiest day (≥ 5 photos), top month with a 12-month chart (≥ 10 active days), longest streak (≥ 3 days),
on the move (places ≥ 2, countries ≥ 2 from the server's place data, km between stops ≥ 50 "as the crow flies"; countries
only where the server provides them — no reverse geocoding), your people (top 5 *named* people; unnamed Recognize clusters
and people hidden on this device left out; round face crops found on the device), pet of the year (dog/cat in ≥ 3
photos), first snow, first beach day, favorites, best of (3 × 3: favourites first, then spread over the year). Pets, snow
and beach come from the on-device labels (Settings › Search › on-device recognition) and are absent without them. Numbers
count up when a card comes into view (not with Reduce Motion). Toolbar: Play film (the year's recap memory, MF-1) and
Share: "Share cards as images…" (1080 × 1920 PNGs) or "Export video…" (MF-2, cards cross-faded, about one picture each).
Offered in the Memories screen ("Year in review": a card per year with ≥ 30 photos) and in the library's memories strip in
December (the year ending) and January (the year just ended), where it replaces that year's recap card.

Platforms: iPhone and iPad (film full screen), Mac and Vision Pro (pushed in the window); all features on all four.
Not done: a MapKit camera *animation* (the flight moves over a snapshot instead, which also works in the export and
offline-rendered video), per-memory music choice, beat-synced Ken Burns accents within a shot.

### 15.2 Photographer's Mac: import, culling, compare, external editors [macpro]

For people who shoot a lot and keep everything on their own Nextcloud: get a card in, go through the shoot with the
keyboard, keep the best, edit in the tools they already use. Mac first; the iPad gets what fits there.

**Culling (all platforms; keys on the Mac and iPad with a keyboard).**
- Ratings 1–5 stars and the flags Pick / Rejected are **collaborative system tags** named `★`, `★★`, `★★★`, `★★★★`,
  `★★★★★`, `Pick` and `Rejected` (fixed names, not translated: they are the shared vocabulary of all devices and the
  web; the app shows them in the user's language). They are created on first use through the stock tags API
  (`POST systemtags/`, an existing tag of that name in another case is reused). No server change. A server that lets
  only admins create tags gets an explanation naming the tags to create.
- Changes are tag operations of the outbox (`PendingOperation.tag`): optimistic, offline, undoable (Edit ▸ Undo
  Rating). Only the tags that differ are changed; a file has at most one rating tag after a change.
- Reading: several rating tags (two devices at once) → the highest counts; Pick and Rejected together → Pick counts,
  so "Delete Rejected" never takes a picked photo. Other devices see changes after the next tag refresh (`LabelSync`).
- Keys without modifiers, as in Lightroom/Photo Mechanic: **P** pick, **X** reject, **U** unflag, **1–5** stars,
  **0** no rating; in the grid (selection, stacked copies included) and the viewer (the photo shown, or all copies of a
  stack). They are deliberately not menu key equivalents (a bare letter in the menu bar would fire while typing in the
  search field); Image ▸ Flag ▸ / Rating ▸ list the same commands, and so do the context menu and the viewer's More menu.
- **Auto-advance** (on by default; Image menu and the filter menu): after a key the next photo is selected (grid) or
  shown (viewer). On the Mac the grid follows the viewer: back in the grid, the photo seen last is selected.
- Feedback: a short confirmation in the middle ("★★★ 3 Stars", "Pick") and VoiceOver announcement; tiles show the flag
  and stars in the top leading corner (stars hidden below 56 pt tiles), rejected tiles are dimmed; the viewer shows the
  mark in a corner.
- "Ratings and Flags" submenu of the Library's filter menu (§19.2): All Items · Picks · Unflagged · Hide Rejected · Rejected · 1–5 Stars or More ·
  Unrated (a condition of the grid query, so 100 000 photos stay fast), Auto-Advance, **Delete Rejected…** (every
  rejected photo of the library that may be deleted, after a confirmation with the count; to the trash bin; undoable).

**Compare (all platforms).** Select 2–4 photos and press **C** (or Image ▸ Compare, context menu): 2-up side by side
(one above the other in a tall window) or 2 × 2. Zoom and pan are shared: zoom into one and all follow, relative to
"fit". **Z**, a double-click or the toolbar button toggles **100 %** (one image pixel per screen pixel of the photo with
the focus); the panes load the 4096 px preview and, above that, the original (RAW developed by Image I/O). Arrow keys
move the focus; rating keys rate the photo with the focus; **Return** ("Keep This One") picks it and rejects the others
after a confirmation. Presented like the viewer (pushed on the Mac, full-screen cover on iPhone/iPad).

**Import from camera or card (Mac, iPad).** File ▸ Import from Camera or Card… (⇧⌘I, as Photos' Import).
- Sources: cameras over USB through ImageCaptureCore (Mac and iPad); on the Mac memory cards mounted as volumes with a
  `DCIM` folder when the sandbox lets the app read them, else ImageCaptureCore offers the card; any folder ("Choose
  Folder…", on the iPad the card reader or drive in Files).
- The sheet shows the shots (thumbnails from the embedded EXIF thumbnail, RAW + JPEG of a shot as one tile with a badge),
  newest first. **New items only** (default on) leaves out what is already on the server: a per-account ledger of earlier
  imports (name + size + capture second), then the backup's matching rules against a server search of the shots' dates,
  plus "same size, capture time off by whole hours" (cameras write local time without an offset). A shot of which only
  the RAW is missing imports the RAW.
- Destination: a folder pattern (default `/Photos/{yyyy}/{yyyy-MM-dd}`; parts `{yyyy} {yy} {MM} {MMM} {dd}` and any
  combination of them, and `{camera}`), date parts from the shot's capture time in this device's time zone; a pair goes
  into one folder (by the earlier time). Suggestions in a menu; the preview line shows the folder and "N new of M".
- Upload with the backup's uploader (chunked, resumable, `X-OC-MTime` = capture time, `OC-Checksum` SHA-256), an existing
  file of the same name and size counts as done. **Verified** = the server has the file with the same size and, where it
  keeps one, the SHA-256 the app computed from the card's bytes.
- **Delete from card after verified upload** (off by default; only when the source can delete): asks once with the count;
  only verified files are deleted, the others are listed as kept. **Eject after import** (when the device can eject).
- The import runs in the background: the sheet can be closed; progress (bytes) as a ring in the Library toolbar with a
  popover (Stop Import, summary: imported, verified, deleted, kept, failures) and on the Mac as a bar on the Dock icon
  (a bounce when done and the app is in the background). iPad: extra background time while the app is left.

**Edit With (Mac).** Image ▸ Edit With ▸ (and the context menu) lists the apps that open the file's type (default app
first, then by name; "Other…" picks any app). The original is downloaded to a private temporary folder and opened in that
app. The file is watched (once a second; a save counts when the file changed and stayed the same for a second, which
covers apps that save in steps or swap in a temporary file). Each save is uploaded as a **new version** of the file with
`If-Match` (the ETag it was downloaded with, then the ETag of the last upload). If the file changed on the server
(412), or the photo is read-only, or the app saved another format, the save becomes `<name> (edited).<ext>` next to it
and later saves update that copy. A toolbar button lists the photos open in other apps with their state ("Saved at
14:02", "Saved as a copy") and **Done**, which stops watching and removes the local copy; quitting the other app ends the
session after its last save. Leftover copies are removed at the next launch.


### 15.3 New platforms: Apple TV and Apple Watch [tvwatch]

Two new apps beside the universal app: one for Apple TV (tvOS 27) and one for Apple Watch (watchOS 27). Bundle ids:
`com.nextcloud.photos.tv` (+ `.tv.topshelf`), `com.nextcloud.photos.watchkitapp` (+ `.watchkitapp.widgets`); the README
lists what Nextcloud's developer account needs.

**Code layout (decided).** The package builds for tvOS and watchOS too. The TV app links `PhotosCore` (accounts, keychain,
Login Flow v2, sync engine, store, image pipeline): the same code as the other platforms, so fixes reach the TV. Only
three things needed `#if os(tvOS)`: Core Spotlight and delivered notifications (unavailable on tvOS: the indexer and the
notification helpers do nothing there) and LocalAuthentication (no app lock on the TV). The free-space key for
"important usage" is unavailable on tvOS/watchOS (plain free capacity there). GRDB supports tvOS and watchOS; NextcloudKit is
no longer a dependency (§4.3). `PhotosAppUI` is not built for tvOS: its grid is a `UICollectionView` with pinch and drag
selection, its viewer is touch-driven; the TV's screens are their own, made for focus and the Siri Remote, in `App/TV`.
The watch app links only `PhotosModel`. Logic shared with tests lives in the package (`PhotosModel/CompanionContent.swift`,
`PhotosDomain/CompanionPlans.swift`, `PhotosCore/CompanionExport.swift`, `CollectionStore.albumMedia`).

#### Apple TV

- **Login without typing a password (TV-1).** The user types only the server address (remote, dictation or the iPhone's
  keyboard). The TV starts Login Flow v2 and shows the flow's login link as a large QR code with three steps ("open the
  camera on your iPhone or iPad", "log in to <host> and allow access", "your photos appear here") and polls the flow. The
  phone's camera opens the link, the user logs in there and grants access; the TV receives its own app password. The full
  link is printed small under the code for a phone without a camera: stock servers have no shorter link or user code
  (a typeable code would need a server change, not done). An expired flow (20 minutes) says so; "Use Another Server" goes
  back. http:// servers and untrusted certificates ask first, like on the other platforms (certificate trust shows the
  SHA-256 fingerprint). Managed server addresses are filled in. A revoked app password brings the login back with the
  account's server filled in. *Not built:* hand-off of a login from the iPhone app (plan below).
- **Home (TV-2).** Tabs Home, Albums, Settings. Home is a column of shelves that scroll sideways, each a focus section:
  the family slideshow banner (when an album is chosen), Memories (16:9 cards with title and dates, in the order of
  `TVShelves.memories`: On this day nearest year first, the year in review, trips newest first; context menu "Play
  Slideshow"), Favorites, Albums, Shared Albums, Recent (photo shelves have "Show All"). Cards use the system's card and
  poster focus styles (lift, parallax). Reloaded after every sync; albums refreshed from the server on load. Empty and
  first-sync states have their own text.
- **Memory, album, all photos (TV-3).** Title, dates or place, "Play Slideshow", for albums "Use for Family Slideshow";
  a four-column grid of focusable tiles (videos with length, favourites with a heart). Shared albums' items that are not in
  the user's own index are shown too (`albumMedia`).
- **Viewer (TV-4).** Full screen, photo shown whole on black (4096 px preview, decoded to at most 3840 px; neighbours
  prefetched). Siri Remote: swipe/press left and right for the previous and next item, down or click shows date and time,
  place, caption, file name and "n of m", up hides it; Play/Pause starts a slideshow from this photo; Menu goes back. A
  video shows a play symbol; click or Play/Pause opens it in the system player (`AVPlayerViewController`: transport bar,
  scrubbing, info panel with title and date), streamed through the app's HTTP client (§5.5.3) or from the cache.
- **Slideshows (TV-5).** Photos only (videos would need their own time), cross-fade (`Slideshow.crossfade`) with a slow
  drift towards a corner (`Slideshow.drift`; none with Reduce Motion), landscape photos fill the screen, others are shown
  whole over a blurred copy of themselves. A memory's or album's title and dates appear over the first photo. Play/Pause
  pauses (symbol), left/right skip, click shows place and date, Menu ends. The next photo loads while the current one is
  shown; photos that fail are skipped. The screen saver is held off while it plays. Time per photo: Settings (2–20 s,
  default 5). Memory films (§15.1) were not on this branch's base; the TV plays memories with this slideshow and can play
  films once they are merged.
- **Family slideshow (TV-6).** One album chosen in Settings or on the album ("Use for Family Slideshow") plays from the
  Home banner like a picture frame: shuffled, every photo once per round, never the same photo twice in a row across
  rounds (`FamilySlideshow`, seeded, so it goes on where it stopped after a restart), for as long as it runs, with the place
  and date and, optionally, the time and date in large type (Settings › Show Time and Date).
- **Top Shelf (TV-7).** A Top Shelf extension shows the recent memories (at most 8) as a full-screen carousel with
  "Play" and the system's "more" action. It holds no account and makes no request: after each sync the app writes
  `TopShelf/manifest.json` and 1920 px covers into the App Group (`CompanionExport.exportTopShelf`, only when something
  changed, then `topShelfContentDidChange()`); the extension reads them. Its links (`nextcloudphotos://memories/<id>` and
  `…/play`, `TVRoute`) open the memory or play it. Logging out empties it. The app's static Top Shelf image and icon layers
  are made from the app icon until there is artwork (§14.5).
- **Settings (TV-8).** Account, server, sync state, Sync Now; time per photo, family slideshow album, time and date; Log Out
  (confirmation; revokes the TV's app password and removes everything the app keeps on the TV).
- Not on the TV: backup, uploads, editing, sharing, deleting, search, people/places, app lock, push. Several accounts are
  supported by the model but the TV shows only the active one (no account switcher yet).

#### Apple Watch

- **Data path (decided): WatchConnectivity from the iPhone app, no login on the watch.** A watch login would need Login
  Flow v2 on the watch (a QR code cannot be scanned from the wrist, typing a server address on the watch is poor) and an
  app password stored on the watch: more to secure for a few photos a day. Instead the iPhone app's `WatchBridge` builds a
  `WatchDigest` (`CompanionExport.watchDigest`) after each sync, when the app comes to the front and in the background
  refresh, and sends it as the application context; the photos go as 480 px JPEGs with `transferFile`. Only changed
  digests are sent; photos the watch already has are not sent again; the watch asks for photos it is missing (re-installed
  app). With app lock on the watch gets an empty, locked digest and shows nothing; logged out, it asks to open the app.
  Received file names are checked (`WatchDigest.isValidFileName`), so nothing from the phone is written outside the
  watch app's folder.
- **What is sent (`WatchDigestPlan`).** On this day: up to 12 photos spread over all years of today's "On this day",
  newest first; on a day without any, the newest memory (trip or year in review) fills in under its title. Favourites: up
  to 12 others. Photo of the day: a favourite of this day if there is one, else one of this day's, else a favourite; the
  same all day, another the next day.
- **Watch app.** Vertical pages (Digital Crown): Photo of the Day full size with "n years ago" and the place; On This Day
  (or "3 years ago" when all are of one year) and Favorites as two-column grids; a tap opens a full-screen pager.
- **Complication (WidgetKit).** "Photo of the Day" in the accessory families: rectangular (photo, title, years ago,
  place), circular and corner (the photo, years ago as the label), inline (years ago · place). Reloaded when a digest or
  photo arrives, and at midnight. Shows a lock symbol while app lock is on.

*Plan for what is not built:* hand-off of the TV login from the iPhone app (the iPhone app scans the TV's QR code with
its own scanner, shows "Log in Apple TV?" and grants the flow with its session through the server's grant page, so the
user does not log in again); an account switcher and search on the TV; watch digest refresh at midnight without the
phone app (needs the background refresh to run, which the system decides).


### 15.4 Ambient: wallpaper, StandBy, Live Activity, Controls, Vision Pro memory room [ambient]

Photos and the backup outside the app's window. Shared logic lives in `PhotosCore/Ambient` (unit-tested on macOS); the
widgets and controls in `Extensions/Widgets`; the controls' intents in `App/Shared/AmbientIntents.swift`, compiled into both
the app and the widget extension (`WIDGET_EXTENSION`).

**Sources and rotation (`AmbientPhotos`, `AmbientRotation`).** A source is Favorites, Memories (On this day; on a day
without, the newest year in review, then the newest trip), an album (own or shared; its own order, including photos only
the album knows) or the Library (newest first). Only still images: no videos, no motion halves of Live Photos, nothing
archived; at most 500 photos. The order is either the source's order or shuffled with a seed derived from the source
(FNV-1a, the same in every process), so every photo comes once before any comes again and a new widget timeline continues
where the last one ended (time slots of the interval, counted from 1970).

**Mac desktop pictures (`DesktopPictures`, macOS).**
- "Use as Desktop Picture" for one still photo: the grid's context menu, the viewer's More menu and Image ▸ Use as Desktop
  Picture. The photo goes on every display, filling it (cropping what does not fit, as "Fill Screen"); a running rotation
  stops, because it would replace the photo. Errors are shown with the system's error alert.
- Rotation: Settings ▸ Desktop (a tab of the Settings window), and "Use as Desktop Pictures…" in an album's menu (a sheet
  preset to the album). Options: photos (Favorites, Memories, Library or any own/shared album), Change picture (every 5,
  15, 30 minutes, hour, day), Show on (All Displays or one display), Shuffle. With All Displays every display gets a photo
  of its own, and each display gets a photo of its shape (landscape on landscape displays, portrait on portrait ones;
  photos that suit none wait for a display they suit, and when none suits, the next photo is taken). "Next Picture" and
  "Stop" in Settings; the running rotation is shown with its source, displays and interval.
- The pictures are files in the app's caches (`Library/Caches/DesktopPictures`): the original for JPEG/HEIC/PNG up to
  40 MB, else the largest preview (4096 px) as JPEG; only the files that are on a display are kept.
- *Decided:* no login item or background agent. The rotation runs inside the app while it runs — in the background and
  with no window open (the Mac app keeps running when its last window closes) — and continues where it was (remembered in
  the app's defaults) at the next launch. It waits in steps of at most five minutes, so a Mac that slept changes soon after
  waking; App Nap may delay a change by a little. Limits: `NSWorkspace` sets the picture of each display's *current* Space
  only; the rotation's photos come from the account they were chosen in and change only while that account is the active
  one; an album's photos must have been loaded once (opening the album). A screen saver is not built (no native API for a
  sandboxed app's own saver short of a separate `.saver` bundle).

**Photo frame widget (`PhotoFrameWidget`).** An App Intents–configured widget ("Photo Frame"): Photos (Favorites,
Memories, Album, Library), Album (own and shared albums of the active account), Change Photo (every 15 minutes, hour,
3 hours, day), Shuffle (on), Hide While Locked (off). Families: small, medium, large, extra large; on iPhone/iPad also the
Lock Screen's rectangular accessory (a small picture with place and day). The photo fills the widget
(`containerBackgroundRemovable(false)`, so StandBy keeps it full-bleed); place (else day) in the corner, left out in the
vibrant/accented renderings and on an always-on screen, where the photo is dimmed (StandBy night mode). In the accented
(tinted) Home Screen the photo is desaturated and tinted. On Vision Pro the frame is a paper-textured print, elevated or
recessed on a wall. Tapping opens the photo in the app (with its account). A timeline has 3–6 entries (by size; each photo
is decoded to the widget's pixel size, max 1200 px), from the preview cache; up to two missing previews are fetched per
timeline. *Decided:* unlike the other widgets the frame shows its photo while the device is locked by default — StandBy
and the Lock Screen are what a photo frame is for; "Hide While Locked" restores the redaction, and with app lock on the
frame shows only a lock. The existing On this day and Favorites widgets stay.

**Backup status widget and snapshot (`BackupPresence`, `BackupWidgetSnapshot`).** The app writes a small snapshot of the
backup (on/off, set up, phase, counts, bytes left, last run; no file names) into the App Group
(`Application Support/backup-status.json`) when it changes: a new phase or switch at once, progress at most every 30 s;
the widget is reloaded at once for a new phase, else at most once a minute. The "Backup" widget: small (all platforms with
backup), and on the Lock Screen circular (a gauge while uploading), rectangular and inline. Tapping opens Backup.

**Live Activity (`BackupLiveActivity`, iPhone and iPad).** Shows photos left (of the pass), the size left (from the
library's byte sizes of what waits, `BackupStatus.pendingBytes`), why it waits ("Waiting for Wi-Fi", "continues when
Nextcloud Photos runs again"), why it stopped (storage full, login expired …) and "Backed up / N uploaded" at the end.
Lock Screen banner with progress bar and a Pause (running) / Resume (paused) button (`PauseBackupIntent`,
`BackUpNowControlIntent`); Dynamic Island: compact (symbol + number left), minimal (circular progress), expanded (counts,
progress, detail, button). Rules: it starts for a pass that uploads at least 10 items or 100 MB, or for any pass the user
started outside the app (control, Action button); it is updated at most every 2 s within a phase (a new phase at once);
a done pass leaves the Lock Screen after 15 minutes, a stopped one stays (system limit) so the user sees what to fix; an
activity not updated for 10 minutes shows "Continues in the background". It does not start while a continued processing
task shows the system's own progress for the same pass, never again in a pass the user swiped it away, and not when the
user turned it off — in Backup ▸ "Show progress on Lock Screen" (on by default) or for the app in Settings. Activities
left from an earlier run end at launch.

**Controls (iOS/iPadOS 18+ `ControlWidget`).** "Backup" (on/off toggle, value read from the backup options in the App
Group), "Back Up Now" (button) and "Nextcloud Photos" (opens the library); all can be placed in Control Center, on the
Lock Screen and on the Action button. Their intents are `LiveActivityIntent`s, so the system performs them in the app's
process (launched in the background when needed); "Back Up Now" waits up to 20 s for the Live Activity to start. Turning
backup on (or Back Up Now) without a backup set up continues in the foreground and opens Backup. "Turn Backup On or Off"
is also a Shortcuts action. *Decided:* no controls on the Mac (backup there runs with the app; a Control Center item
would add little) and none on Vision Pro (no backup).

**Vision Pro memory room (`MemoryRoom`, visionOS).** "Memory Room" in a memory's toolbar opens an immersive space (mixed)
where up to 24 of the memory's photos (all favourites, the others evenly spread, in order) hang as framed pictures — a
dark frame, a light mat, the photo — on a ring around the viewer (at least 2 m away), facing the centre: one row at eye
height up to 12, two rows (sitting and standing height) above. The 60° right in front stay free for the app's window and
the title; the frames start right of the window and go round to its left. They grow into place as their previews arrive and drift slowly up and down;
the memory's title floats in front. Look at one and pinch: it comes to the viewer (1.5 m in front at eye height, 1.2×); pinch again, or
another frame, and it goes back. A spatial photo (HEIC with a stereo pair) brought close is shown with its depth
(`ImagePresentationComponent`, spatial stereo); away from the viewer it is flat. Frames glow where the viewer looks
(hover effect) and are VoiceOver elements with place or day. The button becomes "Leave Memory Room".

### 15.5 Feel and craft: zoom levels, haptics, no spinners, similar photos [feel]

**Zoom levels (Library, all four filters).** Years › Months › Days › All Photos, as in Apple Photos.
- *Ladder.* A pinch moves along one ladder (`LibraryZoomLadder`): years, months, days, then the grid from its densest
  step to its largest tiles. Days sits before the densest grid: it shows a few photos of each day, the grid all of them.
- *Years and months* are cards with a key photo and the date over it (year: large title and count; month: month and
  year). *Days* show the date, the count and a mosaic of the day's best photos (one large and two small; the last one
  says "+N" when there are more). Cards adapt their columns to the width (one year per row on iPhone, more on iPad,
  Mac, Vision Pro). Drawn by SwiftUI over the grid, which stays underneath with its scroll position.
- *Key photos* (`KeyPhoto`): a favourite first, then Vision's aesthetics score where this device worked it out
  (`SimilarityIndex`), utility pictures (screenshots, documents), PNGs, videos and panoramas lose; a photo without a
  preview is never chosen while there is another. A day's photos are its best five, shown in time order, the key photo
  first. Built off the main actor from the grid's own items (`LibrarySummary`): 100 000 items in 80–190 ms in a debug
  build (unit test budget 800 ms), rebuilt once after a burst of changes.
- *Gesture.* The content follows the fingers (scaled around them; past the ends of the ladder it resists like a
  rubber band). On release it settles on the stop the pinch was heading for: a pinch commits from a factor of 1.22,
  each further factor of 3 is one more step (at most three), and the pinch's speed is carried on for 0.12 s (adding at most a factor of 1.42), so a
  quick pinch goes further (`LibraryZoomGesture`). The photo or card under the fingers stays under them: zooming into
  a month shows that month's days, out of the grid shows the day of the photo that was under the fingers. A pinch in
  on the days goes to All Photos at the step the user had before (the default step when that was the densest one).
- *Taps.* A year opens its months, a month its days, a day's photo All Photos at that photo, a day's date All Photos
  at the day.
- *Picker.* iPhone, iPad and Vision Pro: a segmented Years · Months · Days · All Photos picker floating at the bottom
  (hidden while selecting). Mac: the same picker in the toolbar, as in Photos for Mac; the zoom slider is for All
  Photos only. ⌘+/⌘− (View menu) move along the same ladder; ⌘− at the densest step goes to the days. Trackpad pinch
  on the Mac steps through the grid while the fingers move (one step per 0.22 of magnification), anchored on the photo
  under the pointer, and on to the days. The level is remembered on the device (`libraryZoomLevel`).
- Transitions grow out of (or shrink into) the point the pinch started at; short cross-fades with Reduce Motion.

**Haptics.** Following the system's settings (System Haptics on iPhone; the trackpad's force click feedback on the
Mac), none on Vision Pro:
- a selection tick when the year at the top of the grid changes while scrolling fast (> 2200 pt/s) or scrubbing the
  year index, at most one per 70 ms (`YearBoundaryTicker`); not when the grid jumps after a relayout;
- a light impact when a pinch snaps to another zoom step or level, and when the selection mode starts;
- Mac: the trackpad's *level change* feedback on each zoom step of a pinch and *alignment* feedback when the date
  scrubber is dragged past a year. No other haptics on the Mac.

**No spinners.** Every screen shows the shape of what is coming instead of a spinner on an empty page (skeleton
covers and rows that pulse softly, the grid skeleton, BlurHash and cached previews):
albums, an album opened from a link or window, people, folders (Collections and the Settings folder picker), tags, the
album picker of "Add to album", the sharing sheets (one and several photos), partner sharing, tag routes; the editor
shows the cached preview until the original is decoded; the viewer shows nothing (not a spinner) for the milliseconds
the local index takes; the first-sync caption no longer has a spinner beside the skeleton. Where nothing better is
possible a spinner appears only after 0.9 s (`DelayedSpinner`): a video that takes long to start (its poster is shown
meanwhile), slideshows and memory films before their first photo, a public album's full-size photo, the app's first
moment while the account loads. Spinners that remain on purpose (they are progress of something the user started, or
small status indicators): Saving… in the editor, Reading text… (Live Text/extract text), Looking for duplicates… and
files to clean up (local scans with a caption), Preparing video… (server conversion), inline spinners of buttons
(login, diagnostics export, partner and people actions, backup device checks, Takeout import), the "Syncing" row of
Settings, the backup status icon while a pass runs, determinate progress bars (uploads, backup, export, sharing many).

**Show Similar.** In the viewer's More menu and the grid's context menu, for photos (not videos).
- Vision feature prints (revision 2: 768 floats of unit length) and aesthetics scores are computed on the device from
  previews already in the cache (256 or 1024 bucket, decoded at 384 px), stored per photo version in the account
  database (table `similarity`, migration `v5-similarity`; a row without a print marks a photo that could not be
  analysed; rows go with their photos). Never uploaded.
- Indexing is incremental (only new or changed versions) and battery-aware: a `BGProcessingTask` that requires power
  (iPhone, iPad; `com.nextcloud.photos.similar`), an `NSBackgroundActivityScheduler` activity on the Mac, and while the
  Library is on screen a trickle of 16 photos at a time with pauses, at background priority, only when not in Low
  Power Mode, not warm and on battery above 35 % (`SimilarIndexing.Conditions`). Vision Pro only has the trickle.
- Search: each print has a 128-byte sketch (a fixed random projection quantised to bytes) held in memory (12.8 MB for
  100 000 photos); one matrix product scores them all (40 ms for 100 000 in a debug build, budget 250 ms), the best 360 are re-ranked by their full prints, and those at a
  cosine of 0.62 or more are shown (at most 120), most alike first. Calibrated on the test library: unrelated photos
  are below 0.56 in 99 % of pairs, strong crops of one photo above 0.74. A photo that was never indexed is analysed
  on demand (its preview is loaded if needed). While the index is incomplete the screen says how many photos were
  compared and searches again every 6 s.
- *Best shot of a series.* Results at a cosine of 0.84 or more, taken in a chain of shots no more than 10 minutes
  apart that reaches the photo, are its moment; its best shot (since round 11: §21.4) is a favourite, else the best aesthetics score, else the
  middle one. The screen shows it with "Keep Best…", which deletes the other shots (confirmation; to the trash bin,
  through the outbox like every delete). Exact copies stay with Duplicates (§7.15): those are identical files, these
  are different shots.
- Settings › Search: "Find similar photos" (on by default), with the number of photos compared; off deletes the
  stored prints.
- The simulator cannot run Vision's models (they fail on its GPU and return one print for every picture on its CPU):
  there nothing is analysed and "Show Similar" works only on prints made elsewhere (docs/TESTING.md).


### 15.6 Then and now, travel globe [places]

Everything is computed on the device from the local index (GPS, the server's place name `nc:metadata-photos-place`
and country `nc:metadata-photos-place-country`); no server changes. Domain types in PhotosDomain (`Geo.swift`,
`ThenAndNow.swift`, `TimeLapsePlan.swift`, `Travel.swift`), queries in `TravelQueries.swift`, Vision and video in
PhotosMedia (`ThenAndNowMedia.swift`), screens in `ThenAndNowScreens.swift` and `TravelScreens.swift`.

**TN-1 Then and now spots.** A spot is the geotagged photos within 100 m of the first photo taken there (oldest photos
seed the spots, through a spatial grid), kept when they span at least two calendar years. Each year leads with its
best photo: the photo it was opened from, then favourites, then the photo nearest the spot's middle. Spots are ranked
by number of years, then span, then the most recent year. Title: "Lisbon · 2014 · 2019 · 2025" (server place name,
else "This place"; more than four years as "2010 · 2011 · 2012 · … · 2016").
**TN-2 Same view.** When a spot opens, Vision feature prints (`GenerateImageFeaturePrintRequest`) of 256 px previews
are compared on the device: up to 4 photos of the anchor year (the newest, or the year of the photo it was opened
from) and up to 12 per other year (6 with more than 8 years: favourites/middle first, then spread over the year). The
anchor whose matches are closest wins, and every year then leads with its photo closest to it. Without feature prints
(Vision unavailable, previews not loadable) the location order stays. Compass heading is not used: the index has no
`GPSImgDirection` (the server's metadata does not carry it) and reading it would mean downloading originals.
**TN-3 Screens.** Places and Memories show a "Then and now" row (one spot per place name, 12 at most, "See all" for the
full list); a card shows the first and the last year side by side. The spot screen shows the years side by side (two
visible on iPhone, up to four on wide screens, scrolling sideways), each opening its photos in the viewer; "Play
time-lapse"; "Export video…"; "All photos from here". The viewer's More menu has "Then and now" for a photo with
photos of another year within 100 m (found from a small box of the coordinate index while the menu is built); it opens
the spot in a sheet, anchored on that photo.
**TN-4 Time-lapse.** `TimeLapsePlan`: each year's photo held 1.8 s, cross-fading 1 s into the next with a slow 6 %
zoom (dissolve of 0.5 s without zoom with Reduce Motion), looping; the year large in the lower left. Full screen on
iPhone/iPad, a sheet on the Mac and Vision Pro; tap or Space pauses, Escape closes. **Export** writes the same plan
(1.6 s hold, 0.9 s fade, no loop) as an H.264 MP4 (1920 × 1080, or 1080 × 1920 when most photos are portrait, 30 fps,
year burnt in) from the 1024 px previews the screen already loaded, then shows it playing with Share (save to Photos/Files from
the share sheet).

**TG-1 Travel model (`TravelHistory`, reusable).** Visits: consecutive photos within 25 km of where the visit started,
without a gap of more than 2 days. Places: visits within 25 km of a place's largest visit. Home: the place with photos
on the most different days; everything within 50 km of it is home. Trips: runs of visits away from home, ended by a
visit at home or a gap of more than 4 days; path home → visits → home, distance = length of these great-circle paths.
Country of a visit: the server's country code of most of its photos, else its place's. Per year (a visit or trip
counts in each year it touches): trips, places, countries, distance, photo count, farthest place from home. Year in
Review and widgets can use `TravelHistory(items).stats(in: year)`.
**TG-2 Globe.** SwiftUI `Map` with `.hybrid(elevation: .realistic)` (MapKit draws the earth as a globe when zoomed
out), opening on home from 45 000 km. The trips' legs are geodesic `MapPolyline`s, each pair of places once (wider the
more trips used it, brighter the more recently), the selected trip in white on top; places are markers (the
40 with most photos as photo thumbnails, the rest as dots, home as a house); tapping a place opens its photos (of the
year shown). A bottom panel shows the year (or "All years"), the stats line ("37 countries · 412,000 km", miles where
the locale uses them) and the trips newest first; tapping a trip flies the globe to it and offers its photos. A year
filter menu and "Countries" are in the toolbar. Entry points: the Travel card at the top of Places (with the stats
line) and the globe button in the Map's toolbar (the Map exists on every server, Places needs `places`).
**TG-3 Countries.** A count with the share of the world's 195 countries, and per continent either the visited
countries (flag, name, years, photos; opens their photos) or a "scratch map" of every country's flag, the visited ones
in colour. Countries come from the index; for places without one, "Look up countries with Apple Maps" (MapKit
`MKReverseGeocodingRequest`, at most 40 places per run, one request per 1.5 s, answers cached on the device by 0.1°
coordinate) runs only after the user asked once, because it sends the place's approximate location to Apple.

Platforms: iOS, iPadOS, macOS, visionOS (same screens; full-screen player on iOS only).

### 15.7 Bring everything home: imports [import]

**Import Library…** (File menu on the Mac and iPad keyboard menu; Settings › Library › Import from Other Services… on
iPhone, iPad and Vision Pro) takes the user's photos out of other services into their Nextcloud, without duplicates, and
ends with a "Welcome home" summary. It replaces the round-3 Google Takeout import (§7.18.10), whose reader, sidecar
rules and journal it generalises.

- **Choosing.** One file picker for everything: ZIP parts as they are (read in place, never unpacked as a whole; ZIP64),
  unpacked folders, or folders holding the parts; several services at once. The start screen says how to get each export
  (takeout.google.com; privacy.apple.com › Request a copy of your data › iCloud Photos; Meta Accounts Center › Download
  your information, format JSON, high quality for Facebook and Instagram) with links. Files in iCloud Drive that are not on
  the device are downloaded first. On the Mac, **Import Photos Library** adds the Photos app's library (PhotoKit).
- **Sources** (`ImportPlanner`, one adapter each; every adapter takes the files the ones before it left):
  - *Instagram* (2018–2026): `media.json` (`photos`/`videos`/`stories`/`profile`, `taken_at`, `caption`),
    `content/posts_1.json`, `your_instagram_activity/{content,media}/…` (`posts_1`, `stories` → album "Instagram
    Stories", `reels`/`igtv` → "Instagram Reels", `profile_photos` → "Instagram Profile Pictures", `archived_posts` →
    archive, `recently_deleted_content` left out). Caption: the post's `title` when it has several photos, else the
    photo's. Capture time: `exif_data[].date_time_original` (elements merged), else the posting time.
  - *Facebook* (2018–2026): every index below `your_facebook_activity`, `your_activity_across_facebook` or
    `photos_and_videos`: albums (`album/<n>.json`, named), posts (caption: the photo's `description` or the post's text;
    place: the post's check-in), uncategorized photos, videos, stories; `archive` → archive, `trash` left out. Capture time:
    `exif_data[].taken_timestamp` when plausible, else `creation_timestamp` (posting time). Video stills and subtitles are
    not photos.
  - Both: Meta's escaped UTF-8 (`CafÃ©`) is repaired; photos in conversations (`messages/inbox/…`) are left out (mostly
    other people's); index paths resolve against the export's root wherever the user picked it.
  - *Apple iCloud Photos data export*: parts `iCloud Photos Part n of m` (also translated), `Photo Details*.csv` per part
    (`favorite`, `hidden`, `deleted`, `originalCreationDate` "Tuesday November 19,2024 8:31 AM GMT", UTC, to the minute;
    rows belong to their own part because camera counters repeat), `Recently Deleted/` left out, `Albums/*.csv` (names
    across parts; Favorites is no album; Memories ignored), shared albums as folders, ZIPs inside parts unpacked one level
    deep. Rows without a file (Advanced Data Protection) are reported. A Live Photo video renamed `-1` finds its row.
  - *Google Takeout*: §7.18.10 rules, plus `favorited`, `archived` (→ archive) and `trashed` (left out), translated
    `metadata.json` names and the older `albumData` wrapper.
  - *Photos Library (Mac)*: the user's library with hidden photos, the resources the backup would take (original and
    edited version, RAW, Live Photo video; §7.18.2), originals in iCloud downloaded one at a time, favourites, user albums
    (also inside folders). PhotoKit gives no captions.
  - *Other photos* in the chosen files are imported as they are.
- **Nothing twice.** Within the chosen exports: copies in album folders once; the same photo in two services once (same
  name and size, or same kind, size and capture minute/second), keeping the copy with the more exact time and merging
  albums, caption and favourite. Against the server (per day of photos, one SEARCH as the backup does, §7.18.4):
  the backup matcher, then the same name and size, Apple's minute times (same minute with the same size or name, also
  whole hours apart for EXIF without offset), and Facebook/Instagram reduced copies (the capture second of exactly one
  server photo of that kind, proportions agreeing when the export knows the original size; never for a posting time). A
  file without a time in the export is matched by the time in its own EXIF once it is unpacked. Duplicates still get the
  export's favourite and albums.
- **Metadata.** The file is uploaded unchanged, except that a photo without its own capture time, position or caption
  gets them from the export written into its metadata (EXIF `DateTimeOriginal` + offset in the device's time zone, GPS,
  IPTC caption; metadata only, no re-encoding; JPEG, HEIC, PNG, TIFF; option "Give photos back their date and place").
  The capture time (or the posting time when nothing better is known) is sent as `X-OC-MTime`. Captions become file
  comments (stock), favourites `oc:favorite`, positions of files without one a PROPPATCH on Nextcloud 35+, hidden or
  archived photos go to the archive (`/.archive/…`, §7.13), albums are recreated (names merged with existing ones).
- **Where.** `<upload folder>/<service>/<year>` (`Google Photos`, `iCloud Photos`, `Facebook`, `Instagram`, `Photos
  Library`, `Imported`; folder names are not translated: they are server folders), options for the folder per service
  and per year; a warning when the folder is outside the timeline folders.
- **Running.** Up to three uploads at a time while the next day's search runs; one file at a time is unpacked or exported
  (free space checked before each: the import stops with "not enough free space" rather than filling the device). A
  journal per plan makes it resumable (stop, quit, crash); the chosen files are remembered as (security-scoped)
  bookmarks, so the start screen offers "Resume Import" after a relaunch. A finished import of the same files run again
  checks everything against the server again. iPhone/iPad: a continued processing task (`<bundle>.backup.import`, under
  the backup's permitted wildcard) with the system's progress and Stop; when the system does not start one the app runs it
  while open. Mac: the import goes on with the sheet closed and keeps the Mac from sleeping.
- **Welcome home.** Photos of the import fan out like prints, "Welcome home", the number of photos and videos counts up,
  albums and years ("4 albums · from 2004 to 2026"), "Nothing lost" (or "3 not imported — see below"), a chip per
  service, what was uploaded, already there, merged, favourites, captions, dates given back, archived, and what was left
  out and why (deleted, conversations, missing ZIP parts, unsupported files, unreadable indexes, listed without file) with
  examples. "Nothing lost" means every photo the exports hold arrived, apart from what is left out on purpose. Reduce
  Motion shows it without animation. A report file (plain text) is kept in the account's directory, shared from the
  summary, and uploaded to the destination folder.
- **Decisions.** No server change. Facebook/Instagram posting times are used as the file time when nothing better is
  known, but never written as a capture time into EXIF. Unsupported files are counted as not imported rather than
  uploaded into Files. Meta's message photos are excluded. Google Photos' people names and shared-album comments are not
  imported (no stock place for them).

### 15.8 Smart offline and fun extras: stickers, collages, photo of the day [extras]

#### 15.8.1 Smart offline

The app keeps, on its own, the photos the user is most likely to want without a connection, within a storage budget.
Settings › Storage › Smart offline: **Space to use** Off / Small (1 GB) / Medium (5 GB) / Large (20 GB) — *decided:*
Small by default on every platform (a device setting, the same for all accounts); **Keep originals** (off: photos are
kept as previews of 2048 px on the long edge, which fill an iPhone or iPad screen); what it uses now ("1.2 GB · 1,840
photos") and what that covers ("your photos since August 2026, 210 favorites, 12 photos of the coming days' memories and
photos of 2 albums you opened recently").

- **What is wanted** (`SmartOfflinePolicy`, pure and unit-tested): every photo gets a score for each reason that applies,
  the highest counts. *On this day* in the next 7 days of an earlier year: 1.0 (−0.01 per day further away); taken in the
  last 12 months: 0.9 halving every 60 days; in an album opened in the last 30 days: 0.6 halving every 7 days; favourite:
  0.35–0.55 (newer a little higher). The best-scored photos are wanted until their sizes (real ones once downloaded, an
  estimate learnt from the kept previews before) fill the budget; a smaller one further down still takes a gap.
- **Never**: archived photos, Live Photo videos, photos in excluded (`.nomedia`) folders, photos an offline album (§7.19)
  keeps already (those are separate, not counted in the budget, and stay as they are). Videos are kept as previews
  (a still) even with "Keep originals": one video would take the room of hundreds of photos; offline albums keep videos.
- **Eviction**: a kept file whose photo is gone, archived, changed (ETag) or kept at the other quality is removed in the
  next pass. A file that no reason applies to any more stays until its room is needed; then the least recently used go
  first (LRU: a file's modification date is set when the image pipeline reads it, at most once a day). Off removes all.
- **When**: removing happens in every pass. Downloading needs an unmetered network (Wi-Fi/Ethernet; not cellular, a
  hotspot or Low Data Mode) and no Low Power Mode. iPhone/iPad: a `BGProcessingTask` (`com.nextcloud.photos.offline`)
  that requires external power and network (charging, usually at night); in the foreground, after a sync, at most 150
  files per pass (every 10 minutes at most). Mac: an hourly `NSBackgroundActivityScheduler` activity, deferred while the
  Mac is busy or in Low Power Mode. Vision Pro: while the app is open.
- **Storage**: the account's `SmartOffline` folder (Application Support, excluded from backups, removed with the account),
  outside the caches, so a cache trim never touches it; table `smartOfflineFile` (migration `v5-smart-offline`) and
  `smartOfflineAlbumView` (when an album was opened).
- **Use**: the image pipeline asks smart offline for a kept preview at least as large as the bucket before the network
  (decoded to the size asked for, not copied into the cache); kept originals serve like those of offline albums.
- **Visible**: the Info panel says "Available offline" for photos kept by smart offline or an offline album; the offline
  banner over the grids says what can be looked at in full ("Available in full: your photos since August 2026 and 210
  favorites."); other photos show their cached tiles or blurhash. *Not done:* a badge on grid tiles (the grid is another
  package's; Photos.app has no such badge either).

#### 15.8.2 Stickers

- **Make Sticker** (viewer › More, photos): the 4096 px preview (else 1024) is segmented on the device with Vision's
  `VNGenerateForegroundInstanceMaskRequest`; all subjects that are not specks (≥ 1 % of the picture) are lifted
  together, as Photos does. Styles: Cut-out, Outline (white border, faint shadow — the default), Shadow, Comic; at most
  1024 px. Share (transparent PNG through the share sheet), Copy (PNG on the pasteboard), Add to Sticker Book. On
  iPhone and iPad the sticker carries VisionKit's subject interaction: touch and hold shows the system's menu, which
  offers "Add Sticker" for the system's stickers (where the system offers it; the app cannot add to them itself).
  PNG and HEIC with transparency are both produced by `StickerMaker` (the share sheet uses PNG, which every app takes).
- **Sticker book**: a Collections/sidebar entry "Stickers": the stickers made in the app, per account, on this device
  (PNG files plus a JSON list in the account folder; removed with the account). People's packs first, then the others;
  context menu Share, Copy, Delete. Not uploaded.
- **Sticker pack of a person** (People › person › menu › Make Sticker Pack, named people): up to 8 photos of the person
  where the face (Recognize's detection box) is at least 6 % of the picture's width, favourites first (up to half), the
  rest spread over time, largest faces first; in each only the subject that holds the face's centre (or overlaps it
  most) is lifted, so people standing next to them are left out. The stickers appear one by one and go into the book
  under the person's name.
- Segmentation is not available in the simulator (the sheet says so); it runs on devices and Macs with Apple silicon.

#### 15.8.3 Collage and card

- From a selection (grid › More › Create Collage, 1–12 photos), an album (album options) or a memory (memory ›
  More › Create Card: up to 6 photos chosen by `CollagePicker` — favourites first, at most half, the rest spread over the
  memory's time, the best one first — with the memory's title and dates).
- Layouts (`CollageLayouts`, pure and unit-tested): **Grid** (cells about square; a shorter last row fills the width),
  **Mosaic** (justified rows: the number of rows whose natural height fits best, then stretched to fill), **Prints**
  (instant-photo prints with a white border, turned up to ±6°, deterministic per shuffle), **Magazine** (one large photo,
  the others in a column or row, the title over the large photo on a shade). Every photo is cropped around its focus:
  the faces (Vision face rectangles, with room for hair and shoulders) or else the attention-based salient objects;
  when the focus does not fit, its top is kept.
- Title and subtitle, four themes (Classic white, Night, Paper with a serif title, Ocean in Nextcloud blue), formats
  Square, Portrait 4:5, Landscape 3:2, Story 9:16. Editing: tap a photo, then another to swap them; Shuffle; Remove Photo.
- Export: Share (JPEG, 3000 px on the long edge, or a one-page PDF at print size: 8×8 in, 8×10 in, 9×6 in, 4.5×8 in),
  rendered with the 4096 px previews when a destination asks for it; **Save to Nextcloud** uploads the JPEG as
  "Collage <date time>.jpg" into the upload folder (`photosLocation`) and syncs.

#### 15.8.4 Photo of the day

- Settings › Photo of the Day: off by default; turning it on asks for permission to notify (alerts, no push
  registration); a time (default 9:00).
- Choice (`PhotoOfTheDay`, pure and unit-tested): a photo taken on this very calendar day in an earlier year, else within
  ±3 days, else a favourite not shown in the last 60 days (a repeat only when nothing else is left). Scored: favourite
  +3, a recognised person +1.5, ≥ 2 MP +1, a place +0.25, a panorama or sliver −1; screenshots, PNG/GIF graphics and
  pictures under 0.5 MP are never chosen; ties are broken by a hash of the day, so the choice is stable for a day.
  Never an archived photo, a video, a Live Photo video or anything in an excluded folder.
- Local notifications for today (if the time is still to come) and the next days (3 in all), each with its photo as a
  1024 px attachment (the system shows it large when the notification is expanded; no content extension needed). They are
  scheduled again after syncs (at most every 30 minutes), when the setting or app lock changes and when another account
  is shown, so a photo archived meanwhile is replaced before its day. Text: "On this day 3 years ago · Lisbon", "This week
  2 years ago", "From your favorites · June 2019". With app lock on: "A photo from your library is waiting for you." with
  no photo, date or place. Tapping opens the photo in the viewer of its account (`nextcloudphotos://user@host/photo/<id>`,
  after the unlock). Pending ones are removed with their account.

## 16. M7 — Elegant and powerful

Round 6 (2026-11-25): 30 ideas to make the app more elegant, more fun and more powerful. No server changes. Each
subsection is owned by one work package (name in brackets).

### 16.1 Library: moments, scrub to peek, range select, story cards [library]

**Moments.** The Library's days are grouped into named moments ("Sunday in Lisbon", "Anna’s birthday", "Hike near
Zermatt"), computed on the device from the local index (`LibraryMoments`, PhotosDomain).
- *Grouping.* A moment is one local calendar day (the grid's day sections, so ids and the scrubber stay as they are), or
  a run of consecutive days away from home at one place: same main place, or the same foreign country, at most 36 h
  between the photos of two days, at most 7 days. A day without any place between two days of one stay belongs to it
  (a camera without GPS that day); at the end of a stay it does not (that may be the day back home). Home is the place
  that is the main place of the most days (at least 3).
- *Titles* (rules, in this order; `MomentTitle`, localised in the PhotosDomain catalog): an event the device recognised
  in the photos — a birthday ("Anna’s birthday", after the named person seen most, else "Birthday"), a wedding,
  Christmas (December and January only); an activity — skiing, hike, concert, camping, beach, snow, mountains ("Hike near
  Zermatt"; the place only away from home); a day away ("Sunday in Lisbon"), a weekend away ("Weekend in Lisbon"), a
  longer stay ("3 days in Lisbon"), two places ("Lisbon & Porto", the second with at least half as many photos); a day
  with named people ("Sunday with Anna and Ben": people in at least 30 % of the photos or in 3 of them; Recognize's
  unnamed clusters and people hidden on this device are never used). Activities come from the on-device labels of
  Settings › Search (`visionLabel`, current version of the file only) with a minimum share of the moment's labelled
  photos (10 % for events, 20–40 % for scenery). Fewer than 3 photos, or nothing of the above (a day at home with
  nobody named): no title, the day keeps its plain header ("where it reads well").
- *Nicer titles.* Where Apple Intelligence's on-device model is available and speaks the user's language
  (`SystemLanguageModel`), the newest 24 titled moments of each build are worded by it, one at a time, not in Low
  Power Mode. It only gets the moment's facts (days, places, country, people, activities; `MomentTitleWording`); an
  answer is kept only if it has at most 6 words and 40 characters, no year or date, emoji, hashtag or line break, and
  names the moment's place (away), person (birthday, a day with people). Kept titles are stored per moment with the
  facts they came from (table `momentTitle`, migration `v6-library-moment-titles`) and used while those facts stay
  the same; otherwise the rule title is shown. Nothing leaves the device.
- *Where.* Library, unfiltered (all media, no rating filter): the header of a moment's newest day shows the title before
  the day on the same line ("Sunday in Lisbon ›  Sun 22 Nov"; header heights do not change, so scrolling and the
  scrubber stay exact). The Days level shows the title above the moment's newest day. A tap (click on the Mac, pointing
  hand cursor) on the title opens the moment as a memory: its grid, Play Slideshow (the memory film), Save as Album,
  Share as Link, music (`MemoryScreen`, kind trip). VoiceOver: the title line is a button "Sunday in Lisbon, Sun 22
  November" with the hint "Opens the moment".
- *Cost.* Built after each sync (and when the day or the excluded folders change) off the main actor from five columns
  of every visible item plus the named people and the label rows that contain an activity word: 100 000 items in
  0.22 s in a debug build (unit test budget 3 s). Titles appear in place without a relayout.
- Settings › Library display › "Name moments" (on by default).

**Scrub to peek.** Videos, Live Photos and stacks can be looked into without opening them.
- iPhone, iPad, Vision Pro: hold a finger on the tile for 0.2 s, then slide sideways: the tile shows frames of the
  video (8, spread over its length), of the Live Photo's motion (6), or the stack's copies (one segment each), following
  the finger across the tile, with a bar along the bottom (position in the video, or which copy). A quicker move
  scrolls; holding still lets the context menu come; letting go ends it. iPad pointer (trackpad, mouse) and Mac: the
  pointer resting on the tile for 0.25 s starts it, moving across scrubs, leaving ends it. Not while selecting.
- Low cost: frames are decoded at the tile's size with a key-frame tolerance, the one under the finger first; a video
  that is not on the device is read through the app's HTTP client (byte ranges, as for playback), without a player.
  Leaving the tile, scrolling or a change of the grid cancels the loading. The frames of the last 8 peeks are kept in
  memory. Formats the system cannot play are not peeked into.

**Range selection.** iPhone, iPad, Vision Pro: in the selection mode a finger that slides sideways over the tiles selects
everything from the tile it started on to the tile under it, in the grid's order (or deselects, when it started on a
selected tile); moving back gives the tiles left behind their state from before the drag. Dragged into the top or
bottom 64 pt of the grid it scrolls, faster towards the edge (up to 1600 pt/s). A vertical move still scrolls. A
two-finger drag starts the selection mode and selects as in Photos (UIKit's multi-selection, unchanged). Mac: ⇧-click
selects the range, ⌘-click single tiles, dragging on the background draws a selection rectangle (NSCollectionView, as
before).

**Story cards.** The memories at the top of the Library (On this day, the year in review, recent trips; at most 12) are
story cards by default: one large card at a time on iPhone (the next one peeks in), several side by side where there
is room; a fixed band of 184 pt on iPhone, 220 pt on iPad, 210 pt on the Mac (no empty band, as the strip since round
4). The card in front plays: up to 6 photos (the cover, then photos spread over the memory) follow one another every
4 s with a slow zoom (a cross-fade with Reduce Motion), with a bar per photo; a tap on the trailing two thirds goes on,
on the leading third back (mirrored right to left); after the last photo the next card comes to the front. The title
opens the memory, the play button its film; with the pointer, chevrons appear. VoiceOver: one element per card (title,
dates, count, "Photo 2 of 6"), swipe up/down steps through the photos, double-tap opens; no auto-advance while
VoiceOver runs. The card's context menu: Play Slideshow, Show as Strip, Hide Memories. Settings › Library display ›
Memories: Stories or Strip (the strip's context menu has Show as Stories).

### 16.2 Search: command palette, natural-language search with chips, photo descriptions [search]

**Command palette ("Quick Actions", ⌘K).** One field that goes anywhere and does anything.
- *Where.* ⌘K on the Mac (Go ▸ Quick Actions…) and on iPad or iPhone with a keyboard (the same command gives the
  shortcut); the ⌘ button in the Search tab's toolbar on iPhone, iPad and Vision Pro (the Mac window's toolbar button was
  removed in M10, §19.2). A floating panel over
  the window (Mac, iPad, Vision Pro; a click or tap outside closes it, as Spotlight), a sheet on iPhone (compact width).
- *What it finds* (`CommandPalette`, `CommandPaletteCatalog`, read from the local index each time it opens): the app's
  places (with words people use for them: "trash" finds Recently deleted, "settings backup" finds Backup), the Mac's
  Settings pages ("General Settings"… opens that tab of the Settings window), own and shared albums, people, places,
  tags (not the rating and flag tags), the years of the library (with their photo count; choosing one searches it),
  and commands: New Album, Upload Photos, Import Library, Import from Camera or Card, Open Public Album Link, Sync Now,
  Slideshow, and on the selection of the grid or viewer that had the focus when the palette opened: Add to/Remove from
  Favorites, Add to Album…, Add to New Album…, Open, Get Info, Edit…, Edit Date and Location…, Rotate Left/Right,
  Export, Compare, Pick, Reject, Unflag, Delete…. Commands are offered only where the grid or viewer offers them (no
  rating on a read-only share). Wording follows the platform (title case on the Mac).
- *Typed intents.* "add to Summer" / "add to album Road trip" / "put in summer" lists the best matching albums (at most
  5) as "Add to “Summer”" entries for the selection; "rate 4", "4 stars", "★★★★" rates it (0 clears).
- *Words as a search.* The typed words are also read as a search (`NaturalSearch`, below): when they make two or more
  chips ("Lisbon 2019", "favourites of Anna"), the first entry is that search ("Lisbon · 2019"), unless a name is typed
  exactly (the album "Lisbon 2025" stays first, its search second). The last entry always searches for the words.
- *Matching* (`FuzzyMatch`): case and diacritics ignored; every typed word must match a word of the name or of its
  keywords — whole word 1.0, start of a word 0.9, start of the whole name across words 0.75 ("newal"), inside a word
  0.6, one typo in words of four letters or more 0.45 ("lisbn", "lsibon"), letters in order 0.3 × density ("lsbn").
  Keywords count three quarters. Bonuses for the name's word order and for typing the whole name; names with more
  other words rank slightly lower. Recently chosen entries rank higher (+0.12 for the newest) and are shown first when
  nothing is typed, followed by the selection's commands and the places. At most 40 entries.
- *Keyboard.* ↑/↓ move the highlight (the list follows), Return runs it, Escape closes; hovering highlights on the Mac.
  VoiceOver reads each entry as "title, detail, kind".
- *Recent entries* (8) are kept per account in its directory (`palette-recents.json`) and go with the account.

**Searches typed in words, with chips.** "videos of Anna at the beach last summer" → Videos · Anna · beach · Summer 2026.
- *On the device, deterministic* (`NaturalSearch.interpret`, instant, on every pause in typing): read left to right,
  the longest of: a date (`SearchDates`), a rating ("5 stars", "4+ stars", "three-star", "★★★", "rated 3", "at least
  3 stars"), a media kind ("videos", "clips"; "photos only", "stills", "no videos" → still photos) or favourites
  ("favourites", "faves", "loved"), a name the library knows — a person (also by first name when only one person has
  it; possessives "Anna's"), a place, a tag, an album only next to the word "album" ("album Summer", "summer album") —
  else a filler word ("of", "at", "the", "photos"…) is dropped, a word photos show becomes a "shows" chip (the labels
  this device recognised, SR-7, and ~100 common words; plurals: "dogs" → dog), and what is left is one free-text chip,
  so plain text searches as before. A person wins over a date after "with"/"of" ("with Jan"), a place after "in"/"at".
- *Dates in many forms* (`SearchDates`, the user's calendar, month names in English and the user's language): years,
  "2018-2020", "2018 to 2020", "between June 2020 and March 2021", "since 2020", decades ("90s", "1980s"), months with or
  without a year (without: the last one that has begun), "3 March 2021", "March 3rd", "2021-03-03", "2021-03", seasons
  ("summer 2019", "summer of 2019", "last summer" = the last one that is over, "this summer"; winter 2019 = December
  2019 to February 2020; reversed in southern-hemisphere regions), holidays (Christmas = 24–26 December, Christmas
  Eve, New Year's Eve/Day, Halloween, Valentine's Day, Easter = Good Friday to Easter Monday; with or without a year),
  today, yesterday, this/last week, weekend, month, year, "last June", "3 years ago", "two months ago", "last 10 days",
  "recently" (30 days).
- *Apple Intelligence* (`NaturalSearchModel`, OS 27, where `SystemLanguageModel` is available): after a 0.6 s pause and
  for two words or more, the on-device model reads the words into a guided-generation struct (media type, people,
  places, things, first/last day, favourites, least rating); the answer is checked against the library (people and
  places must be known ones, things one or two plain words, dates real dates). `NaturalSearch.merge`: the parser's
  chips stay; the model adds kinds the parser did not find ("seaside" → beach); when it added something, the parser's
  left-over free text goes. The row then shows a sparkles symbol. Without Apple Intelligence the server's Assistant
  stays available as "Ask" (SR-4), unchanged.
- *In the search screen* the understood chips are a row on top of the suggestions ("Search for Videos, Anna, beach,
  Summer 2026" for VoiceOver); a tap or Return applies them (replacing a date, media-kind or rating chip already
  there). Single names keep the existing suggestions and Return behaviour.
- *Editable chips* (`SearchChipBar`, all platforms; on the Mac in addition to the field's tokens): a tap opens the
  chip's menu — dates: the period before/after (a year by a year, a month by a month, a week by a week, a season or
  holiday to the same days of another year, keeping its name: "Summer 2018"; never into the future) and Choose
  Dates… (two date pickers); person/place/tag/album: another one; Videos ↔ Photos; rating: 1–5 stars or more; words:
  Change Words…; and Remove. Results follow every change. The result count is beside the chips.
- *New chip kinds*: `.photos` (still photos only), `.label(word)` (searched in all indexed text: labels, descriptions,
  tags, captions…), `.rating(atLeast:)` (the rating tags of §15.2). They are stored in recent searches; smart albums
  keep storing only what the web app's filters know (places, dates, names, tags).
- *Camera* is not a chip: the index has no camera make/model (it would need `nc:metadata-photos-ifd0` in the sync).

**Photo descriptions.** A short sentence per photo, written on the device: "A dog on a beach at sunset".
- *How* (`PhotoDescriber`): Vision on the cached preview (1024, else 256, decoded at 512 px) — the image classifier
  (labels at 90 % precision), face rectangles (faces of a reasonable size), fast text recognition (the three largest
  lines). With Apple Intelligence: the on-device model writes one sentence of at most 15 words from the picture itself
  (image attachment, when the model has the vision capability) and Vision's facts, in the user's language, with
  instructions not to guess names, ages, feelings or brands; temperature 0.2. Without it (or when it fails):
  `PhotoDescription.compose` writes an English sentence from the facts (subject: faces as "a person", "two people",
  "a group of people", and the most specific non-generic label; a scene with its preposition; light/time "at sunset";
  text "with the text “…”"). Every answer is cleaned (one line, no wrapping quotes or "Description:", no full stop,
  refusals dropped, at most 140 characters cut at a word).
- *Stored* per version of the file in the account database (table `photoDescription`: text — nil when the photo could
  not be described, so it is not tried again until its file changes —, language, source, time; migration
  `v6-search-descriptions`). Descriptions go with their photos (trigger). Never uploaded.
- *Search*: the description of a photo's current version is part of its full-text index text
  (`SearchDescriptions`: the v4 triggers with the description added, and triggers on `photoDescription`; a new file
  version drops the old description from the index). The words photos show feed the "shows" chips.
- *VoiceOver*: tiles (UIKit and AppKit grids) add the description to their label ("Photo, 13 January 2025 at 14:23,
  Favorite, A tower"), the viewer uses it when the server has no caption, and the info panel shows it as Description.
  Only descriptions in the user's language are read (`PhotoDescriptionLookup`, an in-memory cache of what tiles asked
  for, 4 000 entries).
- *When*: like Show Similar (§15.5) — a `BGProcessingTask` that requires external power on iPhone and iPad
  (`com.nextcloud.photos.describe`), an `NSBackgroundActivityScheduler` activity on the Mac, and while the Library is on
  screen a trickle of 8 photos at a time with 1 s pauses at background priority, which on devices with a battery runs
  only while charging (the language model is the heaviest on-device work of the app). Vision Pro only has the trickle.
- *Settings › Search*: "Describe photos" (on by default) with the number of photos described; off deletes every
  description and the index forgets them.
- The simulator cannot run Vision: nothing is described there.

### 16.3 Editing: non-destructive edits, RAW, Live Photo effects, visual undo history [edit]

#### 16.3.1 Non-destructive edits

The editor's result is an **edit recipe**, not a new file: a small versioned JSON document (crop, turns, straighten,
mirror, auto-enhance, filter, adjustments, RAW development, Live Photo effect and key photo) that every view renders on
top of the original. The original file is never changed by Done.

- **Where**: one file per photo in the user's own Nextcloud, `/.nextcloud-photos/edits/<fileId>.json` (decided against
  a sidecar `IMG_1234.edit.json` next to the photo). Keyed by **file id**: a photo moved or renamed in the web, the Files
  app or the desktop client keeps its file id, so its edit follows it; a sidecar would show up in every folder and break
  with every move. A copy is a new file without the edit. The **dot folder** keeps the recipes out of sight: the web
  Files app hides hidden files by default, the desktop client does not sync hidden files by default, and the Photos web
  app lists only pictures and videos (other clients show the original). A photo **shared with the user** is edited in the
  user's own folder: the edit is that user's view of it. **Deleting** a photo leaves its recipe (a few hundred bytes), so a
  photo restored from the trash bin comes back with its edit; recipes of photos deleted for good are removed after a
  full reconcile (§22.5.3).
- **Format** (`EditRecipe`): `{"format": "nextcloud-photos-edit", "version": 1, "updatedAt": …, "original": {name, etag,
  width, height}, "geometry": {rotation, straighten, flipped, aspect, aspectLocked, crop{x,y,width,height}},
  "adjustments": {…}, "filter": …, "raw": {…}, "live": {effect, keyFrameTime}}`. Only values that differ from
  "unchanged" are written. Unknown keys, filters and effects are ignored; broken values fall back to "unchanged"; a crop
  is kept inside the picture. A recipe of a **newer version** is not applied (the original is shown) and not lost: the
  editor says "edited with a newer version" and only saving there replaces it.
- **Sync** (`EditLibrary`, per account, kept on the device in `Edits/recipes.json`): a save is shown at once and sent in
  the background; offline changes wait for the next sync. Every library sync takes over what other devices changed (one
  `PROPFIND` depth 0 of the folder; the listing and `GET`s only when its ETag changed). Writes are **ETag-safe**: `PUT`
  with `If-Match` of the version this device knows (`If-None-Match: *` for a new recipe), revert is `DELETE` with
  `If-Match`. On 412 the device reads the server's version and **the edit made later wins** (by `updatedAt`, the time the
  user made it); the replaced version stays in the server's file versions.
- **Everywhere**: grid tiles, the viewer, context menu previews, covers and the undo history show the edited rendition,
  rendered on the device from the server's preview (or, for a long exposure or another key photo, from the Live Photo's
  motion) and cached under `<etag>_e<digest>` (the digest of what the recipe renders), so a changed edit never shows an
  old picture and a reverted one shows the server's preview at once. Export and Share render the recipe on the
  full-resolution original (`<name> (edited)`, HEIC for HEIC originals, else JPEG, metadata kept); the viewer's More menu
  has **Export Original… / Save Original to Photos** and **Share Original**. Edited Live Photos are saved to Photos as a
  still. Grids in aspect-ratio mode keep the original's tile shape (the edited picture fits inside it).
- **Editor**: re-editing starts from the recipe. **Done** saves the recipe. The More menu has **Save as Copy** (a real
  file next to the original, as before), **Overwrite Original…** (kept, but secondary and with a confirmation: the edit
  is written into the file, the previous version stays in the file versions, and the recipe is removed since it is part
  of the file now; not for read-only shares, formats Image I/O cannot write, or a JPEG developed from its RAW) and
  **Revert to Original** (removes the recipe on all devices; undoable).
- **Image ▸ Rotate** (menu, ⌘R/⌥⌘R, context menu, viewer) is a turn added to the recipe: undoable, works on read-only
  shares and RAW files, and no longer uploads a new version of the file.

#### 16.3.2 RAW

- RAW files (any type conforming to `public.camera-raw-image`) are developed with Core Image's RAW decoder
  (`CIRAWFilter`) in the editor (2048 px proxy, full resolution on save/export) and, on demand, in the viewer (**RAW**
  button: the whole file is downloaded and developed at up to 4096 px with the photo's edit).
- RAW tool: exposure, white balance (temperature and tint, starting from the camera's), shadow boost, highlight recovery
  and noise reduction (offered where the decoder supports them for the camera), "Camera Settings" resets.
- **RAW+JPEG**: the editor finds the other file of the pair (same folder and base name, as the stacking rule). Editing the
  JPEG offers **Edit RAW** (develop the RAW instead); editing the RAW develops it. The recipe is saved for both files: the
  RAW renders it developed, the JPEG stays the quick preview and shows the RAW settings approximated with ordinary filters
  until the RAW itself is decoded. Re-editing a pair developed before goes on with the RAW.

#### 16.3.3 Live Photo effects

- Editor **Live** tool: Live (default), **Loop**, **Bounce**, **Long Exposure**, and **Key Photo** (a slider over the
  motion; "Use the Original Key Photo" goes back). All in the recipe; nothing is written into the files.
- Long exposure: 48 frames sampled evenly from the motion and averaged pixel by pixel (`FrameAverager`). Another key photo:
  the motion's frame at that time. Both replace the still everywhere (grid, viewer, export).
- Loop and Bounce play by themselves, muted, in the viewer (with Reduce Motion only while pressed). Loop plays the motion
  itself (a video with the edit's look on every frame when the photo has adjustments), Bounce a forward-and-back video
  made once and cached. The badge says the effect.
- Export: **Share Loop/Bounce as Video** (MP4, three rounds) and **as GIF** (15 fps, 480 px, loops for ever) in the viewer's
  More menu — through the share sheet, which also saves to Files or Photos.

#### 16.3.4 Undo history

- Every undoable change of the session is recorded (newest first, at most 50): favourites, archive, delete, remove from
  and **add to album** ("Added 12 items to Summer", now undoable), **edits** ("Edited IMG_1234"), **rotations** ("Rotated 3
  photos") and reverts. The history lives as long as the session (like the undo manager).
- **Panel**: Edit ▸ **Undo History…** (⌥⌘Z) on the Mac and iPad keyboards; "Undo history" in the selection's More menu and
  in the viewer's More menu on iPhone and iPad. Each row: up to three thumbnails of the photos (edited renditions), what
  happened, when, and **Undo** — for any entry, not only the last. Undoing an entry does not undo the ones after it. When
  an entry cannot be undone the row says why: already undone, deleted for good (no trash bin), photos shared with the
  user, or "Edited again since" (a later edit, here or on another device, replaced it).
- Undoing from the history goes through the window's undo manager when the entry is on top of it (so Edit ▸ Redo offers it
  again); otherwise the registration is retired so ⌘Z never takes the change back twice.

### 16.4 Organising: smart album builder, batch time/place/rename, GPX geotagging, folder rules, Shortcuts [organize]

Five tools for keeping a large library in order, on every platform of the main app (iPhone, iPad, Mac, Vision Pro; the
TV and watch apps are not affected). No server change: what has to be shared by the user's devices is kept as small JSON
files in the user's own Nextcloud, in the hidden folder `/.nextcloud-photos/` (`AppDataFiles`), and every write names
the version it replaces (`If-Match`, or `If-None-Match: *` for a new file), so two devices never overwrite each other
unseen.

#### 16.4.1 Smart album builder

- **Rules** (`SmartRule`, PhotosModel): conditions combined with *All*, *Any* and *None*, each condition can be negated
  ("is not"), and groups with their own All/Any/None give a second level (Anna AND (beach OR lake) AND NOT rejected).
  Conditions: person, place (name or country code), tag, own album, rating (at least n stars, the round-5 culling tags),
  flag (picked / rejected / unflagged), media type (photo, video, Live Photo, screenshot, RAW, panorama), favourite,
  date range, taken in the last n days, older than n days, folder (and below; `/Photos/Cam` does not contain
  `/Photos/Camera`), file name, any text (name, place, country, caption, folder: what the search's free text looks
  at), camera (make or model), lens, focal length, aperture, ISO (ranges, either end open).
- **Evaluation** (`SmartRuleEvaluator`, PhotosDomain) runs on the device over the local index: one read of the index
  gives the memberships (tags, people, own albums from the stored memberships of `LabelSync` and album contents), the
  ratings/flags and the camera details (`OrganizeStore.ruleContext`), and the rule runs in memory, so the builder
  counts while the user edits (cached for a minute, recounted 250 ms after the last change).
- **Camera details**: the index has no EXIF. The server's `nc:metadata-photos-exif`/`-ifd0` come in bulk with a
  SEARCH for up to 90 file ids at a time (`PhotosAPI.cameraDetails`; the server allows 100 operators and cannot sort
  by file id), stored in the table `cameraDetails` (migration `v6-organize-camera`) with the ETag they were read from.
  They are read only while some smart album or enabled folder rule asks about cameras: about 4 500 photos after each
  sync in the background, and all of them while the builder shows such a condition (with progress; the count grows
  as they arrive).
- **Builder** (`SmartAlbumBuilder`): name, live count with the first photos, the rules, order (newest/oldest first)
  and an optional limit. Entry points: Smart Albums (sidebar/Collections) "+", the Albums screen, Settings ›
  Organize; "Save as smart album" in the search saves into the same list (on extended servers with the server's
  `smartAlbums` setting the search keeps saving there, so the web app sees them; those are listed as "Saved on the
  web").
- **Shown with the albums**: a "Smart Albums" strip above the own albums and the Smart Albums screen (cover = first
  photo, count, context menu Edit/Duplicate/Delete); an album opens as a photo grid with "Edit Rules".
- **Sync between devices**: `.nextcloud-photos/smart-albums.json` (`{"version":1,"items":[…]}`), merged record by
  record (`SyncedList`): the newer `modifiedAt` wins, a change is always stamped later than the version it changes
  (clocks that are behind), deletions are tombstones for 90 days, records a newer version wrote and conditions this
  version does not know are kept unchanged (they match nothing here). The device keeps a copy (offline use; changes
  made offline are merged when the server is reachable). Smart albums that round 4 stored "On this device" move into
  the shared file once.
- *Decision:* Photos' own server-side album filters (extended servers) are not used for these: they cover only
  dates, places, names and tags, and the rules need people, ratings, cameras and NOT.

#### 16.4.2 Batch fixes

One sheet (`BatchFixSheet`) with four tabs, from the selection's context menu (Adjust ▸ Adjust Date and Time… / Set
Location… / Rename… / Geotag from GPS Track…), the Mac's Image ▸ Edit Date and Location…, and the viewer's More menu.
Every tab previews what changes; Apply shows progress, then a summary with what was not changed and why, and **Undo**
(also Edit ▸ Undo / ⌘Z / shake, registered with the window's undo manager).

- **Date and time**: shift by days/hours/minutes, or "set the first photo to" a date (the shift follows; intervals
  stay). **Time zone**: "taken in another time zone" keeps the wall-clock time the camera recorded and says in which
  zone it was (the zone's offset on that day, so summer time is right); the recorded time is the capture time in the
  photo's own offset, or in UTC when it has none, because Nextcloud reads an EXIF time without offset as UTC.
- **Place**: one position for all, picked on a map (tap) or found by name (MapKit search); grey dots show where the
  photos are now; "only photos without a location"; or remove the location.
- **Rename**: a pattern with `{date}`, `{time}`, `{place}`, `{country}`, `{camera}`, `{name}`, `{year}`, `{month}`,
  `{day}`, `{counter}`/`{counter:N}` (token buttons), a start number; the counter follows the capture time; names
  that are taken in the folder (or within the batch) get " (2)"; forbidden characters become "-"; the extension stays
  and a Live Photo's video gets the same name. MOVE with `If-Match` per file; undo moves back.
- **How dates and places are written**: on servers with metadata editing (Nextcloud 35+, `metadataEdit`) through the
  existing outbox operation (PROPPATCH, optimistic, offline-safe). On older servers the importer's approach: the
  original is downloaded, its EXIF (`DateTimeOriginal` + offset, GPS) rewritten without re-encoding
  (`MetadataRewriter`, JPEG/HEIC/PNG/TIFF) and uploaded over the version the index knows (`If-Match`): the server
  reads the new values like any photo's (checked: it re-reads EXIF date, offset and GPS on overwrite), and the old
  version stays in the file's versions. Videos and other formats are skipped there, and the sheet says so before.
  Undo writes the previous values the same way.

#### 16.4.3 GPS track geotagging

The fourth tab, or Settings › Organize › "Geotag photos from a GPS track…" for the whole library. GPX (`trkpt`,
`wpt`, `rtept` with times) and KML (`gx:Track` with `when`/`gx:coord`, placemarks with a `TimeStamp` and a point);
several files at once are one track. Each photo gets the position at its time: interpolated between two points up to
15 minutes apart, else the nearest point within the tolerance (1–60 min, default 5). The camera clock correction
(±14 h in quarter hours) is suggested: the offset that puts the most photos on the track, or, when at least three of
the photos already have positions, the one that agrees with them (within 1 km). The map shows the track and each
matched photo's thumbnail before anything changes; by default only photos without a location are tagged; library-wide
it looks at own photos taken within 14 hours of the track. Writing as in 16.4.2.

*Decided:* no track recording in the app. Recording a track in the background needs "Always" location permission and
the background location mode (Info.plist, App Store review), and the user's phone, watch or sports app records better
tracks already; exporting GPX/KML from them is the supported way. iPhone location history is not accessible to apps.

#### 16.4.4 Folder rules

Automations that run after each sync (Settings › Organize › Folder Rules): **when** a photo matches a rule (the same
conditions as smart albums), **then** add to an album, archive, favourite or tag (albums and tags are created when
missing). Examples to start from: "new in a folder → album", "screenshots older than 30 days → archive", "★★★★★ →
album Best of". A rule acts on photos uploaded after it was made, or also on those already there (switch). Editor with a
preview of what the rule would act on now.

- Stored in `.nextcloud-photos/folder-rules.json` (merged like smart albums), so all devices have the same rules.
- **One device at a time**: before running, a device takes the lease `.nextcloud-photos/folder-rules.lock` (holder id
  — a random id per installation and account — device name, expiry 10 minutes); taking it is a conditional write, so
  two devices cannot both win; it is released after the run and expires when a device goes away.
- **State and log** `.nextcloud-photos/folder-rules-state.json`: the file ids each rule has handled (a photo is handled
  once — taken out of the album again, it stays out) and the last 200 runs (rule, count, device, error), shown in the
  Folder Rules screen. At most 500 photos per rule and run; the actions go through the outbox (offline-safe, retried).
  Runs at most every 2 minutes ("Run Rules Now" forces one); rules with conditions a newer version wrote, or an
  unknown action, do not run here.

#### 16.4.5 Shortcuts

App Intents (`App/Shared/OrganizeIntents.swift`; the work is in `SessionModel+Intents`, PhotosCore) with a
`PhotoEntity` (string query = search, suggestions = newest) and a `MemoryEntity`, next to round 4's `AlbumEntity` and
`PersonEntity`, so actions chain in Shortcuts and personal automations: **Find Photos** (words — people, tags, places,
text, years — person, album, favourites, type, dates, limit → photos), **Create Album from Search** (also an App
Shortcut with a Siri phrase), **Add Photos to Album**, **Rate Photos** (0–5), **Flag Photos**, **Favorite Photos**,
**Archive Photos**, **Export Photos** (originals as files), **Share Photos as Link** (quick share → URL), **Show Photo**,
**Show Memories** (On this day for a memory of this day), **Get Photos of Memory**; backup has "Back up photos to
Nextcloud" (round 4) and the controls' intents (round 5). Entities belong to the account shown; a photo of another
account does not resolve.

### 16.5 Photographer: stats, loupe and filmstrip culling, Continuity Camera, Mac menu bar extra [pro]

For people who shoot a lot: learn from their own photos, go through a shoot full screen, get a picture from the phone
into the right album, and drop files on the server without opening a window. Builds on the culling tags of §15.2.

**16.5.1 Insights (all platforms).** A destination "Insights" (sidebar section Utilities, the Collections list on
iPhone, Go menu) with cards: Cameras and Lenses (ranked bars, six then "Show All"), Focal Lengths, Apertures, ISO and
Shutter Speeds (bar charts), Time of Day (24 bars), Keeper Rate by Lens. Every bar opens its photos in the usual grid
("35 mm", "ƒ/2.8", "Nikon D700", "Keepers: <lens>"); on the Mac a hovered bar shows its count; VoiceOver gets the bars
of a chart as buttons.
- Data: the server's EXIF (`nc:metadata-photos-exif` and `-ifd0`, filled by stock Nextcloud 28+; no Photos API needed).
  The local index has no EXIF, so it is read lazily in the background and kept in table `photoExif` (migration
  `v6-pro-exif`: camera, lens, focal length, 35 mm equivalent, f-number, ISO, exposure time, hour, ETag). Reading starts
  when Insights is opened and continues while the app runs: libraries with 1000+ photos to read are paged through the
  timeline folders newest first (SEARCH, 500 per request, keyset on the capture time), the rest is asked for by file id
  (50 per request), with 250 ms between requests. A photo the server does not return gets an empty row; rows carry the
  index's ETag, so a photo is read again only after the sync saw it change. The header shows "Reading camera data: N of
  M photos" meanwhile; numbers refresh at most every 3 s.
- Parsing: camera = maker and model said once in the maker's usual spelling ("NIKON CORPORATION"/"NIKON D700" → "Nikon
  D700", Apple models alone); lens from `LensModel`; rationals and APEX values (`ApertureValue`, `ShutterSpeedValue`)
  understood; placeholders ("----", "0") and absurd values dropped; the hour from `DateTimeOriginal` (camera clock = local
  time), else from the capture time in the photo's own offset, else this device's zone.
- Buckets on a logarithmic scale (nearest stop): focal lengths of common lenses (4 … 1200 mm, the 35 mm equivalent where
  the camera wrote one, said in a footnote), f-numbers in thirds, ISO and shutter speeds in full stops. A bar's photos are
  the values between the geometric middles to its neighbours, the same rule in Swift and SQL.
- Keeper = Pick, or 3 stars or more without Rejected (Pick wins, as in §15.2). Rate = keepers / all photos of the lens
  (photos without a lens name count per camera); only lenses with 5+ photos, and only once anything was rated; until then
  the card explains P and 1–5.
- Scope: the library's photos (no videos, not archived, not in `.nomedia` folders). Only aggregates are computed, on the
  device.

**16.5.2 Culling view: loupe and filmstrip (Mac first, iPad, Vision Pro).** Image ▸ Culling View (⌥⌘L), the grid's
context menu: several selected photos are culled on their own, else the whole grid from the selected (or first) photo.
On the Mac it opens in a window of its own that goes full screen (the main window stays; a second display works; not
restored at relaunch); iPhone/iPad: a full-screen cover without status bar; Vision Pro: pushed.
- Layout: top bar (Close, name, date and time, "12 of 340", the mark, toggles), the photo on black, a control row (Previous,
  Pick, Reject, Unflag, stars 1–5, Next) and a filmstrip of 64 pt thumbnails (current one outlined and centred, marks on
  each, rejected dimmed; tap to go there).
- Loupe: a click (tap) toggles 100 % at the point clicked; press and hold shows 100 % while held, following the pointer;
  a drag pans the zoomed photo; Z or Space toggles 100 % at the middle; a swipe on the unzoomed photo goes to the next or
  previous one. 100 % = one image pixel per screen pixel, at least twice "fit" (a photo with about as many pixels as the
  screen would not change); above the 4096 px preview the original is decoded (RAW by Image
  I/O). The next two photos are fetched ahead.
- Overlays, computed on the device from the shown preview (CPU, no GPU or Vision): focus peaking F (Sobel gradient of
  the luma; the sharpest 6 % of the photo and never below an absolute floor, so a soft photo shows nothing; magenta),
  clipping warnings J (any channel at 254+ red, all channels at 1 or less blue, with the clipped share), histogram H
  (luminance and RGB, with clipping triangles, and the exposure line "35 mm ƒ/2.8 1/250 s ISO 400" from Insights' data,
  read from the server for that photo if needed). Overlays use a version of at most 2048 px, so at 100 % they are
  coarser than the photo. The toggles are remembered.
- Keys: P X U 0–5 as in §15.2 (outbox, Undo, confirmation) with auto-advance; ← → ↑ ↓, Home, End; Esc leaves 100 %, then
  the view. The Image menu's Flag and Rating work on the photo shown.

**16.5.3 Take photos and scan documents into an album or folder.** On the Mac, Continuity Camera: File ▸ Import from
iPhone or iPad ▸ Take Photo / Scan Documents / Add Sketch (and the same in the context menu) while the Library, an own
album or a folder is shown. A photo is uploaded as it comes (HEIC, JPEG, PNG; other formats as JPEG) named
`IMG_yyyyMMdd_HHmmss`, with its EXIF capture time; a scan becomes one JPEG per page (`Scan_yyyyMMdd_HHmmss_N.jpg`, pages a
second apart so they keep their order), because the library shows pictures, not PDFs. Destination: the album (uploaded
to the upload folder and added), the folder, or the upload folder. iPhone and iPad: Take Photo (system camera) and Scan
Documents (VisionKit) in the Upload menu (the account button's menu and the Collections tab's "+", §19.2) when the device has a camera. Uploads go through the manual-upload
queue (§7.17).

**16.5.4 Menu bar extra (Mac).** Off by default; Settings › General › Show in Menu Bar. An icon (upload arrow while
uploading or backing up) with a panel: account, Open Nextcloud Photos (opens a main window again when all were closed),
today's memory (On this day) as a picture that opens it, a drop zone for photos and videos with "Upload to <upload
folder | own album>", upload progress and result, the backup's state, Library, Albums and Settings. It works while no
window is open (the app keeps running when the last window is closed).

### 16.6 Films: through the years, film styles, SharePlay [films]

Builds on the memory films of §15.1 (`FilmPlan`, `MemoryFilmPlayer`, `FilmExporter`, beat detection).

**FS-1 Through the years.** A time-lapse of one *named* person's face across the years.
- *Entry*: the person's screen (Person menu ▸ Through the Years / Through the years), and a "Through the years" row in
  Memories with the named people (not hidden on this device, ≥ 6 photos, at most 12, most photographed first).
- *Needs*: Recognize on the server (its face clusters and boxes, stock Recognize DAV API). Without Recognize the row and the
  film explain that the Recognize app is needed; an unnamed person gets "Name this person first" with Add Name…; fewer than
  three periods with a usable face gives "not enough photos across time". No server change.
- *Selection* (`ThroughTheYears`, PhotosDomain): one photo per month while the photos span ≤ 4 years, per season (3 months)
  up to 12 years, per year beyond; at most 120 frames, thinned evenly keeping the first and last. Within a period the photo
  with the largest, most central face (Recognize's box) wins, favourites ×1.25, tiny faces (< 6 % of the width) only as a
  last resort; the next two are tried when the best face cannot be lined up. Archived photos and videos are left out.
- *Alignment* (`FaceTimeLapse`, PhotosMedia, on the device): Vision face landmarks; the face overlapping Recognize's box
  (IoU > 0.1) is the person's; pupils (else the eye outlines' centres) give the eyes. A face turned away (|yaw| > 35°, or
  eyes closer than 20 % of the face width) is skipped; if Vision finds nothing, Recognize's box (≥ 8 % wide) gives estimated
  eyes. Each photo is turned so the eyes are level, scaled so they are 17 % of the frame's shorter side apart, and moved so
  their middle is at (50 %, 42 %); the rest of the frame is a blurred, darkened copy of the aligned photo. The player draws
  square frames (fill a landscape or portrait screen alike), only those around the current time; only the eyes are kept.
- *Film*: a title card (name, "Through the years", year span) over the first face, then the faces dissolving into each
  other: Slow 1.6 s / Normal 1.0 s / Fast 0.55 s per face (remembered), 60 % of it a dissolve; last face 2.6 s and a fade
  to black. Under each face its month and year (year for yearly films) and, with a birthday, the age ("8 months old" below
  two, then "5 years old"). The birthday is added in the film's menu and kept on this device per account (Recognize has no
  birthdays). The calm style's music plays (Mute). Controls as in §15.1 (scrubber, ← → Space M Esc, VoiceOver describes
  name, date and age).
- *Export*: 1920 × 1080 video through `FilmExporter` (faces aligned again from 2560-px previews for the landscape frame,
  captions rendered in, calm music), H.264/HEVC, Share/Save to Nextcloud/Save to Mac as in MF-2.

**FS-2 Film styles.** Every memory film can be remixed in the player's style menu (wand icon): Cinematic (default, the
round-5 film unchanged), Upbeat, Black & White, Super 8, Calm. A style (`FilmStyle`) sets:
- *pacing*: about 3.4 / 1.8 / 3.8 / 2.6 / 5.2 s per picture (whole beats of the music); favourites ×2 (not in Calm);
- *transitions*: steady dissolves of 0.8 / 0.3 / 1.1 / 0.45 / 1.8 s; with music, cuts on the beat within a day and a dissolve
  of 1 / ½ / 1 / ½ / 2 beats into a new day — Calm dissolves every picture;
- *camera*: Ken Burns zoom 1.15 / 1.22 / 1.12 / 1.10 / 1.08;
- *look* (`FilmLook`, one colour matrix applied the same way everywhere): Upbeat punchier colours; Black & White monochrome,
  contrast, slight fade, vignette, fine grain; Super 8 warm faded colours, strong vignette, coarse grain, a gate that jitters
  and light that flickers at 18 film frames a second (deterministic, so the player and the video look the same); Calm softer,
  warmer, low contrast. The player grades pictures, map pictures and clips (`AVVideoComposition`) with Core Image and draws
  vignette, grain and flicker over the frame; the export applies the same with Core Image per frame. Titles are not graded.
- *music mood*: each style has its own score (`FilmScore` + `ScoreSynth`): the app ships no recordings, so a short piece is
  composed by the app's code and synthesised on the device (pads, plucked strings, bass, organ with tape wobble, kick, hats,
  shaker, a small reverb), 16 bars that loop seamlessly — Cinematic 70 BPM major, Upbeat 120 BPM with drums, Black & White
  66 BPM minor and sparse, Super 8 96 BPM organ and shaker, Calm 54 BPM pads. Made once (about a second) and cached. The tempo
  is known, so cuts land on its beat.
- *Music menu*: the style's music (default when the user has no music of their own), the user's own music from Settings
  (default when chosen; then the style changes only the pacing, the beat is detected as in §15.1), or No Music.
- *Remembered per memory* on this device (by memory id, last 300); the film is rebuilt from the picture it was at. The video
  export (from the player, its end card and the memory's More menu) uses the memory's style and music and says which.

**FS-3 SharePlay.** Watch a memory film or a slideshow together over FaceTime (GroupActivities, `WatchTogether` in
PhotosCore) on iPhone, iPad, Mac, Vision Pro and Apple TV.
- *Start*: SharePlay button in the film's top bar and in the slideshow's top bar. A slideshow is shared as a film (its photos
  in their order, up to 200, in the style's pacing and music) so every device can be in step; the slideshow closes and the
  film opens.
- *What goes through Apple*: only the activity (`SharedFilm`): title, dates line, the timeline (`FilmPlan` without places —
  no coordinates or place names; map flights become a quiet pause for the others), the files' ids/etags/types, the style and
  the Nextcloud's address. No photo, no preview image on the activity, no music: every participant loads the pictures from
  that Nextcloud **with their own account**, and every device synthesises the style's music itself (the user's own music is
  personal and never shared: sharing switches the film to the style's music).
- *Who sees what*: participants need Nextcloud Photos and an account on the same Nextcloud with access to the photos — the
  practical way is a shared album (or shared folder) both can open. A participant on another account of that server gets
  "Switch Account"; one not signed in to it gets an explanation naming the server. Photos not shared with them show as a dark
  "Not shared with you" card at their place in the timeline, so everyone stays in step. Each participant reports how many of
  the photos they can see (`GroupSessionMessenger`), and everyone's banner says "Watching with N others", "N people can't
  see some photos. Share the album with them on Nextcloud." / "… can't see these photos …", and for the guest "You can see
  37 of 40 photos …".
- *In step*: `AVDelegatingPlaybackCoordinator` with the film as a custom player: play, pause, seek (scrubber, ← →) from
  anyone apply to everyone on the host clock (`FilmSync`); late joiners are brought to the group's time; nobody waits for a
  participant who cannot load pictures. Only whoever shared it changes the style (re-shared to everyone). Closing the film
  leaves SharePlay on that device. While watching together the film keeps playing when the app goes to the background.
- *Platforms*: iPhone/iPad full screen, Mac in a window of its own, Vision Pro full screen; Apple TV (`TVSharedFilmView`,
  also via "continue on TV") with pictures, camera moves, title, look and music — clips show their still; Play/Pause and ← →
  control everyone, Menu leaves. Films shared to a locked app wait until it is unlocked.
- *Needs*: the Group Activities capability (`com.apple.developer.group-session`, added to the app's and the TV app's
  entitlements) in the provisioning profiles of team NKUJUXUJ3B.

Not done: birthdays from the Nextcloud Contacts app (CardDAV `BDAY`), syncing styles and birthdays between devices,
inline clips on Apple TV, a spatial SharePlay template on Vision Pro, beat-synced Ken Burns accents.

### 16.7 Sharing and family: postcards, family library, weekly prompts, Lock Screen shuffle album [family]

Four ways to share photos with the people close to you, all on stock Nextcloud (WebDAV, OCS sharing, the Photos album
API) and the device's own frameworks. Nothing is created on the server beyond ordinary files, folders, albums and links.

#### 16.7.1 Postcards (all platforms)

- **Where**: viewer › More › "Send as postcard…" (Mac: "Send as Postcard…"), photos only.
- **The card**: 6 × 4 inches at 300 dpi (1800 × 1200 px), upright (1200 × 1800) for upright photos, the same size on
  both sides so it can be turned over in place. Drawn with Core Graphics and Core Text (`PostcardRenderer`, layout in
  `PostcardLayout`), so it looks the same on every platform and renders off the main thread.
  - *Front*: the photo (4096 px preview, aspect fill) in one of four styles — **Classic** (white border), **Edge to
    Edge**, **Airmail** (red/blue diagonal stripes, white margin), **Vintage** (cream border, scalloped deckle edge,
    warm faded tones, vignette) — and optional lettering, prefilled with "Greetings from <place>" when the photo has a
    place (condensed heavy type, white with a soft shadow, shrunk to fit).
  - *Back*: warm paper (airmail stripes for Airmail), "POSTCARD" heading, a divider, the message in a handwriting font
    (Bradley Hand, else Noteworthy) in blue ink, as large as fits (at most 400 characters and 12 lines; longer text is
    cut at a word with "…"), a perforated stamp cut from the photo, a tilted postmark with place and date and wavy
    cancellation lines, "To:" with the recipient's name on the first of three address lines.
- **Sending** (`SessionModel.sendPostcard`): the two sides are uploaded as JPEGs `1 Front.jpg` and `2 Back.jpg`
  (numbered so the public page lists the front first) into `/Postcards/<yyyy-MM-dd> <place>` (a number is added when
  the name is taken). `/Postcards` gets an empty `.nomedia` file, so sent cards never appear in the timeline. The folder
  gets an ordinary read-only public link labelled "Postcard to <name>" whose **note is the message**, so the stock public
  page shows both sides and the message as text. **Decision**: an image pair in a folder, not a flip video — the stock
  public page shows pictures well and instantly, a video needs a tap and a player, and the pictures are what people
  save and print. When the server allows no public links, the card is still saved and shared as pictures.
- **After sending** the card turns over (3D flip) and gets a red "SENT" rubber stamp with a success haptic; the link can
  be copied, and "Share Postcard" opens the share sheet with both pictures, the link as message text and "A postcard
  for you" as mail subject (Messages, Mail…). Tapping the card flips it at any time (VoiceOver: an action "Turns the card
  over").
- The sent postcards stay in Files (`/Postcards`); the link is managed there or in the web app's sharing tab.

#### 16.7.2 Family library (all platforms)

- **Setup** (Settings › Family Library; Mac: a sheet from the General tab): the user picks
  - the **family folder**: a folder shared with or by the user that the user can add files to — found with a `PROPFIND`
    of the top level (`oc:permissions` with `C`/`K`, `nc:mount-type` `shared`/`group`, `oc:share-types`), the received
    shares (`shared_with_me`, wherever they were moved) and the user's own folder shares to people, groups or Teams
    (`GET …/shares`). Public links alone do not count. Each is labelled "Shared by Ben", "Team folder" or
    "Shared with Ben and Family";
  - the **family members**: named people of Recognize (unnamed clusters are not offered);
  - **move or copy** (move by default). When the family folder is not one of the timeline folders, a note says that
    moved photos leave the Library and "Show Family Folder in Library" adds it to the timeline folders.
- **Suggestions** (`FamilySuggestions`, computed on the device from the local index): the user's own photos and videos
  (own storage, not archived, not in the family folder or excluded folders, no screenshots or screen recordings, no Live
  Photo motion parts) that
  1. were taken on a day the family folder has photos of (its newest 1000, read with a DAV SEARCH scoped to it) **and**
     within 2 km of one of them or in the same named place — "12 photos from Lisbon on 4 July" (a photo without location
     never matches by date alone), or
  2. show a family member — "These 14 photos show your family", grouped by month.
  At most 200 photos per suggestion; newest first.
- **Card** in Memories with the newest suggestion: four thumbnails, "Move them to <folder>?", a one-tap "Move 14" / "Copy
  14" (the tap is the confirmation; nothing ever happens on its own), "Review", and ✕ ("Don't suggest these photos
  again"). **Review** lists all suggestions with selectable thumbnails, Move / Copy / "Not These".
- **Moving/copying** uses DAV `MOVE`/`COPY` without overwrite; a name that is taken gets " 2", " 3"…; a Live Photo's
  motion part goes along under the photo's new name. Progress is shown; a sync follows.
- **Decisions are remembered** (`familyDecision` table, migration `v6-family-decisions`): moved, copied and dismissed
  photos are never suggested again. Choosing another folder starts over; "Suggest Dismissed Photos Again" forgets them.
  Suggestions are refreshed after syncs at most every 30 minutes. The options and decisions are per account and per
  device (not synced between devices).

#### 16.7.3 Weekly photo prompts (all platforms)

- 52 built-in themes with a one-line hint ("Reflections — Mirrors, puddles, shop windows, a spoon."), localised, in an
  order where colours, light, subjects and techniques take turns. The week's theme is the same for everyone
  (`WeeklyPrompts`, counted from the week of 3 January 2024 in the user's calendar, whose first weekday follows the
  region; daylight saving changes don't skip a week), so a family can play along without any server.
- **Off by default.** While off, Memories shows a small dismissible invitation ("Turn On"). On: a card at the top of
  Memories with the theme, hint, the week's dates and the photos added so far; "Add Photos" lists the user's own photos
  and videos taken that week (already added ones are marked) and adds the chosen ones to the normal album
  "Prompt: <theme>" (created when missing; the theme comes back after a year and adds to the same album).
- **Past Prompts**: the weeks since prompts were first turned on (up to a year), each with how many photos were added
  or "Skipped", linking to its album.
- **Reminder** (off by default, asks for notification permission): one local notification on the week's sixth day at
  10:00 (Saturday where weeks start on Monday) — "This week: Hands. Hands at work, at rest, holding on." — not for a
  week the user already added photos to. Four weeks are scheduled ahead and again after syncs (at most every 6 hours),
  when the setting changes and after adding photos. Tapping opens Memories. No photo is shown, so app lock needs no
  special text.

#### 16.7.4 Lock Screen album (iPhone and iPad)

- Settings › Lock Screen Album: pick one Nextcloud album (own or shared). The app mirrors it into an album
  "Nextcloud: <name>" in the device's own Photos library with PhotoKit, so the Lock Screen's **Photo Shuffle** (and
  Memories, widgets, wallpapers of the system) can use it. The footer says plainly that copies are stored on the device.
- **Copies**: 2048 px server previews (sharp on every iPhone/iPad screen, a fraction of the originals), with the capture
  date and location; at most 300 photos in the album's order. Left out: videos, Live Photo motion parts, archived photos
  and photos with a person hidden on this device.
- **Sync** (`DeviceMirror.plan`, table `deviceMirror`, migration `v6-family-device-mirror`): after each sync of the
  account (at most every 15 minutes) and when the setting changes. New photos are added without asking; a photo edited
  on the server is replaced; a copy the user deleted on the device is made again (the album follows Nextcloud).
  Photos that left the Nextcloud album are taken out of the device album at once and then deleted from the device —
  PhotoKit always asks the user before deleting. If the user says no, they wait, and Settings shows "N removed photos
  are still on this device" to try again.
- **Turning off** ("Turn Off and Remove Copies", confirmed) deletes all copies and the device album in one system
  confirmation. The Nextcloud album is not touched.
- **Permission**: PhotoKit's add-only access cannot make or manage an album, so the app asks for library access when the
  user picks an album; **limited access is enough** (the app only ever touches the copies it made, which join the limited
  selection). If access is denied, Settings says where to allow it. The usage text says what the access is for.
- Mac, Vision Pro, Apple TV, Watch: not offered (no Lock Screen Photo Shuffle; the Mac has its own desktop pictures,
  §15.4).

### 16.8 Look and access: colour from the photo, living album covers, guest mode [look]

**16.8.1 Colour from the photo.** The app takes one colour from a photo and uses a toned version of it as a quiet
backdrop. Platforms: iPhone, iPad, Mac, Vision Pro (headers not on Vision Pro, whose windows are glass).

- *Where the colour comes from* — no extra network: the photo's BlurHash (already in the index) decoded at 8×8, or, when
  the server gave none, a preview that is in memory anyway, scaled to 8×8 on the CPU. The dominant colour is the mean of
  the heaviest of twelve hue families, where colourful pixels weigh more than grey ones (a red coat on a grey street
  gives red); a photo without a hue family of at least 20 % of the weight gives its mean grey (`PhotoPalette`).
- *Toning* (`PhotoTintRole`) — the hue is kept, the saturation calmed, and the colour set to a fixed relative luminance
  for its place: the viewer backdrop and the scrim of memory cards very dark (white text on them ≥ 7:1, WCAG AAA), the
  header wash in Dark Mode dark, in Light Mode light (black text ≥ 7:1). Every tone is checked against its text colour
  and darkened or lightened further if rounding would cost contrast.
- *Viewer* — Settings ▸ Appearance ▸ Viewer Background: **Black** (as before), **Photo Color** (default: the black takes
  a deep shade of the photo's colour) or **Ambient Glow** (the photo's BlurHash colours, each toned dark — brighter parts a
  little brighter, all ≥ 7:1 against white — scaled up and blurred behind the photo). The viewer stays dark in Light Mode,
  as before (its bars are dark), so both options apply in both modes; "ambient in Light Mode" of the idea became the
  Ambient Glow option. While paging, the colour follows the finger: the backdrop blends the two photos the pager is
  between by the scroll position (a jump, e.g. a step with Reduce Motion, fades over 0.4 s). Guest Mode's viewer has the
  same backdrop.
- *Headers* — an album's and a memory's navigation bar (Mac: window toolbar) takes a wash of the cover's colour; memory
  cards draw their title scrim in a deep shade of the cover instead of black. Setting "Tint Headers with Photo Colors"
  (on by default) turns both off.
- *Accessibility* — with Increase Contrast no photo colour is used anywhere (pure black backdrop, plain bars, black
  scrims). With Reduce Transparency the ambient glow becomes the plain tone, header washes are opaque and memory scrims
  black.

**16.8.2 Living album covers.**

- *Live Photo covers* (effect **Automatic**, the default) — a Live Photo cover plays its motion once per app session when
  at least 80 % of the card has been in view for 0.7 s: muted, filling the cover, fading in and back to the still. Not
  with Reduce Motion, Low Power Mode, the system's "Auto-Play Video Previews" off (iPhone, iPad, Vision Pro) or the setting
  "Play Live Photo Covers" off. The motion is streamed like in the viewer (a local or cached copy when there is one).
- *Depth covers* (effect **Depth**) — the album's title is drawn large in the upper part of the cover and the photo's
  subject stands in front of it, like the Lock Screen's depth effect. The subject is found on the device with Vision's
  foreground instance mask from a 768-pixel preview, and kept as a mask PNG next to the account's previews (removed with
  them; a photo without a subject is remembered too, so Vision runs once per photo version). When the subject would hide
  more than 55 % of the title band, or none is found (or Vision is not available, e.g. the simulator), the title is drawn
  in front. The title on the cover is decoration; the card's accessibility label is unchanged and the title stays below
  the card, so the grid keeps its rhythm.
- **Still** never moves.
- *Choosing* — "Customize Cover…" in an album's options menu and in its card's context menu: a preview, the effect, and
  the cover photo from the album's photos (or "Album's Own Cover").
- *Where the choice is kept (decision)* — not in the album description (that is the album's content, shared with
  collaborators and shown on the web), and not only on the device: in the user's own files at
  `/.nextcloud-photos/album-covers.json` (`AlbumLookBook`: `{"version": 1, "albums": {"<kind>:<DAV name>": {"cover": <fileId>,
  "effect": "automatic|still|depth", "updated": "<ISO 8601>"}}}`), so all the user's devices show the same covers, also for
  albums shared with the user and on stock servers. A copy on the device is used at once; the file is read when the
  albums appear (at most every 5 minutes) and written after a change with `If-Match` (`If-None-Match: *` for the first
  version); on 412 the app reads the newer file, merges album by album (the later choice wins; resets are kept as default
  entries so they reach other devices too) and writes again. Offline changes go up with the next read. A rename moves
  the choice. For an own album on a server with the extended cover API, the chosen photo is also set as the album's
  cover there, so the web shows it.

**16.8.3 Guest Mode.**

- "Show to a Guest…" in an album's options menu, its card's context menu and a memory's More menu opens a sheet that
  explains what a guest can and cannot do (and warns when the device has no passcode, so nothing can protect the mode).
  On iPhone, iPad and Vision Pro it also suggests the system's Guided Access, which keeps the guest inside the app.
- In Guest Mode every window of the app shows only the album's or memory's photos as they were when it started (a grid,
  a viewer with paging, zoom, Live Photos, videos and the tinted backdrop, and a slideshow on iPhone, iPad and Vision Pro).
  No sharing, deleting, info, favourites, Live Text, editing, other albums, search, settings or account switching; no
  accessibility actions for them either. Links, Spotlight results, widgets and notifications open nothing (`AppModel.open`
  and `handleNotification` ignore them), and notification banners are not shown in the app (they wait in Notification
  Centre). Only photos of the account the mode was started in are shown.
- It ends with "End Guest Mode", which asks for Face ID, Touch ID, Optic ID or the passcode (the app lock's
  authentication, `.deviceOwnerAuthentication`); on a device without a passcode it ends at once. Anything a guest opened
  from outside meanwhile is dropped. Guest Mode is stored in the app's defaults: quitting and opening the app again comes
  back in Guest Mode. With app lock on, the lock still covers the app as usual.
- Mac: a presentation window of its own fills the screen with the Dock, the menu bar and app switching hidden
  (`NSApplication.PresentationOptions`), cannot be closed or minimised, and ⌘Q is refused; it ends with Touch ID or the
  login password. The other windows (and Settings) show only "Guest Mode" meanwhile. Force Quit stays available as the
  emergency exit; the app then reopens in Guest Mode.

## 17. M8 — Elegant motion and glass

Round 7 (2026-11-25): 25 ideas for a more elegant UI with Liquid Glass, transparency and motion. Everything falls back
cleanly with Reduce Motion (fades instead of movement) and Reduce Transparency (solid surfaces). No server changes.

### 17.1 Viewer as a stage: full-screen photo, glass controls, info glass card, interactive dismissal, viewer colour [viewer]

**17.1.1 The stage (iPhone, iPad).** The photo fills the whole screen, under the status bar and the home indicator;
there are no navigation or bottom bars. The controls float over it as Liquid Glass (`ViewerStageControls`): a round
close button at the top left, a date pill in the middle of the top ("22 November 2026" / "14:36 · Lisbon"; a tap shows
the info), and a glass action bar at the bottom (Share, Favourite, Info, Edit for photos, More, Delete) in one
`GlassEffectContainer`. The heart changes with a symbol transition and bounces. One tap on the photo hides or shows
the controls and the status bar with a 0.25 s fade (also with Reduce Motion — it is a fade). Badges on the photo (Live,
RAW) and a stack's strip of copies sit below the floating controls. VoiceOver order: close, date pill (a header, hint
"Shows the info"), the photo, the action bar; the photo's actions rotor is unchanged. Hidden controls are hidden for
VoiceOver too, as the bars were. Mac: the window toolbar stays (the platform's idiom); Vision Pro: the toolbar and the
dark viewer stay (windows are glass there).

**17.1.2 Viewer colour (decision; replaces the open question of a light viewer).** The stage is **pure black in Dark
Mode and pure white in Light Mode**, with the glass controls in both. While the controls are hidden it is black in both
modes (as in Photos: a tap turns the white stage black), cross-fading in 0.3 s. Settings ▸ Appearance ▸ Viewer
Background still offers three styles, each now with a dark and a light version that follows the stage:

| Style | Dark stage | Light stage |
|---|---|---|
| **Black or White** (default; stored as `black`) | pure black | pure white |
| **Photo Color** (`tinted`) | deep shade of the photo's colour (as in §16.8.1, white text ≥ 7:1) | pale shade (the light header tone mixed with 55 % white; black text ≥ 7:1) |
| **Ambient Glow** (`ambient`) | a blurred (60 pt), enlarged (1.25×) copy of the photo under 50 % black | the same under 60 % white |

The copy for Ambient Glow is the preview already in memory (usually the grid's tile), else the BlurHash; nothing is
loaded for it, and two photos cross-fade while paging as before. The default changed from Photo Color to Black or
White; a style that was chosen explicitly is kept. Increase Contrast: plain black or white, no photo colours (as
before); Reduce Transparency: Ambient Glow becomes the plain tone, and the system makes the glass controls solid.

**17.1.3 Info as a glass card.** On iPhone (and narrow iPad windows) the info panel stays a sheet with the half-height
and full-height detents, drawn as the system's Liquid Glass sheet over the photo; the photo moves up and, if needed,
shrinks so it stays in view between the date pill and the card (`ViewerStage.infoPlacement`), following the card while
it is dragged. Paging still works under the card. A swipe down on the photo closes the card first. Regular-width iPad
and the Mac keep the inspector column beside the photo.

**17.1.4 Interactive dismissal (iPhone, iPad).** Dragging a photo that is not zoomed downwards makes it follow the
finger in both directions and shrink (to 55 % at 60 % of the screen height) while the backdrop and the controls fade.
(Meant: the grid shows through as the backdrop fades. With the zoom transition the system takes the grid's view out of
the window while the cover is up, so for now the stage fades to the system background; see STATUS.) Letting go past 120 pt, or with a downward flick faster than 800 pt/s, lands the photo
exactly in its tile: a no-bounce spring (0.38 s) that starts at the finger's speed moves, scales and clips the photo to
the tile's frame (as the tile crops it); the tile is left empty meanwhile and the viewer then closes without a second
transition. The tile's frame comes from the grid's zoom-transition mark (`ViewerTileTracker`, in global coordinates);
when the tile is not on screen, or the viewer was opened from somewhere without a zoom source, the viewer closes the
usual way. Letting go earlier springs back from the finger's speed. Reduce Motion: the photo still follows the finger
(direct manipulation), but closing fades it out where it is and cancelling snaps back without a spring. The close
button and Escape use the system's zoom transition back into the tile as before.

**17.1.5 Keys without the software keyboard (bug fix).** The viewer, slideshows, films (memory films, Through the
Years) and Guest Mode's viewer were focusable views with `onKeyPress`; on iPhone and iPad a focused view takes key input
like a text field, so whenever it became first responder again (a menu opened over it — the viewer's More menu, the
editor's and the film's menus) the software keyboard came up. On iPhone and iPad these views are no longer focusable;
their keys (arrows, Space, Escape, M, and the rating keys P X U 0–5 in the viewer) are key commands on hidden buttons
(`hardwareKeys`), which a hardware keyboard reaches without a first responder. The Mac and Vision Pro keep focus and
`onKeyPress`. The culling loupe and compare views (iPad and Mac) are unchanged.

### 17.2 Grid: edge to edge, floating date pills, photo arrival, physical selection, action feedback, Live Photo and video tiles [grid]

The photo grid (`PhotoGrid+UIKit`, `PhotoGrid+AppKit`, decisions in `GridMotion`) gets glass and motion. Everything is
done by the system or Core Animation (no per-frame work on the main thread beyond what scrolling did before), and every
effect has its Reduce Motion / Reduce Transparency form.

- **Edge to edge** (iPhone, iPad, Vision Pro). Every grid screen (`MediaGridScreen`) lays its collection view under the
  top and bottom bars (`ignoresSafeArea`); the collection view's own insets keep the first and last rows clear of them,
  and the top edge uses the system's soft scroll-edge effect (`topEdgeEffect.style = .soft`) instead of a band. The
  pinned section headers and their material band are gone (see the date pill). The Library's memories strip scrolls with
  the photos: it is hosted inside the collection view as a header above the first section (a `UIHostingController` child
  with the grid's SwiftUI environment, so its links and buttons work as before), its height counted in the scrubber's and
  the pill's offsets; it comes and goes (selection mode, settings) with the grid kept at the top or on the photo that was
  at the top. Albums and memories with a cover colour (§16.8.1): the solid tinted bar is replaced by a wash of that
  colour that runs from the top of the screen to 36 pt below the bar and fades out, over the photos scrolling under it;
  with Reduce Transparency the solid bar stays. The Mac keeps its own toolbar idiom (memories above the grid, the tinted
  window toolbar, pinned headers in the window's header material).
- **Floating date pill** (iPhone, iPad, Vision Pro; timeline grids only). A glass capsule (`UIGlassEffect`, the thin
  material on Vision Pro) under the bar at the leading edge says what the photos at the top are: "November 2026", or
  with the round-6 moment they belong to "November 2026 · Lisbon" (the moment's place, else its title; a moment covers
  the days from its title day down to its oldest day, `MomentHeaders.Entry.oldestDay/place`). The section under the
  pill's lower edge names it, found by a binary search over the section offsets; the text changes only when the month
  or the moment does, and then hands over with a short push in the scrolling direction (a cross-fade with Reduce Motion).
  It fades in once the grid is scrolled past its first header (and the memories), and out at the top. It takes part in
  the scroll-edge effect (`UIScrollEdgeElementContainerInteraction`), is one VoiceOver element ("November 2026, Lisbon")
  and follows Dynamic Type. The day and month headers in the content stay as light text without a band and scroll with
  their photos; heights are unchanged, so the date scrubber, year ticks and "Show in library" stay exact.
- **Photo arrival.** A preview that loads after its tile was configured cross-fades from the BlurHash (0.22 s) and
  settles from 4 % larger into place — a `contentsRect` animation of the picture's layer, inside the tile, so nothing
  moves in the layout. A sharper preview over a picture only cross-fades; pictures already in memory (scrolling back)
  appear at once, so nothing animates during fast scrolling. Reduce Motion: the fade only. Mac: the same on its layer.
- **Physical selection** (iPhone, iPad, Vision Pro). A selected tile shrinks to 92 % and rounds its corners (7 % of the
  side, 3–10 pt, continuous corners), with a short spring; the picture dims slightly (85 %) so the state also reads in
  black and white. The tick replaces the ring with a symbol transition and a bounce. Only a change of the tile on screen
  animates (not cell reuse, not range selection's off-screen tiles); range selection and two-finger selection animate
  tile by tile as they pass. Reduce Motion: no shrink, the corners and dimming change with a plain spring. The "N
  selected" title rolls its number (`contentTransition(.numericText)`), as the bar's principal item; the navigation
  title keeps the same text for VoiceOver and the back button. The Mac keeps its selection ring.
- **Action feedback.** The screen tells the grid what the user did (`GridActionMotion`): a new favourite gets a heart
  that springs up over its tile and fades (a fade with Reduce Motion; also on the Mac), and the tile's heart badge
  bounces in (iPhone, iPad, Vision Pro). Delete
  (after its confirmation), Archive / Unarchive and Remove from Album mark their tiles as leaving; when the library's
  change arrives (within 8 s), the grid applies it as an animated batch of single tiles (`GridItemChanges`: tiles that
  leave and come by index path, at most 400, nothing reordered) in one spring: deleted tiles collapse in place, archived
  or removed ones slide away to the trailing side, and their neighbours flow into the gap. Tiles that come back within
  two minutes (Undo, from the banner, Edit › Undo, shake) return the same way. Changes nobody asked for (sync, other
  devices) and larger ones keep the existing non-animated batch. Reduce Motion: tiles fade out and in. Mac: the same
  batch, animated by AppKit (fade and move).
- **Live Photos and videos.** The Live badge plays (`variableColor`, layer by layer) while the tile is held for its
  context menu, while the pointer rests on it (iPad, Vision Pro) and while a peek (§16.1) scrubs its motion. Video tiles
  show their duration in a small glass capsule with the camera glyph in the bottom trailing corner (the glyph alone on
  tiles under 64 pt, nothing under 34 pt; a solid dark capsule with Reduce Transparency or Increase Contrast); the dark
  shade at the tile's foot is only drawn under a favourite's heart now. The Mac keeps its duration label.

### 17.3 Chrome: morphing toolbars, minimizing tab bar with progress accessory, animated icons, rolling numbers, edge to edge on the other screens [chrome]

Shared helpers live in `Common/Design.swift` (block "Chrome motion"): `ChromeMotion` (the springs: `.smooth(0.35)` for
morphs, `.snappy(0.3)` for counters; a 0.2 s ease with Reduce Motion), `rollingNumber(_:)`, `ChromeStatusSymbol`,
`ChromeLockSymbol`, `favoriteBounce(_:)` and `chromeGlass(in:)` (Liquid Glass on iPhone, iPad and Mac,
`glassBackgroundEffect` on Vision Pro, a solid surface with a hairline edge with Reduce Transparency or Increase
Contrast).

1. **Selection bar that morphs (iPhone, iPad).** Select hides the tab bar and the selection's action bar materialises in
   its place (`SelectionActionBar`, a `GlassEffectContainer` in a `safeAreaBar` of the grid). With nothing selected it is
   one glass capsule "Select items"; the first selected photo splits it (`glassEffectID`) into Share · the count ·
   Favorite, Add to album, Delete, More, and emptying the selection melts them back. Done dissolves the bar and the tab
   bar returns. "Add to album" (recent albums, New album…, All albums…) is a button of its own now; More holds the
   rest without the bar's buttons (`SelectionBarLayout.ownButtons`). The count rolls; the heart bounces and is replaced by
   the crossed-out heart when everything selected is a favourite. The Mac keeps its window-toolbar items (its own idiom);
   only the heart bounce is shared. Map: the time range panel rises as glass out of the bottom edge.
2. **Tab bar that minimises, progress accessory (iPhone, narrow iPad windows).** `tabBarMinimizeBehavior(.onScrollDown)`
   on the main `TabView`; the UIKit photo grid tells the bars it is the screen's scroll view
   (`registerContentScrollView`, `setContentScrollView` up to the navigation controller), which SwiftUI does not do for
   it. While something runs, `tabViewBottomAccessory` shows a slim bar above the tab bar (beside the
   minimised tab bar it is one line): the activity's animated symbol, what it is ("Uploading", "Backing up", "Importing
   from EOS R5"), "12 of 400" rolling, a "+1 more" when others run, and a thin progress ring. One activity at a time, in
   this order: card import, library import, manual uploads, backup. The backup only counts while it uploads (looking for
   new photos and checking the server at every start would make the bar flicker). When the activity ends the symbol turns
   into a check mark (an exclamation mark when something failed), the title says how it ended, and after 2.5 s the bar
   goes; a pause ends without a check mark. A tap opens the uploads list, Backup, or the import sheet. The toolbar's
   upload gauge steps back while the accessory shows the uploads. The decisions are in `ChromeActivities` (pure, tested).
   Debug builds: `PHOTOS_DEBUG_ACTIVITY=upload|backup|import` plays a made-up activity for screenshots.
3. **Animated symbols.** The upload cloud lifts its arrow (`wiggle.up`, every 1.2 s) while uploading; the backup symbol
   breathes while the backup runs (accessory, Backup screen, the Backup row of Collections); the sync arrows turn while
   syncing (Settings › Server, the first sync's pill) and are replaced by a check mark when the sync is through; the
   Backup screen's symbol is one image for every phase, so "running → up to date" is a replacement into the green check
   cloud instead of a spinner swapped for an icon. Archive and Recently deleted show a padlock that clicks open
   (`replace.magic`) after Face ID / Touch ID / the passcode, then the content replaces it 0.45 s later. With Reduce
   Motion no repeating effect runs, replacements are cross-fades and the unlock does not wait.
4. **Rolling numbers.** `contentTransition(.numericText)` on: the selection count, the accessory's counts, the Backup
   screen's title and counters, the Backup row's progress, Settings' "Loading library"/"Checking library" counts, the first
   sync's pill, and the Insights header and ranked counts (the Year in review cards had it already). With Reduce Motion
   the numbers change in place.
5. **Edge to edge on the other screens.** Lists and scroll views (Collections, People, Places, Memories, Search,
   Settings) already run under the glass bars with the system's scroll edge effect. The solid bands are gone: the Places
   country headers are glass capsules floating over the places instead of pinned `.bar` strips; the map runs under the
   navigation and tab bars with a small title (MapKit keeps its controls in the safe area) and its time range panel and the grid's status
   bars and first-sync pill are glass (`chromeGlass`) instead of `regularMaterial`.

### 17.4 Albums and transitions: glass caption plates, empty-album gradients, hero headers, parallax, zoom transitions everywhere [albums]

**Album cards (idea 4).** An album's title and count (plus owner and place, as before) sit on a caption plate over the
bottom of the cover instead of under it: Liquid Glass (`glassEffect(.regular)`) on iPhone, iPad and Mac, a regular
material on Vision Pro, a solid plate with a hairline border with Reduce Transparency or Increase Contrast
(`CaptionPlate`). At the accessibility text sizes the plate goes and the title and count wrap below the cover as before.
A depth cover (SPEC §16.8.2) already draws the title on the photo: its plate only says the count. Live covers play under
the plate. The sharing badge is a small glass circle (`GlassCircle`). Smart album cards (in Albums and the Smart albums
screen) look the same, with the wand badge at the top. An album without a cover photo shows a soft `MeshGradient` in
Nextcloud's blues made from its name (`AlbumGradient`: FNV-1a hash of the name seeds a SplitMix64 generator; nine tones
with hues 0.5–0.7, brighter in light mode, deeper in dark mode; the inner mesh points move a little), the same on every
device; it is also the backdrop a cover fades in over.

**Hero headers (idea 14).** On iPhone and iPad an album opens with its cover full width at the top (`GridHero`,
`HeroHeaderView`): the cover from the top of the screen to the first row (62 % of the width, at most 42 % of the height
and 380 pt), the title in large bold white type and the album's details line on a scrim at the bottom; under the status
bar and the glass bar buttons the system's own scroll edge effect keeps them readable in light and dark mode. The hero
lives in the grid's collection view, above the first row in the content inset (`GridHeroHost`, `HeroHeaderLayout`), so
it scrolls with the photos without any per-frame work. While its title is in view the navigation bar shows no title
(`toolbar(removing: .title)`); once less than 64 pt of the hero shows below the bar, the bar takes over the title (and
the subtitle), with a short fade. Pulled down past the top, the hero grows upward with the pull and the cover stretches.
An album, memory or person opened with the zoom transition (below) keeps the system's own gesture instead: pulled down
at the top, the screen shrinks back into its card, as in Photos; the stretch (and pull to refresh) then belong to
screens pushed without a zoom (links, restored state, Reduce Motion). While selecting, the bar shows the count as
before. Memories (cover, title, dates) and people (photo, face in a ring, name, count) get the same hero; an empty album
or a grid that is still loading shows no hero. The Mac and Vision Pro keep the title in the window's toolbar with the
cover tint of §16.8.1: that is the calmer version there.

**Parallax (idea 15).** The pictures of album cards, smart album cards, memory cards (Memories screen, strip) and story
cards drift up to 5 % of their length against the scrolling (vertical lists) or swiping (story cards, strips), enlarged
by 10 % so no edge shows (`scrollParallax`, `ScrollParallax.offset`). It is a `visualEffect` on the picture: applied
while rendering, no layout or state change while scrolling. Off with Reduce Motion.

**Zoom transitions (idea 8).** Cards open their screens with `matchedTransitionSource` + `navigationTransition(.zoom)`
on iPhone and iPad and shrink back into the card on the way back: album cards and the thumbnails of "New in shared
albums" → album (pushed by value: each navigation stack gives its `Namespace` through `routeTransitionNamespace`,
`RouteView` applies the destination side, only for album routes so list rows and deep links push as before); memory
cards, story cards and Year in review cards → memory / review; person → person page; place tile → place's photos; the
Map button of Places → map (a toolbar item as source); smart album cards → their grid. With Reduce Motion and on Vision
Pro the push is the system's `.crossFade`; on the Mac, whose stacks have no transitions, the pushed screen fades in over
0.18 s (`CardTransition`).

### 17.5 Zoom levels that morph, typography [levels]

**Zoom levels that morph (idea 13).** The Library's Years › Months › Days › All Photos (§15.5) no longer only
cross-fade: the photos shown on both levels travel and scale from where they were to where they are on the new level.
- *What travels.* A year's key photo is also the key photo of the month and the day it was taken in (`KeyPhoto` picks
  the first best photo of a range), and a day's highlights are tiles of the grid, so photos are matched by their id:
  a year card's photo flies into its month card, a month's into its day, a day's photos into their grid tiles (the grid
  is placed with the tapped photo under the finger), and the other way round when zooming out (grid tiles into the
  days' mosaics, days into months, months into years). The card the zoom starts from (the *hero*) always travels to the
  card it opens, cross-fading its picture when that card's key photo is another one. At most 24 photos travel, the ones
  closest to the fingers; the rest of both levels cross-fades with a slight scale (0.94/1.06) around the fingers
  (`LibraryZoomMorph`).
- *How.* The cards report their photos' frames in the zoom overlay's coordinate space; the grid reports its tiles'
  frames (`GridTileLocator.frame`, now also on the Mac). One or two frames after a level change, when the new level is
  laid out and the grid has scrolled to its photo, the travelling copies are drawn above both levels with the pictures
  already decoded in memory (no BlurHash flash), and the photos they stand for are hidden on both levels until they land
  (grid tiles are painted over in the background colour). Corner radii morph too (year 14, month 10, day and grid 0).
  Timing: the levels cross-fade in 0.38 s (`.smooth`), the photos travel in 0.44 s (`.smooth`, no bounce).
- *With the pinch.* While the fingers move the level follows them as before; on release the photos continue from
  where the fingers left them (the pinch's scale around its anchor is applied to their start frames), so the move is
  one gesture. The pinch out of the grid's densest step hands over to the days in the same way. A level that follows
  the fingers with the next level already showing underneath is ⬜ (see STATUS).
- *Picker, ⌘+/⌘−.* The same morph, without a hero (the top of the screen is kept).
- *Reduce Motion:* no travelling photos and no scale; the levels cross-fade (0.2 s).
- *Budget.* Nothing is done per item of the library: the matching looks only at photos on screen (a few dozen at most),
  and frames are reported by the cards on screen without redrawing them. The summary is built as before (100 000 items
  within the round-5 budget).
- *Fix.* While a summary level covered it, the grid underneath was still in the accessibility tree and could take taps:
  VoiceOver reached invisible tiles and a day's photo was "not hittable" for UI tests where a grid tile lay beneath it
  (`FeelTourTests.testZoomLevelsTour`). The grid takes no hits while years, months or days are shown, and its tiles are
  hidden from VoiceOver by the platform grid itself (`GridTileLocator.isCovered`): on iPhone and iPad its views are
  `accessibilityElementsHidden` and the collection view becomes a leaf element, since SwiftUI's host listed the cells
  even under a hidden parent; on the Mac the grid is `accessibilityHidden`. The toolbar stays reachable.
- *Writing on photos* (a card's title and count, "+12" on a day) is hidden while its photo travels and fades in
  (0.2 s) when it lands, instead of popping back after the copy that flew over it.
- *Picker.* The floating Years · Months · Days · All Photos control is on Liquid Glass on iPhone and iPad
  (`glassEffect(.regular)`, not interactive: the segmented control inside reacts to touches itself and an interactive glass around it swallowed taps; the system makes it solid with Reduce Transparency); material on Vision Pro;
  the Mac keeps it in the toolbar.

**Typography (idea 20).** The text styles are defined once (`Typography` in `Common/Design.swift`) and are all Dynamic
Type styles; the Mac uses its own type scale:

| Token | iPhone, iPad, Vision Pro | Mac | Used for |
|---|---|---|---|
| `yearTitle` | large title, rounded, bold | same style (Mac size) | year cards |
| `heroFigure` | title, rounded, bold, tabular | same | the one big figure of a screen (countries visited) |
| `figure` | title 2, rounded, semibold, tabular | same | "+12" on a day, a smart album's count |
| `yearLabel` | title 2, rounded, bold, tabular | same | years under pictures (Then and now) |
| `count` / `smallCount` | subheadline / caption, rounded, tabular | same | counts beside titles, Insights rows and charts |
| `cardTitle` (+ `cardTitleStyle()`) | subheadline semibold, 2 lines (4 at accessibility sizes), cut at the end | body semibold | album titles |
| `cardSubtitle` | caption | subheadline | the line under an album title |
| `overlayTitle` / `overlaySubtitle` | headline bold, 2 lines / caption medium | same | titles on photos (memories, month cards) |
| `dateTitle` / `dayTitle` / `dateDetail` | title 2 bold / headline bold / subheadline regular | 20 pt bold / 12 pt regular (grid) | date headers: bold date, light day line; a moment's title on the day line is semibold |
| `sectionTitle` | title 2 bold | same | section headings (Memories, Collections, Through the years, Then and now) |

Rules: big numbers rounded; counts tabular so they do not wobble; titles on cards a little smaller than a headline and
two lines rather than one cut short; date headers bold over light. Year in review's poster cards keep their fixed
sizes (they are pictures that are also shared) and were already rounded. Screens owned by other round-7 packages got
only font changes.

### 17.6 First impressions: living gradients, first launch and login [welcome]

#### 17.6.1 Living gradients
- A slowly moving `MeshGradient` (3 × 3 points; corners fixed, edge points slide along their edge, the centre wanders;
  one seamless cycle every 24 s, points move at most 12 % of the size) — `LivingGradient` in `Common/LivingGradient.swift`,
  reusable by every surface (`.livingEmptyBackground()` for an empty state).
- Palettes: **wash** (a faint Nextcloud blue under the system text colours, light and dark variants) for empty states
  and onboarding; **hero** (deep Nextcloud blues under white text, the same in light and dark mode) for the login and the
  welcome; **blend** (between a Year in Review card's two colours, perceptual mix, never lighter than the lighter one) for
  the Year in Review cards, replacing their flat linear gradient. Text contrast is checked in unit tests: ≥ 7:1 for the
  primary text on the wash, ≥ 4.5:1 for white on the hero (≥ 7:1 with Increase Contrast).
- Where: the empty Library/grid ("No photos yet", "You're offline", "Couldn't load your library", "No results", "No
  favorites yet" — every `MediaGridScreen` empty or failed state), "No albums yet"/"No shared albums", the search start
  screen and "Couldn't search", the backup offer after the first login, the login screen, the welcome, the Year in Review
  cards (not the intro card and the photo cards, which keep their photos).
- Cost: the system draws the mesh on the GPU; the view only recomputes nine points, at most 30 times a second
  (`TimelineView(.animation(minimumInterval: 1/30, paused:))`). It pauses — keeping its place, no jump when it goes on
  (`LivingClock`) — with Reduce Motion (then it is a still mesh), off screen (`onDisappear`), while the scene is not
  active, and for a Year in Review card that is not the current page; a card rendered as a picture or into the video is
  still (no timeline at all). Decorative: hidden from VoiceOver, taps go through.
- Increase Contrast: the wash becomes nearly the plain background, the hero darker. Reduce Transparency does not change
  the gradients (they are opaque) but does change what lies on them (§17.6.2).
- The notification question after the backup offer is the system's alert; the app has no screen of its own for it.

#### 17.6.2 First launch: the login
- Behind the first login (not the "Add account" sheet, which stays a plain sheet): a wall of generated pictures —
  gradients that suggest a sunset, the sea, a forest, snow, a city at night, a meadow, a desert, dusk; no photos, nothing
  copyrighted — in columns that drift slowly up and down (6–10 pt/s, neighbouring columns opposite ways), turned by 10°,
  under the moving hero blue at 78 %. Each column is drawn once into one layer (`drawingGroup`); the drift only moves the
  layers. Still with Reduce Motion, paused off screen and while inactive.
- A calm headline, "Welcome to Nextcloud Photos", the app icon and the existing one-line description, with the form on
  one card: Liquid Glass (`glassEffect`, tinted dark) on iPhone and iPad, the window's glass (`glassBackgroundEffect`) on
  Vision Pro, a material panel on the Mac. The login screen is always dark (like the Year in Review), so the text on the
  card reads the same in light and dark mode. With Reduce Transparency or Increase Contrast the wall is left out and the
  card is solid dark blue with an outline.
- The user's own photos are not used for the wall or a splash: before the login there are none, after a logout they
  must not be shown, and on later launches a picture splash would sit in front of the app lock and cost launch time.

#### 17.6.3 The welcome into the Library, and the launch
- After the first login (the first account, `AppModel.welcomesFirstLogin`) the window shows the app icon and "Welcome,
  <name>" on the hero blue for 0.45 s of calm (the hold starts again while the app is too busy to draw, at most 3 s,
  so the greeting is never swallowed by the first sync); then the icon grows towards the viewer as everything fades (0.6 s, `.smooth`),
  revealing the Library, which is already there and can be used at once (the welcome takes no input and is hidden from
  VoiceOver). With Reduce Motion the icon keeps its size and everything only fades. The backup offer (iPhone, iPad)
  comes after the welcome. Adding a second account plays nothing.
- Every other launch: the app's first appearance fades in over 0.35 s with a hint of scale (98.5 % → 100 %), only a fade
  of 0.2 s with Reduce Motion; it starts with the first frame and delays nothing. Once per process, not on an account
  switch.
- Debug builds: `PHOTOS_DEBUG_WELCOME=login` shows the login screen although an account is logged in (screenshots);
  `PHOTOS_DEBUG_WELCOME=transition` plays the welcome at launch, and lets the debug login (`PHOTOS_DEBUG_LOGIN`) play it
  as a real first login does; `PHOTOS_DEBUG_WELCOME_HOLD=<seconds>` holds it longer (XCUITest's `launch()` returns
  only once the app is idle). Without it the debug login plays no welcome, so other UI tests are unchanged.

### 17.7 Mac and Vision Pro polish [platforms]

Each platform's own idiom, from the system's own parts; nothing of the iPhone's glass is forced onto the Mac.

**Mac**

- *Sidebar* — the system's sidebar material (`NavigationSplitView` with `.listStyle(.sidebar)`): translucent with the
  system's vibrancy, solid with Reduce Transparency. The app draws nothing over it (checked in Light and Dark Mode).
- *Photos under the toolbar* — the grid reaches up under the window's unified toolbar (`PhotoGrid` ignores the top
  safe area; the scroll view's automatic content insets keep the first row and the pinned day headers below the
  toolbar). Photos scrolled past the top pass under the glass toolbar, which blurs and fades them with the system's
  scroll edge effect; Reduce Transparency makes that edge solid (system behaviour). In the Library the memories strip
  stays above the grid, so there the grid starts below it.
- *Glass toolbar items* — the window toolbar's items are the system's: on macOS 27 they are drawn as glass capsules,
  grouped by the system (filter menu, zoom level picker, search; M10 removed the zoom slider and the upload button, §19.2).
  No hand-made glass.
- *Tiles lift under the pointer* (`GridHoverLift`) — the picture under the pointer grows by 8 points (2–5 % of its side)
  in 0.16 s and casts a soft shadow (radius 10, 35 %); it settles back in 0.24 s when the pointer leaves. Layer
  properties of one tile only (sublayer transform, shadow with a path), no layout; one tracking area for the grid; only
  in the key window. Over the picture only (in the aspect-ratio grid not over the empty part of the tile). Scrolling, a
  pinch and a peek (scrub to peek, §16.1) put it down; the pointer has to move before the next tile lifts. Reduce
  Motion: no growth, the shadow fades in alone.
- *Smooth trackpad zoom* (`GridPinchZoom`, `GridPinchScaler`) — a pinch no longer jumps between zoom steps: between two
  steps the grid is scaled about the pointer with the fingers, geometrically from 1 to the ratio of the next step's tile
  side (so the tiles are at the next step's size when it is reached); after 0.22 of magnification the layout switches
  to that step (level-change haptic, as before), cross-fading (0.16 s) from the scaled grid into the new layout with the
  photo under the pointer kept in place. A long pinch goes through several steps. Released before a step: at least half
  way switches to it, less springs back (0.22 s). Past the largest step the grid stretches by at most 5 % and springs
  back; out of the densest step the Library's days take over as before. The scale is a sublayer transform of the clip
  view (GPU only, nothing is laid out per frame). Reduce Motion: no scaling; the steps cross-fade.

**Vision Pro**

- *Glass ornaments* — the viewer's actions (share, favourite, info, spatial, edit, More, delete) and a grid's selection
  actions (share, favourite, More, delete) are toolbar items in the `.bottomOrnament` placement: a glass ornament under
  the window, beside the photo instead of over it. The slideshow's playback controls (previous, play/pause, next) are an
  ornament of their own under the window (`slideshowControls`, glass background); a tap on the slideshow shows and
  hides them as before.
- *Hover* — grid tiles use the system's lift hover effect (`UIHoverStyle(.lift)`, rounded 6 pt): the tile looked at lifts
  towards the eyes; drawn by the system out of process, nothing in the app runs per gaze. Library year and month cards
  keep their hover effect.
- *Depth* — the viewer's own controls in the window (previous/next buttons, the copies of a stack) float 24 pt in front
  of the photo (`viewerChromeDepth`).

## 18. M9 — Caching for the photos that matter

Goal (the owner's words): improve the local caching "so that the performance of the most important photos is better".
Ten ideas in three packages; no server changes (existing preview, WebDAV and OCS APIs only). Builds on the preview
pipeline (§5.5), smart offline (§15) and the budgets of §10.

### 18.1 Loading and measuring: one cache key per photo, viewer neighbours, cache metrics [load]

**18.1.1 One cache key per photo.** The memory and disk caches key a preview by `(fileId, ETag, bucket)`. Covers,
memories, story cards, hero headers, Year in Review, places, people's covers, the lock-screen and family album pickers
know only a file id and asked with an empty ETag, so the same photo was cached twice (`<id>-0-<bucket>` next to the
grid's `<id>-<etag>-<bucket>`) and a cover downloaded a preview the grid had on disk. The pipeline now resolves the ETag
itself: `ImagePipeline.setEtagProvider` is set by `AccountServices` to `LibraryStore.etag(of:)` (one primary-key read of
`media`, else the album-only `collectionMedia` row), and `resolved(_:)` fills an empty ETag before anything else
(`withEdits`, `displayedEtag`, `preview`, `prefetch` and `placeholder` all go through it). Callers keep passing `""`;
the two places that read the memory cache directly with `""` (album cover tile, cover tint) ask `displayedEtag` first.
A file the library does not know (a public album, which has no library) keeps its key of its own, as before. Requests
with an ETag are not looked up, so the grid pays nothing. Buckets are chosen by `PreviewSizing` only;
`PhotosAPI.previewBucket(forPixels:)`, which nobody called and which rounded differently (0.8 instead of 0.9), is gone.

**18.1.2 Viewer neighbours and a picture at once.** When the viewer shows page *n* (`ViewerNeighbourPrefetch` on
`MediaViewer`, `ViewerPrefetchPlan` in PhotosMedia):
- the 1024 px previews of *n±1* and *n±2* are asked for with `prefetch(_:decode: true)`, the direction of paging first
  (*n+1, n+2, n−1, n−2* when paging forward; forward when the viewer has just opened). Videos are included: their page
  shows the same 1024 px poster. What is no longer a neighbour after a page change is taken back
  (`cancelPrefetch`), and closing the viewer takes everything back.
- `decode: true` is new: a neighbour that is on disk is also decoded into memory, in the local lane, after what is on
  screen (a queue of local prefetches, like the network one; a prefetch that comes on screen joins the waited-for
  queue). Without it (the grid's prefetching) disk previews are left alone, as before.
- after the photo has been shown for 3 s, on a network that is not expensive or constrained (Wi-Fi, Ethernet; the
  Mac on Wi-Fi) and not in Low Power Mode, its 4096 px preview is prefetched for zooming: stored whole on disk, decoded
  only to 1024 px in memory (zooming decodes it again from disk at full size). Paging away before takes it back.
- the page shows the best picture on the device at once: the largest decode in memory, else (new) a smaller preview
  on disk — 256 or 64 px, usually the grid's tile — read off the main thread (`ImagePipeline.placeholder(for:)`, which
  never downloads), while the 1024 px preview loads; the BlurHash only when there is nothing at all.
Prefetches still run only when nothing on screen is waiting in their lane, newest batch first, and are bounded (200 per
lane).

**18.1.3 Measuring.** `CacheMetrics` (PhotosMedia, one shared instance) counts every preview the pipeline delivers by
layer — memory, disk cache, smart offline, offline album, downloaded, not loaded — and bucket, separately for loads
somebody waited for and loads only a prefetch asked for (the hit rate is waited-for previews served from the device).
The grid's own memory fast path (`TileLoader`) counts as a memory hit. Times to show are kept as ring buffers of 1024
samples each, reported as p50 and p95: grid tiles (configuration to first real picture; the BlurHash does not count),
viewer first picture and viewer sharp picture (the page becoming current to any picture, and to its 1024 px preview).
Recording is a few additions under an uncontended `Mutex` with no allocation; an actor would cost more than the event.
`os_signpost` intervals "Preview" (one load, with the layer it came from), "Tile" and "Viewer" (subsystem
`com.nextcloud.photos`, category `cache`) are only begun while Instruments records. Settings › Server › Cache
performance shows the counts and shares per layer, the hit rate overall and per size, the times with the §10 goals, and
what is stored per bucket and pool (preview cache per size, smart offline, offline albums, originals cache — scanned
off the main thread every 10 s while the screen is open — and the memory budget); Reset counters starts again. While
open it writes the snapshot to `Library/Caches/cache-metrics.json` (used by the simulator measurements).

**18.1.4 Measured (iPhone 17 simulator, iOS 27.2, 8089 test library).** `CacheMeasureTests` runs its phases on a
fresh install, each in a new process (counters from zero, disk cache carried over): 1. the timeline loads and scrolls;
2. after Reset counters, Collections › Memories, Albums and Places with their covers; 3. after Reset counters, the
viewer opened on the 8th tile and paged ten times at 1.5 s per photo; 4. on a fresh install of its own with smart
offline off, the viewer paged ten times at 2 s per photo (`PHOTOS_UITEST_PACE`). Before = the metrics commit without
18.1.1/18.1.2, after = with them (with the 4096 px prefetch after 1.5 s; now 3 s, see below). Script and JSON:
`~/aloha-work/photos-tools/r8load/` (`measure.sh`, `summary.py`, `before*/after*.json`); shots
`ios-fix-shots/r8-load/`. The Mac was heavily loaded by parallel builds (load average 100–600) and the PHP test server
took 2.3–3.9 s per uncached 1024 px preview, so the times are far above a real server's; the counts are what compares.

| Phase | Before | After |
|---|---|---|
| 2 covers: served from the device | 9 of 40 (22 %): 6+3 memory, 28 downloaded | 17 of 38 (45 %): 9 memory, 4 disk, 4 smart offline; 18 downloaded |
| 3 viewer, smart offline on, 1.5 s/photo: 1024 px from the device | 47 of 54 (87 %), 5 downloaded | 24 of 27 (89 %), 1 downloaded |
| 3 viewer: sharp picture p50 / p95 | 0 / 29 ms (11 pages) | 0 / 1194 ms (9 pages; one page waited for the server) |
| 4 viewer, no smart offline, 2 s/photo: 1024 px from memory when shown | 2 of 22 (9 %) | 14 of 24 (58 %); 10 neighbours and 8 large previews loaded ahead |
| 4 viewer: pages sharp while shown | 7 of 9, p95 768 ms | 9 of 9, p95 1606 ms |
| All phases: first picture (any size) | p50 = p95 = 0 ms | p50 = p95 = 0 ms |

Reading: one cache key doubles the covers served from the device — the rest are photos the grid never loaded in the
run (older memories), and their files now serve the grid in turn. Before 18.1.2 the viewer already had one page ahead,
because the paging stack builds the next page early, and smart offline holds most recent photos at 2048 px; the
neighbours help most when photos come from the server and the user looks at each for a few seconds (phase 4: every page
was sharp while shown instead of 7 of 9, 58 % of them straight from memory). At one photo per second (also measured)
neither build kept up with a server needing 2–4 s per preview. The worse p95 of phase 4 came with eight 4096 px
downloads competing with the neighbours on the slow server; the large preview now waits 3 s instead of 1.5 s, so quick
browsing no longer asks for it. The §10 budgets (150 ms cached, 600 ms uncached) are met for every first picture and
for cached pages; uncached sharp pictures are bound by the server here.

### 18.2 Importance-aware cache: recently viewed, importance ranking, per-size budgets, memory pressure [evict]

The caches keep what matters to the user longest: what was looked at lately, what the app shows first (covers, key photos,
memory covers), and the thumbnails the grids cannot do without. Before, one LRU by file date decided for every size at
once, and a memory warning emptied the whole memory cache.

#### 18.2.1 Recently viewed

- A photo the viewer shows for at least one second (`AccountServices.viewedAfter`) counts as viewed. The viewer runs
  `AccountServices.viewerShows(_:neighbours:)` in a `.task(id: currentFileId)` (one line in `MediaViewer.swift`); paging
  on or closing cancels it, so flicking through photos records nothing.
- Per account, in the account database: table `recentlyViewed(fileId, viewedAt, count)` (`CacheImportanceStore`,
  migration `v8-cache-importance`). One upsert per view; only the newest 2000 photos are kept (the bound is applied in the
  same transaction). It survives relaunches and goes with the account (logout, removal).

#### 18.2.2 Importance (`CacheImportance`, PhotosDomain)

One pure scorer, used by smart offline (`SmartOfflinePolicy.score` delegates to it; `SmartOfflineReason` is its
`Reason`) and by the preview cache's eviction. A photo's score is the best of its reasons (0…1):

| Reason | Score |
|---|---|
| On this day in the next 7 days | 1.0 − 0.01 per day away |
| Recent (last 12 months) | 0.9, halving every 60 days |
| Viewed (last 90 days) | 0.7, halving every 14 days; +0.025 per further view (≤ +0.1) |
| Memory cover (the memories strip) | 0.65 |
| Album opened (last 30 days) | 0.6, halving every 7 days |
| Key photo of a Library year, month or day (and a day's highlights) | 0.5 |
| Cover of an album, place or tag | 0.45 |
| Face (a person's cover) | 0.4 |
| Favourite | 0.35 – 0.55, newer higher |

The first, second, fifth and last rows are smart offline's scores of before, unchanged. Covers and faces come from their
tables (`album.coverFileId`/`lastPhotoFileId`, `place`, `tag`, `person.coverFileId`); key photos and memory covers are
worked out by the app (`LibraryZoomModel`, `MemoriesStrip`), which hand them to `AccountServices.noteCacheRole` /
`noteKeyPhotos(of:)` after building them (table `cacheRole`, rewritten only when the set changed). Smart offline's
candidate query includes viewed and role photos, so these are now kept for offline use too, ranked as above.

For eviction, scores are cut into tiers (`CacheImportance.tier`: 0 for no reason, 1–4 for the quarters of the score);
within a tier the least recently used file goes first. The tiers of the whole library come from two queries (the smart
offline candidate query and the roles), never one query per file: 100 000 photos take well under a second.

#### 18.2.3 Per-size pools (`CachePool`, `CachePoolBudgets`, `CacheEviction.plan`)

- Pools by bucket: **thumbnails** (64, 256), **screen** (1024, anything up to 2048), **large** (4096).
- The limit (the user's `previewCacheLimitBytes`, else the default below) is the total. Large previews get 15 % of it, at
  most 300 MB, as a hard cap. Thumbnails and screen previews share the rest half and half; either may use room the other
  leaves free. When the cache is over its limit, the pool furthest over its share gives back first; only when every pool
  is within its share (offline-pinned previews take the room) does the least important file of any pool go.
- Default limit: a twentieth of the free space for caches (`volumeAvailableCapacityForOpportunisticUsage`), at least
  512 MB, at most 4 GB (2 GB with 40 GB free; 2 GB when the free space is unknown). Shown in Settings › Storage as
  "1.2 GB, up to 2 GB".
- Offline-pinned previews still count and are never removed. Trims run as before: at launch, on background, every 2000
  downloads; the plan is a sort of one integer per file (100 000 files plan in about 0.25 s in a debug build).

**Whole-library contract** (with §18.3): `UserDefaults.standard` key `cacheWholeLibraryThumbnails`
(`CacheLimits.wholeLibraryThumbnailsKey`; its default and setting belong to the filler). When true, the 64 and 256 files of
photos still in the library — same file id and the library's current ETag (or its edit `<etag>_e…`, or the ETag-less
`0`) — are never removed and do not count towards any budget. When false they are ordinary members of the thumbnail pool.

#### 18.2.4 Memory pressure (`MemoryImageCache`, `MemoryPressurePolicy`)

The decoded previews live in an own LRU with a byte budget (the old `NSCache` budgets: iPhone physMem/80 within 48–120 MB,
Mac and Vision Pro 200 MB) instead of `NSCache`, which empties itself and cannot be told what to keep. On a memory
warning (`DispatchSource` memory pressure, also on the Mac):

- the viewer's photo keeps every decode (on a critical warning: up to 1024 px), its neighbours (±1 page) decodes up to
  1024 px (critical: tile-size only);
- covers, key photos and memory covers keep their tile-size decodes (≤ 512 px);
- of the other tile-size decodes the most recently used stay within a quarter of the budget (critical: a tenth): the tiles
  on screen;
- everything else goes, so 4096 and 1024 decodes are the first to go.

On iPhone, iPad and Vision Pro the app does the same as a warning when it goes to the background.

### 18.3 Filling the cache: whole-library thumbnails, background preparation, HEIC storage [fill]

Measured on the 8089 test library (448 JPEG photos, 1920 px, Nextcloud 33, server previews by gd at quality 80): a 64 px
preview is 1 538 bytes on average, 256 px 11 163, 1024 px 136 639, 2048 px 604 084 (a "2048" request of a 1920 px photo
returns 1920 px). A 64 px preview made on the device from the 256 px one (ImageIO JPEG 0.8) is 2 430 bytes.

#### 18.3.1 Thumbnails of the whole library

- *Setting* — Settings › Storage › Thumbnails: "Keep thumbnails of the whole library" (`UserDefaults`
  `cacheWholeLibraryThumbnails` = `CacheLimits.wholeLibraryThumbnailsKey`, read through `LibraryThumbnailSettings.isEnabled`,
  which knows the default; the default is also registered at launch so `bool(forKey:)` agrees). Off: the row shows the
  estimate first ("About 680 MB for 50,000 photos": photos with a server preview × the average sizes of this device's
  cached 256/64 px previews, or the typical sizes above while fewer than 30 are cached). On: a progress bar
  ("12,340 of 48,000 photos", "All 48,000 photos", "Waiting for Wi-Fi"). iPhone/iPad also get "Use cellular data"
  (`cacheWholeLibraryThumbnailsOnCellular`, off).
- *Default* — on on the Mac, off on iPhone, iPad and Vision Pro. The thumbnails take 13.6 KB a photo: 136 MB for 10 000
  photos, 680 MB for 50 000, 1.4 GB for 100 000. That is small next to a Mac's disk, but on a phone it is as much as the
  whole 2 GB preview cache's useful part for a large library, and the iPhone grid's default tiles are what it fills
  anyway while scrolling (77 pt tiles at 2× need the 256 px bucket); so the phone keeps it a choice with the estimate
  shown. (At the Mac's default zoom tiles are 130 pt and use 1024 px; there the thumbnails serve the smaller zoom steps,
  Years and Months, and offline browsing.)
- *What* — for every photo the timeline shows (not archived, not a Live Photo's video, not in an excluded folder) that
  has a server preview: the 256 px preview, downloaded, and the 64 px one, made on the device from it (half the
  requests to the server; no network at all when only the 64 px one is missing). Photos without a server preview (HEIC
  without a provider, RAW) are left out: their thumbnails need the original. A lossless (PNG) preview is stored as HEIC
  (§18.3.3).
- *How* — `LibraryThumbnailFiller` (one per account, owned by `SmartOfflineManager`) walks the library newest first in
  pages of 500 (keyset on the timeline's index) and fills what is missing; the files on disk are the state, so a pass
  that stops is resumed by the next. Files are written into the disk cache without being decoded
  (`PreviewCache.storeFile`), so the memory cache keeps what is on screen. Pacing (`FillPacing`): a download starts only
  when the image pipeline has nothing to load from the server and no prefetch queued (`ImagePipeline.isNetworkIdle`)
  and has been so for 1.5 s; while it is busy the filler looks again every 0.5 s; two downloads at a time (the grid has
  six lanes). It stops without an unmetered network (cellular and hotspots unless allowed, never Low Data Mode) and in
  Low Power Mode, and goes on in the next pass.
- *Not through `ImagePipeline.prefetch`* (the brief's suggestion): its queue keeps the newest 200 prefetches and drops
  the oldest, so a filler would push out the grid's own prefetches; it decodes every preview into the memory cache; and
  it does not say when a preview is done, which pacing and progress need.
- *When* — after a sync in the foreground (with smart offline's pass, at most every 10 minutes), right after the
  setting is turned on, in smart offline's `BGProcessingTask` on iPhone/iPad (external power; now scheduled when smart
  offline *or* the thumbnails are on) and in the Mac's background activity.
- *Evict contract* — while on, the evict side keeps the 64/256 px files of photos still in the library and does not
  count them against the pools (§18.2). Off: ordinary cache files, nothing is deleted at once.

#### 18.3.2 Preparation before the app is opened

`BackgroundPreparation` puts into the disk cache what the app shows first, most important first, at the sizes the views
ask for: the first screen of the timeline, the covers of today's memories (1024 px, `MemoriesStrip`), the covers of the
albums opened in the last 14 days (1024 px), the timeline's second screen, the first four story pages of each memory
(1024 px) and the first screen of each of those albums — at most 3 memories, 3 albums and 300 previews (about 15 MB at
the iPhone's sizes); what is cached is skipped. Tile sizes follow the grid: the stored zoom step (`gridColumns`) and
square tiles (`squareTiles`) at the platform's reference width (`GridColumns`), so the bucket per photo is the one
`AccountServices.previewRequest` picks (256 px on iPhone, 1024 px on the Mac and iPad at the default zoom).

- *iPhone, iPad* — after the sync of the existing background refresh (`BGAppRefreshTask` `com.nextcloud.photos.refresh`,
  `BackgroundTasks.runRefresh`): the sync brings the new photos the first screen will show. No new task identifier.
  Also at the end of smart offline's processing task.
- *Mac* — smart offline's `NSBackgroundActivityScheduler` activity now always runs (every 30 minutes, tolerance 15,
  background quality, deferred while the Mac is busy or in Low Power Mode) and prepares after smart offline and the
  thumbnails; the Mac app keeps running with its windows closed.
- *Vision Pro* — only while the app is open.
- Only on an unmetered network and not in Low Power Mode; four downloads at a time; written without decoding.
- Covers and memories are requested by their views with `etag: ""` until §18.1's one-cache-key change: the prepared files
  (real ETags) serve them once that is in.

#### 18.3.3 HEIC storage

Measured first (80 of the 2048 px previews, PSNR over RGB):

| | bytes vs JPEG | PSNR vs the original |
| --- | --- | --- |
| server JPEG (gd q80) | 100 % | 37.81 dB |
| HEIC from it, q 0.5 | 67.1 % | 35.46 dB (−2.35, worst −5.50) |
| HEIC from it, q 0.6 | 88.9 % | 36.55 dB (−1.25) |
| HEIC from it, q 0.7 | 100.9 % | 37.16 dB (−0.65) |

Re-encoding the server's JPEG previews adds a second generation of artefacts: at the same fidelity a HEIC copy is not
smaller, and choosing per photo the smallest HEIC within 40 dB of the JPEG saves 3 % overall (38 dB: 9 %) for about 0.1 s
of CPU a photo. So JPEG previews are kept as they come. PNG files get PNG previews from the server, 3–9 MB at 2048 px;
encoded as HEIC (quality 0.7) from that lossless source they take 11.5 % of the PNG (6 test PNGs: 37.7 MB → 4.35 MB)
at 39.3 dB, better than the server's JPEGs. Rules (`PreviewTranscoding`):

- A preview whose content is PNG, TIFF or BMP (one image) is stored as HEIC at quality 0.7 when the device can write
  HEIC and the result is smaller; anything else is stored as it came. Smart offline's 2048 px files are named `.heic`
  or `.jpg`; ImageIO reads both by content, the lookups do not care.
- *Lazy migration* — every smart offline pass converts kept PNG previews of earlier versions without the network
  (foreground at most 20 per pass, background no limit): the HEIC file is written and recorded before the old one is
  removed. A JPEG file is looked at once per launch (its first bytes) and left alone.
- The thumbnail filler and the preparation store lossless previews as HEIC too (in the `.jpg`-named cache files; the
  cache reads by content). The pipeline's own 1024 px downloads are not converted: that is the load path, and on the
  test library it would save nothing (all JPEG). Converting PNG previews of the 1024/4096 pools in the background is
  possible later (⬜).

## 19. M10 — Simpler navigation: sidebar and toolbars

Goal (the owner's words): "simplify the left sidebar navigation and the toolbar". Fourteen ideas in three packages;
every removed button keeps its keyboard shortcut and menu bar command, active filters stay visible.

### 19.1 Sidebar: filters instead of rows, Places with the map, Albums and Shared, Utilities, editable sidebar, account [sidebar]

**Rows (the default, "slim" sidebar).** First group: Library, Favorites, Memories, People, Places. Group "Albums": on the
Mac the top albums (pinned ones first, then the ones used last in this app, then the most recently changed — at most 8,
`SidebarAlbums`), "All Albums", and Shared. Group "Utilities", collapsed by default: Folders, Tags, Archive, Recently
deleted, Clean up, Insights, Stickers (+ Backup on iPad/Vision Pro and in the iPhone's Collections list; on the Mac Backup is
in Settings). Before: 20 rows in three expanded groups.

**Nothing becomes unreachable.** Every `AppDestination` stays: Go menu (⌘1…⌘9 kept for Library, Photos, Videos, Favorites,
Memories, Map, Albums, Shared albums, Smart albums — now fixed per place, not by position), deep links
(`nextcloudphotos://photos`, `…/map`, `…/smartAlbums`…), Shortcuts (`OpenPhotosViewIntent`), widgets, notifications, the
command palette and scene restoration. A destination without a row opens its row (`SidebarLayout.entry`):

| Destination | Opens |
|---|---|
| Photos, Videos | Library with that media filter (`TimelineScreen(initialKind:)`); the filter is shown in the Library's toolbar |
| Map | Places in its Map mode |
| Smart albums | Albums with the smart albums pushed (Back → Albums) |
| Shared with you | Shared with "Shared with you" pushed |
| On this day | Memories with On this day pushed |
| Duplicates, Free up server space | Clean up at that section (§19.3) |

*Decided:* **Favorites stays a pinned row** (a filter too, in the Library's filter menu of §19.2): it is a collection people
open directly, as in Apple Photos' Pinned, widgets link to it, and a row whose highlight follows a filter the user can change
in place would be confusing. **Memories keeps its row**: the Library's strip is hidden while a filter is on and can be turned
off; the row also holds On this day, trips and the year in review. **Tags moves to Utilities** (managing tags is a utility;
the search already has tag tokens). **Places needs no server feature any more**: without the server's places it is the map
(made on the device from GPS data); with them a segmented "Map | Grid" control switches between the map and the place
tiles, the choice is remembered (`placesMode`), "Map" always opens the map. **Shared** shows the shared albums with a
"Shared with you" link on top (also over the empty state); on a server without shared albums the row is "Shared with you"
itself. **Albums** "+" is a menu: New album, New Smart Album (smart albums have no row of their own any more).

**Editable sidebar.** Mac: right-click a row → Pin / Unpin (moves a row between the first group and Utilities), Hide from
Sidebar, Edit Sidebar…, Restore Default Sidebar; rows of the first group are reordered by dragging; album rows: Pin / Unpin
(keeps the album at the top of the list), Open in New Window. View ▸ Edit Sidebar… opens a sheet with every row: a check box
to show it, Pin/Unpin, drag to reorder the pinned rows, Restore Defaults. Library cannot be hidden or unpinned; Albums and
Shared stay in their group. Stored per device in `UserDefaults` (`sidebarLayout`, pinned albums per account in
`sidebarPinnedAlbums.<account>`); the default writes nothing. iPad and Vision Pro use the system's sidebar editing
(`TabViewCustomization`, now `@AppStorage("sidebarTabCustomization")`: per device, a new key so the slim default applies),
with "Restore Default Sidebar" in the menu of the account row at the bottom of the sidebar (a section action would be a permanent row). The iPad's Albums group
reads "All albums" and "Shared", as on the Mac; it does not list the top albums (a tab view has one selection type, and
album tabs would leave stale ids in `TabViewCustomization` as albums come and go).

**Account (Mac).** The large header with the logo is replaced by a compact row at the bottom of the sidebar (initials badge,
name, server, ⌃⌄), like the account button of Mail or Music: a menu with the accounts (check mark on the shown one), Add
Account…, Settings… (`SettingsLink`; ⌘, as before). iPad and Vision Pro keep the header with the account menu; their
Settings entry is the toolbars package's account button (§19.2).

### 19.2 Toolbars: one filter menu, one zoom control, upload when needed, a calmer viewer, three tabs [toolbars]

Fewer buttons, the same reach: every removed button keeps its menu command, key and link.

1. **No ⌘K button.** The window toolbar's command palette button is gone. The palette stays on ⌘K and Go ▸ Quick
   Actions… — `PhotosCommands` is the menu bar on the Mac and the keyboard shortcuts on iPad, iPhone with a keyboard and
   Vision Pro, so the item exists wherever there is a keyboard. *Decided:* the Search tab keeps its ⌘ button (iPhone,
   iPad, Vision Pro): it is in Search, not the Library's bar, and is the only way to the palette without a keyboard.
2. **One filter menu** (`LibraryFilterMenu`, all platforms, the Library only): Show (All Items, Photos, Videos,
   Favorites), a "Ratings and Flags" submenu (today's culling filter with Auto-Advance and Delete Rejected…, with system
   tags), "Hide partner photos" (with partner folders; it is the account’s setting, SH-8) and "Clear all filters". While a
   filter is on, the symbol is filled and the button carries the number of active filters (badge; VoiceOver "Filter, 2
   active"), and chips under the title (`LibraryFilterChips`: "Favorites ✕", "Picks ✕", "Without partner photos ✕")
   clear one filter each: a row above the grid on the Mac, floating under the navigation bar elsewhere (a
   `safeAreaBar` did not draw them and a horizontal scroll view there crashed SwiftUI on iOS 27.2).
   `LibraryFilters` is the model (chips, count, clearing). *Decided:* no further filters — the grid query
   (`LibraryStore.sql`) knows media kind, culling and excluded folders only; "Edited" or "RAW" would need new store
   conditions, which is not "cheap", so they are left for later. Contract with §19.1: `TimelineScreen(initialKind:)`
   opens the Library with that kind set (Photos, Videos, Favorites from links and menus); `TimelineScreen(filter:)` still
   makes a timeline of its own.
3. **One zoom control.** Years · Months · Days · All Photos stays (the Mac's toolbar, the floating picker elsewhere). The
   Mac's zoom slider and its two step buttons are gone; ⌘+/⌘−, View ▸ Zoom In/Out and a pinch step the grid. *Decided:* no
   slider in All Photos either — it duplicated ⌘+/⌘− and the pinch and took the most toolbar room.
4. **Upload when needed.** No upload button in the Library's toolbar. Mac: File ▸ Upload Photos… (now ⌘U, was ⇧⌘U),
   dropping files on the Library, File ▸ Import from iPhone or iPad. iPhone, iPad, Vision Pro: the account button's
   Upload submenu and the Collections tab's "+" (New album…, Upload) — from Photos, files, the camera or the scanner
   (`UploadMenuItems` + `uploadPresenter`, the pickers live outside the menu). The toolbar shows the uploads only while
   they run or when some failed (`TransfersIndicatorState`); on iPhone the tab bar's accessory shows them.
5. **A calmer Mac viewer.** After Back and the date: favourite, info, share, edit, More. Delete moved into More
   ("Delete…", asks first) and onto ⌫/⌦ in the viewer (and Image ▸ Delete… ⌘⌫); no ⌘K button. Vision Pro's ornament
   shows the same buttons in the same order (with the spatial button), Delete in More. *Open:* the window's search field
   still shows while a photo is open. Tried on macOS 27.2: `toolbar(removing: .search)` on the viewer or on the detail
   column leaves a `searchable` of the split view in place; `searchable` on the detail column shows no field at all; a
   conditional `searchable` would rebuild the window's content (the open viewer closes). Needs a field of our own in
   the toolbar or a later SwiftUI.
6. **Three tabs on iPhone: Library, Collections, Search.** Settings is a sheet (`SettingsSheet`, Done) from the account
   button (`AccountMenuButton`: the account's initials in a circle, a glass button of its own after Select; menu: name and server with the accounts to switch to
   and Add account…, Upload, Settings) in the Library's and the Collections tab's top bars. `nextcloudphotos://settings`,
   the command palette and a restored window that was on Settings open the sheet (`CompactNavigation.sheets`); the
   account button is also on iPad and Vision Pro, which lost their Settings tab too. On the Mac Settings stays the
   Settings window (⌘,); the account button's Settings item is a `SettingsLink` there.
7. **iPhone Library top bar:** filter menu and Select, then the account button; the old All/Photos/Videos/Favorites
   picker, the ratings menu, the partner button and the upload menu are inside those menus.

### 19.3 Clean up: duplicates and free space in one screen [cleanup]

One screen answers "how do I get space back?" (`CleanUpScreen`, `Advanced/CleanUpScreen.swift`). It replaces the two
utility rows Duplicates and Free up server space with one entry point; their screens stay as its detail screens.

- **Sections**, in this order, each a row with an icon, what it found in words, its size on the right and up to six
  small pictures (the largest, or the kept copy / best shot); a click or tap opens the screen that reviews and deletes:
  1. *Duplicates* — "N sets of identical copies · X can be freed" (the copies besides the suggested one that the user
     may delete) → `DuplicatesScreen` (§7.15, unchanged).
  2. *Similar shots* — series of shots of one scene across the whole library, "N series · X in the shots besides the
     best" → `SimilarShotsScreen` (below).
  3. *Large videos* — videos over 100 MiB, "N videos over 100 MB · X" → `FreeSpaceScreen(categories: [.largeVideos])`.
  4. *Screenshots and screen recordings* → `FreeSpaceScreen(categories: [.screenshots, .screenRecordings])`.
     Rows 3 and 4 together are the old "Free up server space" (§7.15, same rules in `Cleanup`).
  5. *Free up space on this iPhone/iPad* (iPhone and iPad only, under "On this iPhone/iPad") — the device's available
     storage (`volumeAvailableCapacityForImportantUsage`) → the Backup screen's "Free up space on this iPhone" (§7.18.8);
     without access to the photo library it opens Backup instead. Not offered on the Mac and Vision Pro (no
     backed-up device library to thin out).
- **Headline**: "Up to X can be freed" over rows 1–4, each file counted once (`CleanUpTotals`: a large video can also
  be a duplicate copy or a similar shot); "Nothing to clean up" when all are empty. The footer says that nothing is
  deleted until the user confirms and that deleting deletes on the server and so everywhere. Every delete goes through
  the same server-delete confirmation as before (count, size, trash bin or permanent).
- **Loading**: all sections at once, off the main actor (store queries, not the whole index); rows show "Looking…"
  until theirs is done. The screen loads again when the user comes back from a detail screen, keeping the old numbers
  until the new ones are there.
- **Similar shots** (`PhotosDomain/SimilarShots.swift`, query `SimilarityStore.similarShots()`): the photos compared by
  "Show Similar" (§15.5; current versions, not archived, no Live Photo videos) in time order, read with a cursor and cut
  on the way: a photo joins the series of the one before when it is at most 10 minutes later and its sketch at a cosine
  of 0.84 or more (`Similarity.seriesThreshold`/`seriesGap`, as for the best shot of a series). Copies of one shot
  never compete: a HEIC and the JPEG beside it (`CopyStacks` rule: same folder, same name apart from the extension,
  ≤ 2 s) or the same file elsewhere (same size and capture second — that is Duplicates' business) are one shot. A series
  has two or more shots; the best is chosen as in Show Similar (a favourite, else the best aesthetics score, else the
  middle one; since round 11 the best-shot analysis of §21.4) and keeps all its files; the others are offered, as far as the user may delete them (a series where
  nothing can be deleted is not listed). The screen lists the series newest first (at most 100 at a time), each with
  its shots as cards (the Duplicates cards: Keep/Delete badge, file name and folder, size); a click or tap keeps another
  shot; "Delete N other shots…" asks the server-delete confirmation. While the comparison is incomplete it says how many
  photos were compared and, like Show Similar, compares the cached previews not compared yet a few seconds at a time
  (not in Low Power Mode, warm or low on battery) and looks again. With "Find similar photos" off, the row says so and
  the screen offers "Turn On" (the same setting as Settings › Search).
- **Old places keep working**: `AppDestination.duplicates` and `.freeSpace` stay (deep links `nextcloudphotos://duplicates`
  and `…/freeSpace`, scene restoration, the command palette, the Go menu while the sidebar lists them) and show Clean up
  scrolled to their section (`CleanUpSection.opened(by:)`: Duplicates → Duplicates, Free up server space → Large videos,
  with Screenshots right below), which lights up for a moment. The new sidebar/Collections row `.cleanUp` (§19.1)
  opens `CleanUpScreen()`.
- Decided: the old destinations open the overview at their section instead of pushing the detail screen, so every way
  in shows the sizes of all sections and Back never leads somewhere unexpected; the detail is one click or tap away.
  Device storage stays a row that opens Backup's screen (it needs the photo library and a server check that takes a
  while), not a number computed up front.

## 20. M11 — Stabilization

Goal (the owner's words, after a fresh look at the app): "implement all the issues you found". No new features: fix
what is visibly wrong, verify what was built (stock server, older servers, accessibility, German), simplify the
screens that grew too much, raise code health, and prepare a release that Nextcloud's team can take to TestFlight.

### 20.1 Visible bugs: sidebar icons, photos without a preview, story snapping, the Mac memories strip [fixes]

1. **Sidebar symbols.** On the Mac only Library showed its symbol (half drawn); Favorites, Memories, Places and every
   album row kept the space but showed none. Cause: the launch reveal (§17.6.3) faded the whole split view in with an
   animated `opacity` and scale in one animated transaction; sidebar rows built in it kept their symbols at the opacity
   of that moment (it came and went with the launch's timing: about one launch in four). The content is now never
   animated: a cover in the window's background colour fades away above it, animated on its own (same look and
   timing; the hint of scale is gone). The iPad's sidebar has the same reveal and gets the same fix.
2. **Photos without a server preview** (a truncated JPEG, a format no preview provider reads: the server answers 404
   and the original cannot be thumbnailed on the device either — item 7 makes one on the device whenever it can) no
   longer stay grey squares. The tile shows a symbol of
   what the file is and, from 96 pt up, its name and "No preview" (VoiceOver: "…, No preview"); a photo page in the
   viewer says the same with a line that it is asked for again. `PreviewFailureLog` in the image pipeline remembers
   such files per version (file id + ETag): they are asked for again only after the library synced since **and** a
   backoff passed (2 min, 10 min, 1 h, 6 h, then daily), a new version at once; network errors and cancellations do not
   count. Scrolling past, other sizes, prefetches and the viewer cost no request in between. In memory per account and
   launch (a launch asks once more), at most 5000 entries.
3. **Story snapping without a scroll target behaviour** (iPhone, iPad, Vision Pro, where the strip lives in the UIKit
   grid and `.viewAligned` trapped SwiftUI, STATUS §M8). The strip watches its scroll phase (`onScrollPhaseChange`) and
   scrolls to the card `MemoryStorySnap` picks with a `ScrollViewReader` (setting the scroll position to the card it
   already holds would not move it): compact (one large card), when the finger lifts, one card on in the direction it
   was moved if it was flung or dragged a third of a card, else back; wider (and a compact strip that still came to rest
   between cards), the strip glides out and settles on the nearest card. The inset is a content margin, so a snapped
   card rests 12 pt in, like the first one. The Mac keeps `.viewAligned` (its strip is not in a grid).
4. **The Mac memories strip** is compact (story cards 128 pt high instead of 210, strip cards 150 × 128) under a title
   line "› Memories" that folds the cards away (a click; the state is remembered on this Mac, key `memoriesCollapsed`);
   folded, the line shows the first memory's title. Its context menu keeps "Show as Stories" and "Hide Memories". The
   title line sits in a scroll view that does not scroll: the toolbar's scroll edge effect goes to the first scroll view
   under it, and with a plain row there it went to the grid's and blurred the grid's first header.
5. **Undo of a delete** (found in the round's tours on a Nextcloud 35.0.3 server: the two photos stayed in the trash
   bin). Undo takes deletes still queued out of the queue and puts their rows back, and restores from the trash bin
   only what reached the server. A delete whose DELETE request went out but failed (a timeout, a 5xx — the server may
   have moved the file to its trash bin all the same, as a loaded server does) waited for its retry, was taken out of
   the queue, and only its row came back: the file stayed in the trash bin and left the library with the next sync.
   The queue now remembers whose DELETE went out (`DeleteWithdrawal.maybeSent`); Undo looks for those in the trash bin
   too and restores them, without counting a file that is not there as a failure. The trash bin API itself behaves
   the same on Nextcloud 35.0.3 and 36 (`oc:fileid` kept, `<name>.d<time>` names, `MOVE …/restore/` with
   `Overwrite: T` → 201).
6. **The Places card's caption** ("411 photos") sat at the bottom of the map. On the iPhone the card is the last one
   of Collections' first screen, and its lower 40 pt rest under the floating tab bar: the bar's glass covered the
   caption's right half ("411 phot…"; the caption was never truncated, it was covered). It now sits at the top of the
   map, one line, its own width. Every card caption of Collections keeps to its card at the default and the largest
   accessibility text size and in German (album and Favorites captions move below the cover at accessibility sizes,
   memory cards stop growing at xxLarge). The shelves' rows are plain `HStack`s (at most 12 cards): a `LazyHStack`
   took its height from the cards it measured first and cut the other titles at accessibility sizes ("r7-grid-…" in
   two of its four lines).
7. **Previews made on the device** (`DevicePreview`, polish). Apple's and Google's apps always show a picture; a
   Nextcloud with the default preview providers has none for videos (Movie provider off), HEIC/TIFF photos (HEIC and
   TIFF providers off) and for images above `preview_max_filesize_image` (50 MB). When the server answers 404 — or says
   `has-preview: false`, then without asking — the app makes the preview itself:
   - **Images**: the original is downloaded once into the originals cache (at most **50 MB**; a larger file is not
     downloaded and the viewer says "… at 72 MB the file is too large to make one here") and decoded downscaled with
     ImageIO. Types ImageIO does not read are not downloaded.
   - **Videos**: one frame (1 s in, or a third of a short clip; the next key frame within 2 s) through `AVURLAsset` fed
     by `StreamingAssetLoader`/`MediaByteSource`, i.e. byte-range GETs of the DAV original through the account's own
     HTTP client (its authentication, trusted and client certificates), 256 KB per range, at most **16 MB** per frame
     (counted before each request; at the limit, loading and generation stop at once), 30 s at most. Formats
     AVFoundation cannot play (WebM, Matroska, AVI) are not read.
   - **Stored once for every size**: made at least 1024 px large and stored in the preview cache under the preview's
     own key (file id, ETag, bucket) for every bucket up to that size, each downscaled from it; grid, viewer, covers,
     memories find it there and cost no request. Requests made without the original's URL (covers, memories) find it
     in the library index (`ImagePipeline.setSourceProvider`).
   - **Not hammering the server**: the backoff of item 2 applies to a file the device could not draw either; the
     reason is kept (`NoPreviewReason`: unreadable, too large, Low Data Mode) and the viewer says it. In **Low Data
     Mode** nothing is downloaded for a preview (an original already on the device is used); such a file is tried as
     soon as Low Data Mode is off, without waiting for a sync. The background cache fill only fills files with a server
     preview, so nothing is rendered behind the user's back. No server change.
   - **The two files of the 8089 test library** that have no preview (`Garden party 89421 – guest uploads/evil.jpg` and
     `party.jpg`, written 2026-11-22 into a folder that by its name belongs to a guest-upload test, not into `Test
     library`) are **24-byte files**: the JPEG start marker,
     the JFIF header and the first four bytes of a quantisation table, no image data. `has-preview` is true (the JPEG
     provider claims the MIME type), the provider's decode fails and the preview endpoint answers 404. Not the format,
     the size or a missing provider: there is nothing to draw, on the server or on a device (Apple's Photos would
     show them as unreadable too). They keep "No preview", and the viewer now says "Neither the server nor this app
     can read the file: it may be damaged…".
8. **The Favorites card** of Collections shows the newest favourite as its cover, as Apple's Photos does, with a small
   heart before "Favorites" on its caption (at accessibility sizes, where the title is below the cover, the heart is a
   small glass badge on the cover, so that the word keeps the card's width); the gradient with the large heart stays
   for a library without favourites.
   The cover follows the index (`LibraryStore.observeNewest(.favorites)`: one row from the favourites' partial index,
   hidden folders excluded like the Favorites grid). The iPad and Mac sidebars list Favorites as a row with its heart
   symbol, as Apple's sidebar does (no cover there); the Apple TV shows a row of the favourites themselves; there is
   no other Favorites cover.

### 20.2 Servers: stock Photos, Nextcloud 33 and 34 [servers]

The app was run against four servers (2026-11-26), each with the 448-photo test library in `Photos/Test library` and the
sample files of a new account:

| Name | Nextcloud | Photos app | How it was set up |
|---|---|---|---|
| **stock** (8093) | 36.0.0 dev | 9.0.0-dev.0, upstream master | local install (`photos-srv6`) |
| **extended** (8091) | 36.0.0 dev | 9.0.0-dev.3, `deploy/devel-all` (all feature branches) | local install (`photos-srv3`) |
| **NC 33** (8095) | 33.0.11 | 6.0.0, bundled | `scripts/test-server.sh` with the release archive (docs/TESTING.md) |
| **NC 34** (8096) | 34.0.6 | 7.0.0, bundled | the same |

None of them has Recognize, an Assistant provider or a `photos` capability (companion API S1).

**How.** (1) A raw protocol probe per server (curl: capabilities, the Photos page's initial state, every DAV collection
and property the app reads, SEARCH by capture time, PROPPATCH of favourite, metadata and Live Photo link, preview sizes,
chunked upload v2, trash and restore). (2) The integration tests (`PHOTOS_IT_SERVER`, 23 tests: detection, sync, changes
made elsewhere, albums, public links, uploads including an interrupted chunked one and a background session, trash,
tags, folders, partner folders, app data files, camera details, link shares). (3) The iPhone simulator with the UI
tours of rounds 1–9 (`PhoneTourTests`, `SmokeTests`, `ToolbarsTourTests`, `CleanUpTourTests`, `PlacesTourTests`,
`FeelTourTests`, `OrganizeTourTests`, `EditTourTests`, `CacheEvictTourTests`, `LibraryTourTests`) with the server's
request log open beside it (for the stock server a second PHP listener on the same installation logged every request).
(4) The Mac test build against stock (signed in, detected, indexed; its screens could not be looked at, STATUS §20.2).
What was seen and what failed is in STATUS §20.2.

**Server matrix.** ✅ works · — not offered by the server, the app hides it or explains it · (n) note below.

| Feature (screens) | stock | extended | NC 33 | NC 34 |
|---|---|---|---|---|
| Login Flow v2, app password, login links | ✅ | ✅ | ✅ | ✅ |
| Detection (Settings › Server features) | core | core + 11 extended (1) | core | core |
| Library sync: SEARCH by capture time (keyset paging), changes, reconciliation | ✅ | ✅ | ✅ | ✅ |
| Previews 256/1024/full (`/apps/photos/api/v1/preview`), BlurHash placeholders | ✅ | ✅ | ✅ | ✅ |
| First-sync total and skeleton (`timeline/days`) | — (no total) | ✅ | — | — |
| Favourites, move, delete with `If-Match`, Recently Deleted + restore | ✅ | ✅ | ✅ | ✅ |
| Albums: create, rename, add/remove, public link, shared albums, collaborators | ✅ | ✅ | ✅ | ✅ |
| Album cover, description, comments, "last changed" from the server | — (2) | ✅ | — (2) | — (2) |
| Places (server places), Map, Travel and Countries | ✅ | ✅ | ✅ (3) | ✅ (3) |
| Places by country (`place-country`) | — (4) | ✅ | — (4) | — (4) |
| Tags: list, filter, assign, Tags screen | ✅ | ✅ | ✅ | ✅ |
| People (Recognize) | — (5) | — (5) | — (5) | — (5) |
| Smart albums, folder rules, edits, album covers (`/.nextcloud-photos/*.json`, app data files) | ✅ | ✅ | ✅ | ✅ |
| Batch fixes of date and place | ✅ metadata PROPPATCH | ✅ metadata PROPPATCH | ✅ written into the files (6) | written into the files (6), not applied in the UI run |
| Imports (Takeout, iCloud, Facebook…): place of a file without one | ✅ PROPPATCH | ✅ PROPPATCH | — (7) | — (7) |
| Upload: PUT with `X-NC-WebDAV-Auto-Mkcol`, chunked v2, background session, backup | ✅ | ✅ | ✅ | ✅ |
| Live Photo pairing (`metadata-files-live-photo` PROPPATCH) | ✅ | ✅ | ✅ | ✅ |
| Folders (PROPFIND, previews by SEARCH) | ✅ (8) | ✅ (8) | ✅ (8) | ✅ (8) |
| Shared with you (`/apps/photos/api/v1/shared`), partner folders | ✅ | ✅ | ✅ (old JSON shape) | ✅ (old JSON shape) |
| Link shares, sharee search, file comments | ✅ | ✅ | ✅ | ✅ |
| Notifications (On this day, shared albums) | — no app (Settings says so) | — no app | detected (push not tested) | detected (push not tested) |
| Captions, caption search, unified search of albums/places, On this day notifications setting | — | ✅ | — | — |
| Clean up (duplicates, similar shots, large videos, screenshots), memories, stories, film, search, cache fill | ✅ (on the device) | ✅ | ✅ | ✅ |
| Assistant (OCR, text, image analysis) | — no provider | — | — | — |

1. `albumComments`, `albumCover`, `albumDescription`, `albumLastModified`, `captions`, `captionsSearchable`,
   `configAPI` (from the initial state), `onThisDayNotifications`, `placeCountry`, `timelineDays`, `unifiedSearchPhotos`.
2. Covers chosen in the app are kept in `/.nextcloud-photos/album-covers.json` (§16.8) on every server; descriptions and
   album comments are hidden without the server's properties.
3. Photos 6 and 7 name some places by their district ("el Raval", "Eixample") where Photos 9 says "Barcelona": the place
   names come from the server's reverse geocoding, the app shows what it gets (moment titles too).
4. `place-country` comes only from the extended Photos (`PlaceMetadataProvider`); elsewhere the countries of Travel and the
   scratch map come from the opt-in Apple Maps lookup of the positions (§15.6), and Places is one flat list.
5. No test server has Recognize. People is not in the sidebar or Collections; a link to it (widget, Shortcut, another
   app) now explains that the server needs Recognize instead of doing nothing (`UnavailableLinkAlert`).
6. Nextcloud 33 and 34 answer a PROPPATCH of `nc:metadata-photos-original_date_time` / `-gps` with **500**
   (`FilesMetadataException: you do not have enough rights to update 'photos-original_date_time'`): metadata editing
   (`MetadataPropPatchPlugin`) arrived in Nextcloud 35. The app does not try it there (`metadataEdit` only from major
   version 35) and writes date and position into the file instead (`MetadataRewriter`, new version with `If-Match`).
7. The import keeps the file unchanged and notes in its sheet that places can only be added on Nextcloud 35 or later.
8. Not a server difference: on iPhone a grid pushed in the Collections tab (Favorites, a folder with photos) re-rendered
   without end and hung the app. It showed up on 33/34 because their root folder holds sample photos; the folder listing
   itself works on every server. Fixed: constant search bindings of the pushed screen (STATUS §20.1).

**Other differences found, none of which needs a change in the app:** the Photos page of Photos 6/7 has no
`gridDensity` initial state (the app's default applies); `nc:metadata-photos-place-country` is a 404 propstat (index
without it); the `shared` API answers in the old JSON shape (`fileid` as a number, `etag` at the top level), which the
parser already reads; the SEARCH properties, preview sizes (the largest preview is the original's size, here 1920 px),
chunked upload v2, auto-MKCOL, trash restore and Login Flow v2 behave the same on 33, 34 and 36.

### 20.3 Accessibility and German [a11y]

**Audits.** `UITests/AccessibilityAuditTests` runs Xcode's accessibility audit (`performAccessibilityAudit`: contrast,
element detection, hit areas, descriptions, traits, Dynamic Type, clipped text) on every main screen on iPhone and iPad:
Library, viewer and its info, Collections (iPad: the sidebar), Albums, Settings, Search, Clean up, Memories, and Library,
Settings, Collections and Search again at the largest accessibility text size (AX5). A finding fails the test unless
`AccessibilityAuditPolicy` accepts it with a stated reason; the accepted kinds are:
- a photo's own colours (tiles, the viewer);
- the system's chrome: content under the tab bar's glass, bar buttons that keep their size (the system shows them
  enlarged with the Large Content Viewer) and whose text the audit measures against the bar's glass (the accent itself
  is checked by `AccentPaletteTests`), the search field's prompt cut short at large sizes;
- "contrast nearly passed" (3:1 or more): the system's secondary label colours in headers, footers and subtitles, as
  Apple's apps use them; Increase Contrast makes them darker;
- findings for which the audit names no element (nothing to act on; they stay in the written report);
- at the default size, "partially unsupported" Dynamic Type and "may be clipped": the audit only guesses there; every
  screen is audited again at the largest size, where these fail;
- Search's start screen on the animated living wash, which the audit cannot sample (it reports even the black title;
  measured in the screenshot: 18.8:1 and 5.3:1), and the viewer's date pill, capped at accessibility2 on purpose;
- the iPad Library dimmed behind the sidebar that overlays it in portrait, and its memory captions under that sidebar;
  text "clipped", or measured against what is outside, only because its row is at the edge of a scroll area; text on
  glass and materials, which the audit measures against what is behind them (the cover under a caption plate, the
  photo under the iPad's info inspector): there the test measures the element's own pixels in the screenshot and
  accepts 7:1 or more, but only on an even background, never on a photo;
- the account row in the sidebar's bottom bar (`sidebar-account`): the badge's initials (white on the accent, 6.1:1,
  measured by the audit against the glass around the circle; a fixed-size picture hidden from VoiceOver) and the text
  size, which the system's bottom bar lets grow only a little. Its name and server are in the text colour and must pass.

**Memory captions on photos** (story cards, memory cards, the Collections and Library strips and the Mac's menu bar
panel; marked `memory-caption` for the tests) are not excused, not even as "nearly passed": white text stands on an
even shade from its first line down (`CaptionScrim`, black or the deep tone of the cover's colour at 65 %, 75 % with
Increase Contrast or Reduce Transparency) that fades in over 22–56 points above it with an eased curve. On a white
photo that is more than 5:1 (`CaptionScrimTests`), so the small date line meets AA on any photo. At accessibility text
sizes the captions go below the picture and wrap, and the strips grow to the tallest card.

The audit is run in three parts (contrast; elements, hit areas, descriptions, traits; Dynamic Type and clipping) and
retried after a pause when it runs out of time, which it does on a loaded Mac; the handler only records.

**Accent colour.** Nextcloud blue #0082c9 has 4.2:1 on white, below WCAG AA (4.5:1) for the text, symbols and tinted
buttons drawn in it. In light mode the app uses the Nextcloud server's own default primary colour (theming, `default.css`),
#00679e (6.1:1 on white, 4.9:1 on a tinted button), and #00507a with Increase Contrast; in dark mode #0082c9 stays
(5.0:1 on black). `AccentPalette` (PhotosAppUI) and the app's `AccentColor` asset have these variants. Confirmed by
the owner on 2026-11-27 over the original #0082c9 in light mode.

**Other fixes from the audits.** Text on Liquid Glass in the secondary colour came out at about 3:1 over light photos
(the glass draws every hierarchical style vibrant): the count line of album and smart album caption plates and the time
in the viewer's date pill use the text colour, set apart by size. The viewer's action bar: plain buttons took taps only
on their icons (17×23 points), each label is now a 44-point square that takes them. The account avatar: white initials
on the accent, hidden from VoiceOver (the button says whose account it is). Settings › Accounts: the current account's
check mark is the account element's value and selected trait, not a 14-point element of its own. The iPad's info inspector, clear glass over the photo, has a thick material behind the info
(its section headers and row titles were below 3:1 on light photos), and the info's section headers use the
prominent style (the system's grey ones measured 3.4:1 there). The year in review cards' year grows with the text size.
The close crosses of the weekly prompt invitation
and the family suggestion: 44-point targets.

**German and locales.** There are no translations yet (Transifex, LOCALIZATION.md), so with German as the preferred
language the app runs in English with the German region. Checked: every user-visible string in the packages goes
through `bundle: .module` (a scan of all SwiftUI and Foundation calls with literals found none without it); dates,
numbers, sizes and durations use Foundation's formatters (the hand-made formats are file names, EXIF and server values,
in `en_US_POSIX` on purpose); date ranges use `DateRangeLabel`; counts that can be one now have plural variations in the
catalogs ("Archived 1 item", "Share 1 photo", "1 of 1 item could not be uploaded", "1 day in Lisbon"). Strings behind
`#if os(iOS)` / `os(visionOS)` had never been extracted into the PhotosAppUI catalog (it is synced from Mac builds):
"Take Photo", "Scan Documents", the sticker hint and two Smart offline footers are added; a scan of every `bundle:
.module` literal against its catalog finds no other gap. Texts that only join a name and a number or two sizes are
verbatim instead of `LocalizedStringKey`s looked up in the app's bundle ("%@ %@", "%@ / %@"). Longer translations are
simulated with `NSDoubleLocalizedStrings` (the tests' `PHOTOS_UITEST_LANGUAGE=double`): the Library's zoom picker ran
off both screen edges and now shrinks its titles to the screen's width; other screens wrap. (Doubling breaks strings
with plural substitutions, which show their raw format then; that is the tool, not the app.)

"25. Nov 2026 at 15:07" is correct system behaviour, not a bug: it is CLDR's format for English with a German region
(`en_DE`: German day-month order and 24-hour time, English words), exactly what Foundation's
`formatted(date: .abbreviated, time: .shortened)` gives and what Apple's own apps show with that setting. A German
user sees it today only because the app has no German yet; with a `de` localization the same call gives "25. Nov. 2026,
15:07". The app builds no date format by hand that could mix the two. Seen in the Mac build started with
`-AppleLanguages (de) -AppleLocale de_DE`: the viewer window is titled "25. Nov 2026 at 15:07" (the viewer's
`navigationTitle`, `formatted(date: .abbreviated, time: .shortened)`); in the iPhone simulator the same settings give
"25. November 2026 at 15:07", "1.200 × 800 (1,0 MP)", "1,5 MB" — English words, German numbers and dates.

### 20.4 Screens: a visual Collections, Settings in pages, Advanced features [screens]

Three screens had grown into lists after nine rounds. Nothing is removed; what is rarely used steps back.

#### 20.4.1 Collections (iPhone, narrow iPad windows)

The Collections tab was a text list that looked like Settings. It is now an overview of **shelves**, like a photo app
(`CollectionsList`, `CollectionsShelfView`, `CompactNavigation.shelves`):

1. **Albums** — Favorites as the first card, then the albums used last in this app and the most recently changed
   (`RecentAlbums.pick`, at most 12), as the usual album cards (cover, glass caption plate, zoom transition into the
   album). The title "Albums ›" opens all albums (smart albums are there, §19.1). Without the server's albums the shelf is
   Favorites alone.
2. **Memories** — the Library strip's cards (On this day, year recap, trips; `MemoriesStrip.load`), a card opens the
   memory, "Memories ›" all of them.
3. **People** — circular faces, named people first, then by number of photos (`CollectionsOverview.shelfPeople`), only
   where the server has Recognize. A face opens the person.
4. **Places** — a small map of where the photos were taken: one `MKMapSnapshotter` image of the photos' area (padded,
   at least a few degrees wide) with a dot per area (about 8×8 cells of `mapCells`, sized by the number of photos),
   light or dark like the app, with "N photos" on a caption plate. It opens Places.
5. **Shared** — shared albums as cards (on servers without shared albums the title is "Shared with you").
6. **Utilities** — the sidebar's Utilities and Backup (with its state, breathing icon while it runs) as compact rows.

*Fast:* the shelves' data is kept in a model that lives with the tab (`CollectionsOverviewModel`) and is loaded again
only after a sync, on a new day or for another account (`CollectionsOverview.LoadKey`); albums come from the local index
as they change; the map image is cached per size and appearance; shelves show placeholders of the covers' size while
loading, so nothing jumps. *Accessible:* every shelf title is a header and a button ("Albums"), every shelf a container
named after it; cards keep their VoiceOver labels; Reduce Motion stops the parallax (as everywhere), Reduce Transparency
and Increase Contrast give the caption plates their solid form.

*Navigation:* an album, a person or a memory opened from a shelf is pushed on the overview itself, so Back returns to
Collections (`CompactNavigation.path(to: .collections, routes:)`; `place(of:)` reads a path that starts with an album as
the overview's). Deep links still open an album under Albums (Back → Albums), as before.

*Favorites* opens in the Collections stack, as every place of the overview does (§19.1 keeps it a pinned place and a
filter of the Library's menu). Favorites opened from Collections once hung the iPhone app at full CPU; for a while it
opened the Library with its filter instead. The cause was not a second timeline but the pushed screen's constant
search bindings, which made every grid pushed by value re-render in a loop (STATUS §20.1); with that fixed the
workaround was taken out again.

#### 20.4.2 Settings in pages

Settings was one long form. It is now a list of pages (`SettingsPage`, `SettingsHome`) on iPhone, iPad and Vision Pro,
with a search field (`searchable`) over every setting (`SettingsIndex`: the setting's title as the page shows it, its
page, and other words people type — "face id", "takeout", "log out"); a result opens its page. The Mac's Settings window
keeps one tab per page, as Mac apps do (no search; the command palette finds the tabs).

| Page (iPhone, iPad, Vision Pro) | Mac tab | What is on it |
|---|---|---|
| Accounts (the account shown, as the first row) | Accounts | accounts, log out, add; server version, Photos features, Server features, Sync now, sync state, certificate and signed-out state |
| Library | General | timeline folders, upload folder, import from other services, On this device (memories, moments, square tiles, stacks), Appearance, partner sharing, family library, Lock Screen album |
| Notifications | General | notifications, On this day, new photos in shared albums, Photo of the Day, weekly prompts |
| Backup | Backup | the backup screen |
| Storage & cache | Storage | preview cache, Cache performance, thumbnails of the whole library, smart offline, available offline |
| Privacy & security | Privacy | app lock, and the analysis made on this device (recognition, similar photos, descriptions) |
| — | Desktop | desktop pictures |
| Advanced | Advanced | Advanced features switch, Organize (folder rules, smart albums, GPS track), Show in Menu Bar (Mac), Diagnostics |
| About | About | version, source code, privacy, licences |

The Mac's old Server tab is part of Accounts; a stored or palette value `server` opens Accounts
(`MacSettingsPage(stored:)`). `nextcloudphotos://settings`, the account button and the command palette open Settings as
before (the first screen; pages have no links of their own).

#### 20.4.3 Feature audit and the Advanced features switch

Every feature of §15–§19 with its entry points and how central it is (★★★ everyday, ★★ regular, ★ niche). **A** = its
entry points need Settings › Advanced › "Show advanced features" (`AdvancedFeature`). The owner adjusts the list by
moving a case in or out of `AdvancedFeature.hiddenByDefault`.

| Feature (SPEC) | Entry points | Central | Advanced |
|---|---|---|---|
| Memories, films, Year in Review (§15.1, §16.6) | Library strip, Memories row/shelf, memory menu | ★★★ | |
| Memory card from a memory (§15.8.3) | memory ⋯ › Make Card | ★ | **A** |
| Film styles, through the years, SharePlay (§16.6) | memory film player, memory menu | ★★ | |
| Import from camera/card, Takeout (§15.2, §15.7) | File menu, Settings › Library | ★★ | |
| Culling: flag, rate, Compare, Loupe (§15.2, §16.5) | viewer ⋯ › Flag/Rating, selection menu, Library filter › Ratings | ★ | **A** (keys P/X/0–5 and menu bar stay) |
| External editors, Edit With (§15.2) | selection menu (Mac) | ★★ | |
| Apple TV, Watch (§15.3) | own apps | ★★ | |
| Wallpaper, StandBy, Live Activity, Controls, memory room (§15.4) | system surfaces, Desktop tab | ★★ | |
| Zoom levels, haptics, similar photos (§15.5) | Library pinch, viewer ⋯ › Show Similar | ★★★ | |
| Then and now (§15.6) | viewer ⋯ (only for photos with a matching spot) | ★ | (contextual, kept) |
| Travel globe (§15.6) | Travel card in Places, map toolbar | ★★ | |
| Smart offline (§15.8.1) | Settings › Storage & cache | ★★ | |
| Stickers (§15.8.2) | Stickers row, viewer ⋯ › Make Sticker | ★ | **A** |
| Collage (§15.8.3) | album ⋯, selection menu | ★ | **A** |
| Photo of the day (§15.8.4) | Settings › Notifications, widget | ★★ | |
| Moments, scrub to peek, range select, story cards (§16.1) | Library | ★★★ | |
| Command palette, natural search, descriptions (§16.2) | ⌘K, Search | ★★★ | |
| Non-destructive edits, RAW, Live Photo effects, undo history (§16.3) | viewer Edit, Edit menu | ★★★ | |
| Smart album builder (§16.4.1) | Albums "+" | ★★ | |
| Batch time/place/rename, GPX (§16.4.2–3) | selection menu | ★★ | |
| Folder rules (§16.4.4) | Settings › Advanced › Organize | ★ | (in Advanced page) |
| Shortcuts (§16.4.5) | system | ★★ | |
| Insights (§16.5.1) | Insights row | ★ | **A** |
| Continuity Camera, menu bar extra (§16.5) | File menu, Settings › Advanced (Mac) | ★ | (opt-in already) |
| Postcards (§16.7.1) | viewer ⋯ › Send as Postcard | ★ | **A** |
| Family library, weekly prompts, Lock Screen album (§16.7) | Settings › Library / Notifications | ★★ | (opt-in already) |
| Colour from photos, living covers, guest mode (§16.8) | Settings › Appearance, album ⋯ | ★★ | |
| Motion, glass, transitions (§17) | everywhere | ★★★ | |
| Caching (§18) | Settings › Storage & cache | ★★★ | |
| Slim sidebar, filter menu, Clean up (§19) | sidebar, Library, Clean up row | ★★★ | |

*Decided: off by default.* The app is for everyone with a Nextcloud, not only photographers: the slim default of §19
continues into the menus (the viewer's ⋯ menu lost four items, the selection menu up to five). The features are one switch
away, the switch says what it adds, and nothing is lost while it is off: the screens stay `AppDestination`s, so deep
links (`nextcloudphotos://stickers`), Shortcuts, widgets, the command palette, the Go menu and the Mac's keyboard
shortcuts open them; a niche place opened that way gets its iPad sidebar tab while it is shown. Only rows
(`AdvancedFeatures.lists`, used by the Mac and iPad sidebars, Edit Sidebar and the Collections list) and menu items
(`AdvancedFeatureGate`) step back. A Ratings filter that is on keeps its menu, so it can be turned off. The switch is on
this device (`advancedFeatures` in `UserDefaults`; `-advancedFeatures YES` for UI tests and screenshots).

### 20.5 Code health: zero warnings, UI smoke tests in CI [health]

**Zero warnings.** The app, its extensions, PhotosKit and its tests build without a warning on macOS, iOS, visionOS, tvOS
and watchOS (there were 38 on the Mac and 50 for iOS before round 10). How the kinds were fixed, so that new code follows:

- Main-actor API read from nonisolated code (`UIDevice.current.userInterfaceIdiom`, a `Commands` title): the wording that
  asks is `@MainActor` (its callers are views), or the value that needs no actor is `nonisolated`. No `nonisolated(unsafe)`.
- `[weak self]` inside a closure whose outer closure captured `self` strongly anyway: the outer capture is spelled out
  (`Task { [self] in`), which keeps the behaviour and says it; where the outer closure should not hold `self` either
  (observation callbacks) it captures weakly too.
- Deprecations of the 27 SDKs are replaced by their successors: `BGTaskScheduler.submitTaskRequest(_:completionHandler:)`
  (errors logged), `PHAssetResource.filename` (nullable: a name from the asset id and the type's extension), the
  Swift-concurrency reader and writer API of AVFoundation (`outputProvider(for:)`, `inputPixelBufferReceiver(for:…)`,
  `start()`, `AVVideoComposition(applyingFiltersTo:)`) and `LanguageModelError`. A deprecation without a replacement
  (`canOpenURL` to see whether the Files app is installed) is silenced for that declaration only, with
  `@diagnose(DeprecatedDeclaration, as: ignored)` and a comment.
- Unused results are discarded with `_ =`; static metatype lists use `SendableMetatype`; one warning showed a real bug:
  `AlbumRecord`'s date strategy was not GRDB 7's per-column requirement any more, so album dates were written as text
  into `REAL` columns. They are seconds since 1970 now; reading still takes the text of older databases.

**CI fails on warnings, ours only.** `PHOTOS_WARNINGS_AS_ERRORS=YES` (environment and build setting, see
docs/TESTING.md) turns PhotosKit's and the app targets' warnings into errors; GRDB is built with its own settings
(Xcode suppresses a dependency's warnings). Warnings inside macro expansions (`#expect`) and of other tools stay warnings
for the compiler, so `.github/scripts/check-warnings.sh` also fails a build or test job whose log has one from our code.
Local builds only warn, so a new SDK's deprecations do not stop anyone's work: CI tells.

**UI smoke tests in CI.** The job `ui-smoke` installs the latest Nextcloud release with `scripts/test-server.sh` (the
sample photos of a new account), boots an iPhone simulator and runs `UITests/SmokeTests`: launch and Library, the viewer
opened and closed, Albums, Collections, the Settings sheet, the filter menu with its chip, Clean up and a section's
review. Screenshots and the result bundle are the artifact `ui-smoke`; 60 minutes at most; a skipped test fails the job.
The tours must not depend on the day: `GridMotionTourTests.testActionFeedback` uploads its own two photos (dated now, so
under "Today" on any day) into a folder of its own and removes them, also from the trash bin, at the end
(`UITests/TestServer.swift`); the smoke tests need nothing but the sample photos.

### 20.6 Release readiness: performance measured, device test plan, App Store material [release]

**Performance against §10 (item 14).** Measured as far as possible without a device; method and all baselines in
[PERFORMANCE.md](PERFORMANCE.md), re-run with `scripts/measure-performance.sh ios <simulator>` / `mac <app>`.

- *Launch → first pictures, every platform:* `LaunchMetrics` (PhotosMedia) logs, once per process, the time from the
  process start (read from the kernel, so it includes pre-`main`) to the first grid tile with a real picture and to the
  24th ("first screen"), category `performance`. Cheap enough for release builds; on a device Console.app shows it.
- *iPhone/iPad simulator:* `UITests/PerformanceTests` — `XCTApplicationLaunchMetric` (to the first responsive frame), an
  XCUITest launch-to-first-tile clock (upper bound), `XCTOSSignpostMetric.scrollDecelerationMetric` and
  `scrollDraggingMetric` (hitch time ratio, frame rate) for fast flicks through the Library and for viewer paging,
  `XCTMemoryMetric` for both, and the app's own "Tile"/"Viewer" signpost intervals. The viewer's time to the 1024 preview
  comes from the cache metrics (§18.1.3).
- *Mac:* XCUITest would take over the owner's pointer, so the script launches a Debug build in the background and
  `PHOTOS_DEBUG_GRID_SCROLL=<pt/s>,<s>` makes the grid scroll itself with the window's display link; `FramePacing`
  counts late frames (a frame more than 1.5 refresh intervals after the last; hitch time = lateness beyond one interval).
  It sees the app's late commits, not frames the render server drops on its own. Memory: `footprint`.
- Simulator numbers are indicative (Mac CPU/GPU, no 120 Hz, no phone memory limit); the store tests run unoptimised
  (Debug). The device run is DEVICE-TEST-PLAN D8.

Results of round 10 (details and the overload caveat in PERFORMANCE.md — the Mac ran at a load average of 150–840 on 18
cores, so the launch numbers say little):

| §10 budget | iPhone simulator | Mac (Debug) | Verdict |
|---|---|---|---|
| Cold launch → cached timeline < 1 s | first picture median 37 s under full load, 9.5 s at load 20–110 (first responsive frame 11 s); at load 6–8: 3.4 s → **3.1 s** with the launch fixes below (1.9–2.2 s of it before `main`) | first picture median 2.2 s under load; 0.97 s → 0.93 s idle | ⚠️ simulator dominated by its dyld; device D8 |
| Scroll hitches < 1 ms/s | not reported by the simulator | window covered → display link throttled | ⬜ device |
| Viewer 1024 preview (cached) < 150 ms | p95 125 ms (loaded), 50 ms (second run) | 51 ms | ✅ |
| Memory < 300 MB (iPhone) | scrolling 95–99 MB, viewer 107–109 MB peak; launch peak 73–99 MB (once 383 MB under full load) | 196–222 MB, 316 MB after scrolling everything | ✅ |
| Search/filter < 100 ms, map < 200 ms (100 000 items) | store tests: 0.2–60 ms, map 4–70 ms | | ✅ |


**Launch (phase 2).** Profiled with Time Profiler and `sample` (PERFORMANCE.md, "Launch, round 10 phase 2"):
`LaunchMetrics` logs the steps "app code", "app model", "main view" and "library data" besides the first picture. The
Library's first items and its memories strip are read off the main thread as soon as the root view is built
(`LibraryLaunchPrefetch`) and taken by the Library when it appears, so the window's first commit already has the grid
and the strip instead of two more full updates after it; the diagnostics log is first copied 60 s after launch, not
during it (its `OSLogStore` read held a pool thread for a second). What is left: in the simulator 1.8–2.2 s before
`main` (dyld loading ~1 600 images, Debug and Release alike; 0.12 s on the Mac) and the window's first SwiftUI update.

**Device test plan (item 15).** [DEVICE-TEST-PLAN.md](DEVICE-TEST-PLAN.md): twelve checks only hardware can show — backup
with and without the Files app's auto upload (duplicates, counts recorded), backup in the background (locked, ended by the
system, force-quit), background tasks, push (incl. production APNs from TestFlight), share extension (60 items, a 500 MB
video, app lock), widgets/Live Activity/Controls, feel and the §10 budgets with Instruments, Watch, Apple TV, Vision Pro,
Mac (Gatekeeper, sandbox). Each with steps, the expected result and a results table to paste into a GitHub issue. The
long per-screen pass stays in `test-plan.md`.

**App Store and TestFlight (item 16).**

- *Privacy manifests:* audited against the code of rounds 4–9; four uses were undeclared and are now declared — free
  space shown in Clean Up (`DiskSpace 85F4.1`: app, share extension, PhotosAppUI), cache budgets from free space
  (`E174.1`: PhotosMedia), smart offline's file times (`FileTimestamp C617.1`: PhotosCore), dates of files on a memory card
  (`3B52.1`: PhotosAppUI). `scripts/check-privacy-manifests.py` finds the uses of every required-reason category per
  module and fails when a module's manifest, or that of an app or extension linking it, lacks the category; reasons stay
  documented in `docs/PRIVACY-AND-EXPORT.md`. No new collected data; the push-token *Device ID* entry stays a decision
  for Nextcloud (it must match the App Store privacy label).
- *Screenshots:* `UITests/AppStoreScreenshots` (iPhone, iPad, visionOS) makes seven screens from the real app against a
  test server — Library, viewer, memories, albums, map, search, backup — reached by deep links so they survive
  navigation changes, after a warm-up test that fills the caches; `scripts/app-store-screenshots.sh` sets a clean
  status bar (9:41, full battery), keeps or (`PHOTOS_SHOTS_FRESH=1`) reinstalls the app and collects the PNGs per device. Sizes: iPhone 6.9" (iPhone 17 Pro Max, 1320 × 2868), iPad 13" (2064 × 2752), Vision
  Pro; the Mac's are window captures. They are not committed (size, and the sample photos' licences): generate them for
  each release from a library Nextcloud owns.
- *Metadata:* [APP-STORE-METADATA.md](APP-STORE-METADATA.md) — name, subtitle, promotional text, keywords, description
  (within Apple's limits, counted), TestFlight "What to Test", a What's New template, URLs, category, age rating.
- *Release checklist:* [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md) — what Nextcloud's team does: App IDs, App Groups
  (including the Files app's), capabilities and the entitlements Apple grants on request (PhotoKit background uploads,
  notification filtering), background task identifiers, CI signing with an App Store Connect key, the App Store record and
  privacy label, push proxy topic, Transifex, artwork, screenshots, TestFlight review account and App Review notes.

### 20.7 Smaller files [split]

The six largest source files (1150–1800 lines) are split into files of one responsibility each, so that parallel work
collides less. Pure moves: the code is unchanged, a type's members moved into `extension`s in new files of the same module,
whole types into files of their own. Old → new, with lines (paths under `Packages/PhotosKit/Sources`):

| Was | Now |
|---|---|
| `PhotosAppUI/Grid/PhotoGrid+UIKit.swift` (1808) | `PhotoGrid+UIKit` 393 (the representable, `PhotoGridController`'s state, set-up, layout, pull to refresh, geometry, keyboard, ⌘C) · `PhotoGridUpdates+UIKit` 243 (moments, updates, selection, tile frames) · `PhotoGridHeader+UIKit` 85 (the hosted header above the first section) · `PhotoGridScrolling+UIKit` 235 (scroll position, date scrubber, date pill, year ticks) · `PhotoGridPinch+UIKit` 139 (pinch, `GridPinch`) · `PhotoGridDataSource+UIKit` 95 (data source, drag out, prefetching) · `PhotoGridDelegate+UIKit` 209 (selection, context menu, `GridMenuPreviewController`) · `GridTile+UIKit` 380 (`PhotoCell`) · `GridSectionHeader+UIKit` 142 (`GridHeaderSlot`, `SectionHeader`) |
| `PhotosAppUI/Grid/PhotoGrid+AppKit.swift` (1504) | `PhotoGrid+AppKit` 240 (`PhotoGrid`, `PhotoGridHost`, `PhotoGridScrollView`'s state, set-up, geometry, layout) · `PhotoGridUpdates+AppKit` 177 (updates, selection, moments) · `PhotoGridScrolling+AppKit` 173 (scroll position, date scrubber) · `PhotoGridEvents+AppKit` 227 (clicks, pinch, keys, menus, copy) · `PhotoGridDataSource+AppKit` 138 (data source, drag out, delegate, prefetching, `FilePromiseDelegate`) · `GridCollectionView+AppKit` 159 (`GridCollectionView`, debug keys and pinch, `MenuActionItem`) · `GridTile+AppKit` 364 (`PhotoTileView`, `TileShadeView`, `PhotoItem`) · `GridSectionHeader+AppKit` 128 (`SectionHeaderView`) |
| `PhotosBackup/BackupEngine.swift` (1666) | `BackupEngine` 401 (state, set-up, status, conditions, run) · `BackupEngine+Scan` 159 · `BackupEngine+Rounds` 126 (rounds, reconciliation) · `BackupEngine+Upload` 205 · `BackupEngine+BackgroundUploads` 146 (uploads handed to the system) · `BackupEngine+ChunkedUploads` 247 (chunked ones, waiting for the system) · `BackupEngine+Ledger` 245 (ledger, details list, reset) · `BackupEngine+Exports` 98 (kept exports) · `BackupStatus` 101 · `BackupLedgerEntry` 51 |
| `PhotosAppUI/Timeline/MediaGridScreen.swift` (1323) | `MediaGridScreen` 329 (state, body, content) · `MediaGridScreen+State` 172 (hero, viewer, reveal, empty state, delete confirmation) · `MediaGridScreen+Toolbar` 182 · `MediaGridScreen+Actions` 301 (selection info, grid actions, culling, albums) · `MediaGridScreen+Menus` 221 (context menu) · `MediaGridModels` 47 (`GridSelectionInfo`, `DeleteConfirmation`, `GridEmptyAction`, `ViewerStart`…) · `MediaGridViews` 128 (`GridSkeleton`, `LinkShareSheet`, `SignedOutView`) |
| `PhotosAppUI/Viewer/MediaViewer.swift` (1228) | `MediaViewer` 403 (state, init, pager, body, page) · `MediaViewer+Actions` 148 (menu bar actions, page changes, `ViewerPageChange`) · `MediaViewer+PageEvents` 137 (taps, swipes, landing, accessibility actions) · `MediaViewer+Navigation` 110 (keys, step buttons) · `MediaViewer+Toolbar` 250 (stage controls, toolbar, More menu) · `MediaViewer+Stacks` 64 · `ViewerPage` 175 |
| `PhotosStore/Queries/LibraryStore.swift` (1145) | `LibraryStore` 249 (SQL building blocks, grids, coalesced observation) · `LibraryStore+Items` 180 · `+Search` 149 · `+Memories` 80 · `+Map` 146 · `+Writes` 76 · `GridMedia` 148 (`GridMedia`, `TimelineRow`) · `LibraryStoreTypes` 176 (`MediaFilter`, `LibrarySearch`, map types, `SelectionSummary`, `MemoriesSnapshot`) |

Rules the split kept, for the next one: a section moves with its doc comments and `// MARK:`; stored properties and
`override`s stay in the type's main file (Swift needs the first there; the second keeps the lifecycle in one place); new
files carry the original's SPDX header, imports and `#if` platform guard. What another file of the type now uses is
internal instead of `private` (one comment at each type says so) — for `BackupEngine`, `PhotoGridController` and the two
SwiftUI views that is most of their state. `MediaGridScreen` has no explicit `init`, so its memberwise initializer now
also takes the widened `@State`/`@Environment` properties as defaulted arguments; no caller passes them. `private` file-scope
helper types stayed next to their only user (`ViewerPageArea`, `ViewerStepButton`, the viewer page's accessibility
modifiers). One stored property moved within `BackupEngine.swift` to its stored-property block (`serverCheckChunk`), one
misplaced doc comment went with the type it documents (`FilePromiseDelegate`).

## 21. M12 — Trust, intelligence and editing

Goal (the owner's words, after a comparison with Apple Photos, Google Photos, Microsoft Photos, Photos for macOS and
Adobe Lightroom): "implement all the improvements". The gap to the best photo apps is no longer the number of
features: it is trust in backup at scale, on-device intelligence, and editing depth. Everything here runs on the device
or uses the existing server APIs; no server changes.

**Principle: Apple's AI only** (*decision 2026-11-27 by the owner*). The app uses the AI features that Apple's
frameworks provide on iOS, iPadOS, macOS and the other Apple platforms — Vision, VisionKit, Core Image, Natural Language
and Foundation Models (Apple Intelligence) — and **never ships, downloads or runs machine-learning models of its own**.
Classic image processing without a model is fine. Round 11 had added two models of its own, Google's SigLIP for search
by meaning (§21.3) and LaMa for Erase (§21.5); both were removed for this reason before the round was released.

### 21.1 Backup you can see: device photos in the Library, resumable large videos [backup]

Like Google Photos, the Library shows what is on this device and not safe yet, and says so plainly. §7.18.7 said a grid
badge was not needed; the owner wants it (a photo taken today would otherwise be missing from the Library until its
upload is through, and nothing in the Library says what is not backed up). Everything here is on the device; no server
change.

#### 21.1.1 Device photos in the Library

- **What**: the photos and videos backup covers (its options: kinds, from date, albums, hidden) whose resources are not
  all on the server. Shown only while backup is on for the account on screen, with access to the photos, and with
  Settings › Backup › *On this iPhone* › **Show in Library** on (default on; `BackupSettings.showsDeviceInLibrary`,
  older settings files keep it on). The Library and its Photos, Videos and Favorites filters show them; other
  timelines (albums, places, archive, culling filters) are about server files and do not.
- **Identity**: a device photo has no server file id. It gets a negative id, FNV-1a (64 bit) of PhotoKit's local
  identifier (`DeviceMediaID`): server ids are positive, the id is the same in every launch, and the grid, selection and
  viewer work with it unchanged. A collision (about 1 in 2·10⁹ at 100 000 photos) drops the second photo from the layer,
  it never mixes two up.
- **No duplicates**: the backup ledger decides. An asset whose every resource is `uploaded` or `matched` (the backup's
  duplicate check found it, §7.18.4) leaves the layer and only the server's copy is shown. An asset the backup has not
  looked at yet (no ledger entry) whose capture second and kind are those of a server photo is not shown either (most
  likely that photo, uploaded by another app before the first pass); once the backup checked it and did not find it on
  the server it is always shown.
- **Stacks**: device photos are merged before the timeline makes its stacks. Each has a name of its own, so they are
  never taken for copies of one shot; a burst's frames carry PhotoKit's `burstIdentifier` (`GridMedia.burstIdentifier`,
  only the frames PhotoKit lists: the chosen ones or the representative) for the best-shot package's burst stacks
  (§21.4).
- **Date**: PhotoKit's `creationDate` (the real capture time); merged into the server's rows by time in one pass
  (`DeviceTimeline.merge`), so sections, the scrubber and zoom levels just work.
- **Badge** (top trailing corner, where the partner badge is; device photos are never partner photos): `icloud.slash`
  not backed up, `icloud.and.arrow.up` while it uploads (the asset this app sends, or what the system has: plain and
  chunked background uploads, `BackupStatus.uploadingIdentifiers`), `exclamationmark.icloud` failed,
  `icloud.and.arrow.down` only in iCloud. VoiceOver reads "Not backed up" etc. after the photo's description.
- **Pictures**: PhotoKit's own (`PHImageManager`, local only for tiles, iCloud allowed above 1024 px), through the image
  pipeline (`setDevicePictureProvider`), kept in memory only, never in the preview cache.
- **Speed**: PhotoKit is read off the main thread (`DeviceLibraryReader`), only when the photo library or the backup
  options change; the ledger is read per asset in one SQL `GROUP BY` when the backup's status changes; at most one
  rebuild per 0.8 s. The snapshot and the merge run detached; the grid gets the merged list like any other query result
  (its model is built off the main actor, `GridFeed`). Measured in the unit test (debug build, M-series Mac): snapshot of
  100 000 device photos 0.14 s, merge of 100 000 + 100 000 rows 0.24 s, both off the main thread.
- **Actions**: a device photo opens in the viewer among the server's photos (`DeviceViewerPage`: PhotoKit's picture,
  zoomable; videos play from PhotoKit) with controls of its own: its state ("Not backed up", "Backing up", "Not backed
  up: <reason>", "Backed up" once it is), **Back Up Now**, **Share** (the file from PhotoKit) and **Delete from This
  iPhone/iPad** / **Delete from Photos Library** (Mac; the system asks, it goes to Recently Deleted). In the grid the
  context menu of a selection with device photos offers Open, Back Up Now, Share, the server photos' actions for the
  rest of the selection, and Delete from This iPhone. The selection bar's buttons act on server photos only.
- **Back Up Now on a selection** (`BackupModel.backUpNow`, `BackupEngine.prioritize`): the selected assets go first
  (the running pass from its next round on, else a new pass), and a failed one is tried at once instead of after its
  back-off; the request is forgotten when a pass has gone through.

#### 21.1.2 Backup summary

- `BackupSummary`: *All backed up* · *N not backed up* · *Backing up · N left* · *Checking backup…*; nothing while backup
  is off. Honest: only what the server confirmed counts (ledger `uploaded` — the server answered the upload with the
  file — or `matched`); a file handed to the system or half uploaded is "not backed up".
- iPhone, iPad, Vision Pro: in the account menu (the Library's top bar), first section; it opens the Backup screen. While
  something is not backed up, a small orange cloud badge sits on the account button. Mac: a toolbar button in the
  Library while something is not backed up; it opens Settings › Backup.
- Per photo: the viewer's controls for a device photo (above); for a server photo the info panel has a **Backup** row
  "Backed up from this iPhone/iPad/Mac" (this device uploaded it) or "Backup of a photo on this device" (the backup
  found it on the server), from the ledger by file id or path.

#### 21.1.3 Large videos (≥ 2 GB)

The upload path was read for size limits and is 64-bit throughout: sizes are `Int64`, chunk ranges and offsets are
`Int64`, the file is read in chunk-sized pieces (`FileHandle.read(upToCount:)`, never the whole file), SHA-256 is
streamed in 4 MiB pieces, `OC-Total-Length` carries the full size, chunks are 10 MiB up to 97 GiB and larger beyond, so a file never needs more
than the server's 10 000 chunks. Chunked upload v2 everywhere (MKCOL upload folder,
numbered chunk PUTs, MOVE `.file` with `OC-Checksum: SHA256:…`, `X-OC-MTime`, `Overwrite: F`).

How each interruption ends:

| Interruption | What survives | What happens next |
|---|---|---|
| App killed during an app-driven upload (Mac; iPhone without a background session) | the chunks on the server, the upload folder (same name for the same file and destination), the kept export (`tmp/Backup/Kept`, ≥ 32 MB) | the next pass lists the folder and sends only missing or short chunks |
| App killed while the system sends the chunks (iPhone, iPad) | the system's transfers, the journal in the container | the system finishes the requests; the next launch hands over the rest (`driveChunkedUploads`) |
| Network lost | as above; the pass pauses "offline" and waits for a network change | resumes by itself on the next change |
| Device restart (the system forgets its transfers) | the journal, the staged file and its chunks, the server's chunks | transfers found missing twice are handed over again; chunks the server has are not sent again |
| Upload folder expired on the server (unfinished for more than a day) | the export | the file is sent again from its first chunk |

Proof: `LargeUploadIntegrationTests` (PhotosNetworkingTests, `PHOTOS_IT_LARGE=1`) uploads a 2 254 857 830-byte file
(above 2³¹) twice per server, interrupting at a third — the app's own upload cancelled (kill, network loss), and a
real background `URLSession` invalidated with its transfers (restart) — then checks that only the missing chunks are
sent, that the server's size is exact, that it stored the SHA-256 the app sent, and that the file downloaded again has
the same SHA-256. Results in STATUS §21.1. Device steps (a real 4K video of ≥ 2 GB, locked device, force-quit, restart)
are D13 in DEVICE-TEST-PLAN.md.

### 21.2 Verification: the 🟡 items seen working [verify]

Goal: every STATUS line that says "built, not seen" either seen working (✅ with a screenshot or a UI tour that CI can
keep running), fixed, or turned into ⬜ with a plan — most central first: Library, viewer, albums, sharing, discover,
then the rest. Backup, search, best shot and the editor are rewritten in this round by their own packages and are left
to them.

1. **Proof is a tour, not a look.** New checks are XCUITests (`UITests/VerifyTourTests.swift`) that run against the
   test server like the other tours, write a screenshot and the accessibility tree of every step, and assert what the
   STATUS line claims (the viewer closed, the Library tab selected, the server's album holds the added photos, the
   confirmation names the stacked copy). A line becomes ✅ only with such a run or a screenshot named in STATUS.
2. **Own data only.** Steps that change something work on photos the tour uploads into a folder of its own and on
   albums it creates over WebDAV, removed in the teardown (also from the trash bin); settings it switches (app lock,
   square tiles) are switched back, and the next run starts from a fresh installation (`simctl uninstall`).
3. **What the simulator cannot do itself is done by the host**, not skipped: Face ID is enrolled and matched with
   `notifyutil` (Recently deleted, Archive, app lock), and a gesture in progress (pull to refresh, the swipe down that
   closes the viewer) is captured with `simctl io screenshot` frames while the test holds the finger
   (`captureFrames`, a request file in the shots folder).
4. **Device-only items move to the device plan.** Camera, MDM, push, real share targets, AirPlay, shake, two devices,
   Spotlight/Siri/Shortcuts with a signed build, StandBy, Watch faces, Vision Pro gaze, and the Mac items that need the
   owner's unlocked screen are collected as D16 in DEVICE-TEST-PLAN.md (StandBy, push, Watch, Vision Pro under their
   existing D5/D7/D9/D11) and marked "⬜ device D…" in STATUS: they have a plan, and the simulator cannot prove them.
5. **Found and fixed on the way.** Sheets with a minimum width meant for the Mac (420–720 pt) were as wide on iPhone:
   "Add photos" to an album was 720 pt wide on a 402 pt screen, its Cancel and Add buttons off the screen and
   unreachable. Twelve sheets now use the existing `sheetMinimumSize` (macOS only): Add photos, collaborators,
   comments, Open public link and the public album's viewer, Share via Nextcloud (one photo, several photos, a share's
   editor), Extract text, the server folder picker (backup folder), Watch Together, memory film export.
   The info card on iPhone did not close when the app closed it: at compact width it was the inspector's own sheet,
   which ignored its binding turning false. Info left it on screen while the photo already moved back, and one swipe
   down on it closed the whole viewer. Compact width now presents a sheet of its own (same detents and background
   interaction; the iPad's inspector column is unchanged), and a swipe down that began with the card open closes only
   the card (`ViewerSwipe.closesViewer`).
   On the Mac the map's list of a marker's photos was a sheet without a Done button (Escape only); it has one now.

6. **Counts and what is left.** STATUS had 246 yellow marks on 226 lines; after this round 202 on 190 (35 new ✅ marks
   with their run and shot, 27 items moved to the device plan). Left yellow, with how to continue (STATUS §21.2): the
   Mac items (drive the `fixr11verify` build through the accessibility API on an unlocked screen), Vision Pro (its
   simulator runtime is installed now: run `SmokeTests` and `VerifyTourTests` there), sharee search with a second user
   (8091/8093), the memory menu's actions, and the §15–§20 lines this round did not reach — add a step to
   `VerifyTourTests` per line, most central first, as this round did.

### 21.3 Search by meaning: not built — Apple's frameworks only [search]

Search finds what photos show with what Apple's frameworks provide, as before round 11: the labels Vision's image
classifier gives the cached previews (SR-7), the descriptions this device writes with Apple Intelligence's language
model or Vision (§16.2), file names, captions, folders, tags, people, places and dates, all in the full-text index
(SR-3); typed sentences are read by the parser and, where Apple Intelligence is available, by its language model
(`NaturalSearchModel`, Foundation Models), whose answer is checked against what the library knows (§16.2).

**Search by meaning** — finding photos by a description ("dog on the beach at sunset", "Hund im Schnee") that no file
name, label or description contains — is **not in the app**. It needs one space for pictures and text, and the OS 27 SDK
has no public API for that (checked Nov 2026): Vision's image feature prints (`GenerateImageFeaturePrintRequest`) compare
images with images only (used by Show Similar, §15.5); Natural Language's embeddings (`NLEmbedding`,
`NLContextualEmbedding`) are text only; Foundation Models' language model can look at one image at a time (used for
descriptions, §16.2) and is far too slow to compare a query with 100 000 photos; Core Spotlight's semantic search covers
only text the app donates; Media Intelligence, Visual Intelligence and Image Playground do not fit. Round 11 built it with
a model of its own (Google's SigLIP through Core ML, 229 MB, downloaded separately); it was removed under the principle
above (§21). If Apple adds an image–text embedding API, search by meaning can be built on it.

### 21.4 Best shot: bursts and similar photos pick their best [bestshot]

The best shot of a burst or of a series of similar photos is chosen on this device, compared within its group, and the
app says why ("Best shot: Sharpest, eyes open."). One scorer (`PhotosDomain/BestShot.swift`) serves every place that
picks a photo out of a group.

**What is measured** (`PhotosMedia/BestShotAnalysis.swift`, Apple frameworks only — no model is bundled, so nothing of
§ML applies: no licence, no download, no size). Checked in the OS 27 SDK: Vision has face rectangles with yaw/pitch,
face landmarks, face capture quality, attention saliency and `CalculateImageAestheticsScoresRequest` (overall score and
`isUtility`); it has no smile or blink detection, which Core Image's `CIDetector` (`CIDetectorSmile`,
`CIDetectorEyeBlink`, not deprecated, also on tvOS/visionOS) still offers. Each photo, from its 1024 px preview scaled to
768 px:
- *Detail*: variance of the 4-neighbour Laplacian (Accelerate) divided by the variance of the tones, as
  log2(1 + 1024 × ratio), for the whole picture and for the subject — the largest face, else Vision's most salient
  object. Dividing by the tones makes it independent of brightness (a darker frame is not "softer"). A group compares
  0.65 × subject + 0.35 × whole.
- *Exposure*: share of blown-out (≥ 250) and crushed (≤ 5) pixels beyond 2 %/3 % and how far the mean tone is from the
  middle; 1 = fine, 0 = mostly clipped.
- *Faces* (largest 12): eyes open 0…1 from the eye landmarks' height/width (0.12 closed … 0.26 open; the more open eye
  counts, a wink is not a blink; a Core Image blink caps it at 0.2), smiling (Core Image), looking at the camera
  (|yaw|, |pitch| ≤ 20°), Vision's capture quality. Only faces at least 5 % of the picture wide *whose eyes were found*
  count (passers-by and false faces in patterns do not).
- *Aesthetics*: Vision's overall score and `isUtility`.
Stored per file version in the account database (table `bestShot`, migration `v_r11_bestshot_signals`, JSON with a
version; rows go with their photos; deleted with "Find similar photos" off). Never uploaded. ~70–130 ms per photo on an
Apple-silicon Mac (debug build; the first ~0.5 s loads the models), a few MB of buffers. The simulator cannot run the
models: nothing is analysed there.

**The choice** (`BestShot.choose`): the user first — favourites, else photos flagged Pick; a rejected photo only when all
are rejected. Then a weighted score in 0…1 relative to the group: detail (a frame 3 doublings of Laplacian/tone variance
below the sharpest gets nothing), exposure, aesthetics; with faces in the group also eyes open, smiling, looking, face
quality and "everyone in the picture" (faces counted against the frame with the most). Weights: people 0.22 detail,
0.26 eyes, 0.10 smile, 0.07 looking, 0.07 face quality, 0.08 everyone, 0.08 exposure, 0.12 aesthetics; scenery 0.45 /
0.20 / 0.35 (detail/exposure/aesthetics); documents and screenshots (majority `isUtility`) 0.6 / 0.3 / 0.1 — legible
beats pretty. Photos not analysed yet never beat analysed ones; with nothing analysed the old rule stays (best aesthetics
score, else the middle shot). **Reasons** are only what sets the shot apart from the others: eyes open (someone blinked
elsewhere), everyone in the picture, smiling, sharpest (≥ 0.35 log2 above the others' mean), looking at the camera,
well exposed, best composed (aesthetics +0.1); at most three, favourite/Pick first; none = "Best balance of sharpness,
faces and composition".

**Where it is used**
- *Clean up › Similar shots* (§19.3): the series' best shot is `BestShot.choose`; on opening, the first 24 series whose
  shots are not analysed are analysed (1024 px previews, loaded when not cached), four series at a time, the list
  refreshing as it goes ("Choosing the best shots on this device… 4 of 12 series"); each series says "Best shot:
  Sharpest, eyes open." (with "the suggestion may change" while incomplete).
- *Show Similar* (§15.5): the moment's shots are analysed while the sheet is open; the header shows the reasons.
- *Culling* (§15.2): Flag ▸ **Pick Best Shots** (context menu, selection, Image ▸ Flag in the Mac menu bar) cuts the
  selected photos into series (`SimilarSeries`: alike ≥ 0.84 and ≤ 10 min apart; photos not compared yet are compared
  from their 256 px previews), analyses them and flags the best of each series Pick through the outbox (one Undo). Other
  shots stay unflagged (rejecting is the photographer's call); "No series to pick from" when there is none.
- *Library stacks* (TL-6): a burst shows its best frame once its frames are analysed (favourite first; else the camera's
  `COVER` frame, as before). VoiceOver says "Burst of N photos" for every burst (`GridMedia.stackIsBurst`).
- *Memory covers* (§7.12): for the 40 newest memories, the cover is the photo with the best `KeyPhoto.score` plus a face
  bonus (`BestShot.coverBonus`: open eyes and smiles +, a blink −0.45), among its favourites and up to 600 spread
  photos — only where this device analysed photos; otherwise the algorithm's cover stays.
- *Background*: when the "Show Similar" trickle or background task has nothing left to compare, it analyses the shots of
  the series found, from cached 1024 px previews only (`BestShotAnalyzer.run`), under the same power/thermal conditions.
- Search ranking does not use the scores this round (contract with the search package).

**Bursts** (TL-6, the round-4 decision revised). Three kinds, most certain first:
1. *Device bursts*: photos of this device with the same PhotoKit `burstIdentifier` (`CopyStackCandidate.burstIdentifier`,
   nil for server files). The hook is in place; the device-photo layer of §21.1 sets it. PhotoKit only returns a burst's
   representative unless asked (`includeAllBurstAssets`), and backup uploads only that one — so on the server an iPhone
   burst is one photo, as in iCloud Photos' default.
2. *Camera-named bursts* (`…_BURST001_COVER.jpg`, unchanged).
3. *Time bursts* (`TimeBursts`, new): photos uploaded frame by frame without a marker — images in one folder, each ≤ 1 s
   after the one before, ≥ 3 frames, ≥ 2 frames per second on average, every frame alike to the one before (sketch cosine
   ≥ 0.84, from "Show Similar"). This answers round 4's objection: quick single shots (one a second) are slower than
   that and stay apart, and nothing is stacked by time alone — a run whose photos are not compared yet is not stacked
   until they are. Only with "Find similar photos" on.
Evidence is read synchronously from the database (`StoredBurstEvidence`) for the few fast runs and burst frames, both
for the live grid and the launch prefetch, so both stack alike. A grid re-stacks when its query delivers again (a new
analysis does not trigger it by itself).

**Evaluation** (repeatable: `TEST_RUNNER_BESTSHOT_EVAL_DIR=<dir> xcodebuild test … -only-testing:PhotosMediaTests/
BestShotEvaluation` writes `report.json`; contact sheet in `ios-fix-shots/r11-bestshot/evaluation-contact-sheet.png`).
Six groups from the test library: three synthetic bursts with a known best frame (a portrait: shaken, 60 % darker,
face-only blur, blown out; the Apollo 11 crew: soft, shaken, slightly shaken; Lake Tenaya: shaken, blown out, dark) —
the steady frame was chosen in 3 of 3 ("Well exposed, best composed", "Smiling, sharpest", "Well exposed"); and three
real pairs: two shots of an award handover (chose the one where both smile: "Smiling, looking at the camera"), two scans
of Signorelli's portrait and two of van Dyck's family portrait (chose the better-exposed, better-composed scan). Before
the tone normalisation the blown-out frames won on detail; that is why it is there.

### 21.5 Remove objects: a basic fill as a non-destructive edit [erase]

**Erase** is a tool of the editor (third in the tool row, after Adjust and Crop; symbol `eraser`): tap (click) an object to erase it, or brush (drag) over it; the
area is filled in on the device from what is around it. It works best on spots, dust and small things on even
backgrounds, and says so under the picture ("Works best on spots and small things."); it is not a generative fill like
Clean Up in Photos, Magic Eraser in Google Photos or Remove in Lightroom, which need a model (see "Fill" below).

- **Picking.** A tap picks the object under it with Vision: the foreground instance there
  (`VNGenerateForegroundInstanceMaskRequest`: people, pets, things in front), else the person there
  (`VNGeneratePersonInstanceMaskRequest`). Nothing found: "Nothing to pick here. Brush over what you want to erase." A
  drag paints a stroke (brush size slider, 1–8 % of the shorter side; the stroke is drawn in red while brushing). Brushed
  points are mapped from the edited picture (crop, turns, straighten, mirror) back onto the original
  (`RetouchGeometry`, kept in step with `PhotoEditor.apply` by a test that renders marked pictures through it).
- **People in the background.** When the tool opens, Vision's person instances are looked at; people under a quarter of
  the size of the largest person (who is at least 2 % of the picture) are offered: **Erase N People in the Background**
  (button and VoiceOver action on the picture). Vision's instance requests are used directly rather than `EditMasks`'
  subject and people masks: picking needs the single instance under the tap, and the people one by one. Of the 45 photos in the test library's People folder it offers this
  on 5, each time for the person behind the subject.
- **Non-destructive.** Each removal is a stroke in the edit recipe's optional `retouch` field (§16.3.1; decoded when
  present, never required):
  `"retouch": {"strokes": [{"brush": {"radius": 0.02, "points": [[x, y], …]}}, {"area": {"width": 192, "height": 128,
  "runs": [9310, 4, 186, …], "grow": 0.015}}]}` — fractions of the upright original (EXIF orientation applied, before
  the recipe's geometry), origin top left; `area` is the picked mask as run lengths over a bitmap of at most 192 cells
  (first run: cells not erased), `grow` the margin added around it (default 1.5 % of the shorter side). Unknown or broken
  strokes are skipped. A recipe with strokes is format version 2 (§21.6: an older app shows the original rather than
  the object), and the field is documented for the Android and web teams in docs/EDIT-FORMAT.md §4.9. Copy Edits and
  presets leave strokes out (they belong to one photo); Paste Edits keeps the target's own. Undo/redo, Done, Revert, Save as Copy and Overwrite Original work on it like on every other edit;
  **Restore All** removes all strokes (one undo step). Another client that cannot fill strokes shows the photo without
  the removal (EDIT-FORMAT.md); the rendered file ("Apply edits to the file", §21.6) carries it to every app.
- **Rendering** (`Inpainting`, one line in `EditRendering.apply`): after the RAW development and *before* colour and
  tone (noise reduction, adjustments, curves, mixer, masks, filter) and geometry; the masks of §21.6 are found on the
  picture with the objects already removed — the fill sees the photo's own pixels, adjusting colours or the crop later never fills again,
  and the strokes stay in the original's coordinates. Each stroke is filled in a window around it with room for context
  (2.2 × the stroke, at least the fill's 512 px at the picture's own resolution: a small object is filled at full
  detail; a large one scaled down and the fill scaled up), blended in with a soft 2 px edge. Strokes apply in order;
  earlier strokes that touch a new one are filled again with it in one window (a person, then their reflection: one hole,
  no leftover of the first guess, no seam). The proxy in the editor, the grid/viewer previews and the full-resolution
  original on save are all filled this way ("tiling" by stroke windows); results are cached by a fingerprint of the
  picture and the strokes so far, so slider changes, undo, redo and the next rendition reuse them. In the editor the
  stroke is filled off the main thread before it is added (spinner on the picture), so the preview never waits.
- **Masks grow.** Vision's masks follow the outline tightly; the object's edge pixels left around the hole would be
  pulled into the fill and leave a dark ghost of the object. Picked areas grow by 1.5 % of the shorter side and every
  stroke by 4 pixels of the fill's window.

**Fill.** `DiffusionFill`, classic image processing without a model: the surroundings are pulled smoothly into the
hole ("push–pull" over an image pyramid, 512 × 512 windows). Right for spots, dust, small things and objects on even
backgrounds (sky, sand, snow, water, a wall); it invents no detail, so a large object on a busy background leaves a
soft, blurred patch. Apple's frameworks have no public inpainting API in the OS 27 SDK (Vision, Core Image, Image
Playground — generation only, Visual Intelligence, Media Intelligence — faces and video highlights, Foundation Models:
none fills a masked area; Photos' Clean Up is not available to apps). Round 11 filled with LaMa through Core ML (99 MB,
downloaded separately); it was removed under the principle "Apple's AI only" (§21). If Apple adds an inpainting API,
`Inpainting` takes it as another `InpaintingEngine` (engines name themselves in the cache keys). Speed and memory on
iPhone and iPad: DEVICE-TEST-PLAN D15.

### 21.6 Editing depth: curves, colour, masks, noise, copy and paste, presets, other apps [edit]

The editor of §7.16/§16.3 had the global sliders of Photos; Lightroom, Photos for macOS and Google Photos also have
curves, a colour mixer, local (AI) masks, noise reduction, copy/paste of edits and presets. All of it is added to the
non-destructive recipe (format version 2, §21.6.7), rendered with Core Image on the device, and specified for the
Android and web teams in **docs/EDIT-FORMAT.md** (storage, sync, JSON, exact rendering formulas).

The editor's tools are now a row of buttons (icon and name) that scrolls sideways — Adjust, Crop, Presets, Filters,
Curves, Color, Masks, RAW (RAW photos and RAW+JPEG pairs), Live (Live Photos) — instead of a segmented control, which no
longer fit on an iPhone. The pipeline is split in two stages, colour (`PhotoEditor.applyColor`) and geometry
(`applyGeometry`), with the place for retouching (§21.5) between them in `EditRendering.apply`; the crop tool now shows
every colour edit too.

#### 21.6.1 Curves

- RGB curve and one curve per channel (red, green, blue); channel picker and Reset in the **Curves** tool.
- Drag a point to move it, start a drag elsewhere to add one, double-tap a point or drag it off the area to remove it;
  the end points move too (black and white points). VoiceOver: every point is adjustable (swipe up/down), "Add Point"
  action. One undo step per drag.
- Interpolation: **monotone cubic (Fritsch–Carlson)**, so a curve never overshoots between points (no clipping or
  colour flips that Catmull-Rom curves cause). At most 16 points; points closer than 1 % merge.
- Rendering: the curves are sampled into a 1024-entry table per channel (`out = channel(rgb(in))`) and applied with
  `CIColorCurves` in **sRGB** values, as every editor shows curves.

#### 21.6.2 Colour mixer (HSL)

- **Color** tool: eight swatches (reds, oranges, yellows, greens, aquas, blues, purples, magentas, centred at 0, 30, 60,
  120, 180, 225, 270, 315°) and Hue (±30°), Saturation (×0…2) and Luminance of the chosen range; a dot marks changed
  ranges; "Reset All Colors".
- Neighbouring ranges overlap linearly (weights add up to 1), so no change shows an edge; greys stay grey (luminance is
  weighted by saturation), nothing clips. Rendered as a 32³ `CIColorCubeWithColorSpace` lookup table in sRGB, made once per
  setting and cached (32 settings).

#### 21.6.3 Masks: subject, background, sky, people

- **Masks** tool: "Add Mask" ▸ Subject, Background, Sky, People; up to 8 masks, each a chip; the chosen mask has Invert
  and its own Exposure, Brightness, Contrast, Highlights, Shadows, Saturation, Vibrance, Warmth, Tint and Sharpness, and
  is **tinted red over the picture** while the tool is open (as in Lightroom). A new mask starts with a small visible
  change. "No sky found in this photo" (etc.) when its part is not there.
- Only the **kind** of mask is stored, never pixels: the recipe stays small, fits the original at any size, and gets
  better with a better segmentation. Masks are found on the picture before any edit (so they do not move while sliders
  do), on a copy of at most 768 px, and scaled up along the picture's edges (`CIEdgePreserveUpsampleFilter`), so a mask
  costs the same for a tile and a 48-megapixel export. Found masks are cached by a fingerprint of the picture (size and
  an 8 × 8 thumbnail).
- **Apple frameworks first** (OS 27 SDK checked): subject = Vision `VNGenerateForegroundInstanceMaskRequest` (all
  instances), people = `VNGeneratePersonSegmentationRequest` (accurate), background = inverted subject. **No public API
  segments the sky** (Vision has subject, person, person-instance, document and — new in OS 27 —
  `GenerateIterativeSegmentationRequest`, a *prompted* segmentation with downloadable assets). Decision: the sky is a
  **heuristic** — smooth pixels that are blue, overcast-bright or sunset-warm and connect to the top edge (flood fill),
  softened and edge-upsampled — gated by Vision's scene classification (`VNClassifyImageRequest`: no sky when every sky
  label is below 0.05). No third-party model: a sky-segmentation network would add 10–40 MB and a licence review for a
  mask the heuristic gets right on ordinary landscapes; the documented upgrade path is to seed
  `GenerateIterativeSegmentationRequest` with the heuristic's sky (⬜ in STATUS). The algorithm is in EDIT-FORMAT.md §4.6
  so Android/web find the same sky.
- Vision does not run in the simulator: there a mask changes nothing and the tool says it found nothing.

#### 21.6.4 Noise reduction and RAW detail

- **Adjust** has **Noise Reduction** (luminance: `CINoiseReduction`) and **Color Noise** (colour blotches: the picture's
  colours blurred, its own luminosity kept — `CIColorBlendMode`). Both are relative to the picture's size, so tile,
  editor and export look alike. Applied first, before any adjustment boosts the noise.
- **RAW**: the RAW tool adds **Color Noise** (`CIRAWFilter.colorNoiseReductionAmount`) and **Detail**
  (`detailAmount`) next to the existing luminance noise reduction, each shown only where the decoder supports it for the
  camera; the JPEG of a pair approximates colour noise with the filter above.

#### 21.6.5 Copy and paste edits, presets, a whole selection at once

- **Look** = everything but crop/turns/straighten/mirror, the Live Photo effect and the original's description. **Copy
  Edits** (editor More menu; grid context menu on one edited photo) copies the look; **Paste Edits** (editor; grid
  context menu on any selection) replaces the target's look and keeps its own crop and turns; RAW settings go only to
  photos developed from RAW. One clipboard for the app, as in Photos.
- **Presets**: tool **Presets** with built-in looks (Vivid, Warm, Cool, Matte, Black & White, Dramatic Sky, Portrait
  Pop, Clean Night — the last three use masks and noise reduction) and the user's own, each shown as a small preview of
  the photo; "Save as Preset…" names the current look; a user preset's context menu deletes it. User presets are synced
  through the user's Nextcloud (`/.nextcloud-photos/edit-presets.json`, merged preset by preset, later change wins,
  removals as markers), when the editor opens and with the library sync at most every 15 minutes.
- **A selection in one go**: grid context menu **Paste Edits** and **Apply Preset ▸** on any number of photos: one
  undoable change (one entry in the undo history), then the edited tiles are rendered in the background with progress
  and Cancel ("Applying edits to 12 of 120…", then "Edited 120 photos"). Videos are left out.

#### 21.6.6 Apply edits to the file

Apps that do not read recipes (the web, the Android app today, desktop apps, other people's shares) show the original.
**Apply Edits to the File** (editor More menu, a lasting option with an explanation when it is turned on) writes the
edited picture into the file on Done and on Paste/presets of a selection:

1. The original is kept first: the current version of the file is given the **version label** "Original (Nextcloud
   Photos)" (`PROPPATCH nc:version-label` on the versions DAV collection; a user's own label is kept inside ours). Nextcloud
   **never expires a labelled version**, neither by age nor by the quota rule (`files_versions/lib/Storage.php` skips
   labelled versions in both). The label is read back; if the server keeps no versions or does not keep the label, the
   file is **not** overwritten (error "Your Nextcloud doesn't keep file versions…"). Only the first original is labelled:
   editing again keeps it.
2. Rendered at full resolution in the original's format and name, `PUT` with `If-Match` (a newer version is never
   replaced), the recipe removed (the edit is in the file now).
3. **Restore Original…** (editor More menu, when the file has such a version) moves the labelled version back
   (`MOVE … /restore/target`, `Overwrite: T`); the edited picture stays a version.

Not for read-only shares, formats Image I/O cannot write, or a JPEG developed from its RAW: those keep the recipe.
"Overwrite Original…" uses the same path, so it too keeps the original as a labelled version and refuses without
versions. Proven against the 8089 server (`ApplyEditsToFileIntegrationTests`): the labelled version is byte-identical
to the original, a second edit keeps the same labelled version, a stale ETag replaces nothing, and Restore Original
brings back the original's exact bytes (SHA-256).

**Default: off.** A recipe can be changed with every slider, undone and reverted at any time, on all devices, for free;
an edit written into the file can only be undone by restoring the original (sliders start from the edited picture), it
uploads the whole photo again, every edit adds a version that counts against the user's space, and it changes the photo
for everybody the file is shared with. Users who need the edits in other apps today turn it on; when the Android and
web apps render recipes (EDIT-FORMAT.md), nobody needs it.

#### 21.6.7 Format version 2, compatibility

- `version` 2 adds `curves`, `colorMixer`, `masks`, `adjustments.noiseReduction`/`colorNoiseReduction`,
  `raw.colorNoiseReduction`/`raw.detail`. A recipe is written with the **lowest version that shows it**: edits without
  these stay version 1 and older app versions keep showing them; with them it is version 2 and an older app shows the
  original and says "edited with a newer version" instead of half the edit.
- Readers ignore unknown keys, unknown mask targets (the others apply) and broken values, clamp ranges, and cut masks at
  8. Retouching (§21.5) adds its optional field and needs version 2 as well.

## 22. M13 — Easier, faster, more useful

After a fresh look at the app (2026-11-27) the owner chose twelve improvements: free up space on the device after
backup, Handoff, setting up Apple TV from the iPhone, a three-step first run, the camera in search, a pre-rendered tile
cache, a targeted sync (and `notify_push` where the server has it), a smaller preview cache, People without Recognize,
birthdays from Nextcloud Contacts, settings synced through `.nextcloud-photos/`, and cleaning up orphaned edit recipes.
The principles of §2 and §21 hold: only Apple's frameworks for analysis on the device, no server changes (an existing
optional server app such as `notify_push` may be used when present).

### 22.1 Free up space on this device [space]
_To be written._

### 22.2 Handoff, Apple TV set-up from the iPhone, a three-step first run [continuity]
_To be written._

### 22.3 Camera in search, People without Recognize, birthdays from Contacts [people]
_To be written._

### 22.4 Faster: tile cache, targeted sync and notify_push, smaller preview cache [speed]
_To be written._

### 22.5 Settings synced between devices, orphaned edit recipes cleaned up [tidy]

#### 22.5.1 Synced settings files (`.nextcloud-photos/<kind>.json`)

What the user sets once should be the same on all their devices, without a server change: small JSON files in the
user's own Nextcloud, in the hidden folder `/.nextcloud-photos/` (§16.4), **one file per kind**.

- **Format** (`SyncedSettingsDocument`, PhotosNetworking): `{"format": "nextcloud-photos-settings", "version": 1,
  "kind": "people", "entries": {"<key>": {"value": <any JSON>, "modifiedAt": "2026-11-27T10:00:00.123Z", "base": …,
  "replaced": [<JSON>…]}, "<removed key>": {"deleted": true, "modifiedAt": …}}}`. Keys are free strings; a kind's
  users group them with prefixes (`person/…`, `decision/…`). Readers skip entries they cannot read, keep unknown keys
  and never write over a file of a newer `version`.
- **Merge: last writer wins per key** by `modifiedAt` (milliseconds, the time the user made the change; a change is
  always stamped after the version it replaces, also when the device clock is behind). Same time: the value that sorts
  first by its JSON, so every device picks the same. Removals are tombstones (dropped after 90 days), so an offline
  device does not bring a removed key back. Merging is commutative and idempotent.
- **Never lose a name**: `base` is the stamp of the version a change replaced. When two devices changed a key without
  having seen each other's change (a race), the losing value is kept in the winner's `replaced` list (newest first, at
  most five), so "Anna" typed on the Mac and "Anne" typed on the iPhone at the same time both survive; the UI may offer
  the replaced values. A later rename over a seen version is no race and keeps nothing extra.
- **Store** (`SyncedSettingsStore`, one per account and kind, from `AccountServices.syncedSettings.store(.people)`):
  values readable at once without waiting (`value`, `value(_:as:)`, `values(prefix:)`, `replacedValues`), changes with
  `set(_:for:)`, `set(encoding:for:)` or several keys at once (`set([key: value?])`, nil removes); a change is kept on
  the device at once (`<account>/SyncedSettings/<kind>.json`) and sent about 2 s later as one write, offline changes
  wait. Every write names the version it replaces (`If-Match`, `If-None-Match: *` for a new file); when another device
  wrote in between, the store reads again, merges and retries (`AppDataFiles.update`). Observers hear the keys that
  changed (here or from another device).
- **When**: after every library sync (`SyncedSettingsFiles.syncAll()`): one `PROPFIND` (depth 1) of the folder tells
  which files changed, so an unchanged set costs one request; a file is read only when its ETag changed.
- **Kinds**:
  - `settings.json` — the app settings that follow the user (§22.5.2).
  - `people.json` — on-device People (§22.3, written by the people feature through the store): `person/<id>` →
    `{"name": …}` (`id` made by the device that found the person), plus assignments and corrections with their own
    prefixes as §22.3 defines them (`face/<face key>` → person id, `merged/<id>` → id, `not/<face key>` → ids). The
    value schemas are §22.3's; the merge rules are the ones above, so a name given on any device is never lost.
    People's records merge in their own way (both devices' faces of a person are kept): `SyncedRecords` keeps one key
    per person (`person/<id>` → §22.3's person record) and folds the versions that lost a race back in with the
    feature's merge; §22.3's `DevicePeopleNames` sits on it (`SyncedDevicePeopleNames`, wired at the merge).
  - `family.json` — the family library (§16.7.2): `settings` → the folder, members and copy option;
    `decision/<fileId>` → `"dismissed"`, `"moved"` or `"copied"` (a union of all devices' decisions; "Show dismissed
    again" and choosing another folder remove them as tombstones).
  - Earlier files keep their own formats: `smart-albums.json`, `folder-rules.json` (§16.4, `SyncedList`),
    `edit-presets.json` (§21.6.5), `album-covers.json` (§16.8), `edits/<fileId>.json` (§16.3.1).

#### 22.5.2 Which settings follow the user

Settings › Advanced › Everywhere › **Sync settings through Nextcloud** (on by default; a setting of each device) syncs
these through `settings.json` (`SyncedDefaults`: the device's settings are compared with what was last synced, changes
are stamped when noticed, at once while the app runs; on the first sync of a device its existing settings count as
old, so the account's settings win and only fill in; a setting given as a launch argument is neither sent nor
replaced). The section "On this device" of Settings › Library is now "Library display":

| Synced (follow the user) | Stay on the device (and why) |
|---|---|
| Library display: show memories, memories as stories/strip, name moments, square tiles, stack copies | Grid columns and zoom level, sidebar layout (screen size) |
| Appearance: viewer background, tinted headers, Live Photo covers | Cache sizes, library thumbnails, smart offline, offline on Wi-Fi (storage of this device) |
| Slideshow interval and repeat; Through the Years speed | Backup, album mirror, Lock Screen album, desktop pictures, menu bar (this device's library and system) |
| Memory films: style and music per memory (`films/<memory>`) | App lock and its timeout, guest mode (security of this device) |
| Birthdays given in Through the Years (`birthdays/<person>`) | Notifications: photo of the day, shared albums, weekly prompt reminders (per device, as in Apple's apps) |
| Culling: auto-advance, loupe peaking/clipping/histogram | On-device analysis: content labels, similar photos, descriptions (battery, Vision on this device) |
| Editing: Apply Edits to the File | Advanced features switch (a simpler phone and a full Mac are both reasonable) |
| Batch rename and card import name patterns; album sort orders | Own music for films (a file on this device), diagnostics, debug and UI-test switches |

Edit presets, smart albums, folder rules and album covers were synced already (own files); the family library and
dismissed suggestions are now (`family.json`); People names with §22.3 (`people.json`).

#### 22.5.3 Orphaned edit recipes

A recipe stays when its photo is deleted, so a photo restored from the trash bin comes back with its edit (§16.3.1).
Recipes of photos that are **gone for good** are removed (`EditLibrary.removeOrphans`, rules in `OrphanRecipes`):

- **When**: at the end of a completed **full** walk through the library, never after a targeted walk (§22.4), which
  does not see the whole library: one call, `OrphanRecipeCleanup.afterFullWalk`, starts the hook `AccountServices`
  set, in the background, not holding the sync up; at most once a day.
- **Which**: only recipes the server has and this device has nothing pending for, whose photo is
  1. not in the library's index nor in an album the app knows (photos of albums shared with the user are not in the
     user's files, so the SEARCH below cannot see them; their recipes stay), and
  2. not a file anywhere in the user's files: one SEARCH by file id over the whole tree (`/files/<user>`, at most 89
     ids each) — a photo **moved** out of the timeline folders, into a shared, group or external folder keeps its file id
     and its recipe, and
  3. not in the **trash bin**, also not inside a trashed folder (`PROPFIND Depth: infinity` of the trash bin; folder by
     folder, at most 300, where a server refuses that), and
  4. found so at two looks at least **30 days** apart (the first look marks it; a photo restored or found in between
     loses the mark and starts over).
- **Proof that the server can see**: every SEARCH also asks for a file the index has (the canary); when the answer
  lacks it, or any request fails, or the trash bin is too large to read, nothing is removed and the marks stay.
- **Removing**: `DELETE` with `If-Match` of the version this device knows, so a recipe another device changed in the
  meantime stays; then the recipe is dropped on the device, the edited tiles show the original (nothing to show).
- *Decision*: no shorter path through Nextcloud's trash retention setting (not readable by the user): the trash bin
  check plus the 30 days cover `trashbin_retention_obligation` "auto" (30 days) and longer retention alike.

## 14. Prerequisites and open items (need Nextcloud GmbH)

1. ~~Create the GitHub repo~~ (done: https://github.com/nextcloud/photos-apple) and ~~confirm the bundle id~~ (done: `com.nextcloud.photos`). Still open: App Group and keychain group names (§4.2) and the App Store record/name "Nextcloud Photos".
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
