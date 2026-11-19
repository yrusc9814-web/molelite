#!/usr/bin/env bats

load helpers/common

# B1-11: the Xcode toolchain rule in find_app_files matched the display name
# by substring ("$app_name" =~ Xcode|xcode) or a loose "apple.*xcode" bundle
# id, so uninstalling "XcodeBuild Helper.app" (com.acme.xcodehelper) or
# "Xcode Clean.app" swept ~/Library/Developer/Xcode/DerivedData (every
# project's build products), the iOS/macOS DeviceSupport caches,
# ~/Library/Developer/CoreSimulator/Caches and ~/.Xcode. The
# MOLE_UNINSTALL_SIBLING_SURVIVES switch only fires when a same-bundle-id
# sibling survives, so a same-prefix app with a different id bypassed it.
#
# The fix replaces the substring with ownership evidence: the bundle id is
# Apple's com.apple.dt.Xcode (either channel) or the bundle declares
# CFBundleExecutable "Xcode". Anything else, including an unreadable
# Info.plist, keeps the caches. Fixtures live in a throwaway HOME; nothing
# here touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B1-11
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    # Safety: refuse to operate on a real home directory.
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    find "$HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2> /dev/null || true
    source "$PROJECT_ROOT/lib/core/base.sh"
    source "$PROJECT_ROOT/lib/core/log.sh"
    source "$PROJECT_ROOT/lib/core/app_protection.sh"
}

# Print 0 when the newline-separated list holds this exact path.
list_has_path() {
    local list="$1" want="${2%/}"
    local line
    while IFS= read -r line; do
        [[ "${line%/}" == "$want" ]] && return 0
    done <<< "$list"
    return 1
}

# Create the four Xcode cache roots the heuristic sweeps.
make_xcode_fixtures() {
    mkdir -p "$HOME/Library/Developer/Xcode/DerivedData/Project-abc/Build" \
        "$HOME/Library/Developer/Xcode/iOS DeviceSupport/17.0" \
        "$HOME/Library/Developer/CoreSimulator/Caches/dyld" \
        "$HOME/.Xcode/UserData"
}

# Make one bundle whose Info.plist declares the given id and executable. An
# empty executable reproduces a bundle with no CFBundleExecutable key.
make_bundle() {
    local path="$1" bundle_id="$2" exec_name="${3:-}"
    mkdir -p "$path/Contents/MacOS"
    {
        printf '%s\n' '<plist version="1.0"><dict>'
        printf '  <key>CFBundleIdentifier</key><string>%s</string>\n' "$bundle_id"
        if [[ -n "$exec_name" ]]; then
            printf '  <key>CFBundleExecutable</key><string>%s</string>\n' "$exec_name"
        fi
        printf '%s\n' '</dict></plist>'
    } > "$path/Contents/Info.plist"
}

@test "B1-11 an Xcode-named third-party helper never sweeps DerivedData or DeviceSupport" {
    # Before the fix "XcodeBuild Helper" matched /Xcode/ and every cache below
    # was queued for removal without a prompt.
    local apps="$HOME/apps"
    make_bundle "$apps/XcodeBuild Helper.app" "com.acme.xcodehelper" "XcodeBuild Helper"
    make_xcode_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.xcodehelper" "XcodeBuild Helper" \
        "$apps/XcodeBuild Helper.app")

    ! list_has_path "$result" "$HOME/Library/Developer/Xcode/DerivedData" || return 1
    ! list_has_path "$result" "$HOME/Library/Developer/Xcode/iOS DeviceSupport" || return 1
    ! list_has_path "$result" "$HOME/Library/Developer/CoreSimulator/Caches" || return 1
    ! list_has_path "$result" "$HOME/.Xcode"
}

