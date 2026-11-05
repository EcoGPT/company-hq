import { dirname, join } from 'node:path';
import type { Server, WebSocketHandler } from 'bun';
import { createAi } from './ai/services';
import type { Ai, AiAdapters } from './ai/types';
import type { AppContext, AppDefinition, AssistantApi } from './apps/define';
import {
	appContext,
	appMigrations,
	appRouter,
	callsView,
	callTarget,
	isMeetingRoom,
	JSON_BODY_LIMIT,
	limitBody,
	type AppServices,
} from './apps/mount';
import { defineAssistant, type ResolvedAssistant } from './assistant/define';
import { Memory, MEMORY_MIGRATIONS, memoryTools } from './assistant/memory';
import { AssistantRunner } from './assistant/runner';
import { migrations as callMigrations, startCalls, type CallsOptions, type RecordingOptions } from './calls';
import { automationRoutes } from './automations/routes';
import { AUTOMATION_MIGRATIONS, Scheduler } from './automations/scheduler';
import { connectorTools, type ConnectorDefinition } from './connectors/define';
import { connectorRoutes } from './connectors/routes';
import { Vault, VAULT_MIGRATIONS } from './connectors/vault';
import { Hub } from './core/hub';
import type { Person } from './core/people';
import { coreRoutes } from './http/core-routes';
import { allowedMethods, assertUniqueRoutes, HttpError, json, methodNotAllowed, type Method } from './http/router';
import { resilient, type ResilienceOptions } from './llm/middleware';
import { echo } from './llm/mock';
import type { Provider } from './llm/types';
import { metered, Usage, USAGE_MIGRATIONS } from './llm/usage';
import { createMcp } from './mcp/server';
import { migrations as pushMigrations, startPush, type PushOptions } from './push';
import { createSocket, type SocketData, type SocketOptions } from './realtime/socket';
import { coreTools } from './tools/core-tools';
import { ToolRegistry } from './tools/registry';
import { migrations as widgetMigrations, widgetRoutes, widgetWork } from './widgets';
import { callerAddress, ENROLL_BODY_BYTES, enrollHandler } from './wire/enroll';
import { memberRoutes } from './wire/members';
import { mediaRoutes, uploadLimit } from './wire/media';
import { Presenter } from './wire/present';
import { RateLimiter } from './wire/rate-limit';
import { wireRoutes } from './wire/routes';

export type HqOptions = {
	dbPath?: string;
	provider?: Provider;
	resilience?: ResilienceOptions;
	ai?: AiAdapters;
	assistant?: ResolvedAssistant;
	apps?: AppDefinition[];
	connectors?: ConnectorDefinition[];
	vaultKey?: string;
	fetch?: typeof fetch;
	startScheduler?: boolean;
	/** Where uploads and pictures are kept. Defaults to a `files` folder beside the database. */
	filesDir?: string;
	/** Largest file one upload may carry. */
	maxUploadBytes?: number;
	/** Most bytes one person may have uploaded in all. Files are never deleted, so this is what stops a full disk. */
	uploadQuotaBytes?: number;
	/** Read the caller's address from the last X-Forwarded-For entry (set when a proxy you run sits in front). */
	trustProxy?: boolean;
	socket?: SocketOptions;
	/** Push notifications. Without a `provider` the routes still store device tokens and nothing is sent. Boot reads it from the environment (docs/push.md). */
	push?: PushOptions;
	/** Live calls. Without a `relay` calls are off: `POST /v1/calls` is 503 `not_configured`. Boot reads it from the environment (docs/calls.md). */
	calls?: CallsOptions;
	/** Call recordings: the stored-audio quota (default `HQ_CALLS_RECORDING_QUOTA_MB`) and one seat's longest recording. */
	callRecording?: RecordingOptions;
	publicUrl?: string;
	inviteTtlDays?: number;
	clock?: () => Date;
};

