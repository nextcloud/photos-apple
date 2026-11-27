# Release checklist — what Nextcloud's team does to ship Nextcloud Photos

The code side is ready for a first TestFlight build: one multiplatform app (iPhone, iPad, Mac, Vision Pro) with four
extensions and a Watch app inside, plus a separate Apple TV app. What is left needs Nextcloud GmbH's Apple developer
account (team `NKUJUXUJ3B`), its servers and its people. Work through the steps in order; each says where the details
are. Tick them in a GitHub issue ("Release 1.0") rather than in this file.

## 1. Identifiers and capabilities (developer portal)

The full table with the reasons is in the README, "Release builds". In short:

- [ ] **App IDs** (explicit): `com.nextcloud.photos` and its extensions `.share`, `.notification-service`, `.widgets`,
      `.background-upload`; the Watch app `.watchkitapp` and `.watchkitapp.widgets`; the Apple TV app `.tv` and
      `.tv.topshelf`. The app ID is shared by iOS, macOS and visionOS (one multiplatform target, universal purchase).
- [ ] **App Group** `group.com.nextcloud.photos` on all nine App IDs.
- [ ] **App Groups of the Files app** `group.com.nextcloud.apps` and `group.it.twsweb.Crypto-Cloud` on `com.nextcloud.photos`
      (the backup reads what the Files app uploaded, SPEC §7.18.5). These groups belong to the Files app's App IDs in the
      same team; check that the portal allows a second App ID in them.
- [ ] **Keychain Sharing**: nothing to register; all targets signed by the same team.
- [ ] **Push Notifications** on `com.nextcloud.photos`; an APNs auth key (`.p8`) for the push proxy (step 4).
- [ ] **Group Activities** (`com.apple.developer.group-session`, SharePlay films) on `com.nextcloud.photos` and `.tv`.
- [ ] **PhotoKit background uploads** (`com.apple.photos.background-upload`) on `.background-upload`. Ask Apple if the
      portal does not offer it. Without it the backup still works, but only through the app's own background session.
- [ ] **Notification filtering** (`com.apple.developer.usernotifications.filtering`) for `.notification-service`:
      **request from Apple** (form "Notification Service Extension Filtering"). Once granted, add the key to
      `Extensions/NotificationService/NotificationService.entitlements`. Without it notifications of other server apps
      are shown too (DEVICE-TEST-PLAN D5).
- [ ] **Background tasks**: nothing to register, but the identifiers are fixed in `project.yml`
      (`BGTaskSchedulerPermittedIdentifiers`): `com.nextcloud.photos.refresh`, `.processing`, `.labels`, `.similar`,
      `.describe`, `.meaning`, `.offline`, and the wildcard `com.nextcloud.photos.backup.*` (continued processing of a backup or an
      import). Background modes in Info.plist: `fetch`, `processing`, `remote-notification`. If the bundle id ever
      changes, the fixed identifiers must change with it (`App/Shared/BackgroundTasks.swift`, `PhotosCore`).
- [ ] **Mac**: App Sandbox with outgoing network, user-selected files, the photo library, USB (camera import),
      removable volumes, app-scoped bookmarks; Hardened Runtime. All from build settings and
      `App/NextcloudPhotos-macOS.entitlements`, nothing to request.

## 2. Signing in CI

