#!/usr/bin/env bats

load helpers/common

# B1-18: the Homebrew stage that runs after the Caskroom path stages matched an
# app to a cask by bundle name and by a substring of `brew info` output. A
# non-Homebrew /Applications/Chat.app (com.acme.chat) therefore selected an
# installed cask whose Caskroom artifact is a different Chat.app, and
# `brew uninstall --cask chat` removed that other product while the app the
# user chose stayed in place.
#
# Both stages now require the cask's own Caskroom artifact to be the same file
# as the selected bundle (`-ef`), so a same-name copy is refused and a real
# Homebrew link is still detected. The Caskroom fixture lives in the throwaway
# HOME and never creates or changes the machine's real Caskroom.

setup_file() {
    mole_test_setup_home p7b-B1-18
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
    CASKROOM="$HOME/Caskroom"
    mkdir -p "$CASKROOM" "$HOME/Applications"
}

# Run one detection stage against a stub brew and this test's Caskroom.
# Arguments: <stage> <selected app path> <bundle name>, where stage is
# caskroom_search or brew_list.
run_detection() {
    local stage="$1" app_path="$2" bundle="$3"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" STAGE="$stage" \
        APP_PATH="$app_path" BUNDLE="$bundle" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

# Stub brew: the cask is installed and its info text names the app artifact,
# which is exactly what the old substring check treated as proof of ownership.
brew() {
    case "$*" in
        "list --cask") printf '%s\n' chat ;;
        "info --cask chat")
            # Names the selected path verbatim, the strongest text claim the
            # old substring check accepted; it still is not file identity.
            printf '==> chat: 1.0\n==> Artifacts\n%s (App)\n' "$APP_PATH"
            ;;
        *) return 1 ;;
    esac
}
export -f brew

_mole_brew_caskroom_roots() { printf '%s\n' "$HOME/Caskroom"; }
# Fixture paths are not under a real Caskroom root, so map them locally.
_extract_cask_token_from_path() {
    local path="$1"
    case "$path" in
        "$HOME/Caskroom/"*) ;;
        *) return 1 ;;
    esac
    path="${path#"$HOME/Caskroom/"}"
    printf '%s\n' "${path%%/*}"
}

result=""
rc=0
case "$STAGE" in
    caskroom_search) result=$(_detect_cask_via_caskroom_search "$BUNDLE" "$APP_PATH") || rc=$? ;;
    brew_list) result=$(_detect_cask_via_brew_list "$APP_PATH" "$BUNDLE") || rc=$? ;;
    *) exit 99 ;;
esac
printf 'rc=%s token=%s\n' "$rc" "$result"
EOF
}

@test "a same-name app that is not the cask artifact is not detected as a cask" {
    # The cask stages its own Chat.app; the user selected an independent one.
    mkdir -p "$CASKROOM/chat/1.0/Chat.app" "$HOME/Applications/Chat.app"
    [[ ! "$HOME/Applications/Chat.app" -ef "$CASKROOM/chat/1.0/Chat.app" ]] || return 1

    run_detection caskroom_search "$HOME/Applications/Chat.app" Chat.app
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "rc=1 token=" ] || { echo "$output"; return 1; }

    run_detection brew_list "$HOME/Applications/Chat.app" Chat.app
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "rc=1 token=" ]
}

@test "a non-Homebrew /Applications app is not claimed by name alone" {
    # Production keeps non-brew apps at exactly /Applications/<App>.app, which
    # the old name-only branch accepted whenever `brew info` merely contained
    # the bundle name. The path is used literally, so no real /Applications
    # entry is created or touched; the cask stages a different Chat.app.
    mkdir -p "$CASKROOM/chat/1.0/Chat.app"

    run_detection caskroom_search "/Applications/Chat.app" Chat.app
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "rc=1 token=" ] || { echo "$output"; return 1; }

    run_detection brew_list "/Applications/Chat.app" Chat.app
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "rc=1 token=" ]
}

@test "the ownership check refuses a name-only brew info and accepts the cask file" {
    # Called directly: a `Chat.app (App)` line and a same-name copy are not
    # ownership, while the cask's own staged bundle is.
    mkdir -p "$CASKROOM/chat/1.0/Chat.app" "$HOME/apps/Chat.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"
_mole_brew_caskroom_roots() { printf '%s\n' "$HOME/Caskroom"; }
# A bare artifact name is all brew info prints; it must not be read as proof.
_mole_brew_cask_owns_app chat "$HOME/apps/Chat.app" 'Chat.app (App)' && exit 1
# The cask's own staged bundle, reached through a link like Homebrew's.
mkdir -p "$HOME/linked"
ln -s "$HOME/Caskroom/chat/1.0/Chat.app" "$HOME/linked/Chat.app"
_mole_brew_cask_owns_app chat "$HOME/linked/Chat.app" || exit 1
exit 0
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a real Homebrew app link to the cask artifact is still detected" {
    mkdir -p "$CASKROOM/chat/1.0/Chat.app"
    ln -s "$CASKROOM/chat/1.0/Chat.app" "$HOME/Applications/Chat.app"
    [[ "$HOME/Applications/Chat.app" -ef "$CASKROOM/chat/1.0/Chat.app" ]] || return 1

    run_detection caskroom_search "$HOME/Applications/Chat.app" Chat.app
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "rc=0 token=chat" ] || { echo "$output"; return 1; }

    run_detection brew_list "$HOME/Applications/Chat.app" Chat.app
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$output" = "rc=0 token=chat" ]
}

@test "get_brew_cask_name leaves a non-Homebrew same-name app alone" {
    mkdir -p "$CASKROOM/chat/1.0/Chat.app" "$HOME/Applications/Chat.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/brew.sh"

brew() {
    case "$*" in
        "list --cask") printf '%s\n' chat ;;
        "info --cask chat") printf '==> chat: 1.0\n==> Artifacts\nChat.app (App)\n' ;;
        *) return 1 ;;
    esac
}
export -f brew

_mole_brew_caskroom_roots() { printf '%s\n' "$HOME/Caskroom"; }
_extract_cask_token_from_path() {
    local path="$1"
    case "$path" in
        "$HOME/Caskroom/"*) ;;
        *) return 1 ;;
    esac
    path="${path#"$HOME/Caskroom/"}"
    printf '%s\n' "${path%%/*}"
}

get_brew_cask_name "$HOME/Applications/Chat.app"
EOF

    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [ -z "$output" ]
}
