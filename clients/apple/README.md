# HQ for Mac and iPhone

Native SwiftUI clients for an HQ server: chat (rooms, DMs, replies, tapbacks,
mentions, attachments, link previews, typing, read state), tasks and the board,
docs and files, meetings with live calls, the Agents page, and the basic
settings (account, this device, MCP keys, members).

There is no default server. You type your server's address on the sign-in
screen. The server must speak the HQ app protocol (the REST paths and socket
frames the app's `Sources/Shared/Models/Wire.swift` and `Sources/Shared/Net`
mirror).

## What you need

- macOS 15 or later and Xcode 26.6 (the iPhone app targets iOS 18).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
  CI uses the pinned release named in `.github/workflows/apple.yml`.
- Nothing else. The only package is WebRTC (stasel/WebRTC, pinned to 152.0.0),
  which Xcode fetches.

## Build

Run these from `clients/apple/`. The Xcode project is generated from
`project.yml`, so regenerate it before every build.

```sh
xcodegen generate

# Mac
xcodebuild -project HQ.xcodeproj -scheme HQ -configuration Debug \
  -derivedDataPath .dd build CODE_SIGNING_ALLOWED=NO

# iPhone (Simulator)
xcodebuild -project HQ.xcodeproj -scheme HQ-iOS -configuration Debug \
  -derivedDataPath .dd -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

Or open `HQ.xcodeproj` in Xcode and run the `HQ` or `HQ-iOS` scheme.

## Test

```sh
xcodebuild -project HQ.xcodeproj -scheme HQ -configuration Debug \
  -derivedDataPath .dd test CODE_SIGNING_ALLOWED=NO
```

The `HQ` scheme runs the hosted unit tests. The headless schemes
(`HQLiveTests-Mac`, `HQHomeTests-Mac`, `HQTypingTests-Mac`, `HQHomeTests-iOS`,
`HQPhotoTests-iOS`, `HQAudioTests-iOS`, `HQSessionSyncTests-Mac`) run the same way;
the iOS ones need a `-destination` for a simulator.

### Against a real server

`Tests/LiveServerTests.swift` runs the app's real `HQClient`, `EventSocket` and
`AppStore` against a real HQ server (no fixtures, no mocks). It is skipped unless
all three variables are set; `TEST_RUNNER_` is how `xcodebuild` hands them to the
test host:

```sh
export TEST_RUNNER_HQ_LIVE_SERVER=http://127.0.0.1:18790
export TEST_RUNNER_HQ_LIVE_KEY_A="$(cat ada.key)"   # an invite key for an admin
export TEST_RUNNER_HQ_LIVE_KEY_B="$(cat bo.key)"    # an invite key for a member
xcodebuild -project HQ.xcodeproj -scheme HQ -configuration Debug \
  -derivedDataPath .dd test -only-testing:HQTests/LiveServerTests CODE_SIGNING_ALLOWED=NO
