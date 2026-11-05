import type { FeatureDeps } from '../hq';
import type { Migration } from '../db/database';
import type { Router } from '../http/router';
import { pushRoutes } from './routes';
import { PushSender } from './sender';
import { PUSH_MIGRATIONS, PushTokens } from './store';
import type { PushOptions } from './provider';

export { pushFromEnv } from './config';
export { ApnsProvider, type ApnsOptions } from './apns';
export type { PushMessage, PushOptions, PushOutcome, PushPreview, PushProvider, PushResult, PushTarget } from './provider';

/** Push notifications. Ids start at `push/001`. */
export const migrations: Migration[] = PUSH_MIGRATIONS;

/**
 * The device-token routes, always, and the sender when `options.provider` is set. With no provider tokens are stored and
 * nothing listens on the bus, so a host who configures nothing sees no change.
 */
export function startPush(
	deps: FeatureDeps,
	options: PushOptions | undefined,
): { routes: Router; stop(): void; idle(): Promise<void> } {
	const tokens = new PushTokens(deps.hub.db);
	const sender = options?.provider == null ? null : new PushSender(deps.hub, tokens, options.provider, options).start();
	return {
		routes: pushRoutes(tokens),
		stop: () => sender?.stop(),
		idle: () => sender?.idle() ?? Promise.resolve(),
	};
}
