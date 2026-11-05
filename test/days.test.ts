import { describe, expect, test } from 'bun:test';
import { resolveDay } from '../src/core/days';

const sunday = new Date('2026-10-18T04:42:00Z');

describe('resolveDay', () => {
	test('weekday words land on the next occurrence in the team zone', () => {
		expect(resolveDay('friday', 'America/New_York', sunday)).toBe('2026-10-23');
		expect(resolveDay('Next Friday', 'America/New_York', sunday)).toBe('2026-10-23');
		expect(resolveDay('sunday', 'America/New_York', sunday)).toBe('2026-10-25');
		expect(resolveDay('monday', 'UTC', new Date('2026-10-18T23:30:00Z'))).toBe('2026-10-19');
		expect(resolveDay('monday', 'Asia/Tokyo', new Date('2026-10-18T23:30:00Z'))).toBe('2026-10-26');
	});

	test('today, tomorrow, in N days, ISO, and nonsense', () => {
		expect(resolveDay('today', 'America/New_York', sunday)).toBe('2026-10-18');
		expect(resolveDay('tomorrow', 'UTC', sunday)).toBe('2026-10-19');
		expect(resolveDay('in 3 days', 'UTC', sunday)).toBe('2026-10-21');
		expect(resolveDay('2026-12-31', 'UTC', sunday)).toBe('2026-12-31');
		expect(resolveDay('2026-02-31', 'UTC', sunday)).toBeNull();
		expect(resolveDay('someday', 'UTC', sunday)).toBeNull();
	});
});