- [ ] Create an **App Store Connect API key** (role App Manager) and store it as repository secrets
      `APP_STORE_CONNECT_KEY`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`.
- [ ] Finish the `TODO(signing)` steps in `.github/workflows/release.yml`: drop `CODE_SIGNING_ALLOWED=NO`, archive with
      `-allowProvisioningUpdates -authenticationKey…`, export with method `app-store-connect` and destination `upload`.
      The export switches `aps-environment` from `development` to `production`.
- [ ] Add the Apple TV app to the workflow (scheme `NextcloudPhotosTV`, `generic/platform=tvOS`); it is a separate
      App Store app unless Nextcloud decides on universal purchase (README).
- [ ] Version: `MARKETING_VERSION` in `Config/Base.xcconfig` (0.1.0 today → 1.0.0 for the store); the build number is
      the workflow's run number.

## 3. App Store Connect record

- [ ] New app "Nextcloud Photos" (check the name is free; fallback "Nextcloud Photos – Gallery"), platforms iOS, macOS,
      visionOS, bundle id `com.nextcloud.photos`, SKU e.g. `nextcloud-photos`. A second record for the Apple TV app.
- [ ] Category **Photo & Video**, secondary **Productivity**. Price free. Age rating: no objectionable content (the app
      shows the user's own photos; answer "no" to all content questions, "unrestricted web access: no").
- [ ] Texts from [APP-STORE-METADATA.md](APP-STORE-METADATA.md): subtitle, description, keywords, promotional text,
      support URL, marketing URL, privacy policy URL, copyright.
- [ ] **Screenshots**: run `scripts/app-store-screenshots.sh` (sizes and how in step 7).
- [ ] **App privacy** ("nutrition label"): must match the privacy manifests (`docs/PRIVACY-AND-EXPORT.md`). Today the
      manifests declare *Device ID, App Functionality, not linked, no tracking* for the push token sent to the push proxy.
      Decide this together with the Files and Talk apps' labels; if Nextcloud says "Data Not Collected" there, remove the
      entry from `App/Resources/PrivacyInfo.xcprivacy`, `App/TV/PrivacyInfo.xcprivacy` and
      `Packages/PhotosKit/Sources/PhotosCore/Resources/PrivacyInfo.xcprivacy` first.
- [ ] **Export compliance**: `ITSAppUsesNonExemptEncryption = false` is in the Info.plist (reasoning in
      `docs/PRIVACY-AND-EXPORT.md`); confirm with whoever answers this for the account.

## 4. Push proxy

- [ ] `push-notifications.nextcloud.com` must accept the APNs topic `com.nextcloud.photos` (development and production)
      with the APNs key of step 1. This is a change in the proxy's configuration, the same as for the Files and Talk apps.
- [ ] Notifications app: decide whether it gets an app filter so that only `photos` notifications reach this client
      (alternative to the filtering entitlement). SPEC §14 item 4.

## 5. Translations (Transifex)

- [ ] With the localization team: create the resources, the bot handler and `.tx/config` as proposed in
      `docs/LOCALIZATION.md` ("Transifex: proposed setup"). Until then the app ships in English only; dates and numbers
      already follow the device's region.
- [ ] Translate the App Store texts too (App Store Connect › localizations), at least German.

## 6. Artwork and legal

- [ ] App icon from a designer (`docs/APP-ICON.md`): today it is the Photos server app's icon on Nextcloud blue; the
      Apple TV layered icon and Top Shelf images are placeholders made from it.
- [ ] The trademark "Nextcloud" in the name and icon: the official account publishes it, nothing else to do.
- [ ] The screenshots show sample photos from Wikimedia Commons (`LICENSES/LicenseRef-Screenshots.txt`); for the store
      prefer photos Nextcloud owns: put them into the test server's library and run the screenshots again.
- [ ] NextcloudKit is GPL-3.0; the app's own code is MIT (SPEC §2). Check with Nextcloud's legal contact that shipping
      through the App Store fits (the Files app does the same).

## 7. Screenshots

`scripts/app-store-screenshots.sh <out> <udid>…` signs in to a test server, sets a clean status bar and writes seven
screens per device (Library, viewer, memories, albums, map, search, backup) from `UITests/AppStoreScreenshots.swift`.

| Store slot | Simulator | Size (portrait) |
|---|---|---|
| iPhone 6.9" (required) | iPhone 17 Pro Max | 1320 × 2868 |
| iPad 13" (required for iPad) | iPad Pro 13-inch (M5) | 2064 × 2752 |
| Apple Vision Pro | Apple Vision Pro | 3840 × 2160 |
| Mac | the Mac app, window 1440 × 900 pt on a Retina display | 2880 × 1800 |
| Apple TV | the TV app (UITestsTV) | 3840 × 2160 or 1920 × 1080 |

- [ ] Use a server whose library is good to look at (step 6) and holds nothing else (the round-10 set shows test albums
      of other test runs and two photos without previews), the app in English, light appearance; check each image for
      personal data and the server address (the Backup screen names it) before uploading. Mac: capture the window of a test build (`screencapture -o -l <window id>`).

## 8. TestFlight

- [ ] Upload a build (step 2), fill **Test Information**: what to test (APP-STORE-METADATA.md), feedback email, and a
      **review account**: a demo Nextcloud server reachable from the internet with an account full of sample photos,
      the Photos app, Notifications; its address, user and app password go into "Sign-in information".
- [ ] **App Review notes** (also for the first store submission) — paste and adapt:

      Nextcloud Photos is a client for a Nextcloud server that the user runs or chooses. To try it, enter the server
      address below on the login screen and sign in with the user and password given. Server: <https://…>
      User: <…> Password: <…>.
      Backup (account button at the top of the Library › Settings › Backup) uploads the photo library to that
      server; it needs full photo library access, which the app asks for only when backup is turned on. Background modes: "processing" and "fetch" keep the
      library and the backup up to date; "remote-notification" delivers Nextcloud notifications through Nextcloud's
      push proxy. App Transport Security: the server address is typed in by the user, many self-hosted servers use HTTP
      in a home network or a private certificate authority, so NSAllowsArbitraryLoads is set; the app warns before
      every login over HTTP and asks before trusting an unknown certificate. All endpoints run by Nextcloud use HTTPS.

- [ ] Internal testers first (DEVICE-TEST-PLAN.md, all of it, on a TestFlight build), then an external group (needs
      Beta App Review, one to two days).

## 9. Before each release

- [ ] `scripts/check-privacy-manifests.py` passes (CI or by hand) and the App privacy answers still match.
- [ ] `scripts/measure-performance.sh ios <udid>` and `mac <app>` compared with the baselines in
      [PERFORMANCE.md](PERFORMANCE.md); D8 of the device plan on the oldest supported iPhone.
- [ ] STATUS.md has no 🟡 that the release notes claim as working.
- [ ] No machine-learning model of the app's own in the archive (no Core ML model, no model download): the app uses only
      Apple's frameworks for AI (SPEC §2 "On-device AI", §21).
- [ ] What's New written (APP-STORE-METADATA.md), version bumped, the release commit tagged `v<version>-<build>`.
