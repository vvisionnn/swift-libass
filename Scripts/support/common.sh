#!/bin/bash
# Shared native-build configuration. This file is sourced by the entry points.
# shellcheck disable=SC2034
reject_shell_startup_environment() {
    local variable
    set -f
    for variable in $(compgen -e); do
        case "$variable" in
            BASH_ENV|ENV|BASHOPTS|SHELLOPTS|CDPATH|GLOBIGNORE|POSIXLY_CORRECT|BASH_COMPAT|BASH_FUNC_*)
                echo "Shell startup override is not accepted: $variable" >&2
                return 1
                ;;
        esac
    done
    set +f
    unset BASH_ENV ENV CDPATH GLOBIGNORE POSIXLY_CORRECT BASH_COMPAT
    export -n BASHOPTS SHELLOPTS
}
load_release_configuration() {
    local values
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    command -v jq >/dev/null || { echo "Missing build tool: jq" >&2; return 1; }
    values="$(jq -er '[
      .libass.version, .libass.sha256, .libass.url,
      .freetype.version, .freetype.sha256, .freetype.url,
      .harfbuzz.version, .harfbuzz.sha256, .harfbuzz.url,
      .fribidi.version, .fribidi.sha256, .fribidi.url,
      .build.iOSMinimumVersion, .build.macOSMinimumVersion,
      (.build.sourceDateEpoch | tostring),
      .toolchain.xcodeVersion, .toolchain.xcodeBuild,
      .toolchain.iPhoneOSSDKVersion, .toolchain.iPhoneSimulatorSDKVersion,
      .toolchain.macOSSDKVersion, .toolchain.clangVersion,
      .toolchain.cctoolsVersion, .toolchain.mesonVersion,
      .toolchain.ninjaVersion, .toolchain.pkgConfigVersion,
      .packageVersion, .artifact.name, .artifact.swiftPackageChecksum
    ] | if all(.[]; type == "string" and length > 0 and (test("[\\t\\r\\n]") | not))
        then @tsv else error("Invalid native release configuration") end' \
      "$PROJECT_ROOT/Configuration/release.json")"
    IFS=$'\t' read -r \
        LIBASS_VERSION LIBASS_SHA256 LIBASS_SOURCE_URL \
        FREETYPE_VERSION FREETYPE_SHA256 FREETYPE_SOURCE_URL \
        HARFBUZZ_VERSION HARFBUZZ_SHA256 HARFBUZZ_SOURCE_URL \
        FRIBIDI_VERSION FRIBIDI_SHA256 FRIBIDI_SOURCE_URL \
        IOS_MINIMUM_VERSION MACOS_MINIMUM_VERSION SOURCE_DATE_EPOCH \
        EXPECTED_XCODE_VERSION_VALUE EXPECTED_XCODE_BUILD \
        EXPECTED_IPHONEOS_SDK_VERSION EXPECTED_IPHONESIMULATOR_SDK_VERSION \
        EXPECTED_MACOSX_SDK_VERSION EXPECTED_CLANG_VERSION EXPECTED_CCTOOLS_VERSION \
        EXPECTED_MESON_VERSION EXPECTED_NINJA_VERSION EXPECTED_PKG_CONFIG_VERSION \
        PACKAGE_VERSION ARTIFACT_NAME ARTIFACT_CHECKSUM <<<"$values"
    EXPECTED_XCODE_VERSION="Xcode $EXPECTED_XCODE_VERSION_VALUE"$'\n'"Build version $EXPECTED_XCODE_BUILD"
    SOURCE_ROOT="$PROJECT_ROOT/.cache/sources"
    LIBASS_TARBALL="$SOURCE_ROOT/libass-${LIBASS_VERSION}.tar.xz"
    FREETYPE_TARBALL="$SOURCE_ROOT/freetype-${FREETYPE_VERSION}.tar.xz"
    HARFBUZZ_TARBALL="$SOURCE_ROOT/harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
    FRIBIDI_TARBALL="$SOURCE_ROOT/fribidi-${FRIBIDI_VERSION}.tar.xz"
    BUILD_ROOT="$PROJECT_ROOT/.build/libass"
    OUTPUT_ROOT="$BUILD_ROOT/output"
    STAGING_ROOT="$BUILD_ROOT/staging"
    FRAMEWORK_ROOT="$PROJECT_ROOT/Artifacts"
    XCFRAMEWORK="$FRAMEWORK_ROOT/LibASS.xcframework"
    STAGED_XCFRAMEWORK="$STAGING_ROOT/LibASS.xcframework"
    BUILD_JOBS="${LIBASS_BUILD_JOBS:-8}"
    DETERMINISTIC_AR_ABSOLUTE="$SCRIPT_DIR/support/deterministic-ar.sh"
    LIBASS_PRIVACY_MANIFEST="$SCRIPT_DIR/support/LibASS.PrivacyInfo.xcprivacy"
}
assert_exact_value() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "$label mismatch" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

