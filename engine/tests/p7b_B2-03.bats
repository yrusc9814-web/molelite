#!/usr/bin/env bats

load helpers/common

# B2-03: a bundle name that spells its word break with the ideographic space
# (U+3000) never reached the folded variants "Foo Bar", "FooBar", "Foo-Bar"
# or "Foo_Bar", because the variant folds replace ASCII spaces only and
# [[:space:]] does not reliably classify U+3000. Those leftover directories
# stayed on disk. The literal name with the wide character must keep working,
# and a folded spelling owned by another installed bundle must still be
# refused by the existing B1-07 guard.

setup_file() {
    mole_test_setup_home p7b-B2-03
    source "$PROJECT_ROOT/lib/core/base.sh"
    source "$PROJECT_ROOT/lib/core/log.sh"
    source "$PROJECT_ROOT/lib/core/app_protection.sh"
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

@test "B2-03 ideographic-space name finds the ASCII-space folder" {
    mkdir -p "$HOME/Library/Application Support/Foo Bar"
    echo "test" > "$HOME/Library/Application Support/Foo Bar/data.db"

    result=$(find_app_files "com.example.foobar" "Foo　Bar")

    [[ "$result" == *"Library/Application Support/Foo Bar"* ]]
}

@test "B2-03 ideographic-space name finds folded folders and keeps the literal one" {
    mkdir -p "$HOME/Library/Application Support/Foo　Bar"
    mkdir -p "$HOME/Library/Caches/FooBar"
    mkdir -p "$HOME/Library/Preferences"
    echo "test" > "$HOME/Library/Application Support/Foo　Bar/data.db"
    echo "test" > "$HOME/Library/Caches/FooBar/cache.db"
    echo "test" > "$HOME/Library/Preferences/Foo-Bar.plist"

    result=$(find_app_files "com.example.foobar" "Foo　Bar")

    [[ "$result" == *"Library/Application Support/Foo　Bar"* ]] || return 1
    [[ "$result" == *"Library/Caches/FooBar"* ]] || return 1
    [[ "$result" == *"Library/Preferences/Foo-Bar.plist"* ]]
}

@test "B2-03 folded guard still keeps folders of an installed FooBar.app" {
    mkdir -p "$HOME/apps/FooBar.app"
    mkdir -p "$HOME/Library/Application Support/Foo Bar"
    mkdir -p "$HOME/Library/Caches/FooBar"
    mkdir -p "$HOME/Library/Preferences"
    echo "test" > "$HOME/Library/Application Support/Foo Bar/data.db"
    echo "test" > "$HOME/Library/Caches/FooBar/cache.db"
    echo "test" > "$HOME/Library/Preferences/FooBar.plist"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$HOME/apps" \
        find_app_files "com.example.foobar" "Foo　Bar")

    [[ "$result" != *"Library/Caches/FooBar"* ]] || return 1
    [[ "$result" != *"Library/Preferences/FooBar.plist"* ]]
}

@test "B2-03 spaced guard keeps folders of an installed Foo Bar.app" {
    mkdir -p "$HOME/apps/Foo Bar.app"
    mkdir -p "$HOME/Library/Application Support/Foo Bar"
    echo "test" > "$HOME/Library/Application Support/Foo Bar/data.db"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$HOME/apps" \
        find_app_files "com.example.foobar" "Foo　Bar")

    [[ "$result" != *"Library/Application Support/Foo Bar"* ]]
}

@test "B2-03 ASCII-space names are unchanged" {
    mkdir -p "$HOME/Library/Application Support/Maestro Studio"
    mkdir -p "$HOME/Library/Application Support/MaestroStudio"
    echo "test" > "$HOME/Library/Application Support/Maestro Studio/data.db"
    echo "test" > "$HOME/Library/Application Support/MaestroStudio/data.db"

    result=$(find_app_files "com.maestro.studio" "Maestro Studio")

    [[ "$result" == *"Library/Application Support/Maestro Studio"* ]] || return 1
    [[ "$result" == *"Library/Application Support/MaestroStudio"* ]]
}