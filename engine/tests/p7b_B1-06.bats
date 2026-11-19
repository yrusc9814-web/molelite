#!/usr/bin/env bats

load helpers/common

# B1-06: the app-name templates in find_app_files are literal concatenations
# behind a two-character floor (AP:1590), so a two-letter display name spelled
# someone else's shared root: "Go.app" claimed ~/.cache/go, ~/.config/go and
# ~/.local/share/go (the Go toolchain's build cache and `go env` config), and
# "QQ.app" claimed ~/Library/Caches/QQ, which review.sh treats as disposable
# and deletes without asking. A one-character name ("R.app") already fell
# below the floor.
#
# The fix raises the floor for name-derived leaves to three characters. Bundle
# ids still address those apps, so nothing addressed by id is lost; only a
# name too short to prove ownership stops claiming a leaf (policy 1: leaving
# data behind beats deleting another product's).

setup_file() {
    mole_test_setup_home p7b-B1-06
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

# The Go toolchain's shared user state, laid out exactly as it lands on disk.
make_go_toolchain_state() {
    mkdir -p "$HOME/.cache/go/build/trim.txt" "$HOME/.config/go/telemetry"
    : > "$HOME/.config/go/env"
    mkdir -p "$HOME/.local/share/go/pkg/mod/cache/download"
}

@test "B1-06 Go.app does not claim the Go toolchain's cache, config or module root" {
    make_go_toolchain_state

    run find_app_files "com.example.go" "Go"
    [ "$status" -eq 0 ]

    # Before the fix the two-character floor queued every XDG leaf.
    ! list_has_path "$output" "$HOME/.cache/go" || return 1
    ! list_has_path "$output" "$HOME/.config/go" || return 1
    ! list_has_path "$output" "$HOME/.local/share/go" || return 1

    # The fixture is still there: this is a miss, never a delete.
    [ -f "$HOME/.config/go/env" ] || return 1
    [ -d "$HOME/.local/share/go/pkg/mod/cache/download" ]
}

@test "B1-06 Go.app no longer offers the name-derived Library leaves either" {
    mkdir -p "$HOME/Library/Application Support/Go" "$HOME/Library/Caches/Go"
    mkdir -p "$HOME/Library/Logs/Go" "$HOME/Library/Preferences"
    : > "$HOME/Library/Preferences/Go.plist"

    run find_app_files "com.example.go" "Go"
    [ "$status" -eq 0 ]

    ! list_has_path "$output" "$HOME/Library/Application Support/Go" || return 1
    ! list_has_path "$output" "$HOME/Library/Caches/Go" || return 1
    ! list_has_path "$output" "$HOME/Library/Logs/Go" || return 1
    ! list_has_path "$output" "$HOME/Library/Preferences/Go.plist" || return 1
    [ -f "$HOME/Library/Preferences/Go.plist" ]
}

@test "B1-06 QQ.app does not claim the auto-deleted ~/Library/Caches/QQ" {
    # review.sh:13 classifies Caches/* as disposable, so this leaf is removed
    # without the D menu: a two-letter name must not reach it.
    mkdir -p "$HOME/Library/Caches/QQ/Default/GPUCache"
    : > "$HOME/Library/Caches/QQ/Default/GPUCache/data_0"
    mkdir -p "$HOME/Library/Application Support/QQ"
    mkdir -p "$HOME/Library/Preferences"
    : > "$HOME/Library/Preferences/QQ.plist"

    run find_app_files "com.tencent.qq" "QQ"
    [ "$status" -eq 0 ]

    ! list_has_path "$output" "$HOME/Library/Caches/QQ" || return 1
    ! list_has_path "$output" "$HOME/Library/Application Support/QQ" || return 1
    ! list_has_path "$output" "$HOME/Library/Preferences/QQ.plist" || return 1
    [ -d "$HOME/Library/Caches/QQ/Default/GPUCache" ]
}

@test "B1-06 R.app (one character) never reaches a name-derived leaf" {
    mkdir -p "$HOME/Library/Caches/R" "$HOME/Library/Application Support/R"
    mkdir -p "$HOME/Library/Preferences"
    : > "$HOME/Library/Preferences/R.plist"

    run find_app_files "org.R-project.R" "R"
    [ "$status" -eq 0 ]

    ! list_has_path "$output" "$HOME/Library/Caches/R" || return 1
    ! list_has_path "$output" "$HOME/Library/Application Support/R" || return 1
    ! list_has_path "$output" "$HOME/Library/Preferences/R.plist"
}

@test "B1-06 a short name still finds everything its bundle id addresses" {
    # The fix may only drop name-derived leaves: the id-addressed directories
    # of the same two-letter app must keep coming back.
    mkdir -p "$HOME/Library/Application Support/com.example.go"
    mkdir -p "$HOME/Library/Caches/com.example.go"
    mkdir -p "$HOME/Library/Logs/com.example.go"
    mkdir -p "$HOME/Library/Preferences"
    : > "$HOME/Library/Preferences/com.example.go.plist"

    run find_app_files "com.example.go" "Go"
    [ "$status" -eq 0 ]

    list_has_path "$output" "$HOME/Library/Application Support/com.example.go" || return 1
    list_has_path "$output" "$HOME/Library/Caches/com.example.go" || return 1
    list_has_path "$output" "$HOME/Library/Logs/com.example.go" || return 1
    list_has_path "$output" "$HOME/Library/Preferences/com.example.go.plist"
}

@test "B1-06 a three-character name keeps its own folders" {
    # The floor must not cost real three-letter apps their data: Zed.app
    # (dev.zed.Zed) writes ~/Library/Application Support/Zed, Caches/Zed and
    # Preferences/Zed.plist. Its lowercase ~/.cache/zed comes from the lowered
    # variant, which the same block owns, so it must survive the floor too.
    mkdir -p "$HOME/Library/Application Support/Zed" "$HOME/Library/Caches/Zed"
    mkdir -p "$HOME/Library/Preferences"
    : > "$HOME/Library/Preferences/Zed.plist"
    mkdir -p "$HOME/.cache/zed"
    : > "$HOME/.cache/zed/state.json"

    run find_app_files "dev.zed.Zed" "Zed"
    [ "$status" -eq 0 ]

    list_has_path "$output" "$HOME/Library/Application Support/Zed" || return 1
    list_has_path "$output" "$HOME/Library/Caches/Zed" || return 1
    list_has_path "$output" "$HOME/Library/Preferences/Zed.plist" || return 1
    list_has_path "$output" "$HOME/.cache/zed"
}
