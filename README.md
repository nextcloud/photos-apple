# Nextcloud Photos for iOS, iPadOS, macOS and visionOS

A native Apple app for the photos and videos in your Nextcloud: timeline, albums, sharing, places, people, memories, backup and more.
It works with the [Photos](https://github.com/nextcloud/photos) app on Nextcloud 33 and later.

The product and technical specification is in [docs/SPEC.md](docs/SPEC.md); optional server additions are in
[docs/SERVER-COMPANION.md](docs/SERVER-COMPANION.md). Wire-format research notes are in [docs/reference](docs/reference).

## Build

Requirements: Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate          # creates NextcloudPhotos.xcodeproj from project.yml (not checked in)
open NextcloudPhotos.xcodeproj
```

Command-line builds without signing:

```sh
xcodebuild -scheme NextcloudPhotos -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme NextcloudPhotos -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

Debug builds use `App/NextcloudPhotos-Debug.entitlements` (no App Groups or keychain group, so they run without Nextcloud's provisioning
profile). Release builds use `App/NextcloudPhotos.entitlements`.

## Code layout

All code lives in the local Swift package `Packages/PhotosKit`; the app target only contains the entry point and resources.

| Module | Contents |
|---|---|
| `PhotosModel` | Value types (media, albums, accounts, server features). No I/O. |
| `PhotosDomain` | Pure algorithms shared with the web app (timeline sections, stacks, memories, duplicates…). |
| `PhotosNetworking` | HTTP with certificate trust, WebDAV/SEARCH, OCS, Login Flow v2, feature detection, Photos API. |
| `PhotosStore` | GRDB database per account, queries, sync engine, outbox. |
| `PhotosMedia` | Preview cache, image pipeline, originals, BlurHash. |
| `PhotosBackup` | Camera-roll backup (milestone M3). |
| `PhotosCore` | Accounts, keychain, per-account services, app and session models. |
| `PhotosAppUI` | SwiftUI screens and the photo grid (UIKit/AppKit collection views). |

## Tests

```sh
cd Packages/PhotosKit && swift test
```

Integration tests against a real server run when these variables are set (use a test server; the test only reads):

```sh
PHOTOS_IT_SERVER=http://localhost:8089 PHOTOS_IT_USER=admin PHOTOS_IT_PASSWORD=admin swift test --filter IntegrationTests
```

For UI work, Debug builds sign in without a browser when started with
`PHOTOS_DEBUG_LOGIN='nc://login/server:<url>&user:<user>&password:<app password>'`.

## Contributing

Pull requests against `main`; one feature or fix per PR; sign off your commits (DCO). Every source file carries an SPDX header.
Lint with `xcrun swift-format lint --strict --configuration .swift-format` on the changed files.

## Licence

MIT, see [LICENSE](LICENSE). The app links [NextcloudKit](https://github.com/nextcloud/NextcloudKit) (GPL-3.0-or-later with App Store
exception), so the distributed app is also subject to its terms. The Nextcloud name and logo are trademarks of Nextcloud GmbH.
