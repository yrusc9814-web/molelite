#!/usr/bin/env bats

load helpers/common

# B1-10: the Raycast rule swept every one-level directory whose name merely
# contained "raycast", plus a depth-two Caches sweep, so uninstalling
# Raycast.app (com.raycast.macos) also claimed another vendor's sandbox and
# script folders (com.thirdparty.raycast-helper,
# com.example.raycast-bridge), a "RaycastBeta" channel directory, and any
# cache nested under an unrelated vendor root. Only the bundle id's dot
# boundary and the app-name leaves the general patterns already own are
# Raycast's now; everything an ambiguous name could mean stays on disk.
#
# Fixtures live in a throwaway HOME; nothing here touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B1-10
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

# The other-product paths the old "*raycast*" sweep used to claim, plus the
# two channel spellings of Raycast's own folder.
make_raycast_fixtures() {
    mkdir -p "$HOME/Library/Containers/com.thirdparty.raycast-helper"
    mkdir -p "$HOME/Library/Application Scripts/com.example.raycast-bridge"
    mkdir -p "$HOME/Library/Application Support/RaycastBeta"
    mkdir -p "$HOME/Library/Caches/com.example.raycast-bridge/Widget"

    mkdir -p "$HOME/Library/Application Support/Raycast"
    mkdir -p "$HOME/Library/Caches/Raycast"
    mkdir -p "$HOME/Library/Caches/com.raycast.macos"
    mkdir -p "$HOME/Library/Containers/com.raycast.macos"
    mkdir -p "$HOME/Library/Application Scripts/com.raycast.macos"
    mkdir -p "$HOME/Library/Containers/com.raycast.macos.BrowserExtension"
    mkdir -p "$HOME/Library/Containers/com.raycast.macos.RaycastAppIntents"
}

@test "B1-10 does not claim another vendor's raycast-named container or script dir" {
    make_raycast_fixtures

    run find_app_files "com.raycast.macos" "Raycast"
    [ "$status" -eq 0 ]

    # Before the fix both were queued by the bare "*raycast*" sweep.
    ! list_has_path "$output" "$HOME/Library/Containers/com.thirdparty.raycast-helper" || return 1
    ! list_has_path "$output" "$HOME/Library/Application Scripts/com.example.raycast-bridge" || return 1

    # Still on disk: the scan only refuses to claim them.
    [ -d "$HOME/Library/Containers/com.thirdparty.raycast-helper" ] || return 1
    [ -d "$HOME/Library/Application Scripts/com.example.raycast-bridge" ]
}

@test "B1-10 does not claim another vendor's raycast-named cache" {
    make_raycast_fixtures

    run find_app_files "com.raycast.macos" "Raycast"
    [ "$status" -eq 0 ]

    # The old depth-two Caches sweep reached this unrelated vendor root.
    ! list_has_path "$output" "$HOME/Library/Caches/com.example.raycast-bridge" || return 1
    [ -d "$HOME/Library/Caches/com.example.raycast-bridge/Widget" ]
}

@test "B1-10 does not claim a RaycastBeta channel folder for the stable app" {
    make_raycast_fixtures
    mkdir -p "$HOME/Library/Caches/RaycastBeta"

    run find_app_files "com.raycast.macos" "Raycast" "$HOME/Applications/Raycast.app"
    [ "$status" -eq 0 ]

    # "RaycastBeta" names a separate build's data, not this bundle's.
    ! list_has_path "$output" "$HOME/Library/Application Support/RaycastBeta" || return 1
    ! list_has_path "$output" "$HOME/Library/Caches/RaycastBeta" || return 1
    [ -d "$HOME/Library/Application Support/RaycastBeta" ]
}

@test "B1-10 keeps Raycast's own bundle-id and product folders" {
    make_raycast_fixtures

    run find_app_files "com.raycast.macos" "Raycast"
    [ "$status" -eq 0 ]

    list_has_path "$output" "$HOME/Library/Containers/com.raycast.macos" || return 1
    list_has_path "$output" "$HOME/Library/Application Scripts/com.raycast.macos" || return 1
    list_has_path "$output" "$HOME/Library/Caches/com.raycast.macos" || return 1
    list_has_path "$output" "$HOME/Library/Containers/com.raycast.macos.BrowserExtension" || return 1
    list_has_path "$output" "$HOME/Library/Containers/com.raycast.macos.RaycastAppIntents" || return 1
    list_has_path "$output" "$HOME/Library/Application Support/Raycast" || return 1
    list_has_path "$output" "$HOME/Library/Caches/Raycast"
}

@test "B1-10 Raycast v2 stays out of the bundle-id sweep" {
    # com.raycast-x.macos has neither the v1 bundle id's prefix nor its name.
    make_raycast_fixtures
    mkdir -p "$HOME/Library/Containers/com.raycast-x.macos"
    mkdir -p "$HOME/Library/Application Support/com.raycast-x.macos"

    run find_app_files "com.raycast.macos" "Raycast"
    [ "$status" -eq 0 ]

    ! list_has_path "$output" "$HOME/Library/Containers/com.raycast-x.macos" || return 1
    ! list_has_path "$output" "$HOME/Library/Application Support/com.raycast-x.macos" || return 1
    [ -d "$HOME/Library/Containers/com.raycast-x.macos" ]
}

@test "B1-10 the Raycast block never scans two levels below Caches" {
    # A depth-two sweep is what reached another vendor's cache root; pin the
    # narrow shape so a later edit cannot restore it.
    run grep -A12 'for raycast_dir in' "$PROJECT_ROOT/lib/core/app_protection.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"-maxdepth 2"* ]] || return 1
    [[ "$output" != *'-iname "*raycast*"'* ]]
}
