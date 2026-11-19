#!/usr/bin/env bats

load helpers/common

# B2-13: "Foo (Beta).app" stores its data as "Foo Beta"/"Foo-Beta"/"FooBeta".
# The old variants folded the parentheses into "Foo(Beta)", "Foo-(Beta)" and
# "Foo_(Beta)", and the suffix table could not strip "(Beta)", so the real
# directories were never discovered.

setup_file() {
    mole_test_setup_home p7b-B2-13
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

@test "find_app_files reaches Foo Beta and Foo-Beta for Foo (Beta)" {
    mkdir -p "$HOME/Library/Application Support/Foo Beta"
    mkdir -p "$HOME/Library/Caches/Foo Beta"
    mkdir -p "$HOME/Library/Application Support/Foo-Beta"
    mkdir -p "$HOME/Library/Preferences"
    touch "$HOME/Library/Preferences/Foo-Beta.plist"

    local result
    result=$(find_app_files "com.example.foo" "Foo (Beta)")

    [[ "$result" == *"Library/Application Support/Foo Beta"* ]] || return 1
    [[ "$result" == *"Library/Caches/Foo Beta"* ]] || return 1
    [[ "$result" == *"Library/Application Support/Foo-Beta"* ]] || return 1
    [[ "$result" == *"Library/Preferences/Foo-Beta.plist"* ]]
}

@test "find_app_files strips a parenthesized channel to the Foo base name" {
    mkdir -p "$HOME/Library/Application Support/Foo"
    mkdir -p "$HOME/.config/foo"

    local result
    result=$(find_app_files "com.example.foo" "Foo (Beta)")

    [[ "$result" == *"Library/Application Support/Foo"* ]] || return 1
    [[ "$result" == *".config/foo"* ]]
}

@test "find_app_files strips a hyphen channel to the Foo base name" {
    mkdir -p "$HOME/Library/Caches/Foo"

    local result
    result=$(find_app_files "com.example.foo" "Foo-Beta")

    [[ "$result" == *"Library/Caches/Foo"* ]]
}

@test "find_app_files no longer treats Foo-(Beta) or Foo_(Beta) as variants" {
    mkdir -p "$HOME/Library/Application Support/Foo-(Beta)"
    mkdir -p "$HOME/Library/Application Support/Foo_(Beta)"
    mkdir -p "$HOME/Library/Application Support/Foo(Beta)"

    local result
    result=$(find_app_files "com.example.foo" "Foo (Beta)")

    [[ "$result" != *"Application Support/Foo-(Beta)"* ]] || return 1
    [[ "$result" != *"Application Support/Foo_(Beta)"* ]] || return 1
    [[ "$result" != *"Application Support/Foo(Beta)"* ]]
}

@test "find_app_files leaves Foo to an installed Foo.app while removing Foo (Beta)" {
    local apps="$HOME/apps"
    mkdir -p "$apps/Foo.app"
    mkdir -p "$HOME/Library/Application Support/Foo"
    mkdir -p "$HOME/Library/Application Support/Foo Beta"

    local result
    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.example.foo.beta" "Foo (Beta)" "$apps/Foo (Beta).app")

    ! printf '%s\n' "$result" | grep -Fxq "$HOME/Library/Application Support/Foo" || return 1
    [[ "$result" == *"Library/Application Support/Foo Beta"* ]]
}

@test "uninstall_strip_version_suffix mirrors the folded channel forms" {
    run /bin/bash --noprofile --norc <<EOF
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
uninstall_strip_version_suffix "Foo (Beta)"
uninstall_strip_version_suffix "Foo-Beta"
EOF

    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Foo" ]
    [ "${lines[1]}" = "Foo" ]
}
