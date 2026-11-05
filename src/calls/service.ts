import type { CallTarget } from '../apps/define';
import type { Conversation } from '../core/conversations';
import type { Hub } from '../core/hub';
import type { Person } from '../core/people';
import { HttpError } from '../http/router';
import { iso } from '../wire/present';
import { RateLimiter } from '../wire/rate-limit';
import type { CallsOptions } from './config';
import { RelayError, type CallRelay } from './relay';
import { CallStore, FLAG_OF, type CallKind, type CallRow, type Mid, type Seat } from './store';

/** What calls need to know of meetings, from the apps: core never imports one. */
export type CallTargets = {
	/** The meeting a person may call into (made now, for a null id); null when there is none they can see. */
	find(person: Person, meetingId: string | null): CallTarget | null;
	/** Whether this room was opened for a meeting, so a call started in it does not ring. */
	isMeetingRoom(conversationId: string): boolean;
};

/** A seat that has not been heard from for this long is taken out of the call. The app beats every 15 s. */
export const SEAT_SILENCE_MS = 45_000;
export const RING_MS = 45_000;
export const TICK_MS = 15_000;
const RECENT_CALLS = 50;

const notFound = () => new HttpError(404, 'not_found');
const notInCall = () => new HttpError(409, 'not_in_call');
const superseded = () => new HttpError(409, 'session_superseded');

export const relayFailure = (error: unknown): never => {
	if (error instanceof RelayError) throw new HttpError(502, error.code);
	throw error;
};

/** Who is joining: the person, and the device that takes the seat. */
export type Caller = { person: Person; deviceId: string };

export class Calls {
	readonly store: CallStore;
	readonly maxParticipants: number;
	private readonly clock: () => number;
	private readonly log: (line: string) => void;
	private readonly starts: RateLimiter;
	private readonly rejoins: RateLimiter;
	private readonly queues = new Map<string, Promise<unknown>>();
	private readonly pending = new Set<Promise<unknown>>();
	/** Told when a device's seat ends (it left or was taken out), so its audio feed closes. */
	readonly seatLeft = new Set<(callId: string, deviceId: string) => void>();

	constructor(
		private readonly hub: Hub,
		readonly relay: CallRelay | null,
		private readonly targets: CallTargets,
		options: Omit<CallsOptions, 'relay'> = {},
	) {
		this.store = new CallStore(hub.db);
		this.maxParticipants = options.maxParticipants ?? 20;
		this.clock = options.clock ?? Date.now;
		this.log = options.log ?? console.warn;
		this.starts = new RateLimiter(options.startsPerWindow ?? 10, options.startWindowMs ?? 10 * 60_000, this.clock);
		this.rejoins = new RateLimiter(options.rejoinsPerWindow ?? 20, options.rejoinWindowMs ?? 60_000, this.clock);
	}

	now(): number {
		return this.clock();
	}

	// --- What the app reads ---

	present(call: CallRow) {
		const seats = this.store.seats(call.id);
		const present = new Map(seats.filter((s) => s.left_at === null).map((s) => [s.device_id, s]));
		// A quiet camera or screen track stays out of the roster until its flag is on.
		const tracks = call.ended_at === null ? this.store.liveTracks(call.id) : [];
		const shown = tracks.filter((t) => {
			const seat = present.get(t.device_id);
			const flag = FLAG_OF[t.source];
			return seat !== undefined && seat.session_id === t.session_id && (flag === null || seat[flag] === 1);
		});
		return {
			id: call.id,
			conversation_id: call.conversation_id,
			kind: call.kind,
			meeting_id: call.meeting_id,
			title: call.title,
			started_by_person_id: call.started_by,
			started_at: iso(call.started_at),
			ended_at: call.ended_at === null ? null : iso(call.ended_at),
			participants: seats.map((s) => ({
				device_id: s.device_id,
				person_id: s.person_id,
				session_id: s.session_id,
				is_muted: s.is_muted === 1,
				is_camera_on: s.is_camera_on === 1,
				is_screen_sharing: s.is_screen_sharing === 1,
				is_hand_raised: s.is_hand_raised === 1,
				joined_at: iso(s.joined_at),
				left_at: s.left_at === null ? null : iso(s.left_at),
			})),
			tracks: shown.map((t) => ({
				track_name: t.track_name,
				session_id: t.session_id,
				device_id: t.device_id,
				person_id: t.person_id,
				source: t.source,
				created_at: iso(t.created_at),
				ended_at: null,
			})),
		};
	}

