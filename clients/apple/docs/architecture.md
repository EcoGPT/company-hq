# How the Apple clients are built

Notes for people changing the Mac and iPhone apps: chrome and layout, the
iPhone app, the offline UI fixtures and calls. Sizes and tokens live in
`Sources/Shared/Design/Tokens.swift` and `GlassStyle.swift`.

## Client UI

Both clients unless a line names one.

- **Messages model:** a compact conversation list, blue outgoing and gray
  incoming bubbles, a bottom composer. The list holds the Updates feed
  (visible while empty), any bot DM, then threads by recency. Personal pins
  never change shared recency; `HomePreferences` is per device.
- Messages stay in creation-time order (`Message.transcriptDate`).
- Documents open the app's own preview. Mac file drops go through
  `FileDropCatcher`, not SwiftUI `onDrop`. An active call is the shared
  `CallReturnStrip`, mounted once above page navigation.
- **Mac shell:** the sidebar never fully collapses; below
  `SidebarMetrics.railBelow` it becomes the avatar rail. Sidebar changes are
  immediate, with no animation. Desktop columns use one `HSplitView`;
  `DesktopDetailPanel` is a fixed-width overlay whose width the content
  reserves in the same update. Closing the last window leaves the app in the
  menu bar.
- **Shortcuts** live in the menu bar (`Sources/macOS/HQCommands.swift`), not in
  invisible buttons. A new shortcut is a menu item fed by the focused
  `HQShellActions`; one that cannot act is disabled, not hidden.
- **Window chrome:** the shell owns header geometry and one `WindowControls`.
  The native toolbar is hidden on every route: do not reserve an opaque
  toolbar band, restore an empty titlebar strip or draw replacement traffic
  lights.
- **Glass:** only bars group glass in `hqGlassContainer`; inside a glass panel
  use `panelWell` tints, not glass on glass. Flat colour, no gradients; glass
  cards take native elevation, no extra shadow.
- **Projects:** the Mac board drags with its own `DragGesture`; the iPhone
  keeps one drop destination per board; every drag has a menu and VoiceOver
  twin. Leaving Done writes `open` first (`ProjectsModel.statusWrites`).
- **Assistant:** the assistant is whichever person the server marks as a bot
  (`kind == "bot"`); there is no special-cased name.
- **Fixtures and snapshots:** fixture people are invented. Glass does not
  survive `cacheDisplay`: render snapshots with `HQ_UI_OPAQUE=1`.

## SwiftUI layout traps

Each of these was a live bug.

- The transcript is a plain `VStack`, not `LazyVStack` (lazy placement plus
  measured bubble text re-measured itself into a main-thread hang), so history
  stays bounded: `AppStore.trimLoadedHistory` trims a thread to
  `StateCache.messagesKept` on switch-away, never under a transcript on
  screen. The open chat trims too, while pinned to the bottom with a page
  past the window (`trimPinnedTranscript`), and when the main window closes;
  a history page that lands after a trim is dropped.
- Incoming messages reassert the bottom only when the reader is pinned there;
  explicit sends use `latestOutgoingMessageIDs`. Failed and in-flight messages
  keep insertion order with the same client message id. Keyboard animations
  emit offset-only geometry, which is not the reader scrolling away.
- History paging: one user gesture, one page; programmatic scrolls request
  none. On the Mac `TranscriptViewportPreserver` keeps the viewport across a
  prepend; the spinner is an overlay.
- Bubble measurement caches by width (`Measurer`); nothing in `draw` walks
  the transcript.
- Do not animate anything that changes the chat column's width, or snapshot
  and fade native glass. Content never decides a column's width (`ColumnWidth`).
- An `.alignmentGuide` on `overlay(alignment:)` content is ignored: hang a
  popup from a zero-height frame.
- On the Mac, `safeAreaInset` through `ScrollViewReader` shrinks the scroll
  view: float with a bottom-aligned `ZStack` and a measured spacer, not
  `.contentMargins`. iOS 26 uses `safeAreaBar`.
- A growing editor never goes in a fixed-height `ToolbarItem`.
- A `repeatForever` animation runs while the window is hidden: wrap it in
  `WindowVisibilityReader`.
- Sidebar measurements use `NSSplitView.arrangedSubviews`, not `subviews`, and
  never persist the inset content width as a divider position.
- Every round control gets an explicit `.contentShape`; a `.background` does
  not enlarge the hit area.
