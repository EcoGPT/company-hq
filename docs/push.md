# Push notifications

HQ can wake a closed Mac or a phone in a pocket with a notification when a
message arrives, and ring them when someone calls. It does this through Apple's
push service (APNs), using **your own** Apple key. There is no shared relay:
nothing is sent to anyone but Apple, and nothing is sent at all until you
configure it.

Without any of the settings below HQ behaves exactly as before. The two device
routes still answer (so a signed app does not log errors) and store the token
the app reports, and nothing else happens.

## What you need

- An Apple Developer Program team (a free account cannot use push).
- The Mac and iPhone apps built and signed with your team, in `team` mode, with
  a bundle id prefix that is yours. The steps are in
  [`clients/apple/README.md`](../clients/apple/README.md), "Push notifications".
  A build signed any other way never asks Apple for a token and never receives a
  push.
- An **APNs authentication key** (a `.p8` file) from your Apple account. Make one
  under Certificates, Identifiers & Profiles, then Keys, with "Apple Push
  Notifications service (APNs)" ticked. Apple shows you the **key id** and lets
  you download the file once. Your **team id** is on the Membership page.

## Turn it on

Set all four. If any is missing push stays off.

| Variable           | Meaning                                                                                          |
| ------------------ | ------------------------------------------------------------------------------------------------ |
| `HQ_APNS_KEY_FILE` | path to the `.p8` file                                                                           |
| `HQ_APNS_KEY_ID`   | the key's 10-character id                                                                        |
| `HQ_APNS_TEAM_ID`  | your 10-character team id                                                                        |
| `HQ_APNS_TOPIC`    | the app's bundle id: your `BUNDLE_ID_PREFIX` and `.hq`, for example `com.you.hq`                 |
| `HQ_PUSH_PREVIEW`  | optional: `full` (default) or `hidden`; see "What is sent". Anything else is treated as `hidden` |

Keep the key file out of the data folder (which you back up and may share) and
out of git. Under Docker, mount it read-only:

```sh
docker run -v /srv/hq/data:/data \
  -v /srv/hq/AuthKey_ABC1234567.p8:/run/secrets/apns.p8:ro \
  -e HQ_APNS_KEY_FILE=/run/secrets/apns.p8 \
  -e HQ_APNS_KEY_ID=ABC1234567 -e HQ_APNS_TEAM_ID=TEAM123456 \
  -e HQ_APNS_TOPIC=com.you.hq ...
```

At start HQ prints one line: `[push] on: APNs, key id ABC1234567, full previews`,
or, when some values are set and some are not, `[push] off: ...` naming what is
missing. With none set it prints nothing. It never prints the key, the path or a
full device token.

Development builds of the app report `development` tokens and are sent to
Apple's sandbox host; every other build reports `production`. HQ sends each
token to the host that matches. A release build signed with a development
profile reports `production` and Apple refuses its tokens.

## Who is notified

A new message goes to every device that has reported a token and belongs to one
of the other people in that conversation. Never to:

- the person who wrote it, on any of their devices
- the assistant or any service
- someone who was removed, or a device whose key was revoked
- anyone in an archived room, or who left the room
- a system row (a message whose metadata names a `kind`)

A device that is online over the socket is notified too. The app drops the second
copy by message id, so nothing shows twice.

When someone reads a conversation, their own devices get a silent push so the
banners they already have are cleared and the badge is recounted. That push
carries only the conversation id and the id of the newest message read.

A push can wait in the queue, so each one is checked again just before it is
sent: the device must still hold that exact token and still be a live recipient
(its person not removed, its key not revoked, still in the room, the room not
archived, the message not unsent). Otherwise it is dropped.

A token belongs to one device. If a device reports a token another device holds
(a phone that changed hands), the token moves and the earlier device stops
receiving pushes. A device that signs out calls `DELETE /v1/devices/apns-token`;
if it never gets to, revoking the device or removing the person stops its pushes
anyway. Apple's `410 Unregistered` answer also clears the token. No other
failure does: a wrong key, topic or environment is logged (once a minute at
most) and the token is kept.

## Rings