	/** `GET /v1/calls`: recent calls in rooms the person is in, and what is ringing for them now. */
	view(person: Person) {
		const at = this.clock();
		const ringing = this.store.ringing({ personId: person.id }).flatMap((ring) => {
			const call = this.store.get(ring.call_id);
			if (call === null || call.ended_at !== null || ring.expires_at <= at) return [];
			if (!this.hub.conversations.isMember(call.conversation_id, person.id)) return [];
			return [this.incoming(call, ring.expires_at)];
		});
		return { calls: this.store.recentFor(person.id, RECENT_CALLS).map((c) => this.present(c)), ringing };
	}

	private incoming(call: CallRow, expiresAt: number) {
		const conversation = this.hub.conversations.get(call.conversation_id);
		return {
			call: this.present(call),
			caller_name: this.hub.people.get(call.started_by)?.name ?? '?',
			conversation_title: conversation === null ? null : roomTitle(conversation),
			expires_at: iso(expiresAt),
		};
	}

	/** The call, if the person is in its room now. A seat this device still holds in a room it left is given up. */
	readable(person: Person, callId: string, deviceId: string | null): CallRow {
		const call = this.store.get(callId);
		if (call === null) throw notFound();
		if (!this.hub.conversations.isMember(call.conversation_id, person.id)) {
			if (deviceId !== null) this.leaveSeat(call.id, deviceId);
			throw notFound();
		}
		return call;
	}

	/** The caller's live seat in a live call, with a relay session, or 409. */
	seated(call: CallRow, deviceId: string): Seat & { session_id: string } {
		if (call.ended_at !== null) throw notInCall();
		const seat = this.store.seat(call.id, deviceId);
		if (seat === null || seat.left_at !== null || seat.session_id === null) throw notInCall();
		return seat as Seat & { session_id: string };
	}

	/** After a relay await: the seat must still be the one that asked, or a rejoin or a leave got in between. */
	still(seat: Seat): void {
		const now = this.store.seat(seat.call_id, seat.device_id);
		if (now === null || now.left_at !== null || now.session_id !== seat.session_id || now.generation !== seat.generation) {
			throw superseded();
		}
	}

	/** `still`, closing what the relay just took on this session when a rejoin or a leave overtook the request. */
	stillOrClose(seat: Seat & { session_id: string }, mids: { mid: string }[]): void {
		try {
			this.still(seat);
		} catch (error) {
			this.closeLater(
				seat.session_id,
				mids.map((m) => ({ session_id: seat.session_id, mid: m.mid })),
			);
			throw error;
		}
	}

	// --- Joining and leaving ---

	async join(
		caller: Caller,
		request: { kind: CallKind; conversationId?: string; meetingId?: string | null },
	): Promise<{ call: CallRow; seat: Seat; sessionId: string }> {
		const relay = this.relay;
		if (relay === null) throw new HttpError(503, 'not_configured');
		const { person, deviceId } = caller;
		let target: { conversationId: string; meetingId: string | null; title: string | null };
		let admitted = false;
		if (request.kind === 'conversation') {
			const conversation = request.conversationId === undefined ? null : this.hub.conversations.get(request.conversationId);
			if (conversation === null || !this.hub.conversations.isMember(conversation.id, person.id)) throw notFound();
			target = { conversationId: conversation.id, meetingId: null, title: roomTitle(conversation) };
		} else {
			const meetingId = request.meetingId ?? null;
			// A Quick Call is always a new call, and the meeting it makes is made now.
			if (meetingId === null) admitted = this.admitStart(person);
			const found = this.targets.find(person, meetingId);
			if (found === null) throw new HttpError(404, 'meeting_not_found');
			target = found;
		}

		// A room call in a meeting's room joins the meeting's call rather than opening a second one beside it.
		let call =
			this.store.live(target.conversationId, target.meetingId) ??
			(request.kind === 'conversation' ? this.store.liveMeetingIn(target.conversationId) : null);
		let created = false;
		if (call === null) {
			if (!admitted) this.admitStart(person);
			call = this.store.create({
				conversation_id: target.conversationId,
				kind: request.kind,
				meeting_id: target.meetingId,
				title: target.title,
				started_by: person.id,
				started_at: this.clock(),
			});
			created = true;
		} else {
			const mine = this.store.seat(call.id, deviceId);
			const seated = mine !== null && mine.left_at === null;
			if (!seated && this.store.presentCount(call.id) >= this.maxParticipants) throw new HttpError(409, 'call_full');
		}

		// Each rejoin makes a relay session and tells the room, so one device cannot do it without end.
		const before = this.store.seat(call.id, deviceId);
		if (before !== null && this.rejoins.admit(deviceId) > 0) throw new HttpError(429, 'too_many_rejoins');
		// One call per device: joining this one leaves any other.
		for (const other of this.store.seatsOfDevice(deviceId)) {
			if (other.call_id !== call.id) this.leaveSeat(other.call_id, deviceId);
		}
		// The seat is written before the relay is awaited, so a sweep in between never finds a new call empty and ends it.
		const { seat, ended } = this.store.sit(call.id, deviceId, person.id, this.clock());
		if (before?.session_id != null) this.closeLater(before.session_id, ended);

		let sessionId: string;
		try {
			({ sessionId } = await relay.newSession());
		} catch (error) {
			this.store.unseat(call.id, deviceId, seat.generation, this.clock());
			if (created && this.store.presentCount(call.id) === 0) this.end(call.id);
			else this.sendState(call.id);
			return relayFailure(error);
		}
		if (!this.store.setSession(call.id, deviceId, seat.generation, sessionId)) throw superseded();
		// Only now is the person in the call: a relay failure above leaves their ring ringing.
		this.answer(call, person.id);
		const joined = this.store.get(call.id)!;
		if (created && joined.kind === 'conversation' && !this.targets.isMeetingRoom(joined.conversation_id)) {
			this.ring(joined, person);
		}
		this.sendState(joined.id);
		return { call: joined, seat: this.store.seat(call.id, deviceId)!, sessionId };
	}

