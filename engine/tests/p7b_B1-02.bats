#!/usr/bin/env bats

load helpers/common

# B1-02: "Application Support/Godot" is one shared root for the whole Godot
# ecosystem: app_userdata/<project> holds every Godot game's save data and
# export_templates holds the editor's export templates. The old rule claimed
# the whole root for the Godot editor itself, and the unanchored
# `=~ Godot|godot` name test also fired for an exported game such as
# MyGodotGame. Neither app owns the root, so uninstall must not offer it.
#
# Fixtures live in a throwaway HOME; nothing here touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B1-02
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

# The shared engine root plus the two contents that prove it is user data:
# every game's saves and the editor's export templates.
make_godot_shared_root() {
    mkdir -p "$HOME/Library/Application Support/Godot/app_userdata/MyProject"
    : > "$HOME/Library/Application Support/Godot/app_userdata/MyProject/save.dat"
    mkdir -p "$HOME/Library/Application Support/Godot/export_templates/4.3.stable"
}

@test "B1-02 uninstalling the Godot editor does not claim the shared Godot root" {
    make_godot_shared_root
    mkdir -p "$HOME/Library/Caches/org.godotengine.godot"

    run find_app_files "org.godotengine.godot" "Godot"
    [ "$status" -eq 0 ]

    # The old rule queued the whole root, saves and export templates included.
    ! list_has_path "$output" "$HOME/Library/Application Support/Godot" || return 1
    # Its own exact cache leaf stays reachable.
    list_has_path "$output" "$HOME/Library/Caches/org.godotengine.godot" || return 1
    # The user data is still on disk: the scan only refuses to claim it.
    [ -f "$HOME/Library/Application Support/Godot/app_userdata/MyProject/save.dat" ]
    [ -d "$HOME/Library/Application Support/Godot/export_templates/4.3.stable" ]
}

@test "B1-02 an exported game whose name contains godot does not claim the shared root" {
    make_godot_shared_root
    mkdir -p "$HOME/Library/Application Support/MyGodotGame"
    mkdir -p "$HOME/Library/Caches/com.example.mygodotgame"

    run find_app_files "com.example.mygodotgame" "MyGodotGame"
    [ "$status" -eq 0 ]

    # The `=~ Godot|godot` substring test used to fire for this name too.
    ! list_has_path "$output" "$HOME/Library/Application Support/Godot" || return 1
    # Its own name and bundle-id leaves are unaffected.
    list_has_path "$output" "$HOME/Library/Application Support/MyGodotGame" || return 1
    list_has_path "$output" "$HOME/Library/Caches/com.example.mygodotgame" || return 1
    [ -f "$HOME/Library/Application Support/Godot/app_userdata/MyProject/save.dat" ]
}

@test "B1-02 the uninstall protection policy refuses the shared Godot root" {
    make_godot_shared_root
    mkdir -p "$HOME/Library/Application Support/godot"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
MOLE_UNINSTALL_MODE=1 should_protect_path "$HOME/Library/Application Support/Godot" || exit 1
MOLE_UNINSTALL_MODE=1 should_protect_path "$HOME/Library/Application Support/godot" || exit 1
# Exact root only: a similarly named sibling stays eligible, matching the
# Unity and Epic roots beside it.
if MOLE_UNINSTALL_MODE=1 should_protect_path "$HOME/Library/Application Support/GodotCompanion"; then
    echo "too broad"
    exit 1
fi
EOF
    [ "$status" -eq 0 ]
    [[ "$output" != *"too broad"* ]]
}

@test "B1-02 a lowercase app name cannot reach the root through the case-insensitive spelling" {
    make_godot_shared_root

    # APFS is case-insensitive, so an app named "godot" would derive
    # "Application Support/godot": the same directory, different spelling.
    run find_app_files "com.example.godotlauncher" "godot"
    [ "$status" -eq 0 ]

    ! list_has_path "$output" "$HOME/Library/Application Support/godot" || return 1
    ! list_has_path "$output" "$HOME/Library/Application Support/Godot" || return 1
    [ -f "$HOME/Library/Application Support/Godot/app_userdata/MyProject/save.dat" ]
}
