import { z } from 'zod';
import type { Conversation } from '../core/conversations';
import type { Message } from '../core/messages';
import { HttpError, Router, type RequestContext } from '../http/router';
import type { Presenter } from './present';

const MAX_MESSAGE_BYTES = 16_384;
const PAGE_LIMIT = 100;

const text = (max: number) => z.string().refine((value) => Buffer.byteLength(value) <= max);

const schemas = {
	createConversation: z.discriminatedUnion('kind', [
		z.object({ kind: z.literal('dm'), person_id: z.string() }),
		z.object({
			kind: z.literal('group'),
			person_ids: z.array(z.string()).min(1).max(50),
			title: z.string().trim().min(1).max(120).optional(),
		}),
	]),
	patchConversation: z.object({ title: z.string().trim().max(120).nullable().optional() }),
	members: z.object({ person_ids: z.array(z.string()).min(1).max(50) }),
	send: z.object({
		client_msg_id: z.uuid(),
		// An attachment can carry the message, so the text may be empty when something goes with it.
		content: text(MAX_MESSAGE_BYTES),
		reply_to_message_id: z.string().nullish(),
		attachment_ids: z.array(z.string()).max(10).optional(),
	}),
	edit: z.object({ content: text(MAX_MESSAGE_BYTES).refine((value) => value !== '') }),
	react: z.object({ emoji: z.string().min(1).max(8) }),
	read: z.object({ message_id: z.string().min(1) }),
};

export async function parse<S extends z.ZodType>(req: Request, schema: S): Promise<z.infer<S>> {
	const parsed = schema.safeParse(
		await req.json().catch((error: unknown) => {
			// A body cut off for being too large is a 413, not a body that failed to parse.
			if (error instanceof HttpError) throw error;
			return null;
		}),
	);
	if (!parsed.success) throw new HttpError(400, 'invalid_body');
	return parsed.data;
}

export const notFound = () => new HttpError(404, 'not_found');

/** A conversation the caller is in. An archived one has no members, so it reads as missing. */
export function memberConversation(ctx: RequestContext): Conversation {
	const id = ctx.params.id ?? '';
	const conversation = ctx.hub.conversations.get(id);
	if (conversation === null || !ctx.hub.conversations.isMember(id, ctx.person.id)) throw notFound();
	return conversation;
}

function group(ctx: RequestContext): Conversation {
	const conversation = memberConversation(ctx);
	if (conversation.kind !== 'room') throw new HttpError(409, 'not_a_group');
	return conversation;
}

/** A group people may rename, leave, delete and give a photo: not a standing room such as General. */
export function editableGroup(ctx: RequestContext): Conversation {
	const conversation = group(ctx);
	if (conversation.key !== null) throw new HttpError(409, 'standing_room');
	return conversation;
}

function memberMessage(ctx: RequestContext): Message {
	const message = ctx.hub.messages.get(ctx.params.id ?? '');
	if (message === null || !ctx.hub.conversations.isMember(message.conversation_id, ctx.person.id)) throw notFound();
	return message;
}

function ownMessage(ctx: RequestContext): Message {
	const message = memberMessage(ctx);
	if (message.author_id !== ctx.person.id) throw new HttpError(403, 'forbidden');
	return message;
}

/** Everyone named must exist and not be removed: a frozen person is not added to anything. */
function existingPeople(ctx: RequestContext, ids: string[]): void {
	for (const id of ids) {
		const person = ctx.hub.people.get(id);
		if (person === null || person.removed_at !== null) throw new HttpError(404, 'person_not_found');
	}
}

