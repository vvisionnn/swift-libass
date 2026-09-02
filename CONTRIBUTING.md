# Contributing

Use the checked-in mise tool pins and the exact Xcode/SDK versions in
`Configuration/release.json`. Run `mise run check` before proposing changes.
Native build changes also require `mise run reproducibility`; release changes
require exact-tag validation with `mise run test:remote` after publication.

Keep the `LibASS` product a thin package boundary around the original C API.
Do not add application playback, UI, networking, or subtitle-compositing
policy. System linker settings belong to `LibASSLinkerSupport`.

Use focused Conventional Commits. Preserve all five architectures, the
configured deployment targets, deterministic archive metadata, required
symbols, identical public headers, and the privacy declaration. Add tests for
source discovery, parsing, archive validation, or release changes.

The daily updater obtains the stable libass version and source asset digest
from the canonical upstream GitHub release. It rejects malformed release
metadata, rollbacks, and changed bytes for an existing version. Transitive
dependency and toolchain updates are separate reviewed configuration changes.
Do not weaken source checks to make a new upstream archive pass.

Release jobs build with read-only repository permissions. Publication runs in
a fresh job, checks fixed-name assets and digests, and does not execute native
build outputs. Release tags and published assets must never be replaced;
correct packaging mistakes with a new package version.

Before enabling automatic publication, a repository administrator must enable
GitHub's immutable releases setting. The workflow uses only the built-in
`GITHUB_TOKEN`, verifies that every published release is immutable, and needs
no administrative token or additional personal access token.
