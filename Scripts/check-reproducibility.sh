#!/bin/bash -p

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/support/common.sh
source "$SCRIPT_DIR/support/common.sh"
reject_shell_startup_environment
load_release_configuration

mode="${1:---full}"
[[ "$#" -le 1 ]] || { echo "usage: $0 [--full|--package-only]" >&2; exit 2; }
case "$mode" in
    --full|--package-only) ;;
    *) echo "usage: $0 [--full|--package-only]" >&2; exit 2 ;;
esac

mkdir -p "$PROJECT_ROOT/.artifacts/reproducibility"
evidence_root="$(mktemp -d "$PROJECT_ROOT/.artifacts/reproducibility/run.XXXXXX")"
first_started="$(date +%s)"
selected_developer_dir="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"

copy_checkout() {
    local destination="$1"
    mkdir -p "$destination"
    /usr/bin/rsync -a \
        --exclude='.git' --exclude='.build' --exclude='.cache' \
        --exclude='.artifacts' --exclude='Artifacts' --exclude='__pycache__' \
        "$PROJECT_ROOT/" "$destination/"
    mkdir -p "$destination/.cache/sources"
    /bin/cp -p "$LIBASS_TARBALL" "$FREETYPE_TARBALL" \
        "$HARFBUZZ_TARBALL" "$FRIBIDI_TARBALL" "$destination/.cache/sources/"
}

for attempt in 1 2; do
    attempt_root="$evidence_root/attempt-$attempt"
    checkout_root="$attempt_root/short-checkout"
    [[ "$attempt" != 2 ]] || checkout_root="$attempt_root/a-deliberately-longer-independent-checkout"
    developer_alias="$attempt_root/XcodeDeveloper-$attempt"
    copy_checkout "$checkout_root"
    /bin/ln -s "$selected_developer_dir" "$developer_alias"
    if [[ "$mode" == "--package-only" ]]; then
        mkdir -p "$checkout_root/Artifacts"
        /bin/cp -R "$XCFRAMEWORK" "$checkout_root/Artifacts/"
    fi
    (
        cd "$checkout_root"
        export DEVELOPER_DIR="$developer_alias"
        if [[ "$mode" == "--full" ]]; then
            ./Scripts/build-xcframework.sh
        fi
        ./Scripts/validate-artifact.sh
        python3 Scripts/release.py package
    )
    attempt_xcframework="$checkout_root/Artifacts/LibASS.xcframework"
    /bin/cp "$checkout_root/.artifacts/release/$ARTIFACT_NAME" "$attempt_root/$ARTIFACT_NAME"
    (
        cd "$(dirname "$attempt_xcframework")"
        /usr/bin/find LibASS.xcframework -type f -print |
            LC_ALL=C /usr/bin/sort |
            while IFS= read -r path; do /usr/bin/shasum -a 256 "$path"; done
    ) >"$attempt_root/xcframework-files.sha256"
    swift package compute-checksum "$attempt_root/$ARTIFACT_NAME" >"$attempt_root/swiftpm-checksum.txt"
done

for filename in "$ARTIFACT_NAME" xcframework-files.sha256 swiftpm-checksum.txt; do
    /usr/bin/cmp -s "$evidence_root/attempt-1/$filename" "$evidence_root/attempt-2/$filename" || {
        echo "Reproducibility failed for $filename; inspect $evidence_root" >&2
        exit 1
    }
done
checksum="$(<"$evidence_root/attempt-1/swiftpm-checksum.txt")"
duration_seconds="$(( $(date +%s) - first_started ))"
jq -n -S --arg checksum "$checksum" --arg mode "${mode#--}" \
    --argjson duration "$duration_seconds" \
    '{schemaVersion: 1, result: "pass", mode: $mode, attempts: 2,
      checksum: $checksum, durationSeconds: $duration}' >"$evidence_root/summary.json"
echo "Reproducibility passed: $checksum"
echo "Evidence: $evidence_root/summary.json"
