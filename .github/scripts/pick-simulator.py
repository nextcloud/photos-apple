#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: MIT
"""Prints the UDID of an iPhone simulator with an iOS 27 runtime, or nothing when there is none.

    xcrun simctl list devices available -j | pick-simulator.py <simulator SDK version>

The newest runtime that is not newer than the SDK of the selected Xcode is preferred (a newer one may not start). Among
its iPhones the standard one: "iPhone 17", then a plain numbered model ("iPhone 16", "iPhone 17 Pro"), then the newest
number. The largest name alone picked a lettered model with a different layout (the tab bar at the side), where the
smoke tests did not find the Collections tab.
"""
import json
import re
import sys


def version(text):
    return tuple(int(part) for part in re.findall(r"\d+", text))


def main():
    sdk = version(sys.argv[1]) if len(sys.argv) > 1 else (99,)
    candidates = []
    for runtime, devices in json.load(sys.stdin).get("devices", {}).items():
        match = re.search(r"SimRuntime\.iOS-(\d+(?:-\d+)*)$", runtime)
        if not match:
            continue
        runtime_version = version(match.group(1))
        if runtime_version[0] != 27:
            continue
        for device in devices:
            if device.get("isAvailable", True) and device.get("name", "").startswith("iPhone"):
                name = device["name"]
                standard = 2 if name == "iPhone 17" else 1 if re.fullmatch(r"iPhone \d+( Pro)?", name) else 0
                candidates.append((runtime_version <= sdk, runtime_version, standard, version(name), name, device["udid"]))
    if candidates:
        print(max(candidates)[-1])


if __name__ == "__main__":
    main()