	private admitStart(person: Person): true {
		const wait = this.starts.admit(person.id);
		if (wait > 0) throw new HttpError(429, 'too_many_calls');
		return true;
	}

	/**
	 * The device leaves; what it sends and what it pulls are closed at the relay, and the call ends with its last seat.
	 * False if it was not seated.
	 */
	leaveSeat(callId: string, deviceId: string): boolean {
		const seat = this.store.seat(callId, deviceId);
		const ended = this.store.leave(callId, deviceId, this.clock());
		if (ended === null || seat === null) return false;
		for (const listener of this.seatLeft) listener(callId, deviceId);
		if (seat.session_id !== null) this.closeLater(seat.session_id, ended);
		if (this.store.presentCount(callId) === 0) this.end(callId);
		else this.sendState(callId);
		return true;
	}

	/** Ends the call: seats left, tracks closed at the relay, rings stopped, and everyone who could see it told. */
	end(callId: string): void {
		const call = this.store.get(callId);
		if (call === null || call.ended_at !== null) return;
		const at = this.clock();
		// A call ends when its last seat has left, and each seat closed what it sent and pulled as it went.
		if (!this.store.end(callId, at)) return;
		for (const ring of this.store.ringing({ callId })) this.stopRing(ring.call_id, ring.person_id, 'ended');
		this.hub.bus.emit({
			type: 'frame',
			conversationId: call.conversation_id,
			audience: this.viewers(call),
			frame: { type: 'call_ended', call_id: call.id, ended_at: iso(at) },
		});
		this.hub.bus.emit({
			type: 'call.ended',
			callId: call.id,
			conversationId: call.conversation_id,
			meetingId: call.meeting_id,
			endedAt: iso(at),
		});
	}

	// --- Ringing ---

	/** A new conversation call rings everyone else in the room who is a person, for 45 s. */
	private ring(call: CallRow, caller: Person): void {
		const conversation = this.hub.conversations.get(call.conversation_id);
		if (conversation === null) return;
		const people = this.hub.people.byIds(this.hub.conversations.memberIds(conversation.id));
		const rung = [...people.values()]
			.filter((p) => p.id !== caller.id && p.kind === 'human' && p.removed_at === null)
			.map((p) => p.id);
		if (rung.length === 0) return;
		const at = this.clock();
		const expiresAt = at + RING_MS;
		this.store.ring(call.id, rung, at, expiresAt);
		const incoming = this.incoming(call, expiresAt);
		this.hub.bus.emit({ type: 'frame', audience: rung, frame: { type: 'call_ring', ...incoming } });
		this.hub.bus.emit({
			type: 'call.ringing',
			callId: call.id,
			conversationId: call.conversation_id,
			callerName: caller.name,
			conversationTitle: incoming.conversation_title,
			expiresAt: incoming.expires_at,
			personIds: rung,
		});
	}

	/** Joining answers the person's ring, so their other devices stop. */
	private answer(call: CallRow, personId: string): void {
		this.stopRing(call.id, personId, 'answered');
	}

	decline(call: CallRow, personId: string): void {
		this.stopRing(call.id, personId, 'declined');
	}

