#!/usr/bin/env bash
# swift test for a Command Line Tools-only machine. With Swift 6.4's default build system the TestingMacros plugin
# is not found on its own, so its folder is passed explicitly; a retry loop remains for the older, flaky form of the error.
# Any other failure is returned as is.
# Usage: Scripts/test.sh [swift test arguments]
set -uo pipefail
cd "$(dirname "$0")/.."
run_tests() {
    local test_attempt test_output test_status
    for test_attempt in 1 2 3 4 5 6 7 8; do
        test_output="$(swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@" 2>&1)"
        test_status=$?
        if grep -q "plugin for module 'TestingMacros' not found" <<<"$test_output"; then continue; fi
        printf '%s\n' "$test_output"
        return "$test_status"
    done
    printf '%s\n' "$test_output"
    echo "TestingMacros plugin still missing after $test_attempt attempts" >&2
    return 1
}

if [[ $# -eq 0 ]]; then
    # Core ML inference competes with the export timing checks for CPU/GPU. Run the model suite
    # separately, preserving the export speed thresholds and still running every test by default.
    run_tests --skip VocalRemovalTests || exit $?
    run_tests --skip-build --filter VocalRemovalTests
else
    run_tests "$@"
fi
