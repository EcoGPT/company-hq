import type { Ai } from '../ai/types';
import type { Hub } from '../core/hub';
import type { Person } from '../core/people';
import type { Migration } from '../db/database';
import { HttpError, Router } from '../http/router';
import type { ToolRegistry } from '../tools/registry';
import { adminDevice } from '../wire/members';
import type { AppContext, AppDefinition, AppRoute, AppSecrets, AssistantApi, CallsView, CallTarget } from './define';

/** The largest JSON body any route takes, unless it says otherwise. */
export const JSON_BODY_LIMIT = 1024 * 1024;

/**
 * The request with its body counted as it is read: over `max` is a 413 `payload_too_large`, up front when the length is
 * declared and otherwise as soon as the bytes pass the limit, so an oversized body is never held whole.
 */
export function limitBody(req: Request, max: number, code = 'payload_too_large'): Request {
	const declared = Number(req.headers.get('content-length') ?? NaN);
	if (Number.isFinite(declared) && declared > max) throw new HttpError(413, code);
	if (req.body === null) return req;
	let seen = 0;
	const capped = req.body.pipeThrough(
		new TransformStream<Uint8Array, Uint8Array>({
			transform(chunk, controller) {
				seen += chunk.byteLength;
				if (seen > max) controller.error(new HttpError(413, code));
				else controller.enqueue(chunk);
			},
		}),
	);
	const init: RequestInit & { duplex: 'half' } = { body: capped, duplex: 'half' };
	return new Request(req, init);
}

export function appMigrations(apps: AppDefinition[]): Migration[] {
	const slugs = new Set<string>();
	for (const app of apps) {
		if (slugs.has(app.slug)) throw new Error(`two apps share the slug ${app.slug}`);
		slugs.add(app.slug);
	}
	return apps.flatMap((app) => (app.migrations ?? []).map((m) => ({ ...m, id: `${app.slug}/${m.id}` })));
}

export type AppServices = {
	assistant: AssistantApi;
	secrets: AppSecrets;
	fetch?: typeof fetch;
	ai: Ai;
	registry: ToolRegistry;
};

export function appContext(
	hub: Hub,
	slug: string,
	{ assistant, secrets, fetch: fetchImpl = fetch, ai, registry }: AppServices,
): AppContext {
	return {
		slug,
		hub,
		assistant,
		secrets,
		fetch: fetchImpl,
		ai,
		tools: {
			has: (name) => registry.get(name) !== undefined,
			call: (name, args, options = {}) => {
				const caller = options.caller ?? assistant.self;
				const viewers =
					options.viewers ??
					(options.conversationId === undefined
						? undefined
						: hub.conversations.memberIds(options.conversationId).filter((id) => id !== caller.id));
				return registry.call(name, args, { hub, caller, conversationId: options.conversationId, viewers });
			},
		},
		emit: (name, data) => hub.bus.emit({ type: 'app.event', app: slug, name, data: data ?? null }),
	};
}

/** Paths the server answers before any router, so a route there could never be reached. */
const UNROUTED = ['/v1/enroll', '/v1/ws'];
/** Core's: it checks the caller is in the room, or sent the message, before anything under these is answered. */
const MEMBERSHIP_CHECKED = ['conversations', 'messages', 'attachments'];

/** The literal path of a `mount: 'v1'` route, or a startup error if it could not be served as core `/v1` routes are. */
function v1Path(slug: string, route: AppRoute): string {
	const where = `${slug}: ${route.method} ${route.path}`;
	const path = route.path.replace(/\/+$/, '');
	const [, v1, first, ...rest] = path.split('/');
	if (v1 !== 'v1' || first === undefined || [first, ...rest].some((part) => part === '' || part === '.' || part === '..')) {
		throw new Error(`${where} cannot be mounted at v1: it must be a plain path under /v1/`);
	}
	if (/[%\\]/.test(path) || UNROUTED.includes(path))
		throw new Error(`${where} cannot be mounted at v1: the server answers that path itself`);
	if (MEMBERSHIP_CHECKED.includes(first))
		throw new Error(`${where} cannot be mounted at v1: core checks membership under /v1/${first}`);
	if (route.access === 'public') throw new Error(`${where} cannot be public at v1: /v1 routes need a sign-in`);
	// The server caps every /v1 body before the route is reached, so a larger cap here would never apply.
	if (route.maxBodyBytes !== undefined && route.maxBodyBytes > JSON_BODY_LIMIT) {
		throw new Error(`${where} cannot take more than ${JSON_BODY_LIMIT} bytes at v1`);
	}
	return route.path;
}

