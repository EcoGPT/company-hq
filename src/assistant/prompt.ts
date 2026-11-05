import type { Conversation } from '../core/conversations';
import type { Person } from '../core/people';
import type { ResolvedAssistant } from './define';
import type { MemoryEntry } from './memory';

export type PromptInput = {
	assistant: ResolvedAssistant;
	conversation: Conversation;
	participants: Person[];
	memories: MemoryEntry[];
	briefings: { app: string; text: string }[];
	now: Date;
};

function partsOf(format: Intl.DateTimeFormat, date: Date): Record<string, string> {
	return Object.fromEntries(format.formatToParts(date).map((part) => [part.type, part.value]));
}

export function localTime(date: Date, timeZone: string): string {
	const parts = partsOf(
		new Intl.DateTimeFormat('en-US', {
			timeZone,
			weekday: 'long',
			year: 'numeric',
			month: '2-digit',
			day: '2-digit',
			hour: '2-digit',
			minute: '2-digit',
			hourCycle: 'h23',
			timeZoneName: 'longOffset',
		}),
		date,
	);
	const offset = parts.timeZoneName === 'GMT' ? 'UTC+00:00' : parts.timeZoneName?.replace('GMT', 'UTC');
	return `${parts.weekday} ${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute} in ${timeZone} (${offset})`;
}

export function comingDays(date: Date, timeZone: string, count = 7): string {
	const dayIn = (zone: string) =>
		new Intl.DateTimeFormat('en-CA', { timeZone: zone, weekday: 'short', year: 'numeric', month: '2-digit', day: '2-digit' });
	const today = partsOf(dayIn(timeZone), date);
	const calendar = dayIn('UTC');
	const days: string[] = [];
	for (let i = 1; i <= count; i++) {
		const day = partsOf(calendar, new Date(Date.UTC(Number(today.year), Number(today.month) - 1, Number(today.day) + i)));
		days.push(`${day.weekday} ${day.year}-${day.month}-${day.day}`);
	}
	return days.join(', ');
}

function whereYouAre({ assistant, conversation, participants, now }: PromptInput): string {
	const where =
		conversation.kind === 'dm'
			? 'a direct message — everything here is addressed to you'
			: `the room "${conversation.title}" — you were tagged with @${assistant.handle}`;
	const people = participants.map((p) => `${p.name} (@${p.handle}${p.kind === 'human' ? '' : `, ${p.kind}`})`);
	return [
		'## Where you are',
		`You are ${assistant.name} (@${assistant.handle}), in ${where}.`,
		`Conversation id: ${conversation.id}`,
		`People here: ${people.join(', ')}`,
		`Now: ${localTime(now, assistant.timezone)}, which is ${now.toISOString()}.`,
		`Coming days: ${comingDays(now, assistant.timezone)}.`,
		`Tell people times in ${assistant.timezone} unless they ask otherwise. When a tool takes an ISO 8601 time, include the offset.`,
	].join('\n');
}

const REPLYING = [
	'## Replying',
	'Your final text is posted into this conversation for you. Do not call send_message to answer here.',
	'Messages arrive as "Name (@handle): text". Handles are unique, names are not: go by the handle when it matters who said something. Answer the newest message; earlier ones are context.',
].join('\n');

function thisRoom({ assistant, conversation }: PromptInput): string | null {
	const surface = conversation.key === null ? undefined : assistant.surfaces[conversation.key];
	return surface === undefined ? null : `## This room\n${surface.trim()}`;
}

function apps({ briefings }: PromptInput): string | null {
	if (briefings.length === 0) return null;
	return ['## Apps', ...briefings.map((b) => `### ${b.app}\n${b.text.trim()}`)].join('\n\n');
}

function remembered({ memories }: PromptInput): string | null {
	if (memories.length === 0) return null;
	return [
		'## What you remember',
		'Saved with remember; correct with forget.',
		...memories.map((m) => `- [${m.id}] ${m.content}`),
	].join('\n');
}

export function buildSystemPrompt(input: PromptInput): string {
	return [input.assistant.persona, whereYouAre(input), REPLYING, thisRoom(input), apps(input), remembered(input)]
		.filter((section) => section !== null)
		.join('\n\n');
}
