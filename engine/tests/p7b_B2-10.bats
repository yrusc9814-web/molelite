#!/usr/bin/env bats

load helpers/common

# B2-10: a cask token is a lowercase slug, so it only equals an app name by
# coincidence. "Foo 2.app", "Foo.Bar.app" and "Foo（Beta）.app" could never pass
# the whole-line name match in stage 4, and stages 1-3 either failed the old
# token grammar or never saw a Caskroom link. Such a Homebrew app was therefore
# uninstalled as a plain app: brew kept the cask registered and never ran the
# cask's own uninstall, while the bundle was deleted underneath it.
#
# The fix reads ownership from the installed artifact instead: a Caskroom
# staging link that is the exact selected directory names the token. Every
# resolved token still has to be installed and still has to pass the existing
# `brew info` ownership check.
#
# Fixtures live under $HOME, never in the real Caskroom, so each stage case
# stubs _extract_cask_token_from_path to report the token its fixture link
# stands for; that helper's real-root parsing is covered separately below.

setup_file() {
    mole_test_setup_home p7b-B2-10
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
}

@test "_extract_cask_token_from_path accepts a versioned cask token" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

[[ "$(_extract_cask_token_from_path /opt/homebrew/Caskroom/node@20/20.11.0/Node.app)" == "node@20" ]] || exit 1
[[ "$(_extract_cask_token_from_path /opt/homebrew/Caskroom/libreoffice-language-pack/24.2/App.app)" == "libreoffice-language-pack" ]] || exit 1
[[ "$(_extract_cask_token_from_path /usr/local/Caskroom/foo.bar/1/Foo.app)" == "foo.bar" ]] || exit 1
# Still refuses anything that is not a token, and anything outside Caskroom.
! _extract_cask_token_from_path "/opt/homebrew/Caskroom/Foo App/1/Foo.app" || exit 1
! _extract_cask_token_from_path "/Applications/foo/1/Foo.app"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "stage 4 resolves Foo 2.app to its cask through the Caskroom link" {
    # The app name is not a token: "foo 2" is not in `brew list --cask`, so the
    # old whole-line name match returned 1 and the app was deleted as a plain
    # app. The Caskroom link is what proves ownership.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

mkdir -p "$HOME/Applications/Foo 2.app" "$HOME/Caskroom/foo/2.0"
ln -s "$HOME/Applications/Foo 2.app" "$HOME/Caskroom/foo/2.0/Foo 2.app"
# A second cask whose app is a different directory: it must not be selected.
mkdir -p "$HOME/Applications/Other.app" "$HOME/Caskroom/bar/1.0"
ln -s "$HOME/Applications/Other.app" "$HOME/Caskroom/bar/1.0/Other.app"

_mole_brew_caskroom_roots() { printf '%s\n' "$HOME/Caskroom"; }
_extract_cask_token_from_path() {
    local path="$1"
    printf '%s\n' "${path#"$HOME/Caskroom/"}" | cut -d/ -f1
}
_mole_brew_detection_list() { printf '%s\n' bar foo; }
_mole_brew_cask_info() {
    case "$1" in
        foo) printf 'app "%s"\n' "$HOME/Applications/Foo 2.app" ;;
        bar) printf 'app "%s"\n' "$HOME/Applications/Other.app" ;;
        *) return 1 ;;
    esac
}

# Stage 2 sees no Caskroom app literally named "Foo 2.app" for the *installed*
# check, but the link does exist; drive stage 4 directly with the same
# inventory stage 2 would have built.
_MOLE_BREW_BATCH_ROOM_READY=1
_MOLE_BREW_BATCH_ROOM_RC=0
_MOLE_BREW_BATCH_ROOM_FILE="$HOME/room.list"
printf '%s\0' "$HOME/Caskroom/foo/2.0/Foo 2.app" "$HOME/Caskroom/bar/1.0/Other.app" > "$_MOLE_BREW_BATCH_ROOM_FILE"

token=$(_detect_cask_via_brew_list "$HOME/Applications/Foo 2.app" "Foo 2.app") || exit 1
printf 'TOKEN=%s\n' "$token"
[[ "$token" == foo ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"TOKEN=foo"* ]]
}

@test "stage 4 resolves Foo.Bar.app and Foo（Beta）.app the same way" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

mkdir -p "$HOME/Applications/Foo.Bar.app" "$HOME/Applications/Foo（Beta）.app"
mkdir -p "$HOME/Caskroom/foo-bar/1.0" "$HOME/Caskroom/foo-beta/1.0"
ln -s "$HOME/Applications/Foo.Bar.app" "$HOME/Caskroom/foo-bar/1.0/Foo.Bar.app"
ln -s "$HOME/Applications/Foo（Beta）.app" "$HOME/Caskroom/foo-beta/1.0/Foo（Beta）.app"

