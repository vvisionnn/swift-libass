# swift-libass

Prebuilt [libass](https://github.com/libass/libass) for Swift projects on iOS,
iPadOS, and macOS. Import the original C API without building the subtitle
renderer or configuring its system linker dependencies yourself.

## Add the package

```swift
.package(url: "https://github.com/vvisionnn/swift-libass.git", exact: "1.0.0")
```

Add the `LibASS` product to your target:

```swift
.product(name: "LibASS", package: "swift-libass")
```

```swift
import LibASS

let library = ass_library_init()!
let renderer = ass_renderer_init(library)!
ass_set_frame_size(renderer, 1920, 1080)
ass_set_fonts(renderer, nil, "Helvetica", Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1)

// Load a track and call ass_render_frame for each presentation time.
// Composite the returned ASS_Image bitmaps in your application's renderer.

ass_renderer_done(renderer)
ass_library_done(library)
```

The package owns no playback clock or UI. Each rendering session owns its
libass library, renderer, and tracks; release them with the matching libass
functions. The product supplies CoreText, CoreFoundation, iconv, C++ linkage,
and the required privacy resource automatically.

## Platforms and build

| Destination | Architectures | Minimum OS |
| --- | --- | --- |
| iOS / iPadOS device | arm64 | 15.0 |
| iOS / iPadOS Simulator | arm64, x86_64 | 15.0 |
| macOS | arm64, x86_64 | 12.0 |

The static XCFramework contains libass, FreeType, HarfBuzz, and FriBidi.
It uses CoreText as the system font
provider. Optional libunibreak, fontconfig, DirectWrite, and optional
HarfBuzz/FreeType integrations are disabled. See
[Configuration/release.json](Configuration/release.json) for exact source
URLs, hashes, toolchain versions, and the release checksum.

Every release includes the checksum-pinned XCFramework, an exact
corresponding-source and rebuild kit, a release manifest, and `SHA256SUMS`.
The source kit includes all four upstream archives, licenses, build scripts,
and configuration. Release tags and assets are immutable.

## Development and maintenance

Install [mise](https://mise.jdx.dev/), select the Xcode version declared in
the release configuration, then run:

```sh
mise install --locked
mise run doctor
mise run sources:fetch
mise run build
mise run check
mise run reproducibility
```

Native development uses `SWIFT_LIBASS_USE_LOCAL_XCFRAMEWORK=1` with the ignored
`Artifacts/LibASS.xcframework`; normal package use leaves that variable unset
and downloads the checksum-pinned release asset.

GitHub Actions checks the canonical stable libass release daily. A new version
is built with the pinned dependencies, tested on macOS and iOS Simulator,
checked for reproducibility, and published with an updated package manifest.
The main branch advances only after exact-tag remote package validation.
Unchanged upstream releases do not launch native build jobs. Dependency and
toolchain pin changes remain explicit reviewed updates.

## Licenses

Packaging code is MIT licensed. libass is ISC licensed, FreeType uses the
FreeType Project License for this build, HarfBuzz uses its MIT-style terms,
and FriBidi is LGPL-2.1-or-later. These licenses are not replaced by the
package's MIT license. Read [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
and [static relinking requirements](Licenses/Static-Relinking.md) before
distributing an application that statically links the artifact.