export type Hq = {
	hub: Hub;
	provider: Provider;
	ai: Ai;
	registry: ToolRegistry;
	apps: Map<string, AppContext>;
	scheduler: Scheduler;
	vault: Vault;
	usage: Usage;
	assistant: { definition: ResolvedAssistant; self: Person; memory: Memory; runner: AssistantRunner };
	fetch(req: Request, server?: Server<SocketData>): Promise<Response | undefined>;
	websocket: WebSocketHandler<SocketData>;
	/**
	 * Live connections: `broadcast` sends a frame to people, `onlineDevices` lists the devices with a socket open,
	 * `sweep` closes sockets that went silent. To send from code that has only the hub, emit a `frame` event on `hub.bus`.
	 */
	socket: Pick<ReturnType<typeof createSocket>, 'broadcast' | 'onlineDevices' | 'onClientFrame' | 'sweep'>;
	/** Live calls: `sweep` runs the liveness pass now, `idle` waits for relay requests sent in the background. */
	calls: { sweep(): void; idle(): Promise<void> };
	/** Stops everything; resolves once call audio still in memory is on disk (at most 5 s). Calling it again is harmless. */
	stop(): Promise<void>;
};

/** What a feature module outside core (push, widgets) is given to build its routes. */
export type FeatureDeps = { hub: Hub; present: Presenter; socket: Hq['socket'] };

const fallbackAssistant = () =>
	defineAssistant({ name: 'Assistant', handle: 'assistant', persona: 'You are a helpful teammate inside HQ.' });

const DEFAULT_MAX_UPLOAD_BYTES = 100 * 1024 * 1024;
const DEFAULT_UPLOAD_QUOTA_BYTES = 2048 * 1024 * 1024;
const ENROLL_ATTEMPTS = 20;
/** Wrong keys the whole server answers per window, from all addresses together. Correct keys are never counted. */
const ENROLL_SERVER_ATTEMPTS = 200;
const ENROLL_WINDOW_MS = 5 * 60_000;

export function normalizePublicUrl(raw: string | undefined): string | null {
	const value = raw?.trim();
	if (value === undefined || value === '') return null;
	const url = URL.parse(value);
	if (url === null || (url.protocol !== 'http:' && url.protocol !== 'https:')) {
		throw new Error(`HQ_PUBLIC_URL must be a full http(s) URL like https://hq.example.com: ${value}`);
	}
	return `${url.origin}${url.pathname.replace(/\/+$/, '')}`;
}

