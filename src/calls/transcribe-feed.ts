import type { Server, ServerWebSocket } from 'bun';
import type { Hub } from '../core/hub';
import { bearer, json } from '../http/router';
import type { SideSocket, SocketData } from '../realtime/socket';
import type { Recorder } from './recording';
import type { Calls } from './service';

const PATH = /^\/v1\/calls\/([^/]+)\/transcribe$/;
/** One second of audio. The app sends a tenth of that a frame. */
export const MAX_AUDIO_FRAME = 32_000;
/** Audio is the seat's heartbeat, written at most this often. */
const BEAT_EVERY_MS = 5_000;

const CLOSE_REPLACED = 4000;
const CLOSE_REVOKED = 4001;
const CLOSE_LEFT = 4003;
const CLOSE_UNSUPPORTED = 1003;
const CLOSE_INVALID = 1007;

/**
 * `WS /v1/calls/:id/transcribe`: each seated device streams its microphone here as 16 kHz mono 16-bit PCM, and the text
 * `ping` is answered with `pong`. One feed per seat; a new one replaces the old. It closes when the seat leaves or the call
 * ends.
 */
export class CallFeeds {
	private readonly feeds = new Map<string, ServerWebSocket<SocketData>>();

	constructor(
		private readonly hub: Hub,
		private readonly calls: Calls,
		private readonly recorder: Recorder,
	) {}

	/** The call id when `pathname` is a feed's. */
	match(pathname: string): string | null {
		return PATH.exec(pathname)?.[1] ?? null;
	}

	/** Refused before the upgrade unless a signed-in device holds a present seat in the live call, in a room its person is in. */
	upgrade(req: Request, server: Server<SocketData> | undefined, callId: string): Response | undefined {
		if (server === undefined) return json({ error: 'upgrade_required' }, 426);
		const auth = this.hub.keys.check(bearer(req));
		if (!auth.ok) return json({ error: auth.error }, 401);
		const device = this.hub.devices.byKey(auth.keyId);
		if (device === null) return json({ error: 'device_only' }, 403);
		const call = this.calls.store.get(callId);
		if (call === null || !this.hub.conversations.isMember(call.conversation_id, auth.person.id)) {
			return json({ error: 'not_found' }, 404);
		}
		const seat = this.calls.store.seat(call.id, device.id);
		if (call.ended_at !== null || seat === null || seat.left_at !== null) return json({ error: 'not_in_call' }, 409);
		const data: SocketData = {
			person: auth.person,
			keyId: auth.keyId,
			deviceId: device.id,
			lastHeard: this.calls.now(),
			servedAt: { typing: 0, sync: 0 },
			resumeAfter: null,
			side: this.feed(call.id, device.id, auth.person.id),
		};
		return server.upgrade(req, { data }) ? undefined : json({ error: 'upgrade_required' }, 426);
	}

	private feed(callId: string, deviceId: string, personId: string): SideSocket {
		const key = `${callId} ${deviceId}`;
		const seat = { callId, deviceId, personId };
		let beatAt = Number.NEGATIVE_INFINITY;
		return {
			open: (ws) => {
				const old = this.feeds.get(key);
				this.feeds.set(key, ws);
				old?.close(CLOSE_REPLACED, 'replaced');
			},
			message: (ws, raw) => {
				// A feed that was replaced, or whose seat or call has ended, takes nothing more while it closes.
				if (this.feeds.get(key) !== ws) return;
				if (!this.hub.keys.isActive(ws.data.keyId)) return void ws.close(CLOSE_REVOKED, 'revoked');
				if (typeof raw === 'string') {
					if (raw === 'ping') return void ws.send('pong');
					return void ws.close(CLOSE_UNSUPPORTED, 'audio only');
				}
				if (raw.byteLength === 0 || raw.byteLength % 2 !== 0 || raw.byteLength > MAX_AUDIO_FRAME) {
					return void ws.close(CLOSE_INVALID, 'not 16-bit audio');
				}
				const at = this.calls.now();
				ws.data.lastHeard = at;
				if (at - beatAt >= BEAT_EVERY_MS) {
					beatAt = at;
					this.calls.heartbeat(callId, deviceId);
				}
				this.recorder.audio(seat, raw);
			},
			close: (ws) => {
				if (this.feeds.get(key) === ws) this.feeds.delete(key);
				this.recorder.flush(callId, deviceId);
			},
		};
	}

	/** The seat left (or was taken out): its feed closes. */
	left(callId: string, deviceId: string): void {
		this.drop(`${callId} ${deviceId}`, CLOSE_LEFT, 'left the call');
	}

	stop(): void {
		for (const key of [...this.feeds.keys()]) this.drop(key, 1001, 'stopping');
	}

	private drop(key: string, code: number, reason: string): void {
		const ws = this.feeds.get(key);
		this.feeds.delete(key);
		ws?.close(code, reason);
	}
}
