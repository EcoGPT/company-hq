import { z } from 'zod';
import type { Message } from '../core/messages';
import { personByHandle } from './lookup';
import { canSee, defineTool, ToolError, type Tool, type ToolContext } from './define';

function requireMember(ctx: ToolContext, conversationId: string) {
	const conversation = ctx.hub.conversations.get(conversationId);
	if (conversation === null || !canSee(ctx, conversationId)) {
		throw new ToolError(`no conversation ${conversationId} that you are in`);
	}
	return conversation;
}

function visible(ctx: ToolContext) {
	return ctx.hub.conversations.listFor(ctx.caller.id).filter((c) => canSee(ctx, c.id));
}

function present(ctx: ToolContext, messages: Message[]) {
	const authors = ctx.hub.people.byIds(messages.map((m) => m.author_id));
	return messages.map((message) => {
		const author = authors.get(message.author_id);
		return {
			id: message.id,
			conversation_id: message.conversation_id,
			from: author === undefined ? message.author_id : `${author.name} (@${author.handle})`,
			at: new Date(message.created_at).toISOString(),
			body: message.body,
		};
	});
}

export const coreTools: Tool[] = [
	defineTool({
		name: 'list_people',
		description: 'List everyone in HQ with their handle, kind and role.',
		input: z.object({}),
		activity: 'Checking who is here',
		run: (_, { hub }) => hub.people.list().map(({ id, name, handle, kind, role }) => ({ id, name, handle, kind, role })),
	}),
	defineTool({
		name: 'list_conversations',
		description: 'List the rooms and DMs you are in.',
		input: z.object({}),
		activity: 'Looking at conversations',
		run: (_, ctx) => {
			const { hub, caller } = ctx;
			const conversations = visible(ctx);
			const others = new Map(
				conversations
					.filter((c) => c.kind === 'dm')
					.map((c) => [c.id, hub.conversations.memberIds(c.id).filter((id) => id !== caller.id)]),
			);
			const people = hub.people.byIds([...others.values()].flat());
			return conversations.map((c) => ({
				id: c.id,
				kind: c.kind,
				title: c.kind === 'dm' ? (others.get(c.id) ?? []).map((id) => people.get(id)?.name ?? id).join(', ') : c.title,
				key: c.key,
			}));
		},
	}),
	defineTool({
		name: 'read_conversation',
		description: 'Read the most recent messages in a conversation you are in.',
		input: z.object({
			conversation_id: z.string(),
			limit: z.number().int().min(1).max(200).default(30),
		}),
		activity: 'Reading the thread',
		run: ({ conversation_id, limit }, ctx) => {
			requireMember(ctx, conversation_id);
			return present(ctx, ctx.hub.messages.list(conversation_id, { limit }));
		},
	}),
	defineTool({
		name: 'search_messages',
		description: 'Search messages across every conversation you are in. Plain substring match.',
		input: z.object({ query: z.string().min(1), limit: z.number().int().min(1).max(50).default(20) }),
		activity: 'Searching HQ',
		run: ({ query, limit }, ctx) => {
			const within = ctx.viewers === undefined ? undefined : visible(ctx).map((c) => c.id);
			return present(ctx, ctx.hub.messages.search(ctx.caller.id, query, limit, within));
		},
	}),
	defineTool({
		name: 'send_message',
		description:
			'Send a message to a conversation you are in, or DM a person by handle. Only send when someone asked you to — your reply in the current thread is sent automatically.',
		input: z
			.object({
				conversation_id: z.string().optional(),
				to_handle: z.string().optional(),
				body: z.string().min(1).max(20_000),
			})
			.refine((v) => (v.conversation_id === undefined) !== (v.to_handle === undefined), {
				message: 'give exactly one of conversation_id or to_handle',
			}),
		activity: 'Sending a message',
		run: ({ conversation_id, to_handle, body }, ctx) => {
			const target =
				conversation_id !== undefined
					? requireMember(ctx, conversation_id)
					: ctx.hub.conversations.dm(ctx.caller.id, personByHandle(ctx.hub, to_handle ?? '').id);
			if (!ctx.hub.conversations.isMember(target.id, ctx.caller.id)) throw new ToolError(`no conversation with ${to_handle}`);
			const message = ctx.hub.messages.send({ conversationId: target.id, authorId: ctx.caller.id, body });
			return { sent: message.id, conversation_id: target.id };
		},
	}),
	defineTool({
		name: 'create_room',
		description: 'Create a room with a title and members (by handle). You are added automatically.',
		input: z.object({ title: z.string().min(1).max(120), member_handles: z.array(z.string()).default([]) }),
		activity: 'Opening a room',
		run: ({ title, member_handles }, ctx) => {
			const memberIds = member_handles.map((handle) => personByHandle(ctx.hub, handle).id);
			const room = ctx.hub.conversations.createRoom({ title, createdBy: ctx.caller.id, memberIds });
			return { id: room.id, title: room.title };
		},
	}),
];
