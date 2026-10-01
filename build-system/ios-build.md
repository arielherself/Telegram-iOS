# iOS build and signing

For Linux cross-compilation, follow the [xtool guide](xtool/README.md).
The Xcode workflow is described below. Both produce Arielgram using the same
independent application identity.

## Source and configuration

```bash
git clone --recursive -j8 https://github.com/arielherself/Telegram-iOS.git
cd Telegram-iOS
```

Obtain your own [Telegram API ID and hash](https://core.telegram.org/api/obtaining_api_id).
Set them and your Apple Team ID in your build configuration. The local xtool driver
uses `build-system/appstore-configuration.json` by default; its filename does not
imply an App Store release. Do not publish credentials or signing material.

## Application identity and signing

| Component | Identifier |
| --- | --- |
| Application | `xyz.arielherself.Arielgram` |
| App Group | `group.xyz.arielherself.Arielgram` |
| URL scheme | `arielgram://` |
| Extensions | Host ID plus `.Share`, `.NotificationContent`, `.NotificationService`, `.SiriIntents`, `.Widget`, `.BroadcastUpload` |

The app, extensions, session backups, Keychain access group, and iCloud container
use this independent identity. Sign the host and **all six extensions** with
matching profiles and keep their shared App Group consistent. Preserve isolation
when a signing tool rewrites identifiers: do not reuse another client's App Group,
Keychain access group, or iCloud container.

The xtool output uses ad hoc signing and requires a developer certificate and
provisioning profiles for device installation. Check the completed archive with:

```bash
python3 build-system/xtool/validate_identity.py path/to/Arielgram.ipa
```

Re-signing may alter entitlements, so inspect the final signed package too. Free
account signing may omit capabilities such as iCloud and Siri; Arielgram checks
the current signature before using those services. See the xtool guide for the
entitlement correction step and device-tested build limitations.

## Service configuration

Online UI translations and announcements use this repository, with bundled
translations as a fallback. Optional Pro API/Web App endpoints in `sg_config`
default to reserved `.invalid` domains, with no bot, public key, or purchases
configured. Supply your own compatible service to use them; no upstream Pro
service is used by default. These placeholders do not constitute a subscription
or privacy policy. Passkeys are disabled until a compatible service and associated
domain are configured for Arielgram.

## Xcode development build

### Install Xcode

Install Xcode (directly from https://developer.apple.com/download/applications or using the App Store).

### Configure the project

1. Use `xyz.arielherself.Arielgram` as the app Bundle ID.
2. Create a new Xcode project. Use `Arielgram` as the Product Name and `xyz.arielherself` as the Organization Identifier.
3. Open `Keychain Access` and navigate to `Certificates`. Locate `Apple Development: your@email.address (XXXXXXXXXX)` and double tap the certificate. Under `Details`, locate `Organizational Unit`. This is the Team ID.
4. Edit `build-system/template_minimal_development_configuration.json`. Use data from the previous steps.

### Generate an Xcode project

```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=build-system/template_minimal_development_configuration.json \
    --xcodeManagedCodesigning
```

## Manual signing and release builds

### Generate with manual signing

1. Copy and edit `build-system/appstore-configuration.json`.
2. Copy `build-system/fake-codesigning`. Create and download provisioning profiles, using the `profiles` folder as a reference for the entitlements.
3. Generate an Xcode project:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=configuration_from_step_1.json \
    --codesigningInformationPath=directory_from_step_2
```

### Build an IPA

1. Repeat the steps from the previous section. Use distribution provisioning profiles.
2. Run:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    build \
    --configurationPath=...see previous section... \
    --codesigningInformationPath=...see previous section... \
    --buildNumber=100001 \
    --configuration=release_arm64
```

## Troubleshooting

### Xcode is stuck at "build-request.json not updated yet"

Occasionally, you might observe the following message in your build log:
```
"/Users/xxx/Library/Developer/Xcode/DerivedData/Telegram-xxx/Build/Intermediates.noindex/XCBuildData/xxx.xcbuilddata/build-request.json" not updated yet, waiting...
```

Should this occur, simply cancel the ongoing build and initiate a new one.

### Telegram_xcodeproj: no such package

Following a system restart, the auto-generated Xcode project might encounter a build failure accompanied by this error:
```
ERROR: Skipping '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj:Telegram_xcodeproj': no such package '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj': BUILD file not found in directory 'generator/Telegram/Telegram_xcodeproj' of external repository @rules_xcodeproj_generated. Add a BUILD file to a directory to mark it as a package.
```

If you encounter this issue, re-run the project generation steps above.


## Build options

### Codesigning is not required for simulator-only builds

Add `--disableProvisioningProfiles`:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=path-to-configuration.json \
    --codesigningInformationPath=path-to-provisioning-data \
    --disableProvisioningProfiles
```

### Tool versions

Each release is built using a specific Xcode version (see `versions.json`). The helper script checks the versions of the installed software and reports an error if they don't match the ones specified in `versions.json`. It is possible to bypass these checks:

```
python3 build-system/Make/Make.py --overrideXcodeVersion build ... # Don't check the version of Xcode
```
