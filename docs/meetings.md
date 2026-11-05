# Meetings

`apps/meetings` schedules calls, reminds the room before they start, and turns
a recording or transcript into a recap with decisions and action items.

## Scheduling

Ask the assistant ("@atlas set up a launch sync with @bo tomorrow at 3pm ET"), or
use the HTTP API (`POST /apps/meetings/api/meetings`). A meeting has a title, a start and end time,
attendees (people in HQ, by handle), an optional agenda, and a room.

The room is where reminders and the recap go:

- scheduled from a room, it uses that room;
- scheduled from a DM or the API, it opens a new room named after the
  meeting;
- `room_id` picks one explicitly.

The organizer and attendees are added to the room.

Assistant tools:

|                    |                                                                                                                                            |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `schedule_meeting` | title, `starts_at` (ISO 8601 with an offset), `duration_minutes` (default 30), `attendee_handles`, `agenda`, `room_id`, `organizer_handle` |
| `list_meetings`    | `upcoming`, `past` or `all`, optionally for one person                                                                                     |
| `update_meeting`   | rename, reschedule, add attendees, cancel or restore                                                                                       |
| `recap_meeting`    | recap from a transcript or notes pasted in chat                                                                                            |

Only the organizer, an attendee or an admin can change or recap a meeting. The
assistant can do it for them, from a room it can see, when one of them asks.

## Reminders

The `meetings/reminders` automation runs every five minutes. It posts to the
room once for each meeting starting within 15 minutes:

> Starting in 10 min (15:00 UTC): **Launch sync** with @ada, @bo.

Rescheduling re-arms the reminder. Cancelled meetings are skipped.

## Recaps

Send a meeting's transcript or notes, or upload a recording (see the requests
below). A recording goes to the speech-to-text capability first,
so it needs `HQ_STT_MODEL` (see [AI services](ai.md)). Pasting works with
chat alone. Recordings over `HQ_STT_MAX_MB` (default 25) get a 413.

The model is asked for a short summary, the decisions, and the action items
with owners and due dates. HQ then:

1. files each action item with `add_task` if the Tasks app is installed,
   linked to the meeting room, with an owner when the model named a real
   handle;
2. posts the recap to the meeting room as the assistant;
3. saves the transcript, the recap and the task ids on the meeting.

Running a recap again replaces it without filing the same tasks twice.

The same steps are available over HTTP (member key):

```sh
curl -XPOST -H "authorization: Bearer $KEY" -H 'content-type: application/json' \
	-d '{"transcript": "Ada: we ship March 6..."}' \
	$HQ/apps/meetings/api/meetings/$ID/transcript

curl -XPOST -H "authorization: Bearer $KEY" -F file=@standup.m4a \
	$HQ/apps/meetings/api/meetings/$ID/recording
```

## Calendar feed

Each person gets a private iCalendar link for the meetings they organize or
attend. Ask for yours with `POST /apps/meetings/api/feed`, then paste
the URL it returns into Google Calendar, Apple Calendar or Outlook as a subscription.

The link carries a calendar-only token, not your API key, so it can only read
your meetings. Getting a new link turns off the old one, and the link stops
working for good once all of that person's keys are revoked, even if they get
a new key later (they get a new link instead). Events link back to the
meeting room, and recaps appear in the event description once they exist.

Signed-in clients can also read `GET /apps/meetings/api/calendar/<handle>.ics`
with a bearer key. It only includes meetings in rooms the caller is in.

## Calls

A meeting has a call: in the app, joining it opens the call in the meeting's
room and adds you to the room if you can see the meeting but are not in it
yet. A cancelled meeting opens no call, and meetings never ring. Starting a
call with no meeting makes a Quick Call: a meeting titled "Quick call", made
now, with a room of its own to invite people to. Calls need the host's relay
set up; see [calls.md](calls.md).
