# Nextcloud iOS app + NextcloudKit — research for a native "Nextcloud Photos" app

Snapshot analysed (shallow clones, 2026-11-22):

| Repo | Commit (HEAD of default branch) | Notes |
|---|---|---|
| `nextcloud/ios` | `5008e007` (2026-11-22), `MARKETING_VERSION = 35.3.0`, codename "Matheria" | Xcode project `Nextcloud.xcodeproj`; pins NextcloudKit to **branch `main`** (not a tag) |
| `nextcloud/NextcloudKit` | `53022284` (2026-11-19) | latest release tag **7.6.5** |

All file paths below are relative to the respective repo root.

---

## 0. TL;DR for the spec

* **Use NextcloudKit (SPM) as the networking layer.** It builds for iOS 17+, macOS 11+, tvOS 14+, watchOS 7+, **visionOS 1+**; deps Alamofire 5.10+, SwiftyJSON 5, SwiftyXMLParser 5.6. Every API has a completion form and an `…Async` wrapper (named-tuple result, errors as `NKError` values, not throws) — except a few async-first ones (`getLoginFlowV2(...) async throws`, `uploadChunkAsync(...) async throws`, `unifiedSearch(...) async`, Governance).
* NextcloudKit already has: Login Flow v2 + polling, app-password from basic creds / one-time token, app-password delete, remote-wipe check/success, capabilities, SEARCH with arbitrary body, PROPFIND with arbitrary body on arbitrary URL, previews by fileId, chunked upload (v2 chunking with `Destination` + `OC-Total-Length`), background-URLSession upload/download, favorites, OCS shares + unified sharing, notifications + push registration, unified search, comments, trashbin, systemtags, Live-Photo linking (`nc:metadata-files-live-photo` PROPPATCH) and — new in 2026 — **Photos-app albums** (`/remote.php/dav/photos/<user>/albums/`).
* There is **no media-specific search helper any more** (`searchMedia` is gone; `NKDataFileXML.getRequestBodySearchMedia` is `internal` and unused). The iOS app builds its own SEARCH body (`iOSClient/Media/NCMediaNetwork.swift`) and sends it via `NextcloudKit.searchAsync(serverUrl:httpBody:…)`. Do the same.
* Also new: **`NextcloudKitUI`** (second SPM product) with a SwiftUI `ServerAddressView` that runs the whole Login Flow v2 through `WebAuthenticationSession` (ASWebAuthenticationSession, ephemeral) — directly reusable for the Photos app (iOS 17 / macOS 15 minimum per its docs).
* Login: Login Flow v2 in **ASWebAuthenticationSession (ephemeral)** with **WKWebView fallback** for mTLS/cert problems; 1-second polling; QR `nc://login/…` and `nc://onetime-login/…`. App password stored in Keychain (KeychainAccess, service `com.nextcloud.keychain`, key `"password" + account`, access group `$(AppIdentifierPrefix)it.twsweb.Crypto-Cloud`). Account id string = `"<user> <urlBase>"`.
* The Files app **does not revoke the app password on logout** (`deleteAppPassword` exists in NextcloudKit but is never called) — the Photos app should do better.
* Auto-upload state lives in a shared **Realm** DB (`nextcloud.realm`, schema 425) plus a new **GRDB SQLite** DB (`nextcloud.sqlite`) in App Group `group.it.twsweb.Crypto-Cloud`. Uploaded-asset tracking is keyed by **PHAsset `localIdentifier`** (`tableAutoUploadTransfer.assetLocalIdentifier` in Realm; `photoLibraryAsset` / `autoUploadResource` tables in SQLite).
* iOS 27: the Files app ships an experimental **PhotoKit background-upload extension** (`PHBackgroundResourceUploadJobExtension`, extension point `com.apple.photos.background-upload`), TestFlight/Debug-only, server ≥ NC 35. This is the most relevant modern pattern for a Photos app.
* Team ID **NKUJUXUJ3B** (Nextcloud GmbH). A second app can share data only if it is signed by the same team and lists the same App Group / keychain group. Cross-app read access has sharp edges (see §6.4).
* Licence **GPL-3.0-or-later + App Store exception** (`COPYING.iOS`) for both repos; logos/name are `LicenseRef-NextcloudTrademarks`. Linking NextcloudKit makes the Photos app a GPL work.

---

## 1. Authentication

### 1.1 Login Flow v2

NextcloudKit (`Sources/NextcloudKit/NextcloudKit+Login.swift`):

| Function | HTTP | Notes |
|---|---|---|
| `getLoginFlowV2(serverUrl:options:taskHandler:) async throws -> (endpoint: URL, login: URL, token: String)` | `POST {server}/index.php/login/v2` | via `unauthorizedSession`; parses `poll.token`, `poll.endpoint`, `login` |
| `getLoginFlowV2(serverUrl:options:taskHandler:completion:)` / `getLoginFlowV2Async` | same | completion/tuple variants |
| `getLoginFlowV2Poll(token:endpoint:options:…)` / `getLoginFlowV2PollAsync` | `POST {endpoint}?token=<token>` | returns `server`, `loginName`, `appPassword`; **HTTP 404 = still pending** |
| `getAppPassword(url:user:password:userAgent:…)` / `…Async` | `GET ocs/v2.php/core/getapppassword` (Basic auth with real password) | used for MDM/AppConfig credentials; fails with 2FA |
| `getAppPasswordOnetime(url:user:onetimeToken:…)` / `…Async` | `GET ocs/v2.php/core/getapppassword-onetime` | for `nc://onetime-login/` QR codes |
| `deleteAppPassword(serverUrl:username:password:…)` / `…Async` | `DELETE ocs/v2.php/core/apppassword` | revocation — **unused by the iOS app** |

Before starting, both the app and NextcloudKitUI call `getServerStatus(serverUrl:)` (`GET status.php`, `NextcloudKit+API.swift`).

**iOS app flow** (`iOSClient/Login/NCLogin.swift`, `iOSClient/Login/NCLoginProvider.swift`):

