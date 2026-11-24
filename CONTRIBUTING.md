<!--
  - SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
  - SPDX-License-Identifier: MIT
-->
# Contributing to Nextcloud Photos for Apple platforms

Thank you for helping. This file covers what is specific to this repository; the
[contribution guidelines of the Nextcloud organization](https://github.com/nextcloud/.github/blob/master/CONTRIBUTING.md)
apply as well.

## Issues

- Search the existing issues first. Questions about using Nextcloud belong in the [forum](https://help.nextcloud.com/).
- **Security:** do not open an issue; see [SECURITY.md](SECURITY.md).
- Say which device, OS version, app version and build, and which Nextcloud and Photos versions the server runs
  (Settings › Server in the app shows them).

## Pull requests

- Against `main`, one feature or fix per pull request, with a
  [Conventional Commits](https://www.conventionalcommits.org/) subject (`fix(backup): …`, `feat(viewer): …`).
- Changed or new logic comes with unit tests; a bug fix with a test that fails without it wherever that is possible.
- When behaviour changes, update `docs/SPEC.md` (the target) and `docs/STATUS.md` (the state) in the same pull request.
- User-visible text goes through the string catalogs, with a comment for translators
  ([docs/LOCALIZATION.md](docs/LOCALIZATION.md)). Translations are made on
  [Transifex](https://explore.transifex.com/nextcloud/), not in pull requests.

### Sign your work

Nextcloud uses the Developer Certificate of Origin (DCO). Read the
[certificate](https://github.com/nextcloud/server/blob/master/contribute/developer-certificate-of-origin); if you can
certify it, add this line to every commit message, with your real name:

```
Signed-off-by: Random J Developer <random@developer.example.org>
```

`git commit -s` adds it for you.

### AI-assisted contributions

Contributions made with the help of AI tools are welcome under Nextcloud's
[AI Contribution Policy](https://github.com/nextcloud/.github/blob/master/AI_POLICY.md). In short: you are the author
of everything you submit and answer for it; declare the AI use in the pull request description and add an
`Assisted-by: AGENT_NAME:MODEL_VERSION` trailer to each affected commit; review, clean up and run the code yourself
before you submit it; an AI agent never adds `Signed-off-by` and never opens issues or pull requests on its own.

### Licence headers

The repository is [REUSE](https://reuse.software/) compliant and checked in CI. Every new source file starts with

```
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT
```

(with the comment signs of its language). Files that cannot carry a comment are covered by `REUSE.toml`.

## Build

Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate            # writes NextcloudPhotos.xcodeproj and the Info.plists from project.yml
open NextcloudPhotos.xcodeproj
```

`project.yml` is the place to change targets, build settings and Info.plist keys; the Xcode project and the
`Info.plist` files are generated and not checked in. To run on your devices, set your own team and bundle id in
`Config/Local.xcconfig` (README, "Signing with your own Apple ID").

## Test

```sh
cd Packages/PhotosKit
swift test                                                                 # unit tests, needs macOS 27
xcodebuild test -scheme PhotosKit-Package -destination 'platform=macOS'    # what CI runs
```

Integration tests against a server, UI tests and the device test plan: [docs/TESTING.md](docs/TESTING.md).

## Lint

```sh
xcrun swift-format lint --strict --configuration .swift-format $(git ls-files '*.swift')
xcrun swift-format format --in-place --configuration .swift-format <files>   # to fix
```

CI uses the swift-format of Xcode 27.2; other versions may format differently.

## What CI checks

Lint, REUSE, unit tests on macOS and in an iOS simulator, Debug builds for iOS, macOS and visionOS, and an unsigned
Release archive for each. Nightly: performance tests and the integration tests against a fresh Nextcloud.

## Where things are

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the modules and the data flow, [docs/SPEC.md](docs/SPEC.md) for what
the app is meant to do, [docs/STATUS.md](docs/STATUS.md) for what it does today.
