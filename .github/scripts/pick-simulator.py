#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: MIT
"""Prints the UDID of an iPhone simulator with an iOS 27 runtime, or nothing when there is none.

    xcrun simctl list devices available -j | pick-simulator.py <simulator SDK version>

The newest runtime that is not newer than the SDK of the selected Xcode is preferred (a newer one may not start).
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
                candidates.append((runtime_version <= sdk, runtime_version, device["name"], device["udid"]))
    if candidates:
        print(max(candidates)[3])


if __name__ == "__main__":
    main()