_mole_brew_caskroom_roots() { printf '%s\n' "$HOME/Caskroom"; }
_extract_cask_token_from_path() {
    local path="$1"
    printf '%s\n' "${path#"$HOME/Caskroom/"}" | cut -d/ -f1
}
_mole_brew_detection_list() { printf '%s\n' foo-bar foo-beta; }
_mole_brew_cask_info() {
    case "$1" in
        foo-bar) printf 'app "%s"\n' "$HOME/Applications/Foo.Bar.app" ;;
        foo-beta) printf 'app "%s"\n' "$HOME/Applications/Foo（Beta）.app" ;;
        *) return 1 ;;
    esac
}

_MOLE_BREW_BATCH_ROOM_READY=1
_MOLE_BREW_BATCH_ROOM_RC=0
_MOLE_BREW_BATCH_ROOM_FILE="$HOME/room.list"
printf '%s\0' \
    "$HOME/Caskroom/foo-bar/1.0/Foo.Bar.app" \
    "$HOME/Caskroom/foo-beta/1.0/Foo（Beta）.app" > "$_MOLE_BREW_BATCH_ROOM_FILE"

[[ "$(_detect_cask_via_brew_list "$HOME/Applications/Foo.Bar.app" "Foo.Bar.app")" == foo-bar ]] || exit 1
[[ "$(_detect_cask_via_brew_list "$HOME/Applications/Foo（Beta）.app" "Foo（Beta）.app")" == foo-beta ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "stage 4 still refuses a cask whose brew info does not name the app" {
    # A Caskroom link that shares the inode is not enough on its own: the cask
    # the inventory points at must still prove it installs this exact app.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

mkdir -p "$HOME/Applications/Foo 2.app" "$HOME/Applications/Bar.app" "$HOME/Caskroom/foo/2.0"
ln -s "$HOME/Applications/Foo 2.app" "$HOME/Caskroom/foo/2.0/Foo 2.app"

_mole_brew_caskroom_roots() { printf '%s\n' "$HOME/Caskroom"; }
_extract_cask_token_from_path() {
    local path="$1"
    printf '%s\n' "${path#"$HOME/Caskroom/"}" | cut -d/ -f1
}
_mole_brew_detection_list() { printf '%s\n' foo; }
_mole_brew_cask_info() { printf 'app "%s"\n' "$HOME/Applications/Bar.app"; }

_MOLE_BREW_BATCH_ROOM_READY=1
_MOLE_BREW_BATCH_ROOM_RC=0
_MOLE_BREW_BATCH_ROOM_FILE="$HOME/room.list"
printf '%s\0' "$HOME/Caskroom/foo/2.0/Foo 2.app" > "$_MOLE_BREW_BATCH_ROOM_FILE"

! _detect_cask_via_brew_list "$HOME/Applications/Foo 2.app" "Foo 2.app"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "stage 4 refuses two installed casks that both name the exact app" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

mkdir -p "$HOME/Applications/Foo 2.app" "$HOME/Caskroom/foo/2.0" "$HOME/Caskroom/foo-beta/2.0"
ln -s "$HOME/Applications/Foo 2.app" "$HOME/Caskroom/foo/2.0/Foo 2.app"
ln -s "$HOME/Applications/Foo 2.app" "$HOME/Caskroom/foo-beta/2.0/Foo 2.app"

_mole_brew_caskroom_roots() { printf '%s\n' "$HOME/Caskroom"; }
_extract_cask_token_from_path() {
    local path="$1"
    printf '%s\n' "${path#"$HOME/Caskroom/"}" | cut -d/ -f1
}
_mole_brew_detection_list() { printf '%s\n' foo foo-beta; }
_mole_brew_cask_info() { printf 'app "%s"\n' "$HOME/Applications/Foo 2.app"; }

_MOLE_BREW_BATCH_ROOM_READY=1
_MOLE_BREW_BATCH_ROOM_RC=0
_MOLE_BREW_BATCH_ROOM_FILE="$HOME/room.list"
printf '%s\0' "$HOME/Caskroom/foo/2.0/Foo 2.app" "$HOME/Caskroom/foo-beta/2.0/Foo 2.app" \
    > "$_MOLE_BREW_BATCH_ROOM_FILE"

! _detect_cask_via_brew_list "$HOME/Applications/Foo 2.app" "Foo 2.app"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "stage 4 never adopts a token that brew does not list as installed" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

mkdir -p "$HOME/Applications/Foo 2.app" "$HOME/Caskroom/foo/2.0"
ln -s "$HOME/Applications/Foo 2.app" "$HOME/Caskroom/foo/2.0/Foo 2.app"

# Caskroom still holds the staging link, but the cask is gone from brew list.
_mole_brew_caskroom_roots() { printf '%s\n' "$HOME/Caskroom"; }
_extract_cask_token_from_path() {
    local path="$1"
    printf '%s\n' "${path#"$HOME/Caskroom/"}" | cut -d/ -f1
}
_mole_brew_detection_list() { printf '%s\n' bar; }
_mole_brew_cask_info() { printf 'app "%s"\n' "$HOME/Applications/Foo 2.app"; }

_MOLE_BREW_BATCH_ROOM_READY=1
_MOLE_BREW_BATCH_ROOM_RC=0
_MOLE_BREW_BATCH_ROOM_FILE="$HOME/room.list"
printf '%s\0' "$HOME/Caskroom/foo/2.0/Foo 2.app" > "$_MOLE_BREW_BATCH_ROOM_FILE"

! _detect_cask_via_brew_list "$HOME/Applications/Foo 2.app" "Foo 2.app"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "stage 4 keeps its timeout status when the app probe is interrupted" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

mkdir -p "$HOME/Applications/Foo 2.app" "$HOME/Caskroom/foo/2.0"
ln -s "$HOME/Applications/Foo 2.app" "$HOME/Caskroom/foo/2.0/Foo 2.app"

_mole_brew_caskroom_roots() { printf '%s\n' "$HOME/Caskroom"; }
_extract_cask_token_from_path() {
    local path="$1"
    printf '%s\n' "${path#"$HOME/Caskroom/"}" | cut -d/ -f1
}
_mole_brew_detection_list() { printf '%s\n' foo; }
_mole_brew_cask_info() { return 124; }

_MOLE_BREW_BATCH_ROOM_READY=1
_MOLE_BREW_BATCH_ROOM_RC=0
_MOLE_BREW_BATCH_ROOM_FILE="$HOME/room.list"
printf '%s\0' "$HOME/Caskroom/foo/2.0/Foo 2.app" > "$_MOLE_BREW_BATCH_ROOM_FILE"

rc=0
_detect_cask_via_brew_list "$HOME/Applications/Foo 2.app" "Foo 2.app" || rc=$?
printf 'RC=%s\n' "$rc"
[[ $rc -eq 124 ]]
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"RC=124"* ]]
}

