#!/usr/bin/env bats

load helpers/common

# B1-05: the name templates in find_app_files are literal concatenations, so any
# app whose display name spells a product or vendor word claimed that word's
# shared data. An unrelated "Code.app" (com.example.code) took Visual Studio
# Code's whole profile root ~/Library/Application Support/Code (settings,
# snippets, globalStorage, workspaceStorage), and an old component named
# "Microsoft.app"/"Adobe.app" took the vendor root. Neither directory is
# declared by that bundle, so uninstall must not offer either.
#
# The fix leaves those exact leaves to bundle-id patterns and to the product
# rules that prove ownership; similarly named products ("CodeRunner",
# "Microsoft Edge") keep their own folders.
#
# Fixtures live in a throwaway HOME; nothing here touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B1-05
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

# Visual Studio Code's profile root, plus the caches and preferences an
# unrelated app named "Code" used to claim and now reports as missing.
make_code_product_data() {
    mkdir -p "$HOME/Library/Application Support/Code/User/globalStorage/ms-python.python"
    : > "$HOME/Library/Application Support/Code/User/settings.json"
    mkdir -p "$HOME/Library/Application Support/Code/User/workspaceStorage/abc123"
    mkdir -p "$HOME/Library/Caches/Code"
    mkdir -p "$HOME/Library/Preferences"
    : > "$HOME/Library/Preferences/Code.plist"
}

# The same shape for one vendor root: Microsoft's shared "Microsoft" folder
# holds Office/Teams/OneDrive data, Adobe's holds Creative Cloud state.
make_vendor_root() {
    local vendor="$1"
    mkdir -p "$HOME/Library/Application Support/$vendor/Shared"
    : > "$HOME/Library/Application Support/$vendor/Shared/state.db"
    mkdir -p "$HOME/Library/Caches/$vendor" "$HOME/Library/Logs/$vendor"
    mkdir -p "$HOME/Library/Preferences"
    : > "$HOME/Library/Preferences/$vendor.plist"
}

@test "B1-05 an unrelated Code.app does not claim Visual Studio Code's profile root" {
    make_code_product_data

    run find_app_files "com.example.code" "Code"
    [ "$status" -eq 0 ]

    # The old name template queued the whole profile root, settings and
    # globalStorage/workspaceStorage included, plus the caches and preferences
    # leaves AP:1397-1400 names.
    ! list_has_path "$output" "$HOME/Library/Application Support/Code" || return 1
    ! list_has_path "$output" "$HOME/Library/Caches/Code" || return 1
    ! list_has_path "$output" "$HOME/Library/Preferences/Code" || return 1
    ! list_has_path "$output" "$HOME/Library/Preferences/Code.plist"
}

@test "B1-05 an old Microsoft.app or Adobe.app does not claim the vendor root" {
    make_vendor_root "Microsoft"
    make_vendor_root "Adobe"

    run find_app_files "com.example.microsoft" "Microsoft"
    [ "$status" -eq 0 ]
    ! list_has_path "$output" "$HOME/Library/Application Support/Microsoft" || return 1
    ! list_has_path "$output" "$HOME/Library/Caches/Microsoft" || return 1
    ! list_has_path "$output" "$HOME/Library/Logs/Microsoft" || return 1
    ! list_has_path "$output" "$HOME/Library/Preferences/Microsoft.plist" || return 1

    run find_app_files "com.example.adobe" "Adobe"
    [ "$status" -eq 0 ]
    ! list_has_path "$output" "$HOME/Library/Application Support/Adobe" || return 1
    ! list_has_path "$output" "$HOME/Library/Preferences/Adobe.plist"
}

@test "B1-05 the real Visual Studio Code bundle still gets Application Support/Code" {
    make_code_product_data

    run find_app_files "com.microsoft.VSCode" "Visual Studio Code"
    [ "$status" -eq 0 ]
    # The explicit com.microsoft.VSCode product rule proves the owner, so the
    # fix must not turn the valid case into a leftover.
    list_has_path "$output" "$HOME/Library/Application Support/Code"
}

@test "B1-05 a derived base name never claims a shared product root" {
    make_code_product_data
    mkdir -p "$HOME/Library/Application Support/Code Nightly"

    run find_app_files "com.example.code-nightly" "Code Nightly"
    [ "$status" -eq 0 ]
    # "Code Nightly" keeps its own folder but must not fall back to the
    # stripped base "Code" (B1-05), which is another product's profile root.
    list_has_path "$output" "$HOME/Library/Application Support/Code Nightly" || return 1
    ! list_has_path "$output" "$HOME/Library/Application Support/Code"
}

@test "B1-05 a compound name variant cannot fold back to the shared root" {
    make_vendor_root "Microsoft"

    # "Microsoft " folds to the bare vendor root, and a trailing space is a
    # legal bundle display name; the compound template used to re-add it
    # after the display-name guard had already refused it (B1-05).
    run find_app_files "com.example.microsoft" "Microsoft "
    [ "$status" -eq 0 ]
    ! list_has_path "$output" "$HOME/Library/Application Support/Microsoft" || return 1
    ! list_has_path "$output" "$HOME/Library/Caches/Microsoft" || return 1
    ! list_has_path "$output" "$HOME/Library/Preferences/Microsoft.plist"
}

@test "B1-05 similarly named products keep their own support folders" {
    mkdir -p "$HOME/Library/Application Support/CodeRunner"
    mkdir -p "$HOME/Library/Application Support/Microsoft Edge/Default"
    mkdir -p "$HOME/Library/Application Support/MaestroStudio"

    run find_app_files "com.example.coderunner" "CodeRunner"
    [ "$status" -eq 0 ]
    list_has_path "$output" "$HOME/Library/Application Support/CodeRunner" || return 1

    # "Microsoft Edge" is a product name, not the bare vendor root (B1-01).
    run find_app_files "com.microsoft.edgemac" "Microsoft Edge"
    [ "$status" -eq 0 ]
    list_has_path "$output" "$HOME/Library/Application Support/Microsoft Edge" || return 1

    # The compound naming variants still work for a name that is not shared
    # (#377): "Maestro Studio" keeps MaestroStudio (B1-05 guard must not
    # over-protect).
    run find_app_files "com.example.maestro" "Maestro Studio"
    [ "$status" -eq 0 ]
    list_has_path "$output" "$HOME/Library/Application Support/MaestroStudio"
}
