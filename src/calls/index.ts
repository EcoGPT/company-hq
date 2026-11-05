import type { Server } from 'bun';
import type { Ai } from '../ai/types';
import type { Migration } from '../db/database';
import type { Router } from '../http/router';
import type { Person } from '../core/people';
import type { FeatureDeps } from '../hq';
import type { SocketData } from '../realtime/socket';
import type { CallsOptions } from './config';
import { CallRecaps, type MeetingRecap } from './recap';
import { Recorder, STOP_WAIT_MS, type RecordingOptions } from './recording';
import { CallRecords } from './recording-routes';
import { RECORDING_MIGRATIONS, RecordingStore } from './recording-store';
import { callRoutes } from './routes';
import { Calls, TICK_MS, type CallTargets } from './service';
import { CALL_MIGRATIONS } from './store';
import { CallFeeds } from './transcribe-feed';
import { CallTranscripts } from './transcribe';

export { callsFromEnv, type CallsOptions } from './config';
export { CloudflareRelay, type CloudflareOptions } from './cloudflare';
export { RelayError, type CallRelay, type RelayErrorCode, type RelayTrack, type SessionDescription } from './relay';
export type { CallTargets } from './service';
export type { MeetingRecap } from './recap';
export { recordingQuotaBytes, type RecordingOptions } from './recording';

/** Live calls (`calls/001`), then their recordings and transcripts (`calls/002`). */
export const migrations: Migration[] = [...CALL_MIGRATIONS, ...RECORDING_MIGRATIONS];

/** What recording, transcribing and recapping a call need beyond the call itself. */
export type CallRecordDeps = { ai: Ai; assistant: Person; meetingRecap: MeetingRecap; options?: RecordingOptions };

export type CallsFeature = {
	routes: Router;
	/** What core adds to `GET /v1/calls`: nothing while calls are off. */
	view(person: Person): { calls: unknown[]; ringing: unknown[] };
	/** The call id when `pathname` is a call's audio feed. */
	feedPath(pathname: string): string | null;
	/** Opens a call's audio feed, or answers why not. */
	upgradeFeed(req: Request, server: Server<SocketData> | undefined, callId: string): Response | undefined;
	/** Runs the 15 s liveness pass now. */
	sweep(): void;
	/** Resolves once the relay requests, audio writes and transcripts started so far have finished. */
	idle(): Promise<void>;
	/** Stops, writing every call's audio still in memory first (waiting at most `stopWaitMs`, 5 s). */
	stop(): Promise<void>;
};

/**
 * The call routes, always. With no relay `POST /v1/calls` is 503 `not_configured` and `GET /v1/calls` lists no calls.
 * Seats live in the database, so a restart sweeps the ones that went silent while it was down.
 */
export function startCalls(
	deps: FeatureDeps,
	targets: CallTargets,
	options: CallsOptions | undefined,
	record: CallRecordDeps,
): CallsFeature {
	const { hub, socket } = deps;
	const calls = new Calls(hub, options?.relay ?? null, targets, options);
	const log = options?.log ?? console.warn;
	const recordings = new RecordingStore(hub.db);
	const recorder = new Recorder(hub.files, recordings, () => calls.now(), log, record.options);
	const recaps = new CallRecaps(hub, record.ai, record.assistant, recordings, record.meetingRecap, () => calls.now(), log);
	const transcripts = new CallTranscripts(
		hub.files,
		record.ai,
		calls.store,
		recordings,
		recorder,
		recaps,
		() => calls.now(),
		log,
	);
	const feeds = new CallFeeds(hub, calls, recorder);
	const records = new CallRecords(hub, calls, recordings, transcripts);
	calls.seatLeft.add((callId, deviceId) => feeds.left(callId, deviceId));
	transcripts.recover();
	const stopFrames = socket.onClientFrame('call_heartbeat', ({ deviceId }, frame) => {
		if (typeof frame.call_id === 'string') calls.heartbeat(frame.call_id, deviceId);
	});
	const stopBus = hub.bus.on((event) => {
		if (event.type === 'key.revoked') calls.signedOut(event.keyId);
		// Someone who left or lost a room gives up their seat in its call now, not at the next tick.
		else if (event.type === 'conversation.removed' || event.type === 'conversation.changed') calls.sweep();
		// Every seat has left by now, so every feed is closing.
		else if (event.type === 'call.ended') transcripts.ended(event.callId);
	});
	const sweep = () => {
		try {
			calls.sweep();
		} catch (error) {
			console.error('[calls] sweep failed', error);
		}
	};
	sweep();
	const timer = setInterval(sweep, TICK_MS);
	timer.unref();
	return {
		routes: callRoutes(calls, records),
		view: (person) => {
			if (calls.relay === null) return { calls: [], ringing: [] };
			try {
				return calls.view(person);
			} catch (error) {
				// The app drops calls, people and conversations together if `GET /v1/calls` fails, as the apps' hooks know too.
				console.error('[calls] listing calls failed', error);
				return { calls: [], ringing: [] };
			}
		},
		feedPath: (pathname) => feeds.match(pathname),
		upgradeFeed: (req, server, callId) => feeds.upgrade(req, server, callId),
		sweep: () => calls.sweep(),
		idle: async () => {
			await calls.idle();
			await recorder.idle();
			await transcripts.idle();
		},
		stop: async () => {
			clearInterval(timer);
			stopFrames();
			stopBus();
			feeds.stop();
			await recorder.save(record.options?.stopWaitMs ?? STOP_WAIT_MS);
		},
	};
}
