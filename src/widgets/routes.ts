import type { WidgetWork } from '../apps/define';
import type { FeatureDeps } from '../hq';
import type { Person } from '../core/people';
import { bearer, HttpError, Router, type PublicContext } from '../http/router';
import { WidgetKeys, type WidgetCaller } from './store';

export const WIDGET_SUMMARY_VERSION = 1;

/** Who is asking: a widget key, or the bearer of a signed-in device. Nothing else reads widgets. */
type Caller = { person: Person; deviceId: string; viaWidgetKey: boolean };

function callerOf(ctx: PublicContext, keys: WidgetKeys): Caller {
	if (ctx.person !== null && ctx.keyId !== null) {
		// A script's or an MCP key is a bearer too, but it is no device: a widget key belongs to one.
		const device = ctx.hub.devices.byKey(ctx.keyId);
		if (device === null) throw new HttpError(403, 'device_bearer_required');
		return { person: ctx.person, deviceId: device.id, viaWidgetKey: false };
	}
	const token = bearer(ctx.req);
	const found: WidgetCaller | null = token === null ? null : keys.check(token);
	if (found === null) throw new HttpError(401, 'unauthorized');
	return { person: found.person, deviceId: found.deviceId, viaWidgetKey: true };
}

function summary(person: Person, work: WidgetWork) {
	return {
		version: WIDGET_SUMMARY_VERSION,
		generated_at: new Date().toISOString(),
		me: { id: person.id, name: person.name, avatar_id: person.avatar_id },
		work,
	};
}

/**
 * The routes of the Mac widgets. They are `public` to the router, which only knows api keys, and sign the caller in here: a
 * widget key never passes the router's own check, so it works on these three routes and nowhere else. Every answer, errors
 * included, says `no-store`.
 */
export function widgetRoutes(deps: FeatureDeps, work: (person: Person) => WidgetWork): Router {
	const keys = new WidgetKeys(deps.hub.db);
	const answer = (body: unknown, status = 200): Response =>
		body === null
			? new Response(null, { status, headers: { 'cache-control': 'no-store' } })
			: Response.json(body, { status, headers: { 'cache-control': 'no-store' } });
	const route =
		(handle: (caller: Caller, ctx: PublicContext) => Response) =>
		(ctx: PublicContext): Response => {
			try {
				return handle(callerOf(ctx, keys), ctx);
			} catch (error) {
				if (error instanceof HttpError) return answer({ error: error.message }, error.status);
				throw error;
			}
		};
	return new Router()
		.public(
			'POST',
			'/v1/widgets/key',
			route((caller) => {
				if (caller.viaWidgetKey) throw new HttpError(403, 'device_bearer_required');
				return answer({ key: keys.mint(caller.deviceId, caller.person.id) }, 201);
			}),
		)
		.public(
			'DELETE',
			'/v1/widgets/key',
			route((caller) => {
				keys.revokeDevice(caller.deviceId);
				return answer(null, 204);
			}),
		)
		.public(
			'GET',
			'/v1/widgets/summary',
			route((caller) => answer(summary(caller.person, work(caller.person)))),
		);
}
