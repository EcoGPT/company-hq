# Desktop widgets: what the app does

For the Mac only (there is no iPhone widget). Paths are under `clients/apple/`. The
server's side is `docs/widgets.md` at the repository root. Widgets exist only in a build
signed with a team (`HQ_SIGNING_MODE=team`, README "Desktop widgets"). Any other build has
no extension, never starts the sync and never calls the routes below.

## The pieces

| Piece                                  | What it is                                                                                                   |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `HQWidgets` target (`Sources/Widgets`) | A sandboxed WidgetKit extension, macOS 26: **My Tasks** (small, medium, large) and **Board** (extra large).  |
| `Sources/WidgetShared`                 | Compiled into the app and the extension: the summary model, `WidgetAPI`, `WidgetShelf`, the invented sample. |
| `Sources/macOS/WidgetSync.swift`       | The app's side: mints the key, writes the summary to the shelf, asks WidgetKit to redraw.                    |
| `Resources/HQWidgets*.entitlements`    | The extension's: sandbox and network. Team mode adds the App Group.                                          |

## The App Group and the names

- The group is `$(TeamIdentifierPrefix)` plus the app's bundle id (`<prefix>.hq`), named in
  `Resources/HQ-Team.entitlements`, `Resources/HQ-Release-Team.entitlements` and
  `Resources/HQWidgets-Team.entitlements`. No team id is written in the source: at run time the
  app and the extension read the group from their own signed entitlements
  (`WidgetIdentity.appGroup`). A build with no team has none, so the shelf is unavailable.
- Widget kinds are `<bundle id>.widgets.my-tasks` and `<bundle id>.widgets.board`, and the log
  subsystem is the bundle id; the extension finds the app's id by dropping its own `.widgets`.
- `local` mode: the extension target is built but the `Embed widgets` script in `project.yml`
  does not put it in the app, its entitlements ask for no group, and `HQ_WIDGETS` is not
  defined, so `WidgetSync.start` and `stop` do nothing (`WidgetSync.isBuilt` is false).
  `team` mode embeds it and defines `HQ_WIDGETS`.

## What the app sends

All on the device bearer, by `WidgetAPI`:

| Call                       | When                                                                        |
| -------------------------- | --------------------------------------------------------------------------- |
| `POST /v1/widgets/key`     | Once per Mac and person, when an HQ widget is on the desktop.               |
| `GET /v1/widgets/summary`  | After the socket connects, on every `tasks` frame (after 2 s), every 5 min. |
| `GET /v1/avatars/people/…` | Your picture, left on the shelf for the board's cards.                      |
| `DELETE /v1/widgets/key`   | At sign-out (`AppStore.signOut`), best effort: not retried if offline.      |

The sync asks WidgetKit for the installed widgets first and does nothing if there are none, so
a Mac without an HQ widget never calls these routes. A 404 (a server without widgets) pauses it
until relaunch.

## What the extension does

It reads `credentials.json` and `summary.json` from the shelf (`Widgets/` in the group
container). When the app's summary is under a minute old it uses it; otherwise it fetches with
the widget key, which is its only credential. A 401 shows "Open HQ on this Mac and sign in." and
deletes that key from the shelf, so the app mints another at its next refresh (the saved key also
records its device, so a new sign-in gets a new key). A summary reaches the shelf, or the screen, only
if the key it was fetched with is still the saved one and belongs to the same person, so a fetch that
finishes after sign-out writes nothing.
Its timeline asks for a fresh entry every 15 minutes.

Redraws: the app asks WidgetKit to reload when the summary's content changed, a picture
arrived, or about 15 minutes passed (`WidgetSync.shouldReload`). A tapped task opens
`hq://task/<id>`, which `HQApp`'s `onOpenURL` hands to `AppStore.open(_:)`.

## Tests

- `Tests/WidgetSummaryTests.swift`, `Tests/WidgetSyncReloadTests.swift`: the wire, links, names,
  and the reload rule. They run in the `HQ` scheme.
- `Tests/LiveWidgetTests.swift`: the real `WidgetAPI` and `HQClient` against a real server
  (`HQ_LIVE_SERVER`, `HQ_LIVE_KEY_A`, `HQ_LIVE_KEY_B`, as `LiveServerTests`).

The widgets themselves, the App Group and the WidgetKit reloads need a team-signed build on a
Mac and are not covered by these.
