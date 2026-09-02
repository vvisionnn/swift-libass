#!/bin/bash -p
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
while IFS= read -r script; do
    bash -n "$script"
    shellcheck -x "$script"
done < <(find Scripts -type f -name '*.sh' | LC_ALL=C sort)
if [[ -d .github/workflows ]]; then actionlint; fi
python3 -m compileall -q Scripts Tests/ReleaseTests
python3 -c 'import plistlib; from pathlib import Path; plistlib.loads(Path("Sources/LibASSLinkerSupport/PrivacyInfo.xcprivacy").read_bytes())'
jq -e '.schemaVersion == 1 and .artifact.name == "LibASS.xcframework.zip"' Configuration/release.json >/dev/null
git diff --check
echo "Script, workflow, configuration and privacy lint passed"
