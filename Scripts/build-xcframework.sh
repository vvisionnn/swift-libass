#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/support/common.sh
source "$SCRIPT_DIR/support/common.sh"
reject_shell_startup_environment
load_release_configuration

verify_tarball() {
    local tarball="$1"
    local expected="$2"
    local label="$3"
    local source_url="$4"
    local actual

    if [[ ! -f "$tarball" ]]; then
        echo "Missing cached $label source archive: $tarball" >&2
        echo "Official source: $source_url" >&2
        exit 1
    fi
    actual="$(/usr/bin/shasum -a 256 "$tarball" | /usr/bin/awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "$label checksum mismatch: expected $expected, got $actual" >&2
        exit 1
    fi
}

verify_license_copy() {
    local tarball="$1"
    local archive_member="$2"
    local checked_in="$3"
    local label="$4"
    local upstream_hash
    local checked_in_hash

    if [[ ! -f "$checked_in" ]]; then
        echo "Missing checked-in $label license: $checked_in" >&2
        exit 1
    fi
    upstream_hash="$(
        /usr/bin/tar -xJOf "$tarball" "$archive_member" |
            /usr/bin/shasum -a 256 |
            /usr/bin/awk '{print $1}'
    )"
    checked_in_hash="$(
        /usr/bin/shasum -a 256 "$checked_in" | /usr/bin/awk '{print $1}'
    )"
    if [[ "$upstream_hash" != "$checked_in_hash" ]]; then
        echo "$label license does not match the verified upstream archive" >&2
        exit 1
    fi
}

prepare_sources_and_licenses() {
    verify_tarball "$LIBASS_TARBALL" "$LIBASS_SHA256" libass "$LIBASS_SOURCE_URL"
    verify_tarball "$FREETYPE_TARBALL" "$FREETYPE_SHA256" FreeType "$FREETYPE_SOURCE_URL"
    verify_tarball "$HARFBUZZ_TARBALL" "$HARFBUZZ_SHA256" HarfBuzz "$HARFBUZZ_SOURCE_URL"
    verify_tarball "$FRIBIDI_TARBALL" "$FRIBIDI_SHA256" FriBidi "$FRIBIDI_SOURCE_URL"

    verify_license_copy \
        "$LIBASS_TARBALL" "libass-${LIBASS_VERSION}/COPYING" \
        "$PROJECT_ROOT/Licenses/libass-ISC.txt" libass
    verify_license_copy \
        "$FREETYPE_TARBALL" "freetype-${FREETYPE_VERSION}/docs/FTL.TXT" \
        "$PROJECT_ROOT/Licenses/FreeType-FTL.txt" FreeType
    verify_license_copy \
        "$HARFBUZZ_TARBALL" "harfbuzz-${HARFBUZZ_VERSION}/COPYING" \
        "$PROJECT_ROOT/Licenses/HarfBuzz-Old-MIT.txt" HarfBuzz
    verify_license_copy \
        "$HARFBUZZ_TARBALL" "harfbuzz-${HARFBUZZ_VERSION}/src/ms-use/COPYING" \
        "$PROJECT_ROOT/Licenses/HarfBuzz-Microsoft-MIT.txt" \
        "HarfBuzz Universal Shaping Engine data"
    verify_license_copy \
        "$FRIBIDI_TARBALL" "fribidi-${FRIBIDI_VERSION}/COPYING" \
        "$PROJECT_ROOT/Licenses/FriBidi-LGPL-2.1.txt" FriBidi
}

write_cross_file() {
    local name="$1"
    local sdk="$2"
    local triple="$3"
    local cpu_family="$4"
    local cpu="$5"
    local cross_file="$BUILD_ROOT/$name.cross"
    local sdk_path
    local compiler
    local cpp_compiler
    local stripper
    local pkg_config

    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
    compiler="$(xcrun --sdk "$sdk" --find clang)"
    cpp_compiler="$(xcrun --sdk "$sdk" --find clang++)"
    stripper="$(xcrun --sdk "$sdk" --find strip)"
    pkg_config="$(command -v pkg-config)"

    mkdir -p "$BUILD_ROOT"
    {
        echo "[binaries]"
        echo "c = '$compiler'"
        echo "cpp = '$cpp_compiler'"
        echo "ar = '$DETERMINISTIC_AR_ABSOLUTE'"
        echo "ranlib = '/usr/bin/true'"
        echo "strip = '$stripper'"
        echo "pkg-config = '$pkg_config'"
        echo ""
        echo "[host_machine]"
        echo "system = 'darwin'"
        echo "cpu_family = '$cpu_family'"
        echo "cpu = '$cpu'"
        echo "endian = 'little'"
        echo ""
        echo "[properties]"
        echo "needs_exe_wrapper = true"
        echo ""
        echo "[built-in options]"
        echo "c_args = ['-target', '$triple', '-isysroot', '$sdk_path']"
        echo "cpp_args = ['-target', '$triple', '-isysroot', '$sdk_path']"
        echo "c_link_args = ['-target', '$triple', '-isysroot', '$sdk_path']"
        echo "cpp_link_args = ['-target', '$triple', '-isysroot', '$sdk_path']"
    } >"$cross_file"
}

