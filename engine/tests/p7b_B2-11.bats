#!/usr/bin/env bats

load helpers/common

# B2-11: the read-only configuration hint missed paths written with a
# shell-escaped space or a file:// prefix, missed a full-width closing
# punctuation mark, and let the "Foo" needle claim "Foo 2". These are hints
# only: the configuration must stay byte-identical and no line content may be
# printed.

setup_file() {
    mole_test_setup_home p7b-B2-11
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
    source "$PROJECT_ROOT/lib/uninstall/batch.sh"
}

@test "B2-11 hints find Foo 2 through an escaped space and a file URL" {
    local base="$HOME/Library/Application Support"
    printf '%s\n' \
        "a=~/Library/Application Support/Foo\\ 2" \
        "b=file://$base/Foo 2" \
        "c=file://localhost$base/Foo 2" > "$HOME/.zshrc"

    run uninstall_configuration_references "$base/Foo 2"
    [ "$status" -eq 0 ]
    [[ "$output" == *"~/.zshrc:1"* ]] || return 1
    [[ "$output" == *"~/.zshrc:2"* ]] || return 1
    [[ "$output" == *"~/.zshrc:3"* ]]
}

@test "B2-11 hints do not let Foo claim Foo 2 or Foo-Bar" {
    printf '%s\n' \
        "a=~/Library/Application Support/Foo 2" \
        "b=~/Library/Application Support/Foo-Bar" \
        "c=~/Library/Application Support/Foo --args" \
        "d=~/Library/Application Support/Foo  2" > "$HOME/.zshrc"

    run uninstall_configuration_references "$HOME/Library/Application Support/Foo"
    [ "$status" -eq 0 ]
    [[ "$output" != *"~/.zshrc:1"* ]] || return 1
    [[ "$output" != *"~/.zshrc:2"* ]] || return 1
    [[ "$output" != *"~/.zshrc:4"* ]] || return 1
    [[ "$output" == *"~/.zshrc:3"* ]]
}

@test "B2-11 hints treat full-width closing punctuation as a boundary" {
    printf '%s\n' \
        "a=~/Library/Application Support/微信）" \
        "b=~/Library/Application Support/微信读书" > "$HOME/.zshrc"

    run uninstall_configuration_references "$HOME/Library/Application Support/微信"
    [ "$status" -eq 0 ]
    [[ "$output" == *"~/.zshrc:1"* ]] || return 1
    [[ "$output" != *"~/.zshrc:2"* ]]
}

@test "B2-11 file URL normalization does not match a foreign host" {
    local base="$HOME/Library/Application Support"
    printf '%s\n' "a=file://example.com$base/Foo 2" > "$HOME/.zshrc"

    run uninstall_configuration_references "$base/Foo 2"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Configuration references"* ]]
}

@test "B2-11 hints stay read-only and never print configuration contents" {
    local base="$HOME/Library/Application Support"
    printf '%s\n' "TOKEN=private-value command=\"$base/Foo 2\"" > "$HOME/.zshrc"
    cp "$HOME/.zshrc" "$HOME/.zshrc.before"

    run uninstall_configuration_references "$base/Foo 2"
    [ "$status" -eq 0 ]
    [[ "$output" == *"~/.zshrc:1"* ]] || return 1
    [[ "$output" != *"private-value"* ]] || return 1
    cmp "$HOME/.zshrc" "$HOME/.zshrc.before"
}
