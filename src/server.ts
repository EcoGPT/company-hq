import { boot } from './boot';
import { envNumber, listenAddress, localUrl } from './config';

const { hq, config, provider } = boot(process.env, { startScheduler: true });
const server = Bun.serve({
	...listenAddress(process.env),
	// Room for an upload at its limit; the upload route enforces that limit itself.
	maxRequestBodySize: envNumber(process.env, 'HQ_MAX_BODY_MB', envNumber(process.env, 'HQ_MAX_UPLOAD_MB', 100) + 1) * 1024 * 1024,
	fetch: hq.fetch,
	websocket: hq.websocket,
});

// --- calls: a stop writes each call's audio still in memory before the process ends (up to 5 s) ---
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
	process.once(signal, () => {
		void server.stop(true);
		void hq.stop().finally(() => process.exit(0));
	});
}
// --- end calls ---

const apps = (config.apps ?? []).map((a) => a.slug).join(', ') || 'none';
console.log(`HQ is up on ${localUrl(process.env, server.port)}`);
console.log(
	`  @${config.assistant.handle} on ${provider.id}${provider.defaultModel ? ` (${config.assistant.model ?? provider.defaultModel})` : ''} · apps: ${apps}`,
);
if (provider.id === 'mock') {
	console.log('  No model yet, so the assistant just echoes. Run `bun hq setup` to pick one, or set HQ_LLM_* in .env.');
}
if (!hq.hub.people.list().some((p) => p.role === 'admin')) {
	console.log('  Nobody can sign in yet. Run `bun hq setup` to create the first admin.');
}
