import { describe, expect, test } from 'bun:test';
import { defineAssistant } from '@hq/sdk';
import tasks from '../tasks/app';
import { Tasks } from '../tasks/store';
import meetings from './app';
import { parseRecap } from './recap';
import { admin, client, createHq, scripted, scriptedTranscriber } from '@hq/sdk/testing';

const RECAP = JSON.stringify({
	summary: 'The team agreed on the beta date.',
	decisions: ['Beta ships on 2030-03-06'],
	action_items: [
		{ title: 'Write the launch post', owner: 'bo', due: '2030-03-04' },
		{ title: 'Book the venue', owner: 'ghost', due: 'next week' },
	],
});

function setup(options: { withTasks?: boolean; replies?: string[] } = {}) {
	const provider = scripted((options.replies ?? [RECAP]).map((content) => ({ content })));
	const transcriber = scriptedTranscriber(['Ada: beta ships March 6. Bo: I will write the post by the 4th.']);
	const hq = createHq({
		provider,
		apps: options.withTasks === false ? [meetings] : [tasks, meetings],
		ai: { transcribe: transcriber },
		assistant: defineAssistant({ name: 'Atlas', handle: 'atlas', persona: 'P', model: 'm' }),
	});
	const ada = admin(hq);
	hq.hub.people.create({ name: 'Bo', handle: 'bo' });
	const as = client(hq, ada.key);
	return { hq, ada, as, provider, transcriber };
}

async function scheduleOne(as: ReturnType<typeof client>) {
	const created = await as('POST', '/apps/meetings/api/meetings', {
		title: 'Beta planning',
		starts_at: '2030-03-01T16:00:00Z',
		attendee_handles: ['bo'],
	});
	return created.body as { id: string; room: { id: string } };
}

