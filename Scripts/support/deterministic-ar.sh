#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/support/common.sh
source "$SCRIPT_DIR/support/common.sh"
reject_shell_startup_environment

create_deterministic_archive() {
    local flags="$1"
    local output="$2"
    shift 2
    local input
    local line=""
    local object
    local response_file
    local object_count=0
    local -a objects

    if [[ "$flags" != *r* ]]; then
        echo "Unsupported deterministic archive flags: $flags" >&2
        exit 1
    fi

    for input in "$@"; do
        if [[ "$input" == @* ]]; then
            response_file="${input#@}"
            while IFS= read -r line || [[ -n "$line" ]]; do
                for object in $line; do
                    objects[object_count]="$object"
                    object_count=$((object_count + 1))
                done
            done <"$response_file"
        else
            objects[object_count]="$input"
            object_count=$((object_count + 1))
        fi
    done

    if [[ "$object_count" -eq 0 ]]; then
        echo "Cannot create an empty deterministic archive: $output" >&2
        exit 1
    fi

    /usr/bin/libtool -static -D -o "$output" "${objects[@]}"
}


case "${1:-}" in
    --version)
        echo "swift-libass deterministic ar 1.0"
        exit 0
        ;;
    -h)
        echo "usage: deterministic-ar [csr] archive object ..."
        exit 0
        ;;
esac
[[ "$#" -ge 3 ]] || { echo "Expected flags, archive and objects" >&2; exit 2; }
create_deterministic_archive "$@"
