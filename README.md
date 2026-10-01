# Arielgram

An unofficial Telegram client for iOS, built locally with [xtool](https://github.com/xtool-org/xtool).

- App name: **Arielgram**
- Bundle ID: `xyz.arielherself.Arielgram`
- App Group: `group.xyz.arielherself.Arielgram`
- URL scheme: `arielgram://`
- Repository: https://github.com/arielherself/Telegram-iOS

The app, its six iOS extensions, session backups, Keychain access group, and iCloud
container use this independent identity. Extensions use the host Bundle ID with
`.Share`, `.NotificationContent`, `.NotificationService`, `.SiriIntents`, `.Widget`,
and `.BroadcastUpload` suffixes. Re-sign the app and **all** extensions with profiles
for these identifiers; keep the App Group consistent across them. Do not assign an
existing client's Keychain access group or App Group during re-signing.

The app registers only `arielgram://`, so installing it does not take over another
client's URL schemes. Telegram links are still parsed inside the app.

## Local Linux IPA build

See [the xtool build guide](build-system/xtool/README.md) for dependencies and resource limitations.
After installing the Darwin Swift SDK extracted from Xcode:

```bash
python3 build-system/xtool/build.py --bazel /path/to/bazel
```

The unsigned/ad hoc IPA is generated at `build/xtool/xtool/Arielgram.ipa` for your own
re-signing. Generated artifacts are excluded from Git. The app supports arm64 iOS
13 and later; installation, shaders, widgets, and launch behavior require device tests.

## Service configuration

Online UI translations and announcements come from this repository, with bundled
translations as a fallback. Optional Pro API/Web App endpoints default to reserved
`.invalid` domains, with no configured bot, public key, or purchases. These services
are unavailable until you supply your own `sg_config`; no upstream Pro service is
used by default. These are development placeholders, not an Arielgram subscription
or privacy policy. Passkey creation/login is disabled until an associated domain
and compatible service are configured for this app.

`build-system/appstore-configuration.json` is the default local build configuration.
Set your own Telegram API ID/hash and Apple Team ID before distributing or signing.
The name of this configuration file does not imply an App Store release.

# Telegram iOS Source Code Compilation Guide

We welcome all developers to use our API and source code to create applications on our platform.
There are several things we require from **all developers** for the moment.

# Creating your Telegram Application

1. [**Obtain your own api_id**](https://core.telegram.org/api/obtaining_api_id) for your application.
2. Please **do not** use the name Telegram for your app — or make sure your users understand that it is unofficial.
3. Kindly **do not** use our standard logo (white paper plane in a blue circle) as your app's logo.
3. Please study our [**security guidelines**](https://core.telegram.org/mtproto/security_guidelines) and take good care of your users' data and privacy.
4. Please remember to publish **your** code too in order to comply with the licences.

# Quick Compilation Guide

## Get the Code

```
git clone --recursive -j8 https://github.com/arielherself/Telegram-iOS.git
```

## Setup Xcode

Install Xcode (directly from https://developer.apple.com/download/applications or using the App Store).

## Adjust Configuration

1. Use `xyz.arielherself.Arielgram` as the app Bundle ID.
2. Create a new Xcode project. Use `Arielgram` as the Product Name and `xyz.arielherself` as the Organization Identifier.
3. Open `Keychain Access` and navigate to `Certificates`. Locate `Apple Development: your@email.address (XXXXXXXXXX)` and double tap the certificate. Under `Details`, locate `Organizational Unit`. This is the Team ID.
4. Edit `build-system/template_minimal_development_configuration.json`. Use data from the previous steps.

## Generate an Xcode project

```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=build-system/template_minimal_development_configuration.json \
    --xcodeManagedCodesigning
```

# Advanced Compilation Guide

## Xcode

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

## IPA

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

# FAQ

## Xcode is stuck at "build-request.json not updated yet"

Occasionally, you might observe the following message in your build log:
```
"/Users/xxx/Library/Developer/Xcode/DerivedData/Telegram-xxx/Build/Intermediates.noindex/XCBuildData/xxx.xcbuilddata/build-request.json" not updated yet, waiting...
```

Should this occur, simply cancel the ongoing build and initiate a new one.

## Telegram_xcodeproj: no such package 

Following a system restart, the auto-generated Xcode project might encounter a build failure accompanied by this error:
```
ERROR: Skipping '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj:Telegram_xcodeproj': no such package '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj': BUILD file not found in directory 'generator/Telegram/Telegram_xcodeproj' of external repository @rules_xcodeproj_generated. Add a BUILD file to a directory to mark it as a package.
```

If you encounter this issue, re-run the project generation steps in the README.


# Tips

## Codesigning is not required for simulator-only builds

Add `--disableProvisioningProfiles`:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=path-to-configuration.json \
    --codesigningInformationPath=path-to-provisioning-data \
    --disableProvisioningProfiles
```

## Versions

Each release is built using a specific Xcode version (see `versions.json`). The helper script checks the versions of the installed software and reports an error if they don't match the ones specified in `versions.json`. It is possible to bypass these checks:

```
python3 build-system/Make/Make.py --overrideXcodeVersion build ... # Don't check the version of Xcode
```
