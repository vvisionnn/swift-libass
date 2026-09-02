#!/bin/bash -p
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
./Scripts/validate-artifact.sh
SWIFT_LIBASS_USE_LOCAL_XCFRAMEWORK=1 swift test --manifest-cache none --parallel
SWIFT_LIBASS_USE_LOCAL_XCFRAMEWORK=1 swift build --manifest-cache none -c release

probe_root="$(mktemp -d "${TMPDIR:-/tmp}/swift-libass-probe.XXXXXX")"
cleanup() {
    case "$probe_root" in
        "${TMPDIR:-/tmp}"/swift-libass-probe.*) /bin/rm -rf "$probe_root" ;;
        *) return 1 ;;
    esac
}
trap cleanup EXIT
mkdir -p "$probe_root/Sources/Smoke"
ln -s "$PROJECT_ROOT" "$probe_root/swift-libass"
cat >"$probe_root/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "LibASSStandaloneSmoke",
    platforms: [.macOS(.v12)],
    dependencies: [.package(path: "swift-libass")],
    targets: [.executableTarget(name: "Smoke", dependencies: [
        .product(name: "LibASS", package: "swift-libass"),
    ])]
)
SWIFT
cp Tests/Smoke/main.swift "$probe_root/Sources/Smoke/main.swift"
SWIFT_LIBASS_USE_LOCAL_XCFRAMEWORK=1 swift run --package-path "$probe_root" --manifest-cache none Smoke
echo "Local package rendering and standalone linkage passed"
