#!/usr/bin/env bats

load helpers/common

# B2-06: find_app_files only entered its PlayCover block when the installed
# bundle's folder name was literally "<bundle-id>.app" (AP:2449). PlayCover
# keys App Settings/, Keymapping/ and Entitlements/ by CFBundleIdentifier, and
# a bundle renamed in Finder ("原神.app", "Genshin Impact.app") keeps its id.
# For those bundles the whole block was skipped: the three settings files, the
# Keymapping/<id> folder and the ~/Applications/PlayCover launcher alias were
# all left behind.
#
# The fix keeps mole_is_playcover_app's layout proof and adds the bundle's own
# root Info.plist as the owner: an id read from it must equal the bundle id
# being uninstalled. The old folder-name test stays as the second proof, so a
# bundle whose plist cannot be read keeps exactly its previous behavior.
#
# Fixtures live in a throwaway HOME; nothing here touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B2-06
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

playcover_root() {
    printf '%s\n' "$HOME/Library/Containers/io.playcover.PlayCover"
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

# A flat PlayCover bundle under the given folder name carrying bundle_id.
make_playcover_bundle() {
    local name="$1" bundle_id="$2"
    local root bundle
    root=$(playcover_root)
    bundle="$root/Applications/$name"
    mkdir -p "$bundle"
    cat > "$bundle/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleExecutable</key><string>GameProbe</string>
</dict></plist>
PLIST
    printf 'MACH-O GAME PROBE\n' > "$bundle/GameProbe"
    printf '%s\n' "$bundle"
}

# The per-app settings PlayCover writes beside the bundle, all keyed by id.
make_playcover_settings() {
    local bundle_id="$1"
    local root
    root=$(playcover_root)
    mkdir -p "$root/App Settings" "$root/Keymapping/$bundle_id" "$root/Entitlements"
    : > "$root/App Settings/$bundle_id.plist"
    : > "$root/Keymapping/$bundle_id.plist"
    : > "$root/Keymapping/$bundle_id/default.plist"
    : > "$root/Entitlements/$bundle_id.plist"
}

# A launcher alias for that bundle: every entry links back into the bundle.
make_playcover_alias() {
    local bundle="$1" alias_name="$2"
    local alias="$HOME/Applications/PlayCover/$alias_name"
    mkdir -p "$alias"
    ln -s "$bundle/Info.plist" "$alias/Info.plist"
    ln -s "$bundle/GameProbe" "$alias/GameProbe"
    printf '%s\n' "$alias"
}

@test "B2-06 a PlayCover bundle renamed in Finder keeps its settings and alias" {
    local bundle alias root result
    bundle=$(make_playcover_bundle "原神.app" "com.miHoYo.GenshinImpact")
    make_playcover_settings "com.miHoYo.GenshinImpact"
    alias=$(make_playcover_alias "$bundle" "原神.app")
    root=$(playcover_root)

    run find_app_files "com.miHoYo.GenshinImpact" "原神" "$bundle"
    [ "$status" -eq 0 ]
    result="$output"

    # Before the fix every one of these was missing: the folder name is not
    # "<bundle-id>.app", so the whole PlayCover block was skipped.
    list_has_path "$result" "$root/App Settings/com.miHoYo.GenshinImpact.plist" || return 1
    list_has_path "$result" "$root/Keymapping/com.miHoYo.GenshinImpact.plist" || return 1
    list_has_path "$result" "$root/Entitlements/com.miHoYo.GenshinImpact.plist" || return 1
    list_has_path "$result" "$root/Keymapping/com.miHoYo.GenshinImpact" || return 1
    list_has_path "$result" "$alias"
}

@test "B2-06 a space-named PlayCover bundle gets the same leftovers" {
    local bundle alias root result
    bundle=$(make_playcover_bundle "Genshin Impact.app" "com.miHoYo.GenshinImpact")
    make_playcover_settings "com.miHoYo.GenshinImpact"
    alias=$(make_playcover_alias "$bundle" "Genshin Impact.app")
    root=$(playcover_root)

    run find_app_files "com.miHoYo.GenshinImpact" "Genshin Impact" "$bundle"
    [ "$status" -eq 0 ]
    result="$output"

    list_has_path "$result" "$root/App Settings/com.miHoYo.GenshinImpact.plist" || return 1
    list_has_path "$result" "$root/Keymapping/com.miHoYo.GenshinImpact" || return 1
    list_has_path "$result" "$alias"
}

@test "B2-06 a PlayCover bundle whose plist names another app claims nothing" {
    # Guard direction: the id in the bundle's own Info.plist must be this
    # uninstall's id. A differently named bundle carrying someone else's plist
    # (or no readable id) must not offer that app's settings or alias.
    local other result root
    other=$(make_playcover_bundle "Other Game.app" "com.example.othergame")
    make_playcover_settings "com.miHoYo.GenshinImpact"
    make_playcover_alias "$other" "Other Game.app"
    root=$(playcover_root)
    # An unreadable plist: neither proof holds, so the block stays closed.
    local broken
    broken=$(make_playcover_bundle "Broken Game.app" "com.example.brokengame")
    : > "$broken/Info.plist"

    run find_app_files "com.miHoYo.GenshinImpact" "Genshin Impact" "$other"
    [ "$status" -eq 0 ]
    result="$output"

    ! list_has_path "$result" "$root/App Settings/com.miHoYo.GenshinImpact.plist" || return 1
    ! list_has_path "$result" "$root/Keymapping/com.miHoYo.GenshinImpact" || return 1
    ! list_has_path "$result" "$HOME/Applications/PlayCover/Other Game.app" || return 1

    run find_app_files "com.example.brokengame" "Broken Game" "$broken"
    [ "$status" -eq 0 ]
    ! list_has_path "$output" "$root/App Settings/com.example.brokengame.plist" || return 1
    ! list_has_path "$output" "$HOME/Applications/PlayCover/Broken Game.app"
}

@test "B2-06 the conventional <bundle-id>.app PlayCover bundle still works" {
    # The folder-name proof stays, so a bundle whose plist id cannot be read
    # under its old name is unchanged; this is the pre-fix positive control.
    local bundle root result
    root=$(playcover_root)
    bundle="$root/Applications/fit.mole.probe.app"
    mkdir -p "$bundle"
    printf '%s\n' '<plist><dict><key>CFBundleIdentifier</key><string>fit.mole.probe</string></dict></plist>' \
        > "$bundle/Info.plist"
    : > "$bundle/MoleProbe"
    mkdir -p "$root/App Settings"
    : > "$root/App Settings/fit.mole.probe.plist"

    run find_app_files "fit.mole.probe" "Mole Probe" "$bundle"
    [ "$status" -eq 0 ]
    result="$output"

    list_has_path "$result" "$root/App Settings/fit.mole.probe.plist"
}
