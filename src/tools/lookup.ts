import type { Conversation } from '../core/conversations';
import type { Hub } from '../core/hub';
import type { Person } from '../core/people';
import { ProviderError } from '../llm/types';
import { canSee, errorMessage, ToolError, type ToolContext } from './define';

export function personByHandle(hub: Hub, handle: string): Person {
	const person = hub.people.byHandle(handle.trim().replace(/^@/, ''));
	if (person === null) throw new ToolError(`nobody has the handle ${handle}`);
	return person;
}

export function roomFor(ctx: ToolContext, conversationId: string | undefined): Conversation {
	if (conversationId === undefined) throw new ToolError('say which room: pass conversation_id');
	const conversation = ctx.hub.conversations.get(conversationId);
	if (conversation === null || conversation.kind !== 'room' || !canSee(ctx, conversation.id)) {
		throw new ToolError(`no room ${conversationId} that you are in`);
	}
	return conversation;
}

export async function asToolError<T>(work: () => Promise<T>): Promise<T> {
	try {
		return await work();
	} catch (error) {
		if (error instanceof ToolError) throw error;
		if (error instanceof ProviderError) console.error('[tools] provider error', error);
		throw new ToolError(errorMessage(error));
	}
}