@test "get_brew_cask_name routes Foo 2.app to brew instead of a plain delete" {
    # End to end through the public entry point: no Caskroom link visible to
    # stage 2's find, so the lookup order still has to end on stage 4.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

mkdir -p "$HOME/Applications/Foo 2.app" "$HOME/Caskroom/foo/2.0"
ln -s "$HOME/Applications/Foo 2.app" "$HOME/Caskroom/foo/2.0/Foo 2.app"

# Stage 2's own Caskroom find is stubbed empty, as if the link were not
# visible there, so the public entry point is forced through to stage 4.
resolve_path() { return 1; }
find() { return 0; }
# is_homebrew_available() runs in a subshell, so it needs a brew on PATH.
mkdir -p "$HOME/bin"
printf '#!/bin/sh\nexit 0\n' > "$HOME/bin/brew"
chmod +x "$HOME/bin/brew"
PATH="$HOME/bin:$PATH"
_mole_brew_caskroom_roots() { printf '%s\n' "$HOME/Caskroom"; }
_extract_cask_token_from_path() {
    local path="$1"
    printf '%s\n' "${path#"$HOME/Caskroom/"}" | cut -d/ -f1
}
_mole_brew_detection_list() { printf '%s\n' foo; }
_mole_brew_cask_info() { printf 'app "%s"\n' "$HOME/Applications/Foo 2.app"; }
_MOLE_BREW_BATCH_ROOM_READY=1
_MOLE_BREW_BATCH_ROOM_RC=0
_MOLE_BREW_BATCH_ROOM_FILE="$HOME/room.list"
# The inventory stage 2 would have built before its find came up empty.
printf '%s\0' "$HOME/Caskroom/foo/2.0/Foo 2.app" > "$_MOLE_BREW_BATCH_ROOM_FILE"

TOKEN0=$(get_brew_cask_name "$HOME/Applications/Foo 2.app") || exit 1
printf 'TOKEN=%s\n' "$TOKEN0"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"TOKEN=foo"* ]]
}