build_freetype_slice() {
    local name="$1"
    local source_root="$BUILD_ROOT/source-freetype-$name"
    local component_build_root="$BUILD_ROOT/build-freetype-$name"
    local install_root="$BUILD_ROOT/install/$name"
    local log_root="$BUILD_ROOT/logs"

    rm -rf "$source_root" "$component_build_root" "$install_root/freetype"
    mkdir -p "$source_root" "$install_root" "$log_root"
    /usr/bin/tar -xJf "$FREETYPE_TARBALL" -C "$source_root" --strip-components=1

    echo "Building FreeType for $name"
    meson setup "$component_build_root" "$source_root" \
        --cross-file "$BUILD_ROOT/$name.cross" \
        --wrap-mode=nodownload \
        --prefix=/freetype \
        --libdir=lib \
        --buildtype=release \
        --default-library=static \
        -Db_staticpic=true \
        -Db_lto=false \
        -Db_ndebug=true \
        -Dbrotli=disabled \
        -Dbzip2=disabled \
        -Dharfbuzz=disabled \
        -Dmmap=enabled \
        -Dpng=disabled \
        -Dtests=disabled \
        -Dzlib=disabled \
        >"$log_root/freetype-meson-$name.log" 2>&1
    meson compile -C "$component_build_root" --jobs "$BUILD_JOBS" \
        >"$log_root/freetype-build-$name.log" 2>&1
    DESTDIR="$install_root" meson install -C "$component_build_root" \
        >"$log_root/freetype-install-$name.log" 2>&1
}

build_harfbuzz_slice() {
    local name="$1"
    local source_root="$BUILD_ROOT/source-harfbuzz-$name"
    local component_build_root="$BUILD_ROOT/build-harfbuzz-$name"
    local install_root="$BUILD_ROOT/install/$name"
    local log_root="$BUILD_ROOT/logs"

    rm -rf "$source_root" "$component_build_root" "$install_root/harfbuzz"
    mkdir -p "$source_root" "$install_root" "$log_root"
    /usr/bin/tar -xJf "$HARFBUZZ_TARBALL" -C "$source_root" --strip-components=1

    echo "Building HarfBuzz for $name"
    meson setup "$component_build_root" "$source_root" \
        --cross-file "$BUILD_ROOT/$name.cross" \
        --wrap-mode=nodownload \
        --prefix=/harfbuzz \
        --libdir=lib \
        --buildtype=release \
        --default-library=static \
        -Db_staticpic=true \
        -Db_lto=false \
        -Db_ndebug=true \
        -Dbenchmark=disabled \
        -Dcairo=disabled \
        -Dchafa=disabled \
        -Dcoretext=disabled \
        -Ddirectwrite=disabled \
        -Ddocs=disabled \
        -Dfreetype=disabled \
        -Dfontations=disabled \
        -Dgdi=disabled \
        -Dglib=disabled \
        -Dgobject=disabled \
        -Dgpu=disabled \
        -Dgpu_demo=disabled \
        -Dgraphite2=disabled \
        -Dharfrust=disabled \
        -Dicu=disabled \
        -Dintrospection=disabled \
        -Dkbts=disabled \
        -Dpng=disabled \
        -Draster=disabled \
        -Dsubset=disabled \
        -Dtests=disabled \
        -Dutilities=disabled \
        -Dvector=disabled \
        -Dwasm=disabled \
        -Dzlib=disabled \
        >"$log_root/harfbuzz-meson-$name.log" 2>&1
    meson compile -C "$component_build_root" --jobs "$BUILD_JOBS" \
        >"$log_root/harfbuzz-build-$name.log" 2>&1
    DESTDIR="$install_root" meson install -C "$component_build_root" \
        >"$log_root/harfbuzz-install-$name.log" 2>&1
}

