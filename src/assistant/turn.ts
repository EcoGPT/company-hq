import type { Conversation } from '../core/conversations';
import type { Hub } from '../core/hub';
import type { Message } from '../core/messages';
import type { Person } from '../core/people';
import { stripReasoning } from '../llm/reasoning';
import {
	ProviderError,
	type ChatMessage,
	type CompletionRequest,
	type CompletionResult,
	type Provider,
	type ToolCall,
} from '../llm/types';
import { errorMessage, type ToolContext } from '../tools/define';
import { formatResult, type ToolRegistry } from '../tools/registry';
import type { ResolvedAssistant } from './define';
import type { Memory } from './memory';
import { buildSystemPrompt } from './prompt';
import { shouldReply } from './runner';
import { toolCallsInText } from './text-tool-calls';

export type TurnDeps = {
	hub: Hub;
	provider: Provider;
	registry: ToolRegistry;
	assistant: ResolvedAssistant;
	self: Person;
	memory: Memory;
	briefings?: () => { app: string; text: string }[];
	now?: () => Date;
};

export type TurnResult =
	| { kind: 'replied'; text: string; hops: number }
	| { kind: 'silent'; hops: number }
	| { kind: 'failed'; error: string; hops: number };

const OUT_OF_HOPS = 'You are out of tool calls for this turn. Answer now with what you have, and say what is unfinished.';

export const escapeRegExp = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function cleanReply(text: string, assistant: ResolvedAssistant): string {
	return stripReasoning(text).replace(
		new RegExp(`^${escapeRegExp(assistant.name)}(?: \\(@${escapeRegExp(assistant.handle)}\\))?:\\s*`),
		'',
	);
}

const speaker = (person: Person | undefined) => (person === undefined ? 'Unknown' : `${person.name} (@${person.handle})`);

function historyToMessages(hub: Hub, self: Person, history: Message[]): ChatMessage[] {
	const authors = hub.people.byIds(history.map((m) => m.author_id));
	return history.map((message): ChatMessage =>
		message.author_id === self.id
			? { role: 'assistant', content: message.body }
			: { role: 'user', content: `${speaker(authors.get(message.author_id))}: ${message.body}` },
	);
}

function inOrderSeen(history: Message[], self: Person): Message[] {
	const ordered: Message[] = [];
	for (const message of history) {
		const seen = message.author_id === self.id ? (message.metadata?.turn as { seen?: unknown } | undefined)?.seen : undefined;
		const at = ordered.findIndex((earlier) => earlier.id === seen);
		ordered.splice(at === -1 ? ordered.length : at + 1, 0, message);
	}
	return ordered;
}

function openingMessages(
	deps: TurnDeps,
	conversation: Conversation,
	memberIds: string[],
	ctx: ToolContext,
): { messages: ChatMessage[]; seen?: string } {
	const { hub, assistant, self } = deps;
	const members = hub.people.byIds(memberIds);
	const system = buildSystemPrompt({
		assistant,
		conversation,
		participants: memberIds.flatMap((id) => members.get(id) ?? []),
		memories: deps.memory.visibleTo([ctx.caller.id, ...(ctx.viewers ?? [])]),
		briefings: deps.briefings?.() ?? [],
		now: deps.now?.() ?? new Date(),
	});
	const history = inOrderSeen(hub.messages.list(conversation.id, { limit: assistant.historyLimit }), self);
	return { messages: [{ role: 'system', content: system }, ...historyToMessages(hub, self, history)], seen: history.at(-1)?.id };
}

function toolCallsOf(result: CompletionResult, known: Set<string>): { calls: ToolCall[]; native: boolean } {
	if (result.toolCalls.length > 0) return { calls: result.toolCalls, native: true };
	return { calls: toolCallsInText(result.content, (name) => known.has(name)), native: false };
}

export async function runTurn(deps: TurnDeps, conversationId: string, signal?: AbortSignal): Promise<TurnResult> {
	const { hub, provider, registry, assistant, self } = deps;
	const conversation = hub.conversations.get(conversationId);
	if (conversation === null || conversation.archived_at !== null)
		return { kind: 'failed', error: 'conversation not found', hops: 0 };
	const model = assistant.model ?? provider.defaultModel;
	if (model === undefined) return { kind: 'failed', error: 'no model configured (set HQ_LLM_MODEL)', hops: 0 };

	const setState = (label: string | null) => hub.bus.emit({ type: 'assistant.state', conversationId, personId: self.id, label });
	const memberIds = hub.conversations.memberIds(conversationId);
	// Whatever a tool returns can end up in the reply, so tools only reach what everyone here can already see.
	const recent = hub.messages.list(conversationId, { limit: assistant.historyLimit });
	const authors = hub.people.byIds(recent.map((message) => message.author_id));
	const requester = recent.findLast((message) =>
		shouldReply(assistant, self, authors.get(message.author_id) ?? null, conversation, message),
	)?.author_id;
	const ctx: ToolContext = {
		hub,
		caller: self,
		conversationId,
		viewers: memberIds.filter((id) => id !== self.id),
		requester,
		signal,
	};

	const usage = { inputTokens: 0, outputTokens: 0 };
	let answeredBy = model;
	const ask = (request: Pick<CompletionRequest, 'messages' | 'tools' | 'toolChoice'>) =>
		provider.complete({ model, ...request, temperature: assistant.temperature, signal });
	const tally = (result: CompletionResult) => {
		usage.inputTokens += result.usage?.inputTokens ?? 0;
		usage.outputTokens += result.usage?.outputTokens ?? 0;
		answeredBy = result.model ?? model;
		return result;
	};

	let hops = 0;
	try {
		const { messages, seen } = openingMessages(deps, conversation, memberIds, ctx);
		const tools = registry.specs('assistant', ctx);
		const known = new Set(tools.map((tool) => tool.name));
		let reply: string | undefined;
		setState('Thinking');
		while (hops < assistant.maxHops) {
			hops += 1;
			const result = tally(await ask({ messages, tools }));
			const { calls, native } = toolCallsOf(result, known);
			if (calls.length === 0) {
				reply = result.content;
				break;
			}
			messages.push({ role: 'assistant', content: native ? result.content : '', toolCalls: calls });
			for (const call of calls) {
				setState(registry.get(call.name)?.activity ?? `Using ${call.name}`);
				const outcome = await registry.call(call.name, call.arguments, ctx);
				messages.push({ role: 'tool', toolCallId: call.id, name: call.name, content: formatResult(outcome) });
			}
			setState('Thinking');
		}
		if (reply === undefined) {
			messages.push({ role: 'system', content: OUT_OF_HOPS });
			reply = tally(await ask({ messages, tools, toolChoice: 'none' })).content;
		}

		const text = cleanReply(reply, assistant);
		if (text === '') return { kind: 'silent', hops };
		const counted = usage.inputTokens + usage.outputTokens > 0;
		hub.messages.send({
			conversationId,
			authorId: self.id,
			body: text,
			metadata: { turn: { hops, model: answeredBy, ...(seen === undefined ? {} : { seen }), ...(counted ? { usage } : {}) } },
		});
		return { kind: 'replied', text, hops };
	} catch (error) {
		if (error instanceof ProviderError) console.error(`[assistant] provider error in ${conversationId}`, error);
		return { kind: 'failed', error: errorMessage(error), hops };
	} finally {
		setState(null);
	}
}