When someone is rung for a call (the calls feature puts a `call.ringing` event
on the server's bus), each rung person's devices get a push, so a closed app
rings too. The caller is never rung, and the open socket rings any app that is
running as before; the app drops the second ring by call id.

- A team-signed iPhone reports a **VoIP token** beside its alert token, even
  when notifications are not allowed. It gets a VoIP push, which iOS hands to
  the app even when it is closed, and the app shows it as a call on the lock
  screen (CallKit).
- Any other device with an alert token (a Mac, or a phone without a VoIP token)
  gets an alert push titled "Incoming call", with the body `Ada is calling`, or
  `Ada is calling in Launch` in a named room. The app reads it as a ring: on
  an iPhone it wakes the app, which finds the ring in `GET /v1/calls`.
- A device with neither token is not pushed to.

Each ring push is checked again just before it is sent, as a message push is:
the person must still be in the room (not archived), not removed, on a device
whose key is live and that still holds that exact token. A ring is not sent
once it has run out or the call has ended, and Apple is told to drop it at the
ring's end too (`apns-expiration`). A ring someone declined has no server event
yet: their other devices learn of it from the app, which asks while it rings.
Rings go through the same queue as messages, so a slow Apple never slows a call.

| Push      | Headers                                                                                                       | Payload                                                                                          |
| --------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| VoIP push | `apns-push-type: voip`, topic `<HQ_APNS_TOPIC>.voip`, priority 10, `apns-expiration` = the ring's end         | `call_id`, `caller_name`, `conversation_id`, `conversation_title` (`null` in a DM), `expires_at` |
| Alert     | `apns-push-type: alert`, topic `<HQ_APNS_TOPIC>`, priority 10, `apns-collapse-id: ring:<call id>`, expiration | the banner, `aps.content-available: 1`, `call_id`, `conversation_id`                             |

The VoIP push uses the same key and settings as everything else; HQ adds
`.voip` to `HQ_APNS_TOPIC` itself. Apple's `410 Unregistered` answer clears the
token that was used and only that one, so a phone whose VoIP token is gone gets
the alert ring next time.

The app sends the build's environment (`development` or `production`) with
either token, and HQ keeps it with each. A phone that has not allowed
notifications has no alert token but still rings by VoIP push.

## What is sent

Everything below goes to Apple's servers, which then deliver it to the device.
It is not end-to-end encrypted by HQ.

| `HQ_PUSH_PREVIEW=full` (default)                                                                                              | `hidden`            |
| ----------------------------------------------------------------------------------------------------------------------------- | ------------------- |
| title: the room's name, or the sender in a direct message or an unnamed group                                                 | title: the sender   |
| body: `Sender: text` in a group, the text in a direct message; one line, at most 240 characters, "Sent an attachment" if none | body: `New message` |

Both also carry the device token, the conversation id and the message id, which
the app uses to open the right conversation and to skip duplicates. A read sync
carries the two ids and no text.

A ring carries the caller's name, the call and conversation ids, and with
`full` the room's title. `hidden` keeps the title back, as it does for messages:
the banner says `Ada is calling` and the VoIP push's `conversation_title` is
`null`. The exact payload keys are in
[`clients/apple/docs/push.md`](../clients/apple/docs/push.md).

Apple can see that a push happened, when, and for which device and app, whatever
the preview. If your team should not have message text pass through Apple at all,
set `hidden`, or leave push off.

## Limits to know

- Pushes are sent from a queue, a few at a time, after the message is saved. A
  slow or failing Apple never slows sending. If the queue ever holds more than
  1,000 pushes the newest are dropped (and one line says so).
- A push is tried once. If Apple is unreachable the person sees the message
  when they next open the app.
- The icon badge is counted by the app, not sent by the server. A closed
  iPhone's badge moves when it next wakes.
- Messages written from a separate process (`bun hq chat`) never reach the
  running server's bus, so they are not pushed, exactly as they do not reach
  open sockets.
- A ring is tried once, like any push. If it is lost, the person still sees the
  ring when they next open the app while the call is ringing.

## Checking a device

Each device's last report is in the database: `SELECT device_id, environment,
status, status_at, token IS NOT NULL AS has_token, voip_token IS NOT NULL AS
can_ring FROM push_tokens`. `status` is
what the app said about its own standing (`authorized`, `denied`, `alerts_off`,
`no_token`, or `error: <reason>`). Do not paste tokens into issues.
