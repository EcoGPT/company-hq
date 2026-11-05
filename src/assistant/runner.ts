import type { Conversation } from '../core/conversations';
import type { Message } from '../core/messages';
import type { Person } from '../core/people';
import type { ResolvedAssistant } from './define';
import { escapeRegExp, runTurn, type TurnDeps, type TurnResult } from './turn';

export function mentions(body: string, handle: string): boolean {
	return new RegExp(`(^|[^\\w@])@${escapeRegExp(handle)}(?![\\w-])`, 'i').test(body);
}

export function shouldReply(
	assistant: ResolvedAssistant,
	self: Person,
	author: Person | null,
	conversation: Conversation,
	message: Message,
): boolean {
	if (message.author_id === self.id || author === null || author.kind !== 'human') return false;
	// The app inserts a person's display name when you tag them, so the name counts as well as the handle.
	if (mentions(message.body, assistant.handle) || mentions(message.body, assistant.name)) return true;
	if (conversation.kind === 'dm') return true;
	return assistant.replyIn === 'everything';
}

export class AssistantRunner {
	private readonly running = new Map<string, Promise<void>>();
	private readonly pending = new Set<string>();
	private unsubscribe?: () => void;
	onResult: (conversationId: string, result: TurnResult) => void = () => {};

	constructor(private readonly deps: TurnDeps) {}

	start(): void {
		const { hub, self, assistant } = this.deps;
		for (const conversation of hub.conversations.all()) {
			if (conversation.kind === 'room') hub.conversations.addMember(conversation.id, self.id);
		}
		this.unsubscribe = hub.bus.on((event) => {
			if (event.type === 'conversation.created') {
				if (event.conversation.kind === 'room') hub.conversations.addMember(event.conversation.id, self.id);
				return;
			}
			if (event.type !== 'message.created') return;
			const conversation = hub.conversations.get(event.message.conversation_id);
			if (conversation === null || !hub.conversations.isMember(conversation.id, self.id)) return;
			const author = hub.people.get(event.message.author_id);
			if (shouldReply(assistant, self, author, conversation, event.message)) this.schedule(conversation.id);
		});
	}

	stop(): void {
		this.unsubscribe?.();
	}

	schedule(conversationId: string): void {
		if (this.running.has(conversationId)) {
			this.pending.add(conversationId);
			return;
		}
		const work = this.drain(conversationId).finally(() => this.running.delete(conversationId));
		this.running.set(conversationId, work);
	}

	async idle(): Promise<void> {
		while (this.running.size > 0) await Promise.all(this.running.values());
	}

	private async drain(conversationId: string): Promise<void> {
		do {
			this.pending.delete(conversationId);
			// An unhandled rejection here would take the whole server down.
			try {
				const result = await runTurn(this.deps, conversationId);
				if (result.kind === 'failed') {
					console.error(`[assistant] turn failed in ${conversationId}: ${result.error}`);
					this.deps.hub.messages.send({
						conversationId,
						authorId: this.deps.self.id,
						body: `I couldn't finish that: ${result.error}`,
						metadata: { turn: { failed: true } },
					});
				}
				this.onResult(conversationId, result);
			} catch (error) {
				console.error(`[assistant] turn crashed in ${conversationId}`, error);
			}
		} while (this.pending.has(conversationId));
	}
}