	private stopRing(callId: string, personId: string, state: 'answered' | 'declined' | 'missed' | 'ended'): void {
		if (!this.store.resolveRing(callId, personId, state, this.clock())) return;
		this.hub.bus.emit({ type: 'frame', audience: [personId], frame: { type: 'call_ring_ended', call_id: callId } });
	}

	// --- Liveness ---

	heartbeat(callId: string, deviceId: string): void {
		this.store.touch(callId, deviceId, this.clock());
	}

	/**
	 * Takes out every seat that went silent, whose device was signed out, whose person was removed or who left the room;
	 * ends calls nobody is in; stops rings that ran out. Runs every 15 s and once at start.
	 */
	sweep(): void {
		const at = this.clock();
		for (const seat of this.store.presentSeats()) {
			const call = this.store.get(seat.call_id);
			const device = this.hub.devices.get(seat.device_id);
			const person = this.hub.people.get(seat.person_id);
			const gone =
				call === null ||
				device === null ||
				!this.hub.keys.isActive(device.key_id) ||
				person === null ||
				person.removed_at !== null ||
				!this.hub.conversations.isMember(call.conversation_id, seat.person_id) ||
				at - seat.last_seen_at > SEAT_SILENCE_MS;
			if (gone) this.leaveSeat(seat.call_id, seat.device_id);
		}
		for (const call of this.store.liveCalls()) if (this.store.presentCount(call.id) === 0) this.end(call.id);
		for (const ring of this.store.ringing({ expiredBy: at })) this.stopRing(ring.call_id, ring.person_id, 'missed');
		for (const ring of this.store.ringing({})) {
			const call = this.store.get(ring.call_id);
			const person = this.hub.people.get(ring.person_id);
			const gone =
				call === null ||
				person === null ||
				person.removed_at !== null ||
				!this.hub.conversations.isMember(call.conversation_id, ring.person_id);
			if (gone) this.stopRing(ring.call_id, ring.person_id, 'ended');
		}
	}

	/** A device whose key was revoked leaves every call it sits in. */
	signedOut(keyId: string): void {
		const device = this.hub.devices.byKey(keyId);
		if (device === null) return;
		for (const seat of this.store.seatsOfDevice(device.id)) this.leaveSeat(seat.call_id, device.id);
	}

	// --- Frames ---

	/**
	 * Who may see the call now: the room's members who have not been removed. Everyone seated is one, since a seat whose
	 * person left the room is given up; the frames go with the room as well, so the socket checks membership again as it sends.
	 */
	private viewers(call: CallRow): string[] {
		const ids = this.hub.conversations.memberIds(call.conversation_id);
		const people = this.hub.people.byIds(ids);
		return ids.filter((id) => people.get(id)?.removed_at === null);
	}

	sendState(callId: string): void {
		const call = this.store.get(callId);
		if (call === null) return;
		this.hub.bus.emit({
			type: 'frame',
			conversationId: call.conversation_id,
			audience: this.viewers(call),
			frame: { type: 'call_state', call: this.present(call) },
		});
	}

	// --- The relay ---

	/** One relay request at a time per session: two offers in flight on one peer connection both fail. */
	serialized<T>(sessionId: string, op: () => Promise<T>): Promise<T> {
		const previous = this.queues.get(sessionId) ?? Promise.resolve();
		const next = previous.then(op, op);
		const tail = next.catch(() => {});
		this.queues.set(sessionId, tail);
		void tail.then(() => {
			if (this.queues.get(sessionId) === tail) this.queues.delete(sessionId);
		});
		return next;
	}

	/** Closes this session's transceivers at the relay in the background; a failure is logged, as the relay drops idle ones itself. */
	closeLater(sessionId: string, mids: Mid[]): void {
		const relay = this.relay;
		const own = mids.filter((m) => m.session_id === sessionId).map((m) => m.mid);
		if (relay === null || own.length === 0) return;
		const done = this.serialized(sessionId, () => relay.closeTracks(sessionId, own)).catch((error: unknown) => {
			this.log(`[calls] closing tracks failed: ${error instanceof RelayError ? error.code : 'error'}`);
		});
		this.pending.add(done);
		void done.finally(() => this.pending.delete(done));
	}

	/** Resolves when every background relay request so far has finished. */
	async idle(): Promise<void> {
		while (this.pending.size > 0) await Promise.all([...this.pending]);
	}
}

function roomTitle(conversation: Conversation): string | null {
	return conversation.kind === 'room' && conversation.title !== '' ? conversation.title : null;
}
