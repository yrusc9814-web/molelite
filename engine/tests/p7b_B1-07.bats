#!/usr/bin/env bats

load helpers/common

# B1-07: find_app_files folds a spaced app name into a no-space, hyphen and
# underscore spelling to reach the folders such an app really writes
# ("Maestro Studio" -> "MaestroStudio"). The fold also names other products:
# uninstalling "Foo Bar.app" (com.vendor.foobar) also offered
# ~/Library/Application Support/FooBar, Foo_Bar and Foo-Bar, FooBar.plist and
# ~/.config/foobar, so an installed independent "FooBar.app" lost its data.
#
# A folded group now needs every spelling to be free of an installed bundle
# with that exact name; the app's own direct and base-name patterns still
# apply. Fixtures live in a throwaway HOME; nothing here touches the real
# Library.

setup_file() {
    mole_test_setup_home p7b-B1-07
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

# The folders a folded "Foo Bar" spelling reaches, plus the app's own two
# direct spellings (which never depend on the fold).
make_foo_bar_leaf_fixtures() {
    mkdir -p "$HOME/Library/Application Support/FooBar" \
        "$HOME/Library/Application Support/Foo_Bar" \
        "$HOME/Library/Application Support/Foo-Bar" \
        "$HOME/Library/Application Support/Foo Bar" \
        "$HOME/Library/Preferences" \
        "$HOME/.config/foobar" "$HOME/.cache/foobar" "$HOME/.local/share/foobar"
    touch "$HOME/Library/Preferences/FooBar.plist" \
        "$HOME/Library/Preferences/Foo Bar.plist"
}

@test "find_app_files keeps a folded spelling whose independent product is installed" {
    local apps="$HOME/apps"
    mkdir -p "$apps/Foo Bar.app" "$apps/FooBar.app"
    make_foo_bar_leaf_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.vendor.foobar" "Foo Bar" "$apps/Foo Bar.app")

    # The independent FooBar.app owns every spelling of the folded name.
    [[ "$result" != *"Application Support/FooBar"* ]] || return 1
    [[ "$result" != *"Application Support/Foo_Bar"* ]] || return 1
    [[ "$result" != *"Application Support/Foo-Bar"* ]] || return 1
    [[ "$result" != *"Preferences/FooBar.plist"* ]] || return 1
    [[ "$result" != *".config/foobar"* ]] || return 1
    [[ "$result" != *".cache/foobar"* ]] || return 1
    [[ "$result" != *".local/share/foobar"* ]] || return 1
    # The app's own exact spelling is still this app's data.
    list_has_path "$result" "$HOME/Library/Application Support/Foo Bar" || return 1
    list_has_path "$result" "$HOME/Library/Preferences/Foo Bar.plist"
}

@test "find_app_files keeps the folded group when the installed product differs in case" {
    local apps="$HOME/apps"
    # A case-sensitive volume must answer like APFS: "foo-bar.app" is FooBar.
    mkdir -p "$apps/Foo Bar.app" "$apps/foo-bar.app"
    make_foo_bar_leaf_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.vendor.foobar" "Foo Bar" "$apps/Foo Bar.app")

    [[ "$result" != *"FooBar"* ]] || return 1
    [[ "$result" != *"Foo_Bar"* ]] || return 1
    [[ "$result" != *"Foo-Bar"* ]] || return 1
    [[ "$result" != *".config/foobar"* ]]
}

@test "find_app_files still offers every folded spelling when no product claims one" {
    local apps="$HOME/apps"
    mkdir -p "$apps/Foo Bar.app" "$apps/FooBar Deluxe.app" "$apps/FooBarPlus.app"
    make_foo_bar_leaf_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.vendor.foobar" "Foo Bar" "$apps/Foo Bar.app")

    # Only an exact name collides; a longer product name proves nothing.
    list_has_path "$result" "$HOME/Library/Application Support/FooBar" || return 1
    list_has_path "$result" "$HOME/Library/Preferences/FooBar.plist" || return 1
    list_has_path "$result" "$HOME/Library/Application Support/Foo_Bar" || return 1
    list_has_path "$result" "$HOME/Library/Application Support/Foo-Bar" || return 1
    list_has_path "$result" "$HOME/.config/foobar" || return 1
    list_has_path "$result" "$HOME/.cache/foobar" || return 1
    list_has_path "$result" "$HOME/.local/share/foobar"
}

@test "find_app_files does not read the app being removed as its own collision" {
    local apps="$HOME/apps"
    # The bug report's exact shape: "FooBar.app" is the selected bundle, and
    # "Foo Bar.app" is the independent product still installed.
    mkdir -p "$apps/FooBar.app"
    make_foo_bar_leaf_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.vendor.foobar" "FooBar" "$apps/FooBar.app")

    # Same-name app: no fold is generated, its own folder is its data.
    list_has_path "$result" "$HOME/Library/Application Support/FooBar"
}

@test "find_app_files keeps Maestro Studio's folded folders when MaestroStudio.app is gone" {
    mkdir -p "$HOME/apps"
    mkdir -p "$HOME/Library/Application Support/MaestroStudio" "$HOME/.config/maestro-studio"

    # Guards the B1-07 fix against over-reach: the fold still works (#377).
    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$HOME/apps" \
        find_app_files "com.maestro.studio" "Maestro Studio")

    list_has_path "$result" "$HOME/Library/Application Support/MaestroStudio" || return 1
    list_has_path "$result" "$HOME/.config/maestro-studio"
}