export function wireRoutes(present: Presenter): Router {
	const mine = (ctx: RequestContext, conversation: Conversation) => present.conversation(conversation, ctx.person.id);
	const announce = (ctx: RequestContext, conversation: Conversation) =>
		ctx.hub.bus.emit({
			type: 'conversation.changed',
			conversationId: conversation.id,
			audience: ctx.hub.conversations.memberIds(conversation.id),
		});
	const changed = (ctx: RequestContext, conversation: Conversation) => {
		announce(ctx, conversation);
		return { conversation: mine(ctx, conversation) };
	};

	return new Router()
		.get('/v1/me', ({ person }) => ({ person: present.person(person) }))
		.post('/v1/devices/:id/revoke', ({ hub, person, params }) => {
			const device = hub.devices.get(params.id ?? '');
			if (device === null || (device.person_id !== person.id && person.role !== 'admin')) throw notFound();
			if (!hub.devices.revoke(device.id)) throw notFound();
			return { ok: true };
		})

		.get('/v1/conversations', ({ hub, person }) => {
			// Newest activity first: the app keeps this order for its chat list and opens the first one.
			// Ids sort in the order they were made, so within one millisecond the later message or chat wins.
			const activity = (c: { id: string; created_at: string; last_message: { id: string; created_at: string } | null }) =>
				c.last_message ?? c;
			const conversations = hub.conversations.listFor(person.id).map((c) => present.conversation(c, person.id));
			conversations.sort((x, y) => {
				const [ax, ay] = [activity(x), activity(y)];
				return ay.created_at.localeCompare(ax.created_at) || ay.id.localeCompare(ax.id);
			});
			return { conversations };
		})
		.post('/v1/conversations', async (ctx) => {
			const { hub, person } = ctx;
			const body = await parse(ctx.req, schemas.createConversation);
			if (body.kind === 'dm') {
				existingPeople(ctx, [body.person_id]);
				const existing = hub.conversations.findDm(person.id, body.person_id);
				const dm = existing ?? hub.conversations.dm(person.id, body.person_id);
				if (!hub.conversations.isMember(dm.id, person.id)) throw notFound();
				return Response.json({ conversation: mine(ctx, dm) }, { status: existing === null ? 201 : 200 });
			}
			existingPeople(ctx, body.person_ids);
			const room = hub.conversations.createRoom({
				title: body.title ?? '',
				createdBy: person.id,
				memberIds: body.person_ids,
			});
			return Response.json({ conversation: mine(ctx, room) }, { status: 201 });
		})
		.get('/v1/conversations/:id', (ctx) => ({ conversation: mine(ctx, memberConversation(ctx)) }))
		.patch('/v1/conversations/:id', async (ctx) => {
			const conversation = editableGroup(ctx);
			const body = await parse(ctx.req, schemas.patchConversation);
			if (body.title !== undefined) ctx.hub.conversations.rename(conversation.id, body.title ?? '');
			return changed(ctx, ctx.hub.conversations.get(conversation.id)!);
		})
		.delete('/v1/conversations/:id', (ctx) => {
			const conversation = editableGroup(ctx);
			const audience = ctx.hub.conversations.memberIds(conversation.id);
			ctx.hub.conversations.archive(conversation.id);
			ctx.hub.bus.emit({ type: 'conversation.removed', conversationId: conversation.id, audience });
			return { ok: true };
		})
		.post('/v1/conversations/:id/members', async (ctx) => {
			const conversation = group(ctx);
			const body = await parse(ctx.req, schemas.members);
			existingPeople(ctx, body.person_ids);
			for (const id of body.person_ids) ctx.hub.conversations.addMember(conversation.id, id);
			return changed(ctx, conversation);
		})
		.delete('/v1/conversations/:id/members/me', (ctx) => {
			const conversation = editableGroup(ctx);
			ctx.hub.conversations.removeMember(conversation.id, ctx.person.id);
			ctx.hub.bus.emit({ type: 'conversation.removed', conversationId: conversation.id, audience: [ctx.person.id] });
			announce(ctx, conversation);
			return { ok: true };
		})

		.get('/v1/conversations/:id/messages', (ctx) => {
			const conversation = memberConversation(ctx);
			const asked = Number.parseInt(ctx.url.searchParams.get('limit') ?? '', 10);
			const limit = Math.min(Math.max(Number.isNaN(asked) ? 50 : asked, 1), PAGE_LIMIT);
			const before = ctx.url.searchParams.get('before') ?? undefined;
			const after = ctx.url.searchParams.get('after') ?? undefined;
			return { messages: ctx.hub.messages.list(conversation.id, { before, after, limit }).map((m) => present.message(m)) };
		})
		.post('/v1/conversations/:id/messages', async (ctx) => {
			const { hub, person } = ctx;
			const conversation = memberConversation(ctx);
			const body = await parse(ctx.req, schemas.send);
			const attachmentIds = body.attachment_ids ?? [];
			if (body.content.trim() === '' && attachmentIds.length === 0) throw new HttpError(400, 'empty_message');
			// A retry after a lost answer finds its first attempt instead of posting twice.
			const earlier = hub.messages.byClientId(person.id, body.client_msg_id);
			if (earlier !== null) {
				if (earlier.conversation_id !== conversation.id) throw new HttpError(409, 'client_msg_id_reused');
				return Response.json({ message: present.message(earlier) });
			}
			if (!hub.attachments.claimable(attachmentIds, conversation.id, person.id)) throw new HttpError(400, 'invalid_attachment');
			try {
				const message = hub.messages.send({
					conversationId: conversation.id,
					authorId: person.id,
					body: body.content,
					replyTo: body.reply_to_message_id,
					clientMsgId: body.client_msg_id,
					attachmentIds,
				});
				return Response.json({ message: present.message(message) }, { status: 201 });
			} catch (error) {
				// The same id arriving twice at once (from another process, say) loses to the unique index and gets the winner.
				const unique = (error as { code?: string }).code === 'SQLITE_CONSTRAINT_UNIQUE';
				const winner = unique ? hub.messages.byClientId(person.id, body.client_msg_id) : null;
				if (winner === null) throw error;
				if (winner.conversation_id !== conversation.id) throw new HttpError(409, 'client_msg_id_reused');
				return Response.json({ message: present.message(winner) });
			}
		})
		.post('/v1/conversations/:id/read', async (ctx) => {
			const conversation = memberConversation(ctx);
			const body = await parse(ctx.req, schemas.read);
			if (ctx.hub.messages.get(body.message_id)?.conversation_id !== conversation.id) throw notFound();
			const { changed: moved, effective } = ctx.hub.reads.markRead(conversation.id, ctx.person.id, body.message_id);
			if (moved) {
				ctx.hub.bus.emit({ type: 'read', conversationId: conversation.id, personId: ctx.person.id, messageId: effective });
			}
			return { last_read_message_id: effective };
		})
		.post('/v1/conversations/:id/unread', (ctx) => {
			const conversation = memberConversation(ctx);
			ctx.hub.reads.markUnread(conversation.id, ctx.person.id);
			ctx.hub.bus.emit({ type: 'conversation.changed', conversationId: conversation.id, audience: [ctx.person.id] });
			return { conversation: mine(ctx, conversation) };
		})

		.patch('/v1/messages/:id', async (ctx) => {
			const message = ownMessage(ctx);
			if (message.deleted_at !== null) throw new HttpError(409, 'message_deleted');
			const body = await parse(ctx.req, schemas.edit);
			return { message: present.message(ctx.hub.messages.edit(message.id, body.content)!) };
		})
		.delete('/v1/messages/:id', (ctx) => {
			const message = ownMessage(ctx);
			return { message: present.message(ctx.hub.messages.unsend(message.id)!) };
		})
		.post('/v1/messages/:id/reactions', async (ctx) => {
			const message = memberMessage(ctx);
			if (message.deleted_at !== null) throw new HttpError(409, 'message_deleted');
			const body = await parse(ctx.req, schemas.react);
			ctx.hub.reactions.toggle(message.id, ctx.person.id, body.emoji);
			return { message: present.message(ctx.hub.messages.announce(message.id)!) };
		})
		.get('/v1/search', ({ hub, person, url }) => {
			const query = (url.searchParams.get('q') ?? '').trim();
			if (query.length < 2) return { messages: [] };
			return { messages: hub.messages.search(person.id, query, 50).map((m) => present.message(m)) };
		});
}
