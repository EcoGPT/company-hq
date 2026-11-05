import { describe, expect, test } from 'bun:test';
import { calendar, escapeText, fold } from './ics';

const HOUR = 3_600_000;

describe('ics', () => {
	test('escapes and folds long lines on byte boundaries', () => {
		expect(escapeText('a,b;c\\d\ne')).toBe('a\\,b\\;c\\\\d\\ne');
		const long = `DESCRIPTION:${'é'.repeat(100)}`;
		const folded = fold(long);
		for (const line of folded.split('\r\n')) expect(new TextEncoder().encode(line).length).toBeLessThanOrEqual(75);
		expect(folded.replace(/\r\n /g, '')).toBe(long);
	});

	test('cancelled events say so', () => {
		const text = calendar('Ada', [{ uid: 'x@hq', start: 0, end: HOUR, title: 'Gone', cancelled: true }], 0);
		expect(text).toContain('STATUS:CANCELLED');
		expect(text).toContain('DTSTAMP:19700101T000000Z');
	});
});

describe('line breaks in text', () => {
	test('a bare carriage return cannot start a new calendar line', () => {
		expect(escapeText('Review\rATTENDEE:mailto:x@example.com')).toBe('Review\\nATTENDEE:mailto:x@example.com');
		expect(escapeText('a\r\nb\nc\rd')).toBe('a\\nb\\nc\\nd');
	});
});
