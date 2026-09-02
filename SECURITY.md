# Security policy

The newest package release is supported. Older releases remain immutable;
fixes are published as new versions.

Report vulnerabilities through GitHub's confidential vulnerability-reporting
feature. Include the affected version, platform, impact, and a minimal
reproduction. Do not publish credentials, sensitive media, or exploit details
in an issue. Report issues wholly inside libass or a bundled library to the
appropriate upstream maintainers as well.

The release pipeline verifies canonical source URLs and SHA-256 digests,
rejects unsafe archive paths and links, and separates read-only builds from
publication. The binary is validated and tested before release; SwiftPM checks
its immutable download checksum. Keep the exact package pin and checksum.
