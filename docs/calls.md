# Calls

The Mac and iPhone apps can call: a direct message or a group rings everyone
else in it, and a meeting has a call anyone invited can join. People can mute,
turn the camera on and off, share a Mac's screen, raise a hand and leave.

HQ does not carry the audio and video itself. Each device sends its tracks to a
media relay (a selective forwarding unit, SFU) and pulls the others' from it;
HQ is the part that decides who may be in which call and tells the relay so.
The relay is **your own** Cloudflare Realtime SFU app. Nothing is sent to
Cloudflare until you configure it, and with nothing configured calls are off
and the rest of HQ works as before.

## What you need

A Cloudflare account. In the Cloudflare dashboard, open **Realtime**, then
**Serverless SFU**, and create an app. Cloudflare shows the app's **App ID** and
**App Secret**; the secret is for HQ only and never goes to the apps. The steps
are in Cloudflare's own guide,
[Get started with the SFU](https://developers.cloudflare.com/realtime/sfu/get-started/),
and the API HQ calls is described in
[the SFU's HTTPS API](https://developers.cloudflare.com/realtime/sfu/https-api/).

## Turn it on

| Variable                    | Meaning                                                                                       |
| --------------------------- | --------------------------------------------------------------------------------------------- |
| `HQ_CALLS_SFU_APP_ID`       | the App ID                                                                                    |
| `HQ_CALLS_SFU_SECRET`       | the App Secret, or leave it out and set the next one                                          |
| `HQ_CALLS_SFU_SECRET_FILE`  | a file holding the App Secret (one of these two, not both)                                    |
| `HQ_CALLS_SFU_URL`          | the API's address; default `https://rtc.live.cloudflare.com/v1`. Tests point it at a fake one |
| `HQ_CALLS_MAX_PARTICIPANTS` | devices in one call at once; default 20, past it joining answers 409 `call_full`              |

With none of the `HQ_CALLS_SFU_*` values set calls are off and nothing is
logged. With some set and some missing, the server prints one line naming what
is missing (never a value) and calls stay off. When they are on it prints the
app id and the address, never the secret.

While calls are off the apps still load: `GET /v1/calls` lists the meetings,
and starting a call answers 503 `not_configured`, which the app shows as "HQ
needs its Realtime credentials".

## Cost

Cloudflare charges for what the relay sends out to devices. As of 2026-11 the
first 1,000 GB a month are free (shared with Cloudflare's TURN service), then
it is $0.05 per GB; what devices send in is free. See
[Cloudflare's pricing page](https://developers.cloudflare.com/realtime/sfu/pricing/).
As a rough guide, one person listening to audio for an hour pulls about 15 MB,
and an hour-long video call between ten people moves about 40 GB, so the free
tier covers roughly 25 such hours a month. `HQ_CALLS_MAX_PARTICIPANTS` caps the
largest call.

## What is sent where

| Where                               | What                                                                                                                                                                                  |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| HQ to Cloudflare's API              | the App Secret (as the bearer), each device's WebRTC offer and answer (SDP: codecs, its network addresses, no names), track names (`<device id>-mic`, `-cam`, `-screen`), session ids |
| Devices to the relay                | the call's audio, camera video and shared screen. WebRTC encrypts it on the way, but not end to end: the relay decrypts and forwards it to the other devices in the call              |
| Devices to Cloudflare's STUN server | each device asks `stun.cloudflare.com` for its own public address, as WebRTC does; the address is built into the app                                                                  |
| HQ's database                       | who was in which call and when, their mute, camera, screen and hand flags, track names, and who was rung                                                                              |
| HQ's files folder                   | each person's call audio, and the transcript and recap in the database ([below](#recordings-transcripts-and-recaps))                                                                  |

Names, messages and room titles never go to Cloudflare. Cloudflare can see that
devices talk to its relay, from which addresses, for how long and how much.

The app tells everyone before they join that calls are recorded and
transcribed. What that means on this server is the next section.

## Recordings, transcripts and recaps

Every call is recorded, one recording per person (per device, to be exact).
While a device is in a call, the app streams its microphone to HQ over its own
socket, as plain 16 kHz mono 16-bit audio. A muted app sends nothing, so a mute
is silence in the recording. Screen-share audio is not recorded.

What HQ keeps, and where:

| What                        | Where                                                                                                            |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| each person's audio         | raw pieces of up to 30 seconds in `files/calls/<call id>/<device id>/` beside the database, plus a row per piece |
| the transcript              | the database: one line per piece, with who spoke and when                                                        |
| the recap                   | a message in the call's room from the assistant, and the summary on the call                                     |
| sent to your speech-to-text | each piece as a WAV, after the call ends (`HQ_STT_*`, [ai.md](ai.md)); nothing while the call is going           |
| sent to your chat model     | the transcript with names and times, once per recap (`HQ_LLM_*`)                                                 |
| sent to Cloudflare          | none of this: the audio HQ records comes straight from the app                                                   |

After the call ends, each piece goes to the host's speech-to-text as a WAV of
its own, and its text becomes a line by that person, at the time the piece
started. A piece is at most 30 seconds (about 960 KB), so it stays under
`HQ_STT_MAX_MB`; if the provider says it is still too big, it is split to fit.
The lines make one version of the transcript, and the call shows it only if
every piece came back. If any failed, the call keeps the transcript it had,
the failure is kept with that version, and anyone in the room can press
**Retranscribe** to try again.

Then the recap. A meeting's call is recapped by the meetings app, as a
transcript shared with it would be: a recap in the meeting's room and its
action items filed as tasks ([meetings.md](meetings.md)). Any other call gets a
short summary from the chat model, posted in its room by the assistant. Each
call is posted about once: a later recap edits that message. The transcript is
what people said, so the model is told to treat it as quoted text, never as
instructions.

Without speech-to-text set up, recordings are still kept, the transcript stays
empty and Retranscribe answers `not_configured`. Without a chat model (the
server's "no model yet" stand-in), the transcript is written and there is no
summary; nothing is posted.

**Size and cost.** Audio is 32,000 bytes a second, so one person talking for an
hour is about 115 MB on disk. All call audio together is capped by
`HQ_CALLS_RECORDING_QUOTA_MB` (default 10,240 MB, about 93 person-hours; `0`
keeps none). Past it, no new audio is kept and the server logs that once.
Recordings are never deleted, like every file HQ keeps. One person's
recording of one call stops after 4 hours. Speech-to-text providers usually
charge by the minute of audio, so one person-hour is 60 billed minutes; at, for
example, $0.006 a minute that is $0.36 (check your provider's price). Each
retranscribe sends the whole call again, so it is limited to 3 an hour per call
and 10 an hour per person; the count is kept in the database, so a restart does
not reset it. A retranscribe that hears nothing at all keeps the transcript and
summary the call had, and a meeting's recap done again files no tasks twice.

**What a crash loses.** Up to the last 30 seconds of each person's audio is
held in memory until its piece is written: at a gap, when a feed closes and
when the call ends. A stop (SIGTERM or SIGINT, as `docker stop` and Ctrl-C send)
writes it before the process exits, waiting up to 5 seconds for the disk. A
crash, or a kill that gives no signal, loses that unwritten tail. A transcript
the server was writing when it stopped is marked failed when it starts again,
and Retranscribe redoes it from the saved audio.

**Downloads.** `GET /v1/calls/:id/recording/:deviceId` sends one person's whole
call as a WAV (16 kHz mono 16-bit, a 44-byte header), with silence for the gaps,
read from disk as it is sent. Anyone in the room can listen from the app, and so
can anyone who joins the room later, as with its messages. A download needs the
app's own sign-in (a device); a script or MCP key gets 403 `device_only`, though
it can read the transcript, as it can read the room's messages.

## How a call works

1. A device asks HQ to join (`POST /v1/calls`). HQ checks the person is in the
   room (or can see the meeting), gives the device a seat, and asks the relay
   for a session for it.
2. The device sends its offer to `publish`; HQ names the tracks, passes the
   offer to the relay and hands the answer back.
3. To hear and see the others, the device asks to `subscribe` to tracks in the
   call's roster. HQ passes on only tracks that are in this call now, because
   one relay app serves every call on the server. The relay answers with an
   offer, which the device answers through `renegotiate`.
4. Mute, camera, screen and hand changes go through `state`. A camera or screen
   that is switched off stays negotiated but out of the roster, so turning it
   back on needs no new offer.
5. Every change to who is in a call reaches everyone in the room as a
   `call_state` frame; the end, as `call_ended`.

A new call in a direct message or a group rings everyone else in it who is a
person (not the assistant) for 45 seconds: a `call_ring` frame to their open
apps, and the call listed under `ringing` in `GET /v1/calls`. Joining answers
it; declining stops it on all of that person's devices. Meetings never ring.
A closed app does not ring: there is no call push yet.

The apps send a heartbeat every 15 seconds. A device not heard from for 45
seconds is taken out of the call, and the call ends when its last device
leaves. A device that is signed out, a person who is removed and someone who
leaves the room lose their seats too. Seats are kept in the database, so a
restart sweeps the ones that went quiet while it was down.

The routes and frames are listed in [protocol.md](protocol.md#calls).

## Limits to know

- One device sits in one call at a time; joining another leaves the first.
- A person may start 10 calls in 10 minutes; joining a call that is already
  going does not count. One device may rejoin 20 times a minute.
- Starting a call in a meeting's room joins the meeting's call if one is going.
  A call started in a room made for a meeting rings no one.
- Call request bodies are capped at 64 KB. An audio frame is at most one
  second (32,000 bytes). Audio may arrive up to 10 seconds ahead of real time,
  so speech queued during a network stall is kept; audio sent faster than people
  speak beyond that is dropped. Kept audio is timed by when it arrives, so after a
  stall that person's lines can sort a few seconds late against the others'.
- The app connects to the relay directly over UDP and has no TURN server
  configured, so a network that blocks UDP cannot carry a call.
- The iPhone can watch a shared screen but cannot share its own.
