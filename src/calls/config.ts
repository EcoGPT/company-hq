import { readFileSync } from 'node:fs';
import { envNumber, envString, type Env } from '../config';
import { CLOUDFLARE_REALTIME_URL, CloudflareRelay } from './cloudflare';
import type { CallRelay } from './relay';

export type CallsOptions = {
	/** Null turns calls off: `GET /v1/calls` still answers and `POST /v1/calls` is 503 `not_configured`. */
	relay: CallRelay | null;
	/** Devices seated in one call at once (default 20). */
	maxParticipants?: number;
	/** New calls one person may start in `startWindowMs` (default 10 in 10 minutes). */
	startsPerWindow?: number;
	startWindowMs?: number;
	/** Times one device may rejoin calls in `rejoinWindowMs` (default 20 a minute). */
	rejoinsPerWindow?: number;
	rejoinWindowMs?: number;
	clock?: () => number;
	/** Where the few log lines go (default `console.warn`). */
	log?: (line: string) => void;
};

const NAMES = ['HQ_CALLS_SFU_APP_ID', 'HQ_CALLS_SFU_SECRET', 'HQ_CALLS_SFU_SECRET_FILE', 'HQ_CALLS_SFU_URL'] as const;

/**
 * Calls from the environment. With none of the `HQ_CALLS_SFU_*` values set it is silent and calls are off. With some set and
 * some missing, it says which in one line and calls stay off. The secret is never logged.
 */
export function callsFromEnv(env: Env, log: (line: string) => void = console.warn): CallsOptions {
	const value = (name: string) => envString(env, name, '');
	const maxParticipants = Math.max(1, Math.floor(envNumber(env, 'HQ_CALLS_MAX_PARTICIPANTS', 20)));
	const off = (why: string): CallsOptions => {
		log(`[calls] off: ${why}`);
		return { relay: null, maxParticipants };
	};
	if (NAMES.every((name) => value(name) === '')) return { relay: null, maxParticipants };
	const appId = value('HQ_CALLS_SFU_APP_ID');
	const inline = value('HQ_CALLS_SFU_SECRET');
	const file = value('HQ_CALLS_SFU_SECRET_FILE');
	const missing = [
		...(appId === '' ? ['HQ_CALLS_SFU_APP_ID'] : []),
		...(inline === '' && file === '' ? ['HQ_CALLS_SFU_SECRET or HQ_CALLS_SFU_SECRET_FILE'] : []),
	];
	if (missing.length > 0) return off(`${missing.join(', ')} not set`);
	if (inline !== '' && file !== '') return off('set HQ_CALLS_SFU_SECRET or HQ_CALLS_SFU_SECRET_FILE, not both');
	let secret = inline;
	if (file !== '') {
		try {
			secret = readFileSync(file, 'utf8').trim();
		} catch {
			return off('HQ_CALLS_SFU_SECRET_FILE cannot be read');
		}
		if (secret === '') return off('HQ_CALLS_SFU_SECRET_FILE is empty');
	}
	const baseUrl = value('HQ_CALLS_SFU_URL') || CLOUDFLARE_REALTIME_URL;
	const url = URL.parse(baseUrl);
	if (url === null || (url.protocol !== 'https:' && url.protocol !== 'http:'))
		return off('HQ_CALLS_SFU_URL is not an http(s) URL');
	log(`[calls] on: Cloudflare Realtime app ${appId} at ${url.origin}`);
	return { relay: new CloudflareRelay({ appId, secret, baseUrl }), maxParticipants };
}
