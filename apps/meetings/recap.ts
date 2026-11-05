import { type AppContext, stripReasoning, z } from '@hq/sdk';
import { Meetings, type ActionItem, type Meeting } from './store';

const MAX_TRANSCRIPT = 60_000;

const RECAP_SYSTEM = `You write meeting recaps. Read the transcript and answer with JSON only, no prose around it:
{"summary": "2-4 plain sentences", "decisions": ["..."], "action_items": [{"title": "short imperative", "owner": "handle or null", "due": "YYYY-MM-DD or null"}]}
Use only what the transcript says. Owners must be one of the listed handles, without the @. Leave lists empty when there is nothing.`;

const shape = z.object({
	summary: z.string().default(''),
	decisions: z.array(z.string()).default([]),
	action_items: z
		.array(
			z.object({
				title: z.string().min(1),
				owner: z.string().nullish(),
				due: z.string().nullish(),
			}),
		)
		.default([]),
});

export type ParsedRecap = z.infer<typeof shape>;

export function parseRecap(raw: string): ParsedRecap {
	const text = stripReasoning(raw);
	const fenced = /```(?:json)?\s*([\s\S]*?)```/.exec(text)?.[1];
	const candidate = fenced ?? text.slice(text.indexOf('{'), text.lastIndexOf('}') + 1);
	try {
		const parsed = shape.safeParse(JSON.parse(candidate));
		if (parsed.success) return parsed.data;
	} catch {}
	return { summary: text, decisions: [], action_items: [] };
}

function formatDay(ms: number): string {
	return new Date(ms).toISOString().slice(0, 10);
}

function recapMessage(meeting: Meeting, recap: ParsedRecap, items: ActionItem[]): string {
	const lines = [`**Recap: ${meeting.title}** (${formatDay(meeting.starts_at)})`];
	if (recap.summary.trim() !== '') lines.push('', recap.summary.trim());
	if (recap.decisions.length > 0) lines.push('', '**Decisions**', ...recap.decisions.map((d) => `- ${d}`));
	if (items.length > 0) {
		lines.push(
			'',
			'**Action items**',
			...items.map((item) => {
				const meta = [item.owner === null ? null : `@${item.owner}`, item.due === null ? null : `due ${item.due}`].filter(
					Boolean,
				);
				return `- ${item.title}${meta.length > 0 ? ` (${meta.join(', ')})` : ''}`;
			}),
		);
	}
	return lines.join('\n');
}

export async function recapMeeting(app: AppContext, meeting: Meeting, transcript: string) {
	const { hub } = app;
	const store = new Meetings(hub);
	const handles = store.participants(meeting).map((p) => p.handle);
	const raw = await app.ai.chat(
		[
			`Meeting: ${meeting.title}`,
			`Started: ${new Date(meeting.starts_at).toISOString()}`,
			`Handles: ${handles.join(', ') || 'none'}`,
			meeting.agenda === '' ? '' : `Agenda: ${meeting.agenda}`,
			'',
			'Transcript:',
			transcript.slice(0, MAX_TRANSCRIPT),
		].join('\n'),
		{ system: RECAP_SYSTEM, temperature: 0 },
	);
	const recap = parseRecap(raw);

	const items: ActionItem[] = [];
	const filing = app.tools.has('add_task');
	const earlier = new Map(
		(meeting.action_items === null ? [] : (JSON.parse(meeting.action_items) as ActionItem[])).map((item) => [
			item.title.toLowerCase(),
			item.task_id,
		]),
	);
	for (const item of recap.action_items) {
		const owner = item.owner?.replace(/^@/, '') ?? null;
		const action: ActionItem = {
			title: item.title.trim().slice(0, 200),
			owner: owner !== null && hub.people.byHandle(owner) !== null ? owner : null,
			due: item.due !== undefined && item.due !== null && /^\d{4}-\d{2}-\d{2}$/.test(item.due) ? item.due : null,
			task_id: null,
		};
		const filed = earlier.get(action.title.toLowerCase());
		if (filed !== undefined && filed !== null) action.task_id = filed;
		else if (filing) {
			const result = await app.tools.call(
				'add_task',
				{
					title: action.title,
					notes: `From the meeting "${meeting.title}" on ${formatDay(meeting.starts_at)}.`,
					...(action.owner === null ? {} : { owner_handle: action.owner }),
					...(action.due === null ? {} : { due: action.due }),
				},
				{ conversationId: meeting.room_id },
			);
			if (result.ok) action.task_id = (result.value as { id?: string }).id ?? null;
		}
		items.push(action);
	}

	const body = recapMessage(meeting, recap, items);
	const message = app.assistant.post(meeting.room_id, body, { app: 'meetings', meeting: meeting.id });
	const saved = store.saveRecap(meeting, { transcript, summary: body, actionItems: items });
	app.emit('changed', { id: meeting.id });
	return { meeting: saved, message_id: message.id, decisions: recap.decisions, action_items: items, tasks_filed: filing };
}
