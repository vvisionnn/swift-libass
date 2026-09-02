#!/bin/bash -p

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/support/common.sh
source "$SCRIPT_DIR/support/common.sh"
reject_shell_startup_environment
load_release_configuration

[[ "$#" -le 1 ]] || { echo "usage: $0 [XCFRAMEWORK]" >&2; exit 2; }
XCFRAMEWORK="${1:-$XCFRAMEWORK}"
[[ -d "$XCFRAMEWORK" && ! -L "$XCFRAMEWORK" ]] || {
    echo "Missing or unsafe LibASS XCFramework: $XCFRAMEWORK" >&2
    exit 1
}
XCFRAMEWORK="$(cd "$XCFRAMEWORK" && pwd)"
unsafe_entry="$(/usr/bin/find "$XCFRAMEWORK" ! -type d ! -type f -print -quit)"
[[ -z "$unsafe_entry" ]] || {
    echo "XCFramework contains a symbolic link or special file: $unsafe_entry" >&2
    exit 1
}
VALIDATION_TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/swift-libass-validation.XXXXXX")"
trap '/bin/rm -rf "$VALIDATION_TEMP_ROOT"' EXIT

assert_platform_metadata() {
    local archive="$1" expected_platform="$2" expected_minos="$3" metadata_counts
    metadata_counts="$(/usr/bin/otool -l "$archive" | /usr/bin/awk \
        -v expected_platform="$expected_platform" -v expected_minos="$expected_minos" '
        /^[^[:space:]].*\):$/ { members++ }
        /cmd LC_BUILD_VERSION/ {
            versions++
            getline
            getline
            platform = $2
            getline
            minos = $2
            getline
            if (platform == expected_platform && minos == expected_minos) matching++
        }
        END { print members + 0, versions + 0, matching + 0 }
    ')"
    # The producer emits exactly three space-delimited integer counts.
    # shellcheck disable=SC2086
    set -- $metadata_counts
    [[ "$1" -gt 0 && "$1" -eq "$2" && "$1" -eq "$3" ]] || {
        echo "Incorrect LC_BUILD_VERSION metadata: $archive ($metadata_counts)" >&2
        exit 1
    }
}

assert_symbols() {
    local archive="$1" label="$2" symbol
    /usr/bin/nm "$archive" >"$VALIDATION_TEMP_ROOT/nm-$label.txt"
    for symbol in ass_library_init ass_library_version ass_renderer_init \
        ass_add_font ass_process_chunk ass_process_codec_private ass_render_frame \
        FT_Init_FreeType hb_shape fribidi_log2vis; do
        /usr/bin/grep -Eq "[[:space:]][Tt][[:space:]]_${symbol}$" \
            "$VALIDATION_TEMP_ROOT/nm-$label.txt" || {
            echo "Missing required symbol _$symbol in $label" >&2
            exit 1
        }
    done
    for symbol in FcInit set_linebreaks_utf8 g_malloc u_init; do
        if /usr/bin/grep -Eq "[[:space:]]_${symbol}$" "$VALIDATION_TEMP_ROOT/nm-$label.txt"; then
            echo "Unexpected dependency symbol _$symbol in $label" >&2
            exit 1
        fi
    done
    /usr/bin/grep -Eq '[[:space:]]U[[:space:]]_CTFont' "$VALIDATION_TEMP_ROOT/nm-$label.txt" || {
        echo "CoreText font provider is missing in $label" >&2
        exit 1
    }
    # Darwin x86_64 uses the inode64 ABI suffix for file-metadata APIs.
    /usr/bin/grep -Eq '[[:space:]]U[[:space:]]_fstat([$]INODE64)?$' "$VALIDATION_TEMP_ROOT/nm-$label.txt" || {
        echo "Audited file timestamp dependency is missing in $label" >&2
        exit 1
    }
    for symbol in fgetattrlist fstatfs fstatvfs getattrlist getattrlistat \
        getattrlistbulk mach_absolute_time statfs statvfs; do
        if /usr/bin/grep -Eq "[[:space:]]U[[:space:]]_${symbol}"'([$]INODE64)?$' \
            "$VALIDATION_TEMP_ROOT/nm-$label.txt"; then
            echo "Undeclared required-reason API _$symbol in $label" >&2
            exit 1
        fi
    done
}

