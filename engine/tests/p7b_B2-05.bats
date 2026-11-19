#!/usr/bin/env bats

load helpers/common

# B2-05: when CFBundleExecutable cannot be read, diagnostic-report matching
# used only the no-space app name ("Foo 2" -> "Foo2") and missed reports named
# after the bundle basename with its spaces ("Foo 2-<date>.ips"). The fallback
# now tries both prefixes, with the same " Helper" expansion for each.
#
# The CrashReporter half is pinned here as well: "Foo Bar.app" can leave
# "Foo Bar_<UUID>.plist" while another tool writes "FooBar_<UUID>.plist", so
# both prefixes must stay in the scan.

setup_file() {
    mole_test_setup_home p7b-B2-05
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

@test "diagnostic reports fall back to spaced and unspaced bundle names" {
    local reports="$HOME/Library/Logs/DiagnosticReports"
    local app="$HOME/Applications/Foo 2.app"
    mkdir -p "$reports" "$app/Contents"
    # No CFBundleExecutable: this is the unreadable-plist fallback.
    cat > "$app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.foo2</string>
</dict></plist>
PLIST

    : > "$reports/Foo 2-2026-11-19-101010.ips"
    : > "$reports/Foo2-2026-11-19-101011.ips"
    : > "$reports/Foo 2 Helper-2026-11-19-101012.ips"
    : > "$reports/Foo2 Helper-2026-11-19-101013.ips"
    : > "$reports/Foobar-2026-11-19-101014.ips"
    : > "$reports/Foo 2 Beta-2026-11-19-101015.ips"

    run get_diagnostic_report_paths_for_app "$app" "Foo 2" "$reports"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Foo 2-2026-11-19-101010.ips"* ]] || return 1
    [[ "$output" == *"Foo2-2026-11-19-101011.ips"* ]] || return 1
    [[ "$output" == *"Foo 2 Helper-2026-11-19-101012.ips"* ]] || return 1
    [[ "$output" == *"Foo2 Helper-2026-11-19-101013.ips"* ]] || return 1
    [[ "$output" != *"Foobar-"* ]] || return 1
    [[ "$output" != *"Foo 2 Beta"* ]]
}

@test "find_app_files claims both spaced and unspaced CrashReporter plists" {
    local crash="$HOME/Library/Application Support/CrashReporter"
    mkdir -p "$crash"
    : > "$crash/Foo Bar_OWN-SPACED.plist"
    : > "$crash/FooBar_OWN-NOSPACE.plist"
    : > "$crash/Foobar_OTHER.plist"

    run find_app_files "com.example.foo.bar" "Foo Bar"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Foo Bar_OWN-SPACED.plist"* ]] || return 1
    [[ "$output" == *"FooBar_OWN-NOSPACE.plist"* ]] || return 1
    [[ "$output" != *"Foobar_OTHER.plist"* ]]
}

@test "a readable CFBundleExecutable keeps the diagnostic scan on its own prefix" {
    local reports="$HOME/Library/Logs/DiagnosticReports"
    local app="$HOME/Applications/Foo 2.app"
    mkdir -p "$reports" "$app/Contents"
    cat > "$app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>FooBar</string>
</dict></plist>
PLIST

    : > "$reports/FooBar-2026-11-19-101010.ips"
    : > "$reports/Foo 2-2026-11-19-101011.ips"

    run get_diagnostic_report_paths_for_app "$app" "Foo 2" "$reports"

    [ "$status" -eq 0 ]
    [[ "$output" == *"FooBar-2026-11-19-101010.ips"* ]] || return 1
    [[ "$output" != *"Foo 2-"* ]]
}