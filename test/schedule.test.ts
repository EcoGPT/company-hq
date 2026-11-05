import { describe, expect, test } from 'bun:test';
import { nextRun, parseSchedule } from '../src/automations/schedule';

const at = (iso: string) => new Date(iso);

describe('parseSchedule', () => {
	test('manual and @every', () => {
		expect(parseSchedule('manual')).toEqual({ kind: 'manual' });
		expect(parseSchedule('@every 15m')).toEqual({ kind: 'every', ms: 900_000 });
		expect(() => parseSchedule('@every 1s')).toThrow('10s');
	});

	test('rejects nonsense', () => {
		expect(() => parseSchedule('* * *')).toThrow('5 cron fields');
		expect(() => parseSchedule('61 * * * *')).toThrow('minute');
		expect(() => parseSchedule('*/0 * * * *')).toThrow('step');
		expect(() => parseSchedule('1,,2 * * * *')).toThrow('empty entry');
		expect(() => parseSchedule('0 9- * * *')).toThrow('hour');
	});
});

describe('nextRun (UTC)', () => {
	test('daily at 09:30', () => {
		const s = parseSchedule('30 9 * * *');
		expect(nextRun(s, at('2026-03-01T08:00:00Z'))?.toISOString()).toBe('2026-03-01T09:30:00.000Z');
		expect(nextRun(s, at('2026-03-01T09:30:00Z'))?.toISOString()).toBe('2026-03-02T09:30:00.000Z');
	});

	test('steps, ranges, lists and aliases', () => {
		expect(nextRun(parseSchedule('*/15 * * * *'), at('2026-03-01T10:01:00Z'))?.toISOString()).toBe('2026-03-01T10:15:00.000Z');
		expect(nextRun(parseSchedule('0 9 * * 1-5'), at('2026-03-07T10:00:00Z'))?.toISOString()).toBe('2026-03-09T09:00:00.000Z');
		expect(nextRun(parseSchedule('0 8,17 * * *'), at('2026-03-01T09:00:00Z'))?.toISOString()).toBe('2026-03-01T17:00:00.000Z');
		expect(nextRun(parseSchedule('@weekly'), at('2026-03-04T00:00:00Z'))?.toISOString()).toBe('2026-03-08T00:00:00.000Z');
		expect(nextRun(parseSchedule('0 0 * * 7'), at('2026-03-04T00:00:00Z'))?.toISOString()).toBe('2026-03-08T00:00:00.000Z');
	});

	test('day-of-month OR day-of-week when both are set', () => {
		const s = parseSchedule('0 12 1 * 5');
		expect(nextRun(s, at('2026-03-02T00:00:00Z'))?.toISOString()).toBe('2026-03-06T12:00:00.000Z');
	});

	test('@every runs now, then every interval after the last run', () => {
		const s = parseSchedule('@every 1h');
		expect(nextRun(s, at('2026-03-01T00:00:00Z'))?.toISOString()).toBe('2026-03-01T00:00:00.000Z');
		expect(nextRun(s, at('2026-03-01T00:10:00Z'), at('2026-03-01T00:00:00Z'))?.toISOString()).toBe('2026-03-01T01:00:00.000Z');
	});

	test('manual never runs; impossible dates give null', () => {
		expect(nextRun(parseSchedule('manual'), new Date())).toBeNull();
		expect(nextRun(parseSchedule('0 0 31 2 *'), at('2026-01-01T00:00:00Z'))).toBeNull();
	});

	test('a leap-day schedule finds the next leap year', () => {
		expect(nextRun(parseSchedule('30 9 29 2 *'), at('2026-10-23T00:00:00Z'))).toEqual(at('2028-02-29T09:30:00Z'));
		expect(nextRun(parseSchedule('0 0 29 2 *'), at('2097-01-01T00:00:00Z'))).toEqual(at('2104-02-29T00:00:00Z'));
	});
});
