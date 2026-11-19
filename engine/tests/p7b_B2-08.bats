#!/usr/bin/env bats

load helpers/common

# B2-08: find(1) reads -name as a glob, so an app name pasted into a pattern
# was treated as a pattern, not a literal. "Foo[1]" matched another app's
# "Foo1_<UUID>.plist" in CrashReporter and missed its own literal
# "Foo[1]_<UUID>.plist"; the JetBrains scan had the same problem with
# "GoLand [EAP]" versus "GoLand E2024.1".
#
# The fix escapes find metacharacters before composing every app-name -name
# pattern. These cases pin the own/foreign split for '[' and '?' and cover the
# JetBrains scan with a bundle id that gets no help from the vendor-token path.

setup_file() {
    mole_test_setup_home p7b-B2-08
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

@test "find_app_files keeps the app's bracketed CrashReporter plist and drops Foo1" {
    local crash="$HOME/Library/Application Support/CrashReporter"
    mkdir -p "$crash"
    : > "$crash/Foo[1]_OWN.plist"
    : > "$crash/Foo1_OTHER.plist"

    run find_app_files "com.example.foo1" "Foo[1]"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Foo[1]_OWN.plist"* ]] || return 1
    [[ "$output" != *"Foo1_OTHER.plist"* ]]
}

@test "find_app_files treats ? literally in CrashReporter names" {
    local crash="$HOME/Library/Application Support/CrashReporter"
    mkdir -p "$crash"
    : > "$crash/Foo?Bar_OWN.plist"
    : > "$crash/FooXBar_OTHER.plist"

    run find_app_files "com.example.fooxbar" "Foo?Bar"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Foo?Bar_OWN.plist"* ]] || return 1
    [[ "$output" != *"FooXBar_OTHER.plist"* ]]
}

@test "find_app_files finds the literal bracketed JetBrains product directory" {
    # JetBrains roots are only reachable through JetBrains' own bundle id
    # (B1-13), so the id here must be com.jetbrains.*; the product token stays
    # unrelated so the vendor-token scan cannot reach the directory and the
    # escaped -name pattern is still what has to match the bracket literally.
    local jetbrains="$HOME/Library/Application Support/JetBrains"
    mkdir -p "$jetbrains/GoLand [EAP]2024.1" "$jetbrains/GoLand E2024.1"

    run find_app_files "com.jetbrains.custom" "GoLand [EAP]"

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"GoLand [EAP]2024.1"* ]] || return 1
    [[ "$output" != *"GoLand E2024.1"* ]]
}