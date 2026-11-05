import { z } from 'zod';
import type { Hub } from '../core/hub';
import { now } from '../core/ids';
import type { Person } from '../core/people';
import { HttpError, Router, type RequestContext } from '../http/router';
import type { Presenter } from './present';
import { parse } from './routes';

const schemas = {
	// The server makes every key. A `key` an older app still sends is refused, not ignored, so nobody believes it was used.
	mint: z.object({ person_name: z.string().trim().min(1).max(80), key: z.unknown().optional() }),
	role: z.object({ is_admin: z.boolean() }),
	mcpKey: z.object({ label: z.string().trim().min(1).max(80), scopes: z.array(z.string()).min(1).max(5) }),
};

/**
 * `read,send` is what the app asks for, and it is the person's whole access except admin work: this server has no narrower
 * scopes, so a key can do everything its holder can in rooms they are in, and nothing that changes who may sign in.
 */
const SCOPES = ['read', 'send'];

/**
 * Admin work on who may sign in is done from a signed-in device by someone who is an admin right now. An MCP key or a script
 * key acts as its person everywhere else, but an agent holding one cannot add people, promote them or cut them off. Called
 * again once the body has been read, because the admin may have been demoted or removed while it arrived.
 */
export function adminDevice(ctx: RequestContext): void {
	const actor = ctx.hub.people.get(ctx.person.id);
	if (
		ctx.keyKind !== 'device' ||
		actor === null ||
		actor.role !== 'admin' ||
		actor.removed_at !== null ||
		!ctx.hub.keys.isActive(ctx.keyId)
	) {
		throw new HttpError(403, 'admin_only');
	}
}

/** The company must always have someone who signs in and can run it. */
function keepsAnAdmin(ctx: RequestContext, leaving: Person): void {
	if (!ctx.hub.people.activeAdmins().some((p) => p.id !== leaving.id)) throw new HttpError(409, 'last_admin');
}

/** A person who can be managed: someone who signs in, not the assistant or a service. */
function human(ctx: RequestContext): Person {
	const target = ctx.hub.people.get(ctx.params.id ?? '');
	if (target === null || target.kind !== 'human') throw new HttpError(404, 'person_not_found');
	return target;
}

/** Everything Settings does to keys and members. The admin-only routes refuse everyone else with `admin_only`. */
export function memberRoutes(present: Presenter): Router {
	const announce = (hub: Hub, id: string) => {
		const person = hub.people.get(id)!;
		hub.bus.emit({ type: 'person.updated', person });
		return { person: present.person(person) };
	};

	return new Router()
		.post(
			'/v1/keys',
			async (ctx) => {
				adminDevice(ctx);
				const { hub } = ctx;
				const body = await parse(ctx.req, schemas.mint);
				adminDevice(ctx);
				if (body.key !== undefined) throw new HttpError(400, 'key_not_allowed');
				// This adds a new person and nobody else. Someone who exists, the assistant included (by name or handle), is
				// never given a second key from here: that is the operator's `bun hq invite <handle>`.
				const named = hub.people.named(body.person_name);
				if (named.some((p) => p.removed_at === null)) throw new HttpError(409, 'person_exists');
				// A removed person is brought back by restoring them; a key alone would not undo that.
				if (named.length > 0) throw new HttpError(409, 'person_removed');
				const { person, secret } = hub.db.transaction(() => {
					const created = hub.people.create({ name: body.person_name, handle: hub.people.freeHandle(body.person_name) });
					hub.conversations.addMember(hub.general().id, created.id);
					return { person: created, secret: hub.keys.mint(created.id, 'invite').secret };
				})();
				hub.bus.emit({ type: 'person.updated', person });
				return Response.json({ ok: true, person_name: body.person_name, key: secret }, { status: 201 });
			},
			'admin',
		)
		.post(
			'/v1/people/:id/role',
			async (ctx) => {
				adminDevice(ctx);
				const body = await parse(ctx.req, schemas.role);
				adminDevice(ctx);
				const target = human(ctx);
				// Not your own seat: that is what keeps the company from ending up with no admin.
				if (target.id === ctx.person.id) throw new HttpError(409, 'not_yourself');
				if (target.removed_at !== null) throw new HttpError(409, 'person_removed');
				if (!body.is_admin && target.role === 'admin') keepsAnAdmin(ctx, target);
				ctx.hub.people.setRole(target.id, body.is_admin ? 'admin' : 'member');
				return announce(ctx.hub, target.id);
			},
			'admin',
		)
		.post(
			'/v1/people/:id/remove',
			(ctx) => {
				adminDevice(ctx);
				const target = human(ctx);
				if (target.id === ctx.person.id) throw new HttpError(409, 'not_yourself');
				if (target.removed_at !== null) throw new HttpError(409, 'already_removed');
				if (target.role === 'admin') keepsAnAdmin(ctx, target);
				// Freezing: the row, their messages and their place in rooms stay; what ends is access, the same second. An
				// admin who comes back is a member, and is promoted again by someone who means it.
				ctx.hub.people.setRemoved(target.id, now());
				ctx.hub.people.setRole(target.id, 'member');
				ctx.hub.keys.revokeAll(target.id);
				return announce(ctx.hub, target.id);
			},
			'admin',
		)
		.post(
			'/v1/people/:id/restore',
			(ctx) => {
				adminDevice(ctx);
				const target = human(ctx);
				if (target.removed_at === null) throw new HttpError(409, 'not_removed');
				// Their keys stay revoked: coming back takes a fresh one.
				ctx.hub.people.setRemoved(target.id, null);
				return announce(ctx.hub, target.id);
			},
			'admin',
		)

		.get('/v1/mcp-keys', ({ hub, person }) => ({
			keys: hub.keys
				.list(person.id)
				.filter((key) => key.kind === 'mcp')
				.reverse()
				.map((key) => ({
					id: key.id,
					label: key.label,
					scopes: SCOPES.join(','),
					created_at: key.created_at,
					revoked_at: key.revoked_at,
					last_used_at: key.last_used_at,
				})),
		}))
		.post('/v1/mcp-keys', async (ctx) => {
			const body = await parse(ctx.req, schemas.mcpKey);
			if (new Set(body.scopes).size !== SCOPES.length || !SCOPES.every((scope) => body.scopes.includes(scope))) {
				throw new HttpError(400, 'scope_unsupported');
			}
			const { key, secret } = ctx.hub.keys.mint(ctx.person.id, 'mcp', { label: body.label });
			return Response.json({ id: key.id, key: secret, label: key.label }, { status: 201 });
		})
		.delete('/v1/mcp-keys/:id', ({ hub, person, params }) => {
			const key = hub.keys.get(params.id ?? '');
			// Yours, or anyone's if you are an admin. Revoking twice, or a key that is not an MCP key, is not found.
			if (key === null || key.kind !== 'mcp' || (key.person_id !== person.id && person.role !== 'admin')) {
				throw new HttpError(404, 'not_found');
			}
			if (!hub.keys.revoke(key.id)) throw new HttpError(404, 'not_found');
			return { ok: true };
		});
}
