#!/usr/bin/env bats

load helpers/common

# B1-16: a crash report is matched to an app by a name prefix, and the prefix
# ends at the first "."/"_"/"-". "Foo.app" (CFBundleExecutable=Foo) therefore
# claimed "Foo-Bar-<date>.ips" / "Foo_Bar-<date>.ips", which belong to
# Foo-Bar.app, and review.sh:13 deletes everything under ~/Library/Logs without
# asking (no D menu). The report header itself records the writer's bundle id,
# so a readable id that names another bundle now refuses the file. A report with
# no readable id keeps the name-only match, because that is the only evidence
# there and the sweep must still collect this app's own legacy reports.
#
# Fixtures live in a throwaway HOME; nothing here touches the real Library.

setup_file() {
    mole_test_setup_home p7b-B1-16
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

# Write an Info.plist for one app bundle.
write_app() {
    local app="$1" exec_name="$2" bundle_id="$3"
    mkdir -p "$app/Contents"
    cat > "$app/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$exec_name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
</dict></plist>
PLIST
}

# Write a one-line JSON header, the shape a real .ips file starts with.
write_ips() {
    local report="$1" name="$2" bundle_id="$3"
    printf '{"app_name":"%s","bundleID":"%s","procPath":"/Applications/%s.app/Contents/MacOS/%s"}\n{"uptime":42}\n' \
        "$name" "$bundle_id" "$name" "$name" > "$report"
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

@test "B1-16 refuses a sibling app's report that only shares the name prefix" {
    local reports="$HOME/Library/Logs/DiagnosticReports"
    local app="$HOME/Applications/Foo.app"
    mkdir -p "$reports"
    write_app "$app" "Foo" "com.example.foo"

    write_ips "$reports/Foo-2024-01-02-101010.ips" "Foo" "com.example.foo"
    write_ips "$reports/Foo-Bar-2024-01-01-101010.ips" "Foo-Bar" "com.example.foobar"
    write_ips "$reports/Foo_Bar-2024-01-01-101011.ips" "Foo_Bar" "com.example.foo2"

    run get_diagnostic_report_paths_for_app "$app" "Foo" "$reports"

    [ "$status" -eq 0 ] || return 1
    list_has_path "$output" "$reports/Foo-2024-01-02-101010.ips" || return 1
    ! list_has_path "$output" "$reports/Foo-Bar-2024-01-01-101010.ips" || return 1
    ! list_has_path "$output" "$reports/Foo_Bar-2024-01-01-101011.ips" || return 1
    # Refused only, never removed: both reports are still on disk.
    [[ -f "$reports/Foo-Bar-2024-01-01-101010.ips" ]] || return 1
    [[ -f "$reports/Foo_Bar-2024-01-01-101011.ips" ]]
}

@test "B1-16 keeps this app's own report and its helper's report" {
    local reports="$HOME/Library/Logs/DiagnosticReports"
    local app="$HOME/Applications/Foo.app"
    mkdir -p "$reports"
    write_app "$app" "Foo" "com.example.foo"

    write_ips "$reports/Foo Helper-2024-01-01-101010.ips" "Foo Helper" "com.example.foo.helper"
    # APFS folds case, so a differently cased own id is still this bundle.
    write_ips "$reports/Foo-2024-01-01-101011.ips" "Foo" "COM.Example.Foo"

    run get_diagnostic_report_paths_for_app "$app" "Foo" "$reports"

    [ "$status" -eq 0 ] || return 1
    list_has_path "$output" "$reports/Foo Helper-2024-01-01-101010.ips" || return 1
    list_has_path "$output" "$reports/Foo-2024-01-01-101011.ips"
}

@test "B1-16 refuses a legacy crash report whose Identifier names another bundle" {
    local reports="$HOME/Library/Logs/DiagnosticReports"
    local app="$HOME/Applications/Foo.app"
    mkdir -p "$reports"
    write_app "$app" "Foo" "com.example.foo"

    printf 'Process: Foo\nPath: /Applications/Foo.app/Contents/MacOS/Foo\nIdentifier: com.example.foo\n' \
        > "$reports/Foo_2024-01-01-101010.crash"
    printf 'Process: Foo_Bar\nPath: /Applications/Foo_Bar.app/Contents/MacOS/Foo_Bar\nIdentifier: com.example.foobar\n' \
        > "$reports/Foo_Bar_2024-01-01-101011.crash"

    run get_diagnostic_report_paths_for_app "$app" "Foo" "$reports"

    [ "$status" -eq 0 ] || return 1
    list_has_path "$output" "$reports/Foo_2024-01-01-101010.crash" || return 1
    ! list_has_path "$output" "$reports/Foo_Bar_2024-01-01-101011.crash"
}

@test "B1-16 falls back to procPath when a report names no bundle id" {
    local reports="$HOME/Library/Logs/DiagnosticReports"
    local app="$HOME/Applications/Foo.app"
    mkdir -p "$reports"
    write_app "$app" "Foo" "com.example.foo"

    # No bundleID in the header; only the process path identifies the writer.
    printf '{"app_name":"Foo","procPath":"/Applications/Foo.app/Contents/MacOS/Foo"}\n{}\n' \
        > "$reports/Foo-2024-01-01-101010.ips"
    printf '{"app_name":"Foo 2","procPath":"/Applications/Foo 2.app/Contents/MacOS/Foo 2"}\n{}\n' \
        > "$reports/Foo_2-2024-01-01-101011.ips"
    # Legacy text header: Path names the writer, no Identifier.
    printf 'Process: Foo-Bar\nPath: /Applications/Foo-Bar.app/Contents/MacOS/Foo-Bar\n' \
        > "$reports/Foo-Bar-2024-01-01-101012.crash"

    run get_diagnostic_report_paths_for_app "$app" "Foo" "$reports"

    [ "$status" -eq 0 ] || return 1
    list_has_path "$output" "$reports/Foo-2024-01-01-101010.ips" || return 1
    ! list_has_path "$output" "$reports/Foo_2-2024-01-01-101011.ips" || return 1
    ! list_has_path "$output" "$reports/Foo-Bar-2024-01-01-101012.crash"
}

@test "B1-16 refuses a spaced sibling app's report that only shares the name prefix" {
    # Foo.app / CFBundleExecutable=Foo claims "Foo_<date>.ips"; the sibling
    # "Foo 2.app" leaves "Foo_2-<date>.ips", which the same "_" rule reaches.
    local reports="$HOME/Library/Logs/DiagnosticReports"
    local app="$HOME/Applications/Foo.app"
    local sibling="$HOME/Applications/Foo 2.app"
    mkdir -p "$reports"
    write_app "$app" "Foo" "com.example.foo"
    write_app "$sibling" "Foo 2" "com.example.foo2"

    write_ips "$reports/Foo_2-2024-02-01-101010.ips" "Foo 2" "com.example.foo2"
    write_ips "$reports/Foo_2024-02-01-101011.ips" "Foo" "com.example.foo"

    run get_diagnostic_report_paths_for_app "$app" "Foo" "$reports"

    [ "$status" -eq 0 ] || return 1
    ! list_has_path "$output" "$reports/Foo_2-2024-02-01-101010.ips" || return 1
    list_has_path "$output" "$reports/Foo_2024-02-01-101011.ips" || return 1
    # Only refused, never deleted.
    [[ -f "$reports/Foo_2-2024-02-01-101010.ips" ]]
}

@test "B1-16 does not pathname-expand a glob metacharacter in procPath" {
    # procPath is report content, so a "*" in it must not expand against the
    # caller's working directory into this app's own bundle name.
    local reports="$HOME/Library/Logs/DiagnosticReports"
    local app="$HOME/Applications/Foo.app"
    local workdir="$HOME/workdir"
    mkdir -p "$reports" "$workdir/Foo.app"
    write_app "$app" "Foo" "com.example.foo"

    # No bundleID: only procPath speaks, and only an expanded "/*.app" names
    # this app's bundle. A literal read leaves "*.app", which owns nothing.
    printf '{"app_name":"Foo Bar","procPath":"/*.app/Contents/MacOS/Foo Bar"}\n{}\n' \
        > "$reports/Foo-Bar-2024-03-01-101010.ips"

    cd "$workdir" || return 1
    run get_diagnostic_report_paths_for_app "$app" "Foo" "$reports"
    cd "$BATS_TEST_DIRNAME" || return 1

    [ "$status" -eq 0 ] || return 1
    ! list_has_path "$output" "$reports/Foo-Bar-2024-03-01-101010.ips"
}

@test "B1-16 keeps name matching when no bundle id or report header is readable" {
    local reports="$HOME/Library/Logs/DiagnosticReports"
    local app="$HOME/Applications/Foo.app"
    local no_plist="$HOME/Applications/Foo 2.app"
    mkdir -p "$reports" "$no_plist/Contents"
    write_app "$app" "Foo" "com.example.foo"

    # Empty reports (no header) are the pre-B1-16 fixtures and real truncated
    # files; without an id the prefix match stays the only evidence.
    : > "$reports/Foo-2024-01-01-101010.ips"
    : > "$reports/Foo Helper-2024-01-01-101011.diag"
    : > "$reports/Foo 2-2024-01-01-101012.ips"

    run get_diagnostic_report_paths_for_app "$app" "Foo" "$reports"
    [ "$status" -eq 0 ] || return 1
    list_has_path "$output" "$reports/Foo-2024-01-01-101010.ips" || return 1
    list_has_path "$output" "$reports/Foo Helper-2024-01-01-101011.diag" || return 1

    # A bundle without a readable id cannot prove anyone else's ownership, so
    # its basename fallback still collects the report named after it.
    run get_diagnostic_report_paths_for_app "$no_plist" "Foo 2" "$reports"
    [ "$status" -eq 0 ] || return 1
    list_has_path "$output" "$reports/Foo 2-2024-01-01-101012.ips"
}
