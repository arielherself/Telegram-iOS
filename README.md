# Arielgram

An unofficial Telegram client for iOS with local change tracking and an independent
app identity. It can be installed alongside other clients.

## Features

- **Message history:** retain deleted messages with a `deleted` label. Open
  **History** from the long-press menu for the original observed version and edits,
  displayed as complete message bubbles with text differences and changed-media badges.
- **Profile changes:** local system messages for observed name and avatar changes
  in private chats, groups, group members, and channels, with old/new avatar previews.
- **Protected chats:** allow screenshots, copying, saving, sharing, and forwarding.
- **Content visibility:** ignore client content restrictions, including `porn-ios`.
- **No sponsored ads:** hide Telegram sponsored messages and search placements.
- **Pro features:** enable all local Pro features without a subscription.
- **Background monitoring:** optionally continue receiving updates in the background.

## Tracking and storage

History records only changes the client receives. It cannot reconstruct missed
versions or profile changes. Each message version retains its own content; article
pages are preserved without text diff highlighting. Secret chats and timed
disappearing messages keep their normal deletion behavior.

Records are local and follow chat/account cleanup. Media and avatars use the normal
cache and may become unavailable after automatic or manual storage clearing.

**Background Message Monitoring** is available on the settings home page and off
by default. It uses silent audio mixed with other apps and yields to in-app media
and calls. Enabling it increases battery use; force quitting, system termination,
audio interruptions, and lost connectivity can still leave recording gaps.

## Build and install

- [Linux / xtool](build-system/xtool/README.md): dependencies and local IPA builds.
- [iOS build and signing](build-system/ios-build.md): API credentials, independent
  identifiers, signing, and Xcode builds.

With the xtool dependencies and Darwin Swift SDK installed:

```bash
python3 build-system/xtool/build.py --bazel /path/to/bazel
```

Output: `build/xtool/xtool/Arielgram.ipa`, ready for your own re-signing.
The app targets arm64 iOS 13+; WidgetKit requires iOS 14+.
Bundle ID: `xyz.arielherself.Arielgram`. URL scheme: `arielgram://`.

## Services

Telegram still controls content delivery, media access, and message sending.
Local Pro access does not grant Telegram Premium. Optional Pro services and passkeys
require your own service configuration; they are unconfigured by default.
Translations and announcements use this repository, with bundled translation fallback.
See [service configuration](build-system/ios-build.md#service-configuration).

## Credits

Built on [Telegram iOS](https://github.com/TelegramMessenger/Telegram-iOS) and
[the upstream client](https://github.com/Swiftgram/Telegram-iOS), using
[xtool](https://github.com/xtool-org/xtool) for Linux builds. Component licenses apply.
When distributing a fork, use your own API credentials, identify it as unofficial,
follow Telegram's [security guidelines](https://core.telegram.org/mtproto/security_guidelines)
and naming/logo requirements, and publish source as required by the licenses.
