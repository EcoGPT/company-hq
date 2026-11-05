import { describe, expect, test } from 'bun:test';
import { z } from 'zod';
import { Hub } from '../src/core/hub';
import { defineTool, toSpec, ToolError } from '../src/tools/define';
import { formatResult, resolveRoomRefs, ToolRegistry } from '../src/tools/registry';

const add = defineTool({
	name: 'add',
	description: 'Add two numbers',
	input: z.object({ a: z.number(), b: z.number().default(0) }),
	run: ({ a, b }) => a + b,
});

function ctx() {
	const hub = Hub.open();
	return { hub, caller: hub.people.create({ name: 'Ada', handle: 'ada' }) };
}

describe('tools', () => {
	test('an input JSON Schema cannot express is refused when the tool is defined', () => {
		expect(() => defineTool({ name: 'when', description: 'd', input: z.object({ at: z.date() }), run: () => null })).toThrow(
			'tool when has an input the model can',
		);
	});

	test('a spec is the input as JSON Schema', () => {
		expect(toSpec(add)).toEqual({
			name: 'add',
			description: 'Add two numbers',
			parameters: {
				type: 'object',
				properties: { a: { type: 'number' }, b: { type: 'number', default: 0 } },
				required: ['a'],
			},
		});
	});

	test('a call validates its input and turns failures into results', async () => {
		const registry = new ToolRegistry().register([
			add,
			defineTool({
				name: 'refuse',
				description: 'Always refuses',
				input: z.object({}),
				run: () => {
					throw new ToolError('not today');
				},
			}),
		]);
		expect(await registry.call('add', { a: 2 }, ctx())).toEqual({ ok: true, value: 2 });
		expect((await registry.call('add', { a: 'two' }, ctx())).ok).toBe(false);
		expect(await registry.call('refuse', {}, ctx())).toEqual({ ok: false, error: 'not today' });
		expect(await registry.call('nope', {}, ctx())).toEqual({ ok: false, error: 'unknown tool: nope' });
	});

	test('audience and availability filter the list', async () => {
		const registry = new ToolRegistry().register([
			add,
			defineTool({ name: 'secret', description: 's', audience: 'assistant', input: z.object({}), run: () => 1 }),
			defineTool({ name: 'gated', description: 'g', available: () => false, input: z.object({}), run: () => 1 }),
		]);
		expect(registry.list('everyone').map((t) => t.name)).toEqual(['add', 'gated']);
		expect(registry.specs('assistant', ctx()).map((t) => t.name)).toEqual(['add', 'secret']);
		expect((await registry.call('secret', {}, ctx(), 'everyone')).ok).toBe(false);
		expect(await registry.call('gated', {}, ctx())).toEqual({ ok: false, error: 'gated is not configured' });
	});

	test('a duplicate or non-snake_case name is refused', () => {
		expect(() => new ToolRegistry().register([add], 'core').register([add], 'apps/math')).toThrow('apps/math');
		expect(() => defineTool({ name: 'Bad-Name', description: '', input: z.object({}), run: () => 0 })).toThrow();
	});

	test('formatResult truncates long results', () => {
		expect(formatResult({ ok: true, value: 'x'.repeat(20) }, 5)).toBe('xxxxx… [truncated 15 chars]');
		expect(formatResult({ ok: false, error: 'e' })).toBe('{"error":"e"}');
	});
});

describe('room references', () => {
	test('a room title, #name, key or "this room" becomes its id', () => {
		const hub = Hub.open();
		const ada = hub.people.create({ name: 'Ada', handle: 'ada' });
		const launch = hub.conversations.createRoom({ title: 'Launch', createdBy: ada.id });
		const general = hub.general();
		hub.conversations.addMember(general.id, ada.id);
		const ctx = { hub, caller: ada, conversationId: launch.id };
		expect(resolveRoomRefs({ conversation_id: 'launch', x: 1 }, ctx)).toEqual({ conversation_id: launch.id, x: 1 });
		expect(resolveRoomRefs({ conversation_id: '#General' }, ctx)).toEqual({ conversation_id: general.id });
		expect(resolveRoomRefs({ room_id: 'this room' }, ctx)).toEqual({ room_id: launch.id });
		expect(resolveRoomRefs({ conversation_id: launch.id }, ctx)).toEqual({ conversation_id: launch.id });
		expect(resolveRoomRefs({ conversation_id: 'nowhere' }, ctx)).toEqual({ conversation_id: 'nowhere' });
	});

	test('rooms the caller is not in, and ambiguous titles, are left alone', () => {
		const hub = Hub.open();
		const ada = hub.people.create({ name: 'Ada', handle: 'ada' });
		const bo = hub.people.create({ name: 'Bo', handle: 'bo' });
		hub.conversations.createRoom({ title: 'Secret', createdBy: bo.id });
		hub.conversations.createRoom({ title: 'Twin', createdBy: ada.id });
		hub.conversations.createRoom({ title: 'Twin', createdBy: ada.id });
		expect(resolveRoomRefs({ conversation_id: 'Secret' }, { hub, caller: ada })).toEqual({ conversation_id: 'Secret' });
		expect(resolveRoomRefs({ conversation_id: 'twin' }, { hub, caller: ada })).toEqual({ conversation_id: 'twin' });
	});
});
