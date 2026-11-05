import { describe, expect, test } from 'bun:test';
import { extraParts, mergeWire, unsentFrames } from './wire-fixture';

const part = (file: string, name: string) => ({ file, fixture: { structs: { [name]: {} }, frames: { [name]: name } } });

describe('the wire fixtures', () => {
	test('are merged side by side', () => {
		const merged = mergeWire([part('swift-wire.json', 'A'), part('swift-wire.planning.json', 'B')]);
		expect(Object.keys(merged.structs)).toEqual(['A', 'B']);
		expect(Object.keys(merged.frames)).toEqual(['A', 'B']);
		expect(merged.ignored).toEqual({});
	});

	test('never overwrite: a name two files define is an error that names the file', () => {
		expect(() => mergeWire([part('swift-wire.json', 'A'), part('swift-wire.push.json', 'A')])).toThrow(
			'swift-wire.push.json: structs.A is already defined',
		);
	});
});

describe('a frame in a feature’s own fixture file', () => {
	const tasks = {
		file: 'swift-wire.tasks.json',
		fixture: {
			frames: { task_changed: 'T', task_gone: 'T', task_moved: 'T', task_paused: 'T' },
			sent_by: {
				task_changed: 'test/tasks.test.ts',
				task_gone: 'test/missing.test.ts',
				task_moved: 'test/other.test.ts',
				task_paused: 'test/tasks.ts',
			},
		},
	};
	const push = { file: 'swift-wire.push.json', fixture: { frames: { push_ping: 'P' } } };
	const files: Record<string, string> = {
		'test/tasks.test.ts': "expect(frame.type).toBe('task_changed')",
		'test/other.test.ts': 'nothing about it',
		'test/tasks.ts': "'task_paused'",
	};
	const read = (path: string) => files[path] ?? null;

	test('must be sent by a test that exists and names it', () => {
		expect(unsentFrames([tasks, push], read)).toEqual([
			'swift-wire.tasks.json: task_gone',
			'swift-wire.tasks.json: task_moved',
			'swift-wire.tasks.json: task_paused',
			'swift-wire.push.json: push_ping',
		]);
	});

	test('is found when its test names it in quotes of any kind', () => {
		const only = {
			file: 'swift-wire.x.json',
			fixture: { frames: { a: 'A', b: 'A', c: 'A' }, sent_by: { a: 't/x.test.ts', b: 't/x.test.ts', c: 't/x.test.ts' } },
		};
		const text = `send({ type: "a" }); take('b'); send(\`c\`)`;
		expect(unsentFrames([only], () => text)).toEqual([]);
	});

	test('all that are in the fixture files beside swift-wire.json are sent by a test', () => {
		expect(unsentFrames(extraParts)).toEqual([]);
	});
});