```

Use a throwaway database: the tests create rooms, messages, keys and a person per
run. The `live` job in `.github/workflows/apple.yml` starts a fresh server from the
same checkout and runs exactly this.

A debug build can also screenshot a live launch: set `HQ_UI_SNAPSHOT=<png>`,
`HQ_UI_SNAPSHOT_SIZE=1440x900`, `HQ_UI_OPAQUE=1` and `HQ_UI_APPEARANCE=light` with
no `HQ_UI_SCENARIO`, after signing in once.

## Sign with your own team

Identity and signing live in one file, `Config/Signing.xcconfig`:

- `BUNDLE_ID_PREFIX`: your reverse-DNS prefix (default `org.example`). Both apps
  are `$(BUNDLE_ID_PREFIX).hq`. The Keychain service, log subsystem, cache
  folders, preferences suite and URL type names are all derived from the bundle
  id at run time, so changing the prefix changes all of them.
- `DEVELOPMENT_TEAM`: your 10-character Apple team id. It is empty by default.
  Debug builds do not need one: the Mac app is ad-hoc signed ("Sign to Run
  Locally") and the iPhone app runs unsigned in the Simulator. You need a team
  to run on a physical iPhone or to archive a Release build.

- `HQ_SIGNING_MODE`: `local` (the default) or `team`. `local` is the build
  described above, with no push and no desktop widgets. `team` adds push and
  the Mac's widgets; see below.

You can also override any of these on the `xcodebuild` command line, for
example `xcodebuild ... DEVELOPMENT_TEAM=ABCDE12345 BUNDLE_ID_PREFIX=com.you`.
Do not commit your team id to a shared repository.

## Push notifications

Message notifications with the app closed (a closed Mac, a phone in a pocket)
come from Apple's push service. They are off in a `local` build, which is the
default: the app builds and runs exactly as without push, shows banners while
it is running, and never asks Apple for a token or tells the server anything
about push. The app counts the icon badge itself from the chat list; see
`docs/push.md` for when a closed app's badge moves.

To turn push on for your own builds you need:

1. An Apple Developer Program team (a free account cannot use push).
2. An App ID for `<BUNDLE_ID_PREFIX>.hq` with the **Push Notifications**
   capability. Automatic signing creates and manages it for your team when you
   build with `DEVELOPMENT_TEAM` set. Use a prefix that is yours: the App ID
   belongs to whichever team registers it first.
3. A server that sends the pushes. Each host brings their own APNs key (made in
   their Apple account) and their own signing team; there is no shared relay.
   What the server must send and accept is in `docs/push.md`.

Then build with the mode and your team:

```sh
xcodebuild -project HQ.xcodeproj -scheme HQ -configuration Debug \
  -derivedDataPath .dd build \
  HQ_SIGNING_MODE=team DEVELOPMENT_TEAM=ABCDE12345 BUNDLE_ID_PREFIX=com.you