@test "B1-11 an Xcode-named bundle with no Info.plist keeps the toolchain caches" {
    # Unreadable ownership is unknown, so the caches stay (fail-safe direction).
    local apps="$HOME/apps"
    mkdir -p "$apps/Xcode Clean.app/Contents"
    make_xcode_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.xcodeclean" "Xcode Clean" "$apps/Xcode Clean.app")

    ! list_has_path "$result" "$HOME/Library/Developer/Xcode/DerivedData" || return 1
    ! list_has_path "$result" "$HOME/Library/Developer/CoreSimulator/Caches" || return 1
    ! list_has_path "$result" "$HOME/.Xcode"
}

@test "B1-11 a bundle id that merely contains apple and xcode does not qualify" {
    # The old id test was "$bundle_id" =~ apple.*xcode, which accepted
    # com.notapple.toolxcode. Only Apple's exact Xcode id is ownership proof.
    local apps="$HOME/apps"
    make_bundle "$apps/Xcode Runner.app" "com.notapple.xcoderunner" "Xcode Runner"
    make_xcode_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.notapple.xcoderunner" "Xcode Runner" "$apps/Xcode Runner.app")

    ! list_has_path "$result" "$HOME/Library/Developer/Xcode/DerivedData"
}

@test "B1-11 Apple's Xcode still sweeps its own regenerable caches" {
    # The fix must not stop a real Xcode uninstall from reclaiming them.
    local apps="$HOME/apps"
    make_bundle "$apps/Xcode.app" "com.apple.dt.Xcode" "Xcode"
    make_xcode_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.apple.dt.Xcode" "Xcode" "$apps/Xcode.app")

    list_has_path "$result" "$HOME/Library/Developer/Xcode/DerivedData" || return 1
    list_has_path "$result" "$HOME/Library/Developer/Xcode/iOS DeviceSupport" || return 1
    list_has_path "$result" "$HOME/Library/Developer/CoreSimulator/Caches" || return 1
    list_has_path "$result" "$HOME/.Xcode"
}

@test "B1-11 Xcode-beta still sweeps the shared caches through its bundle id or executable" {
    # Xcode-beta.app ships CFBundleExecutable "Xcode" and the same bundle id;
    # both proofs keep the beta channel working.
    local apps="$HOME/apps"
    make_bundle "$apps/Xcode-beta.app" "com.apple.dt.Xcode" "Xcode"
    make_xcode_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.apple.dt.Xcode" "Xcode-beta" "$apps/Xcode-beta.app")

    list_has_path "$result" "$HOME/Library/Developer/Xcode/DerivedData"
}

@test "B1-11 a renamed Xcode channel with the Xcode executable keeps the caches" {
    # A channel that changes both display name and bundle id (for example a
    # locally repackaged build) is still Xcode while it declares the Xcode
    # executable, and taking DerivedData with it is correct.
    local apps="$HOME/apps"
    make_bundle "$apps/Xcode Nightly.app" "com.apple.dt.Xcode.nightly" "Xcode"
    make_xcode_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.apple.dt.Xcode.nightly" "Xcode Nightly" "$apps/Xcode Nightly.app")

    list_has_path "$result" "$HOME/Library/Developer/Xcode/DerivedData"
}

@test "B1-11 the sibling switch is not the only guard for a lookalike name" {
    # Regression shape: no sibling survives (SIBLING_SURVIVES is 0 here, as
    # the batch sets it only for a same-bundle-id survivor), yet the caches
    # must still stay because the bundle has no Xcode ownership.
    local apps="$HOME/apps"
    make_bundle "$apps/XcodeBuild Helper.app" "com.acme.xcodehelper" "XcodeBuild Helper"
    make_xcode_fixtures

    result=$(MOLE_UNINSTALL_SIBLING_SURVIVES=0 MOLE_TEST_MODE=1 \
        MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.xcodehelper" "XcodeBuild Helper" \
        "$apps/XcodeBuild Helper.app")

    ! list_has_path "$result" "$HOME/Library/Developer/Xcode/DerivedData"
}
