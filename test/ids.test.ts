import { describe, expect, spyOn, test } from 'bun:test';
import { newId } from '../src/core/ids';

const inOrder = (ids: string[]) => ids.every((id, i) => i === 0 || ids[i - 1]! < id);

describe('ids', () => {
	test('are uuidv7 with the time in front', () => {
		const before = Date.now();
		const id = newId();
		expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
		const stamped = Number.parseInt(id.replace('-', '').slice(0, 12), 16);
		expect(stamped).toBeGreaterThanOrEqual(before);
		expect(stamped).toBeLessThanOrEqual(Date.now());
	});

	test('sort as strings in the order they were made, many to one millisecond', () => {
		// The app finds the newest message by comparing ids as plain strings.
		const ids = Array.from({ length: 200_000 }, () => newId());
		expect(new Set(ids).size).toBe(ids.length);
		expect(inOrder(ids)).toBe(true);
	});

	test('keep sorting when the clock stands still or steps back', () => {
		const clock = spyOn(Date, 'now');
		const ids: string[] = [];
		for (const ms of [5_000_000, 5_000_000, 5_000_000, 4_999_000, 4_999_000, 5_000_001]) {
			clock.mockReturnValue(ms);
			for (let i = 0; i < 3; i++) ids.push(newId());
		}
		clock.mockRestore();
		expect(inOrder(ids)).toBe(true);
	});

	test('a full millisecond of ids rolls into the next one instead of repeating', () => {
		const clock = spyOn(Date, 'now').mockReturnValue(7_000_000);
		const ids = Array.from({ length: 10_000 }, () => newId());
		clock.mockRestore();
		expect(inOrder(ids)).toBe(true);
	});
});
