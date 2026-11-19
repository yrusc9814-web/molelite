#!/usr/bin/env bats

load helpers/common

# B1-01: "Microsoft Edge" must not lose its product word to the channel-suffix
# table. Stripping "Edge" derived the shared vendor root "Microsoft", so an
# Edge uninstall offered ~/Library/Application Support/Microsoft (Office,
# Teams, OneDrive), Caches/Microsoft, Logs/Microsoft,
# Preferences/Microsoft.plist and the lowercase XDG roots for deletion.
#
# Fixtures live in a throwaway HOME; nothing here touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B1-01
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

# The shared vendor root plus every name-derived path the old suffix table
# produced from "Microsoft Edge" -> base "Microsoft".
make_vendor_root_fixtures() {
    mkdir -p "$HOME/Library/Application Support/Microsoft/Office"
    mkdir -p "$HOME/Library/Caches/Microsoft"
    mkdir -p "$HOME/Library/Logs/Microsoft"
    mkdir -p "$HOME/Library/Preferences"
    : > "$HOME/Library/Preferences/Microsoft.plist"
    mkdir -p "$HOME/.config/microsoft"
    mkdir -p "$HOME/.cache/microsoft"
    mkdir -p "$HOME/.local/share/microsoft"
}

make_edge_fixtures() {
    mkdir -p "$HOME/Library/Application Support/Microsoft Edge/Default"
    mkdir -p "$HOME/Library/Caches/Microsoft Edge"
    mkdir -p "$HOME/Library/Logs/Microsoft Edge"
    : > "$HOME/Library/Preferences/Microsoft Edge.plist"
    mkdir -p "$HOME/.config/microsoft-edge"
    mkdir -p "$HOME/.local/share/microsoft-edge"
}

@test "B1-01 find_app_files does not claim the shared Microsoft vendor root for Microsoft Edge" {
    make_vendor_root_fixtures
    make_edge_fixtures

    run find_app_files "com.microsoft.edgemac" "Microsoft Edge"
    [ "$status" -eq 0 ]

    # The vendor root is Office/Teams/OneDrive data, not Edge's.
    ! list_has_path "$output" "$HOME/Library/Application Support/Microsoft" || return 1
    ! list_has_path "$output" "$HOME/Library/Caches/Microsoft" || return 1
    ! list_has_path "$output" "$HOME/Library/Logs/Microsoft" || return 1
    ! list_has_path "$output" "$HOME/Library/Preferences/Microsoft.plist" || return 1
    ! list_has_path "$output" "$HOME/.config/microsoft" || return 1
    ! list_has_path "$output" "$HOME/.cache/microsoft" || return 1
    ! list_has_path "$output" "$HOME/.local/share/microsoft" || return 1

    # An office document fixture proves the root survived the scan.
    [ -d "$HOME/Library/Application Support/Microsoft/Office" ]
}

@test "B1-01 find_app_files still lists Microsoft Edge's own leftovers" {
    make_vendor_root_fixtures
    make_edge_fixtures

    run find_app_files "com.microsoft.edgemac" "Microsoft Edge"
    [ "$status" -eq 0 ]

    list_has_path "$output" "$HOME/Library/Application Support/Microsoft Edge" || return 1
    list_has_path "$output" "$HOME/Library/Caches/Microsoft Edge" || return 1
    list_has_path "$output" "$HOME/Library/Logs/Microsoft Edge" || return 1
    list_has_path "$output" "$HOME/Library/Preferences/Microsoft Edge.plist" || return 1
    list_has_path "$output" "$HOME/.config/microsoft-edge" || return 1
    list_has_path "$output" "$HOME/.local/share/microsoft-edge"
}

@test "B1-01 a channel build such as Microsoft Edge Beta cannot collapse to the vendor root" {
    make_vendor_root_fixtures
    mkdir -p "$HOME/Library/Application Support/Microsoft Edge Beta/Default"

    run find_app_files "com.microsoft.edgemac.beta" "Microsoft Edge Beta"
    [ "$status" -eq 0 ]

    # "Microsoft Edge Beta" still loses its channel suffix, but the base
    # "Microsoft Edge" is a product leaf, never the shared vendor root.
    ! list_has_path "$output" "$HOME/Library/Application Support/Microsoft" || return 1
    ! list_has_path "$output" "$HOME/Library/Caches/Microsoft" || return 1
    ! list_has_path "$output" "$HOME/Library/Logs/Microsoft" || return 1
    ! list_has_path "$output" "$HOME/Library/Preferences/Microsoft.plist" || return 1
    ! list_has_path "$output" "$HOME/.config/microsoft" || return 1
    ! list_has_path "$output" "$HOME/.cache/microsoft" || return 1
    ! list_has_path "$output" "$HOME/.local/share/microsoft" || return 1
    list_has_path "$output" "$HOME/Library/Application Support/Microsoft Edge Beta"
}

@test "B1-01 an Edge channel build keeps the shared Edge leaves while the stable app is installed" {
    make_vendor_root_fixtures
    make_edge_fixtures

    local apps="$HOME/apps"
    mkdir -p "$apps/Microsoft Edge.app" "$apps/Microsoft Edge Beta.app"

    # shellcheck disable=SC2016 # Expand fixture paths in the child shell.
    run env MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc -c '
        source "$PROJECT_ROOT/lib/core/base.sh"
        source "$PROJECT_ROOT/lib/core/log.sh"
        source "$PROJECT_ROOT/lib/core/app_protection.sh"
        find_app_files "com.microsoft.edgemac.beta" "Microsoft Edge Beta" "$HOME/apps/Microsoft Edge Beta.app"
    '
    [ "$status" -eq 0 ]

    # Both builds share "Application Support/Microsoft Edge"; the channel
    # build must not take it, and neither build may take the vendor root.
    ! list_has_path "$output" "$HOME/Library/Application Support/Microsoft Edge" || return 1
    ! list_has_path "$output" "$HOME/.config/microsoft-edge" || return 1
    ! list_has_path "$output" "$HOME/Library/Application Support/Microsoft" || return 1
    ! list_has_path "$output" "$HOME/Library/Preferences/Microsoft.plist"
}

@test "B1-01 batch.sh suffix mirror keeps Edge as a product word" {
    # shellcheck disable=SC2016 # Expand fixture paths in the child shell.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        /bin/bash --noprofile --norc -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lib/core/common.sh"
        source "$PROJECT_ROOT/lib/uninstall/batch.sh"
        printf "edge=[%s]\n" "$(uninstall_strip_version_suffix "Microsoft Edge")"
        printf "nightly=[%s]\n" "$(uninstall_strip_version_suffix "Zed Nightly")"
        printf "dev=[%s]\n" "$(uninstall_strip_version_suffix "Google Chrome Dev")"
    '
    [ "$status" -eq 0 ]
    # "Microsoft Edge" keeps its product word, while real channels still strip.
    [[ "$output" == *"edge=[Microsoft Edge]"* ]] || return 1
    [[ "$output" == *"nightly=[Zed]"* ]] || return 1
    [[ "$output" == *"dev=[Google Chrome]"* ]]
}
