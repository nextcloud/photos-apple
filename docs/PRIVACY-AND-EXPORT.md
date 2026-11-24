# Privacy manifest, App Transport Security and export compliance

The reasoning behind three declarations the App Store asks for. Keep it in step with the code: when a new use of one
of these APIs appears, update the manifests and this file in the same change.

## Privacy manifests (`PrivacyInfo.xcprivacy`)

Where: one in the app (`App/Resources`), one in each extension (`Extensions/*`), and one in each package target that
uses a required-reason API (`Packages/PhotosKit/Sources/<target>/Resources`, bundled as a package resource). The
package's code is linked statically into the app and the extensions, so their manifests repeat what the linked modules
need.

**Tracking:** none. No tracking domains, no analytics, no third-party SDK besides GRDB (which ships its own manifest).

**Required-reason APIs**

| API category | Reason | Where the code uses it |
|---|---|---|
| User defaults | `CA92.1` (the app's own defaults) | Settings: `@AppStorage` in `PhotosAppUI`; `PushNotifications.enabledKey`, offline Wi-Fi switch, `ContentLabeling.enabledKey`, `SharedAlbumNotifications.enabledKey` in `PhotosCore`; cache limits in `PhotosMedia` |
| User defaults | `1C8F.1` (defaults of an App Group of the same developer) | `PhotosBackup/FilesAppLedger`: reads the auto-upload options of the Nextcloud Files app from `group.com.nextcloud.apps`, to avoid uploading its photos twice |
| File timestamps | `C617.1` (files in the app's containers) | `PhotosMedia`: `PreviewCache` and `ImagePipeline` set and read the modification time of cached files to trim the least recently used |
| File timestamps | `3B52.1` (files the user gave the app access to) | `PhotosNetworking/Uploader.fingerprint`: size and modification time of a file being uploaded identify an interrupted upload that can be continued |
| System boot time | `35F9.1` (time between events inside the app) | `PhotosAppUI/Grid/PhotoGrid+AppKit`: `ProcessInfo.systemUptime` as the timestamp of a synthesized key event, macOS only |

Not used (checked with grep): disk space APIs, active keyboards.

**Collected data**

The photos, metadata and credentials go to the Nextcloud server the user chose; the developer of the app never
receives them, so they are not "collected" in Apple's sense.

On-device labels (Settings › Search, off by default; SPEC SR-7): Vision's classifier runs on previews already in the
cache, on the device, and its words ("dog", "beach") are stored only in the account's database on the device, for
search. They are never uploaded, not to the user's server either, and turning the switch off deletes them. Tag and
people names that the search index also holds come from the user's own server. Shared-album notifications are local
notifications the app posts itself; nothing is registered for them anywhere.

One thing does reach a service run by Nextcloud GmbH: for push notifications the app registers its **APNs device
token**, a per-account public key and the device identifier issued by the user's server with
`push-notifications.nextcloud.com` (`PhotosCore/PushNotifications.register`), as the other Nextcloud apps do. The
manifests of the app and of `PhotosCore` declare it as *Device ID*, purpose *App Functionality*, not linked to the
user's identity, not used for tracking.

> To decide before submission: the App Store privacy label ("nutrition label") must say the same. If Nextcloud's
> position for its other apps is that the push token is not collected data, remove the entry from both manifests
> instead; the two must not contradict each other.

## App Transport Security: `NSAllowsArbitraryLoads`

`project.yml` sets `NSAppTransportSecurity › NSAllowsArbitraryLoads = true` for the app. SPEC §8 asked for per-host
exceptions. Those are not possible here: `NSExceptionDomains` are fixed in the Info.plist at build time, and the hosts
this app talks to are typed in by the user at run time.

Why the exception is needed at all:

- **Plain `http://` servers.** Nextcloud is self-hosted; servers in a home or lab network without a certificate are
  common. `NSAllowsLocalNetworking` alone would cover `.local` names and IP addresses, but not a host name in a local
  DNS zone or a server reached through a VPN.
- **TLS setups that ATS rejects** although the user trusts them: self-signed or private-CA certificates (the app
  evaluates trust itself and asks the user, `PhotosNetworking/HTTP/TrustStore`), and older servers without forward
  secrecy or TLS 1.2.

What the app does instead of relying on ATS:

- Logging in to an `http://` server shows a warning that the password and all photos would travel unencrypted and
  needs an explicit "Log in anyway" (not for `localhost`). A server entered with `https://` that redirects to
  `http://` is refused.
- A certificate the system does not trust is shown to the user (fingerprint) and only used after approval; the
  approval is stored per host and a changed certificate asks again.
- The push proxy and every other fixed endpoint are `https://`.

**App Review note** (for the "App Review Information" field):

> Nextcloud Photos connects to a Nextcloud server that the user operates or chooses, at an address the user enters.
> Because these hosts are not known at build time, per-domain ATS exceptions cannot be used. Many self-hosted servers
> use plain HTTP on a local network or certificates from a private CA, so the app sets NSAllowsArbitraryLoads. The app
> warns before every login over unencrypted HTTP and asks the user before trusting a certificate the system does not
> trust. All endpoints operated by Nextcloud are HTTPS.

## Export compliance: `ITSAppUsesNonExemptEncryption = false`

The app uses encryption, but only kinds that App Store Connect treats as exempt from export documentation
(encryption provided by the operating system, and standard algorithms used through it). This is the technical basis
for that answer, not legal advice; whoever answers the export questions for the developer account should confirm it.

| Use | Implementation |
|---|---|
| HTTPS to the server and to the push proxy | `URLSession` (the operating system's TLS) |
| Secrets (app passwords, push keys) | Keychain Services |
| Files at rest | Data Protection of the operating system |
| Push notifications: an RSA-2048 key pair per account; the server encrypts the notification's subject with the public key, the app decrypts it and checks nothing else | `Security` framework: `SecKeyCreateRandomKey`, `SecKeyCreateDecryptedData` with `rsaEncryptionOAEPSHA1` / `rsaEncryptionPKCS1` (`PhotosCore/PushNotifications`) |
| Hashes: push token hash (SHA-512), upload checksums and cache keys (SHA-256), certificate fingerprints | `CryptoKit` |

There is no encryption algorithm of the app's own, none that is not a published standard, and all of it is the
implementation that ships with the operating system. The push-payload decryption is the same scheme the Nextcloud Files
and Talk apps use. That is why the key is `false` and no export compliance documentation is uploaded.

Review this section when one of these is added: end-to-end encryption of files, a cryptography library bundled with
the app, or encryption with an algorithm that is not a published standard. Distribution in France additionally asks
for a declaration for apps that use encryption; exempt uses as above normally fall under its exemption, but that is a
question for whoever holds the developer account.
