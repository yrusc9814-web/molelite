#!/usr/bin/env bats

load helpers/common

# B2-02: the JetBrains leftover scan built its find pattern from the display
# name ("IntelliJ IDEA*"), but the IDE writes a compact product code:
#   IntelliJ IDEA           -> ~/Library/.../JetBrains/IntelliJIdea2024.1
#   IntelliJ IDEA CE        -> ~/Library/.../JetBrains/IdeaIC2024.1
# Neither has the space, and the second also has a different product code, so
# both stayed behind whenever Info.plist had no idea.paths.selector (CE, EAP
# and repackaged builds). These tests keep fixtures in a throwaway HOME.

setup_file() {
    mole_test_setup_home p7b-B2-02
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

# One bundle whose Info.plist declares the given id. No JVMOptions selector is
# written on purpose: that is the CE/EAP/repackaged case B2-02 is about.
make_bundle() {
    local path="$1" bundle_id="$2" exec_name="${3:-}"
    mkdir -p "$path/Contents/MacOS"
    {
        printf '%s\n' '<plist version="1.0"><dict>'
        printf '  <key>CFBundleIdentifier</key><string>%s</string>\n' "$bundle_id"
        if [[ -n "$exec_name" ]]; then
            printf '  <key>CFBundleExecutable</key><string>%s</string>\n' "$exec_name"
        fi
        printf '%s\n' '</dict></plist>'
    } > "$path/Contents/Info.plist"
}

# The three JetBrains roots, each holding one versioned IDE leaf.
make_jetbrains_fixtures() {
    local leaf="$1"
    mkdir -p "$HOME/Library/Application Support/JetBrains/$leaf" \
        "$HOME/Library/Caches/JetBrains/$leaf" \
        "$HOME/Library/Logs/JetBrains/$leaf"
}

@test "B2-02 IntelliJ IDEA without a selector claims IntelliJIdea leaves" {
    # Before the fix find -name "IntelliJ IDEA*" never matched the real
    # "IntelliJIdea2024.1" directories and the uninstall left all settings.
    local apps="$HOME/apps"
    make_bundle "$apps/IntelliJ IDEA.app" "com.jetbrains.intellij" "idea"
    make_jetbrains_fixtures IntelliJIdea2024.1

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.jetbrains.intellij" "IntelliJ IDEA" "$apps/IntelliJ IDEA.app")

    list_has_path "$result" "$HOME/Library/Application Support/JetBrains/IntelliJIdea2024.1" || return 1
    list_has_path "$result" "$HOME/Library/Caches/JetBrains/IntelliJIdea2024.1" || return 1
    list_has_path "$result" "$HOME/Library/Logs/JetBrains/IntelliJIdea2024.1"
}

@test "B2-02 IntelliJ IDEA CE without a selector claims IdeaIC leaves" {
    # CE uses a different product code, so even a compact-name fallback is not
    # enough; the exact com.jetbrains.intellij.ce id supplies "IdeaIC".
    local apps="$HOME/apps"
    make_bundle "$apps/IntelliJ IDEA CE.app" "com.jetbrains.intellij.ce" "idea"
    make_jetbrains_fixtures IdeaIC2024.1

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.jetbrains.intellij.ce" "IntelliJ IDEA CE" "$apps/IntelliJ IDEA CE.app")

    list_has_path "$result" "$HOME/Library/Application Support/JetBrains/IdeaIC2024.1" || return 1
    list_has_path "$result" "$HOME/Library/Caches/JetBrains/IdeaIC2024.1" || return 1
    list_has_path "$result" "$HOME/Library/Logs/JetBrains/IdeaIC2024.1"
}

@test "B2-02 an IntelliJ channel does not claim the other channel's leaves" {
    # Ultimate (com.jetbrains.intellij) and Community (…intellij.ce) are
    # different products; uninstalling one must not wipe the other's licence
    # and plugin state when both are installed.
    local apps="$HOME/apps"
    make_bundle "$apps/IntelliJ IDEA CE.app" "com.jetbrains.intellij.ce" "idea"
    make_jetbrains_fixtures IntelliJIdea2024.1
    mkdir -p "$HOME/Library/Application Support/JetBrains/IdeaIC2024.1"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.jetbrains.intellij.ce" "IntelliJ IDEA CE" "$apps/IntelliJ IDEA CE.app")

    # The CE leaf is claimed; the Ultimate leaf is not.
    list_has_path "$result" "$HOME/Library/Application Support/JetBrains/IdeaIC2024.1" || return 1
    ! list_has_path "$result" "$HOME/Library/Application Support/JetBrains/IntelliJIdea2024.1"
}

@test "B2-02 an unrelated app called IntelliJ IDEA still claims no JetBrains leaf" {
    # The extra product codes are keyed by JetBrains' exact bundle id; a
    # namesake app keeps only its own bundle-id paths (B1-13 boundary).
    local apps="$HOME/apps"
    make_bundle "$apps/IntelliJ IDEA.app" "com.acme.intellij" "idea"
    make_jetbrains_fixtures IntelliJIdea2024.1

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.intellij" "IntelliJ IDEA" "$apps/IntelliJ IDEA.app")

    ! list_has_path "$result" "$HOME/Library/Application Support/JetBrains/IntelliJIdea2024.1" || return 1
    ! list_has_path "$result" "$HOME/Library/Caches/JetBrains/IntelliJIdea2024.1" || return 1
    ! list_has_path "$result" "$HOME/Library/Logs/JetBrains/IntelliJIdea2024.1"
}

@test "B2-02 a real PyCharm still claims only its own versioned leaves" {
    # Other JetBrains products already worked through the compact display
    # name; the all-entry scan and product-code boundary must keep them.
    local apps="$HOME/apps"
    make_bundle "$apps/PyCharm.app" "com.jetbrains.pycharm" "pycharm"
    make_jetbrains_fixtures PyCharm2024.1
    mkdir -p "$HOME/Library/Application Support/JetBrains/PyCharm2024.1-backup"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.jetbrains.pycharm" "PyCharm" "$apps/PyCharm.app")

    list_has_path "$result" "$HOME/Library/Application Support/JetBrains/PyCharm2024.1" || return 1
    list_has_path "$result" "$HOME/Library/Caches/JetBrains/PyCharm2024.1" || return 1
    list_has_path "$result" "$HOME/Library/Logs/JetBrains/PyCharm2024.1" || return 1
    ! list_has_path "$result" "$HOME/Library/Application Support/JetBrains/PyCharm2024.1-backup"
}