build_fribidi_slice() {
    local name="$1"
    local source_root="$BUILD_ROOT/source-fribidi-$name"
    local component_build_root="$BUILD_ROOT/build-fribidi-$name"
    local install_root="$BUILD_ROOT/install/$name"
    local log_root="$BUILD_ROOT/logs"

    rm -rf "$source_root" "$component_build_root" "$install_root/fribidi"
    mkdir -p "$source_root" "$install_root" "$log_root"
    /usr/bin/tar -xJf "$FRIBIDI_TARBALL" -C "$source_root" --strip-components=1

    echo "Building FriBidi for $name"
    meson setup "$component_build_root" "$source_root" \
        --cross-file "$BUILD_ROOT/$name.cross" \
        --wrap-mode=nodownload \
        --prefix=/fribidi \
        --libdir=lib \
        --buildtype=release \
        --default-library=static \
        -Db_staticpic=true \
        -Db_lto=false \
        -Db_ndebug=true \
        -Dbin=false \
        -Ddocs=false \
        -Dtests=false \
        >"$log_root/fribidi-meson-$name.log" 2>&1
    meson compile -C "$component_build_root" --jobs "$BUILD_JOBS" \
        >"$log_root/fribidi-build-$name.log" 2>&1
    DESTDIR="$install_root" meson install -C "$component_build_root" \
        >"$log_root/fribidi-install-$name.log" 2>&1
}

build_libass_slice() {
    local name="$1"
    local source_root="$BUILD_ROOT/source-libass-$name"
    local component_build_root="$BUILD_ROOT/build-libass-$name"
    local install_root="$BUILD_ROOT/install/$name"
    local log_root="$BUILD_ROOT/logs"
    local pkg_config_libdir

    rm -rf "$source_root" "$component_build_root" "$install_root/libass"
    mkdir -p "$source_root" "$install_root" "$log_root"
    /usr/bin/tar -xJf "$LIBASS_TARBALL" -C "$source_root" --strip-components=1
    pkg_config_libdir="$install_root/freetype/lib/pkgconfig:$install_root/harfbuzz/lib/pkgconfig:$install_root/fribidi/lib/pkgconfig"

    echo "Building libass for $name"
    PKG_CONFIG_LIBDIR="$pkg_config_libdir" \
    PKG_CONFIG_SYSROOT_DIR="$install_root" \
    meson setup "$component_build_root" "$source_root" \
        --cross-file "$BUILD_ROOT/$name.cross" \
        --wrap-mode=nodownload \
        --prefix=/libass \
        --libdir=lib \
        --buildtype=release \
        --default-library=static \
        -Db_staticpic=true \
        -Db_lto=false \
        -Db_ndebug=true \
        -Dart-samples= \
        -Dasm=disabled \
        -Dcheckasm=disabled \
        -Dcompare=disabled \
        -Dcoretext=enabled \
        -Ddirectwrite=disabled \
        -Dfontconfig=disabled \
        -Dfuzz=disabled \
        -Dlarge-tiles=false \
        -Dlibunibreak=disabled \
        -Dprofile=disabled \
        -Drequire-system-font-provider=true \
        -Dtest=disabled \
        >"$log_root/libass-meson-$name.log" 2>&1
    # Meson's vcs_tag custom target generates config.h during compilation.
    meson compile -C "$component_build_root" --jobs "$BUILD_JOBS" \
        >"$log_root/libass-build-$name.log" 2>&1
    if ! /usr/bin/grep -Fqx '#define CONFIG_CORETEXT 1' \
        "$component_build_root/config.h"; then
        echo "libass CoreText support was not enabled for $name" >&2
        exit 1
    fi
    if ! /usr/bin/grep -Fqx '#define CONFIG_ICONV 1' \
        "$component_build_root/config.h"; then
        echo "libass iconv support was not enabled for $name" >&2
        exit 1
    fi
    if /usr/bin/grep -Eq '^#define CONFIG_(FONTCONFIG|UNIBREAK) ' \
        "$component_build_root/config.h"; then
        echo "libass unexpectedly enabled an excluded dependency for $name" >&2
        exit 1
    fi
    if ! /usr/bin/grep -Fqx \
        "#define CONFIG_SOURCEVERSION \"meson, commit: failed to determine (>= $LIBASS_VERSION)\"" \
        "$component_build_root/config.h"; then
        echo "libass source version captured nonreproducible checkout state for $name" >&2
        exit 1
    fi
    DESTDIR="$install_root" meson install -C "$component_build_root" \
        >"$log_root/libass-install-$name.log" 2>&1
}

