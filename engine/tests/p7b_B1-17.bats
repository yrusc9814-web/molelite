#!/usr/bin/env bats

load helpers/common

# B1-17: a vendor folder holds several products side by side, and
# find_app_files matched any child that started with the app name plus a
# space. "FooBar.app" (com.acme.foobar) therefore claimed
# ~/Library/Application Support/Acme/FooBar 2, the data of the copied or
# side-by-side "FooBar 2.app", and "Acme/FooBar Deluxe" of an unrelated
# product. The spaced arm now needs a channel word ("FooBar Beta") or a
# version ("FooBar 8.5", "FooBar 2024.1") after the name; the exact name and
# the hyphen/underscore/dot separators are unchanged.
#
# Fixtures live in a throwaway HOME; nothing here touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B1-17
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

# An empty app-family root, so a bundle installed on the test host can never
# answer as a sibling.
no_app_family() {
    mkdir -p "$HOME/apps"
    printf '%s\n' "$HOME/apps"
}

@test "B1-17 find_app_files leaves the vendor folder's numbered copy to that copy" {
    local vendor="$HOME/Library/Application Support/Acme"
    mkdir -p "$vendor/FooBar" "$vendor/FooBar 2" "$vendor/FooBar Deluxe"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$(no_app_family)" \
        find_app_files "com.acme.foobar" "FooBar")

    # "FooBar 2" is FooBar 2.app's data; the vendor match must not take it.
    ! list_has_path "$result" "$vendor/FooBar 2" || return 1
    ! list_has_path "$result" "$vendor/FooBar Deluxe" || return 1
    # This app's own folder is still found.
    list_has_path "$result" "$vendor/FooBar"
}

@test "B1-17 the numbered copy stays on disk, only the listing shrinks" {
    local vendor="$HOME/Library/Application Support/Acme"
    mkdir -p "$vendor/FooBar 2"
    touch "$vendor/FooBar 2/settings.db"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$(no_app_family)" \
        find_app_files "com.acme.foobar" "FooBar")

    [[ "$result" != *"FooBar 2"* ]] || return 1
    [[ -f "$vendor/FooBar 2/settings.db" ]]
}

@test "B1-17 a vendor child that keeps a channel word or a version is still this app's" {
    local vendor="$HOME/Library/Application Support/Acme"
    mkdir -p "$vendor/FooBar Beta" "$vendor/FooBar (Beta)" \
        "$vendor/FooBar 8.5" "$vendor/FooBar 2024.1" "$vendor/FooBar-2" \
        "$vendor/FooBar_2" "$vendor/FooBar.data"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$(no_app_family)" \
        find_app_files "com.acme.foobar" "FooBar")

    # Channel and version tails name this product, not a copy of it.
    list_has_path "$result" "$vendor/FooBar Beta" || return 1
    list_has_path "$result" "$vendor/FooBar (Beta)" || return 1
    list_has_path "$result" "$vendor/FooBar 8.5" || return 1
    list_has_path "$result" "$vendor/FooBar 2024.1" || return 1
    # The other separators were never the problem and keep matching.
    list_has_path "$result" "$vendor/FooBar-2" || return 1
    list_has_path "$result" "$vendor/FooBar_2" || return 1
    list_has_path "$result" "$vendor/FooBar.data"
}

@test "B1-17 a spaced display name still reaches its own spaced vendor folder" {
    local vendor="$HOME/Library/Application Support/Acme"
    mkdir -p "$vendor/Foo Bar" "$vendor/Foo Bar 2" "$vendor/FooBar 2"

    # The app is "Foo Bar", so the exact spaced leaf is its own folder; the
    # numbered copies belong to "Foo Bar 2.app"/"FooBar 2.app".
    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$(no_app_family)" \
        find_app_files "com.acme.foobar" "Foo Bar")

    list_has_path "$result" "$vendor/Foo Bar" || return 1
    ! list_has_path "$result" "$vendor/Foo Bar 2" || return 1
    ! list_has_path "$result" "$vendor/FooBar 2"
}
