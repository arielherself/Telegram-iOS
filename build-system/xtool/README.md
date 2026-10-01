# Linux xtool adapter (work in progress)

Builds **Arielgram** (`xyz.arielherself.Arielgram`) with its own App Group,
Keychain access group, iCloud container, extension identifiers, and `arielgram://`
URL scheme. Exports the existing Bazel iOS arm64 Release graph into SwiftPM, cross-compiles
native codec dependencies, and uses xtool to link and pack the application.
It does not use GitHub Actions, Apple login, or provisioning profiles.

The build requires xtool 1.20.1, Swift 6.3, the xtool Darwin SDK extracted from
Xcode 26.2, Bazel 8.4.2, Linux LLVM, CMake, Ninja, Meson, Make, NASM/YASM,
autoconf/automake/libtool, pkgconf, Go, Python with Pillow, Poppler's pdftocairo,
and librsvg's rsvg-convert. Signing metadata correction requires
[ProcursusTeam/ldid](https://github.com/ProcursusTeam/ldid) (build dependencies:
OpenSSL and libplist) and bsdtar. IPA compression uses zip, with a bsdtar fallback. Generated output lives in ignored `build/xtool`.

For a single entry point, use `python3 build-system/xtool/build.py --bazel /path/to/bazel`.
Use `--skip-native` only when the generated codec archives already exist.

The query-only configuration uses the repository's appstore configuration and
Arielgram's placeholder service settings. It does not contain an Arielgram
service public key, custom purchases, or developer signing credentials.

```bash
python3 build-system/xtool/sdk_compat.py --clang-resources /path/to/swift/usr/lib/clang/21
python3 build-system/xtool/bootstrap.py --bazel /path/to/bazel
python3 build-system/xtool/prepare.py --bazel /path/to/bazel
python3 build-system/xtool/generate.py --bazel /path/to/bazel
python3 build-system/xtool/native.py --bazel /path/to/bazel opus webp mozjpeg dav1d vpx ffmpeg td
python3 build-system/xtool/intents.py
python3 build-system/xtool/prepare.py --bazel /path/to/bazel
python3 build-system/xtool/linux_resources.py --bazel /path/to/bazel --query-file build/xtool/rules.star
(cd build/xtool && CC="$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/toolset/bin/clang-compatible" xtool dev build --ipa --configuration release)
```

`sdk_compat.py` preserves the original SDK configuration as
`swift-sdk.json.xtool-original` and creates a symlink overlay: Apple Darwin
libraries remain unchanged, while builtin C headers come from the matching
Linux Swift compiler. This fixes Apple-only NEON intrinsics in Accelerate/simd.
The same step installs a Clang argument adapter for mixed C/Objective-C/C++
targets. SwiftPM 6.3 requires the `CC` environment override shown above
to select the adapter. C++ dialect options are retained only for C++/Objective-C++ sources.

`bootstrap.py` refuses to overwrite an existing configuration. Supply
`--configuration` for a custom configuration. `--query-file` on the export and
native scripts reuses a saved Bazel query to avoid repeated graph resolution.

The driver also applies `patches/lottie-vector3d.patch` to the nested LottieCpp
submodule. It supplies component-wise equality for Vector3D, required by the
existing `std::optional<Vector3D>` keyframe comparisons. The patch is idempotent
and leaves a reviewable uncommitted submodule change.

The export also supplies missing Abseil production sources, corrects the UIKit
framework spelling, and shares Ogg/Opusfile and WebRTC platform-helper
implementations across targets to avoid duplicate symbols. FFmpeg configuration
uses LLVM nm to detect the Mach-O symbol prefix.

Linux resource adaptations are applied only to exported source copies:

- PDF/SVG image assets become named PNGs at 1x, 2x, and 3x. Namespaces and
  transparency are preserved. Vector representation is rasterized.
- UIImage's named-image lookup applies the original template-rendering metadata.
- Original Metal shaders and quoted includes are packed as source and compiled
  on device. The first load incurs compilation overhead; device testing is needed.
- Widget INIntent/INObject types use the system's `@NSManaged` storage. The original
  localized intent definitions are included. Widget runtime behavior needs testing.
- The empty launch-screen XIB becomes a `UILaunchScreen` declaration on iOS 14+.
  The iOS 13 launch-screen fallback has not been validated.
- Resources are copied into each statically linked extension so `Bundle(for:)`
  works inside extensions. This increases archive size.
- Classic primary and alternate icon PNGs are packed. Icon Composer's iOS 26
  material/glass effects are not reproduced by the classic primary icon.

`resource-status.json` records outstanding runtime limitations. Export completion
alone does not prove an IPA was built. An IPA without a developer signature must
be re-signed with appropriate app/extension entitlements before installation.

Validation:

```bash
python3 -m unittest discover -s build-system/xtool -p 'test_*.py'
```

The parser never evaluates arbitrary BUILD Python; unknown expressions/selects
fail explicitly. Apple generators are not replaced by empty implementations.
`resources.py` also retains a macOS compiler backend for local use on a Mac;
this is not used by the Linux workflow above.

The single-entry driver verifies the completed IPA automatically. To check an
archive independently, verify its embedded Mach-O entitlements (including all
six extensions) and localized UI resources:

```bash
python3 build-system/xtool/validate_identity.py build/xtool/xtool/Arielgram.ipa --report build/xtool/identity-validation.json
```

The checks reject missing extensions, a shared upstream Bundle ID/App Group/Keychain
group/iCloud container, a URL scheme other than `arielgram`, and old branding in
localized resources. These archive checks do not replace device testing. Re-signing
can alter entitlements; preserve the isolated identifiers described in the root README.

xtool 1.20.1's Linux signer passes the root entitlements to all extensions.
`fix_entitlements.py` applies each product's own entitlement file, then uses
`ldid -S -M` to regenerate the bundle resource seals while preserving those values.
This is ad hoc signing; it does not supply a developer certificate or provisioning
profile. The driver performs this step before validating the actual IPA.

WidgetKit needs iOS 14 or later. `extensions.py` corrects the Widget executable's
minimum and linked SDK version, using `SDKSettings.json` from the extracted SDK,
and writes matching iPhoneOS metadata into its Info.plist before signing. It
preserves xtool's `_NSExtensionMain` entry and the existing Mach-O flags. This
metadata-only correction was installed successfully on the connected iOS 27 device.

Self-signing can remove iCloud capabilities even when the build requested them.
BuildConfig checks the executable's current signed entitlements before enabling
CloudKit or the iCloud key-value store. Local login-token storage remains available
without those capabilities; this avoids the observed startup trap in
`CKContainer.default()` on a free-account signature.

Siri authorization also requires the current signature to grant
`com.apple.developer.siri`. BuildConfig checks that permission before querying or
requesting authorization: iOS throws an exception for either INPreferences call
when a self-signing profile omits Siri, including after login.