/** What `GET /v1/calls` answers for `person`: the lists every app's `calls` hook adds, joined. With no hooks, three empty lists. */
export function callsView(mounted: { app: AppDefinition; context: AppContext }[], person: Person): CallsView {
	const view: CallsView = { calls: [], meetings: [], ringing: [] };
	for (const { app, context } of mounted) {
		if (app.calls === undefined) continue;
		try {
			// This app's part is built whole before any of it is added, so a hook that fails part way adds nothing.
			const added = app.calls(context, person);
			const part: CallsView = { calls: [], meetings: [], ringing: [] };
			for (const key of Object.keys(part) as (keyof CallsView)[]) {
				const list = added[key] ?? [];
				if (!Array.isArray(list)) throw new Error(`${key} is not a list`);
				part[key] = list;
			}
			for (const key of Object.keys(view) as (keyof CallsView)[]) view[key].push(...part[key]);
		} catch (error) {
			// The app drops calls, people and conversations together if this fails, so one app's bug must not break it.
			console.error(`[apps] ${app.slug} calls hook failed`, error);
		}
	}
	return view;
}

/** Where a meeting's call happens, from the first app with a `callTarget` hook; null when no app has one. */
export function callTarget(
	mounted: { app: AppDefinition; context: AppContext }[],
	person: Person,
	meetingId: string | null,
): CallTarget | null {
	const answering = mounted.find(({ app }) => app.callTarget !== undefined);
	return answering === undefined ? null : answering.app.callTarget!(answering.context, person, meetingId);
}

/** Whether any app says this room was opened for a meeting. */
export function isMeetingRoom(mounted: { app: AppDefinition; context: AppContext }[], conversationId: string): boolean {
	return mounted.some(({ app, context }) => {
		try {
			return app.isMeetingRoom?.(context, conversationId) === true;
		} catch (error) {
			// It runs after the relay session is made, so a failing app must not fail the join.
			console.error(`[apps] ${app.slug} failed on isMeetingRoom`, error);
			return false;
		}
	});
}

export function appRouter(apps: AppDefinition[], contexts: Map<string, AppContext>): Router {
	const router = new Router();
	router.get('/v1/apps', () =>
		apps.map((app) => ({
			slug: app.slug,
			name: app.name,
			description: app.description,
			icon: app.icon ?? null,
			tools: (app.tools ?? []).map((t) => t.name),
		})),
	);
	for (const app of apps) {
		const context = contexts.get(app.slug)!;
		for (const route of app.routes ?? []) {
			const path = route.mount === 'v1' ? v1Path(app.slug, route) : `/apps/${app.slug}/api/${route.path.replace(/^\/+/, '')}`;
			const max = route.maxBodyBytes ?? JSON_BODY_LIMIT;
			if (route.access === 'public') {
				router.public(route.method, path, (ctx) => route.handler({ ...ctx, req: limitBody(ctx.req, max), app: context }));
			} else {
				const deviceAdmin = route.mount === 'v1' && route.access === 'admin';
				router.add(
					route.method,
					path,
					(ctx) => {
						if (deviceAdmin) adminDevice(ctx);
						return route.handler({ ...ctx, req: limitBody(ctx.req, max), app: context });
					},
					route.access ?? 'member',
				);
			}
		}
	}
	return router;
}