build_slice() {
    local name="$1"
    local sdk="$2"
    local triple="$3"
    local cpu_family="$4"
    local cpu="$5"

    write_cross_file "$name" "$sdk" "$triple" "$cpu_family" "$cpu"
    build_freetype_slice "$name"
    build_harfbuzz_slice "$name"
    build_fribidi_slice "$name"
    build_libass_slice "$name"
}

prepare_headers() {
    local name="$1"
    local include_root="$BUILD_ROOT/install/$name/libass/include"

    rm -f "$include_root/module.modulemap"
    cp "$SCRIPT_DIR/support/LibASS.h" "$include_root/LibASS.h"
}

merge_slice() {
    local name="$1"
    local install_root="$BUILD_ROOT/install/$name"
    local destination="$OUTPUT_ROOT/$name"
    local log_root="$BUILD_ROOT/logs"
    local archive

    for archive in \
        "$install_root/libass/lib/libass.a" \
        "$install_root/freetype/lib/libfreetype.a" \
        "$install_root/harfbuzz/lib/libharfbuzz.a" \
        "$install_root/fribidi/lib/libfribidi.a"
    do
        if [[ ! -f "$archive" ]]; then
            echo "Missing component archive for $name: $archive" >&2
            exit 1
        fi
    done

    mkdir -p "$destination" "$log_root"
    /usr/bin/libtool -static -D -o "$destination/libLibASS.a" \
        "$install_root/libass/lib/libass.a" \
        "$install_root/freetype/lib/libfreetype.a" \
        "$install_root/harfbuzz/lib/libharfbuzz.a" \
        "$install_root/fribidi/lib/libfribidi.a" \
        >"$log_root/libtool-$name.log" 2>&1
}

assert_archive_deterministic_metadata() {
    local archive="$1"
    local invalid_member

    invalid_member="$(/usr/bin/otool -a "$archive" | /usr/bin/awk '
        NR > 1 && ($1 != "0100644" || $2 != "0/0" ||
                   $4 !~ /^[0-9]+$/ || $4 > 65535) { print; exit }
    ')"
    if [[ -n "$invalid_member" ]]; then
        echo "Archive contains nondeterministic member metadata: $archive" >&2
        echo "$invalid_member" >&2
        exit 1
    fi
}

assert_thin_slice() {
    local name="$1"
    local architecture="$2"
    local expected_platform="$3"
    local expected_minos="$4"
    local archive="$OUTPUT_ROOT/$name/libLibASS.a"
    local metadata_log="$BUILD_ROOT/logs/otool-$name.log"
    local metadata_counts
    local actual_architectures

    actual_architectures="$(/usr/bin/lipo -archs "$archive")"
    if [[ "$actual_architectures" != "$architecture" ]]; then
        echo "$name architecture mismatch: expected $architecture, got $actual_architectures" >&2
        exit 1
    fi

    /usr/bin/otool -l "$archive" >"$metadata_log"
    metadata_counts="$(/usr/bin/awk \
        -v expected_platform="$expected_platform" \
        -v expected_minos="$expected_minos" '
        /^[^[:space:]].*\):$/ { members++ }
        /cmd LC_BUILD_VERSION/ {
            versions++
            getline
            getline
            platform = $2
            getline
            minos = $2
            getline
            if (platform == expected_platform && minos == expected_minos)
                matching++
        }
        END { print members + 0, versions + 0, matching + 0 }
    ' "$metadata_log")"
    # The producer emits exactly three space-delimited integer counts.
    # shellcheck disable=SC2086
    set -- $metadata_counts
    if [[ "$1" -eq 0 || "$1" -ne "$2" || "$1" -ne "$3" ]]; then
        echo "$name has incomplete or incorrect LC_BUILD_VERSION metadata" >&2
        echo "Mach-O members=$1 build_versions=$2 matching=$3" >&2
        exit 1
    fi

    assert_archive_deterministic_metadata "$archive"
}

assert_archive_symbols() {
    local label="$1"
    local archive="$2"
    local architecture="$3"
    local nm_log="$BUILD_ROOT/logs/nm-$label-$architecture.log"
    local symbol

    /usr/bin/nm -arch "$architecture" "$archive" >"$nm_log"
    for symbol in \
        ass_add_font \
        ass_library_init \
        ass_process_chunk \
        ass_process_codec_private \
        ass_render_frame \
        ass_renderer_init \
        FT_Init_FreeType \
        fribidi_log2vis \
        hb_shape
    do
        if ! /usr/bin/grep -Eq "[[:space:]][Tt][[:space:]]_$symbol$" "$nm_log"; then
            echo "$label/$architecture is missing required symbol _$symbol" >&2
            exit 1
        fi
    done

    for symbol in FcInit set_linebreaks_utf8 g_malloc u_init; do
        if /usr/bin/grep -Eq "[[:space:]]_$symbol$" "$nm_log"; then
            echo "$label/$architecture unexpectedly references _$symbol" >&2
            exit 1
        fi
    done
}