assert_framework() {
    local identifier="$1" sdk="$2" platform="$3" minimum="$4"
    shift 4
    local framework="$XCFRAMEWORK/$identifier/LibASS.framework"
    local archive="$framework/LibASS" architectures architecture thin_archive triple metadata
    local expected_architectures="$*" privacy_path="$framework/PrivacyInfo.xcprivacy"
    [[ -f "$archive" ]] || { echo "Missing LibASS archive: $archive" >&2; exit 1; }
    architectures="$(/usr/bin/lipo -archs "$archive" | tr ' ' '\n' | LC_ALL=C sort | xargs)"
    assert_exact_value "$identifier architectures" "$expected_architectures" "$architectures"
    /usr/bin/plutil -lint "$framework/Info.plist" >/dev/null
    assert_exact_value "$identifier bundle identifier" "org.swift-libass.LibASS" \
        "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$framework/Info.plist")"
    assert_exact_value "$identifier bundle version" "$LIBASS_VERSION" \
        "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$framework/Info.plist")"
    assert_exact_value "$identifier executable" "LibASS" \
        "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$framework/Info.plist")"
    /usr/bin/cmp -s "$framework/Headers/LibASS.h" "$SCRIPT_DIR/support/LibASS.h" || {
        echo "Umbrella header differs from canonical header: $identifier" >&2; exit 1;
    }
    local major minor patch expected_version actual_version
    IFS=. read -r major minor patch <<<"$LIBASS_VERSION"
    printf -v expected_version '0x%d%02d%02d000' "$major" "$minor" "$patch"
    actual_version="$(/usr/bin/awk '$1 == "#define" && $2 == "LIBASS_VERSION" { print $3 }' \
        "$framework/Headers/ass/ass.h")"
    assert_exact_value "$identifier header version" "$expected_version" "$actual_version"
    /usr/bin/cmp -s "$framework/Modules/module.modulemap" "$SCRIPT_DIR/support/LibASS.modulemap" || {
        echo "Module map differs from canonical module: $identifier" >&2; exit 1;
    }
    [[ "$sdk" != macosx ]] || privacy_path="$framework/Resources/PrivacyInfo.xcprivacy"
    /usr/bin/cmp -s "$privacy_path" "$LIBASS_PRIVACY_MANIFEST" || {
        echo "Privacy manifest differs from canonical bytes: $identifier" >&2; exit 1;
    }
    /usr/bin/plutil -lint "$privacy_path" >/dev/null
    for architecture in "$@"; do
        thin_archive="$archive"
        if [[ "$#" -gt 1 ]]; then
            thin_archive="$VALIDATION_TEMP_ROOT/$identifier-$architecture.a"
            /usr/bin/lipo "$archive" -thin "$architecture" -output "$thin_archive"
        fi
        assert_platform_metadata "$thin_archive" "$platform" "$minimum"
        metadata="$(/usr/bin/otool -a "$thin_archive" | /usr/bin/awk '
            NR > 1 && ($1 != "0100644" || $2 != "0/0" ||
                       $4 !~ /^[0-9]+$/ || $4 > 65535) { print; exit }
        ')"
        [[ -z "$metadata" ]] || {
            echo "Nondeterministic archive metadata: $identifier/$architecture: $metadata" >&2
            exit 1
        }
        assert_symbols "$thin_archive" "$identifier-$architecture"
        case "$sdk" in
            iphoneos) triple="$architecture-apple-ios$minimum" ;;
            iphonesimulator) triple="$architecture-apple-ios$minimum-simulator" ;;
            macosx) triple="$architecture-apple-macos$minimum" ;;
        esac
        "$(xcrun --sdk "$sdk" --find clang)" \
            -target "$triple" -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
            -fmodules -fmodules-cache-path="$VALIDATION_TEMP_ROOT/module-cache-$identifier-$architecture" \
            -F "$(dirname "$framework")" "$SCRIPT_DIR/support/module-check.m" \
            -framework LibASS -framework CoreFoundation -framework CoreText -lc++ -liconv \
            -o "$VALIDATION_TEMP_ROOT/module-check-$identifier-$architecture"
    done
}

/usr/bin/plutil -lint "$XCFRAMEWORK/Info.plist" >/dev/null
expected_libraries='[
  {"BinaryPath":"LibASS.framework/LibASS","LibraryIdentifier":"ios-arm64","LibraryPath":"LibASS.framework","SupportedArchitectures":["arm64"],"SupportedPlatform":"ios"},
  {"BinaryPath":"LibASS.framework/LibASS","LibraryIdentifier":"ios-arm64_x86_64-simulator","LibraryPath":"LibASS.framework","SupportedArchitectures":["arm64","x86_64"],"SupportedPlatform":"ios","SupportedPlatformVariant":"simulator"},
  {"BinaryPath":"LibASS.framework/LibASS","LibraryIdentifier":"macos-arm64_x86_64","LibraryPath":"LibASS.framework","SupportedArchitectures":["arm64","x86_64"],"SupportedPlatform":"macos"}
]'
actual_libraries="$(/usr/bin/plutil -extract AvailableLibraries json -o - "$XCFRAMEWORK/Info.plist" |
    jq -cS 'sort_by(.LibraryIdentifier)')"
expected_libraries="$(printf '%s' "$expected_libraries" | jq -cS 'sort_by(.LibraryIdentifier)')"
assert_exact_value "XCFramework variants" "$expected_libraries" "$actual_libraries"
assert_exact_value "XCFramework format" "1.0" \
    "$(/usr/bin/plutil -extract XCFrameworkFormatVersion raw -o - "$XCFRAMEWORK/Info.plist")"
for identifier in ios-arm64_x86_64-simulator macos-arm64_x86_64; do
    /usr/bin/diff -qr "$XCFRAMEWORK/ios-arm64/LibASS.framework/Headers" \
        "$XCFRAMEWORK/$identifier/LibASS.framework/Headers" || {
        echo "Headers differ between XCFramework slices: $identifier" >&2
        exit 1
    }
done
assert_framework ios-arm64 iphoneos 2 "$IOS_MINIMUM_VERSION" arm64
assert_framework ios-arm64_x86_64-simulator iphonesimulator 7 "$IOS_MINIMUM_VERSION" arm64 x86_64
assert_framework macos-arm64_x86_64 macosx 1 "$MACOS_MINIMUM_VERSION" arm64 x86_64
echo "Validated LibASS $LIBASS_VERSION: all five architectures, metadata, symbols, module links and privacy manifests"
