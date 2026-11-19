#!/usr/bin/env bats

load helpers/common

# B1-03: the "<bundle id>.*" prefix arm in find_app_files's derived-root scan
# collected every Container / Application Scripts directory whose name merely
# starts with the primary bundle id. Uninstalling Foo.app (com.acme.Foo) thus
# queued Containers/com.acme.Foo.Bar (another vendor product's sandbox) and
# Application Scripts/com.acme.Foo.helper. Only "<id>.<suffix>" names that
# complete one of the app's own embedded bundle ids are its helpers now.
#
# Fixtures live in a throwaway HOME; nothing here touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B1-03
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

# Foo.app owns com.acme.Foo and embeds one Share extension.
make_foo_fixtures() {
    local app="$HOME/Applications/Foo.app"
    local widget="$app/Contents/PlugIns/Share.appex/Contents"
    mkdir -p "$widget"
    cat > "$widget/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key>
  <string>com.acme.Foo.Share</string>
</dict></plist>
PLIST

    mkdir -p "$HOME/Library/Containers/com.acme.Foo"
    mkdir -p "$HOME/Library/Containers/com.acme.Foo.Share"
    # Another vendor product whose bundle id shares the primary id as a prefix.
    mkdir -p "$HOME/Library/Containers/com.acme.Foo.Bar"
    mkdir -p "$HOME/Library/Application Scripts/com.acme.Foo.helper"
}

@test "B1-03 keeps prefix-only containers and script dirs that are not embedded bundle ids" {
    make_foo_fixtures

    run find_app_files "com.acme.Foo" "Foo" "$HOME/Applications/Foo.app"
    [ "$status" -eq 0 ]

    list_has_path "$output" "$HOME/Library/Containers/com.acme.Foo" || return 1
    list_has_path "$output" "$HOME/Library/Containers/com.acme.Foo.Share" || return 1
    ! list_has_path "$output" "$HOME/Library/Containers/com.acme.Foo.Bar" || return 1
    ! list_has_path "$output" "$HOME/Library/Application Scripts/com.acme.Foo.helper" || return 1

    # The other product's data must still be on disk.
    [ -d "$HOME/Library/Containers/com.acme.Foo.Bar" ] || return 1
    [ -d "$HOME/Library/Application Scripts/com.acme.Foo.helper" ]
}

@test "B1-03 an embedded helper id still claims its container and script dir" {
    make_foo_fixtures
    mkdir -p "$HOME/Library/Application Scripts/com.acme.Foo.Share"

    run find_app_files "com.acme.Foo" "Foo" "$HOME/Applications/Foo.app"
    [ "$status" -eq 0 ]

    list_has_path "$output" "$HOME/Library/Application Scripts/com.acme.Foo.Share" || return 1
    list_has_path "$output" "$HOME/Library/Containers/com.acme.Foo.Share"
}

@test "B1-03 without an installed app path the previous prefix behavior stands" {
    make_foo_fixtures

    # No app_path: there is no embedded bundle table to check against, so the
    # callers that pass only ids/names keep their old derived-root results.
    run find_app_files "com.acme.Foo" "Foo"
    [ "$status" -eq 0 ]

    list_has_path "$output" "$HOME/Library/Containers/com.acme.Foo" || return 1
    list_has_path "$output" "$HOME/Library/Containers/com.acme.Foo.Share"
}

@test "B1-03 a bundle with no nested code claims no prefix-only derived root" {
    # PlayCover-style flat bundle: there is no Contents/ to read embedded ids
    # from. With nothing proven embedded, prefix-only roots are skipped.
    local app="$HOME/Applications/Foo.app"
    mkdir -p "$app"
    : > "$app/Info.plist"
    mkdir -p "$HOME/Library/Containers/com.acme.Foo"
    mkdir -p "$HOME/Library/Containers/com.acme.Foo.Bar"

    run find_app_files "com.acme.Foo" "Foo" "$app"
    [ "$status" -eq 0 ]

    list_has_path "$output" "$HOME/Library/Containers/com.acme.Foo" || return 1
    ! list_has_path "$output" "$HOME/Library/Containers/com.acme.Foo.Bar"
}

@test "B1-03 batch.sh passes the selected app path into find_app_files" {
    # The guard above is only reachable when the real uninstall flow supplies
    # app_path; pin that call site so the B1-03 fix cannot silently fall back.
    local call=""
    call=$(grep -A2 'find_app_files "\$bundle_id" "\$discovery_app_name"' \
        "$PROJECT_ROOT/lib/uninstall/batch.sh") || return 1

    [[ "$call" == *'"$app_path"'* ]]
}
