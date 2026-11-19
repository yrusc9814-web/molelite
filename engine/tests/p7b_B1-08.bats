#!/usr/bin/env bats

load helpers/common

# B1-08: find_app_files derives data folders from a bundle id's last segment
# when that leaf extends the display name: "AyuGram" + one.ayugram.AyuGramDesktop
# reaches "Application Support/AyuGram Desktop". The derivation only checked
# that the leaf was glued to the display name, so a short display name handed
# another product's folders over:
#
#   "Code"   + com.acme.CodeRunner      -> "Application Support/CodeRunner",
#                                         "Caches/CodeRunner", "CodeRunner.plist",
#                                         "CodeRunner.savedState"
#   "Notion" + com.notion.NotionCalendar -> the same for NotionCalendar, which
#                                         is the real shipped shape: the
#                                         calendar product's bundle on disk is
#                                         literally "Notion Calendar.app".
#
# The fix asks the installed-bundle probe (case- and space-folded) whether a
# derived leaf names a bundle of its own, and keeps the whole derived group
# when it does. Real channels keep deriving because no bundle carries their
# leaf. Fixtures live in a throwaway HOME; nothing here touches the real
# Library.

setup_file() {
    mole_test_setup_home p7b-B1-08
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

# Every leaf the bundle-id derivation adds, for one derived name.
make_derived_leaf_fixtures() {
    local leaf="$1"
    mkdir -p "$HOME/Library/Application Support/$leaf" \
        "$HOME/Library/Caches/$leaf" \
        "$HOME/Library/Logs/$leaf" \
        "$HOME/Library/Preferences" \
        "$HOME/Library/Saved Application State/$leaf.savedState"
    : > "$HOME/Library/Preferences/$leaf.plist"
}

@test "B1-08 the Acme wrapper does not claim an installed AcmeRunner's data" {
    # The reported "Code" + com.acme.CodeRunner shape, spelled with a name
    # that is not already a shared product word (B1-05 keeps "Code" itself
    # out of the name templates), so the positive side is observable.
    local apps="$HOME/apps"
    mkdir -p "$apps/Acme.app" "$apps/AcmeRunner.app"
    make_derived_leaf_fixtures AcmeRunner
    # The app's own display-name folders exist too, so a miss is meaningful.
    mkdir -p "$HOME/Library/Application Support/Acme" "$HOME/Library/Caches/Acme"
    : > "$HOME/Library/Preferences/Acme.plist"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.AcmeRunner" "Acme" "$apps/Acme.app")

    [[ "$result" != *"Application Support/AcmeRunner"* ]] || return 1
    [[ "$result" != *"Caches/AcmeRunner"* ]] || return 1
    [[ "$result" != *"Logs/AcmeRunner"* ]] || return 1
    [[ "$result" != *"Preferences/AcmeRunner.plist"* ]] || return 1
    [[ "$result" != *"AcmeRunner.savedState"* ]] || return 1
    # The wrapper's own folders are still its own data.
    list_has_path "$result" "$HOME/Library/Application Support/Acme" || return 1
    list_has_path "$result" "$HOME/Library/Preferences/Acme.plist"
}

@test "B1-08 the split spelling stays out too while the product is installed" {
    local apps="$HOME/apps"
    # One collision keeps the whole derived group: "AcmeRunner" is one
    # product, and its split spelling is the same vendor's product too.
    mkdir -p "$apps/Acme.app" "$apps/AcmeRunner.app"
    mkdir -p "$HOME/Library/Application Support/Acme Runner" \
        "$HOME/Library/Caches/Acme Runner" \
        "$HOME/Library/Preferences"
    : > "$HOME/Library/Preferences/Acme Runner.plist"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.AcmeRunner" "Acme" "$apps/Acme.app")

    [[ "$result" != *"Acme Runner"* ]]
}

@test "B1-08 Notion does not claim an installed Notion Calendar's data" {
    local apps="$HOME/apps"
    # The reported real shape: the calendar bundle is "Notion Calendar.app",
    # which only differs from the derived leaf "NotionCalendar" by a space.
    mkdir -p "$apps/Notion.app" "$apps/Notion Calendar.app"
    make_derived_leaf_fixtures NotionCalendar
    mkdir -p "$HOME/Library/Application Support/Notion" \
        "$HOME/Library/Caches/Notion" \
        "$HOME/Library/Application Support/Notion Calendar"
    : > "$HOME/Library/Preferences/Notion.plist"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.notion.NotionCalendar" "Notion" "$apps/Notion.app")

    [[ "$result" != *"NotionCalendar"* ]] || return 1
    [[ "$result" != *"Application Support/Notion Calendar"* ]] || return 1
    # Notion's own data still belongs to Notion.
    list_has_path "$result" "$HOME/Library/Application Support/Notion" || return 1
    list_has_path "$result" "$HOME/Library/Preferences/Notion.plist"
}

@test "B1-08 a real channel still derives its leaf with no product of that name" {
    # Regression guard against over-narrowing: AyuGram's "Desktop" leaf names
    # no installed bundle, so both spellings must keep deriving.
    local apps="$HOME/apps"
    mkdir -p "$apps/AyuGram.app" "$apps/AyuGram Desktop Deluxe.app"
    mkdir -p "$HOME/Library/Application Support/AyuGram Desktop" \
        "$HOME/Library/Application Support/AyuGramDesktop"

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "one.ayugram.AyuGramDesktop" "AyuGram" "$apps/AyuGram.app")

    list_has_path "$result" "$HOME/Library/Application Support/AyuGram Desktop" || return 1
    list_has_path "$result" "$HOME/Library/Application Support/AyuGramDesktop"
}

@test "B1-08 the app being removed is not its own collision" {
    local apps="$HOME/apps"
    # Removing AcmeRunner.app itself: its leaf names exactly the selected
    # bundle, so the derivation must still claim that app's data.
    mkdir -p "$apps/AcmeRunner.app"
    make_derived_leaf_fixtures AcmeRunner

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.AcmeRunner" "Acme" "$apps/AcmeRunner.app")

    list_has_path "$result" "$HOME/Library/Application Support/AcmeRunner" || return 1
    list_has_path "$result" "$HOME/Library/Preferences/AcmeRunner.plist"
}

@test "B1-08 a longer product name proves no ownership of the derived leaf" {
    local apps="$HOME/apps"
    # Only an exact name collides; "AcmeRunner Deluxe.app" is another product.
    mkdir -p "$apps/Acme.app" "$apps/AcmeRunner Deluxe.app"
    make_derived_leaf_fixtures AcmeRunner

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.AcmeRunner" "Acme" "$apps/Acme.app")

    list_has_path "$result" "$HOME/Library/Application Support/AcmeRunner" || return 1
    list_has_path "$result" "$HOME/Library/Preferences/AcmeRunner.plist"
}