assert_matching_headers() {
    local first="$BUILD_ROOT/install/ios-arm64/libass/include"
    local candidate
    local first_hashes
    local candidate_hashes

    first_hashes="$(
        cd "$first"
        /usr/bin/find . -type f -print | LC_ALL=C /usr/bin/sort | while IFS= read -r header; do
            /usr/bin/shasum -a 256 "$header"
        done
    )"

    for candidate in \
        "$BUILD_ROOT/install/ios-simulator-arm64/libass/include" \
        "$BUILD_ROOT/install/ios-simulator-x86_64/libass/include" \
        "$BUILD_ROOT/install/macos-arm64/libass/include" \
        "$BUILD_ROOT/install/macos-x86_64/libass/include"
    do
        candidate_hashes="$(
            cd "$candidate"
            /usr/bin/find . -type f -print | LC_ALL=C /usr/bin/sort | while IFS= read -r header; do
                /usr/bin/shasum -a 256 "$header"
            done
        )"
        if [[ "$candidate_hashes" != "$first_hashes" ]]; then
            echo "Installed libass headers differ between slices: $first and $candidate" >&2
            exit 1
        fi
    done
}

write_toolchain_manifest() {
    mkdir -p "$BUILD_ROOT/logs"
    {
        echo "DEVELOPER_DIR=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
        xcodebuild -version
        echo "iphoneos SDK $(xcrun --sdk iphoneos --show-sdk-version)"
        echo "iphonesimulator SDK $(xcrun --sdk iphonesimulator --show-sdk-version)"
        echo "macosx SDK $(xcrun --sdk macosx --show-sdk-version)"
        xcrun clang --version | /usr/bin/awk 'NR == 1'
        /usr/bin/libtool -V 2>&1
        echo "Meson $(meson --version)"
        echo "Ninja $(ninja --version)"
        echo "pkg-config $(pkg-config --version)"
        echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
        echo "libass $LIBASS_VERSION $LIBASS_SHA256"
        echo "FreeType $FREETYPE_VERSION $FREETYPE_SHA256"
        echo "HarfBuzz $HARFBUZZ_VERSION $HARFBUZZ_SHA256"
        echo "FriBidi $FRIBIDI_VERSION $FRIBIDI_SHA256"
        echo "libunibreak disabled (optional dependency)"
        echo "CoreText enabled; fontconfig and DirectWrite disabled"
    } >"$BUILD_ROOT/logs/toolchain.txt"
}

canonicalize_xcframework_info() {
    local info_plist="$1"

    /usr/bin/plutil -replace AvailableLibraries -json '[
      {
        "BinaryPath": "LibASS.framework/LibASS",
        "LibraryIdentifier": "ios-arm64",
        "LibraryPath": "LibASS.framework",
        "SupportedArchitectures": ["arm64"],
        "SupportedPlatform": "ios"
      },
      {
        "BinaryPath": "LibASS.framework/LibASS",
        "LibraryIdentifier": "ios-arm64_x86_64-simulator",
        "LibraryPath": "LibASS.framework",
        "SupportedArchitectures": ["arm64", "x86_64"],
        "SupportedPlatform": "ios",
        "SupportedPlatformVariant": "simulator"
      },
      {
        "BinaryPath": "LibASS.framework/LibASS",
        "LibraryIdentifier": "macos-arm64_x86_64",
        "LibraryPath": "LibASS.framework",
        "SupportedArchitectures": ["arm64", "x86_64"],
        "SupportedPlatform": "macos"
      }
    ]' "$info_plist"
}

