<p align="center">
  <img src="icon/app-icon.png" width="128" height="128" alt="The Nextcloud Photos app icon: a white mountain and sun on a blue rounded square">
</p>

<h1 align="center">Nextcloud Photos</h1>

<p align="center">
  <b>Your photos on your own server, in a native app for every Apple device.</b><br>
  iPhone · iPad · Mac · Apple Vision Pro · Apple TV · Apple Watch
</p>

<p align="center">
  <img src="docs/screenshots/hero.webp" width="860" alt="Nextcloud Photos on iPad and iPhone: on iPad the Library with its sidebar, the memories “1 year ago”, “2 years ago” and “13 years ago” as cards above November's photos; on iPhone the Library at the Days level with Lake Wakatipu on December 15 and a white tulip on November 29">
</p>

Nextcloud Photos gives the photos on your Nextcloud a fast, native home on every Apple device: a library that scrolls
through 100 000 photos at once, memories that play like films, editing that never loses the original, and a backup you
can see. It is built with SwiftUI for each platform (no web views, no Catalyst) and works with the Photos app your
Nextcloud already has — there is nothing to install on the server.

## Why Nextcloud Photos

<table>
  <tr>
    <td width="33%" valign="top"><b>Your photos, your server</b><br>Everything stays on the Nextcloud you run or trust. No analytics, no ads, no trackers, no other cloud.</td>
    <td width="33%" valign="top"><b>Native on every Apple device</b><br>One library on iPhone, iPad, Mac, Vision Pro, Apple TV and Apple Watch, each with the controls of its platform.</td>
    <td width="33%" valign="top"><b>Fast with 100 000 photos</b><br>The library is indexed on the device and scrolls without waiting for the server, also offline.</td>
  </tr>
  <tr>
    <td valign="top"><b>Backup you can trust</b><br>Full-quality backup that shows what is not safe yet, checks checksums before it frees space on the phone, and never uploads a photo twice.</td>
    <td valign="top"><b>Private intelligence</b><br>Faces, labels, text on signs and the best shot are found on your device by Apple's own frameworks. No AI models of its own, no photo sent away.</td>
    <td valign="top"><b>Edits that keep the original</b><br>Presets, curves, colour, masks and Erase are saved as a recipe next to the photo, so the original is never lost.</td>
  </tr>
</table>

## Your whole library, instantly

<table>
  <tr>
    <td width="55%" valign="top">
      The library is indexed on your device, so it opens and scrolls at once — with 100 000 photos, and also offline.
      Recent months are kept as ready-made tiles, so the first screen is there before the server has answered.
      <br><br>
      <b>Pinch</b> from years to months to days to every photo, or jump through time with the date scroller. Days that
      belong together get a name ("Weekend in Lisbon"), copies of one shot (RAW + JPEG, HEIC + JPEG) and bursts stack
      into one tile behind the best frame, and the photos you are likely to open next are already on the device.
      <br><br>
      <a href="docs/media/library-zoom.mp4">Watch as video</a>
    </td>
    <td width="45%" align="center">
      <img src="docs/media/library-zoom.webp" width="300" alt="Video: on iPhone the Library is pinched from days out to months and years, a year opens its months, and a pinch in shows that month's days">
    </td>
  </tr>
</table>

<p align="center">
  <img src="docs/screenshots/iphone-levels.webp" width="860" alt="Three iPhones: the Library as years, each a card with its key photo; the months of 2025 as cards; and the days, each a mosaic of its photos">
</p>

## Memories that tell a story

<table>
  <tr>
    <td width="45%" align="center">
      <img src="docs/media/memory-film.webp" width="300" alt="Video: a memory called “1 year ago” plays as a film on iPhone: a title over Moraine Lake, a slow move across the mountains, then a cross-fade to a seagull on Lake Wakatipu">
    </td>
    <td width="55%" valign="top">
      On this day, your trips and the people you love come together as memories at the top of the Library. Play one and
      it becomes a film: a title card, slow moves towards the faces in each photo, cross-fades between days and map
      flights between the stops of a trip. Pick a style (Cinematic, Upbeat, Black & White, Super 8, Calm) and export it
      as a video to share.
      <br><br>
      Birthdays from your Nextcloud's contacts become memories too: "Anna turns 30 today", with her photos.
      <br><br>
      <a href="docs/media/memory-film.mp4">Watch as video</a>
    </td>
  </tr>
