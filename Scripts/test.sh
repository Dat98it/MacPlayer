#!/usr/bin/env bash
# swift test for a Command Line Tools-only machine. With Swift 6.4's default build system the TestingMacros plugin
# is not found on its own, so its folder is passed explicitly; a retry loop remains for the older, flaky form of the error.
# Any other failure is returned as is.
# Usage: Scripts/test.sh [swift test arguments]
set -uo pipefail
cd "$(dirname "$0")/.."
for attempt in 1 2 3 4 5 6 7 8; do
    output="$(swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@" 2>&1)"
    status=$?
    if grep -q "plugin for module 'TestingMacros' not found" <<<"$output"; then
        continue
    fi
    printf '%s\n' "$output"
    exit $status
done
printf '%s\n' "$output"
echo "TestingMacros plugin still missing after $attempt attempts" >&2
exit 1
