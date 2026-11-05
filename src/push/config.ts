import { readFileSync } from 'node:fs';
import { envString, type Env } from '../config';
import { ApnsProvider } from './apns';
import type { PushOptions, PushPreview } from './provider';

const APNS_VARS = ['HQ_APNS_KEY_FILE', 'HQ_APNS_KEY_ID', 'HQ_APNS_TEAM_ID', 'HQ_APNS_TOPIC'] as const;

/**
 * Push settings from the environment. With none of the four `HQ_APNS_*` values set it is silent and sending stays off. With
 * some set and some missing, it says which in one line and sending stays off. The key itself is never logged, only its id.
 */
export function pushFromEnv(env: Env, log: (line: string) => void = console.warn): PushOptions {
	const preview = previewFromEnv(env, log);
	const [file, keyId, teamId, topic] = APNS_VARS.map((name) => envString(env, name, ''));
	const missing = APNS_VARS.filter((name) => envString(env, name, '') === '');
	if (missing.length === APNS_VARS.length) return { provider: null, preview };
	const off = (why: string): PushOptions => {
		log(`[push] off: ${why}`);
		return { provider: null, preview };
	};
	if (missing.length > 0) return off(`${missing.join(', ')} not set`);
	let key: string;
	try {
		key = readFileSync(file!, 'utf8');
	} catch {
		return off('HQ_APNS_KEY_FILE cannot be read');
	}
	if (!/-----BEGIN PRIVATE KEY-----/.test(key))
		return off('HQ_APNS_KEY_FILE is not a .p8 key (a PEM that starts BEGIN PRIVATE KEY)');
	log(`[push] on: APNs, key id ${keyId}, ${preview} previews`);
	return { provider: new ApnsProvider({ key, keyId: keyId!, teamId: teamId!, topic: topic! }), preview };
}

/** A value that is not `full` hides: a typo must never send text to Apple that the host meant to keep back. */
function previewFromEnv(env: Env, log: (line: string) => void): PushPreview {
	const value = envString(env, 'HQ_PUSH_PREVIEW', 'full').toLowerCase();
	if (value === 'full' || value === 'hidden') return value;
	log(`[push] HQ_PUSH_PREVIEW must be full or hidden; using hidden`);
	return 'hidden';
}