verify_privacy_manifests() {
    local xcframework="$1"
    local relative_path

    [[ -d "$xcframework" && ! -L "$xcframework" ]] || {
        echo "LibASS XCFramework is missing or unsafe: $xcframework" >&2
        return 1
    }
    [[ -f "$LIBASS_PRIVACY_MANIFEST" && ! -L "$LIBASS_PRIVACY_MANIFEST" ]] || {
        echo "Canonical LibASS privacy manifest is missing or unsafe" >&2
        return 1
    }
    /usr/bin/plutil -lint "$LIBASS_PRIVACY_MANIFEST" >/dev/null
    for relative_path in \
        ios-arm64/LibASS.framework/PrivacyInfo.xcprivacy \
        ios-arm64_x86_64-simulator/LibASS.framework/PrivacyInfo.xcprivacy \
        macos-arm64_x86_64/LibASS.framework/Resources/PrivacyInfo.xcprivacy; do
        [[ -f "$xcframework/$relative_path" &&
           ! -L "$xcframework/$relative_path" ]] || {
            echo "LibASS privacy manifest is missing or unsafe: $relative_path" >&2
            return 1
        }
        /usr/bin/cmp -s \
            "$LIBASS_PRIVACY_MANIFEST" "$xcframework/$relative_path" || {
            echo "LibASS privacy manifest differs from canonical bytes: $relative_path" >&2
            return 1
        }
        /usr/bin/plutil -lint "$xcframework/$relative_path" >/dev/null
    done
}

install_privacy_manifests() {
    local xcframework="$1"
    local framework_path
    local relative_path

    [[ -d "$xcframework" && ! -L "$xcframework" ]] || {
        echo "LibASS XCFramework is missing or unsafe: $xcframework" >&2
        return 1
    }
    [[ -f "$LIBASS_PRIVACY_MANIFEST" && ! -L "$LIBASS_PRIVACY_MANIFEST" ]] || {
        echo "Canonical LibASS privacy manifest is missing or unsafe" >&2
        return 1
    }
    /usr/bin/plutil -lint "$LIBASS_PRIVACY_MANIFEST" >/dev/null
    for framework_path in \
        ios-arm64/LibASS.framework \
        ios-arm64_x86_64-simulator/LibASS.framework \
        macos-arm64_x86_64/LibASS.framework; do
        [[ -d "$xcframework/$framework_path" &&
           ! -L "$xcframework/$framework_path" ]] || {
            echo "LibASS framework slice is missing or unsafe: $framework_path" >&2
            return 1
        }
    done
    [[ ! -L "$xcframework/macos-arm64_x86_64/LibASS.framework/Resources" ]] || {
        echo "LibASS macOS Resources directory may not be a symbolic link" >&2
        return 1
    }
    /bin/mkdir -p \
        "$xcframework/macos-arm64_x86_64/LibASS.framework/Resources"
    for relative_path in \
        ios-arm64/LibASS.framework/PrivacyInfo.xcprivacy \
        ios-arm64_x86_64-simulator/LibASS.framework/PrivacyInfo.xcprivacy \
        macos-arm64_x86_64/LibASS.framework/Resources/PrivacyInfo.xcprivacy; do
        [[ ! -L "$xcframework/$relative_path" ]] || {
            echo "LibASS privacy manifest destination may not be a symbolic link: $relative_path" >&2
            return 1
        }
        /bin/cp -f "$LIBASS_PRIVACY_MANIFEST" "$xcframework/$relative_path"
    done
    verify_privacy_manifests "$xcframework"
}

create_static_framework() {
    local archive="$1"
    local headers="$2"
    local destination="$3"

    rm -rf "$destination"
    mkdir -p "$destination/Headers" "$destination/Modules"
    cp "$archive" "$destination/LibASS"
    cp -R "$headers/." "$destination/Headers/"
    cp "$SCRIPT_DIR/support/LibASS.modulemap" \
        "$destination/Modules/module.modulemap"

    /usr/bin/plutil -create xml1 "$destination/Info.plist"
    /usr/bin/plutil -insert CFBundleDevelopmentRegion -string en \
        "$destination/Info.plist"
    /usr/bin/plutil -insert CFBundleExecutable -string LibASS \
        "$destination/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier \
        -string org.swift-libass.LibASS "$destination/Info.plist"
    /usr/bin/plutil -insert CFBundleInfoDictionaryVersion -string 6.0 \
        "$destination/Info.plist"
    /usr/bin/plutil -insert CFBundleName -string LibASS \
        "$destination/Info.plist"
    /usr/bin/plutil -insert CFBundlePackageType -string FMWK \
        "$destination/Info.plist"
    /usr/bin/plutil -insert CFBundleShortVersionString -string "$LIBASS_VERSION" \
        "$destination/Info.plist"
    /usr/bin/plutil -insert CFBundleVersion -string 1 \
        "$destination/Info.plist"
}

