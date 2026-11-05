import { TooLarge } from '../core/files';
import { newId } from '../core/ids';
import { HttpError, Router, type RequestContext } from '../http/router';
import type { Presenter } from './present';
import { editableGroup, memberConversation, notFound } from './routes';

const MAX_AVATAR_BYTES = 5 * 1024 * 1024;
/** Uploads a person may have made that no sent message holds yet. */
const MAX_UNSENT_UPLOADS = 20;

const startsWith = (head: Uint8Array, at: number, text: string) => [...text].every((c, i) => head[at + i] === c.charCodeAt(0));
const HEIC_BRANDS = new Set(['heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1']);

/** Pictures people may set: only formats the app shows, and never SVG (which is a page). Each is checked by its first bytes. */
const AVATAR_TYPES = {
	'image/png': { extension: 'png', matches: (h: Uint8Array) => h[0] === 0x89 && startsWith(h, 1, 'PNG') },
	'image/jpeg': { extension: 'jpg', matches: (h: Uint8Array) => h[0] === 0xff && h[1] === 0xd8 && h[2] === 0xff },
	'image/webp': { extension: 'webp', matches: (h: Uint8Array) => startsWith(h, 0, 'RIFF') && startsWith(h, 8, 'WEBP') },
	'image/heic': {
		extension: 'heic',
		matches: (h: Uint8Array) =>
			startsWith(h, 4, 'ftyp') && HEIC_BRANDS.has(String.fromCharCode(h[8] ?? 0, h[9] ?? 0, h[10] ?? 0, h[11] ?? 0)),
	},
} as const;

/** The routes that carry a file, and how big a body each may have. Every other route takes a small JSON body. */
export function uploadLimit(method: string, pathname: string, maxUploadBytes: number): number | null {
	if (method === 'POST' && /^\/v1\/conversations\/[^/]+\/attachments\/?$/.test(pathname)) return maxUploadBytes;
	if (method === 'PUT' && (pathname === '/v1/me/avatar' || /^\/v1\/conversations\/[^/]+\/image\/?$/.test(pathname))) {
		return MAX_AVATAR_BYTES;
	}
	return null;
}

/** A body cut off at a limit, by the counting reader or by the file store. */
const overLimit = (error: unknown) => error instanceof TooLarge || (error instanceof HttpError && error.status === 413);

// A right-to-left override makes a name read backwards (invoice + exe.pdf looks like a pdf), and control characters can hide.
const INVISIBLE = /[\p{Cc}\p{Bidi_Control}]/gu;

