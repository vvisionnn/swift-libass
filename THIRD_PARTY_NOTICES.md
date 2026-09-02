# Third-party notices

The LibASS static XCFramework includes these unmodified upstream sources:

| Library | Selected license |
| --- | --- |
| [libass](https://github.com/libass/libass) | [ISC](Licenses/libass-ISC.txt) |
| [FreeType](https://freetype.org/) | [FreeType Project License](Licenses/FreeType-FTL.txt) |
| [HarfBuzz](https://github.com/harfbuzz/harfbuzz) | [Old MIT](Licenses/HarfBuzz-Old-MIT.txt), [Microsoft MIT](Licenses/HarfBuzz-Microsoft-MIT.txt) |
| [FriBidi](https://github.com/fribidi/fribidi) | [LGPL-2.1-or-later](Licenses/FriBidi-LGPL-2.1.txt) |

Portions of this software are copyright © The FreeType Project
(https://freetype.org). All rights reserved.

Exact versions, source URLs, and SHA-256 values are recorded in
`Configuration/release.json`. Each release includes the four corresponding
source archives, these notices, and rebuild tooling in its source-kit asset.
No optional libunibreak, fontconfig, GLib, ICU, or Graphite2 code is bundled.
Apple frameworks and system runtimes are linked from the operating system.

FriBidi remains subject to its LGPL terms when combined into a static archive.
See [Licenses/Static-Relinking.md](Licenses/Static-Relinking.md). The MIT license
for packaging code does not change any upstream library license.
