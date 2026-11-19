#!/usr/bin/env bats

load helpers/common

# A launchd label can be reused by another installed app. When an exact
# bundle-id plist names a program outside the selected bundle, its filename
# alone must not authorize teardown or deletion (B1-19).

setup_file() {
    mole_test_setup_home p7b_b1_19
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    find "$HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2> /dev/null || true

    export MOLE_TEST_NO_AUTH=1
    export MOLE_DELETE_MODE=trash
    export MOLE_TEST_TRASH_DIR="$HOME/Trash"
    export MOLE_DELETE_LOG="$HOME/deletions.log"
    export P7B_OTHER_PROGRAM="$HOME/Applications/Bar.app/Contents/MacOS/Bar"
    export P7B_OWNED_PROGRAM="$HOME/Applications/Legacy.app/Contents/MacOS/Legacy"

    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/fake-bin" \
        "$HOME/Applications/Legacy.app/Contents/MacOS" \
        "$HOME/Applications/Bar.app/Contents/MacOS"
    : > "$P7B_OWNED_PROGRAM"
    : > "$P7B_OTHER_PROGRAM"

    cat > "$HOME/fake-bin/plutil" <<'SH'
#!/bin/bash
[[ "${1:-}" == "-extract" ]] || exit 1
key="${2:-}"
file="${4:-}"
case "${file##*/}:$key" in
    com.vendor.legacy.plist:Program) printf '%s' "$P7B_OTHER_PROGRAM" ;;
    com.vendor.legacy.helper.plist:Program) printf '%s' "$P7B_OWNED_PROGRAM" ;;
    com.vendor.owned.plist:Program) printf '%s' "$P7B_OWNED_PROGRAM" ;;
    com.vendor.argv.plist:ProgramArguments.0) printf '%s' "$P7B_OTHER_PROGRAM" ;;
    com.vendor.selfargv.plist:ProgramArguments.0) printf '%s' "$P7B_OWNED_PROGRAM" ;;
    *) exit 1 ;;
esac
SH
    chmod +x "$HOME/fake-bin/plutil"
}

_write_plist() {
    local plist="$1" key="$2" value="$3"
    cat > "$plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>$key</key><string>$value</string></dict></plist>
PLIST
}

@test "exact launch label naming another app is neither planned nor deleted" {
    local app="$HOME/Applications/Legacy.app"
    local foreign="$HOME/Library/LaunchAgents/com.vendor.legacy.plist"
    local owned="$HOME/Library/LaunchAgents/com.vendor.legacy.helper.plist"
    _write_plist "$foreign" Program "$P7B_OTHER_PROGRAM"
    _write_plist "$owned" Program "$P7B_OWNED_PROGRAM"

    run env PROJECT_ROOT="$PROJECT_ROOT" HOME="$HOME" \
        PATH="$HOME/fake-bin:$PATH" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
source "$PROJECT_ROOT/tests/helpers/uninstall.bash"
mole_test_isolate_uninstall_inventory
app="$HOME/Applications/Legacy.app"
foreign="$HOME/Library/LaunchAgents/com.vendor.legacy.plist"
owned="$HOME/Library/LaunchAgents/com.vendor.legacy.helper.plist"

plan=$(find_app_files com.vendor.legacy "Legacy App" "$app")
[[ "$plan" != *"$foreign"* ]] || { echo "planned foreign agent"; exit 1; }
[[ "$plan" == *"$owned"* ]] || { echo "lost owned agent"; exit 1; }

# The app has moved when batch removal reaches the leftover list, as it has
# during a real uninstall.
mv "$app" "$HOME/moved-Legacy.app"
remove_file_list "$foreign" false com.vendor.legacy "$app" > /dev/null
[[ -f "$foreign" ]] || { echo "foreign agent deleted"; exit 1; }
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "exact launch label with its own program or no program stays owned" {
    _write_plist "$HOME/Library/LaunchAgents/com.vendor.owned.plist" \
        Program "$P7B_OWNED_PROGRAM"
    _write_plist "$HOME/Library/LaunchAgents/com.vendor.selfargv.plist" \
        ProgramArguments "$P7B_OWNED_PROGRAM"
    : > "$HOME/Library/LaunchAgents/com.vendor.empty.plist"

    run env PROJECT_ROOT="$PROJECT_ROOT" HOME="$HOME" \
        PATH="$HOME/fake-bin:$PATH" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/core/app_protection.sh"
for spec in "com.vendor.owned:com.vendor.owned.plist" \
    "com.vendor.selfargv:com.vendor.selfargv.plist" \
    "com.vendor.empty:com.vendor.empty.plist"; do
    bundle_id="${spec%%:*}"
    plist="$HOME/Library/LaunchAgents/${spec#*:}"
    rc=0
    mole_uninstall_launch_agent_owned_by_app "$plist" "$bundle_id" \
        "$HOME/Applications/Legacy.app" || rc=$?
    [[ $rc -eq 0 ]] || { echo "unowned exact agent: $plist rc=$rc"; exit 1; }
done
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "exact launch label with only foreign ProgramArguments stays unowned" {
    _write_plist "$HOME/Library/LaunchAgents/com.vendor.argv.plist" \
        ProgramArguments "$P7B_OTHER_PROGRAM"

    run env PROJECT_ROOT="$PROJECT_ROOT" HOME="$HOME" \
        PATH="$HOME/fake-bin:$PATH" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/core/app_protection.sh"
rc=0
mole_uninstall_launch_agent_owned_by_app \
    "$HOME/Library/LaunchAgents/com.vendor.argv.plist" com.vendor.argv \
    "$HOME/Applications/Legacy.app" || rc=$?
[[ $rc -eq 1 ]] || { echo "foreign argv agent accepted: rc=$rc"; exit 1; }
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}
