# Push: what the app sends and reads

For a server that wants to push to the Mac and iPhone apps. Paths are under
`clients/apple/`. Push exists only in a build signed with a team
(`HQ_SIGNING_MODE=team`, README "Push notifications"). Any other build never
registers, never calls the routes below and never receives a push.

## What the app sends the server

The app reports its push standing on the device bearer. Both calls are best
effort: the app ignores any error, so a server without push can answer 404.

| Call                            | Body                                               | Where                          |
| ------------------------------- | -------------------------------------------------- | ------------------------------ |
| `POST /v1/devices/apns-token`   | `{"environment", "status", "token", "voip_token"}` | `HQClient.reportPush`          |
| `DELETE /v1/devices/apns-token` | none                                               | `HQClient.unregisterPushToken` |

- `token`: the APNs device token, lower-case hex (both `AppDelegate`s). Omitted
  when Apple issued none.
- `environment`: `development` in a Debug build, `production` otherwise
  (`AppStore.apnsEnvironment`). Sent only with a token or a VoIP token, and it
  applies to both. Send to
  `api.sandbox.push.apple.com` for `development`, `api.push.apple.com` for
  `production`. A Release build signed with a development profile reports
  `production` and its tokens are refused.
- `status`: one short string, the first failing rung of `PushState.wire`:
  `error: <reason, 100 characters>`, then the permission (`not_determined`,
  `denied`; `provisional` counts as granted), `alerts_off`, `no_token`, and
  `authorized`.
- `voip_token`: the iPhone's PushKit token, lower-case hex, in a build signed
  with a team (`CallKitCoordinator.startPushKit`, at every launch). Omitted on
  the Mac, in any other build, and until iOS issues one. It is sent whether or
  not notifications are allowed: CallKit rings without that permission.
- The report is sent whenever the state changes and once after sign-in
  (`AppStore.reportPush`). Reports go one at a time, in order. `DELETE` is sent
  at sign-out after the last report (`AppStore.signOut`). The server answers
  `{"ok": true}`.
- The app never asks for a push to be sent; it only registers.

## What the server must enforce

A push shows message text on a lock screen, so these rules are the server's,
not the app's:

- **A token belongs to one device.** A `POST` with a token already stored on
  another device row moves it there. Otherwise a phone that changed hands
  (person A signed out offline, person B signed in) shows A's messages to B.
- **The `DELETE` may never arrive.** A device signed out offline never sends
  it, and the app does not retry. Revoking a device, or removing a person,
  must stop its pushes on its own.
- **Push only what the socket would send.** A device gets a push for a
  conversation only when its person can see that conversation, and an archived
  room sends none.

## What the app reads from a push

Send an `alert` push to the topic `<bundle id>` (the app's bundle id, which is
`$(BUNDLE_ID_PREFIX).hq` for both apps).

### New message (an alert push)

```json
{
  "aps": {
    "alert": { "title": "Ada", "body": "Lunch at noon?" },
    "sound": "default",
    "thread-id": "<conversation id>"
  },
  "conversation_id": "<conversation id>",
  "message_id": "<message id>"
}
```

| Key                                              | Read by                                                                      | What it does                                                                                                                                                                                                                                                                                                 |
| ------------------------------------------------ | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `conversation_id` (top level)                    | `NotificationManager.presentation(for:)`, `didReceive`                       | Which conversation a tap opens; the read-cursor check; the thread being read on screen.                                                                                                                                                                                                                      |
| `message_id` (top level)                         | `presentation(for:)`, `noteRemoteDelivery`, `messageNotificationIdentifiers` | Dedupe against the socket copy; the read-cursor check; clearing banners once read. Message ids compare as strings (`messageId <= readThrough`), so they must sort in send order.                                                                                                                             |
| `aps.alert.title`, `aps.alert.body`, `aps.sound` | the system                                                                   | The banner. The app reads none of them.                                                                                                                                                                                                                                                                      |
| `aps.thread-id`                                  | the system                                                                   | Must equal `conversation_id`: the app's own local banner uses the same value as its `threadIdentifier`, so the two copies stack together.                                                                                                                                                                    |
| `aps.content-available`                          | the system                                                                   | Optional. With `1` on an alert push an iPhone also runs `didReceiveRemoteNotification` (`Sources/iOS/AppDelegate.swift`), which claims `message_id` when backgrounded and then refreshes the conversation list, people and calls (`AppStore.handleRemotePush`). Without it, the phone refreshes when opened. |
| `apns-collapse-id` (header)                      | the system                                                                   | Optional: the message id keeps a re-sent push from stacking.                                                                                                                                                                                                                                                 |