- The iPhone composer's `UITextView` owns its gestures: no tap gesture around
  it. Composers use `hqComposerGlass`, with everything inside the glass.
- A `Menu` with a custom label takes `.menuStyle(.button)`. A pinned avatar in
  an iPhone `List` is a `Menu` with a `primaryAction`, not a `.contextMenu`.

## The iPhone app

`Sources/iOS` plus everything in `Sources/Shared` except `Views/`.

- It shares the Mac's bundle id (`$(BUNDLE_ID_PREFIX).hq`), so one access key
  and one server setting serve both.
- `Resources/HQ-iOS-Info.plist` is hand-maintained and only referenced
  (`INFOPLIST_FILE`); XcodeGen's `info:` key would overwrite it. No
  `NSAllowsArbitraryLoads`; `NSAllowsLocalNetworking` is the dev allowance.
- The draft lives in `AppStore.textDrafts`, keyed by conversation. Popping back
  to the list writes nil through the selection, which is how
  `isReadingThread` learns the transcript left the screen.
- A long-press menu is a sheet, not a `.contextMenu`: the tapback strip leads,
  and a context menu cannot lay reactions across the top.
- Calls: `CallAudioConfiguration` installs WebRTC's defaults before the
  factory starts, through `RTCAudioSession`'s lock, and releases the session on
  leave. No screen share from the phone. CallKit is the ring surface while
  the app runs: every incoming call reports into `CallKitCoordinator`, one
  claim per call id; WebRTC waits for CallKit's audio activation. The
  simulator never draws the call UI: verify on a device. A media-services
  reset replaces the WebRTC factory, not only the peer.
- Notifications are local banners while the app runs (`NotificationManager`).
  Remote push (messages and the badge) exists only in a build signed with
  `HQ_SIGNING_MODE=team`, which swaps in the push entitlements and defines
  `HQ_PUSH`; every other build never registers. The wire is in `docs/push.md`.

## UI fixtures

Debug builds carry an offline harness (`Sources/Shared/Fixtures`).
`HQ_UI_SCENARIO` starts it with an in-memory session and routes every request
through `HQFixtureProtocol`, so nothing reaches a server or the real Keychain.
The `HQ*Fixture` types list the scenarios; `HQ_UI_CONTENT`, `HQ_UI_ROUTE`,
`HQ_UI_KEYBOARD=1`, `HQ_UI_OPAQUE=1` and `HQ_UI_HOME_STORAGE` adjust them.
Fixtures qualify layout, not a live server.

Settings has one scenario per page: `settings-general`, `settings-coding` and
`settings-admin`. `HQ_UI_SETTINGS_ROLE=member` signs the fixture in as a
member, with no Admin page. `HQ_UI_REQUEST_LOG=<file>` appends `METHOD /path`
for each fixture request, to count what a page asks the server for.
`HQ_UI_SETTINGS_FAIL=mcp-keys` fails that `GET /v1/<name>` read as if offline,
to show a card's error line.

A store loaded from a fixture remains ineligible for persistent session writes
after a test restores `HQ_UI_SCENARIO`. Delayed sign-out work must not enter
those real-session paths.

Launch a scenario on a dedicated simulator to look at it:

```sh
SIMCTL_CHILD_HQ_UI_SCENARIO=call xcrun simctl launch <UDID> <bundle id>
```

A landscape request that keeps capturing portrait, or a zero keyboard frame,
is the simulator: reboot it.

## Calls

- A ring is an AppKit `NSPanel` (`IncomingCallWindow`), so it shows with the
  main window closed or behind a full-screen app. `AppStore` owns it: one at a
  time, never for your own call, never past `expires_at`.
- The meeting `Window` scene uses `.windowManagerRole(.principal)`: a
  non-first scene defaults to the associated role, which disables Enter Full
  Screen. Answering joins with mic live, camera off.
- Local tracks use `addTransceiver(direction: .sendOnly)`, never `addTrack`
  (it takes a teammate's receive slot). Camera and screen are negotiated at
  join against a server offering `quiet_tracks`, so a toggle adds no m-section.
- A rejected description ends the connection: unpublish, log the m-sections
  (never ICE credentials or candidates) and rebuild. Every negotiation is
  pinned to its connection generation.
- The camera is taken away only by a proven-dead capture, an ICE failure or
  the user. Mute is never a dead mic. A changed audio device rebuilds at most
  once per 20 seconds and four times a call.