validate_module_framework() {
    local name="$1"
    local sdk="$2"
    local triple="$3"
    local framework="$4"
    local compiler
    local sdk_path
    local source="$BUILD_ROOT/module-check-$name.m"
    local module_cache="$BUILD_ROOT/module-cache-$name"

    compiler="$(xcrun --sdk "$sdk" --find clang)"
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
    rm -rf "$module_cache"
    /usr/bin/printf '%s\n' \
        '@import LibASS;' \
        'int libass_module_check(void) { return (int)ass_library_version(); }' \
        >"$source"
    "$compiler" \
        -target "$triple" \
        -isysroot "$sdk_path" \
        -fmodules \
        -fmodules-cache-path="$module_cache" \
        -F "$(dirname "$framework")" \
        -fsyntax-only \
        "$source"
}

package_xcframework() {
    rm -rf "$OUTPUT_ROOT" "$STAGING_ROOT"
    mkdir -p "$OUTPUT_ROOT" "$STAGING_ROOT" "$FRAMEWORK_ROOT"

    prepare_headers ios-arm64
    merge_slice ios-arm64
    assert_thin_slice ios-arm64 arm64 2 "$IOS_MINIMUM_VERSION"

    prepare_headers ios-simulator-arm64
    merge_slice ios-simulator-arm64
    assert_thin_slice ios-simulator-arm64 arm64 7 "$IOS_MINIMUM_VERSION"

    prepare_headers ios-simulator-x86_64
    merge_slice ios-simulator-x86_64
    assert_thin_slice ios-simulator-x86_64 x86_64 7 "$IOS_MINIMUM_VERSION"

    prepare_headers macos-arm64
    merge_slice macos-arm64
    assert_thin_slice macos-arm64 arm64 1 "$MACOS_MINIMUM_VERSION"

    prepare_headers macos-x86_64
    merge_slice macos-x86_64
    assert_thin_slice macos-x86_64 x86_64 1 "$MACOS_MINIMUM_VERSION"

    assert_matching_headers

    mkdir -p "$OUTPUT_ROOT/ios-simulator-universal" "$OUTPUT_ROOT/macos-universal"
    /usr/bin/lipo -create \
        "$OUTPUT_ROOT/ios-simulator-arm64/libLibASS.a" \
        "$OUTPUT_ROOT/ios-simulator-x86_64/libLibASS.a" \
        -output "$OUTPUT_ROOT/ios-simulator-universal/libLibASS.a"
    /usr/bin/lipo -create \
        "$OUTPUT_ROOT/macos-arm64/libLibASS.a" \
        "$OUTPUT_ROOT/macos-x86_64/libLibASS.a" \
        -output "$OUTPUT_ROOT/macos-universal/libLibASS.a"

    assert_archive_symbols ios-device "$OUTPUT_ROOT/ios-arm64/libLibASS.a" arm64
    assert_archive_symbols ios-simulator-arm64 "$OUTPUT_ROOT/ios-simulator-arm64/libLibASS.a" arm64
    assert_archive_symbols ios-simulator-x86_64 "$OUTPUT_ROOT/ios-simulator-x86_64/libLibASS.a" x86_64
    assert_archive_symbols macos-arm64 "$OUTPUT_ROOT/macos-arm64/libLibASS.a" arm64
    assert_archive_symbols macos-x86_64 "$OUTPUT_ROOT/macos-x86_64/libLibASS.a" x86_64

    create_static_framework \
        "$OUTPUT_ROOT/ios-arm64/libLibASS.a" \
        "$BUILD_ROOT/install/ios-arm64/libass/include" \
        "$OUTPUT_ROOT/ios-arm64/LibASS.framework"
    create_static_framework \
        "$OUTPUT_ROOT/ios-simulator-universal/libLibASS.a" \
        "$BUILD_ROOT/install/ios-simulator-arm64/libass/include" \
        "$OUTPUT_ROOT/ios-simulator-universal/LibASS.framework"
    create_static_framework \
        "$OUTPUT_ROOT/macos-universal/libLibASS.a" \
        "$BUILD_ROOT/install/macos-arm64/libass/include" \
        "$OUTPUT_ROOT/macos-universal/LibASS.framework"

    xcodebuild -create-xcframework \
        -framework "$OUTPUT_ROOT/ios-arm64/LibASS.framework" \
        -framework "$OUTPUT_ROOT/ios-simulator-universal/LibASS.framework" \
        -framework "$OUTPUT_ROOT/macos-universal/LibASS.framework" \
        -output "$STAGED_XCFRAMEWORK"

    canonicalize_xcframework_info "$STAGED_XCFRAMEWORK/Info.plist"
    /usr/bin/plutil -lint "$STAGED_XCFRAMEWORK/Info.plist" >/dev/null
    install_privacy_manifests "$STAGED_XCFRAMEWORK"
    assert_exact_value "iOS device XCFramework architectures" "arm64" \
        "$(/usr/bin/lipo -archs "$STAGED_XCFRAMEWORK/ios-arm64/LibASS.framework/LibASS")"
    assert_exact_value "iOS Simulator XCFramework architectures" "x86_64 arm64" \
        "$(/usr/bin/lipo -archs "$STAGED_XCFRAMEWORK/ios-arm64_x86_64-simulator/LibASS.framework/LibASS")"
    assert_exact_value "macOS XCFramework architectures" "x86_64 arm64" \
        "$(/usr/bin/lipo -archs "$STAGED_XCFRAMEWORK/macos-arm64_x86_64/LibASS.framework/LibASS")"

    validate_module_framework \
        ios-device iphoneos "arm64-apple-ios${IOS_MINIMUM_VERSION}" \
        "$STAGED_XCFRAMEWORK/ios-arm64/LibASS.framework"
    validate_module_framework \
        ios-simulator iphonesimulator "x86_64-apple-ios${IOS_MINIMUM_VERSION}-simulator" \
        "$STAGED_XCFRAMEWORK/ios-arm64_x86_64-simulator/LibASS.framework"
    validate_module_framework \
        ios-simulator-arm64 iphonesimulator "arm64-apple-ios${IOS_MINIMUM_VERSION}-simulator" \
        "$STAGED_XCFRAMEWORK/ios-arm64_x86_64-simulator/LibASS.framework"
    validate_module_framework \
        macos-x86_64 macosx "x86_64-apple-macos${MACOS_MINIMUM_VERSION}" \
        "$STAGED_XCFRAMEWORK/macos-arm64_x86_64/LibASS.framework"
    validate_module_framework \
        macos macosx "arm64-apple-macos${MACOS_MINIMUM_VERSION}" \
        "$STAGED_XCFRAMEWORK/macos-arm64_x86_64/LibASS.framework"

    rm -rf "$XCFRAMEWORK"
    mv "$STAGED_XCFRAMEWORK" "$XCFRAMEWORK"
    verify_privacy_manifests "$XCFRAMEWORK"
    "$SCRIPT_DIR/validate-artifact.sh"
}

