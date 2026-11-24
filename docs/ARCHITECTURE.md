# Architecture

A short map of the code. The target design, with its reasons, is in [SPEC.md](SPEC.md) §4–§5; what is built is in
[STATUS.md](STATUS.md).

## Targets

The Xcode project is generated from `project.yml` (XcodeGen). It has four small targets that contain little more than
entry points; all other code is in the local Swift package `Packages/PhotosKit`.

| Target | Platforms | Links | Contents |
|---|---|---|---|
| `NextcloudPhotos` (app) | iOS, iPadOS, macOS, visionOS | `PhotosAppUI`, `PhotosCore` | `App`, app delegates (push, background sessions), background tasks, App Intents |
| `ShareExtension` | iOS, macOS | `PhotosAppUI` | Upload from the share sheet |
| `NotificationService` | iOS, macOS | `PhotosCore` | Decrypts push payloads, hides what is not about photos |
| `Widgets` | iOS, macOS, visionOS | `PhotosCore` | "On this day" and "Favorites" widgets |
| `NextcloudPhotosUITests` | iOS, macOS | – | XCUITest smoke tests ([TESTING.md](TESTING.md)) |

## Modules of `PhotosKit`

Dependencies as declared in `Packages/PhotosKit/Package.swift`; a module only depends on modules above it in this list.

| Module | Depends on | Contents |
|---|---|---|
| `PhotosModel` | – | Value types: media items, albums, accounts, identifiers, `ServerFeatures`. No I/O. |
| `PhotosDomain` | Model | Pure algorithms: timeline sections, grid layout, stacks, memories, clean-up rules, search suggestions, deep links. |
| `PhotosNetworking` | Model | `HTTPClient` (one `URLSession`, certificate trust, client certificates, retries), `DAVClient`, `OCSClient`, Login Flow v2, `FeatureDetector`, the Photos APIs, `Uploader` (PUT, chunked, background sessions). |
| `PhotosStore` | Model, Domain, Networking, GRDB | One SQLite database per account (`AccountDatabase`), queries (`LibraryStore`, `CollectionStore`, `GridModel`), `SyncEngine`, `Outbox`. |
| `PhotosMedia` | Model, Networking, Store | `PreviewCache` (memory and disk), `ImagePipeline` (queueing, cancelling, decoding), video streaming, editing with Core Image, BlurHash. |
| `PhotosBackup` | Model, Domain, Networking, Store, Media, GRDB | PhotoKit source, ledger of what was uploaded, matcher against the server, `BackupEngine`, coexistence with the Files app's auto upload. |
| `PhotosCore` | all of the above | Composition root: `AppModel` (accounts, keychain, push), `SessionModel` (the services of the account in use), `BackupModel`, offline files, transfers. |
| `PhotosAppUI` | all of the above | SwiftUI screens, the photo grid (a `UICollectionView` / `NSCollectionView`), viewer, settings, login. |

The only third-party dependency is [GRDB](https://github.com/groue/GRDB.swift) (SQLite).

## Data flow

```
server ──► SyncEngine ──► AccountDatabase (SQLite) ──► LibraryStore / CollectionStore ──► GridModel ──► views
              ▲                    ▲                          (observations)
              │                    │ optimistic change
           Outbox ◄────────────────┴──────────────────────────────────────────────────── user action
```

- **The database is the only thing the UI reads.** Views observe queries of the store; the network never feeds a view
  directly. That makes the app work offline and keeps scrolling independent of the connection.
- **Sync** (`SyncEngine`, an actor per account): a first run indexes all photos and videos of the timeline folders with
  WebDAV `SEARCH`, page by page; later runs ask for what changed since the last one and compare folder ETags;
  a reconciliation pass finds deletes and moves. Albums, places and other collections are refreshed when they are shown.
- **Writes** (favourite, delete, album changes, metadata…) are applied to the database at once and queued in the
  `Outbox`, which sends a few at a time (in order for each file), retries with a growing delay and wakes up when the
  network comes back.
- **Previews and originals** go through `ImagePipeline`: memory cache, disk cache, then the server; loads nobody waits
  for any more are cancelled, the caches are trimmed (least recently used first).

## Feature detection

Nextcloud servers differ: version of the server and of the Photos app, optional apps (Recognize, Assistant, Notifications),
and newer Photos APIs that not every server has. `FeatureDetector` builds a `ServerFeatures` value per account from the
capabilities, the Photos app's initial state and a few probe requests. Screens and services ask that value; what a
server does not offer is hidden, not shown as broken. Detection runs at launch, hourly and when the capabilities
change; an API that unexpectedly answers 404 turns its feature off and triggers a new detection. Settings › Server
features shows the result. Details: SPEC §5.2–§5.3.

## Backup

`BackupEngine` (an actor) uploads the photo library of the device to one account:

1. `PhotoLibrarySource` lists PhotoKit assets and their resources (original, edited version, Live Photo video). A pass
   only looks at the assets that changed since the last one (PhotoKit's persistent change token); the whole library
   once a day, after the uploads, or when the options or the selection change.
2. The ledger (a table per account) remembers what was uploaded, and for what still waits the resource itself and when
   the server was last asked about it, so a pass can upload it without reading the library or asking the server again.
   The Files app's auto-upload history is read so that photos it already uploaded are not uploaded again.
3. `BackupMatcher` compares the rest with the server (a WebDAV `SEARCH` by name, size and date), a batch at a time,
   with the candidates indexed by second; uploads start after the first batch.
4. Missing files are uploaded by `Uploader`; on iOS files up to 100 MB are handed to a background `URLSession`, so
   they continue while the app is suspended.

The engine pauses for Wi-Fi-only, Low Data Mode and Low Power Mode and stops with a reason when the server refuses
(full storage, expired login, no permission). Background tasks, silent pushes and the "Back up now" shortcut start it
without a window (`AppHost`). Details: SPEC §7.18.

## Shared state between app and extensions

Accounts, databases and caches live in the App Group container (`group.<bundle id>`), secrets in a shared keychain
access group. Debug builds are signed without these entitlements by default and then use the app's own container; the
extensions cannot see the accounts in that case (see "Signing" in the README).
