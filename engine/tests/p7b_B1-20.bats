#!/usr/bin/env bats

load helpers/common

# B1-20: CrashReporter plists are named "<app name>_<UUID>.plist", and the
# scan used a bare "<app name>_*.plist" glob. With "Foo.app" and
# "Foo_Bar.app" both installed, the latter's "Foo_Bar_<UUID>.plist" starts
# with "Foo_" and was claimed (and deleted with --with-data); "Foo_Insiders"
# was hit the same way. The app name must end at the "_" before the UUID:
# an underscore left in the suffix means the prefix was only part of another
# app's name. Fixtures live in a throwaway HOME; nothing here touches the
# real Library.
#
# The last case pins the other direction: an app whose own name contains an
# underscore ("Foo_Bar.app") still owns "Foo_Bar_<UUID>.plist", so the
# boundary must not turn every suffix underscore into a refusal.

setup_file() {
    mole_test_setup_home p7b-B1-20
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
    # The sibling app bundles below live here, so the installed-app probes
    # see the same coexistence the risk report describes.
    export MOLE_TEST_APP_FAMILY_ROOT="$HOME/Applications"
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

@test "B1-20 does not claim a sibling app's CrashReporter plist when both are installed" {
    local crash="$HOME/Library/Application Support/CrashReporter"
    mkdir -p "$crash" "$HOME/Applications/Foo.app" "$HOME/Applications/Foo_Bar.app"
    : > "$crash/Foo_OWN-UUID.plist"
    : > "$crash/Foo_Bar_OTHER-UUID.plist"

    run find_app_files "com.example.foo" "Foo" "$HOME/Applications/Foo.app"

    [ "$status" -eq 0 ] || return 1
    list_has_path "$output" "$crash/Foo_OWN-UUID.plist" || return 1
    # Before the fix the bare "Foo_*" glob queued this one too.
    ! list_has_path "$output" "$crash/Foo_Bar_OTHER-UUID.plist" || return 1
    # The scan only refuses to claim it; it never deletes.
    [ -f "$crash/Foo_Bar_OTHER-UUID.plist" ]
}

@test "B1-20 does not claim an Insiders build's CrashReporter plist" {
    local crash="$HOME/Library/Application Support/CrashReporter"
    mkdir -p "$crash" "$HOME/Applications/Foo.app" "$HOME/Applications/Foo_Insiders.app"
    : > "$crash/Foo_INSIDERS-UUID.plist"
    : > "$crash/Foo_Insiders_OWN-UUID.plist"

    run find_app_files "com.example.foo" "Foo" "$HOME/Applications/Foo.app"

    [ "$status" -eq 0 ] || return 1
    ! list_has_path "$output" "$crash/Foo_Insiders_OWN-UUID.plist" || return 1
    list_has_path "$output" "$crash/Foo_INSIDERS-UUID.plist"
}

@test "B1-20 keeps spaced and unspaced own plists but drops a foreign suffix" {
    local crash="$HOME/Library/Application Support/CrashReporter"
    mkdir -p "$crash"
    : > "$crash/Foo Bar_OWN-SPACED.plist"
    : > "$crash/FooBar_OWN-NOSPACE.plist"
    : > "$crash/FooBar_Baz_OTHER.plist"

    run find_app_files "com.example.foo.bar" "Foo Bar"

    [ "$status" -eq 0 ] || return 1
    list_has_path "$output" "$crash/Foo Bar_OWN-SPACED.plist" || return 1
    list_has_path "$output" "$crash/FooBar_OWN-NOSPACE.plist" || return 1
    ! list_has_path "$output" "$crash/FooBar_Baz_OTHER.plist"
}

@test "B1-20 still claims an underscored bundle name's own CrashReporter plist" {
    local crash="$HOME/Library/Application Support/CrashReporter"
    mkdir -p "$crash" "$HOME/Applications/Foo_Bar.app"
    : > "$crash/Foo_Bar_OWN-UUID.plist"
    : > "$crash/Foo_Bar_Extra_OTHER-UUID.plist"

    run find_app_files "com.example.foo_bar" "Foo_Bar" "$HOME/Applications/Foo_Bar.app"

    [ "$status" -eq 0 ] || return 1
    list_has_path "$output" "$crash/Foo_Bar_OWN-UUID.plist" || return 1
    ! list_has_path "$output" "$crash/Foo_Bar_Extra_OTHER-UUID.plist"
}

@test "B1-20 refuses a name-only match whose plist names another app" {
    local crash="$HOME/Library/Application Support/CrashReporter"
    mkdir -p "$crash"
    cat > "$crash/Foo_OWN-UUID.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.foo</string>
</dict></plist>
PLIST
    cat > "$crash/Foo_STALE-UUID.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.other</string>
</dict></plist>
PLIST

    run find_app_files "com.example.foo" "Foo"

    [ "$status" -eq 0 ] || return 1
    list_has_path "$output" "$crash/Foo_OWN-UUID.plist" || return 1
    ! list_has_path "$output" "$crash/Foo_STALE-UUID.plist"
}