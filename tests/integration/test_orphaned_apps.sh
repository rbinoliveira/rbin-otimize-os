#!/usr/bin/env bash

# Integration tests for orphaned_apps cleanup (macOS)
# Runs against a fake HOME so real Application Support/Preferences are never touched

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TEST_DIR}/../.." && pwd)"

TEST_LOG="${TEST_DIR}/test_orphaned_apps.log"
PASSED=0
FAILED=0

if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    COLOR_GREEN=$(tput setaf 2 2>/dev/null || echo '')
    COLOR_RED=$(tput setaf 1 2>/dev/null || echo '')
    COLOR_RESET=$(tput sgr0 2>/dev/null || echo '')
else
    COLOR_GREEN=''
    COLOR_RED=''
    COLOR_RESET=''
fi

test_pass() {
    echo -e "${COLOR_GREEN}✓ PASS${COLOR_RESET}: $1"
    PASSED=$((PASSED + 1))
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PASS: $1" >> "$TEST_LOG"
}

test_fail() {
    echo -e "${COLOR_RED}✗ FAIL${COLOR_RESET}: $1 - $2"
    FAILED=$((FAILED + 1))
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAIL: $1 - $2" >> "$TEST_LOG"
}

FAKE_HOME=""
FAKE_BIN=""

# Fake HOME with Apple system dirs, an installed CLI tool and real orphans
setup_fake_home() {
    FAKE_HOME="$(mktemp -d)"
    FAKE_BIN="$(mktemp -d)"
    local support="${FAKE_HOME}/Library/Application Support"
    local prefs="${FAKE_HOME}/Library/Preferences"
    mkdir -p "$support" "$prefs"

    # macOS system dirs (must be kept)
    local d
    for d in Dock AddressBook Music CallHistoryDB CloudDocs Knowledge FaceTime DiskImages \
             com.apple.sharedfilelist fakesysdaemon9f3; do
        mkdir -p "${support}/${d}"
    done
    touch "${prefs}/com.apple.dock.plist" "${prefs}/com.apple.Music.plist" \
          "${prefs}/com.apple.AddressBook.abd.plist" "${prefs}/com.apple.fakesysdaemon9f3.plist"

    # Installed CLI tool storing data in Application Support (must be kept)
    mkdir -p "${support}/fakeclitool9f3"
    printf '#!/bin/sh\n' > "${FAKE_BIN}/fakeclitool9f3"
    chmod +x "${FAKE_BIN}/fakeclitool9f3"

    # Real orphans (must be removed)
    mkdir -p "${support}/FakeOrphanApp9f3" "${support}/com.fakevendor.orphan9f3"
    touch "${prefs}/com.fakevendor.orphan9f3.plist" "${prefs}/com.fakevendor.FakeOrphanApp9f3.plist"
}

cleanup_fake_home() {
    [[ -n "$FAKE_HOME" && -d "$FAKE_HOME" ]] && rm -rf "$FAKE_HOME"
    [[ -n "$FAKE_BIN" && -d "$FAKE_BIN" ]] && rm -rf "$FAKE_BIN"
    return 0
}
trap cleanup_fake_home EXIT

# Runs a snippet with the libs loaded, HOME pointed at the fake home
run_with_libs() {
    HOME="$FAKE_HOME" HOME_OVERRIDE="$FAKE_HOME" PATH="${FAKE_BIN}:$PATH" \
    SKIP_CATEGORY_CONFIRM=true QUIET=true DRY_RUN=false \
    bash -c '
        source "$1/lib/common.sh" >/dev/null 2>&1
        source "$1/lib/cleanup_preview.sh" >/dev/null 2>&1
        [[ "$(get_user_home)" == "$HOME_OVERRIDE" ]] || { echo "HOME_OVERRIDE_NOT_APPLIED"; exit 1; }
        eval "$2"
    ' _ "$PROJECT_ROOT" "$1"
}

test_detection() {
    echo "Testing orphaned app detection..."
    local found
    found=$(run_with_libs 'find_orphaned_apps' 2>/dev/null | sed 's|.*/||')

    if [[ "$found" == *HOME_OVERRIDE_NOT_APPLIED* ]]; then
        test_fail "fake HOME" "HOME_OVERRIDE not honored, aborting"
        return 1
    fi

    local name
    for name in Dock AddressBook Music CallHistoryDB CloudDocs Knowledge FaceTime DiskImages \
                com.apple.sharedfilelist fakesysdaemon9f3; do
        if grep -qx "$name" <<< "$found"; then
            test_fail "system dir '$name'" "flagged as orphan"
        else
            test_pass "system dir '$name' is not flagged"
        fi
    done

    if grep -qx "fakeclitool9f3" <<< "$found"; then
        test_fail "installed CLI tool" "flagged as orphan"
    else
        test_pass "installed CLI tool is not flagged"
    fi

    for name in FakeOrphanApp9f3 com.fakevendor.orphan9f3; do
        if grep -qx "$name" <<< "$found"; then
            test_pass "orphan '$name' is flagged"
        else
            test_fail "orphan '$name'" "not flagged"
        fi
    done
}

test_deletion() {
    echo "Testing orphaned app deletion..."
    run_with_libs 'delete_category_files orphaned_apps' >/dev/null 2>&1 || true

    local support="${FAKE_HOME}/Library/Application Support"
    local prefs="${FAKE_HOME}/Library/Preferences"

    [[ -d "${support}/Dock" && -d "${support}/Music" && -d "${support}/AddressBook" ]] \
        && test_pass "system Application Support dirs kept" \
        || test_fail "system Application Support dirs" "were deleted"

    [[ -d "${support}/fakeclitool9f3" ]] \
        && test_pass "CLI tool data kept" \
        || test_fail "CLI tool data" "was deleted"

    local kept_apple=true f
    for f in com.apple.dock.plist com.apple.Music.plist com.apple.AddressBook.abd.plist com.apple.fakesysdaemon9f3.plist; do
        [[ -f "${prefs}/${f}" ]] || kept_apple=false
    done
    [[ "$kept_apple" == "true" ]] \
        && test_pass "com.apple.* preferences kept" \
        || test_fail "com.apple.* preferences" "were deleted"

    [[ ! -d "${support}/FakeOrphanApp9f3" && ! -d "${support}/com.fakevendor.orphan9f3" ]] \
        && test_pass "orphan Application Support dirs deleted" \
        || test_fail "orphan Application Support dirs" "not deleted"

    [[ ! -f "${prefs}/com.fakevendor.orphan9f3.plist" && ! -f "${prefs}/com.fakevendor.FakeOrphanApp9f3.plist" ]] \
        && test_pass "orphan preferences deleted" \
        || test_fail "orphan preferences" "not deleted"
}

main() {
    echo "=========================================="
    echo "Orphaned Apps Cleanup Tests"
    echo "=========================================="
    echo ""

    echo "Test started: $(date)" > "$TEST_LOG"

    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "Skipping: macOS only"
        exit 0
    fi

    setup_fake_home
    if test_detection; then
        test_deletion
    fi

    echo ""
    echo "=========================================="
    echo "Test Summary"
    echo "=========================================="
    echo -e "${COLOR_GREEN}Passed: $PASSED${COLOR_RESET}"
    echo -e "${COLOR_RED}Failed: $FAILED${COLOR_RESET}"
    echo "Total: $((PASSED + FAILED))"

    [[ $FAILED -eq 0 ]]
}

main "$@"