</table>

## Every photo, full screen

<table>
  <tr>
    <td width="55%" valign="top">
      The viewer puts the photo first: swipe between photos, double-tap or pinch to zoom, swipe down and the photo lands
      back in its tile. Swipe up for the details — date, place on a map, camera and exposure, file and folder. Copies
      of one shot sit side by side in a strip, and a slideshow starts from any photo or album.
      <br><br>
      <a href="docs/media/viewer.mp4">Watch as video</a>
    </td>
    <td width="45%" align="center">
      <img src="docs/media/viewer.webp" width="300" alt="Video: in the album Lisbon 2025 on iPhone a photo opens full screen, three swipes go through the album, a double tap zooms in and out, and a swipe down puts the photo back into the album's grid">
    </td>
  </tr>
</table>

<p align="center">
  <img src="docs/screenshots/ipad-viewer.webp" width="760" alt="The viewer on iPad: Moraine Lake below snowy mountains, with the info inspector beside it showing name, date, camera, exposure, dimensions, size, type and folder">
</p>

## Find any photo

Type the way you think: "Lisbon 2025" or "favourite photos from Lisbon" become chips for a place, a date and your
favourites, and each chip can be changed with a tap. Type a camera — "x100v" — and it becomes a camera chip.
Search looks at places, dates, file names, albums, tags, people and cameras, and, once you turn it on, at what is in
your photos: labels, short descriptions and the text on signs, which Apple's Vision framework finds on your device.
On devices with Apple Intelligence, its on-device language model can help to understand what you type. Quick Actions
(⌘K) jump to any album, place, year or command.

<p align="center">
  <img src="docs/screenshots/iphone-search.webp" width="860" alt="Search on iPhone: “Lisbon 2025” is understood as a place chip and a date chip; the result, 11 photos from January 2025 in Lisbon; and a camera chip “Nikon D50” with the 8 flower photos taken with it">
</p>

## Places and people

Places shows your photos on a map, grouped as you zoom, with a time range to see one summer or one decade. "Then and
now" finds the spots you have photographed over the years, and the travel globe draws your trips.

