# Corresponding source and static relinking

Each release provides `swift-libass-VERSION-source-kit.zip` containing the
exact libass, FreeType, HarfBuzz, and FriBidi source archives, license texts,
package configuration, and build tooling used for the static XCFramework.
Verify all assets against the same release's `SHA256SUMS`.

Extract the kit, install the locked mise tools, and select the exact Xcode
release from `Configuration/release.json`. The archives are already provided
in `.cache/sources`, so rebuild with:

```sh
mise install --locked
mise run sources:verify
mise run build
```

The build preserves component object files in the merged static archive and
produces `Artifacts/LibASS.xcframework`. To modify FriBidi, supply its complete
modified source archive and update its reviewed source pin, then rebuild.
Set `SWIFT_LIBASS_USE_LOCAL_XCFRAMEWORK=1` when using the rebuilt package.

Application distributors are responsible for satisfying the applicable LGPL
static-linking terms, including the practical ability to relink a modified
FriBidi, required notices, corresponding source, and any necessary application
object files or equivalent relinking mechanism. Providing the library-side
source kit alone does not satisfy every application distribution obligation.
The upstream license texts are authoritative; obtain qualified advice for
your distribution model if needed.
