# Library and scheduled meetings

What the native app's Files and Meetings screens call, and who sees what. The
JSON is what the app decodes; the keys are checked against
`test/fixtures/swift-wire.library.json`.

## Routes

All under `/v1`, signed in with any key of a person. Times are ISO 8601.

| Route                           | Body                                                       | Answer                                              |
| ------------------------------- | ---------------------------------------------------------- | --------------------------------------------------- |
| `GET /v1/library`               |                                                            | `{folders: []}`                                     |
| `GET /v1/files`                 |                                                            | `{files: [file]}`, newest first, at most 500        |
| `GET /v1/documents`             |                                                            | `{documents: [summary]}`, newest first, at most 500 |
| `GET /v1/documents/:slug`       |                                                            | `{document}`                                        |
| `POST /v1/meetings`             | `{title, scheduled_at?, invitee_person_ids?, recurrence?}` | `{meeting}` (201)                                   |
| `PUT /v1/meetings/:id/invitees` | `{person_ids}`                                             | `{meeting}`                                         |
| `DELETE /v1/meetings/:id`       |                                                            | `{ok: true}`                                        |
| `DELETE /v1/meeting-series/:id` |                                                            | `{ok: true}`                                        |
| `GET /v1/calls`                 |                                                            | `{calls: [], meetings: [meeting], ringing: []}`     |

`calls` and `ringing` stay empty: there is no live call on this server yet.

### Files

A file is listed for you if it was sent in a conversation you are in now. That is
the rule for downloading one (`GET /v1/attachments/:id`), so the list never shows
a file you could not open: a room you are not in, a room that is archived, a
message that was unsent and an upload no message holds yet are all left out.
Open a file with its `id` at `/v1/attachments/:id`.

There are no folders. `GET /v1/library` answers an empty list, and `folder_id` is
always `null`. The Files screen then shows one flat list.

### Documents

These are the docs of the [docs app](apps.md). Every signed-in member reads all of
them, exactly as through `/apps/docs/api/docs` and `/docs/:slug`, which still
work. `content` is the doc's Markdown. A doc has no folder either.

### Meetings

`scheduled_at` is the start; a meeting is 30 minutes long. Leave it out and the
meeting starts now. A start that has already ended, or is over ten years ahead, is
refused. `invitee_person_ids` and `person_ids` are people on this server who
sign in: a made-up id, the assistant or someone who was removed is a
`person_not_found` (404). At most 100 are named, a body is at most 64 KB, and one
person keeps at most 100 meetings ahead and 20 repeating ones.

A new meeting gets a room of its own named after it, with the organizer and the
invitees in it. That is the meeting's thread (`conversation_id`). Setting the
invitees replaces the whole list: the organizer always stays, someone new joins the
room, and someone left out leaves it. A meeting the assistant scheduled into a
shared room leaves that room alone: the invitees are recorded on the meeting, and
are added to that room only if the person changing the list is in it now, as in
chat.

`recurrence` is `{freq, timezone, weekdays}` with `freq` one of `daily`,
`weekdays`, `weekly`, `biweekly` and `monthly`, and `weekdays` (0 is Sunday) only
for the weekly ones, defaulting to the first meeting's weekday. The meeting keeps
its wall-clock time in that time zone through clock changes; a monthly one on the
31st takes the last day of a shorter month. The answer's `recurrence` is
the rule in words ("Weekly on Mon at 10:00") and `series_id` ties the occurrences
together.

A repeating meeting keeps one occurrence ahead. Cancelling it with
`DELETE /v1/meetings/:id` skips that one and the next takes its place, with the
same room and invitees. The reminder automation (every five minutes) puts the next
one up when the last has passed. `DELETE /v1/meeting-series/:id` stops it for good
and cancels what is ahead; occurrences that already happened stay. One invite list
is for all of a series. A series also ends by itself, with what is ahead cancelled,
once its room is archived or its organizer is removed, and a meeting in an archived
room gets no reminder.

### Who may do what

- **See a meeting:** the person who runs it, anyone invited, anyone who can open
  its room now. A meeting in an archived room is closed to everyone. Anything else
  is a `meeting_not_found` (404), the same as a meeting that does not exist.
- **Cancel it, change its invitees, or end its series:** the organizer, or an
  admin on a signed-in device (not an admin's script key) who can see it. Anyone
  else who can see it gets `forbidden` (403).
  The assistant's own tools, and `/apps/meetings/api`, keep their rule: the
  organizer, an attendee or an admin may change a meeting.

### The `meetings` frame

When a meeting is made, cancelled, re-invited or ended, each person it affects gets
`{type: "meetings", meetings: [...]}` on their socket: their own whole list again,
built for them. Nobody else gets one.
