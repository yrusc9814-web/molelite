#!/usr/bin/env bats

load helpers/common

# B1-15: ByHost preferences are named "<domain>.<host-uuid>.plist". The scan
# used mole_name_starts_with_bundle_id_boundary, a dot-boundary prefix test, so
# uninstalling Foo.app (com.acme.Foo) also claimed
# "com.acme.Foo.Bar.<uuid>.plist" -- the domain of Foo Bar.app
# (com.acme.Foo.Bar), a different product of the same vendor. The same held
# for an embedded extension id's "<id>.*.plist" pattern. Both are personal
# rows, so "--with-data" preselected another app's preferences for deletion.
#
# The fix requires the exact "<id>.<uuid>.plist" shape: one UUID segment
# between the bundle id and the extension, and nothing else. A suffix that is
# not a UUID stays on disk, because a name alone cannot prove ownership.
#
# Fixtures live in a throwaway HOME; nothing here touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B1-15
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
    # The sibling app bundles below live here, so the installed-app probes see
    # the same coexistence the risk report describes.
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

OWN_HOST_UUID="11111111-2222-3333-4444-555555555555"
OTHER_HOST_UUID="66666666-7777-8888-9999-000000000000"

# Foo.app owns com.acme.Foo; Foo Bar.app owns the longer com.acme.Foo.Bar.
make_foo_fixtures() {
    local byhost="$HOME/Library/Preferences/ByHost"
    mkdir -p "$byhost" "$HOME/Applications/Foo.app" "$HOME/Applications/Foo Bar.app"
    : > "$byhost/com.acme.Foo.$OWN_HOST_UUID.plist"
    : > "$byhost/com.acme.Foo.Bar.$OTHER_HOST_UUID.plist"
}

@test "B1-15 does not claim a sibling product's ByHost preference" {
    make_foo_fixtures

    run find_app_files "com.acme.Foo" "Foo" "$HOME/Applications/Foo.app"

    [ "$status" -eq 0 ] || return 1
    list_has_path "$output" "$HOME/Library/Preferences/ByHost/com.acme.Foo.$OWN_HOST_UUID.plist" || return 1
    # Before the fix the dot-boundary prefix test queued this one too.
    ! list_has_path "$output" "$HOME/Library/Preferences/ByHost/com.acme.Foo.Bar.$OTHER_HOST_UUID.plist" || return 1
    # The scan only refuses to claim it; it never deletes.
    [ -f "$HOME/Library/Preferences/ByHost/com.acme.Foo.Bar.$OTHER_HOST_UUID.plist" ]
}

@test "B1-15 does not claim an embedded extension's sibling ByHost preference" {
    local app="$HOME/Applications/Foo.app"
    local widget="$app/Contents/PlugIns/Share.appex/Contents"
    local byhost="$HOME/Library/Preferences/ByHost"
    mkdir -p "$widget" "$byhost"
    cat > "$widget/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key>
  <string>com.acme.Foo.Share</string>
</dict></plist>
PLIST
    : > "$byhost/com.acme.Foo.Share.$OWN_HOST_UUID.plist"
    : > "$byhost/com.acme.Foo.Share.Bar.$OTHER_HOST_UUID.plist"

    run find_app_files "com.acme.Foo" "Foo" "$app"

    [ "$status" -eq 0 ] || return 1
    # The extension still owns its own preference...
    list_has_path "$output" "$byhost/com.acme.Foo.Share.$OWN_HOST_UUID.plist" || return 1
    # ...but not the longer domain of com.acme.Foo.Share.Bar.
    ! list_has_path "$output" "$byhost/com.acme.Foo.Share.Bar.$OTHER_HOST_UUID.plist" || return 1
    [ -f "$byhost/com.acme.Foo.Share.Bar.$OTHER_HOST_UUID.plist" ]
}

@test "B1-15 a non-UUID ByHost suffix is left on disk" {
    local byhost="$HOME/Library/Preferences/ByHost"
    mkdir -p "$byhost"
    : > "$byhost/com.acme.Foo.$OWN_HOST_UUID.plist"
    # A by-host file whose host segment is not a UUID names no host this app
    # can prove, so the ambiguous name is not claimed.
    : > "$byhost/com.acme.Foo.ABC123.plist"
    : > "$byhost/com.acme.Foo.insiders.$OTHER_HOST_UUID.plist"

    run find_app_files "com.acme.Foo" "Foo"

    [ "$status" -eq 0 ] || return 1
    list_has_path "$output" "$byhost/com.acme.Foo.$OWN_HOST_UUID.plist" || return 1
    ! list_has_path "$output" "$byhost/com.acme.Foo.ABC123.plist" || return 1
    ! list_has_path "$output" "$byhost/com.acme.Foo.insiders.$OTHER_HOST_UUID.plist" || return 1
    [ -f "$byhost/com.acme.Foo.ABC123.plist" ]
}

@test "B1-15 an uppercase UUID host segment is still claimed" {
    local byhost="$HOME/Library/Preferences/ByHost"
    local upper="A1B2C3D4-E5F6-7890-ABCD-EF0123456789"
    mkdir -p "$byhost"
    : > "$byhost/com.acme.Foo.$upper.plist"

    run find_app_files "com.acme.Foo" "Foo"

    [ "$status" -eq 0 ] || return 1
    list_has_path "$output" "$byhost/com.acme.Foo.$upper.plist"
}

@test "B1-15 the exact Preferences plist match is unchanged" {
    local prefs="$HOME/Library/Preferences"
    mkdir -p "$prefs"
    : > "$prefs/com.acme.Foo.plist"
    : > "$prefs/com.acme.Foo.Bar.plist"

    run find_app_files "com.acme.Foo" "Foo"

    [ "$status" -eq 0 ] || return 1
    # A top-level Preferences file is an exact domain, so it stays claimed;
    # a longer domain belongs to the other product.
    list_has_path "$output" "$prefs/com.acme.Foo.plist" || return 1
    ! list_has_path "$output" "$prefs/com.acme.Foo.Bar.plist"
}

@test "B1-15 the ownership helper refuses a plist outside ByHost" {
    local prefs="$HOME/Library/Preferences"
    mkdir -p "$prefs"
    : > "$prefs/com.acme.Foo.$OWN_HOST_UUID.plist"

    # Guard: the helper must exist, so its refusal below is a real refusal and
    # not a missing-command status.
    declare -F mole_uninstall_byhost_plist_owned > /dev/null || return 1

    run mole_uninstall_byhost_plist_owned "$prefs/com.acme.Foo.$OWN_HOST_UUID.plist" "com.acme.Foo"

    [ "$status" -eq 1 ]
}
