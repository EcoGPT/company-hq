import type { z } from 'zod';
import type { Hub } from '../core/hub';
import type { KeyKind } from '../core/keys';
import type { Person } from '../core/people';
import { ProviderError } from '../llm/types';
import { errorMessage, ToolError } from '../tools/define';

export type Method = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
export type Access = 'public' | 'member' | 'admin';

export type RequestContext = {
	req: Request;
	url: URL;
	params: Record<string, string>;
	person: Person;
	/** The key this request signed in with; a device's bearer is one. */
	keyId: string;
	/** What kind of key that is: only a device's bearer is a person at their own app. */
	keyKind: KeyKind;
	hub: Hub;
};

export type PublicContext = Omit<RequestContext, 'person' | 'keyId' | 'keyKind'> & {
	person: Person | null;
	keyId: string | null;
	keyKind: KeyKind | null;
};

export type Handler<C = RequestContext> = (ctx: C) => unknown | Promise<unknown>;

export class HttpError extends Error {
	constructor(
		readonly status: number,
		message: string,
	) {
		super(message);
	}
}

/** The 405s `Router.handle` itself made, with the methods each lists: a handler's own 405 is its answer and is never in here. */
const UNMATCHED = new WeakMap<Response, Method[]>();

/** The methods a router's “this path takes only other methods” answer lists, or undefined for any other response. */
export function allowedMethods(response: Response): Method[] | undefined {
	return UNMATCHED.get(response);
}

export function methodNotAllowed(allowed: Method[]): Response {
	return Response.json({ error: 'method not allowed' }, { status: 405, headers: { allow: allowed.join(', ') } });
}

export function json(data: unknown, status = 200): Response {
	return Response.json(data, { status });
}

