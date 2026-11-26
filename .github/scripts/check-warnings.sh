#!/bin/sh
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: MIT
#
# Fails when an xcodebuild log has warnings of our own: the compiler's are errors in CI already (PHOTOS_WARNINGS_AS_ERRORS),
# but not those inside macro expansions (#expect) nor those of other tools (asset catalogs, linker, Info.plist).
# Dependencies (SourcePackages) are not ours.
#
#   .github/scripts/check-warnings.sh <xcodebuild log>
set -eu
# Only diagnostics of the build (a file, a macro expansion, the linker, xcodebuild itself), not what tests print while they run.
WARNINGS=$(grep -E '^((/[^:]+)(:[0-9]+:[0-9]+)?|macro expansion [^:]+:[0-9]+:[0-9]+|ld): warning: |^warning: ' "$1" \
    | grep -v '/SourcePackages/' | sort -u || true)
if [ -n "$WARNINGS" ]; then
    echo "$WARNINGS"
    echo "::error::$(echo "$WARNINGS" | wc -l | tr -d ' ') warnings (see above)."
    exit 1
fi
echo "No warnings."
