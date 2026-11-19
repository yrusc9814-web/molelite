#!/usr/bin/env bats

load helpers/common

# B1-21: find_app_system_files feeds the review-only preview. Its name-based
# launchd scan used a raw substring, so "ClashX" offered ClashX Pro's
# com.west2online.ClashXPro.ProxyConfigHelper.plist; its standard path list
# offered the machine-wide /Library/Application Support/Steam game library;
# and find_shared_app_paths let the generic product token "live" claim
# /Users/Shared/Live Recording Session for Ableton Live. Nothing here is
# deleted, but the preview must not mislead about ownership.

setup_file() {
    mole_test_setup_home p7b-B1-21
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

@test "launchd labels match the app name only as a whole dotted component" {
    # ClashX Pro's helper is a different product, not ClashX's leftover.
    run _mole_uninstall_launchd_label_has_app_name \
        "com.west2online.ClashXPro.ProxyConfigHelper" "ClashX"
    [ "$status" -eq 1 ]

    # The real ClashX helper and a space-separated label stay discoverable.
    run _mole_uninstall_launchd_label_has_app_name \
        "com.vendor.ClashX.ProxyConfigHelper" "ClashX"
    [ "$status" -eq 0 ]
    run _mole_uninstall_launchd_label_has_app_name "ClashX Helper" "ClashX"
    [ "$status" -eq 0 ]
}

@test "the machine-wide Steam library is never a system leftover" {
    run _mole_is_steam_system_library_path "/Library/Application Support/Steam"
    [ "$status" -eq 0 ]
    run _mole_is_steam_system_library_path \
        "/Library/Application Support/Steam/steamapps/common/Game"
    [ "$status" -eq 0 ]

    # A similarly named sibling is a different folder and stays separate.
    run _mole_is_steam_system_library_path "/Library/Application Support/SteamCompanion"
    [ "$status" -eq 1 ]
}

@test "find_shared_app_paths does not claim a generic Live folder for Ableton Live" {
    local shared="$HOME/Shared"
    mkdir -p "$shared/Live Recording Session" "$shared/Ableton Live"

    result=$(find_shared_app_paths "com.ableton.live" "Ableton Live" "$shared")

    [[ "$result" != *"Live Recording Session"* ]] || return 1
    [[ "$result" == *"$shared/Ableton Live"* ]]
}

@test "find_shared_app_paths still uses a distinctive product token" {
    local shared="$HOME/Shared"
    mkdir -p "$shared/UURemote"

    result=$(find_shared_app_paths "com.netease.uuremote" "UU远程" "$shared")

    [[ "$result" == *"$shared/UURemote"* ]]
}
