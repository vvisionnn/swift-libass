#!/bin/bash -p
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tag=""
expected_checksum=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag) tag="$2"; shift 2 ;;
        --expected-checksum) expected_checksum="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "A release SemVer is required" >&2; exit 2; }
if [[ -n "$expected_checksum" ]]; then
    [[ "$expected_checksum" =~ ^[0-9a-f]{64}$ ]] || exit 2
fi
repository="https://github.com/vvisionnn/swift-libass.git"
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/swift-libass-release.XXXXXX")"
cleanup() {
    case "$probe_root" in
        "${TMPDIR:-/tmp}"/swift-libass-release.*) /bin/rm -rf "$probe_root" ;;
        *) return 1 ;;
    esac
}
trap cleanup EXIT
git clone --quiet --depth 1 --branch "$tag" "$repository" "$probe_root/release"
revision="$(git -C "$probe_root/release" rev-parse HEAD)"
configuration="$probe_root/release/Configuration/release.json"
jq -e --arg tag "$tag" '.packageVersion == $tag' "$configuration" >/dev/null
checksum="$(jq -er '.artifact.swiftPackageChecksum' "$configuration")"
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]]
[[ -z "$expected_checksum" || "$checksum" == "$expected_checksum" ]]
grep -F "url: \"https://github.com/vvisionnn/swift-libass/releases/download/$tag/LibASS.xcframework.zip\"" "$probe_root/release/Package.swift" >/dev/null
grep -F "checksum: \"$checksum\"" "$probe_root/release/Package.swift" >/dev/null

mkdir -p "$probe_root/package/Sources/Smoke" "$probe_root/package/Tests/SmokeTests"
cat >"$probe_root/package/Package.swift" <<SWIFT
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "LibASSReleaseSmoke",
    platforms: [.iOS(.v15), .macOS(.v12)],
    dependencies: [.package(url: "$repository", exact: "$tag")],
    targets: [
        .executableTarget(name: "Smoke", dependencies: [.product(name: "LibASS", package: "swift-libass")]),
        .testTarget(name: "SmokeTests", dependencies: [.product(name: "LibASS", package: "swift-libass")]),
    ]
)
SWIFT
cp "$PROJECT_ROOT/Tests/Smoke/main.swift" "$probe_root/package/Sources/Smoke/main.swift"
sed '/@testable import LibASSLinkerSupport/d; /@Test func bundlesRequiredPrivacyDeclaration/,$d' \
    "$PROJECT_ROOT/Tests/LibASSTests/LibASSTests.swift" >"$probe_root/package/Tests/SmokeTests/SmokeTests.swift"
env -u SWIFT_LIBASS_USE_LOCAL_XCFRAMEWORK -u SWIFTPM_MIRROR_CONFIG \
    swift run --package-path "$probe_root/package" --manifest-cache none Smoke
jq -e --arg tag "$tag" --arg revision "$revision" --arg repository "$repository" '
    [.pins[] | select(.identity == "swift-libass" and .location == $repository and .state.version == $tag and .state.revision == $revision)] | length == 1
' "$probe_root/package/Package.resolved" >/dev/null
env -u SWIFT_LIBASS_USE_LOCAL_XCFRAMEWORK -u SWIFTPM_MIRROR_CONFIG \
    swift test --package-path "$probe_root/package" --manifest-cache none
"$PROJECT_ROOT/Scripts/test-ios-simulator.sh" --remote --package "$probe_root/package" --scheme LibASSReleaseSmoke
echo "Exact remote LibASS $tag ($revision) passed macOS and iOS validation"