Do not put `call_id` in a message push: a payload with `call_id` is treated as
a ring.

### Ring, VoIP (iPhone, a team build)

Headers: `apns-push-type: voip`, topic `<bundle id>.voip`, `apns-priority: 10`,
`apns-expiration` at the ring's end.

```json
{
  "call_id": "<call id, a lower-case UUID>",
  "caller_name": "Ada",
  "conversation_id": "<conversation id>",
  "conversation_title": "Launch",
  "expires_at": "2030-01-02T03:04:05.678Z"
}
```

`conversation_title` is `null` for a direct message. `CallKitCoordinator`'s
PushKit delegate reads it into a `VoIPRing` (`Sources/Shared/Notifications.swift`)
and reports a CallKit call at once, because iOS stops an app that takes a VoIP
push without reporting one. A push that cannot be read (no UUID `call_id`, no
`conversation_id`), or whose `expires_at` has passed, is reported and ended in
the same moment. A ring the socket already reported is reported again, and
CallKit's "already exists" answer is ignored. Answer joins the room; End declines.

### Ring, alert (a Mac, or an iPhone with no VoIP token)

Headers: `apns-push-type: alert`, topic `<bundle id>`, `apns-priority: 10`,
`apns-collapse-id: ring:<call id>`, `apns-expiration` at the ring's end.

```json
{
  "aps": {
    "alert": { "title": "Incoming call", "body": "Ada is calling in Launch" },
    "sound": "default",
    "content-available": 1
  },
  "call_id": "<call id>",
  "conversation_id": "<conversation id>"
}
```

A payload with `call_id` is a ring (`presentation(for:)`): no banner while the
ring already shows. With `content-available` an iPhone refreshes, finds the
call in `GET /v1/calls` `ringing` and reports it to CallKit.

### Read sync (a silent background push)

Sent to a person's other devices when a conversation was read. It clears
banners already delivered and recounts the badge.

```json
{
  "aps": { "content-available": 1 },
  "conversation_id": "<conversation id>",
  "read_through_message_id": "<newest message id read>"
}
```

Headers: `apns-push-type: background`, `apns-priority: 5`, topic `<bundle id>`.

- iPhone: `noteRemoteDelivery` moves the read cursor and removes delivered
  banners for that conversation up to `read_through_message_id`; the store then
  reads only `GET /v1/conversations` (`AppStore.refreshBadgeOnly`) and sets the
  badge from the unread counts.
- Mac: `Sources/macOS/AppDelegate.swift` clears the banners only; the Dock badge
  is recounted the next time the conversation list is read.

## How a push is deduped against the socket

Every connected device gets a message twice, once on the socket and once by
push. The server need not guess which is working: the app drops the second one
by `message_id`.

1. `NotificationManager.didClaim(messageId)` records the first arrival of a
   message id (the last 400 are kept) and answers `false` for any later one.
2. The socket path calls `post(...)`, which claims the id. If the push was
   already claimed, no local banner is posted.
3. A push shown while the app is running goes through `willPresent` ->
   `presentation(for:)`. A remote copy (no `is_local` key) claims the id; if
   the socket's local banner got there first it returns no presentation, so
   nothing shows twice.
4. A push for a backgrounded iPhone is shown by the system without
   `willPresent`. With `content-available: 1` the app claims it in
   `noteRemoteDelivery`. Without it, the app checks the delivered list before
   posting a local copy, and a backgrounded iPhone that holds a token posts no
   local message banner at all (`leavesBannerToPush`). Meeting reminders never
   come by push, so they always post.
5. A message at or before the conversation's read cursor never shows
   (`isMessageRead`), and the thread open on screen shows no banner
   (`shouldSuppressBanner`, `AppStore.isReadingThread`).

The local banner's identifier is the message id, so a second banner for the
same message replaces the first.

## The badge

The badge is computed by the app, never read from the push. Nothing in the
payload sets it, and the sample payloads above carry no `aps.badge`.

- The number is the sum of `unread_count` over the conversations the list shows
  (`AppStore.updateDockBadge`), so it is exactly the count the chat list shows.
  Zero clears it.
- iPhone: `UNUserNotificationCenter.setBadgeCount`; Mac: the Dock tile
  (`Platform`).
- It is recounted whenever the conversation list changes and on activation,
  including for a read-sync or `content-available` push on an iPhone. A
  new-message alert push without `content-available` does not run app code, so
  a closed iPhone's badge moves only when it next wakes. A server that wants a
  true badge with the app closed has to send `aps.badge` itself (the
  per-person unread total); the app overwrites it with its own count the next
  time it runs.
