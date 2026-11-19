#!/usr/bin/env bats

load helpers/common

# B2-07: mole_playcover_alias_target treated every regular entry in a
# ~/Applications/PlayCover launcher alias as foreign unless it was .DS_Store or
# an Info.plist copy carrying the bundle's id. A PlayCover alias is a directory
# of links into one installed bundle, and PlayCover already copies Info.plist
# instead of linking it since the macOS 27 change; when it copies anything else
# (the App Store receipt iTunesMetadata.plist, a real icon) the strict entry
# check failed closed and the whole alias stayed out of the uninstall list, so
# ~/Applications/PlayCover/<name>.app was left behind.
#
# The fix keeps the ownership test but reads it per entry: a regular entry is
# accepted only when the same-named entry of the very bundle it links to is a
# regular file with identical bytes. A same-named file with other bytes, a real
# subdirectory, or any entry the bundle does not carry still fails closed.
#
# Fixtures live in a throwaway HOME; nothing here touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B2-07
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

# A flat PlayCover bundle with the root files PlayCover itself copies into an
# alias: Info.plist plus an App Store receipt and an icon.
make_playcover_bundle() {
    local bundle="$HOME/Library/Containers/io.playcover.PlayCover/Applications/fit.mole.probe.app"
    mkdir -p "$bundle"
    cat > "$bundle/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>fit.mole.probe</string>
<key>CFBundleExecutable</key><string>MoleProbe</string>
</dict></plist>
PLIST
    printf 'MACH-O MOLE PROBE\n' > "$bundle/MoleProbe"
    printf 'ICON BYTES\n' > "$bundle/AppIcon.icns"
    printf 'RECEIPT BYTES\n' > "$bundle/iTunesMetadata.plist"
    printf '%s\n' "$bundle"
}

# A launcher alias for that bundle: every item is a link back into the bundle
# except Info.plist, which PlayCover copies.
make_playcover_alias() {
    local bundle="$1" alias="$HOME/Applications/PlayCover/Mole Probe.app"
    mkdir -p "$alias"
    ln -s "$bundle/MoleProbe" "$alias/MoleProbe"
    cp "$bundle/Info.plist" "$alias/Info.plist"
    printf '%s\n' "$alias"
}

@test "find_app_files keeps a PlayCover alias that copies the bundle's icon and receipt" {
    local bundle alias
    bundle=$(make_playcover_bundle)
    alias=$(make_playcover_alias "$bundle")
    mkdir -p "$HOME/Library/Containers/io.playcover.PlayCover/App Settings"
    : > "$HOME/Library/Containers/io.playcover.PlayCover/App Settings/fit.mole.probe.plist"
    # PlayCover copies these instead of linking them: byte-identical to the
    # bundle's own root entries, so the alias still identifies that bundle.
    cp "$bundle/AppIcon.icns" "$alias/AppIcon.icns"
    cp "$bundle/iTunesMetadata.plist" "$alias/iTunesMetadata.plist"

    run find_app_files "fit.mole.probe" "Mole Probe" "$bundle"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"$alias"$'\n'* || "$output" == *"$alias" ]] || return 1
}

@test "find_app_files still refuses a PlayCover alias holding a foreign same-named file" {
    local bundle alias
    bundle=$(make_playcover_bundle)
    alias=$(make_playcover_alias "$bundle")
    # Same name as a bundle root entry, but not the bundle's bytes.
    printf 'SOME OTHER APP ICON\n' > "$alias/AppIcon.icns"
    # Not in the bundle at all: no owner can be proven for it.
    printf 'another app\n' > "$alias/Notes.txt"

    run find_app_files "fit.mole.probe" "Mole Probe" "$bundle"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"$alias"* ]]
}

@test "mole_playcover_alias_target proves copied entries by bytes, not by name" {
    local bundle alias
    bundle=$(make_playcover_bundle)
    alias=$(make_playcover_alias "$bundle")
    cp "$bundle/iTunesMetadata.plist" "$alias/iTunesMetadata.plist"
    run mole_playcover_alias_target "$alias"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "$bundle" ] || return 1

    # A different copy of the same name is another app's file.
    printf 'FOREIGN RECEIPT\n' > "$alias/iTunesMetadata.plist"
    run mole_playcover_alias_target "$alias"
    [ "$status" -ne 0 ]
}

@test "mole_playcover_alias_target refuses an alias with a real subdirectory" {
    local bundle alias
    bundle=$(make_playcover_bundle)
    alias=$(make_playcover_alias "$bundle")
    mkdir -p "$alias/PlugIns"

    run mole_playcover_alias_target "$alias"

    [ "$status" -ne 0 ]
}

@test "mole_playcover_alias_target still refuses a forged Info.plist copy" {
    local bundle alias
    bundle=$(make_playcover_bundle)
    alias=$(make_playcover_alias "$bundle")
    sed 's/fit\.mole\.probe/fit.mole.other/' "$bundle/Info.plist" > "$alias/Info.plist"

    run mole_playcover_alias_target "$alias"

    [ "$status" -ne 0 ]
}