1. Normalises the URL (adds `https://`, upgrades `http://` to `https://`; on https failure offers an explicit "try http" alert in Release, automatic in Debug).
2. `getServerStatus` → on `NSURLErrorServerCertificateUntrusted` offers "connect anyway" / certificate details (see 1.4).
3. `getLoginFlowV2(serverUrl:options: NKRequestOptions(customUserAgent: userAgent))`.
4. `NCLoginProvider.startPolling(...)` — a `Task` that calls `getLoginFlowV2Poll` then `Task.sleep(for: .seconds(1))` until it gets credentials.
5. `NCLoginProvider.startAuthentication()` — **`ASWebAuthenticationSession(url: login, callbackURLScheme: "nc")`**, `prefersEphemeralWebBrowserSession = true`. If the session fails with anything other than `.canceledLogin` (e.g. client-certificate/mTLS challenge) or fails to start, it **falls back to `NCLoginProviderWebViewFallback`** (a `WKWebView` with `customUserAgent = userAgent`, handling `didReceive challenge` for server trust and intercepting `nc://login/...` redirects).
6. Callback URL format (legacy flow v1 style, also emitted by the server's grant page): `nc://login/server:<url>&user:<user>&password:<apppassword>`; parsed in `handleLoginCallback(url:)`.
7. On grant → `NCAccount().createAccount(viewController:urlBase:user:password:controller:)` (`iOSClient/Account/NCAccount.swift`).

**NextcloudKitUI flow** (`Sources/NextcloudKitUI/Views/Login/LoginFlowModel.swift`, `ServerAddressView.swift`) — the cleaner reference for a SwiftUI app:

```swift
ServerAddressView(backgroundColor: Binding<Color>, brandImage: Image,
                  sharedAccounts: [SharedAccount], userAgent: String?,
                  addAccount: (host: URL, name: String, password: String) -> Void)
```
`LoginFlowModel` (`@MainActor @Observable`): `getServerStatusAsync` → `getLoginFlowV2` → polling task every 1 s (404 = pending, any other error terminal) → `presentLoginPage(_:using: WebAuthenticationSession)` with `session.authenticate(using: url, callbackURLScheme: "nc", preferredBrowserSession: .ephemeral)`. Also handles QR codes via CodeScanner (`QRCodeParsing`, prefixes `nc://login/` and `nc://onetime-login/`), and a "shared accounts" picker (prefills server only — username prefill disabled until nextcloud/server#59874). No WKWebView fallback here (only a generic `WebView` view exists).

**2FA**: entirely handled server-side inside the web login page of Login Flow v2; the app never sees it. Only the AppConfig/MDM path (`getAppPassword` with username+password) cannot do 2FA.

### 1.2 Account model, multiple accounts

* Account key: `let account = "\(user) \(urlBase)"` (`NCAccount.createAccount`). `urlBase` has trailing `/` stripped.
* After login: `NextcloudKit.shared.appendSession(account:urlBase:user:userId:password:userAgent:httpMaximumConnectionsPerHost…:groupIdentifier:)`, then `getUserProfileAsync` (`GET ocs/v2.php/cloud/user`) to learn the real `userId` (may differ from login name) → `updateSession(account:userId:)`.
* Persists: Realm `tableAccount` (primary key `account`, `active` flag marks the current one), Keychain password, File Provider domain (`FileProviderDomain().ensureDomainRegistered`), client certificate (if any).
* Multiple accounts are fully supported; one is `active`. `NCAccount.changeAccount(...)` switches theming, push subscription, services. Auto-upload may be enabled for **only one account at a time** (`"_autoupload_active_other_account_message_"`).
* NextcloudKit keeps one `NKSession` per account in `nkCommonInstance.nksessions` (`SynchronizedNKSessionArray`); every API takes `account: String`.
* MDM/AppConfig (`com.apple.configuration.managed`) keys (`iOSClient/NCGlobal.swift`): `serverUrl`, `username`, `password`, `apppassword`, `brand`, `disable_intro`, `disable_multiaccount`, `disable_crash_service`, `disable_log`, `disable_more_external_site`, `disable_openin_file`, `enforce_passcode_lock` (only honoured if `NCBrandOptions.use_AppConfig`).

### 1.3 App-password storage (Keychain)

`iOSClient/Settings/NCPreferences.swift`:

* `let keychain = Keychain(service: "com.nextcloud.keychain")` (KeychainAccess 4.x, **no explicit `accessGroup`** → default = first entry of `keychain-access-groups` entitlement = `$(AppIdentifierPrefix)it.twsweb.Crypto-Cloud`, i.e. `NKUJUXUJ3B.it.twsweb.Crypto-Cloud`). Default accessibility of KeychainAccess = `afterFirstUnlock`.
* Password: key `"password" + account` (`getPassword(account:)` / `setPassword(account:password:)`); legacy migration from service `"Crypto Cloud"`.
* Other keychain items per account: `PushPrivateKey<account>`, `PushPublicKey<account>`, `PushSubscribingPublicKey<account>`, `PushDeviceIdentifierSignature<account>`, `ClientCertificateData<account>` (PKCS#12), `ClientCertificatePassword<account>`, E2EE keys, `passcodeBlock`.
* Non-secret preferences have moved to App-Group `UserDefaults(suiteName: "group.it.twsweb.Crypto-Cloud")` with key prefix `Preferences_<key>` or `Preferences_<key>_<account>` (lazy migration from keychain).

### 1.4 Self-signed server certs and client certificates

* NextcloudKit forwards every `URLAuthenticationChallenge` to `NextcloudKitDelegate.authenticationChallenge(_:didReceive:completionHandler:)` (`NKCommon.swift`, `NextcloudKitSessionDelegate.swift`, also from `NKBackground` for background sessions). Default: `.performDefaultHandling`. The app implements it in `iOSClient/Networking/NCNetworking.swift`:
  * **Client certificate (mTLS)**: `NSURLAuthenticationMethodClientCertificate` → builds a `URLCredential` from stored PKCS#12 (`p12Data`, `p12Password`, helper `PKCS12`), else asks the user to import one (`certificateDelegate?.didAskForClientCertificate()`). Stored in keychain per account after login (`NCPreferences.setClientCertificate`).
  * **Server trust**: `checkTrustedChallenge` — if `SecTrustEvaluateWithError` passes → use. Otherwise compares the leaf cert DER bytes with a user-accepted copy at `<AppGroup>/Library/Application Support/Certificates/<host>.der` (written from `<host>.tmp` when the user taps "yes" in `AppDelegate.trustCertificateError(host:)` / `NCLogin`). Also dumps a human-readable `<host>.txt` via OpenSSL for the details screen (`NCViewCertificateDetails`). Pinning is per-host, leaf-cert equality.
  * **Extensions (`#if EXTENSION`) accept any server trust** (`URLCredential(trust:)` without evaluation) — a security weakness; don't copy.
* WKWebView fallback in login handles server-trust challenges too.
* `Info.plist`: `NSAppTransportSecurity.NSAllowsArbitraryLoads = true` (needed for http / self-signed).

### 1.5 Server-side wipe & unauthorized handling

NextcloudKit `NextcloudKit+API.swift`:
* `getRemoteWipeStatus(serverUrl:token:account:…)` → `POST index.php/core/wipe/check` form param `token=<apppassword>`, unauthenticated session, JSON `{"wipe": true|false}`.
* `setRemoteWipeCompletition(serverUrl:token:account:…)` (sic, typo in name) → `POST index.php/core/wipe/success`.

App logic `NCAccount.checkRemoteUser(account:controller:)`:
1. Triggered when a request returns 401. NextcloudKit records the account in App-Group defaults array `"Unauthorized"` (`NKCommon.appendServerErrorAccount`, keys `"Unauthorized"`, `"Unavailable"` (503), `"ToS"` (403 + terms_of_service capability)). `NKInterceptor` then **short-circuits all further requests** for that account with a synthetic 401/503/403 until removed (bypass with `NKRequestOptions(checkInterceptor: false)`).
2. Re-verifies with `getUserProfileAsync(options: checkInterceptor:false)`; only a real 401 continues.
3. Shows a banner, calls `getRemoteWipeStatusAsync(token: password)`, then `deleteAccount(account, wipe: result.wipe)`; if wipe → `setRemoteWipeCompletitionAsync`.

### 1.6 Logout / app-password revocation

`NCAccount.deleteAccount(_:wipe:)`: unsubscribes push (server + proxy), removes File Provider domain, deletes local files (if wipe), clears Realm + GRDB rows, removes NK session and capabilities, clears keychain password/E2EE/push keys. **It never calls `deleteAppPassword`**, so the device token stays valid on the server ("Devices & sessions"). Recommendation for Photos: call `NextcloudKit.shared.deleteAppPasswordAsync(serverUrl:username:password:account:)` (`DELETE ocs/v2.php/core/apppassword`, OCS-APIRequest) before discarding credentials.

### 1.7 User-Agent conventions

* `Brand/NCBrand.swift`: `"Mozilla/5.0 (iOS) Nextcloud-iOS/\(CFBundleShortVersionString)"` + optional `-<brandUserAgent>` suffix. Registered as `UserDefaults.standard "UserAgent"` and passed into every `NKSession` (`appendSession(userAgent:)`); WK fallback uses it as `customUserAgent`.
* For the push proxy the app sends `"<userAgent>  (Strict VoIP)"` (two spaces) via `NKRequestOptions(customUserAgent:)`.
* NextcloudKitUI's login just passes through whatever `userAgent:` you give it.
* (Server knowledge, not from these repos: Nextcloud's `IRequest::USER_AGENT_CLIENT_IOS` regex matches `^Mozilla/5.0 (iOS) (ownCloud|Nextcloud)-iOS.*` and is used for client detection / naming the app token in "Devices & sessions"; a Photos app should use a distinct but similarly structured UA, e.g. `Mozilla/5.0 (iOS) Nextcloud-Photos-iOS/<ver>` — confirm against the server's regexes before relying on any server behaviour.)
* NextcloudKit adds on every authenticated request: Basic auth, `OCS-APIRequest: true`, `Accept: application/json` (default), **`X-NC-Account: <account>`** (internal header used by the interceptor; it is also sent to the server), optional `X-NC-Paginate*` headers.

---

## 2. NextcloudKit (Swift Package)

### 2.1 Package facts (`Package.swift`)

* `swift-tools-version:5.9`, `name: "NextcloudKit"`, `defaultLocalization: "en"`.
* **Products**: `.library("NextcloudKit")`, `.library("NextcloudKitUI")`.
* **Platforms**: `.iOS(.v17)`, `.macOS(.v11)`, `.tvOS(.v14)`, `.watchOS(.v7)`, **`.visionOS(.v1)`** → macOS and visionOS are supported. (`AGENTS.md`: "used by the Nextcloud Files, Notes and Talk apps on iOS as well as the Desktop client" — the macOS desktop client's File Provider uses it.) `NKShareAccounts` is `#if os(iOS)` only (uses `UIApplication`). NextcloudKitUI docs state minimum iOS 17 / macOS 15; CodeScanner/QR is iOS-only.
* **Dependencies**: Alamofire `from: 5.10.2` (resolved 5.12.2), SwiftyJSON `5.0.2`, SwiftyXMLParser `5.6.0`; NextcloudKitUI adds twostraws/CodeScanner `2.5.2`; tests use WeTransfer/Mocker.
* Install: `.package(url: "https://github.com/nextcloud/NextcloudKit.git", from: "7.6.5")` (README still says 2.0.0).
* Latest tag **7.6.5**; the iOS app itself tracks `branch = main`.
* Swift 6: `NextcloudKit.shared` exists only under `#if swift(<6.0)`; in Swift 6 language mode you instantiate `NextcloudKit()` yourself (public `init()`).

### 2.2 Setup / sessions

```swift
NextcloudKit.shared.setup(groupIdentifier: "group.…", delegate: NextcloudKitDelegate?, memoryCapacity: 30, diskCapacity: 500)
NextcloudKit.shared.appendSession(account:urlBase:user:userId:password:userAgent:
     httpMaximumConnectionsPerHost: 6, …InDownload: 6, …InUpload: 6, groupIdentifier:)
NextcloudKit.shared.updateSession(account:urlBase:user:userId:password:userAgent:)
NextcloudKit.configureLogger(logLevel:logDirectory:) / nkLog(...)
```
`NKSession` (`NKSession.swift`) contains per account: `sessionData` (Alamofire, protocol cache), `sessionDataNoCache`, background `URLSession`s `sessionDownloadBackground`, `sessionUploadBackground`, `sessionUploadBackgroundWWan` (**`allowsCellularAccess = false`, i.e. Wi-Fi-only**), lazy `…BackgroundExt` sessions for extensions (with `sharedContainerIdentifier = groupIdentifier`). Background session identifiers are fixed constants in `NKCommon`: `com.nextcloud.session.downloadbackground.<account>`, `com.nextcloud.session.uploadbackground.<account>`, `com.nextcloud.session.uploadbackgroundWWan.<account>`, `com.nextcloud.session.uploadextension`, `com.nextcloud.session.downloadextension` — not configurable; beware collisions if two apps share a container. Cookies per account via `HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "<user>@<urlBase>")`.

`NextcloudKitDelegate` (all optional): `authenticationChallenge`, `urlSessionDidFinishEvents(forBackgroundURLSession:)`, `networkReachabilityObserver`, `downloadProgress/uploadProgress`, `downloadComplete/uploadComplete(fileName:serverUrl:allHeaderFields:task:error:)`.

`NKRequestOptions` (`NKRequestOptions.swift`): `endpoint, version, customHeader, customUserAgent, contentType, e2eToken, timeout (60), taskDescription, createProperties: [NKProperties]?, removeProperties, checkInterceptor (true), paginate, paginateToken, paginateOffset, paginateCount, queue (.main)`. `createProperties`/`removeProperties` choose which DAV props are requested (enum `NKProperties` in `Models/NKProperties.swift` includes `metadataphotosexif`, `metadataphotosgps`, `metadataphotosoriginaldatetime`, `metadataphotoplace`, `metadataphotossize`, `metadatafileslivephoto`, `haspreview`, `uploadtime`, `creationtime`, `systemtags`, `hidden`, …).

### 2.3 Async/await

Convention (`AGENTS.md` of NextcloudKit): every completion API has an `…Async` twin returning a named tuple with `error: NKError` (never throws). Async-first/throwing exceptions: `getLoginFlowV2(serverUrl:) async throws`, `uploadChunkAsync(...) async throws`, `unifiedSearch(...) async`, Governance, Unified Sharing. Completion callbacks are delivered on `options.queue` (default main).

### 2.4 API inventory relevant to a Photos app

| Area | Functions (file) | Endpoint |
|---|---|---|
| Server status | `checkServer`, `getServerStatus(serverUrl:)` (`+API`) | `status.php` |
| Capabilities | `getCapabilities(account:)` / `getCapabilitiesAsync`; cache `NKCapabilities.shared.getCapabilities(for:)` (actor store) (`+Capabilities`) | `ocs/v1.php/cloud/capabilities` — parsed into `NKCapabilities.Capabilities` (server version, sharing, theming colors, `filesComments`, `filesUndelete`, `filesBigfilechunking`, `isLivePhotoServerAvailable` (= major ≥ 28), forbidden filename rules, ToS, …). **No photos/recognize/memories capability fields**; read raw JSON from `responseData` if needed. |
| PROPFIND | `readFileOrFolder(serverUrlFileName:depth:showHiddenFiles:includeHiddenFiles:requestBody: Data?, account:options:)` (`+WebDAV`) | any URL; default body from `NKProperties` |
| By fileId | `getFileFromFileId(fileId:…)` | SEARCH on fileid |
| SEARCH | `search(serverUrl:httpBody:showHiddenFiles:includeHiddenFiles:account:options:)` / `searchAsync`; `searchBodyRequest(serverUrl:requestBody: String,…)`; `searchLiteral(…)` | `SEARCH {urlBase}/remote.php/dav` |
| Media search | **no public helper**; `NKDataFileXML.getRequestBodySearchMedia(...)` is internal/unused. App builds its own body (see §3). |
| Favorites | `setFavorite(fileName:favorite:…)` (PROPPATCH `oc:favorite`), `listingFavorites(…)` (REPORT `oc:filter-files` on `/remote.php/dav/files/<user>`), `setFavoriteTag` (`+Tags`, `index.php/apps/files/api/v1/files`) | |
| Previews | `downloadPreview(fileId:width:1024 height:1024 etag:etagResource:crop:1 cropMode:"cover" forceIcon:0 mimeFallback:0 account:)` → `GET index.php/core/preview?fileId=&x=&y=&a=&mode=&forceIcon=&mimeFallback=&etag=` (etag in URL defeats URLCache after overwrite; optional `If-None-Match`); `downloadPreview(url:account:etag:)` for arbitrary preview URLs; `downloadTrashPreview(...)` → `index.php/apps/files_trashbin/preview`; `downloadAvatar(user:…)` → `index.php/avatar/<user>/<size>`. There is **no `downloadThumbnail`** any more. |
| Download | `download(serverUrlFileName:fileNameLocalPath:…)` (`+Download`), background `NKBackground.download(...)` (`NextcloudKitBackground.swift`), `getDirectDownload(fileId:)` (`ocs/v2.php/apps/dav/api/v1/direct`), `downloadContent(serverUrl:)` |
| Upload (single PUT) | `upload(serverUrlFileName:fileNameLocalPath:dateCreationFile:dateModificationFile:overwrite:autoMkcol:account:…)` / `uploadAsync` — headers `X-OC-CTime`, `X-OC-MTime` (epoch, only if >0), `Overwrite: true` if requested, `X-NC-WebDAV-Auto-Mkcol: 1` (server ≥ 33 creates missing parents) | |
| Background upload | `NKBackground(nkCommonInstance:).upload(serverUrlFileName:fileNameLocalPath:dateCreationFile:dateModificationFile:overwrite:autoMkcol:account:sessionIdentifier:)` → `URLSessionUploadTask` on the background session (Basic auth header built manually) | |
| Chunked upload | `uploadChunkAsync(directory:fileChunksOutputDirectory:fileName:destinationFileName:date:creationDate:serverUrl:chunkFolder:filesChunk:chunkSize:account:options:ifMatch:overwrite:chunkProgressHandler:uploadStart:uploadTaskHandler:uploadProgressHandler:uploaded:assembling:) async throws -> (account, file: NKFile?)` | **v2 chunking**: MKCOL `remote.php/dav/uploads/<userId>/<chunkFolder>` with `Destination` + `OC-Total-Length` headers; chunks PUT as `1`,`2`,…; final `MOVE <chunkFolder>/.file → Destination` (timeout 1–30 min scaled by size, optional `If-Match`); reads `OC-FileID`/`OC-ETag` from MOVE response. Disk preflight requires 3× file size. iOS app uses chunk size `100_000_000` bytes (`NCGlobal.chunkSize`). |
| Folders/moves | `createFolder`, `deleteFileOrFolder`, `moveFileOrFolder`, `copyFileOrFolder` | MKCOL/DELETE/MOVE/COPY |
| Live Photo link | `setLivephoto(serverUrlfileNamePath:livePhotoFile:account:)` (`+Livephoto`) | PROPPATCH `<nc:metadata-files-live-photo>` = fileId of the partner |
| **Albums (Photos app)** | `fetchAllAlbums(for:)` (PROPFIND `nc:last-photo nc:nbItems nc:location nc:dateRange nc:collaborators` on `remote.php/dav/photos/<userId>/albums/`), `createNewAlbum` (MKCOL), `renameAlbum` (MOVE), `deleteAlbum`, `fetchAlbumPhotos` (PROPFIND default props), `copyPhotoToAlbum` (COPY file → album), `deletePhotoFromAlbum(Async)`; model `NKPhotoAlbum` (`Models/NKPhotoAlbum.swift`, parses `dateRange` JSON `{start,end}`). Uses `Result<…, NKError>` completions. No shared-albums / collaborative-albums / places / people endpoints yet. |
| Sharing | `readShares(parameters: NKShareParameter)`, `searchSharees`, `createShare`, `updateShare`, `deleteShare` (`+Share`, `ocs/v2.php/apps/files_sharing/api/v1/shares[/<id>]`, `/sharees`), download limits (`+ShareDownloadLimit`), new **Unified Sharing** API (`+UnifiedSharing`) + SwiftUI `UnifiedShareListView`/`UnifiedShareEditView` in NextcloudKitUI | |
| Notifications | `getNotifications(idNotification:)` (`ocs/v2.php/apps/notifications/api/v2/notifications[/<id>]`), `setNotification(...)` (delete/action) | |
| Push | see §5 | |
| Activity | `getActivity(...)` (`ocs/v2.php/apps/activity/api/v2/activity/`) | |
| Unified search | `unifiedSearchProviders(...)` (`ocs/v2.php/search/providers`), `unifiedSearch(providerId:term:limit:cursor:…) async` (`…/providers/<id>/search?term=`) | |
| Comments | `getComments(fileId:)` (PROPFIND on `remote.php/dav/comments/files/<fileId>`), `putComments`, `updateComments`, `deleteComments`, `markAsReadComments` | |
| Trashbin | `listingTrash(filename:showHiddenFiles:account:)` (PROPFIND Depth 1 on `remote.php/dav/trashbin/<userId>/trash/`); restore = `moveFileOrFolder` to `…/trashbin/<userId>/restore/<name>`; empty = `deleteFileOrFolder` on `…/trash` (`iOSClient/Trash/NCTrash+Networking.swift`) | |
| System tags | `getTags`, `createTag`, `addTagToFile`, `removeTagFromFile`, `updateTagColor` (`+Tags`; `/remote.php/dav/systemtags/`, `/remote.php/dav/systemtags-relations/files/`) | |
| Misc | `getUserProfile` (`ocs/v2.php/cloud/user`), `getUserMetadata` (`cloud/users/<id>`), `generalWithEndpoint(_:account:method:)` (any OCS path, **no body**), Terms of Service, user status, recommended files, files lock, E2EE, Assistant, Client Integration | |

### 2.5 Arbitrary DAV requests (e.g. `/remote.php/dav/photos/...`)

* **PROPFIND with custom body on any URL: yes** — `readFileOrFolder(serverUrlFileName: "<urlBase>/remote.php/dav/photos/<user>/…", depth:, requestBody: customXML)`. Results are parsed by `NKDataFileXML.convertDataFile` into `[NKFile]` using generic `d:href` handling (works for non-`/files/` hrefs; `serverUrl`/`fileName` derived from href). Props outside the known set are dropped — if you need custom props (e.g. `nc:face-detections`, `nc:realpath`), parse `responseData.data` yourself.
* **SEARCH with custom body: yes** (`searchAsync(serverUrl:httpBody:…)`, always to `<urlBase>/remote.php/dav`).
* **REPORT / PROPPATCH / custom methods with body: no generic helper.** Options: (a) use the public `nkSession.sessionData` (Alamofire `Session`) from `NextcloudKit.shared.nkCommonInstance.nksessions.session(forAccount:)` with `nkCommonInstance.getStandardHeaders(account:options:contentType:accept:)` (public) and `HTTPMethod(rawValue: "REPORT")` — note `NKInterceptor` is internal, so 401 bookkeeping won't happen automatically; (b) add a `NextcloudKit+Photos.swift` extension upstream (the repo's documented convention).
* `generalWithEndpoint` cannot send a body.

---

## 3. Media view (NCMedia)

Files: `iOSClient/Media/NCMedia*.swift`, `NCMediaDataSource.swift`, `NCMediaNetwork.swift`, `iOSClient/Processor/NCMediaMetadataBackfillProcessor.swift`, `NCMediaPreviewBackfillProcessor.swift`, `iOSClient/NCImageCache.swift`, `iOSClient/Utility/NCUtility+Image.swift`. UIKit `UICollectionView` with custom `NCMediaLayout`, pinch-to-zoom columns, year/month sections, image/video filters, date picker.

### 3.1 Query

`NCMediaNetwork.searchMediaPage(path:firstDate:lastDate:account:paginate:limit:…)`:
* `SEARCH {urlBase}/remote.php/dav`, scope `<d:href>/files/<userId><mediaPath></d:href>`, `depth infinity`.
* Select props: `oc:id, oc:fileid, oc:permissions, d:getetag, d:getlastmodified, nc:upload_time, oc:size, nc:has-preview, nc:metadata-files-live-photo`.
* Where: `getcontenttype LIKE image/%` OR `video/%` AND `getlastmodified <= firstDate` AND `>= lastDate` (dates formatted `yyyy-MM-dd'T'HH:mm:ssZZZZZ`). **Date property = `d:getlastmodified`** (`NCGlobal.mediaPropOrder`), not EXIF date.
* Order: `getlastmodified DESC`, `displayname DESC`. `<d:limit><d:nresults>limit</d:nresults></d:limit>`.
* Limits: new-media window `max(visibleCells*3, 300)`; verification of the visible window `limit 1000` with **server pagination** (`X-NC-Paginate: true`, `X-NC-Paginate-Count: 200`, `X-NC-Paginate-Offset`, continuation `X-NC-Paginate-Token` from response); timeout 180 s.
* Strategy: on scroll, compute date window of visible cells; search "new" media above/below; then "verify" visible window and diff against Realm (`syncPlaceholderMetadatasAsync` → inserts/updates; deletion candidates are confirmed individually with `fileExists` (404) before deleting).
* `mediaPath` per account (`tableAccount.mediaPath`, default `""` = whole home; user can choose a folder).
* Background: `NCMediaMetadataBackfillProcessor` (BGProcessingTask) walks the whole archive backwards in batches (`pagesPerBatch = 4`), persists a cursor date, re-runs weekly; `NCMediaPreviewBackfillProcessor` pre-downloads previews.

### 3.2 Local cache

* **Realm** `tableMetadata` (same table as Files browsing) — media rows are "placeholder" metadata (`metadata.placeholder`, hydrated with `readFileAsync` on demand). Predicate (`NCMedia.getMediaPredicate`): `account == … AND serverUrl BEGINSWITH <home+mediaPath> AND hasPreview == true AND classFile IN (image, video) AND NOT status IN metadataStatusHideInView`; "images only" includes videos with `livePhotoFile != ''`. Sorted by `date`. Lightweight `NCCompactMetadata` objects feed the collection view.
* Realm file: `<AppGroup>/Library/Application Support/Nextcloud/nextcloud.realm`, `databaseSchemaVersion = 425` (`Brand/Database.swift`), file protection `completeUntilFirstUserAuthentication`.
* Album cache: Realm `tableAlbum…` (`NCManageDatabase+Albums.swift`: `primaryKey, account, href, lastPhotoId, itemCount, location, dateRange, collaborators, photosLoaded, photos: List<String>`).

### 3.3 Thumbnail cache

* Download: `downloadPreviewAsync(fileId:etag:account:)` with defaults **1024×1024, a=1, mode=cover**.
* Disk: `<AppGroup>/File Provider Storage/<userId-host path>/<ocId>/<etag>.1024.preview.jpg`, plus locally down-scaled `<etag>.512.preview.jpg` and `<etag>.256.preview.jpg` (JPEG quality 0.5/0.6/0.7) (`NCUtility.createImageFileFrom`, `createImageStandard`). Variant chosen by cell width (`NCGlobal.getSizeExtension(column:viewWidth:)`: ≤384 px→256, ≤768→512, else 1024).
* Memory: `NCImageCache` — `NSCache` with `countLimit 510`, key `"<ocId>-<etag>-<ext>"`, plus a sliding "media window" cache around the visible index; purged on memory warning and on entering background.
* Clean-up: `NCUtilityFileSystem.cleanUpAsync()` deletes cached files older than `cleanUpDay` (brand default 0 = never) except offline folders.

---

## 4. Auto upload

Key files: `iOSClient/Networking/NCAutoUpload.swift`, `iOSClient/Utility/NCCameraRoll.swift`, `iOSClient/Data/NCManageDatabase+AutoUpload.swift`, `NCManageDatabase+Account.swift`, `NCLocalDatabase*.swift`, `iOSClient/Settings/AutoUpload/*`, `iOSClient/Refresh/AppDelegate+AppRefresh.swift`, `iOSClient/Processor/AppDelegate+AppProcessing.swift`, `iOSClient/NCBackgroundLocationUploadManager.swift`, `BackgroundUploadExtension/*`.

### 4.1 Where settings live

Realm `tableAccount` (per account):

| Field | Meaning |
|---|---|
| `autoUploadStart` | on/off (only one account may be on) |
| `autoUploadSessionIdentifier` | UUID-ish token; changes on start/stop to invalidate in-flight scans |
| `autoUploadImage`, `autoUploadVideo` | media types |
| `autoUploadWWAnPhoto`, `autoUploadWWAnVideo` | **"Wi-Fi only"** (selects `sessionUploadBackgroundWWan`, which has `allowsCellularAccess = false`) |
| `autoUploadDirectory` | parent dir (default = user home `…/remote.php/dav/files/<userId>`) |
| `autoUploadFileName` | folder name (default **`NCBrandOptions.folderDefaultAutoUpload = "Photos"`**) → target `<home>/Photos` |
| `autoUploadCreateSubfolder`, `autoUploadSubfolderGranularity` | subfolders `yyyy` (0), `yyyy/MM` (1, default), `yyyy/MM/dd` (2) from asset creationDate (`createGranularityPath`) |
| `autoUploadAllPhotos` | whole library vs. from a date |
| `autoUploadSinceDate` | lower bound; **advances** as uploads are confirmed |
| `autoUploadForceReupload` | ignore local history ("Upload previously uploaded photos again") |

App-Group `UserDefaults` (`NCPreferences`, keys prefixed `Preferences_`): `formatCompatibility` (default **true** → HEIC/HEIF/RAW converted to JPEG), `livePhoto` (default **true**), `fileNameOriginal` (default false), `fileNameType` (default false), `fileNameMask` (default ""), `incrementalnumber`, `AlbumIds_<account>` (selected source albums, comma-separated `PHAssetCollection.localIdentifier`s; empty = Camera Roll `smartAlbumUserLibrary`), `removePhotoCameraRoll`, `location` (location trigger), `backgroundUploadExtensionEnabled`, `BackgroundUploadSuspended_<account>`, `BackgroundUploadFailedAssets_<account>`.

### 4.2 File naming (`NCUtilityFileSystem.createFileName(_:fileDate:fileType:notUseMask:)`)

* `fileNameOriginal == true` → original `PHAsset.originalFilename` (e.g. `IMG_1234.HEIC`).
* Default → `"<yy-MM-dd HH-mm-ss> <NNNN>.<ext>"`, e.g. `26-11-22 14-03-12 1234.heic`; `NNNN` = first digit run of the original name, else a persistent 4-digit counter (`incrementalNumber`). Date from `creationDate`, local time zone, `en_US_POSIX`. Extension lower-cased.
* `fileNameType == true` → prefix localised `"Photo "` / `"Video "` (`_photo_`, `_video_`), e.g. `Photo 26-11-22 14-03-12 1234.jpg`.
* Custom `fileNameMask` with tokens `DD, MMM, MM, YYYY, YY, HH, hh, mm, ss, ampm` (+ number suffix).
* With JPEG conversion, extension becomes `.jpg` (`NCCameraRoll.outputFileName`). Live-photo companion = same basename + `.mov`.
* Manual (non-auto) uploads avoid collisions by appending ` 1`, ` 2`, … (`createFileName(_:serverUrl:account:)`).

### 4.3 Discovery & duplicate tracking

`NCAutoUpload.initAutoUpload()` / `getCameraRollAssets(...)`:
1. `PHFetchOptions` predicate `mediaType == image|video` AND (`creationDate >= autoUploadSinceDate` unless `autoUploadAllPhotos`), sorted by `creationDate` asc; over selected albums or the Camera Roll (deduped with `OrderedSet`).
2. For each asset compute file name; skip if in **`fetchAutoUploadFileNamesAsync(account:autoUploadServerUrlBase:)`** → `(queued: Set<String>, uploaded: Set<String>)`, built from Realm `tableMetadata` (queued) and **`tableAutoUploadTransfer`** (uploaded history).
3. Create a `tableMetadata` "seed" per asset (`assetLocalIdentifier`, `sessionSelector = "uploadAutoUpload"`, `status = WaitUpload`, `session = uploadbackground[WWan]`, `livePhotoFile = <base>.mov`), plus folder-create seeds unless server ≥ 33 (`X-NC-WebDAV-Auto-Mkcol`).

`tableAutoUploadTransfer` (Realm): `primaryKey = account + serverUrlBase + fileName`, `account`, `serverUrlBase`, `fileName`, **`assetLocalIdentifier`**, `date`, `uploadSessionIdentifier`. Also `fetchAutoUploadAssetIdentifiersAsync(...)` returns `(tracked, uploaded)` sets of **PHAsset localIdentifiers**.

GRDB SQLite `<AppGroup>/Library/Application Support/Nextcloud/nextcloud.sqlite` (`NCLocalDatabase`, migrations in `NCLocalDatabaseMigrator.swift`):
* `photoLibraryAsset(account, assetLocalIdentifier, photoUploaded BOOL?, videoUploaded BOOL?, creationDate)` PK `(account, assetLocalIdentifier)` — per-component upload state (nil = component doesn't exist), used for "remove from camera roll after upload".
* `autoUploadResource(account, serverUrlBase, assetLocalIdentifier, uploadSessionIdentifier, classFile, fileName, uploaded, creationDate, transferIdentifier)` PK `(account, serverUrlBase, assetLocalIdentifier, uploadSessionIdentifier, classFile)` — background-upload-extension history.

Before uploading (`autoUploadBackgroundSync`): unless `autoUploadForceReupload`, `NCNetworking.fileExists(serverUrlFileName:)` — **if the target name already exists on the server it is treated as uploaded and skipped** (`completeExistingAutoUploadAsync`; no content/hash comparison). Live-photo `.mov` checked separately. With force-reupload, uploads go out with `Overwrite: true` → existing server files may be overwritten. No checksum-based dedup.

### 4.4 Extraction, HEIC/JPEG, Live Photos (`NCCameraRoll`)

* Images: `PHImageManager.requestImageDataAndOrientation` (`isNetworkAccessAllowed`, high quality, `.current` version — i.e. **edited rendition**; `.original` for RAW). If `shouldConvertToJPEG(ext, nativeFormat: !formatCompatibility)` (HEIC/HEIF/RAW) → `CIContext().jpegRepresentation(… quality 0.85)`.
* Videos: `AVAssetExportSession` passthrough.
* **Live Photos** (if `livePhoto` pref and `mediaSubtypes.contains(.photoLive)`): uploads the still **and** a `.mov` from `PHAssetResource` `.fullSizePairedVideo` (fallback `.pairedVideo`) via `PHAssetResourceManager.writeData`. Then `NCNetworking.setLivePhoto(account:)` cross-links both files with `setLivephotoAsync` (PROPPATCH `nc:metadata-files-live-photo` = partner fileId) — tracked in Realm `tableLivePhoto(account, serverUrlFileNameNoExt, serverUrlFileNameImage/Video, fileIdImage/Video, errorCount)`. Server considered capable when major ≥ 28.
* Files > 100 MB (`chunkSize = 100_000_000`) go through `uploadChunkAsync` on the foreground `sessionUpload`; others via background `URLSession` upload tasks (`NKBackground.upload`).

### 4.5 Background execution

* `BGTaskSchedulerPermittedIdentifiers`: **`com.nextcloud.refreshTask`** (`BGAppRefreshTaskRequest`, earliest +60 s) and **`com.nextcloud.processingTask`** (`BGProcessingTaskRequest`, +5 min, no network/power requirement). Both call `NCAutoUpload.shared.autoUploadBackgroundSync()` (processing task also does media backfill/previews).
* `UIBackgroundModes`: `audio, fetch, processing, remote-notification, location`.
* Background `URLSession` uploads (`sessionSendsLaunchEvents = true`, `isDiscretionary = false`); `application(_:handleEventsForBackgroundURLSession:completionHandler:)` stores the handler, called from `urlSessionDidFinishEvents`.
* **Location trigger**: `NCBackgroundLocationUploadManager` — `startMonitoringSignificantLocationChanges()` (needs "Always" location permission); on update while in background → `autoUploadBackgroundSync()`.
* `applicationWillTerminate` posts a local notification "_keep_running_" reminding the user to keep the app alive.
* **iOS 27 PhotoKit background upload extension** (`BackgroundUploadExtension/`, target bundle `it.twsweb.Nextcloud.BackgroundUploadExtension`, deployment target 27.0, `EXExtensionPointIdentifier = com.apple.photos.background-upload`):
  * `@main final class BackgroundUploadExtension: PHBackgroundResourceUploadJobExtension` with `processJobs() async -> PHBackgroundResourceUploadProcessingResult`.
  * Host enables via `PHPhotoLibrary.shared().enableUploadJobExtension(with: PHAssetResourceUploadJobOptions)` / `setUploadJobExtensionOptions` (`NCBackgroundUploadExtensionManager.ensureEnabled()`); gated by `.authorized` photo access, user opt-in (`backgroundUploadExtensionEnabled`, Debug/TestFlight only), auto-upload account, **server ≥ NC 35**.
  * Jobs: `PHAssetResourceUploadJobChangeRequest.creationRequestForJob(destination: URLRequest, resource: PHAssetResource)`; job lifecycle via `PHAssetResourceUploadJob.fetchJobs(action: .process/.retry/.acknowledge)`, max `min(PHAssetResourceUploadJob.jobLimit, 20)` slots.
  * Destination request (`BackgroundUploadExtension+Destination.swift`): `PUT <serverUrlFileName>`, Basic auth, UA, `Content-Type: application/octet-stream`, **`X-NC-WebDAV-Auto-Mkcol: 1`**, **`X-NC-PhotoKit-Upload: 1`**, `X-OC-CTime`/`X-OC-MTime`, `allowsCellularAccess = !wifiOnly`.
  * Uploads the **original resource bytes** (`.fullSizePhoto`/`.photo`, `.fullSizeVideo`/`.video`, paired video) — no JPEG conversion; resources > 100 MB are handed back to the host app for chunked upload. Success is confirmed by a valid `oc-fileid` response header (even if PhotoKit reports failure after 204). Max 3 attempts; 3 consecutive distinct-asset failures or auth failure suspend the account (`BackgroundUploadSuspended_<account>`). Documented in `BackgroundUploadExtension/README.md` + `diagram.png`.

### 4.6 What a second app (same Apple team) could read

Requires: signed by team **NKUJUXUJ3B** and entitlements listing the same groups. App Groups/keychain groups cannot be shared across teams.

| Resource | Location | Content | Caveats |
|---|---|---|---|
| Accounts list (designed for cross-app use) | App Group **`group.com.nextcloud.apps`** → `Library/Application Support/NextcloudAccounts/accounts.json` + `<user>-<host>-<user>.png` | `{"apps": {"nextcloud": [{"url","user","name"}], "<otherScheme>": [...]}}` written by `NKShareAccounts.putShareAccounts(at:app:dataAccounts:)`; read with `getShareAccount(at:application:)` which keeps only apps whose `<scheme>://` `canOpenURL` (reader needs `LSApplicationQueriesSchemes` incl. `nextcloud`) | **No passwords** — only server/user to prefill login. iOS-only helper. |
| App password | Keychain group `NKUJUXUJ3B.it.twsweb.Crypto-Cloud`, service `com.nextcloud.keychain`, account key `password<user> <urlBase>` | the Files app's app password | Sharing a token between two apps means revocation/wipe in one breaks the other; better to do own Login Flow v2 (pre-filled from accounts.json). |
| Realm DB | App Group `group.it.twsweb.Crypto-Cloud` → `Library/Application Support/Nextcloud/nextcloud.realm` (schema 425) | `tableAccount` (auto-upload settings incl. target folder), `tableAutoUploadTransfer` (uploaded file names + `assetLocalIdentifier`), `tableMetadata` (queued seeds with `assetLocalIdentifier`), `tableLivePhoto` | Opening it from another app with a different/partial model set and the same `schemaVersion` triggers Realm schema validation/migration and can corrupt or block Files. Only safe with an exact copy of Files' models and `readOnly: true`, and it breaks whenever Files bumps `databaseSchemaVersion`. **Not recommended.** |
| GRDB SQLite | same group, `Library/Application Support/Nextcloud/nextcloud.sqlite` (WAL) | `photoLibraryAsset`, `autoUploadResource` — keyed by PHAsset `localIdentifier` | Plain SQLite, can be opened read-only; but only populated by newer code paths (remove-from-camera-roll, PhotoKit extension) — not the full legacy history. |
| Group UserDefaults | suite `group.it.twsweb.Crypto-Cloud`, keys `Preferences_*` | auto-upload prefs (`fileNameType`, `formatCompatibility`, `AlbumIds_<account>` …) and NextcloudKit's `Unauthorized`/`Unavailable`/`ToS` arrays | If the Photos app uses NextcloudKit with **the same `groupIdentifier`**, a 401 recorded by Files blocks Photos' requests for the same account string (and vice versa) via `NKInterceptor`. Use a separate group for NextcloudKit's `setup(groupIdentifier:)`. |
| Pinned certs | same group, `Library/Application Support/Certificates/<host>.der` | user-accepted server certs | reusable trust decisions |

PHAsset `localIdentifier`s are stable per device/library and identical across apps on the same device, so a localIdentifier set from Files can be intersected with the Photos app's own PhotoKit fetch. For a robust "already on server" check independent of Files, query the server (e.g. SEARCH in the auto-upload folder by name/size/mtime, or `oc:checksums` when available).

---

## 5. Push notifications

Files: `iOSClient/PushNotification/NCPushNotification.swift`, `NCPushNotificationEncryption.{h,m}` (OpenSSL), `Notification Service Extension/NotificationService.swift`, NextcloudKit `NextcloudKit+PushNotification.swift`.

1. APNs token → hex upper-case string (`stringWithDeviceToken:`), stored in `Preferences_deviceTokenPushNotification`.
2. Per account, if no key pair in keychain: `generatePushNotificationsKeyPair` = **RSA 2048** (`EVP_PKEY_keygen`), public key PEM (`PEM_write_bio_PUBKEY`), private key PKCS#8 PEM; stored as `PushPublicKey<account>`/`PushPrivateKey<account>`.
3. `subscribingPushNotification(serverUrl:pushTokenHash:devicePublicKey:proxyServerUrl:account:)` → `POST ocs/v2.php/apps/notifications/api/v2/push` form params `pushTokenHash = SHA512(hex token)`, `devicePublicKey = <PEM>`, `proxyServer = <proxy URL>`; returns `deviceIdentifier`, `signature`, `publicKey` (server's user key).
4. `subscribingPushProxy(proxyServerUrl:pushToken:deviceIdentifier:signature:publicKey:account:options:)` → `POST <proxy>/devices?format=json` form `pushToken, deviceIdentifier, deviceIdentifierSignature, userPublicKey`, header only `User-Agent` (`"<UA>  (Strict VoIP)"`).
5. Proxy URL: `NCBrandOptions.pushNotificationServerProxy`, default **`https://push-notifications.nextcloud.com`** when brand == "Nextcloud".
6. Unsubscribe: `DELETE ocs/v2.php/apps/notifications/api/v2/push` and `DELETE <proxy>/devices` (params `deviceIdentifier, deviceIdentifierSignature, userPublicKey`).
7. Receiving: payload `userInfo["subject"]` = base64 RSA-encrypted JSON; decrypted with each account's private key, **OAEP first, then PKCS#1 v1.5 fallback**. JSON keys used: `subject`, `nid`, `app`, `delete`, `delete-all`. The Notification Service Extension sets the body, stores JSON (+`account`) under group-defaults key `NOTIFICATION_DATA`, then fetches full text with `getNotificationsAsync(idNotification:)` (20 s timeout). `delete`/`delete-all` handled in `application(_:didReceiveRemoteNotification:)` by removing delivered notifications.
8. Important for a new app: the Nextcloud push proxy delivers to APNs with credentials for **known Nextcloud apps' bundle IDs/topics**; a new bundle ID needs either its own proxy instance (nextcloud/push-notifications style) or explicit support from Nextcloud GmbH. Same team does not automatically suffice.

---

## 6. Bundle IDs, groups, extensions

### 6.1 Identifiers (`Nextcloud.xcodeproj/project.pbxproj`, `Brand/*.entitlements`)

* Team: **`NKUJUXUJ3B`**. App Store id 1125420102.
* Main app: `it.twsweb.Nextcloud` (`it.twsweb.$(PRODUCT_NAME:rfc1034identifier)`), URL scheme **`nextcloud://`** (`CFBundleURLName it.twsweb.Nextcloud`), queries `nextcloudtalk`, `nextcloudnotes`. iPhone/iPad; "Designed for iPad" on Mac and visionOS enabled (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES`, `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = YES`), no Catalyst. Deployment iOS 17.0.
* App Groups: **`group.it.twsweb.Crypto-Cloud`** (`NCBrandOptions.capabilitiesGroup`; all targets) and **`group.com.nextcloud.apps`** (`capabilitiesGroupApps`; main app only, shared with Talk/Notes for accounts.json).
* Keychain access group: **`$(AppIdentifierPrefix)it.twsweb.Crypto-Cloud`** (all targets).
* Main app entitlements also: `aps-environment`, camera, microphone, location, photos-library, network client.

### 6.2 Extensions

| Target | Bundle id | Extension point | Purpose |
|---|---|---|---|
| Share | `it.twsweb.Nextcloud.Share` | `com.apple.share-services` (`NCShareEntryController`, SwiftUI UI in `Share/View`) | upload from share sheet |
| File Provider Extension | `it.twsweb.Nextcloud.File-Provider-Extension` | `com.apple.fileprovider-nonui` (document group `group.it.twsweb.Crypto-Cloud`) | Files.app integration (domains per account) |
| File Provider Extension UI | `it.twsweb.Nextcloud.File-Provider-Extension-UI` | `com.apple.fileprovider-actionsui` | custom actions |
| Notification Service Extension | `it.twsweb.Nextcloud.Notification-Service-Extension` | `com.apple.usernotifications.service` | decrypt push |
| Widget | `it.twsweb.Nextcloud.Widget` | `com.apple.widgetkit-extension` | dashboard/files/lockscreen widgets |
| WidgetDashboardIntentHandler | `it.twsweb.Nextcloud.WidgetDashboardIntentHandler` | `com.apple.intents-service` | widget configuration |
| Action Assistant | `it.twsweb.Nextcloud.Action-Assistant` | `com.apple.ui-services` | send text to Assistant |
| BackgroundUploadExtension | `it.twsweb.Nextcloud.BackgroundUploadExtension` | `com.apple.photos.background-upload` | iOS 27 PhotoKit background upload |

### 6.3 How they share data

All targets: `NextcloudKit.shared.setup(groupIdentifier: capabilitiesGroup)` + `appendSession(...)` with password read from the shared keychain; Realm opened from the App Group (`NCManageDatabase.openRealmAppex()` for extensions); GRDB in the same folder; preferences in group `UserDefaults`; logs in `<AppGroup>/Logs`; previews/files in `<AppGroup>/File Provider Storage`; extensions compiled with `EXTENSION` flag (relaxed TLS handling!).

### 6.4 Notes for the Photos app

* Use your own App Group and keychain group for your own state; if you are on team NKUJUXUJ3B and want to read Files' data, add `group.it.twsweb.Crypto-Cloud` / `group.com.nextcloud.apps` **as additional** groups, open foreign stores read-only, and never call `NextcloudKit.setup(groupIdentifier:)` with Files' group (interceptor coupling, shared background-session container).
* To avoid double uploads when both apps auto-upload: coordinate via server existence checks (same target folder + same naming scheme) or by reading Files' `tableAutoUploadTransfer`/`autoUploadResource` localIdentifiers; also note only one PhotoKit background-upload extension per app — two apps may each register one and would both upload.

---

## 7. Licence and branding

* Both repos: **GPL-3.0-or-later** (`LICENSE.txt`) **with Apple App Store exception** (`COPYING.iOS`: copyright holders won't pursue violations resulting solely from App Store ToS conflicts). REUSE-compliant, SPDX headers mandatory, DCO sign-off, no CLA. Any app linking NextcloudKit (GPL, not LGPL) must itself be GPL-compatible and publish source.
* Trademarks: app icons, logo image sets, `AppIcon.icon`, NextcloudKit logo are `LicenseRef-NextcloudTrademarks` (`LICENSES/LicenseRef-NextcloudTrademarks.txt`, https://nextcloud.com/trademarks/) — not reusable without permission.
* **Brand mechanism** (`Brand/` folder, GPL): `Brand/NCBrand.swift`
  * `NCBrandOptions` — `brand`, `brandUserAgent` (UA suffix), copyright strings, `loginBaseUrl`, `pushNotificationServerProxy`, `linkLoginHost`, `linkloginPreferredProviders`, `webLoginAutenticationProtocol = "nc://"`, `privacy`, `sourceCode`, `mobileconfig`, `appStoreUrl`, `folderDefaultAutoUpload = "Photos"`, `capabilitiesGroup`, `capabilitiesGroupApps`, `use_AppConfig`, `use_themingColor`, MDM `disable_*` / `enforce_*` flags, `enforce_servers: [(name,url)]`, `cleanUpDay`, connection limits (8 per host), `numMaximumProcess = 20`, passcode limits; `isServerVersion(_:greaterOrEqualTo:)` with `NextcloudVersion` (v18…v35).
  * `NCBrandColor` — default customer color `#0082C9`, server theming via capabilities (`themingColor`, `themingColorElement`, `themingColorText`) with lighter/darker adjustments (`settingThemingColor(account:capabilities:)`), generated user colors.
  * `Brand/Database.swift` (DB name, schema version), all `Info.plist`s/entitlements, `Custom.xcassets`, `LaunchScreen.storyboard`, intro screens.
  * Worth reusing for Photos: the `NCBrandOptions` pattern (single overridable options object + AppConfig override + server theming), `NextcloudVersion` gating, MDM keys compatible with Files (so admins can configure both alike). NextcloudKitUI's `ServerAddressView`/`OnboardingView` take a `brandImage` and `backgroundColor` for white-labelling.

---

## 8. Recommendations distilled for the spec

1. Depend on `NextcloudKit` ≥ 7.6.5 (+ optionally `NextcloudKitUI` for login/onboarding/account button/unified sharing). Wrap it behind your own async service layer; supply your own `NextcloudKitDelegate` for trust/mTLS.
2. Login: Login Flow v2 via `ASWebAuthenticationSession`/`WebAuthenticationSession` (ephemeral, callback scheme `nc`), poll every 1 s (404 = pending), WKWebView fallback for mTLS; support `nc://login/` and `nc://onetime-login/` QR codes; prefill from `group.com.nextcloud.apps` accounts.json; store app password in your own keychain group; on logout call `deleteAppPassword`; on 401 run wipe check (`index.php/core/wipe/check` → `…/wipe/success`).
3. Timeline: SEARCH as in `NCMediaNetwork` (consider ordering by `nc:metadata-photos-original_date_time` / Photos app DAV endpoints instead of `getlastmodified`), pagination headers `X-NC-Paginate*`, previews via `index.php/core/preview?fileId=…&x=&y=&a=1&mode=cover&etag=` and an on-disk cache keyed `(ocId, etag, size)`.
4. Albums/places/people: use `NextcloudKit+Albums` for albums; for anything else under `/remote.php/dav/photos/<user>/…` use `readFileOrFolder(requestBody:)` or raw `sessionData` requests (REPORT not wrapped).
5. Auto upload: replicate the configurable naming scheme (default `yy-MM-dd HH-mm-ss NNNN.ext`, optional `Photo `/`Video ` prefix, original-name option, mask), target `<home>/Photos[/yyyy/MM]`, JPEG-compat toggle (default on in Files), Live Photo `.mov` + `nc:metadata-files-live-photo` linking, track by PHAsset localIdentifier, server-existence check before upload, `X-OC-CTime/MTime`, `X-NC-WebDAV-Auto-Mkcol` on NC ≥ 33, chunking > 100 MB; on iOS 27+ prefer the PhotoKit background-upload extension (`X-NC-PhotoKit-Upload: 1`, confirm via `OC-FileID`).
6. Push: requires a push proxy that knows the new app's APNs topic — plan this with Nextcloud GmbH or self-host.
