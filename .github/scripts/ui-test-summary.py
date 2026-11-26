#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: MIT
"""Writes a Markdown summary of a UI test run and fails unless tests passed and none failed or was skipped.

    xcrun xcresulttool get test-results summary --path <bundle> --compact | ui-test-summary.py

A skipped smoke test means that the login did not reach the test runner (or the platform was wrong): that is a failure.
"""
import json
import sys


def main():
    summary = json.load(sys.stdin)
    passed = summary.get("passedTests", 0)
    failed = summary.get("failedTests", 0)
    skipped = summary.get("skippedTests", 0)
    print("### UI smoke tests")
    print(f"{passed} passed, {failed} failed, {skipped} skipped ({summary.get('result', 'unknown')}).")
    for failure in summary.get("testFailures", []):
        print(f"- **{failure.get('testName', '?')}**: {failure.get('failureText', '').strip()}")
    if passed == 0 or failed > 0 or skipped > 0:
        print("::error::The UI smoke tests did not all pass (failed or skipped tests, or none ran).", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