export async function readBody<S extends z.ZodType>(req: Request, schema: S): Promise<z.infer<S>> {
	let raw: unknown;
	try {
		raw = await req.json();
	} catch (error) {
		// A body cut off for being too large says so, rather than "not JSON".
		throw error instanceof HttpError ? error : new HttpError(400, 'body must be JSON');
	}
	const parsed = schema.safeParse(raw);
	if (!parsed.success) throw new HttpError(400, parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; '));
	return parsed.data;
}

export function bearer(req: Request): string | null {
	const header = req.headers.get('authorization');
	if (header !== null && header.toLowerCase().startsWith('bearer ')) return header.slice(7).trim();
	return null;
}

type Route = { method: Method; path: string; pattern: RegExp; keys: string[]; access: Access; handler: Handler<PublicContext> };

function compile(path: string): { pattern: RegExp; keys: string[] } {
	const keys: string[] = [];
	const source = path
		.replace(/\/+$/, '')
		.split('/')
		.map((part) => {
			if (part.startsWith(':')) {
				keys.push(part.slice(1));
				return '([^/]+)';
			}
			if (part === '*') {
				keys.push('rest');
				return '(.*)';
			}
			return part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
		})
		.join('/');
	return { pattern: new RegExp(`^${source}/?$`), keys };
}

export class Router {
	private readonly routes: Route[] = [];

	add(method: Method, path: string, handler: Handler, access: Exclude<Access, 'public'>): this;
	add(method: Method, path: string, handler: Handler<PublicContext>, access: 'public'): this;
	add(method: Method, path: string, handler: Handler<never>, access: Access): this {
		this.routes.push({ method, path, ...compile(path), access, handler: handler as Handler<PublicContext> });
		return this;
	}

	/** Every method and path added, in order. */
	list(): { method: Method; path: string }[] {
		return this.routes.map(({ method, path }) => ({ method, path }));
	}

	get(path: string, handler: Handler, access: Exclude<Access, 'public'> = 'member') {
		return this.add('GET', path, handler, access);
	}
	post(path: string, handler: Handler, access: Exclude<Access, 'public'> = 'member') {
		return this.add('POST', path, handler, access);
	}
	put(path: string, handler: Handler, access: Exclude<Access, 'public'> = 'member') {
		return this.add('PUT', path, handler, access);
	}
	patch(path: string, handler: Handler, access: Exclude<Access, 'public'> = 'member') {
		return this.add('PATCH', path, handler, access);
	}
	delete(path: string, handler: Handler, access: Exclude<Access, 'public'> = 'member') {
		return this.add('DELETE', path, handler, access);
	}
	public(method: Method, path: string, handler: Handler<PublicContext>) {
		return this.add(method, path, handler, 'public');
	}

	async handle(req: Request, hub: Hub): Promise<Response | null> {
		const url = new URL(req.url);
		let path: string;
		try {
			path = decodeURIComponent(url.pathname);
		} catch {
			return json({ error: 'malformed path' }, 400);
		}
		const allowed = new Set<Method>();
		for (const route of this.routes) {
			const match = route.pattern.exec(path);
			if (match === null) continue;
			if (route.method !== req.method) {
				allowed.add(route.method);
				continue;
			}
			const params = Object.fromEntries(route.keys.map((key, i) => [key, match[i + 1] ?? '']));
			try {
				const auth = hub.keys.check(bearer(req));
				const person = auth.ok ? auth.person : null;
				const keyId = auth.ok ? auth.keyId : null;
				const keyKind = auth.ok ? auth.kind : null;
				if (route.access !== 'public' && !auth.ok) throw new HttpError(401, auth.error);
				if (route.access === 'admin' && person?.role !== 'admin') throw new HttpError(403, 'admin_only');
				return toResponse(await route.handler({ req, url, params, person, keyId, keyKind, hub }));
			} catch (error) {
				if (error instanceof HttpError) return json({ error: error.message }, error.status);
				if (error instanceof ToolError) return json({ error: error.message }, 400);
				console.error(`[http] ${req.method} ${path}`, error);
				if (error instanceof ProviderError) return json({ error: errorMessage(error) }, 502);
				return json({ error: 'internal error' }, 500);
			}
		}
		if (allowed.size === 0) return null;
		const response = methodNotAllowed([...allowed]);
		UNMATCHED.set(response, [...allowed]);
		return response;
	}
}

const segments = (path: string) => path.replace(/\/+$/, '').split('/');

/** Whether some request path could match both patterns (`:name` is any one segment, `*` the rest), trailing slashes aside. */
function overlaps(a: string, b: string): boolean {
	const left = segments(a);
	const right = segments(b);
	for (let i = 0; i < Math.max(left.length, right.length); i++) {
		const x = left[i];
		const y = right[i];
		if (x === '*' || y === '*') return true;
		if (x === undefined || y === undefined) return false;
		if (!x.startsWith(':') && !y.startsWith(':') && x !== y) return false;
	}
	return true;
}

/**
 * Throws if, across the routers in this order, two routes with one method could take the same request: the same path, a
 * `:param` against another or a literal, or a `*`. The first would answer and the other would sit there looking like it works, or
 * a member's route would answer where an admin's was meant. Routes under `/apps/` are apps' own `api` routes, some of which
 * started before this check, so those only warn.
 */
export function assertUniqueRoutes(routers: Router[], warn: (line: string) => void = console.warn): void {
	const seen: { method: Method; path: string }[] = [];
	for (const route of routers.flatMap((router) => router.list())) {
		for (const other of seen) {
			if (other.method !== route.method || !overlaps(other.path, route.path)) continue;
			const message = `two routes overlap: ${route.method} ${other.path} and ${route.method} ${route.path}`;
			if (other.path.startsWith('/apps/') && route.path.startsWith('/apps/')) warn(`[http] ${message}`);
			else throw new Error(message);
		}
		seen.push(route);
	}
}

function toResponse(result: unknown): Response {
	if (result instanceof Response) return result;
	if (result === undefined) return new Response(null, { status: 204 });
	return json(result);
}