**People** come from [Recognize](https://apps.nextcloud.com/apps/recognize) when your server runs it. Without it, the
app finds the faces itself, on your device, with Apple's Vision framework, and groups them into people you can name.
Nothing is sent anywhere for it.

<p align="center">
  <img src="docs/screenshots/places-people.webp" width="860" alt="Left: Places on iPhone, a map of Europe and Africa with photos grouped into clusters, each with a count. Right: People in the Mac app on a server without Recognize, eight people found on the Mac by Apple's Vision, each with “Add name”, and the note “People are found on this device with Apple's Vision, from the previews it has. Nothing is sent anywhere for it.”">
</p>

## Albums and sharing

Create albums, add photos from the grid, open the albums others share with you, and share an album through a public
link. Share photos and folders the Nextcloud way — with users, groups, Talk conversations or a link with a password and
an expiry date. Smart albums fill themselves from rules (people, places, dates, cameras, ratings…) and are the same on
all your devices. Send a photo as a postcard, find the photos in a family member's shared folder that belong with
yours, or hand your phone to someone with Guest Mode, which shows one album and nothing else.

## Edit without losing the original

<table>
  <tr>
    <td width="45%" align="center">
      <img src="docs/media/editor.webp" width="300" alt="Video: the editor on iPhone with a glacier lagoon at sunset: the presets Vivid, Warm, Cool, Black &amp; White and Matte are tried one after another, then an S curve deepens the shadows and brightens the highlights">
    </td>
    <td width="55%" valign="top">
      Edits are saved as a small recipe next to your photo on your Nextcloud, never in the photo itself, so they can be
      changed or undone at any time and show up on all your devices. Besides light, colour, crop and filters there are
      curves, a colour mixer for each hue, masks for the sky, the subject or the people in a photo, noise reduction and
      presets. Copy the edits of one photo and paste them onto others. When you want the result in the file itself,
      Apply Edits to the File writes it and keeps the original as a version on your Nextcloud.
      <br><br>
      <b>Erase</b> removes dust, spots and small distractions: tap them or brush over them, and the area is filled from
      what is around it.
      <br><br>
      <a href="docs/media/editor.mp4">Watch as video</a>
    </td>
  </tr>
</table>

<p align="center">
  <img src="docs/screenshots/iphone-editor.webp" width="860" alt="Three iPhones with the editor on a glacier lagoon at sunset: the presets Vivid, Warm, Cool and Matte; the Curves tool with an S curve; the colour mixer with the oranges selected and their hue, saturation and luminance">
</p>

## Backup you can trust

Backup is the second of three steps when you sign in: one tap, and your new photos and videos go to your Nextcloud — in
full quality, Live Photos with their motion. Photos that are on your phone but not on your server yet stand in the
Library with a small badge, so you always know what is safe; the account menu counts them, and "Back Up Now" sends any
photo at once. Large videos resume where they stopped after a lost connection or a restart. If you have used the
Nextcloud Files app's auto upload, the app sees what is already there and never uploads a photo twice.

**Free up space on this iPhone.** Once photos are safely on your Nextcloud, the app offers to remove them from the
phone. It keeps your recent photos, favourites and anything not fully backed up, lets you review every photo, and
compares checksums with the server right before anything is removed. The photos go to the phone's Recently Deleted,
never anywhere on the server.

<p align="center">
  <img src="docs/screenshots/iphone-backup.webp" width="860" alt="Three iPhones: the first run asks “Back up the photos of this iPhone?” with a Turn on backup button; the Backup screen says Up to date with 6 uploaded and offers Free up space on this iPhone, 12.5 MB; the free-up screen shows 12.5 MB in 4 photos that are safely on the Nextcloud, a review of the photos and the photos that stay">
</p>

Moving from another service? **Import** reads a Google Takeout, Apple's iCloud Photos export, or a Facebook or Instagram
download, keeps dates, albums and favourites, and skips what is already on your Nextcloud. **Clean up** gathers
duplicates, similar shots, large videos and screenshots, says how much space each would free on the server, and picks
the best shot of a series — sharp, well exposed, eyes open — and tells you why.

## Widgets and controls

<table>
  <tr>
    <td width="55%" valign="top">
      Your photos on the Home Screen: a <b>photo frame</b> that changes during the day (made for StandBy), <b>On this
      day</b>, your <b>favourites</b> and the state of the <b>backup</b>. They show what the app has synced,
      and no photo at all while app lock is on.
      <br><br>
      Control Center gets a switch for the backup and a Back Up Now button, and while a large backup runs, a Live
      Activity shows its progress on the Lock Screen and in the Dynamic Island.
    </td>
    <td width="45%" align="center">
      <img src="docs/screenshots/iphone-widgets.webp" width="300" alt="The iPhone Home Screen with four Nextcloud Photos widgets: a photo frame with a café in Queenstown, On this day with Moraine Lake “1 year ago”, the backup widget saying Backed up, last backup 1 minute ago, and Favorites with a seagull on Lake Wakatipu">
    </td>
  </tr>
</table>

## Made for every Apple device

**iPhone and iPad** — Liquid Glass, a sidebar on iPad with your account at the bottom, several windows with drag and drop
between them, keyboard shortcuts, widgets, Controls and the backup Live Activity.

<p align="center">
  <img src="docs/screenshots/ipad-editor.webp" width="760" alt="The editor on iPad in landscape: a glacier lagoon at sunset with the presets Vivid, Warm, Cool, Matte, Black &amp; White, Dramatic Sky, Portrait Pop and Clean Night below it">
</p>

**Mac** — a real Mac app: a full menu bar and keyboard control, smooth trackpad zoom, and tools for photographers —
ratings and flags with one key, compare two or four photos side by side, and Insights into your cameras, lenses and
settings.

<p align="center">
  <img src="docs/screenshots/mac-library.webp" width="860" alt="The Mac app: a sidebar with Library, Favorites, Memories, Places and the albums; the Library with Years, Months, Days and All Photos in the toolbar, the memories as cards and November's photos">
</p>

**Apple Vision Pro** — the app in a window of glass, with its controls in ornaments below it. Open a memory in the
Memory Room and its photos hang framed all around you.

**Apple TV** — memories, favourites and albums on the big screen, slideshows that drift and dissolve, a family slideshow
that keeps going, and your newest memories in the Top Shelf. Set it up from your iPhone: the TV finds the phone, you
confirm there, and the TV signs in with an app password of its own. Scanning a QR code works too.

**Apple Watch** — a photo of the day and the photos from this day in earlier years on your wrist, sent by the iPhone app.

<p align="center">
  <img src="docs/screenshots/vision-tv.webp" width="860" alt="Left: Apple Vision Pro with the albums Barcelona, Berlin, Lisbon, Prague, Rome and Vienna in a window with a sidebar, floating in a living room. Right: Apple TV with rows of memories and favourites">
</p>
<p align="center">
  <img src="docs/screenshots/watch.webp" width="420" alt="Two Apple Watch screens: the photo of the day, a station in Dubai from 13 years ago, and a grid of photos titled On This Day">
</p>

The devices work together: with Handoff, the photo, album or place you are looking at on one device can be continued on
the next.

## Private by design

- **Your photos stay on your Nextcloud.** They go to your server and nowhere else. The app has no analytics, no ads and
  no third-party trackers.
- **Intelligence on your device, from Apple.** Faces, labels, descriptions, the best shot and the masks come from Apple's
  own frameworks — Vision, VisionKit, Core Image and, where available, Apple Intelligence — running on your device. The
  app never ships or downloads AI models of its own, and no photo is sent anywhere else to be analysed.
- **Locked when you want it.** App lock with Face ID, Touch ID or Optic ID; archived photos and Recently Deleted always
  ask first. Widgets show no photo while app lock is on.
- **Nothing to install on the server.** The app works with the Photos app that comes with Nextcloud and finds out by
  itself what your server offers.

## For everyone

Photos, cards and controls have VoiceOver labels, text grows to the largest accessibility sizes, and the app follows
Reduce Motion, Reduce Transparency and Increase Contrast. Every main screen passes Apple's accessibility audit, at the
default and at the largest text size, in our UI tests. The app is in English today, and every text is ready for
translation ([docs/LOCALIZATION.md](docs/LOCALIZATION.md)).

## Requirements

- **Server:** Nextcloud 33 or later with its [Photos](https://github.com/nextcloud/photos) app (included with
  Nextcloud). Newer Photos versions add features, which the app switches on by itself.
- **Optional server apps:** [Recognize](https://apps.nextcloud.com/apps/recognize) for People found on the server
  (without it, the app finds people on your device); Contacts for birthdays; [notify_push](https://apps.nextcloud.com/apps/notify_push)
  for changes made elsewhere to arrive at once; the Tags, Trash bin and Talk apps for tags, Recently Deleted and sharing
  to conversations.
- **Devices:** iOS 27, iPadOS 27, macOS 27, visionOS 27, tvOS 27 or watchOS 27 (the watch app comes with the iPhone
  app).

The screenshots and videos show the real app, signed in to a test server with sample photos from Wikimedia Commons.

---

## For developers

The product and technical specification (the target) is in [docs/SPEC.md](docs/SPEC.md), what is built so far in
[docs/STATUS.md](docs/STATUS.md), a map of the code in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Optional server
additions are in [docs/SERVER-COMPANION.md](docs/SERVER-COMPANION.md), wire-format research notes in
[docs/reference](docs/reference). The screenshots above come from `scripts/readme-screenshots.sh` (and
`scripts/readme-screenshots-mac.sh` for the Mac), the videos from `scripts/readme-videos.sh`, and both are framed by
`scripts/frame-screenshots.swift` ([docs/TESTING.md](docs/TESTING.md)).

### Build

Requirements: Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate          # creates NextcloudPhotos.xcodeproj and the Info.plists from project.yml (not checked in)
open NextcloudPhotos.xcodeproj
```

Command-line builds without signing:

```sh
xcodebuild -scheme NextcloudPhotos -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme NextcloudPhotos -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
xcodebuild -scheme NextcloudPhotosTV -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme NextcloudPhotosWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The watch app is also built and embedded by the iOS build of `NextcloudPhotos`.

#### Signing with your own Apple ID

The project defaults to Nextcloud's team. To run on your Mac or devices, create `Config/Local.xcconfig` (git-ignored) from
`Config/Local.xcconfig.example` with your team id and a bundle id you own (not `com.nextcloud.photos`):

```
DEVELOPMENT_TEAM = ABCDE12345
PHOTOS_BUNDLE_ID = com.example.nextcloudphotos
```

Add your Apple ID in Xcode › Settings › Accounts, run `xcodegen generate`, and press Run.

Debug builds are signed **without entitlements** on purpose, so that any team, and no team at all, can build and run
them. The price: no App Group, no shared keychain and no push, so widgets and extensions cannot see the app's
accounts. To test those, register what the next section lists for your own bundle id and add
`PHOTOS_DEBUG_ENTITLEMENTS = YES` to `Config/Local.xcconfig`. The macOS App Sandbox comes from build settings
(`ENABLE_APP_SANDBOX`), so it is on in every build.

#### Release builds: what must exist in the Apple developer account

Release builds are signed with the entitlement files (`App/NextcloudPhotos.entitlements`, on macOS
`App/NextcloudPhotos-macOS.entitlements`, and one per extension). For the official app (team `NKUJUXUJ3B`):

| What | Value | Needed by |
|---|---|---|
| App IDs | `com.nextcloud.photos`, `.share`, `.notification-service`, `.widgets`, `.background-upload` | app and extensions |
| App IDs (Apple TV) | `com.nextcloud.photos.tv`, `com.nextcloud.photos.tv.topshelf` | the Apple TV app and its Top Shelf (SPEC §15.3). A separate App Store app; for universal purchase with the iPhone app the TV target would use `com.nextcloud.photos` itself (decision for Nextcloud) |
| App IDs (Apple Watch) | `com.nextcloud.photos.watchkitapp`, `com.nextcloud.photos.watchkitapp.widgets` | the watch app (shipped inside the iPhone app) and its complication |
| App Group | `group.com.nextcloud.photos`, enabled on all five App IDs and on the four TV and watch App IDs | accounts, databases and caches shared with the extensions; the share extension's uploads that the app finishes; on the TV and the watch (separate devices, same group name) what their Top Shelf and complication show |
| App Groups of the Files app | `group.com.nextcloud.apps`, `group.it.twsweb.Crypto-Cloud`, enabled on the app's App ID | backup: reading what the Files app already uploaded |
| Keychain Sharing | group `$(AppIdentifierPrefix)com.nextcloud.photos` (needs no registration; all five targets must be signed by the same team) | app passwords and push keys for the extensions |
| Keychain (Apple TV) | group `$(AppIdentifierPrefix)com.nextcloud.photos.tv` (no registration) | the TV's app password |
| PhotoKit background uploads | `com.apple.photos.background-upload` on `com.nextcloud.photos.background-upload` (iOS and macOS). The extension point requires it (`EXRequiredEntitlements` of `com.apple.photos.background-upload` on macOS 27.3); it is in `Extensions/BackgroundUpload/BackgroundUpload.entitlements`. **Has to be enabled for Nextcloud's App ID** (check in the developer portal whether Apple grants it on request, as for the Files app's extension). Without it the system never starts the extension and the backup uses the app's own background session only | backup (SPEC §7.18.6) |
| Push Notifications | capability on `com.nextcloud.photos`, and an APNs key or certificate for it | push |
| Push proxy | `push-notifications.nextcloud.com` must accept the topic `com.nextcloud.photos` (server side, not in the developer portal) | push |
| Notification filtering | `com.apple.developer.usernotifications.filtering` on the notification service extension. **Apple grants it on request only.** It is not in the entitlement file yet: add it to `Extensions/NotificationService/NotificationService.entitlements` once granted. Without it the extension cannot hide notifications of the server that are not about photos | push |
| Provisioning profiles | one per App ID and platform (iOS, macOS, visionOS, tvOS, watchOS), or automatic signing with an App Store Connect API key | all |
| Apple TV artwork | layered app icon (400×240, 1280×768) and Top Shelf images (1920×720, 2320×720); `App/TV/Assets.xcassets` has placeholders made from the app icon | App Store |

The entitlement files say `aps-environment = development` (macOS: `com.apple.developer.aps-environment`); exporting an
archive for TestFlight or the App Store switches it to `production`. Version and build number are `MARKETING_VERSION`
and `PHOTOS_BUILD_NUMBER` in `Config/Base.xcconfig`; CI overrides the build number on the command line
(`xcodebuild … PHOTOS_BUILD_NUMBER=123`). `.github/workflows/release.yml` archives all three platforms, unsigned
until the signing secrets exist.

App Store declarations (privacy manifest, the App Transport Security exception and its justification for App Review,
export compliance) are explained in [docs/PRIVACY-AND-EXPORT.md](docs/PRIVACY-AND-EXPORT.md); what the app icon still
needs from a designer in [docs/APP-ICON.md](docs/APP-ICON.md).

### Code layout

All code lives in the local Swift package `Packages/PhotosKit`; the app target only contains the entry point and resources.
The exceptions are the Apple TV app (`App/TV`, Top Shelf in `Extensions/TopShelf`) and the Apple Watch app (`App/Watch`,
complication in `Extensions/WatchWidgets`): their screens are made for the Siri Remote and the watch and share no UI
with `PhotosAppUI`; their logic is in the package (SPEC §15.3).

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

### Tests

The unit tests need macOS 27 (the package's deployment target). Either of these runs all of them:

```sh
cd Packages/PhotosKit
swift test
xcodebuild test -scheme PhotosKit-Package -destination 'platform=macOS'   # what CI runs
```

With `xcodebuild`, environment variables only reach the tests with the prefix `TEST_RUNNER_`
(`TEST_RUNNER_PHOTOS_SKIP_PERFORMANCE=1 xcodebuild test …` skips the slow timing tests).

All CI jobs run on GitHub's `xcode-27` runner (macOS 27), except REUSE (Linux): lint, the unit tests on macOS and in an
iOS 27 simulator (a job fails when no test ran), Debug builds for iOS, macOS and visionOS, and an unsigned Release
archive of each. A nightly workflow runs the timing tests and the integration tests against a Nextcloud that it
installs on the runner.

Integration tests against a real server, UI smoke tests and the manual test plan for devices are described in
[docs/TESTING.md](docs/TESTING.md) and [docs/test-plan.md](docs/test-plan.md). In short:

```sh
scripts/test-server.sh /tmp/photos-test-server 8089     # a throw-away Nextcloud with sample photos
PHOTOS_IT_SERVER=http://127.0.0.1:8089 PHOTOS_IT_USER=admin PHOTOS_IT_PASSWORD=admin swift test --no-parallel --filter Integration
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md): pull requests against `main`, one feature or fix each, signed off (DCO), with
tests; Nextcloud's AI contribution policy applies. Security issues: [SECURITY.md](SECURITY.md).

## Licence

MIT, see [LICENSE](LICENSE). The only third-party dependency is [GRDB](https://github.com/groue/GRDB.swift) (MIT).
The Nextcloud name and logo are trademarks of Nextcloud GmbH.
