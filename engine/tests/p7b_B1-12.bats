#!/usr/bin/env bats

load helpers/common

# B1-12: the Android Studio toolchain rule in find_app_files triggered on an
# unanchored name regex (/Android.*Studio|android.*studio/) or a loose
# bundle-id regex (/google.*android.*studio|jetbrains.*android/), so
# uninstalling "NotAndroid Studio.app" or "Android Paint Studio.app" swept
# ~/.android/cache, ~/.android/build-cache and ~/.android/breakpad.
# ~/.android/build-cache is Gradle's cross-project build cache (shared by
# every Gradle project on the machine, not an Android Studio leaf), and
# ~/.android also holds the SDK's own state, so a name that merely spells
# "Android ... Studio" must not claim any of it.
#
# The fix requires ownership: Google's com.google.android.studio bundle id
# (plus channel/helper continuations) or a bundle declaring
# CFBundleExecutable "studio". build-cache is dropped from the sweep entirely
# because Gradle, not Android Studio, owns it. Fixtures live in a throwaway
# HOME; nothing here touches the real ~/.android.

setup_file() {
    mole_test_setup_home p7b-B1-12
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

# The three toolchain cache roots the Android Studio rule used to sweep.
make_android_fixtures() {
    mkdir -p "$HOME/.android/build-cache/9f2a" \
        "$HOME/.android/cache/gradle" \
        "$HOME/.android/breakpad/abcd"
    : > "$HOME/.android/adbkey"
    : > "$HOME/.android/debug.keystore"
    mkdir -p "$HOME/.android/avd/Pixel_5.avd"
}

# Make one bundle whose Info.plist declares the given id and executable. An
# empty executable reproduces a bundle with no CFBundleExecutable key.
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

@test "B1-12 NotAndroid Studio.app does not claim Gradle's shared .android caches" {
    # Before the fix the name regex /Android.*Studio/ matched and all three
    # cache roots were queued for removal without a prompt.
    local apps="$HOME/apps"
    make_bundle "$apps/NotAndroid Studio.app" "com.acme.notandroidstudio" "NotAndroid Studio"
    make_android_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.notandroidstudio" "NotAndroid Studio" \
        "$apps/NotAndroid Studio.app")

    ! list_has_path "$result" "$HOME/.android/build-cache" || return 1
    ! list_has_path "$result" "$HOME/.android/cache" || return 1
    ! list_has_path "$result" "$HOME/.android/breakpad"
}

@test "B1-12 Android Paint Studio.app with a non-Google bundle id claims nothing under .android" {
    # The loose bundle-id arm /google.*android.*studio/ accepted an id such as
    # com.notgoogle.androidpaintstudio; the ownership check now rejects it.
    local apps="$HOME/apps"
    make_bundle "$apps/Android Paint Studio.app" "com.notgoogle.androidpaintstudio" "Android Paint Studio"
    make_android_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.notgoogle.androidpaintstudio" "Android Paint Studio" \
        "$apps/Android Paint Studio.app")

    ! list_has_path "$result" "$HOME/.android/cache" || return 1
    ! list_has_path "$result" "$HOME/.android/breakpad" || return 1
    ! list_has_path "$result" "$HOME/.android/build-cache"
}

@test "B1-12 an Android-Studio-shaped name with no Info.plist keeps the caches" {
    # Unreadable ownership is unknown, so nothing is collected (fail-safe).
    local apps="$HOME/apps"
    mkdir -p "$apps/Android Studio Helper.app/Contents"
    make_android_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.studiohelper" "Android Studio Helper" \
        "$apps/Android Studio Helper.app")

    ! list_has_path "$result" "$HOME/.android/cache" || return 1
    ! list_has_path "$result" "$HOME/.android/breakpad"
}

@test "B1-12 Google's Android Studio still sweeps its own .android caches but never build-cache" {
    # The fix must not stop a real Android Studio uninstall from reclaiming its
    # own regenerable caches; Gradle's build-cache is never Android Studio's.
    local apps="$HOME/apps"
    make_bundle "$apps/Android Studio.app" "com.google.android.studio" "studio"
    make_android_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.google.android.studio" "Android Studio" \
        "$apps/Android Studio.app")

    list_has_path "$result" "$HOME/.android/cache" || return 1
    list_has_path "$result" "$HOME/.android/breakpad" || return 1
    ! list_has_path "$result" "$HOME/.android/build-cache" || return 1
    # Signing key, adb key and AVD images stay even for the real owner.
    ! list_has_path "$result" "$HOME/.android/adbkey" || return 1
    ! list_has_path "$result" "$HOME/.android/debug.keystore" || return 1
    ! list_has_path "$result" "$HOME/.android/avd"
}

@test "B1-12 a hyphen-spelled Google channel id still owns the .android caches" {
    # Google's own channel ids may spell the suffix with a hyphen
    # (com.google.android.studio-canary); that is still Google's product.
    local apps="$HOME/apps"
    make_bundle "$apps/Android Studio Canary.app" "com.google.android.studio-canary" "studio-canary"
    make_android_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.google.android.studio-canary" "Android Studio Canary" \
        "$apps/Android Studio Canary.app")

    list_has_path "$result" "$HOME/.android/cache" || return 1
    ! list_has_path "$result" "$HOME/.android/build-cache"
}

@test "B1-12 a non-Google bundle that declares CFBundleExecutable studio still owns the caches" {
    # Ownership can also come from the bundle itself: Android Studio ships the
    # "studio" executable, so a re-signed or renamed copy keeps its caches.
    local apps="$HOME/apps"
    make_bundle "$apps/Acme Studio Nightly.app" "com.example.studionightly" "studio"
    make_android_fixtures

    result=$(MOLE_TEST_MODE=1 MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.example.studionightly" "Acme Studio Nightly" \
        "$apps/Acme Studio Nightly.app")

    list_has_path "$result" "$HOME/.android/cache" || return 1
    ! list_has_path "$result" "$HOME/.android/build-cache"
}

@test "B1-12 the sibling switch is not the only guard against a lookalike name" {
    # Regression shape: no same-bundle-id sibling survives (SIBLING_SURVIVES is
    # 0 here, as the batch sets it only for a same-bundle-id survivor), yet the
    # caches must stay because the bundle has no Android Studio ownership.
    local apps="$HOME/apps"
    make_bundle "$apps/NotAndroid Studio.app" "com.acme.notandroidstudio" "NotAndroid Studio"
    make_android_fixtures

    result=$(MOLE_UNINSTALL_SIBLING_SURVIVES=0 MOLE_TEST_MODE=1 \
        MOLE_TEST_APP_FAMILY_ROOT="$apps" \
        find_app_files "com.acme.notandroidstudio" "NotAndroid Studio" \
        "$apps/NotAndroid Studio.app")

    ! list_has_path "$result" "$HOME/.android/build-cache" || return 1
    ! list_has_path "$result" "$HOME/.android/cache"
}
