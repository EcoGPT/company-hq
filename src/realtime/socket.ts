import type { Server, ServerWebSocket, WebSocketHandler } from 'bun';
import type { HubEvent, WireFrame as Frame } from '../core/events';
import type { Hub } from '../core/hub';
import type { Person } from '../core/people';
import { bearer, json } from '../http/router';
import { iso, WIRE_VERSION, type Presenter } from '../wire/present';

export type SocketData = {
	person: Person;
	keyId: string;
	deviceId: string;
	lastHeard: number;
	/** When this connection last had a typing or a sync frame served, for the pace limits below. */
	servedAt: { typing: number; sync: number };
	/** The newest message of a replay that stopped short: asking again from exactly there is the next page, not a new request. */
	resumeAfter: string | null;
	/** Set on a socket of another kind (a call's audio feed): it is handled there and never joins the event sockets. */
	side?: SideSocket;
};

/** The handler of a socket that is not an event socket, carried in its data. */
export type SideSocket = {
	open(ws: ServerWebSocket<SocketData>): void;
	message(ws: ServerWebSocket<SocketData>, raw: string | Buffer): void;
	close(ws: ServerWebSocket<SocketData>): void;
};

export type SocketOptions = {
	clock?: () => number;
	/** A socket that sends nothing for this long is closed. The app pings every 30 s. */
	silentMs?: number;
	/** On a new connection, the same device's older sockets quiet for this long are replaced. */
	staleMs?: number;
};

const CLOSE_REPLACED = 4000;
const CLOSE_REVOKED = 4001;
const CLOSE_SILENT = 4002;

const TYPING_MS = 5_000;
const BOT_STATE_MS = 120_000;
const SYNC_BATCH = 100;
const SYNC_LIMIT = 500;
const SWEEP_MS = 15_000;
/** The app sends a few hundred bytes a frame; nothing it sends is near this. */
const MAX_FRAME_BYTES = 64 * 1024;
/** One connection's typing frames are passed on this often, and its sync requests served this often. The rest are dropped. */
const TYPING_EVERY_MS = 1_000;
const SYNC_EVERY_MS = 2_000;
/** One person's open connections (their devices, and each device's reconnects). The oldest give way. */
const MAX_CONNECTIONS = 10;
/** The most messages a person's replays serve in a window, across all their sockets, which the pace above does not bound. */
const REPLAY_BUDGET = 2_000;
const REPLAY_WINDOW_MS = 10_000;

/** Who sent a client frame: the person and the device the socket signed in as. */
export type FrameSender = { personId: string; deviceId: string };
export type ClientFrameHandler = (from: FrameSender, frame: Record<string, unknown>) => void;

