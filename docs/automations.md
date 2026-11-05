# Automations

An automation is a named job an app ships as code. It runs on a schedule or
on demand, and every run leaves a record people can read.

```sh
bun hq new automation nudge --app standup
```

```ts
import { defineAutomation } from '@hq/sdk';

export default defineAutomation({
  slug: 'nudge',
  name: 'Standup nudge',
  description: 'Reminds anyone who has not posted a standup by 15:00 UTC.',
  schedule: '0 15 * * 1-5',
  async run({ hub, assistant, log, trigger, signal }) {
    log('checking who posted');
    // ...
    return 'nudged 2 people';
  },
});
```

Add it to the app's `automations: [...]`. The scaffolder does this for you.

## Schedules

All times are UTC.

|                                         |                                                                   |
| --------------------------------------- | ----------------------------------------------------------------- |
| `30 9 * * 1-5`                          | 5-field cron: minute, hour, day of month, month, day of week      |
| `*/15 * * * *`                          | steps, ranges (`1-5`) and lists (`8,17`) work in any field        |
| `@hourly` `@daily` `@weekly` `@monthly` | the usual aliases                                                 |
| `@weekdays`                             | 09:00 Monday to Friday                                            |
| `@every 15m`                            | an interval (`s`, `m`, `h`, `d`; at least 10s), first run at boot |
| `manual`                                | only runs when someone starts it                                  |

When both day of month and day of week are something other than `*`, either
one matching is enough, as in classic cron. An invalid schedule throws when the app loads, not at 3am.

## Runs

The scheduler checks every 15 seconds.

- A due job runs once. If HQ was down when it was due, it catches up once on
  boot.
- A job already running is never started a second time.
- The return value (if a string) is saved as the run's `output`. `log(line)`
  lines are saved with timestamps. A thrown error marks the run `failed` with
  its message.
- Runs that were in flight when the server stopped are marked `failed` with
  the error `interrupted by restart` when it starts again. `bun hq` commands
  don't run the scheduler and leave run history alone.
- Run output and logs often name rooms, meetings and tasks from across HQ, so
  run history is admin-only. Members see each automation's schedule and the
  status of its last run.
- Each automation keeps its newest 200 runs (and always its last scheduled one,
  which the schedule counts from). Older rows are deleted as new runs finish.

```sh
curl -H "authorization: Bearer $KEY" localhost:8787/v1/automations
curl -H "authorization: Bearer $KEY" localhost:8787/v1/automations/standup/nudge/runs     # admins
curl -XPOST -H "authorization: Bearer $KEY" localhost:8787/v1/automations/standup/nudge/run   # admins
```

## Patterns

**Draft, don't send.** For anything that reaches outside the team (email,
social posts, customers), have the automation write drafts into a table and
let a person approve them through the app's API.

**Ask the model, post the result.** Call `assistant.ask(prompt)` for the text
and `assistant.post(conversationId, text)` to put it in a room. `run` gets the same `AppContext` an app's `setup` does
([apps](apps.md#talking-to-the-team)), plus `log`, `trigger` and `signal`.

**Testing.** `hq.scheduler.run(app, slug)` runs one now and returns the run
record. For timing, pass a fake `clock` to `createHq` and call
`hq.scheduler.tick()` (see `test/automations.test.ts`).
