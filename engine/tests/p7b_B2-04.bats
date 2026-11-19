#!/usr/bin/env bats

load helpers/common

# B2-04: find_app_files folds a spaced app name ("Foo Bar" -> "FooBar") but
# never folded a dotted one, so "Foo.Bar.app" (com.acme.foobar) only offered
# ~/Library/Application Support/Foo.Bar and Preferences/Foo.Bar.plist while
# the app really writes the dotless "FooBar", its caches and its preferences.
# The dotless spelling is another product's name ("FooBar.app") unless the
# same folded-name guard as a spaced name accepts it, so the fold is only
# offered when no installed bundle carries that exact name and the spelling
# is not a shared product root. Fixtures live in a throwaway HOME.

setup_file() {
    mole_test_setup_home p7b-B2-04
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

# The dotless leaves a "Foo.Bar" app writes, in the three separator spellings
# the dot fold derives.
make_dotted_leaf_fixtures() {
    mkdir -p "$HOME/Library/Application Support/FooBar" \
        "$HOME/Library/Application Support/Foo_Bar" \
        "$HOME/Library/Application Support/Foo-Bar" \
        "$HOME/Library/Caches/FooBar" \
        "$HOME/Library/Logs/FooBar" \
        "$HOME/Library/Preferences" \
        "$HOME/Library/Saved Application State/FooBar.savedState"
    touch "$HOME/Library/Preferences/FooBar.plist" \
        "$HOME/Library/Preferences/Foo_Bar.plist" \
        "$HOME/Library/Preferences/Foo-Bar.plist"
}

@test "find_app_files reaches the dotless leaves of a dotted display name" {
    make_dotted_leaf_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$HOME/apps" \
        find_app_files "com.acme.foobar" "Foo.Bar")

    list_has_path "$result" "$HOME/Library/Application Support/FooBar" || return 1
    list_has_path "$result" "$HOME/Library/Caches/FooBar" || return 1
    list_has_path "$result" "$HOME/Library/Logs/FooBar" || return 1
    list_has_path "$result" "$HOME/Library/Preferences/FooBar.plist" || return 1
    list_has_path "$result" "$HOME/Library/Saved Application State/FooBar.savedState" || return 1
    list_has_path "$result" "$HOME/Library/Application Support/Foo_Bar" || return 1
    list_has_path "$result" "$HOME/Library/Preferences/Foo_Bar.plist" || return 1
    list_has_path "$result" "$HOME/Library/Application Support/Foo-Bar" || return 1
    list_has_path "$result" "$HOME/Library/Preferences/Foo-Bar.plist"
}

@test "find_app_files still offers the dotted spelling itself" {
    mkdir -p "$HOME/Library/Application Support/Foo.Bar" "$HOME/Library/Preferences"
    touch "$HOME/Library/Preferences/Foo.Bar.plist"
    make_dotted_leaf_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$HOME/apps" \
        find_app_files "com.acme.foobar" "Foo.Bar")

    list_has_path "$result" "$HOME/Library/Application Support/Foo.Bar" || return 1
    list_has_path "$result" "$HOME/Library/Preferences/Foo.Bar.plist"
}

@test "find_app_files keeps the dotless group while an independent FooBar.app is installed" {
    local apps="$HOME/apps"
    mkdir -p "$apps/Foo.Bar.app" "$apps/FooBar.app"
    make_dotted_leaf_fixtures
    mkdir -p "$HOME/Library/Application Support/Foo.Bar"
    touch "$HOME/Library/Preferences/Foo.Bar.plist"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.foobar" "Foo.Bar" "$apps/Foo.Bar.app")

    # FooBar.app owns every dotless spelling, so none of them may be offered.
    [[ "$result" != *"Application Support/FooBar"* ]] || return 1
    [[ "$result" != *"Application Support/Foo_Bar"* ]] || return 1
    [[ "$result" != *"Application Support/Foo-Bar"* ]] || return 1
    [[ "$result" != *"Preferences/FooBar.plist"* ]] || return 1
    [[ "$result" != *"Preferences/Foo_Bar.plist"* ]] || return 1
    [[ "$result" != *"Preferences/Foo-Bar.plist"* ]] || return 1
    [[ "$result" != *"Caches/FooBar"* ]] || return 1
    # The selected app's own dotted spelling is still its data.
    list_has_path "$result" "$HOME/Library/Application Support/Foo.Bar" || return 1
    list_has_path "$result" "$HOME/Library/Preferences/Foo.Bar.plist"
}

@test "find_app_files does not fold a dotless spelling that names a shared product root" {
    mkdir -p "$HOME/Library/Application Support/Code" "$HOME/Library/Preferences"
    touch "$HOME/Library/Preferences/Code.plist"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$HOME/apps" \
        find_app_files "com.acme.code" "Co.de")

    # "Co.de" folds to the product word "Code"; that root belongs to Visual
    # Studio Code, not to this bundle, so the fold stays closed (B1-05).
    [[ "$result" != *"Application Support/Code"* ]] || return 1
    [[ "$result" != *"Preferences/Code.plist"* ]]
}

@test "find_app_files folds only an interior dot between two non-dot characters" {
    mkdir -p "$HOME/Library/Application Support/Foo..Bar" \
        "$HOME/Library/Application Support/FooBar"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$HOME/apps" \
        find_app_files "com.acme.foobar" "Foo..Bar")

    # "Foo..Bar" names no dotless product, so it keeps only its literal path.
    list_has_path "$result" "$HOME/Library/Application Support/Foo..Bar" || return 1
    [[ "$result" != *"Application Support/FooBar"* ]]
}