/** Header values are ASCII, so the app percent-encodes the name. */
function fileNameOf(header: string | null): string {
	let name = 'file';
	if (header !== null) {
		try {
			name = decodeURIComponent(header);
		} catch {
			name = header;
		}
	}
	return (
		name
			.replaceAll(INVISIBLE, '')
			.trim()
			.replaceAll(/[/\\:*?"<>|]/g, '_')
			.slice(0, 120) || 'file'
	);
}

// Types a browser would run or render in the page's own origin. They are handed back as opaque bytes.
const ACTIVE_CONTENT =
	/^(text\/html|application\/xhtml|image\/svg|text\/xml|application\/xml|text\/javascript|application\/javascript)/i;

function downloadHeaders(fileName: string, contentType: string): Record<string, string> {
	const ascii = fileName.replaceAll(/[^\x20-\x7e]/g, '_').replaceAll('"', "'");
	return {
		'content-type': ACTIVE_CONTENT.test(contentType) ? 'application/octet-stream' : contentType,
		'content-disposition': `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(fileName)}`,
		'x-content-type-options': 'nosniff',
		'content-security-policy': "default-src 'none'; sandbox",
		'cache-control': 'private, max-age=31536000, immutable',
	};
}

function positive(header: string | null): number | null {
	const value = Number(header);
	return Number.isInteger(value) && value > 0 ? value : null;
}

export function mediaRoutes(present: Presenter, limits: { maxUploadBytes: number; uploadQuotaBytes: number }): Router {
	const { maxUploadBytes, uploadQuotaBytes } = limits;
	// Uploads still arriving, per person: they are not in the database until they finish, so they are counted here, and
	// each holds back the room it may still fill, so uploads at once cannot together go past the quota.
	const arriving = new Map<string, { uploads: number; reserved: number }>();
	const avatarPath = (
		ctx: RequestContext,
		kind: 'people' | 'conversations',
		ownerId: string,
		avatarId: string,
		extension: string,
	) => ctx.hub.files.path('avatars', kind, ownerId, `${avatarId}.${extension}`);

	/**
	 * Streams a raw image body to disk under a fresh id (stopping at 5 MiB), then checks its first bytes. `commit` points the
	 * owner at the new picture. The check, `commit` and the clean-up run the moment the file is in place, with nothing able to
	 * run between, so a second upload at once never sees this one half done, and a picture still arriving is never deleted.
	 */
	async function saveAvatar(
		ctx: RequestContext,
		kind: 'people' | 'conversations',
		ownerId: string,
		commit: (avatarId: string) => void,
	): Promise<void> {
		const type = AVATAR_TYPES[(ctx.req.headers.get('content-type') ?? '') as keyof typeof AVATAR_TYPES];
		if (type === undefined) throw new HttpError(415, 'unsupported_type');
		if (ctx.req.body === null) throw new HttpError(400, 'empty_file');
		if (Number(ctx.req.headers.get('content-length') ?? 0) > MAX_AVATAR_BYTES) throw new HttpError(413, 'file_too_large');
		const avatarId = newId();
		const path = avatarPath(ctx, kind, ownerId, avatarId, type.extension);
		const { files } = ctx.hub;
		let size: number;
		try {
			size = await files.save(path, ctx.req.body, MAX_AVATAR_BYTES, (saved) => {
				if (!type.matches(files.head(saved, 16))) {
					files.remove(saved);
					throw new HttpError(415, 'unsupported_type');
				}
				commit(avatarId);
				files.keepOnly(saved);
			});
		} catch (error) {
			throw overLimit(error) ? new HttpError(413, 'file_too_large') : error;
		}
		if (size === 0) throw new HttpError(400, 'empty_file');
	}

	/** Only the current avatar is served, so a replaced picture cannot be fetched again by its old id. */
	function serveAvatar(ctx: RequestContext, kind: 'people' | 'conversations', ownerId: string, current: string | null) {
		if (current === null || current !== ctx.params.avatarId) throw notFound();
		for (const [type, { extension }] of Object.entries(AVATAR_TYPES)) {
			const file = Bun.file(avatarPath(ctx, kind, ownerId, current, extension));
			if (file.size > 0) {
				return new Response(file, {
					headers: {
						'content-type': type,
						'x-content-type-options': 'nosniff',
						'cache-control': 'private, max-age=31536000, immutable',
					},
				});
			}
		}
		throw notFound();
	}

	function announcePerson(ctx: RequestContext) {
		const person = ctx.hub.people.get(ctx.person.id)!;
		ctx.hub.bus.emit({ type: 'person.updated', person });
		return present.person(person);
	}

	function announceConversation(ctx: RequestContext, id: string) {
		const conversation = ctx.hub.conversations.get(id)!;
		ctx.hub.bus.emit({ type: 'conversation.changed', conversationId: id, audience: ctx.hub.conversations.memberIds(id) });
		return { conversation: present.conversation(conversation, ctx.person.id) };
	}

	return new Router()
		.post('/v1/conversations/:id/attachments', async (ctx) => {
			const conversation = memberConversation(ctx);
			if (ctx.req.body === null) throw new HttpError(400, 'empty_file');
			// Nothing is ever deleted, so what a person may keep is limited: unsent files, and bytes in all.
			const who = ctx.person.id;
			const held = arriving.get(who) ?? { uploads: 0, reserved: 0 };
			if (ctx.hub.attachments.unattached(who) + held.uploads >= MAX_UNSENT_UPLOADS) throw new HttpError(429, 'too_many_uploads');
			const room = Math.max(0, uploadQuotaBytes - ctx.hub.attachments.usedBytes(who) - held.reserved);
			// Refuse on the declared length before reading anything; the stream is counted too, for senders that do not declare one.
			const declared = Number(ctx.req.headers.get('content-length') ?? 0);
			if (declared > maxUploadBytes) throw new HttpError(413, 'file_too_large');
			if (declared > room) throw new HttpError(413, 'quota_exceeded');
			// What this upload may still add is held for it from here (nothing awaits between the sum and the hold) until it
			// ends, so each upload sees the room the others left. A declared length holds just that; otherwise the most it may be.
			const hold = Math.min(maxUploadBytes, room, declared > 0 ? declared : maxUploadBytes);
			if (hold === 0) throw new HttpError(413, 'quota_exceeded');
			held.uploads += 1;
			held.reserved += hold;
			arriving.set(who, held);
			const id = newId();
			const path = ctx.hub.files.path('attachments', conversation.id, id);
			let size: number;
			try {
				size = await ctx.hub.files.save(path, ctx.req.body, hold);
			} catch (error) {
				if (!overLimit(error)) throw error;
				throw new HttpError(413, room < maxUploadBytes ? 'quota_exceeded' : 'file_too_large');
			} finally {
				held.uploads -= 1;
				held.reserved -= hold;
				if (held.uploads === 0) arriving.delete(who);
			}
			if (size === 0) throw new HttpError(400, 'empty_file');
			const attachment = ctx.hub.attachments.create({
				id,
				conversation_id: conversation.id,
				uploader_id: ctx.person.id,
				file_name: fileNameOf(ctx.req.headers.get('x-hq-file-name')),
				content_type: ctx.req.headers.get('content-type') ?? 'application/octet-stream',
				byte_size: size,
				width: positive(ctx.req.headers.get('x-hq-image-width')),
				height: positive(ctx.req.headers.get('x-hq-image-height')),
			});
			return Response.json({ attachment: present.attachment(attachment) }, { status: 201 });
		})
		.get('/v1/attachments/:id', (ctx) => {
			const { hub, person } = ctx;
			const attachment = hub.attachments.get(ctx.params.id ?? '');
			if (attachment === null || !hub.conversations.isMember(attachment.conversation_id, person.id)) throw notFound();
			// Until a message claims it, an upload is its uploader's alone; once unsent, nobody's.
			if (
				attachment.message_id === null
					? attachment.uploader_id !== person.id
					: hub.messages.get(attachment.message_id)?.deleted_at !== null
			) {
				throw notFound();
			}
			const file = Bun.file(hub.files.path('attachments', attachment.conversation_id, attachment.id));
			if (file.size === 0) throw notFound();
			return new Response(file, { headers: downloadHeaders(attachment.file_name, attachment.content_type) });
		})

		.put('/v1/me/avatar', async (ctx) => {
			await saveAvatar(ctx, 'people', ctx.person.id, (avatarId) => ctx.hub.people.setAvatar(ctx.person.id, avatarId));
			return { person: announcePerson(ctx) };
		})
		.delete('/v1/me/avatar', (ctx) => {
			ctx.hub.people.setAvatar(ctx.person.id, null);
			ctx.hub.files.empty('avatars', 'people', ctx.person.id);
			return { person: announcePerson(ctx) };
		})
		.put('/v1/conversations/:id/image', async (ctx) => {
			const conversation = editableGroup(ctx);
			await saveAvatar(ctx, 'conversations', conversation.id, (avatarId) =>
				ctx.hub.conversations.setAvatar(conversation.id, avatarId),
			);
			return announceConversation(ctx, conversation.id);
		})
		.delete('/v1/conversations/:id/image', (ctx) => {
			const conversation = editableGroup(ctx);
			ctx.hub.conversations.setAvatar(conversation.id, null);
			ctx.hub.files.empty('avatars', 'conversations', conversation.id);
			return announceConversation(ctx, conversation.id);
		})
		.get('/v1/avatars/people/:personId/:avatarId', (ctx) => {
			const owner = ctx.hub.people.get(ctx.params.personId ?? '');
			if (owner === null) throw notFound();
			return serveAvatar(ctx, 'people', owner.id, owner.avatar_id);
		})
		.get('/v1/avatars/conversations/:id/:avatarId', (ctx) => {
			const conversation = memberConversation(ctx);
			return serveAvatar(ctx, 'conversations', conversation.id, conversation.avatar_id);
		});
}
