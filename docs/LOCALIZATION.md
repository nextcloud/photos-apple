# Localization

All user-visible text is in Xcode string catalogs (`.xcstrings`), English only so far:

| Catalog | Text of |
|---|---|
| `Packages/PhotosKit/Sources/PhotosAppUI/Resources/Localizable.xcstrings` | the screens (by far the largest) |
| `Packages/PhotosKit/Sources/PhotosCore/Resources/Localizable.xcstrings` | backup results, transfers |
| `Packages/PhotosKit/Sources/PhotosBackup/Resources/Localizable.xcstrings` | backup states, file name prefixes |
| `Packages/PhotosKit/Sources/PhotosDomain/Resources/Localizable.xcstrings` | day headers, search suggestions |
| `Packages/PhotosKit/Sources/PhotosNetworking/Resources/Localizable.xcstrings` | error messages |
| `App/Resources/Localizable.xcstrings` | App Intents (Shortcuts, Siri) |
| `App/Resources/AppShortcuts.xcstrings` | Siri phrases |
| `App/Resources/InfoPlist.xcstrings` | permission texts |
| `Extensions/Widgets/Localizable.xcstrings` | widgets |

## Rules for strings

- In the package: `String(localized: "…", bundle: .module)` or `Text("…", bundle: .module)`.
- Every key has a **comment for translators**: where the text appears, what the placeholders are, what must not be
  translated. Xcode writes one for many keys by itself; for the others write it in the code
  (`comment:`) or in the catalog. `scripts/xcstrings-comments.py --check <catalog>` lists keys without one;
  `scripts/xcstrings-comments.py <comments> <catalog>` inserts comments from a JSON file or from another version of the catalog and changes nothing else
  (useful after a merge: `git show <branch>:<catalog> > /tmp/theirs.xcstrings`, then run it with that file).
- Native wording per platform ("passcode" on iPhone, "password" on the Mac; title case in Mac menus) means separate
  keys, not one key with a compromise.

## Transifex: proposed setup, to be decided with the localization team

Nextcloud translates on [Transifex](https://explore.transifex.com/nextcloud/); a bot (`nextcloud/docker-ci`,
`translations/`) syncs each repository every night. There is **no `.tx/config` in this repository yet** on purpose:
the resources have to be created in Transifex and the bot needs a handler for this repository first, and both are
decisions of the localization team. This is the proposal.

How Nextcloud's other Apple projects do it (looked up in November 2026):

| Project | Format | Sync |
|---|---|---|
| `nextcloud/ios`, `nextcloud/talk-ios`, `nextcloud/notes-ios` | `.strings` / `.stringsdict`, one file per language (`type = STRINGS`) | bot |
| `nextcloud/desktop` (macOS File Provider extensions) | string catalogs, `type = XCSTRINGS`, `file_filter` = the catalog itself | by hand, with a sanitizer tool, because a push replaces all translations on Transifex |
| `nextcloud/NextcloudKit` | string catalogs, `type = XCSTRINGS`, one resource per catalog, pulled into `translations/<resource>/<lang>.xcstrings` | bot, with its own handler (`translations/handleNextcloudKitTranslations.sh`) that merges the pulled translations into the catalog before it pushes the sources |

The NextcloudKit convention is the one that fits: string catalogs, automated, and it already solves the data-loss
problem of pushing a catalog. Following it, `.tx/config` here would be:

```ini
[main]
host = https://www.transifex.com

[o:nextcloud:p:nextcloud:r:photos-ios]
file_filter = translations/photos-ios/<lang>.xcstrings
source_file = Packages/PhotosKit/Sources/PhotosAppUI/Resources/Localizable.xcstrings
source_lang = en
type        = XCSTRINGS

[o:nextcloud:p:nextcloud:r:photos-ios-core]
file_filter = translations/photos-ios-core/<lang>.xcstrings
source_file = Packages/PhotosKit/Sources/PhotosCore/Resources/Localizable.xcstrings
source_lang = en
type        = XCSTRINGS

[o:nextcloud:p:nextcloud:r:photos-ios-backup]
file_filter = translations/photos-ios-backup/<lang>.xcstrings
source_file = Packages/PhotosKit/Sources/PhotosBackup/Resources/Localizable.xcstrings
source_lang = en
type        = XCSTRINGS

[o:nextcloud:p:nextcloud:r:photos-ios-domain]
file_filter = translations/photos-ios-domain/<lang>.xcstrings
source_file = Packages/PhotosKit/Sources/PhotosDomain/Resources/Localizable.xcstrings
source_lang = en
type        = XCSTRINGS

[o:nextcloud:p:nextcloud:r:photos-ios-networking]
file_filter = translations/photos-ios-networking/<lang>.xcstrings
source_file = Packages/PhotosKit/Sources/PhotosNetworking/Resources/Localizable.xcstrings
source_lang = en
type        = XCSTRINGS

[o:nextcloud:p:nextcloud:r:photos-ios-app]
file_filter = translations/photos-ios-app/<lang>.xcstrings
source_file = App/Resources/Localizable.xcstrings
source_lang = en
type        = XCSTRINGS

[o:nextcloud:p:nextcloud:r:photos-ios-shortcuts]
file_filter = translations/photos-ios-shortcuts/<lang>.xcstrings
source_file = App/Resources/AppShortcuts.xcstrings
source_lang = en
type        = XCSTRINGS

[o:nextcloud:p:nextcloud:r:photos-ios-info]
file_filter = translations/photos-ios-info/<lang>.xcstrings
source_file = App/Resources/InfoPlist.xcstrings
source_lang = en
type        = XCSTRINGS

[o:nextcloud:p:nextcloud:r:photos-ios-widgets]
file_filter = translations/photos-ios-widgets/<lang>.xcstrings
source_file = Extensions/Widgets/Localizable.xcstrings
source_lang = en
type        = XCSTRINGS
```

To decide and do with the localization team:

1. **Resource names and number.** Nine resources mirror the nine catalogs. Fewer would be easier for translators
   (for example by moving the small package catalogs into the `PhotosAppUI` one), but that means changing which bundle
   the code reads its strings from.
2. **Create the resources** in the `nextcloud` Transifex project.
3. **A handler in `nextcloud/docker-ci`** modelled on `handleNextcloudKitTranslations.sh`, with this repository's list
   of catalogs: it pulls, refuses to push when Transifex returned no translations although the repository has some,
   merges, drops stale keys, maps language codes (`de_DE` → `de`, `sr@latin` → `sr-Latn`) and keeps Xcode's formatting.
4. Add `.tx/config` (above) and `/translations/` to `.gitignore` in the same change, and a CI check that every key has
   a comment (`scripts/xcstrings-comments.py --check`).
5. Siri phrases (`AppShortcuts.xcstrings`) must keep `${applicationName}` and are limited by what Siri supports per
   language; worth a note to translators or leaving this catalog out at first.
