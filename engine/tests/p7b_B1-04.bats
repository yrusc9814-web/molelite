#!/usr/bin/env bats

load helpers/common

# B1-04: a Group Container is named "<prefix>.<group id>" and every app of that
# team which declares the group shares it. find_app_files used the generic
# bundle-id boundary (*.<id>.*), so uninstalling Foo.app (com.acme.Foo)
# collected ABCD1234.com.acme.Foo.shared -- the App Group Foo Sync.app also
# uses. Only the exact "<id>" and "<prefix>.<id>" spellings are the app's own
# now; anything with a further group-id segment stays on disk.
#
# Fixtures live in a throwaway HOME; nothing here touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B1-04
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

groups="$HOME/Library/Group Containers"

@test "B1-04 does not claim a shared App Group with a further group-id segment" {
    mkdir -p "$groups/ABCD1234.com.acme.Foo.shared"
    : > "$groups/ABCD1234.com.acme.Foo.shared/sync.db"

    run find_app_files "com.acme.Foo" "Foo"
    [ "$status" -eq 0 ]

    # Before the fix the suffix arm (*.<id>.*) queued the shared group.
    ! list_has_path "$output" "$groups/ABCD1234.com.acme.Foo.shared" || return 1
    [ -d "$groups/ABCD1234.com.acme.Foo.shared" ]
}

@test "B1-04 does not claim another product's group that extends the id" {
    # com.acme.Foo.sync is a different group id, not Foo's own container. It
    # has the shape "<anything>.<id>.<suffix>", so the old boundary matched.
    mkdir -p "$groups/com.acme.Foo.sync"
    mkdir -p "$groups/group.com.acme.Foo.sync"

    run find_app_files "com.acme.Foo" "Foo"
    [ "$status" -eq 0 ]

    ! list_has_path "$output" "$groups/com.acme.Foo.sync" || return 1
    ! list_has_path "$output" "$groups/group.com.acme.Foo.sync"
}

@test "B1-04 keeps the app's own exact and TeamID-prefixed group containers" {
    mkdir -p "$groups/ABCD1234.com.acme.Foo"
    mkdir -p "$groups/com.acme.Foo"
    mkdir -p "$groups/ABCD1234.com.acme.Foo.shared"

    run find_app_files "com.acme.Foo" "Foo"
    [ "$status" -eq 0 ]

    list_has_path "$output" "$groups/ABCD1234.com.acme.Foo" || return 1
    list_has_path "$output" "$groups/com.acme.Foo" || return 1
    ! list_has_path "$output" "$groups/ABCD1234.com.acme.Foo.shared"
}

@test "B1-04 still claims a single-label prefixed group (group.com.example.app)" {
    # The conventional "group." prefix is one label, so this stays the app's
    # own container; the fix must not turn the whole suffix arm off.
    mkdir -p "$groups/group.com.example.real"
    mkdir -p "$groups/group.com.example.real.shared"

    run find_app_files "com.example.real" "RealApp"
    [ "$status" -eq 0 ]

    list_has_path "$output" "$groups/group.com.example.real" || return 1
    ! list_has_path "$output" "$groups/group.com.example.real.shared"
}

@test "B1-04 a multi-label prefix is not proof of ownership" {
    # "ABCD1234" alone is one label, but two prefix labels are a group domain.
    mkdir -p "$groups/com.acme.com.acme.Foo"

    run find_app_files "com.acme.Foo" "Foo"
    [ "$status" -eq 0 ]

    ! list_has_path "$output" "$groups/com.acme.com.acme.Foo"
}

@test "B1-04 Group Containers stay held back from --with-data" {
    # The ownership anchor above is the first layer; the review holdback is the
    # second, so an App Group is never preselected even if discovery names it.
    mkdir -p "$groups/ABCD1234.com.acme.Foo.shared"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        bash -c '
            source "$PROJECT_ROOT/lib/core/base.sh"
            source "$PROJECT_ROOT/lib/core/log.sh"
            source "$PROJECT_ROOT/lib/uninstall/review.sh"
            _uninstall_data_preselect_holdback "$HOME/Library/Group Containers/ABCD1234.com.acme.Foo.shared"
        '
    [ "$status" -eq 0 ]
}
