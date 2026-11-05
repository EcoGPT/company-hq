# The assistant

HQ has one assistant. It is a `people` row with `kind = 'assistant'`, a member
of every room, and it acts with the same tools as everyone else.

## Files

- `assistant/persona.md`: who it is and how it talks. Plain Markdown, loaded
  as the first part of the system prompt.
- `assistant/assistant.ts` sets its name, handle and when it replies. These
  are all the fields, with their defaults:

```ts
defineAssistant({
  name: 'Atlas', // display name; renaming updates the existing row
  handle: 'atlas', // what people @mention
  persona,
  model: undefined, // overrides HQ_LLM_MODEL for this assistant
  replyIn: 'mentions', // or 'everything' to answer every human message
  maxHops: 24, // tool-call rounds per turn
  historyLimit: 40, // messages of context
  temperature: undefined,
  timezone: undefined, // IANA zone for times it tells people and dates tools resolve; defaults to HQ_TIMEZONE, then this machine's
  surfaces: {
    general: 'This is the whole-team room. Keep replies extra short.',
  },
});
```

`surfaces` maps a room key to extra instructions for that room. Rooms made with
`hub.conversations.ensureRoom(key, title)` have keys; `general` always exists.

## When it replies

- Someone writes `@atlas` at the start of a message or after a space or
  punctuation (so `me@atlas.com` doesn't count).
- A human writes in its DM.
- Any human message, if `replyIn: 'everything'`.

Only people start turns. Messages from the assistant itself, other bots and
service accounts (CI, scripts) never do, even when they tag it, because
anyone who can reach those integrations could otherwise make the assistant act
with the room's access. It is not a member of DMs between other people, so it
never sees them.

## A turn

1. The system prompt is assembled from the persona, where it is (room or DM,
   who is in it, the current time), the room's surface, each app's
   `briefing`, and everything it has saved with `remember`.
2. The last `historyLimit` messages are replayed. Its own messages become
   `assistant` turns and everyone else's become `user` turns as `Name (@handle): text`.
   Handles are unique, so a display name can't impersonate someone.
3. The model is called with every tool it can reach. Tool calls run, results
   (including validation errors) go back, and this repeats.
4. The final text is posted to the room. An empty reply means it stays silent.

If it reaches `maxHops`, it gets one last call without tools and is told to
answer with what it has. While a turn runs, the room sees what it's doing
("checking the task list…"), taken from each tool's `activity`.

There is one live turn per conversation. Messages that arrive mid-turn queue
one follow-up turn that sees all of them. A failed turn posts the error into
the room.

## Memory

The assistant has `remember(fact)` and `forget(id)`, and the newest 100 facts
are in its prompt. A fact remembers the conversation it was saved in and only
shows up where everyone present is in that conversation too, so something
said in a DM stays in that DM. Both tools are assistant-only and hidden from
MCP. Memory is for short facts the assistant needs; anything a person would
want to read belongs in Docs.

## Tuning loop

```sh
$EDITOR assistant/persona.md
bun hq chat           # your DM with it
bun hq chat --room    # a scratch room, auto-tagged, to test room behavior
```

Tool activity prints inline, so you can see which tools a prompt reaches for.
Most behavior problems are fixed faster in a tool's `description` or an app's
`briefing` than in the persona.
