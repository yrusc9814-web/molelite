#!/usr/bin/env bats

load helpers/common

# B1-09: find_app_files derived an electron-updater cache directory from the
# display name alone ("Code" -> "Code-updater", "Arc" -> "Arc-updater"). A
# "<productName>-updater" folder belongs to one Squirrel/electron-updater
# product, and ~/Library/Caches/* is removed without a prompt, so an unrelated
# "Code.app" or "Arc.app" took the real product's cache.
#
# The fix reads the updater cache name the bundle declares for itself in
# Contents/Resources/app-update.yml (updaterCacheDirName). A bundle that
# declares none has no ownership evidence and the folder stays. Two installed
# bundles that declare the same folder share it, so neither claims it.
# Fixtures live in a throwaway HOME; nothing here touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B1-09
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

# Make one bundle that declares an electron-updater cache directory.
make_bundle() {
    local path="$1" declared="${2:-}" bundle_id="${3:-}"
    mkdir -p "$path/Contents/Resources"
    if [[ -n "$bundle_id" ]]; then
        printf '%s\n' \
            '<plist><dict><key>CFBundleIdentifier</key>' \
            "<string>$bundle_id</string></dict></plist>" > "$path/Contents/Info.plist"
    fi
    if [[ -n "$declared" ]]; then
        printf 'provider: generic\nupdaterCacheDirName: %s\n' "$declared" \
            > "$path/Contents/Resources/app-update.yml"
    fi
}

# The two cache roots an updater folder can live under.
make_updater_fixtures() {
    local leaf="$1"
    mkdir -p "$HOME/Library/Caches/$leaf" \
        "$HOME/Library/Application Support/Caches/$leaf"
}

@test "B1-09 a Code.app without an updater config never claims Code-updater" {
    # Before the fix the display name alone offered both Caches/Code-updater
    # roots, and review.sh deletes Caches/* without asking.
    local apps="$HOME/apps"
    make_bundle "$apps/Code.app" "" "com.example.code"
    make_updater_fixtures "Code-updater"
    mkdir -p "$HOME/Library/Application Support/com.example.code"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.example.code" "Code" "$apps/Code.app")

    [[ "$result" != *"-updater"* ]] || return 1
    # The app's own bundle-id folders still belong to it.
    list_has_path "$result" "$HOME/Library/Application Support/com.example.code"
}

@test "B1-09 an Arc.app without an updater config never claims Arc-updater" {
    local apps="$HOME/apps"
    make_bundle "$apps/Arc.app" "" "company.thebrowser.Browser"
    make_updater_fixtures "Arc-updater"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "company.thebrowser.Browser" "Arc" "$apps/Arc.app")

    [[ "$result" != *"Arc-updater"* ]]
}

@test "B1-09 the declaring bundle still finds its own updater cache" {
    # A real electron-updater product must keep working: 1Password declares
    # "1Password-updater" and its cache is its own leftover.
    local apps="$HOME/apps"
    make_bundle "$apps/1Password.app" "1Password-updater" "com.1password.1password"
    make_updater_fixtures "1Password-updater"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.1password.1password" "1Password" "$apps/1Password.app")

    list_has_path "$result" "$HOME/Library/Caches/1Password-updater" || return 1
    list_has_path "$result" "$HOME/Library/Application Support/Caches/1Password-updater"
}

@test "B1-09 a declared name is not the display name's guess" {
    # The declaration wins: an app called "Gizmo" that declares "gizmo-desktop"
    # must not fall back to "gizmo-updater" for a different product.
    local apps="$HOME/apps"
    make_bundle "$apps/Gizmo.app" "gizmo-desktop-updater" "com.example.gizmo"
    make_updater_fixtures "Gizmo-updater"
    make_updater_fixtures "gizmo-desktop-updater"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.example.gizmo" "Gizmo" "$apps/Gizmo.app")

    [[ "$result" != *"Gizmo-updater"* ]] || return 1
    [[ "$result" != *"gizmo-updater"* ]] || return 1
    list_has_path "$result" "$HOME/Library/Caches/gizmo-desktop-updater"
}

@test "B1-09 two installed bundles declaring one cache leave it alone" {
    # Two Electron products built with one productName share the directory,
    # so while the other one is installed neither can claim it.
    local apps="$HOME/apps"
    make_bundle "$apps/Note.app" "Shared-updater" "com.example.note"
    make_bundle "$apps/Note Preview.app" "Shared-updater" "com.example.note.preview"
    make_updater_fixtures "Shared-updater"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.example.note" "Note" "$apps/Note.app")

    [[ "$result" != *"Shared-updater"* ]]
}

@test "B1-09 the app being removed is not its own sharing collision" {
    local apps="$HOME/apps"
    make_bundle "$apps/Note.app" "Shared-updater" "com.example.note"
    make_updater_fixtures "Shared-updater"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.example.note" "Note" "$apps/Note.app")

    list_has_path "$result" "$HOME/Library/Caches/Shared-updater"
}

@test "B1-09 a traversal or glob in the declaration is refused" {
    local apps="$HOME/apps"
    # A malformed or hostile app-update.yml must not widen the candidate path.
    make_bundle "$apps/Evil.app" "../../Documents" "com.example.evil"
    mkdir -p "$HOME/Documents" "$HOME/Library/Caches/Evil-updater"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.example.evil" "Evil" "$apps/Evil.app")

    [[ "$result" != *Documents* ]] || return 1
    [[ "$result" != *"Evil-updater"* ]]
}
