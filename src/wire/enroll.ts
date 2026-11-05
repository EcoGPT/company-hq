import { z } from 'zod';
import type { Hub } from '../core/hub';
import { INVITE_EXPIRED } from '../core/keys';
import { HttpError } from '../http/router';
import { Presenter, WIRE_VERSION } from './present';
import type { RateLimiter } from './rate-limit';

/** A real enroll body is under 300 bytes. */
export const ENROLL_BODY_BYTES = 4096;

/**
 * Who is calling, for the one route that has no bearer to say so. An IPv6 address is a whole /64 (one household or one
 * server gets that many), so the 18 quintillion addresses inside it are one caller; an IPv4-mapped one is its IPv4.
 * Behind a proxy you run (`trustProxy`), the last `X-Forwarded-For` entry is the caller. Called with the request the
 * server handed over: a copy made from it (a body with a size count, say) is not one the server can name an address for.
 */
export function callerAddress(
	req: Request,
	server: { requestIP(req: Request): { address: string } | null } | undefined,
	trustProxy: boolean,
): string {
	if (trustProxy) {
		const forwarded = req.headers.get('x-forwarded-for')?.split(',').at(-1)?.trim();
		if (forwarded) return addressGroup(forwarded);
	}
	const address = server?.requestIP(req)?.address;
	return address === undefined ? 'unknown' : addressGroup(address);
}

function addressGroup(address: string): string {
	const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(address);
	if (mapped !== null) return mapped[1]!;
	if (!address.includes(':')) return address;
	const [head = '', tail] = address.split('%')[0]!.split('::');
	const left = head === '' ? [] : head.split(':');
	const right = tail === undefined || tail === '' ? [] : tail.split(':');
	const groups =
		tail === undefined ? left : [...left, ...Array<string>(Math.max(0, 8 - left.length - right.length)).fill('0'), ...right];
	const first = groups.slice(0, 4).map((group) => Number.parseInt(group, 16));
	if (first.length < 4 || first.some((n) => !Number.isInteger(n) || n < 0 || n > 0xffff)) return address;
	return `${first.map((n) => n.toString(16)).join(':')}::/64`;
}

const body = z.object({
	// A sign-in key: from `bun hq setup` or `bun hq invite`, or one the app's Settings got for a new person.
	key: z.string().min(1),
	device_name: z.string().trim().min(1).max(80).optional(),
	// Accepted so the app can send it; the person already has a name, set by whoever added them.
	person_name: z.string().trim().min(1).max(80).optional(),
});

const reply = (data: unknown, status: number, headers: Record<string, string> = {}) =>
	Response.json(data, { status, headers: { 'cache-control': 'no-store', ...headers } });

/** Trades a sign-in key for a device of its own: a new bearer, shown once, that can be revoked alone. */
export function enrollHandler(hub: Hub, present: Presenter, limiter: RateLimiter, budget: RateLimiter) {
	return async (req: Request, source: string): Promise<Response> => {
		if (req.method !== 'POST') return Response.json({ error: 'method_not_allowed' }, { status: 405, headers: { allow: 'POST' } });
		const parsed = body.safeParse(
			await req.json().catch((error: unknown) => {
				if (error instanceof HttpError) throw error;
				return null;
			}),
		);
		if (!parsed.success) return reply({ error: 'invalid_body' }, 400);
		// The key is checked first and a good one is always let in. Only failed tries count: against the address, and
		// (once the address is within its own limit) against one budget for the whole server, which is what stops guessing
		// from many addresses. Junk can slow wrong keys down but never locks a real person out.
		const auth = hub.keys.checkSignIn(parsed.data.key);
		if (!auth.ok) {
			if (auth.error === INVITE_EXPIRED) return reply({ error: INVITE_EXPIRED }, 401);
			const retryAfter = limiter.admit(source) || budget.admit('everyone');
			if (retryAfter > 0) {
				return reply({ error: 'rate_limited', retry_after: retryAfter }, 429, { 'retry-after': String(retryAfter) });
			}
			const anyone = hub.people.list().some((p) => p.kind !== 'assistant');
			return anyone ? reply({ error: 'invalid_key' }, 401) : reply({ error: 'not_configured' }, 503);
		}
		const { device, bearer } = hub.devices.enroll(auth.person.id, parsed.data.device_name ?? 'Device');
		return reply({ bearer, device_id: device.id, person: present.person(auth.person), wire_version: WIRE_VERSION }, 201);
	};
}