describe('meeting recaps', () => {
	test('a pasted transcript becomes a recap in the room and tasks on the list', async () => {
		const { hq, as, provider } = setup();
		const meeting = await scheduleOne(as);
		const response = await as('POST', `/apps/meetings/api/meetings/${meeting.id}/transcript`, {
			transcript: 'Ada: ship it March 6.',
		});
		expect(response.status).toBe(200);

		const prompt = provider.requests[0]!;
		expect(prompt.messages[0]).toMatchObject({ role: 'system' });
		expect(prompt.messages[1]!.content).toContain('Handles: ada, bo');
		expect(prompt.messages[1]!.content).toContain('Ada: ship it March 6.');

		const posted = hq.hub.messages.list(meeting.room.id).at(-1)!;
		expect(posted.author_id).toBe(hq.assistant.self.id);
		expect(posted.metadata).toEqual({ app: 'meetings', meeting: meeting.id });
		expect(posted.body).toBe(
			[
				'**Recap: Beta planning** (2030-03-01)',
				'',
				'The team agreed on the beta date.',
				'',
				'**Decisions**',
				'- Beta ships on 2030-03-06',
				'',
				'**Action items**',
				'- Write the launch post (@bo, due 2030-03-04)',
				'- Book the venue',
			].join('\n'),
		);

		const filed = new Tasks(hq.hub).list();
		expect(filed.map((t) => [t.title, hq.hub.people.get(t.owner_id ?? '')?.handle ?? null, t.conversation_id])).toEqual([
			['Write the launch post', 'bo', meeting.room.id],
			['Book the venue', null, meeting.room.id],
		]);
		expect(response.body.action_items.map((i: { task_id: string }) => i.task_id)).toEqual(filed.map((t) => t.id));
		expect(response.body.summary).toBe(posted.body);
		expect(response.body.has_transcript).toBe(true);
	});

	test('recapping again does not file the same tasks twice', async () => {
		const { hq, as } = setup({ replies: [RECAP, RECAP] });
		const meeting = await scheduleOne(as);
		await as('POST', `/apps/meetings/api/meetings/${meeting.id}/transcript`, { transcript: 'first pass' });
		await as('POST', `/apps/meetings/api/meetings/${meeting.id}/transcript`, { transcript: 'second pass' });
		expect(new Tasks(hq.hub).list()).toHaveLength(2);
	});

	test('a recording is transcribed first', async () => {
		const { hq, as, ada, transcriber } = setup();
		const meeting = await scheduleOne(as);
		const form = new FormData();
		form.append('file', new File([new Uint8Array([1, 2, 3])], 'planning.m4a', { type: 'audio/mp4' }));
		const response = await hq.fetch(
			new Request(`http://hq.test/apps/meetings/api/meetings/${meeting.id}/recording`, {
				method: 'POST',
				headers: { authorization: `Bearer ${ada.key}` },
				body: form,
			}),
		);
		expect(response?.status).toBe(200);
		expect(transcriber.requests[0]?.filename).toBe('planning.m4a');
		expect(transcriber.requests[0]?.audio.size).toBe(3);
		expect(hq.hub.messages.list(meeting.room.id).at(-1)?.body).toContain('**Recap: Beta planning**');

		const raw = await hq.fetch(
			new Request(`http://hq.test/apps/meetings/api/meetings/${meeting.id}/recording?filename=raw.wav`, {
				method: 'POST',
				headers: { authorization: `Bearer ${ada.key}`, 'content-type': 'audio/wav' },
				body: new Uint8Array([9, 9]),
			}),
		);
		expect(raw?.status).toBe(200);
		expect(transcriber.requests[1]?.filename).toBe('raw.wav');

		const garbled = await hq.fetch(
			new Request(`http://hq.test/apps/meetings/api/meetings/${meeting.id}/recording`, {
				method: 'POST',
				headers: { authorization: `Bearer ${ada.key}`, 'content-type': 'multipart/form-data; boundary=x' },
				body: 'garbage',
			}),
		);
		expect(garbled?.status).toBe(400);

		const unnamed = await hq.fetch(
			new Request(`http://hq.test/apps/meetings/api/meetings/${meeting.id}/recording`, {
				method: 'POST',
				headers: { authorization: `Bearer ${ada.key}`, 'content-type': 'audio/webm' },
				body: new Uint8Array([9, 9]),
			}),
		);
		expect(unnamed?.status).toBe(200);
		expect(transcriber.requests[2]?.filename).toBe('recording.webm');
	});

	test('a recording over the speech-to-text limit is refused before upload', async () => {
		const transcriber = scriptedTranscriber();
		const hq = createHq({
			provider: scripted([{ content: RECAP }]),
			apps: [meetings],
			ai: { transcribe: { ...transcriber, maxBytes: 2 } },
			assistant: defineAssistant({ name: 'Atlas', handle: 'atlas', persona: 'P', model: 'm' }),
		});
		const ada = admin(hq);
		hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const meeting = await scheduleOne(client(hq, ada.key));
		const response = await hq.fetch(
			new Request(`http://hq.test/apps/meetings/api/meetings/${meeting.id}/recording`, {
				method: 'POST',
				headers: { authorization: `Bearer ${ada.key}`, 'content-type': 'audio/wav' },
				body: new Uint8Array([1, 2, 3]),
			}),
		);
		expect(response?.status).toBe(413);
		expect((await response?.json()).error).toContain('HQ_STT_MAX_MB');
		expect(transcriber.requests).toHaveLength(0);
	});

	test('without speech-to-text or the Tasks app it degrades cleanly', async () => {
		const hq = createHq({
			apps: [meetings],
			provider: scripted([{ content: RECAP }]),
			assistant: defineAssistant({ name: 'Atlas', handle: 'atlas', persona: 'P', model: 'm' }),
		});
		const ada = admin(hq);
		hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		const as = client(hq, ada.key);
		const meeting = await scheduleOne(as);
		const audio = await hq.fetch(
			new Request(`http://hq.test/apps/meetings/api/meetings/${meeting.id}/recording`, {
				method: 'POST',
				headers: { authorization: `Bearer ${ada.key}` },
				body: new Uint8Array([1]),
			}),
		);
		expect(audio?.status).toBe(503);
		expect(await audio?.json()).toEqual({ error: 'speech-to-text is not configured (set HQ_STT_MODEL)' });
		const response = await as('POST', `/apps/meetings/api/meetings/${meeting.id}/transcript`, { transcript: 'notes' });
		expect(response.body.action_items.every((i: { task_id: string | null }) => i.task_id === null)).toBe(true);
		expect((await as('POST', `/apps/meetings/api/meetings/${meeting.id}/transcript`, { transcript: '  ' })).status).toBe(400);
	});

	test('the assistant can recap from chat', async () => {
		const { hq, as } = setup();
		const meeting = await scheduleOne(as);
		const result = await hq.registry.call(
			'recap_meeting',
			{ id: meeting.id, transcript: 'Bo will write the post.' },
			{ hub: hq.hub, caller: hq.assistant.self },
		);
		expect(result).toMatchObject({
			ok: true,
			value: { posted_to: meeting.room.id, tasks_filed: true, decisions: ['Beta ships on 2030-03-06'] },
		});
		const stranger = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
		expect(
			await hq.registry.call('recap_meeting', { id: meeting.id, transcript: 'x' }, { hub: hq.hub, caller: stranger }, 'everyone'),
		).toMatchObject({
			ok: false,
		});
	});
});

describe('parseRecap', () => {
	test('reads fenced, wrapped and reasoning-prefixed JSON', () => {
		expect(parseRecap('```json\n{"summary":"s"}\n```')).toEqual({ summary: 's', decisions: [], action_items: [] });
		expect(parseRecap('<think>let me see</think>Here you go: {"summary":"s","decisions":["d"]} done').decisions).toEqual(['d']);
	});

	test('falls back to the raw text as the summary', () => {
		expect(parseRecap('We mostly talked about lunch.')).toEqual({
			summary: 'We mostly talked about lunch.',
			decisions: [],
			action_items: [],
		});
	});
});