if [[ "${1:-}" == "--install-privacy-manifests" ]]; then
    [[ "$#" -eq 2 ]] || {
        echo "usage: build-xcframework.sh --install-privacy-manifests XCFRAMEWORK" >&2
        exit 2
    }
    install_privacy_manifests "$2"
    exit 0
elif [[ "${1:-}" == "--verify-privacy-manifests" ]]; then
    [[ "$#" -eq 2 ]] || {
        echo "usage: build-xcframework.sh --verify-privacy-manifests XCFRAMEWORK" >&2
        exit 2
    }
    verify_privacy_manifests "$2"
    exit 0

fi

sanitize_build_environment
require_build_tools
if [[ "${1:-}" == "--check-environment" && "$#" -eq 1 ]]; then
    echo "Toolchain validated: Xcode $EXPECTED_XCODE_VERSION_VALUE ($EXPECTED_XCODE_BUILD)"
    exit 0
fi
prepare_sources_and_licenses
write_toolchain_manifest

if [[ "${1:-}" == "--package-only" ]]; then
    package_xcframework
    echo "Created $XCFRAMEWORK"
    exit 0
fi

if [[ -n "${1:-}" ]]; then
    echo "Unknown argument: $1" >&2
    exit 1
fi

build_slice ios-arm64 iphoneos "arm64-apple-ios${IOS_MINIMUM_VERSION}" aarch64 arm64
build_slice ios-simulator-arm64 iphonesimulator "arm64-apple-ios${IOS_MINIMUM_VERSION}-simulator" aarch64 arm64
build_slice ios-simulator-x86_64 iphonesimulator "x86_64-apple-ios${IOS_MINIMUM_VERSION}-simulator" x86_64 x86_64
build_slice macos-arm64 macosx "arm64-apple-macos${MACOS_MINIMUM_VERSION}" aarch64 arm64
build_slice macos-x86_64 macosx "x86_64-apple-macos${MACOS_MINIMUM_VERSION}" x86_64 x86_64
package_xcframework

echo "Created $XCFRAMEWORK"