export function createHq(options: HqOptions = {}): Hq {
	const apps = options.apps ?? [];
	const connectors = options.connectors ?? [];
	const definition = options.assistant ?? fallbackAssistant();

	const dbPath = options.dbPath ?? ':memory:';
	/**
	 * Every migration beyond core's, each module's own list, spread here once. Ids are unique strings run in array order, and a
	 * module's ids start with its name (an app's get its slug in front in appMigrations), so a feature adds to its own list and
	 * never to this one. Ranges set aside for features not yet written, so they can be built side by side:
	 *   push/001+   widgets/001+   library/001+   calls/001+   (new, own the whole range)
	 *   tasks/003-009 planning     tasks/010-019 agent sessions
	 *   docs/004+   meetings/003+                        (after the ids they already have)
	 */
	const migrations = [
		...MEMORY_MIGRATIONS,
		...AUTOMATION_MIGRATIONS,
		...VAULT_MIGRATIONS,
		...USAGE_MIGRATIONS,
		...appMigrations(apps),
		...pushMigrations,
		...widgetMigrations,
		...callMigrations,
	];
	const hub = Hub.open(dbPath, migrations, options.filesDir ?? (dbPath === ':memory:' ? null : join(dirname(dbPath), 'files')));
	hub.publicUrl = normalizePublicUrl(options.publicUrl);
	if (options.inviteTtlDays !== undefined) hub.keys.inviteTtlDays = options.inviteTtlDays;

	const usage = new Usage(hub.db, options.clock);
	const meter = (p: Provider) => metered(p, usage);
	const provider =
		options.resilience === undefined
			? meter(options.provider ?? echo())
			: resilient(options.provider ?? echo(), { ...options.resilience, meter });
	const ai = createAi({ chat: provider, chatModel: definition.model, adapters: options.ai, usage });
	const self = hub.people.ensure({ name: definition.name, handle: definition.handle, kind: 'assistant' });
	const memory = new Memory(hub.db);
	const vault = new Vault(hub.db, options.vaultKey);
	const registry = toolRegistry({ ai, timezone: definition.timezone, memory, vault, apps, connectors, fetch: options.fetch });

	const services: AppServices = {
		assistant: assistantApi(hub, ai, definition, self),
		secrets: { has: (slug) => vault.has(slug), get: (slug) => vault.get(slug) },
		fetch: options.fetch,
		ai,
		registry,
	};
	const mounted = apps.map((app) => ({ app, context: appContext(hub, app.slug, services) }));
	const contexts = new Map(mounted.map(({ app, context }) => [app.slug, context]));

	const runner = new AssistantRunner({
		hub,
		provider,
		registry,
		assistant: definition,
		self,
		memory,
		briefings: () => apps.flatMap((app) => (app.briefing ? [{ app: app.name, text: app.briefing }] : [])),
	});
	runner.start();
	hub.general();

	const teardown = mounted.flatMap(({ app, context }) => {
		const stop = app.setup?.(context);
		return typeof stop === 'function' ? [stop] : [];
	});

	const scheduler = new Scheduler(hub, options.clock);
	for (const { app, context } of mounted) {
		for (const automation of app.automations ?? []) scheduler.add(app.slug, automation, context);
	}
	if (options.startScheduler === true) scheduler.start();

	const present = new Presenter(hub);
	const maxUploadBytes = options.maxUploadBytes ?? DEFAULT_MAX_UPLOAD_BYTES;
	const socket = createSocket(hub, present, options.socket);
	const features: FeatureDeps = { hub, present, socket };
	const push = startPush(features, options.push);
	// --- call recordings: a meeting call's recap goes to the first app with the hook (meetings) ---
	const recapper = mounted.find(({ app }) => app.callRecap !== undefined);
	const calls = startCalls(
		features,
		{
			find: (person, meetingId) => callTarget(mounted, person, meetingId),
			isMeetingRoom: (conversationId) => isMeetingRoom(mounted, conversationId),
		},
		options.calls,
		{
			ai,
			assistant: self,
			meetingRecap: recapper === undefined ? null : (input) => recapper.app.callRecap!(recapper.context, input),
			options: options.callRecording,
		},
	);
	// --- end call recordings ---
	// In this order, and the first router to answer a request wins. Apps come last, and no two routes may be able to take
	// one request (checked below), so an app's `/v1` route can neither answer in place of a core route nor sit behind one.
	const routers = [
		coreRoutes(present, (person) => {
			const apps = callsView(mounted, person);
			const live = calls.view(person);
			return { calls: [...live.calls, ...apps.calls], meetings: apps.meetings, ringing: [...live.ringing, ...apps.ringing] };
		}),
		memberRoutes(present),
		wireRoutes(present),
		mediaRoutes(present, { maxUploadBytes, uploadQuotaBytes: options.uploadQuotaBytes ?? DEFAULT_UPLOAD_QUOTA_BYTES }),
		push.routes,
		calls.routes,
		widgetRoutes(features, (person) => widgetWork(mounted, person)),
		automationRoutes(scheduler),
		connectorRoutes(connectors, vault, options.fetch),
		appRouter(apps, contexts),
	];
	assertUniqueRoutes(routers);
	const enroll = enrollHandler(
		hub,
		present,
		new RateLimiter(ENROLL_ATTEMPTS, ENROLL_WINDOW_MS),
		new RateLimiter(ENROLL_SERVER_ATTEMPTS, ENROLL_WINDOW_MS),
	);
	const mcp = createMcp(hub, registry, { name: 'hq-community', version: '0.1.0' });

	/**
	 * How much body a route may read. The server itself has to allow an upload's worth for the upload routes, so every other
	 * route is held to a small JSON body here (1 MB); enroll, which needs no sign-in, to 4 KB. App routes cap their own.
	 */
	function bodyLimit(method: string, pathname: string): { max: number; code: string } | null {
		if (pathname === '/v1/enroll') return { max: ENROLL_BODY_BYTES, code: 'payload_too_large' };
		if (pathname.startsWith('/apps/')) return null;
		const upload = uploadLimit(method, pathname, maxUploadBytes);
		return upload === null ? { max: JSON_BODY_LIMIT, code: 'payload_too_large' } : { max: upload, code: 'file_too_large' };
	}

	let stopping: Promise<void> | undefined;

	async function fetch(request: Request, server?: Server<SocketData>): Promise<Response | undefined> {
		const { pathname } = new URL(request.url);
		if (pathname === '/v1/ws')
			return server === undefined ? json({ error: 'upgrade_required' }, 426) : socket.upgrade(request, server);
		// A call's audio feed is a socket of its own kind.
		const feed = calls.feedPath(pathname);
		if (feed !== null) return calls.upgradeFeed(request, server, feed);
		try {
			// Read from the request the server gave us: the copy made to count its body is not one it can name an address for.
			const source = pathname === '/v1/enroll' ? callerAddress(request, server, options.trustProxy === true) : '';
			const limit = bodyLimit(request.method, pathname);
			const req = limit === null ? request : limitBody(request, limit.max, limit.code);
			if (pathname === '/v1/enroll') return await enroll(req, source);
			if (pathname === '/mcp') return await mcp(req);
			// A router answers 405 when the path is its own under other methods only; a later one may take this method. A
			// handler's own 405 is not that: it is the answer.
			const allowed = new Set<Method>();
			for (const router of routers) {
				const response = await router.handle(req, hub);
				if (response === null) continue;
				const methods = allowedMethods(response);
				if (methods === undefined) return response;
				for (const method of methods) allowed.add(method);
			}
			return allowed.size === 0 ? json({ error: 'not_found' }, 404) : methodNotAllowed([...allowed]);
		} catch (error) {
			if (error instanceof HttpError) return json({ error: error.message }, error.status);
			throw error;
		}
	}

	return {
		hub,
		provider,
		ai,
		registry,
		apps: contexts,
		scheduler,
		vault,
		usage,
		assistant: { definition, self, memory, runner },
		fetch,
		websocket: socket.websocket,
		socket,
		calls: { sweep: calls.sweep, idle: calls.idle },
		stop: () =>
			(stopping ??= (async () => {
				socket.stop();
				push.stop();
				const saving = calls.stop();
				runner.stop();
				scheduler.stop();
				for (const stop of teardown) stop();
				await saving;
				hub.files.dispose();
			})()),
	};
}

function toolRegistry(sources: {
	ai: Ai;
	timezone: string;
	memory: Memory;
	vault: Vault;
	apps: AppDefinition[];
	connectors: ConnectorDefinition[];
	fetch?: typeof fetch;
}): ToolRegistry {
	const registry = new ToolRegistry()
		.provide({ ai: sources.ai, timezone: sources.timezone })
		.register(coreTools)
		.register(memoryTools(sources.memory), 'assistant');
	for (const app of sources.apps) registry.register(app.tools ?? [], `apps/${app.slug}`);
	for (const connector of sources.connectors) {
		registry.register(connectorTools(connector, sources.vault, sources.fetch), `connectors/${connector.slug}`);
	}
	return registry;
}

function assistantApi(hub: Hub, ai: Ai, definition: ResolvedAssistant, self: Person): AssistantApi {
	return {
		self,
		post: (conversationId, body, metadata) => hub.messages.send({ conversationId, authorId: self.id, body, metadata }),
		ask: (prompt, options = {}) =>
			ai.chat(prompt, { system: options.system ?? definition.persona, temperature: definition.temperature }),
	};
}
