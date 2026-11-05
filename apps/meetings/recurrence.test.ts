import { describe, expect, test } from 'bun:test';
import { describe as words, nextStart, validTimezone, type Rule } from './recurrence';

const at = (iso: string) => Date.parse(iso);
const iso = (ms: number | null) => (ms === null ? null : new Date(ms).toISOString());
const rule = (freq: Rule['freq'], timezone = 'UTC', weekdays: number[] = []): Rule => ({ freq, timezone, weekdays });

describe('recurrence', () => {
	test('daily gives the next day, and never the anchor itself', () => {
		const anchor = at('2026-11-02T10:00:00Z');
		expect(iso(nextStart(rule('daily'), anchor, anchor))).toBe('2026-11-03T10:00:00.000Z');
		expect(iso(nextStart(rule('daily'), anchor, 0))).toBe('2026-11-03T10:00:00.000Z');
		expect(iso(nextStart(rule('daily'), anchor, at('2026-11-12T11:00:00Z')))).toBe('2026-11-13T10:00:00.000Z');
	});

	test('weekdays skips the weekend', () => {
		const friday = at('2026-11-06T10:00:00Z');
		expect(iso(nextStart(rule('weekdays'), friday, friday))).toBe('2026-11-09T10:00:00.000Z');
	});

	test('weekly repeats on the anchor’s weekday, or on the days it names', () => {
		const monday = at('2026-11-02T10:00:00Z');
		expect(iso(nextStart(rule('weekly'), monday, monday))).toBe('2026-11-09T10:00:00.000Z');
		const named = rule('weekly', 'UTC', [1, 3]);
		expect(iso(nextStart(named, monday, monday))).toBe('2026-11-04T10:00:00.000Z');
		expect(iso(nextStart(named, monday, at('2026-11-04T10:00:00Z')))).toBe('2026-11-09T10:00:00.000Z');
	});

	test('biweekly skips every other week', () => {
		const monday = at('2026-11-02T10:00:00Z');
		expect(iso(nextStart(rule('biweekly'), monday, monday))).toBe('2026-11-16T10:00:00.000Z');
		const named = rule('biweekly', 'UTC', [1, 3]);
		expect(iso(nextStart(named, monday, at('2026-11-04T10:00:00Z')))).toBe('2026-11-16T10:00:00.000Z');
		expect(iso(nextStart(named, monday, at('2026-11-16T10:00:00Z')))).toBe('2026-11-18T10:00:00.000Z');
	});

	test('monthly keeps the day, and takes the last day of a shorter month', () => {
		const end = at('2026-01-31T10:00:00Z');
		expect(iso(nextStart(rule('monthly'), end, end))).toBe('2026-02-28T10:00:00.000Z');
		expect(iso(nextStart(rule('monthly'), end, at('2026-02-28T10:00:00Z')))).toBe('2026-03-31T10:00:00.000Z');
		expect(iso(nextStart(rule('monthly'), end, at('2026-12-31T10:00:00Z')))).toBe('2027-01-31T10:00:00.000Z');
	});

	test('keeps the wall clock across a clock change', () => {
		const newYork = rule('daily', 'America/New_York');
		// 10:00 on the day before the clocks go forward, then 10:00 the day after: an hour earlier in UTC.
		const before = at('2027-03-13T15:00:00Z');
		expect(iso(nextStart(newYork, before, before))).toBe('2027-03-14T14:00:00.000Z');
		const after = at('2027-11-06T14:00:00Z');
		expect(iso(nextStart(newYork, after, after))).toBe('2027-11-07T15:00:00.000Z');
	});

	test('says the rule the way the app shows it', () => {
		const monday = at('2026-11-02T15:00:00Z');
		expect(words(rule('daily', 'America/New_York'), monday)).toBe('Daily at 10:00');
		expect(words(rule('weekdays'), monday)).toBe('Weekdays at 15:00');
		expect(words(rule('weekly'), monday)).toBe('Weekly on Mon at 15:00');
		expect(words(rule('weekly', 'UTC', [1, 3]), monday)).toBe('Weekly on Mon, Wed at 15:00');
		expect(words(rule('biweekly'), monday)).toBe('Every 2 weeks on Mon at 15:00');
		expect(words(rule('monthly', 'Asia/Tokyo'), monday)).toBe('Monthly on day 3 at 00:00');
	});

	test('knows a real time zone from a made-up one', () => {
		expect(validTimezone('Europe/London')).toBe(true);
		expect(validTimezone('UTC')).toBe(true);
		expect(validTimezone('Mars/Olympus')).toBe(false);
		expect(validTimezone('')).toBe(false);
	});
});
