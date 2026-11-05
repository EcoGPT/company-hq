import { describe, expect, test } from 'bun:test';
import assistant from '../assistant/assistant';
import { Hub } from '../src/core/hub';
import { defineAssistant } from '../src/assistant/define';
import { Memory, MEMORY_MIGRATIONS, memoryTools } from '../src/assistant/memory';
import { buildSystemPrompt, comingDays, localTime } from '../src/assistant/prompt';
import { ToolRegistry } from '../src/tools/registry';

describe('assistant definition', () => {
	test('the shipped persona loads from markdown', () => {
		expect(assistant.handle).toBe('atlas');
		expect(assistant.persona).toContain('team assistant on a self-hosted workspace');
		expect(assistant.maxHops).toBe(24);
	});

	test('prompt names the room, people, surface, apps and memories', () => {
		const hub = Hub.open(':memory:', MEMORY_MIGRATIONS);
		const ada = hub.people.create({ name: 'Ada', handle: 'ada' });
		const bot = hub.people.create({ name: 'Atlas', handle: 'atlas', kind: 'assistant' });
		const general = hub.general();
		const memory = new Memory(hub.db);
		const fact = memory.add('Ada owns the launch.');
		const prompt = buildSystemPrompt({
			assistant: defineAssistant({ name: 'Atlas', handle: 'atlas', persona: 'Be kind.', surfaces: { general: 'Be brief.' } }),
			conversation: general,
			participants: [ada, bot],
			memories: memory.list(),
			briefings: [{ app: 'Tasks', text: 'Use add_task.' }],
			now: new Date('2026-01-01T00:00:00Z'),
		});
		expect(prompt.startsWith('Be kind.')).toBe(true);
		expect(prompt).toContain('the room "General"');
		expect(prompt).toContain('Ada (@ada), Atlas (@atlas, assistant)');
		expect(prompt).toContain('## This room\nBe brief.');
		expect(prompt).toContain('### Tasks\nUse add_task.');
		expect(prompt).toContain(`[${fact.id}] Ada owns the launch.`);
	});
});

describe('memory tools', () => {
	test('remember and forget, assistant-only', async () => {
		const hub = Hub.open(':memory:', MEMORY_MIGRATIONS);
		const memory = new Memory(hub.db);
		const registry = new ToolRegistry().register(memoryTools(memory));
		const caller = hub.people.create({ name: 'Atlas', handle: 'atlas', kind: 'assistant' });
		const saved = await registry.call('remember', { fact: 'Standup is at 10.' }, { hub, caller });
		expect(memory.list().map((m) => m.content)).toEqual(['Standup is at 10.']);
		await registry.call('forget', { id: (saved.ok && (saved.value as { saved: string }).saved) || '' }, { hub, caller });
		expect(memory.list()).toEqual([]);
		expect(registry.list('everyone')).toEqual([]);
	});
});

describe('time zone', () => {
	test('the prompt gives local time with its offset, plus UTC', () => {
		const prompt = buildSystemPrompt({
			assistant: defineAssistant({ name: 'Atlas', handle: 'atlas', persona: 'P', timezone: 'America/New_York' }),
			conversation: {
				id: 'c',
				kind: 'dm',
				title: '',
				key: null,
				created_by: null,
				created_at: 0,
				archived_at: null,
				avatar_id: null,
			},
			participants: [],
			memories: [],
			briefings: [],
			now: new Date('2026-10-18T04:42:00Z'),
		});
		expect(prompt).toContain('Now: Sunday 2026-10-18 00:42 in America/New_York (UTC-04:00), which is 2026-10-18T04:42:00.000Z.');
		expect(prompt).toContain('Tell people times in America/New_York');
	});

	test('UTC renders a zero offset; unknown zones fail at definition', () => {
		expect(localTime(new Date('2026-01-01T09:05:00Z'), 'UTC')).toBe('Thursday 2026-01-01 09:05 in UTC (UTC+00:00)');
		expect(() => defineAssistant({ name: 'E', handle: 'e', persona: 'p', timezone: 'Mars/Olympus' })).toThrow(
			'unknown time zone',
		);
	});
});

describe('coming days', () => {
	test('lists the next week by weekday in the team zone', () => {
		expect(comingDays(new Date('2026-10-18T04:42:00Z'), 'America/New_York', 6)).toBe(
			'Mon 2026-10-19, Tue 2026-10-20, Wed 2026-10-21, Thu 2026-10-22, Fri 2026-10-23, Sat 2026-10-24',
		);
		expect(comingDays(new Date('2026-10-18T04:42:00Z'), 'Asia/Tokyo', 1)).toBe('Mon 2026-10-19');
	});

	test('does not skip the day clocks spring forward', () => {
		expect(comingDays(new Date('2026-03-08T04:30:00Z'), 'America/New_York', 2)).toBe('Sun 2026-03-08, Mon 2026-03-09');
	});
});