sanitize_build_environment() {
    unset \
        AR AS CC CPP CXX LD NM OBJC OBJCXX RANLIB STRIP \
        CFLAGS CPPFLAGS CXXFLAGS LDFLAGS ARCHFLAGS \
        CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH \
        PKG_CONFIG PKG_CONFIG_PATH PKG_CONFIG_DIR PKG_CONFIG_SYSROOT_DIR \
        PKG_CONFIG_LIBDIR PKG_CONFIG_SYSTEM_INCLUDE_PATH \
        PKG_CONFIG_SYSTEM_LIBRARY_PATH PKG_CONFIG_ALLOW_SYSTEM_CFLAGS \
        PKG_CONFIG_ALLOW_SYSTEM_LIBS CMAKE_PREFIX_PATH \
        SDKROOT MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET \
        MAKEFLAGS MFLAGS NINJAFLAGS MESON_ARGS \
        DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
        GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES \
        BASH_ENV ENV CDPATH

    export LANG=C
    export LC_ALL=C
    export TZ=UTC
    export SOURCE_DATE_EPOCH
    export ZERO_AR_DATE=1
    export COPYFILE_DISABLE=1
    # libass uses `git describe` when a parent checkout is visible. Its release
    # archive lives under this repository's .build directory, so stop discovery
    # there and force Meson's deterministic upstream-archive fallback string.
    export GIT_CEILING_DIRECTORIES="$BUILD_ROOT"
    umask 022

    if [[ ! "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        echo "LIBASS_BUILD_JOBS must be a positive integer" >&2
        exit 1
    fi
}

require_build_tools() {
    [[ "$(uname -s)" == Darwin ]] || { echo "XCFramework builds require macOS" >&2; exit 1; }
    local clang_version
    local cctools_version

    for tool in jq meson ninja pkg-config python3 swift xcodebuild xcrun; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Missing build tool: $tool" >&2
            exit 1
        fi
    done

    for tool in /usr/bin/awk /usr/bin/find /usr/bin/grep \
        /usr/bin/libtool /usr/bin/lipo /usr/bin/nm /usr/bin/otool \
        /usr/bin/plutil /usr/bin/shasum /usr/bin/sort /usr/bin/tar \
        /usr/bin/true /usr/bin/xcode-select; do
        if [[ ! -x "$tool" ]]; then
            echo "Missing build tool: $tool" >&2
            exit 1
        fi
    done

    assert_exact_value "Xcode version" "$EXPECTED_XCODE_VERSION" "$(xcodebuild -version)"
    assert_exact_value "iPhoneOS SDK version" "$EXPECTED_IPHONEOS_SDK_VERSION" "$(xcrun --sdk iphoneos --show-sdk-version)"
    assert_exact_value "iPhoneSimulator SDK version" "$EXPECTED_IPHONESIMULATOR_SDK_VERSION" "$(xcrun --sdk iphonesimulator --show-sdk-version)"
    assert_exact_value "macOS SDK version" "$EXPECTED_MACOSX_SDK_VERSION" "$(xcrun --sdk macosx --show-sdk-version)"

    clang_version="$(xcrun --find clang)"
    clang_version="$("$clang_version" --version)"
    clang_version="${clang_version%%$'\n'*}"
    assert_exact_value "Apple clang version" "$EXPECTED_CLANG_VERSION" "$clang_version"

    cctools_version="$(/usr/bin/libtool -V 2>&1)"
    cctools_version="${cctools_version%%$'\n'*}"
    assert_exact_value "Apple cctools version" "$EXPECTED_CCTOOLS_VERSION" "$cctools_version"
    assert_exact_value "Meson version" "$EXPECTED_MESON_VERSION" "$(meson --version)"
    assert_exact_value "Ninja version" "$EXPECTED_NINJA_VERSION" "$(ninja --version)"
    assert_exact_value "pkg-config version" "$EXPECTED_PKG_CONFIG_VERSION" "$(pkg-config --version)"
}
