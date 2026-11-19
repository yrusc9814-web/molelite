#!/usr/bin/env bats

load helpers/common

# B1-14: the VS Code rule in find_app_files triggered on the unanchored regex
# /microsoft.*vscode/, so any bundle id that merely spelled it claimed the
# stable profile. Uninstalling a helper component such as
# com.microsoft.VSCode.ShipIt or com.microsoft.VSCode.helper queued
# ~/Library/Application Support/Code (extensions, settings, globalStorage)
# and ~/.vscode, i.e. every stable extension and setting. The block also
# queued both channels' Squirrel caches unconditionally, so removing stable
# VS Code deleted the Insiders updater cache as well.
#
# The fix anchors the rule to the two product ids and lets each channel add
# only its own leaves. Fixtures live in a throwaway HOME; nothing here
# touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B1-14
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

# Both channels' data, both updater caches, and one unrelated look-alike
# product, all under the temporary HOME.
make_vscode_fixtures() {
    mkdir -p "$HOME/.vscode/extensions/pub.ext-1.0.0"
    mkdir -p "$HOME/Library/Application Support/Code/User/globalStorage"
    mkdir -p "$HOME/Library/Caches/com.microsoft.VSCode"
    mkdir -p "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt"

    mkdir -p "$HOME/.vscode-insiders/extensions/pub.ext-1.0.0"
    mkdir -p "$HOME/Library/Application Support/Code - Insiders/User/globalStorage"
    mkdir -p "$HOME/Library/Caches/com.microsoft.VSCodeInsiders"
    mkdir -p "$HOME/Library/Caches/com.microsoft.VSCodeInsiders.ShipIt"
}

@test "B1-14 a VS Code helper component does not claim the stable profile" {
    make_vscode_fixtures

    # Before the fix this id matched /microsoft.*vscode/ and the block queued
    # Application Support/Code (every extension and setting) plus ~/.vscode.
    local helper_id
    for helper_id in "com.microsoft.VSCode.helper" \
        "com.microsoft.VSCode.ShipIt" \
        "com.microsoft.VSCode.GPU" \
        "com.microsoft.VSCodeInsiders.helper"; do
        run find_app_files "$helper_id" "Visual Studio Code Helper"
        [ "$status" -eq 0 ]
        ! list_has_path "$output" "$HOME/Library/Application Support/Code" || return 1
        ! list_has_path "$output" "$HOME/Library/Application Support/Code - Insiders" || return 1
        ! list_has_path "$output" "$HOME/.vscode" || return 1
        ! list_has_path "$output" "$HOME/.vscode-insiders" || return 1
    done

    # Refusing to claim is the whole change: nothing on disk moves.
    [ -d "$HOME/Library/Application Support/Code/User/globalStorage" ] || return 1
    [ -d "$HOME/.vscode/extensions/pub.ext-1.0.0" ]
}

@test "B1-14 a look-alike bundle id claims neither channel's data" {
    make_vscode_fixtures

    # "microsoft.<vendor>.vscode" and a bare lowercase spelling are not the
    # product's two ids; the old substring regex accepted both.
    local lookalike_id
    for lookalike_id in "com.microsoft.something.vscode" \
        "org.microsoft.vscode" \
        "com.example.microsoft-vscode"; do
        run find_app_files "$lookalike_id" "Visual Studio Code Helper"
        [ "$status" -eq 0 ]
        ! list_has_path "$output" "$HOME/Library/Application Support/Code" || return 1
        ! list_has_path "$output" "$HOME/.vscode" || return 1
        ! list_has_path "$output" "$HOME/Library/Caches/com.microsoft.VSCode" || return 1
        ! list_has_path "$output" "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt" || return 1
    done

    [ -d "$HOME/Library/Application Support/Code/User/globalStorage" ]
}

@test "B1-14 uninstalling stable VS Code keeps the Insiders Squirrel cache" {
    make_vscode_fixtures

    run find_app_files "com.microsoft.VSCode" "Visual Studio Code"
    [ "$status" -eq 0 ]

    # The block added both ShipIt caches for either channel; only the stable
    # one belongs to this uninstall.
    list_has_path "$output" "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt" || return 1
    ! list_has_path "$output" "$HOME/Library/Caches/com.microsoft.VSCodeInsiders.ShipIt" || return 1
    ! list_has_path "$output" "$HOME/Library/Application Support/Code - Insiders" || return 1
    ! list_has_path "$output" "$HOME/.vscode-insiders" || return 1

    # The fix removes the wrong claim only; the other channel stays on disk.
    [ -d "$HOME/Library/Caches/com.microsoft.VSCodeInsiders.ShipIt" ]
}

@test "B1-14 uninstalling VS Code Insiders keeps stable data and cache" {
    make_vscode_fixtures

    run find_app_files "com.microsoft.VSCodeInsiders" "Visual Studio Code - Insiders"
    [ "$status" -eq 0 ]

    list_has_path "$output" "$HOME/Library/Caches/com.microsoft.VSCodeInsiders.ShipIt" || return 1
    ! list_has_path "$output" "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt" || return 1
    ! list_has_path "$output" "$HOME/Library/Application Support/Code" || return 1
    ! list_has_path "$output" "$HOME/.vscode" || return 1

    [ -d "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt" ]
}

@test "B1-14 the real VS Code bundles still get their own leaves (#850)" {
    make_vscode_fixtures

    run find_app_files "com.microsoft.VSCode" "Visual Studio Code"
    [ "$status" -eq 0 ]
    list_has_path "$output" "$HOME/Library/Application Support/Code" || return 1
    list_has_path "$output" "$HOME/.vscode" || return 1
    list_has_path "$output" "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt" || return 1

    run find_app_files "com.microsoft.VSCodeInsiders" "Visual Studio Code - Insiders"
    [ "$status" -eq 0 ]
    list_has_path "$output" "$HOME/Library/Application Support/Code - Insiders" || return 1
    list_has_path "$output" "$HOME/.vscode-insiders" || return 1
    list_has_path "$output" "$HOME/Library/Caches/com.microsoft.VSCodeInsiders.ShipIt"
}

@test "B1-14 the VS Code rule matches only the two product ids" {
    # Pin the narrow shape so a later edit cannot restore a substring match or
    # the unconditional two-channel ShipIt sweep.
    run grep -A24 '^    # 6. Tools$' "$PROJECT_ROOT/lib/core/app_protection.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *'=~ microsoft'* ]] || return 1
    [[ "$output" == *'com.microsoft.vscode)'* ]] || return 1
    [[ "$output" == *'com.microsoft.vscodeinsiders)'* ]]
}
