#!/usr/bin/env bats

load helpers/common

# B1-13: the JetBrains leftover rule in find_app_files triggered on the display
# name alone (/IntelliJ|PyCharm|WebStorm|GoLand|RubyMine|PhpStorm|CLion|
# DataGrip|Rider/) as well as on an unanchored /jetbrains/ bundle-id substring.
# So uninstalling any "Rider.app" swept the real JetBrains IDE's
# ~/Library/Application Support/JetBrains/Rider2024.1 (keymaps, plugins and
# licence state), Caches/JetBrains/Rider2024.1 and Logs/JetBrains/Rider2024.1.
#
# The fix requires JetBrains' own com.jetbrains.* bundle id for the name arm.
# An unrelated id keeps only its exact bundle-id paths. Fixtures live in a
# throwaway HOME; nothing here touches a real Library.

setup_file() {
    mole_test_setup_home p7b-B1-13
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

# One bundle whose Info.plist declares the given id and executable name.
make_bundle() {
    local path="$1" bundle_id="$2" exec_name="${3:-}"
    mkdir -p "$path/Contents/MacOS"
    {
        printf '%s\n' '<plist version="1.0"><dict>'
        printf '  <key>CFBundleIdentifier</key><string>%s</string>\n' "$bundle_id"
        if [[ -n "$exec_name" ]]; then
            printf '  <key>CFBundleExecutable</key><string>%s</string>\n' "$exec_name"
        fi
        printf '%s\n' '</dict></plist>'
    } > "$path/Contents/Info.plist"
}

# The three JetBrains roots, each holding one versioned IDE leaf.
make_jetbrains_fixtures() {
    local leaf="$1"
    mkdir -p "$HOME/Library/Application Support/JetBrains/$leaf" \
        "$HOME/Library/Caches/JetBrains/$leaf" \
        "$HOME/Library/Logs/JetBrains/$leaf"
}

@test "B1-13 an unrelated Rider.app does not claim the real IDE's JetBrains leaves" {
    # Before the fix the name arm matched "Rider" and all three leaves were
    # queued for removal without any ownership proof.
    local apps="$HOME/apps"
    make_bundle "$apps/Rider.app" "com.acme.rider" "Rider"
    make_jetbrains_fixtures Rider2024.1

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.rider" "Rider" "$apps/Rider.app")

    ! list_has_path "$result" "$HOME/Library/Application Support/JetBrains/Rider2024.1" || return 1
    ! list_has_path "$result" "$HOME/Library/Caches/JetBrains/Rider2024.1" || return 1
    ! list_has_path "$result" "$HOME/Library/Logs/JetBrains/Rider2024.1"
}

@test "B1-13 a lookalike PyCharm.app with a foreign id claims no JetBrains leaf" {
    # The same hole covered every product word in the regex, so any bundle
    # displayed as "PyCharm" took PyCharm's own settings and licence state.
    local apps="$HOME/apps"
    make_bundle "$apps/PyCharm.app" "com.example.pycharm" "PyCharm"
    make_jetbrains_fixtures PyCharm2024.1

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.example.pycharm" "PyCharm" "$apps/PyCharm.app")

    ! list_has_path "$result" "$HOME/Library/Application Support/JetBrains/PyCharm2024.1" || return 1
    ! list_has_path "$result" "$HOME/Library/Caches/JetBrains/PyCharm2024.1"
}

@test "B1-13 an id that merely contains jetbrains is not ownership" {
    # The old arm was an unanchored /jetbrains/ substring, so a vendor that
    # happens to spell the word inside its own id was treated as JetBrains.
    local apps="$HOME/apps"
    make_bundle "$apps/Rider.app" "com.notjetbrains.rider" "Rider"
    make_jetbrains_fixtures Rider2024.1

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.notjetbrains.rider" "Rider" "$apps/Rider.app")

    ! list_has_path "$result" "$HOME/Library/Application Support/JetBrains/Rider2024.1"
}

@test "B1-13 JetBrains' own Rider still reclaims its exact versioned leaves" {
    # The fix must not stop a real JetBrains uninstall from reclaiming its own
    # settings; only the exact product+version leaf is claimed.
    local apps="$HOME/apps"
    make_bundle "$apps/Rider.app" "com.jetbrains.rider" "rider"
    make_jetbrains_fixtures Rider2024.1
    mkdir -p "$HOME/Library/Application Support/JetBrains/Rider2024.1-backup"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.jetbrains.rider" "Rider" "$apps/Rider.app")

    list_has_path "$result" "$HOME/Library/Application Support/JetBrains/Rider2024.1" || return 1
    list_has_path "$result" "$HOME/Library/Caches/JetBrains/Rider2024.1" || return 1
    list_has_path "$result" "$HOME/Library/Logs/JetBrains/Rider2024.1" || return 1
    # A backup folder is not a version leaf the IDE owns.
    ! list_has_path "$result" "$HOME/Library/Application Support/JetBrains/Rider2024.1-backup"
}

@test "B1-13 a mixed-case JetBrains id is still recognized" {
    # JetBrains ids arrive with inconsistent casing; the ownership test folds
    # ASCII case in-process, like the selector branch already did.
    local apps="$HOME/apps"
    make_bundle "$apps/Rider.app" "COM.JETBRAINS.rider" "rider"
    make_jetbrains_fixtures Rider2024.1

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "COM.JETBRAINS.rider" "Rider" "$apps/Rider.app")

    list_has_path "$result" "$HOME/Library/Application Support/JetBrains/Rider2024.1"
}

@test "B1-13 an unrelated app still keeps its own exact bundle-id leftovers" {
    # The fix narrows the JetBrains name arm only: an ordinary app must still
    # collect paths that carry its own bundle id, so nothing else regresses.
    local apps="$HOME/apps"
    make_bundle "$apps/Rider.app" "com.acme.rider" "Rider"
    mkdir -p "$HOME/Library/Caches/com.acme.rider" "$HOME/Library/Preferences"
    : > "$HOME/Library/Preferences/com.acme.rider.plist"
    make_jetbrains_fixtures Rider2024.1

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.rider" "Rider" "$apps/Rider.app")

    list_has_path "$result" "$HOME/Library/Caches/com.acme.rider" || return 1
    list_has_path "$result" "$HOME/Library/Preferences/com.acme.rider.plist" || return 1
    ! list_has_path "$result" "$HOME/Library/Application Support/JetBrains/Rider2024.1"
}
