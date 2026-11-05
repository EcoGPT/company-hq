import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import config from '../hq.config';
import { aiFromEnv } from './ai/env';
import { readVaultKey } from './connectors/vault';
import { envNumber, envString, type Env } from './config';
import { createHq, type HqOptions } from './hq';
import { providerFromEnv, resilienceFromEnv } from './llm';
import { pushFromEnv } from './push';
import { callsFromEnv } from './calls';

export function boot(env: Env = process.env, overrides: Partial<HqOptions> = {}) {
	const dbPath = envString(env, 'HQ_DB', 'data/hq.sqlite');
	if (dbPath !== ':memory:') mkdirSync(dirname(dbPath), { recursive: true });
	const hq = createHq({
		dbPath,
		provider: config.provider ?? providerFromEnv(env),
		resilience: resilienceFromEnv(env),
		ai: { ...aiFromEnv(env), ...config.ai },
		assistant: config.assistant,
		apps: config.apps,
		connectors: config.connectors,
		vaultKey: envString(env, 'HQ_VAULT_KEY', '') || readVaultKey(dbPath),
		publicUrl: env.HQ_PUBLIC_URL,
		inviteTtlDays: envNumber(env, 'HQ_INVITE_TTL_DAYS', 7),
		maxUploadBytes: envNumber(env, 'HQ_MAX_UPLOAD_MB', 100) * 1024 * 1024,
		uploadQuotaBytes: envNumber(env, 'HQ_UPLOAD_QUOTA_MB', 2048) * 1024 * 1024,
		trustProxy: ['1', 'true'].includes(envString(env, 'HQ_TRUST_PROXY', '')),
		// --- push: its environment settings are read here ---
		push: pushFromEnv(env),
		// --- end push ---
		// --- calls: its environment settings are read here ---
		calls: callsFromEnv(env),
		// --- end calls ---
		...overrides,
	});
	return { hq, config, provider: hq.provider, dbPath };
}