```

(or set the three values in `Config/Signing.xcconfig`). `team` mode:

- adds the push entitlement: `com.apple.developer.aps-environment` on the Mac
  and `aps-environment` on the iPhone, `development` for Debug builds and
  `production` for Release builds (`Resources/*Team.entitlements`,
  `Resources/HQ-iOS*.entitlements`);
- signs the Mac app with your team's "Apple Development" identity instead of
  ad hoc (macOS refuses to launch an ad-hoc app that claims the push
  entitlement);
- so it needs a real signing setup. Without a team, leave the mode at `local`.

A Debug build reports `development` tokens and a Release build `production`
ones, so sign Release builds with a distribution profile. Team-mode Release
signing has not been tested by this project.

## Desktop widgets

The Mac app can show two widgets, **My Tasks** and **Board** (your tasks by
status, read-only; a tap opens the task in HQ). They need the same `team` mode as
push, and a server with the Tasks app (it answers `/v1/widgets/summary`; see
`../../docs/widgets.md`). In a `local` build there are no widgets and nothing
else changes: the extension is built but not put in the app, its entitlements ask
for no App Group, and the app never starts the sync.

Build with `HQ_SIGNING_MODE=team DEVELOPMENT_TEAM=<yours>` as for push. `team`
mode also:

- adds the App Group `$(TeamIdentifierPrefix)` + the app's bundle id
  (`<BUNDLE_ID_PREFIX>.hq`) to the app's entitlements
  (`Resources/HQ-Team.entitlements`, `Resources/HQ-Release-Team.entitlements`)
  and to the extension's (`Resources/HQWidgets-Team.entitlements`). It is how the
  app hands the extension its widget key and the last summary; no team id is
  written in the source. Automatic signing should register the group for your
  team (unverified);
- puts the widget extension (`<BUNDLE_ID_PREFIX>.hq.widgets`, macOS 26) in the
  app, with the `Embed widgets` build script in `project.yml`;
- defines the `HQ_WIDGETS` Swift flag, which turns the sync on.

Run the app once and sign in, then add **HQ** widgets from the desktop's widget
gallery (Edit Widgets). The app mints the widget key when it sees a widget on the
desktop. `docs/widgets.md` has the details. Team-signed widgets have not been
tested by this project.

## Session sync

A background helper inside the Mac app (`HQSessionSync`, a login item) reads your Claude
Code and Codex conversations from the last 7 days and uploads them as text to the server
you are signed in to, so teammates see them on the Agents board and can open the
transcript. It is on after sign-in, asks first with a notice that says what leaves the Mac
and who can read it, and has a Pause switch in the notice and in Settings → Coding;
signing out stops it. Secrets are hidden before upload on a best-effort basis.

It runs only in a `team`-signed build (`HQ_SIGNING_MODE=team`): the helper's Keychain item
needs a signing identity that survives a rebuild. A `local` build leaves it off and Settings
says so. Everything it reads, sends, hides and needs from a server is in
`docs/session-sync.md`.

## Point the app at a server

On the sign-in screen (Mac and iPhone) fill in three fields:

1. **Server**: your HQ address, for example `hq.example.com`. A bare host gets
   `https://` (a bare `localhost`, `127.0.0.1` or `.local` name gets `http://`).
   Plain `http://` is accepted only for those local names, so a server on your
   own machine or network works without a certificate.
2. **Access key**: the key you were given.
3. **Your name**: leave it blank if you have joined before.

The app remembers the last server you used. A session belongs to one server, and
its Keychain item and cache are keyed by that server's host and port.

## Offline fixtures

Debug builds carry a fixture harness (`Sources/Shared/Fixtures`) that fills the
app with invented people and projects and answers every request locally, so a
screen can be checked without a server. Set `HQ_UI_SCENARIO` (for example
`chat`, `projects`, `meetings`, `files`, `settings`, `call`) in the scheme's
environment. `docs/architecture.md` lists the other switches.

## Layout

- `Sources/Shared`: the wire mirror, the HTTP and socket clients, `AppStore`,
  the design system and the views both platforms share.
- `Sources/macOS`, `Sources/iOS`: the platform shells and platform-only views.
- `Tests`, `Tests-*`: unit tests.
- `docs/architecture.md`: how the clients are built, and the layout traps.

## Privacy

- **Link previews are fetched by each reader's device.** When someone sends a
  message that is only a link, your Mac or iPhone requests that page itself
  (Apple's LinkPresentation) to draw the card, so the site sees your device's
  address, not the sender's and not your server's. Turn it off in Settings →
  "Show link previews" (on by default); links from other people then stay plain
  text and nothing is fetched for them.
- **Calls are transcribed by the server when it has speech-to-text configured.**
  While you are in a call the app streams your microphone to your server's
  transcription endpoint, and the server also records the call. The call
  window shows "Recording · Transcribing" for as long as that runs. The app
  cannot tell whether your server has speech-to-text set up, so treat every
  call as transcribed.
- **STUN.** To set up a call, each device asks a public STUN server
  (`stun.cloudflare.com:3478`) for its public address, so that server sees the
  device's IP address.
- **Session sync uploads your coding conversations** (Claude Code and Codex, text only, last
  7 days) to your server, where everyone on it and its operator can read them. It asks
  first and can be paused; see Session sync above.
- No analytics or crash-reporting package is linked: the only package is WebRTC.

## Third-party

- WebRTC, packaged by [stasel/WebRTC](https://github.com/stasel/WebRTC)
  (BSD-3-Clause), built from Google's WebRTC (Google's WebRTC license, a
  BSD-style license). Pinned to 152.0.0.

## Scope

Notifications are local banners while the app runs. Message push and the
badge with the app closed need a team-signed build (`HQ_SIGNING_MODE=team`) and
a server that holds an APNs key. Calls ring through CallKit on iPhone while the
app is running; there are no push rings yet. Widgets are Mac-only and need a
team-signed build (see "Desktop widgets").
