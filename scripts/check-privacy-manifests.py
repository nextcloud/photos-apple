#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: MIT
"""Checks that the privacy manifests declare every required-reason API category the code uses.

Apple rejects an upload whose binary uses an API of a "required reason" category that the bundle's
PrivacyInfo.xcprivacy does not declare. This finds the uses by name in the Swift sources (a grep, not a
compiler: good enough for the handful of APIs Apple lists) and checks

  * each package module with such a use has a manifest that declares the category, and
  * each app and extension manifest declares the categories of everything linked into it
    (the package is linked statically, so its uses end up in every binary that links a module).

The reasons themselves (CA92.1, C617.1, …) are a judgement; they are explained in docs/PRIVACY-AND-EXPORT.md.
Usage: scripts/check-privacy-manifests.py [-v]   (exit status 1 when something is missing)
"""

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Packages/PhotosKit/Sources"

# Apple's list of required-reason APIs (as of 2026), by the names Swift code uses.
CATEGORIES = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": re.compile(
        r"contentModificationDate|creationDateKey|contentAccessDate|attributeModificationDate|addedToDirectoryDate"
        r"|fileModificationDate|\[\s*\.(modificationDate|creationDate)\s*\]|FileAttributeKey\.(modificationDate|creationDate)"
        r"|\bgetattrlist|\bfstatat\(|\bfstat\(|\blstat\(|Darwin\.stat\("
    ),
    "NSPrivacyAccessedAPICategorySystemBootTime": re.compile(r"\bsystemUptime\b|\bmach_absolute_time\b"),
    "NSPrivacyAccessedAPICategoryDiskSpace": re.compile(
        r"volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|\bsystemSize\b|\bstatv?fs\b|\bfstatv?fs\b"
    ),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": re.compile(r"\bactiveInputModes\b"),
    "NSPrivacyAccessedAPICategoryUserDefaults": re.compile(r"\bUserDefaults\b|@AppStorage\b"),
}

# Package modules and what they link (Packages/PhotosKit/Package.swift).
MODULES = {
    "PhotosModel": [],
    "PhotosDomain": ["PhotosModel"],
    "PhotosNetworking": ["PhotosModel"],
    "PhotosStore": ["PhotosModel", "PhotosDomain", "PhotosNetworking"],
    "PhotosMedia": ["PhotosModel", "PhotosDomain", "PhotosNetworking", "PhotosStore"],
    "PhotosBackup": ["PhotosModel", "PhotosDomain", "PhotosNetworking", "PhotosStore", "PhotosMedia"],
    "PhotosCore": ["PhotosModel", "PhotosDomain", "PhotosNetworking", "PhotosStore", "PhotosMedia", "PhotosBackup"],
    "PhotosAppUI": [
        "PhotosModel", "PhotosDomain", "PhotosNetworking", "PhotosStore", "PhotosMedia", "PhotosBackup", "PhotosCore",
    ],
}

# Bundles (project.yml): manifest, own source folders/files, the package product they link.
BUNDLES = {
    "app": ("App/Resources/PrivacyInfo.xcprivacy", ["App/Shared"], "PhotosAppUI"),
    "share extension": ("Extensions/ShareExtension/PrivacyInfo.xcprivacy", ["Extensions/ShareExtension"], "PhotosAppUI"),
    "notification service": (
        "Extensions/NotificationService/PrivacyInfo.xcprivacy", ["Extensions/NotificationService"], "PhotosCore",
    ),
    "widgets": ("Extensions/Widgets/PrivacyInfo.xcprivacy", ["Extensions/Widgets", "App/Shared/AmbientIntents.swift"], "PhotosCore"),
    "background upload": ("Extensions/BackgroundUpload/PrivacyInfo.xcprivacy", ["Extensions/BackgroundUpload"], "PhotosCore"),
    "Apple TV app": ("App/TV/PrivacyInfo.xcprivacy", ["App/TV"], "PhotosCore"),
    "Top Shelf": ("Extensions/TopShelf/PrivacyInfo.xcprivacy", ["Extensions/TopShelf"], "PhotosModel"),
    "Apple Watch app": ("App/Watch/PrivacyInfo.xcprivacy", ["App/Watch"], "PhotosModel"),
    "watch complication": ("Extensions/WatchWidgets/PrivacyInfo.xcprivacy", ["Extensions/WatchWidgets"], "PhotosModel"),
}


def swift_files(path: Path):
    if path.is_file():
        return [path]
    return sorted(path.rglob("*.swift"))


def uses(paths):
    """Category → list of 'file:line' where the code uses it (comments skipped)."""
    found = {}
    for path in paths:
        for file in swift_files(path):
            for number, line in enumerate(file.read_text(encoding="utf-8").splitlines(), 1):
                code = line.split("//", 1)[0] if not line.lstrip().startswith("//") else ""
                for category, pattern in CATEGORIES.items():
                    if pattern.search(code):
                        found.setdefault(category, []).append(f"{file.relative_to(ROOT)}:{number}")
    return found


def declared(manifest: Path):
    """Category → reasons declared in a manifest; None when there is no manifest."""
    if not manifest.exists():
        return None
    with manifest.open("rb") as handle:
        plist = plistlib.load(handle)
    return {
        entry["NSPrivacyAccessedAPIType"]: entry.get("NSPrivacyAccessedAPITypeReasons", [])
        for entry in plist.get("NSPrivacyAccessedAPITypes", [])
    }


def short(category):
    return category.removeprefix("NSPrivacyAccessedAPICategory")


def main():
    verbose = "-v" in sys.argv
    problems = []
    module_uses = {name: uses([SOURCES / name]) for name in MODULES}

    for name, found in module_uses.items():
        manifest = SOURCES / name / "Resources/PrivacyInfo.xcprivacy"
        have = declared(manifest)
        for category, places in sorted(found.items()):
            if have is None or category not in have:
                problems.append(f"{name}: uses {short(category)} ({places[0]}, {len(places)} places) but its manifest does not declare it")
        if verbose:
            print(f"{name}: " + (", ".join(f"{short(c)} ×{len(p)}" for c, p in sorted(found.items())) or "nothing"))

    for bundle, (manifest_path, own, product) in BUNDLES.items():
        found = uses([ROOT / path for path in own])
        for module in [product] + MODULES[product]:
            for category, places in module_uses[module].items():
                found.setdefault(category, []).extend(places)
        have = declared(ROOT / manifest_path)
        if have is None:
            problems.append(f"{bundle}: no manifest at {manifest_path}")
            continue
        for category, places in sorted(found.items()):
            if category not in have:
                problems.append(f"{bundle} ({manifest_path}): links code that uses {short(category)} ({places[0]}) but does not declare it")
        for category, reasons in have.items():
            if not reasons:
                problems.append(f"{bundle}: {short(category)} is declared without a reason")
        if verbose:
            print(f"{bundle}: needs " + (", ".join(sorted(short(c) for c in found)) or "nothing")
                  + "; declares " + (", ".join(f"{short(c)} {'/'.join(r)}" for c, r in sorted(have.items())) or "nothing"))

    for problem in problems:
        print("MISSING:", problem)
    if not problems:
        print("Privacy manifests: every required-reason API category in use is declared.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
