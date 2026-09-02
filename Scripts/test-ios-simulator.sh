#!/bin/bash -p
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_root="$PROJECT_ROOT"
scheme="swift-libass"
local_artifact=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --package) package_root="$2"; shift 2 ;;
        --scheme) scheme="$2"; shift 2 ;;
        --remote) local_artifact=0; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
cd "$package_root"
mkdir -p "$PROJECT_ROOT/.build/simulator-tests"
evidence_root="$(mktemp -d "$PROJECT_ROOT/.build/simulator-tests/run.XXXXXX")"
build_env=(env -u SWIFT_LIBASS_USE_LOCAL_XCFRAMEWORK)
if [[ "$local_artifact" == 1 ]]; then
    "$PROJECT_ROOT/Scripts/validate-artifact.sh"
    build_env+=(SWIFT_LIBASS_USE_LOCAL_XCFRAMEWORK=1)
fi

run_build() {
    local name="$1"
    shift
    if ! "${build_env[@]}" xcodebuild "$@" >"$evidence_root/$name.log" 2>&1; then
        tail -100 "$evidence_root/$name.log" >&2
        return 1
    fi
}
run_build device build-for-testing -quiet -scheme "$scheme" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$evidence_root/DeviceDerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

xcrun simctl list runtimes available -j >"$evidence_root/runtimes.json"
xcrun simctl list devices available -j >"$evidence_root/devices.json"
runtime="$(jq -er '[.runtimes[] | select(.platform == "iOS" and .isAvailable)] | sort_by(.version | split(".") | map(tonumber)) | last.identifier' "$evidence_root/runtimes.json")"
simulator="${SWIFT_LIBASS_SIMULATOR_UDID:-$(jq -er --arg runtime "$runtime" '
    [.devices[$runtime][] | select(.isAvailable and (.deviceTypeIdentifier | contains(".iPhone-")))]
    | sort_by((if .state == "Booted" then 0 else 1 end), .name, .udid)
    | first.udid' "$evidence_root/devices.json")}"
jq -e --arg runtime "$runtime" --arg udid "$simulator" \
    'any(.devices[$runtime][]; .udid == $udid and .isAvailable)' \
    "$evidence_root/devices.json" >/dev/null
xcrun simctl boot "$simulator" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator" -b >/dev/null
run_build simulator build-for-testing -quiet -scheme "$scheme" \
    -destination "platform=iOS Simulator,id=$simulator" \
    -derivedDataPath "$evidence_root/DerivedData"
xctestrun_count="$(find "$evidence_root/DerivedData/Build/Products" -maxdepth 1 -name '*.xctestrun' | wc -l | tr -d ' ' )"
[[ "$xctestrun_count" == 1 ]]
xctestrun="$(find "$evidence_root/DerivedData/Build/Products" -maxdepth 1 -name '*.xctestrun')"
run_build tests test-without-building -quiet -xctestrun "$xctestrun" \
    -destination "platform=iOS Simulator,id=$simulator" \
    -resultBundlePath "$evidence_root/LibASSTests.xcresult"
xcrun xcresulttool get test-results summary --path "$evidence_root/LibASSTests.xcresult" >"$evidence_root/summary.json"
jq -e '.failedTests == 0 and .passedTests > 0 and .skippedTests == 0' "$evidence_root/summary.json" >/dev/null
echo "iOS device build and Simulator rendering tests passed: $evidence_root"
