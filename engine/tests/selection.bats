#!/usr/bin/env bats

load helpers/common

# MOLE_SELECTION_FILE narrows an execution run to the rows a caller previewed
# and a user kept. Every case below runs in a throwaway HOME and calls the real
# safe_clean funnel, so the assertion is about the sink, not a helper's return
# value: a selected row must go, an unselected, empty-file or unreadable row
# must stay, and an unreadable file must refuse the command outright.

setup_file() {
    mole_test_setup_home selection
    export TERM="xterm-256color"
    export MOLE_TEST_MODE=1
    export MOLE_TEST_NO_AUTH=1
    mkdir -p "$HOME/Library/Caches" "$HOME/.config/mole"
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
    rm -rf "${HOME:?}"/*
    mkdir -p "$HOME/Library/Caches" "$HOME/.config/mole"
    SELECTION_ROOT="$HOME/selection-fixture"
    mkdir -p "$SELECTION_ROOT"
}

teardown() {
    rm -rf "${SELECTION_ROOT:-}" # SAFE: test-owned fixture under a temp HOME
}

# Run one safe_clean over $SELECTION_ROOT/{keep,drop} with the caller's
# environment and a real removal funnel, then report which rows survived.
# The heredoc ends with an echo so its exit status reflects the funnel.
run_selected_clean() {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 \
        MOLE_SELECTION_FILE="${1:-}" /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
safe_remove() { /bin/rm -rf "$1"; return 0; } # SAFE: test fixture under a temp HOME
safe_clean "$HOME/selection-fixture/keep" "$HOME/selection-fixture/drop" "Selection fixture"
EOF
}

@test "selected path is removed by safe_clean" {
    mkdir -p "$SELECTION_ROOT/keep" "$SELECTION_ROOT/drop"
    printf 'xxxx' > "$SELECTION_ROOT/keep/data"
    printf 'xxxx' > "$SELECTION_ROOT/drop/data"
    printf '%s\n' "$SELECTION_ROOT/keep" > "$HOME/selection.txt"

    run_selected_clean "$HOME/selection.txt"

    [ "$status" -eq 0 ]
    [[ ! -e "$SELECTION_ROOT/keep" ]] || return 1
    [[ -e "$SELECTION_ROOT/drop" ]] || return 1
}

@test "unselected path is kept by safe_clean" {
    mkdir -p "$SELECTION_ROOT/keep" "$SELECTION_ROOT/drop"
    printf 'xxxx' > "$SELECTION_ROOT/keep/data"
    printf 'xxxx' > "$SELECTION_ROOT/drop/data"
    # Only an unrelated path is selected, so both fixture rows stay.
    printf '%s\n' "$HOME/somewhere-else" > "$HOME/selection.txt"

    run_selected_clean "$HOME/selection.txt"

    [ "$status" -eq 0 ]
    [[ -e "$SELECTION_ROOT/keep" ]] || return 1
    [[ -e "$SELECTION_ROOT/drop" ]] || return 1
}

@test "empty selection file keeps every path (fail closed)" {
    mkdir -p "$SELECTION_ROOT/keep" "$SELECTION_ROOT/drop"
    printf 'xxxx' > "$SELECTION_ROOT/keep/data"
    printf 'xxxx' > "$SELECTION_ROOT/drop/data"
    : > "$HOME/selection.txt"

    run_selected_clean "$HOME/selection.txt"

    [ "$status" -eq 0 ]
    [[ -e "$SELECTION_ROOT/keep" ]] || return 1
    [[ -e "$SELECTION_ROOT/drop" ]] || return 1
}

@test "unreadable selection file keeps every path (fail closed)" {
    mkdir -p "$SELECTION_ROOT/keep" "$SELECTION_ROOT/drop"
    printf 'xxxx' > "$SELECTION_ROOT/keep/data"
    printf 'xxxx' > "$SELECTION_ROOT/drop/data"

    run_selected_clean "$HOME/does-not-exist-selection.txt"

    [ "$status" -eq 0 ]
    [[ -e "$SELECTION_ROOT/keep" ]] || return 1
    [[ -e "$SELECTION_ROOT/drop" ]] || return 1
}

@test "mole_selection_preflight returns 2 for an unreadable selection file" {
    run env PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 \
        MOLE_SELECTION_FILE="$HOME/missing-selection.txt" /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
rc=0
mole_selection_preflight || rc=$?
echo "RC=$rc"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=2"* ]] || return 1
    [[ "$output" == *"MOLE_SELECTION_FILE is set but unreadable"* ]] || return 1
}

@test "mole_selection_preflight accepts a readable selection and ignores a dry run" {
    printf '%s\n' "$HOME/anything" > "$HOME/selection.txt"

    run env PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 \
        MOLE_SELECTION_FILE="$HOME/selection.txt" /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
mole_selection_preflight
echo "READABLE_RC=$?"
MOLE_SELECTION_FILE="$HOME/missing-selection.txt"
MOLE_DRY_RUN=1
mole_selection_preflight
echo "DRYRUN_RC=$?"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"READABLE_RC=0"* ]] || return 1
    [[ "$output" == *"DRYRUN_RC=0"* ]] || return 1
}