export function createSocket(hub: Hub, present: Presenter, options: SocketOptions = {}) {
	const clock = options.clock ?? Date.now;
	const silentMs = options.silentMs ?? 75_000;
	const staleMs = options.staleMs ?? 35_000;
	const sockets = new Set<ServerWebSocket<SocketData>>();
	/** Frame types a feature outside core takes from the app (calls take `call_heartbeat`). They get no answer. */
	const clientFrames = new Map<string, ClientFrameHandler>();

	function onClientFrame(type: string, handler: ClientFrameHandler): () => void {
		if (['sync', 'typing'].includes(type) || clientFrames.has(type)) throw new Error(`the ${type} frame is already handled`);
		clientFrames.set(type, handler);
		return () => clientFrames.delete(type);
	}

	const onlinePeople = () => new Set([...sockets].map((ws) => ws.data.person.id));

	/**
	 * Devices with a socket open now. A socket stays open until it has been quiet for `silentMs`, so a device that just lost
	 * its connection still counts for up to that long. Push suppression should be per device, not per person.
	 */
	const onlineDevices = () => new Set([...sockets].map((ws) => ws.data.deviceId));

	// Messages replayed per person in the current window, with when it began.
	const replayed = new Map<string, { since: number; count: number }>();
	const spent = (personId: string, at: number) => {
		const used = replayed.get(personId);
		return used === undefined || at - used.since >= REPLAY_WINDOW_MS ? 0 : used.count;
	};
	const charge = (personId: string, at: number, count: number) => {
		const used = replayed.get(personId);
		if (used === undefined || at - used.since >= REPLAY_WINDOW_MS) replayed.set(personId, { since: at, count });
		else used.count += count;
	};

	/** Closes the socket if its key was revoked (possibly by another process, such as `bun hq revoke`). */
	function live(ws: ServerWebSocket<SocketData>, checked: Map<string, boolean>): boolean {
		const { keyId } = ws.data;
		if (!checked.has(keyId)) checked.set(keyId, hub.keys.isActive(keyId));
		if (checked.get(keyId)) return true;
		ws.close(CLOSE_REVOKED, 'revoked');
		return false;
	}

	/**
	 * Sends frames to people, each built for the person it goes to. `to` is a list of person ids, or
	 * null for everyone connected. Phase 2 surfaces (tasks, meetings, calls) send their frames here.
	 */
	function broadcast(
		to: Iterable<string> | null,
		frame: Frame | ((personId: string) => Frame | null),
		except?: ServerWebSocket<SocketData>,
	) {
		if (sockets.size === 0) return;
		const wanted = to === null ? null : new Set(to);
		const built = new Map<string, string | null>();
		const checked = new Map<string, boolean>();
		for (const ws of sockets) {
			const personId = ws.data.person.id;
			if (ws === except || (wanted !== null && !wanted.has(personId))) continue;
			if (!built.has(personId)) {
				const value = typeof frame === 'function' ? frame(personId) : frame;
				built.set(personId, value === null ? null : JSON.stringify(value));
			}
			const payload = built.get(personId);
			if (payload !== null && payload !== undefined && live(ws, checked)) ws.send(payload);
		}
	}

	function members(conversationId: string): string[] {
		return hub.conversations.memberIds(conversationId);
	}

	function conversationFor(conversationId: string): (personId: string) => Frame | null {
		return (personId) => {
			const conversation = hub.conversations.get(conversationId);
			if (conversation === null || conversation.archived_at !== null) return null;
			return { type: 'conversation_updated', conversation: present.conversation(conversation, personId) };
		};
	}

	hub.bus.on((event: HubEvent) => {
		switch (event.type) {
			case 'message.created':
				return broadcast(members(event.message.conversation_id), { type: 'message', message: present.message(event.message) });
			case 'message.updated':
				return broadcast(members(event.message.conversation_id), {
					type: 'message_updated',
					message: present.message(event.message),
				});
			case 'conversation.created':
				return broadcast(members(event.conversation.id), conversationFor(event.conversation.id));
			case 'conversation.changed':
				return broadcast(event.audience, conversationFor(event.conversationId));
			case 'conversation.removed':
				return broadcast(event.audience, { type: 'conversation_removed', conversation_id: event.conversationId });
			case 'read':
				return broadcast(members(event.conversationId), {
					type: 'read',
					conversation_id: event.conversationId,
					person_id: event.personId,
					last_read_message_id: event.messageId,
				});
			case 'person.updated':
				return broadcast(null, { type: 'person_updated', person: present.person(event.person) });
			case 'assistant.state':
				return broadcast(members(event.conversationId), {
					type: 'bot_state',
					conversation_id: event.conversationId,
					person_id: event.personId,
					label: event.label,
					expires_at: iso(clock() + (event.label === null ? 0 : BOT_STATE_MS)),
				});
			case 'key.revoked':
				for (const ws of sockets) if (ws.data.keyId === event.keyId) ws.close(CLOSE_REVOKED, 'revoked');
				return;
			case 'frame': {
				const { audience, conversationId, frame } = event;
				// Anything but a list, "everyone" or a room is no one.
				if (conversationId === undefined)
					return broadcast(audience === 'everyone' ? null : Array.isArray(audience) ? audience : [], frame);
				// The room's members now: none once it is archived, and not someone who has left since the event was built.
				const inRoom = members(conversationId);
				return broadcast(
					audience === undefined ? inRoom : Array.isArray(audience) ? inRoom.filter((id) => audience.includes(id)) : [],
					frame,
				);
			}
			case 'app.event':
				// An app's own change events stay on the server; to reach the app's socket it emits a `frame` event.
				return;
		}
	});

	function sync(ws: ServerWebSocket<SocketData>, since: string, at: number) {
		const messages = hub.messages.since(ws.data.person.id, since, SYNC_LIMIT);
		charge(ws.data.person.id, at, messages.length);
		ws.data.resumeAfter = messages.length === SYNC_LIMIT ? messages[messages.length - 1]!.id : null;
		for (let i = 0; i < messages.length; i += SYNC_BATCH) {
			const batch = messages.slice(i, i + SYNC_BATCH).map((m) => present.message(m));
			ws.send(JSON.stringify({ type: 'sync_batch', messages: batch }));
		}
		// A full page means more may be waiting; the app asks again from where this one ended.
		ws.send(JSON.stringify({ type: 'sync_complete', is_partial: messages.length === SYNC_LIMIT }));
	}

	function handle(ws: ServerWebSocket<SocketData>, text: string) {
		const invalid = () => ws.send(JSON.stringify({ type: 'error', code: 'invalid_frame' }));
		let frame: unknown;
		try {
			frame = JSON.parse(text);
		} catch {
			return invalid();
		}
		const { type, since_message_id: since, conversation_id: conversationId } = (frame ?? {}) as Record<string, unknown>;
		const at = clock();
		const served = ws.data.servedAt;
		if (type === 'sync' && (since === undefined || typeof since === 'string')) {
			// The page after a short one is what the server itself asked for; anything else inside the pace is dropped. A
			// dropped request is still answered (the app waits for that), as a replay that stopped short with nothing in it,
			// so the app sees its cursor has not moved and stops asking.
			const nextPage = since !== undefined && since === ws.data.resumeAfter;
			// The person's replays across all their sockets are budgeted too, next pages included; past it the answer is the same.
			const tooSoon = !nextPage && at - served.sync < SYNC_EVERY_MS;
			if (tooSoon || spent(ws.data.person.id, at) >= REPLAY_BUDGET) {
				return void ws.send(JSON.stringify({ type: 'sync_complete', is_partial: true }));
			}
			served.sync = at;
			return sync(ws, since ?? '', at);
		}
		if (type === 'typing' && typeof conversationId === 'string') {
			// Typing in a room you are not in is dropped without a word, and so is typing faster than people type.
			if (at - served.typing < TYPING_EVERY_MS) return;
			if (!hub.conversations.isMember(conversationId, ws.data.person.id)) return;
			served.typing = at;
			return broadcast(members(conversationId), {
				type: 'typing',
				conversation_id: conversationId,
				person_id: ws.data.person.id,
				expires_at: iso(clock() + TYPING_MS),
			});
		}
		const handler = typeof type === 'string' ? clientFrames.get(type) : undefined;
		if (handler !== undefined) {
			try {
				return handler({ personId: ws.data.person.id, deviceId: ws.data.deviceId }, frame as Record<string, unknown>);
			} catch (error) {
				return console.error(`[socket] ${type} frame failed`, error);
			}
		}
		invalid();
	}

	const websocket: WebSocketHandler<SocketData> = {
		maxPayloadLength: MAX_FRAME_BYTES,
		open(ws) {
			if (ws.data.side !== undefined) return ws.data.side.open(ws);
			const person = ws.data.person.id;
			const wasOnline = onlinePeople().has(person);
			const now = clock();
			const stale = [...sockets].filter(
				(other) => other.data.deviceId === ws.data.deviceId && now - other.data.lastHeard > staleMs,
			);
			ws.data.lastHeard = now;
			sockets.add(ws);
			// Over the cap, the oldest connections of this person go (sets keep the order they were added in).
			const theirs = [...sockets].filter((other) => other.data.person.id === person && other.readyState === WebSocket.OPEN);
			for (const oldest of theirs.slice(0, Math.max(0, theirs.length - MAX_CONNECTIONS)))
				oldest.close(CLOSE_REPLACED, 'replaced');
			ws.send(
				JSON.stringify({
					type: 'hello',
					device_id: ws.data.deviceId,
					person_id: person,
					online_person_ids: [...onlinePeople()],
					wire_version: WIRE_VERSION,
				}),
			);
			// Closed only after the new socket is in, so the person never reads as offline in between.
			for (const old of stale) old.close(CLOSE_REPLACED, 'replaced');
			if (!wasOnline) broadcast(null, { type: 'presence', person_id: person, is_online: true }, ws);
		},
		message(ws, raw) {
			if (ws.data.side !== undefined) return ws.data.side.message(ws, raw);
			ws.data.lastHeard = clock();
			if (typeof raw !== 'string') return;
			if (!hub.keys.isActive(ws.data.keyId)) return void ws.close(CLOSE_REVOKED, 'revoked');
			if (raw === 'ping') return void ws.send('pong');
			handle(ws, raw);
		},
		close(ws) {
			if (ws.data.side !== undefined) return ws.data.side.close(ws);
			sockets.delete(ws);
			if (!onlinePeople().has(ws.data.person.id)) {
				broadcast(null, { type: 'presence', person_id: ws.data.person.id, is_online: false });
			}
		},
	};

	function sweep() {
		const now = clock();
		for (const ws of sockets) if (now - ws.data.lastHeard > silentMs) ws.close(CLOSE_SILENT, 'silent');
	}
	const timer = setInterval(sweep, SWEEP_MS);
	timer.unref();

	function upgrade(req: Request, server: Server<SocketData>): Response | undefined {
		if (req.headers.get('upgrade')?.toLowerCase() !== 'websocket') return json({ error: 'upgrade_required' }, 426);
		const auth = hub.keys.check(bearer(req));
		if (!auth.ok) return json({ error: auth.error }, 401);
		const deviceId = hub.devices.byKey(auth.keyId)?.id ?? auth.keyId;
		const data: SocketData = {
			person: auth.person,
			keyId: auth.keyId,
			deviceId,
			lastHeard: clock(),
			servedAt: { typing: Number.NEGATIVE_INFINITY, sync: Number.NEGATIVE_INFINITY },
			resumeAfter: null,
		};
		if (server.upgrade(req, { data })) return undefined;
		return json({ error: 'upgrade_required' }, 426);
	}

	return { websocket, upgrade, broadcast, onlineDevices, onClientFrame, sweep, stop: () => clearInterval(timer) };
}
