import { afterEach, describe, expect, spyOn, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import meetings from '../apps/meetings/app';
import type { AppDefinition } from '../src/apps/define';
import { CloudflareRelay, type CallsOptions } from '../src/calls';
import type { HubEvent } from '../src/core/events';
import { createHq } from '../src/hq';
import { client, connect, enrolled, pair, serve, type Connection, type Frame } from './helpers';
import { startFakeSfu, type FakeSfu } from './fake-sfu';
import { wire } from './wire-fixture';

// Live calls against a Cloudflare-shaped fake relay: joining, media signalling, the roster, ringing, liveness and who may do
// what. Every shape the app decodes is checked against swift-wire.calls.json.

const ISO_MS = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** What the app decodes, as the fixture says it. */
function shape(name: string, value: unknown, path = name): string[] {
	const spec = wire.structs[name];
	if (spec === undefined) return [`${path}: no struct ${name} in the fixture`];
	if (typeof value !== 'object' || value === null || Array.isArray(value)) return [`${path}: expected an object`];
	const object = value as Record<string, unknown>;
	const problems: string[] = [];
	for (const key of Object.keys(object))
		if (key !== 'type' && !(key in spec)) problems.push(`${path}.${key}: the app does not decode this`);
	for (const [key, field] of Object.entries(spec)) {
		const present = object[key];
		if (present === undefined || present === null) {
			if (field.required) problems.push(`${path}.${key}: the app requires this`);
			continue;
		}
		if (key.endsWith('_at') && !ISO_MS.test(String(present))) problems.push(`${path}.${key}: not an ISO time with milliseconds`);
		if (field.of === undefined) continue;
		if (!field.list) problems.push(...shape(field.of, present, `${path}.${key}`));
		else if (!Array.isArray(present)) problems.push(`${path}.${key}: expected a list`);
		else present.forEach((item, i) => problems.push(...shape(field.of!, item, `${path}.${key}[${i}]`)));
	}
	return problems;
}

/** An offer as WebRTC writes one before gathering: a sendonly section per local track. */
function offer(tracks: { mid: string; source: string }[]): string {
	return [
		'v=0',
		'o=- 4611731400430051336 2 IN IP4 127.0.0.1',
		's=-',
		't=0 0',
		`a=group:BUNDLE ${tracks.map((t) => t.mid).join(' ')}`,
		...tracks.flatMap((t) =>
			t.source === 'mic'
				? [
						'm=audio 9 UDP/TLS/RTP/SAVPF 111',
						'c=IN IP4 0.0.0.0',
						`a=mid:${t.mid}`,
						'a=sendonly',
						'a=rtcp-mux',
						'a=rtpmap:111 opus/48000/2',
					]
				: [
						'm=video 9 UDP/TLS/RTP/SAVPF 96',
						'c=IN IP4 0.0.0.0',
						`a=mid:${t.mid}`,
						'a=sendonly',
						'a=rtcp-mux',
						'a=rtpmap:96 VP8/90000',
					],
		),
		'',
	].join('\r\n');
}

type As = ReturnType<typeof client>;
type Track = { mid: string; source: 'mic' | 'cam' | 'screen'; is_enabled?: boolean };

const start = (as: As, body: Record<string, unknown>) => as('POST', '/v1/calls', { client_build: 'test', ...body });
const publish = (as: As, callId: string, tracks: Track[] = [{ mid: '0', source: 'mic' }]) =>
	as('POST', `/v1/calls/${callId}/publish`, { session_description: { type: 'offer', sdp: offer(tracks) }, tracks });

const cleanup: (() => void | Promise<void>)[] = [];
afterEach(async () => {
	for (const step of cleanup.splice(0).reverse()) await step();
});

async function setup(options: Partial<CallsOptions> & { apps?: AppDefinition[]; off?: boolean } = {}) {
	const { apps = [meetings], off = false, ...calls } = options;
	const sfu = startFakeSfu();
	let at = Date.parse('2026-11-02T10:00:00.000Z');
	const clock = { now: () => at, advance: (ms: number) => void (at += ms) };
	const log: string[] = [];
	const relay = off ? null : new CloudflareRelay({ appId: sfu.appId, secret: sfu.secret, baseUrl: sfu.url, retryDelayMs: 1 });
	const made = await pair({ apps, calls: { relay, clock: clock.now, log: (line) => log.push(line), ...calls } });
	const server = serve(made.hq);
	const events: HubEvent[] = [];
	made.hq.hub.bus.on((event) => {
		if (event.type.startsWith('call.')) events.push(event);
	});
	cleanup.push(() => sfu.stop());
	cleanup.push(() => void server.stop(true));
	cleanup.push(async () => {
		await made.hq.calls.idle();
		made.hq.stop();
	});
	const socket = async (bearer: string): Promise<Connection> => {
		const connection = await connect(server, bearer);
		cleanup.push(() => connection.ws.close());
		return connection;
	};
	const dm = (await made.a.as('POST', '/v1/conversations', { kind: 'dm', person_id: made.b.person.id })).body.conversation;
	return { ...made, sfu, clock, log, server, events, socket, dm };
}

const relayCalls = (sfu: FakeSfu, suffix: string) => sfu.requests.filter((r) => r.path.endsWith(suffix));

describe('a call between two people', () => {
	test('Ada calls Bo: ring, join, publish, subscribe, quiet camera, leave and the record', async () => {
		const { hq, a, b, dm, sfu, events, socket } = await setup();
		const adaSocket = await socket(a.bearer);
		const boSocket = await socket(b.bearer);

		const joined = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		expect(joined.status).toBe(200);
		expect(shape('JoinedCall', joined.body)).toEqual([]);
		expect(joined.body.call.id).toMatch(UUID);
		expect(joined.body).toMatchObject({ generation: 1, capabilities: ['quiet_tracks'] });
		const callId: string = joined.body.call.id;
		const adaSession: string = joined.body.session_id;
		expect(joined.body.call).toMatchObject({ kind: 'conversation', conversation_id: dm.id, meeting_id: null, title: null });

		// Bo's devices ring; Ada's do not.
		const ring = await boSocket.take('call_ring');
		expect(shape('IncomingCall', ring)).toEqual([]);
		expect(ring).toMatchObject({ caller_name: 'Ada', conversation_title: null });
		expect(ring.call.id).toBe(callId);
		const snapshot = (await b.as('GET', '/v1/calls')).body;
		expect(snapshot.ringing.map((r: Frame) => r.call.id)).toEqual([callId]);
		snapshot.ringing.forEach((r: unknown) => expect(shape('IncomingCall', r)).toEqual([]));
		expect((await a.as('GET', '/v1/calls')).body.ringing).toEqual([]);
		const ringing = events.find((e) => e.type === 'call.ringing');
		expect(ringing).toMatchObject({
			callId,
			conversationId: dm.id,
			callerName: 'Ada',
			conversationTitle: null,
			personIds: [b.person.id],
		});
		expect((ringing as { expiresAt: string }).expiresAt).toMatch(ISO_MS);
		await adaSocket.settle();
		expect(adaSocket.types()).not.toContain('call_ring');
		expect(shape('CallStatePayload', await adaSocket.take('call_state'))).toEqual([]);

		// Ada publishes her mic and a camera that is off. The server names the tracks; the answer carries the offer's mids.
		const published = await publish(a.as, callId, [
			{ mid: '0', source: 'mic' },
			{ mid: '1', source: 'cam', is_enabled: false },
		]);
		expect(published.status).toBe(200);
		expect(shape('PublishEnvelope', published.body)).toEqual([]);
		expect(published.body.refused).toEqual([]);
		expect(published.body.session_description.type).toBe('answer');
		expect(published.body.session_description.sdp).toContain('a=mid:0');
		expect(published.body.session_description.sdp).toContain('a=mid:1');
		const sent = relayCalls(sfu, '/tracks/new').at(-1)!;
		expect(sent.path).toContain(`/sessions/${adaSession}/`);
		expect(sent.body!.tracks).toEqual([
			{ location: 'local', mid: '0', trackName: `${a.deviceId}-mic` },
			{ location: 'local', mid: '1', trackName: `${a.deviceId}-cam` },
		]);
		// The quiet camera stays off the roster until its flag is on.
		let roster = (await a.as('GET', `/v1/calls/${callId}`)).body.call;
		expect(shape('Call', roster)).toEqual([]);
		expect(roster.tracks.map((t: Frame) => t.track_name)).toEqual([`${a.deviceId}-mic`]);
		const on = await a.as('POST', `/v1/calls/${callId}/state`, { is_camera_on: true });
		expect(on.body.call.tracks.map((t: Frame) => t.source)).toEqual(['mic', 'cam']);
		expect(on.body.call.participants[0]).toMatchObject({ is_camera_on: true, is_muted: false });
		const muted = await a.as('POST', `/v1/calls/${callId}/state`, { is_muted: true });
		// Untold flags are left alone.
		expect(muted.body.call.participants[0]).toMatchObject({ is_camera_on: true, is_muted: true });
		roster = (await a.as('POST', `/v1/calls/${callId}/state`, { is_camera_on: false })).body.call;
		expect(roster.tracks.map((t: Frame) => t.source)).toEqual(['mic']);

		// Bo answers: his ring stops on every device of his.
		const bo = await start(b.as, { kind: 'conversation', conversation_id: dm.id });
		expect(bo.body.call.id).toBe(callId);
		expect((await boSocket.take('call_ring_ended')).call_id).toBe(callId);
		expect((await b.as('GET', '/v1/calls')).body.ringing).toEqual([]);
		expect(events.filter((e) => e.type === 'call.ringing')).toHaveLength(1);

		// Bo pulls Ada's mic. A track not in this call's roster is not passed on.
		const mic = roster.tracks[0];
		const subscribed = await b.as('POST', `/v1/calls/${callId}/subscribe`, {
			tracks: [
				{ session_id: mic.session_id, track_name: mic.track_name },
				{ session_id: mic.session_id, track_name: `${a.deviceId}-screen` },
				{ session_id: 'elsewhere', track_name: mic.track_name },
			],
		});
		expect(subscribed.status).toBe(200);
		expect(shape('SubscribeResult', subscribed.body)).toEqual([]);
		expect(subscribed.body.requires_immediate_renegotiation).toBe(true);
		expect(subscribed.body.session_description.type).toBe('offer');
		const [pulled, ...unknown] = subscribed.body.tracks;
		expect(pulled.track_name).toBe(mic.track_name);
		expect(subscribed.body.session_description.sdp).toContain(`a=mid:${pulled.mid}`);
		expect(unknown.map((t: Frame) => t.error_code)).toEqual(['unknown_track', 'unknown_track']);
		const pull = relayCalls(sfu, '/tracks/new').at(-1)!;
		expect(pull.path).toContain(`/sessions/${bo.body.session_id}/`);
		expect(pull.body!.tracks).toEqual([{ location: 'remote', sessionId: mic.session_id, trackName: mic.track_name }]);
		expect(
			await b.as('PUT', `/v1/calls/${callId}/renegotiate`, { session_description: { type: 'answer', sdp: 'v=0\r\n' } }),
		).toEqual({ status: 200, body: { ok: true } });

		// Unsubscribe closes on Bo's own session, whatever the body says.
		const closed = await b.as('POST', `/v1/calls/${callId}/unsubscribe`, { mids: [pulled.mid], session_id: adaSession });
		expect(closed).toEqual({ status: 200, body: { ok: true } });
		const close = relayCalls(sfu, '/tracks/close').at(-1)!;
		expect(close.path).toBe(`/v1/apps/${sfu.appId}/sessions/${bo.body.session_id}/tracks/close`);
		expect(close.body).toEqual({ force: true, tracks: [{ mid: pulled.mid }] });

		// Ada stops her camera for good.
		await a.as('POST', `/v1/calls/${callId}/state`, { is_camera_on: true });
		expect(await a.as('POST', `/v1/calls/${callId}/unpublish`, { mids: ['1'], sources: ['cam'] })).toEqual({
			status: 200,
			body: { ok: true },
		});
		roster = (await a.as('GET', `/v1/calls/${callId}`)).body.call;
		expect(roster.tracks.map((t: Frame) => t.source)).toEqual(['mic']);
		expect(roster.participants.find((p: Frame) => p.device_id === a.deviceId).is_camera_on).toBe(false);

		// Bo leaves; the call goes on. Ada leaves; it ends, and her tracks are closed at the relay.
		expect(await b.as('POST', `/v1/calls/${callId}/leave`, {})).toEqual({ status: 200, body: { ok: true } });
		const state = await adaSocket.take('call_state', (f) => f.call.participants.some((p: Frame) => p.left_at !== null));
		expect(state.call.ended_at).toBeNull();
		expect(await a.as('POST', `/v1/calls/${callId}/leave`, {})).toEqual({ status: 200, body: { ok: true } });
		const ended = await boSocket.take('call_ended');
		expect(shape('CallEndedPayload', ended)).toEqual([]);
		expect(ended.call_id).toBe(callId);
		expect((await adaSocket.take('call_ended')).ended_at).toBe(ended.ended_at);
		await hq.calls.idle();
		expect(relayCalls(sfu, '/tracks/close').at(-1)).toMatchObject({
			path: `/v1/apps/${sfu.appId}/sessions/${adaSession}/tracks/close`,
			body: { force: true, tracks: [{ mid: '0' }] },
		});
		expect(events.find((e) => e.type === 'call.ended')).toEqual({
			type: 'call.ended',
			callId,
			conversationId: dm.id,
			meetingId: null,
			endedAt: ended.ended_at,
		});

		// The history lists the ended call, and its record is the call with nothing written down yet.
		const history = (await b.as('GET', '/v1/calls')).body;
		expect(history.calls.map((c: Frame) => c.id)).toEqual([callId]);
		history.calls.forEach((c: unknown) => expect(shape('Call', c)).toEqual([]));
		expect(history.calls[0].ended_at).toBe(ended.ended_at);
		expect(history.calls[0].tracks).toEqual([]);
		const record = await a.as('GET', `/v1/calls/${callId}/record`);
		expect(shape('CallRecord', record.body)).toEqual([]);
		expect(record.body).toMatchObject({ transcript: [], recordings: [] });
		expect(await a.as('GET', `/v1/calls/${callId}/recording/${a.deviceId}`)).toEqual({
			status: 404,
			body: { error: 'not_found' },
		});
		expect(await a.as('POST', `/v1/calls/${callId}/retranscribe`, {})).toEqual({
			status: 503,
			body: { error: 'not_configured' },
		});
		// In a call that ended there is nothing left to do.
		expect((await publish(a.as, callId)).body).toEqual({ error: 'not_in_call' });
	});

	test('a second caller joins the live call instead of starting another, and nothing rings twice', async () => {
		const { a, b, dm, events } = await setup();
		const first = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		const second = await start(b.as, { kind: 'conversation', conversation_id: dm.id });
		expect(second.body.call.id).toBe(first.body.call.id);
		expect(second.body.call.participants.map((p: Frame) => p.person_id)).toEqual([a.person.id, b.person.id]);
		expect(events.filter((e) => e.type === 'call.ringing')).toHaveLength(1);
	});

	test('declining stops the ring on all of the person’s devices and leaves the call alone', async () => {
		const { hq, a, b, dm, bo, socket } = await setup();
		const phone = await enrolled(hq, hq.hub.keys.mint(bo.id, 'setup').secret, 'Bo Phone');
		const mac = await socket(b.bearer);
		const handset = await socket(phone.bearer);
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		await mac.take('call_ring');
		await handset.take('call_ring');
		expect(await phone.as('POST', `/v1/calls/${body.call.id}/decline`, {})).toEqual({ status: 200, body: { ok: true } });
		const stopped = await mac.take('call_ring_ended');
		expect(shape('CallRingEndedPayload', stopped)).toEqual([]);
		expect(stopped.call_id).toBe(body.call.id);
		expect((await handset.take('call_ring_ended')).call_id).toBe(body.call.id);
		expect((await b.as('GET', '/v1/calls')).body.ringing).toEqual([]);
		expect((await a.as('GET', `/v1/calls/${body.call.id}`)).body.call.ended_at).toBeNull();
		// Declining again is fine and says nothing more.
		expect((await b.as('POST', `/v1/calls/${body.call.id}/decline`, {})).status).toBe(200);
		await mac.settle();
		expect(mac.types().filter((t) => t === 'call_ring_ended')).toHaveLength(1);
	});

	test('a group call rings the room’s people, never the caller or the assistant; the frame names the room', async () => {
		const { hq, a, b, room, socket, events } = await setup();
		hq.hub.conversations.addMember(room.id, hq.assistant.self.id);
		const boSocket = await socket(b.bearer);
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: room.id });
		expect(body.call.title).toBe('Launch');
		const ring = await boSocket.take('call_ring');
		expect(ring.conversation_title).toBe('Launch');
		expect(events.find((e) => e.type === 'call.ringing')).toMatchObject({
			personIds: [b.person.id],
			conversationTitle: 'Launch',
		});
	});

	test('the caller hanging up stops the ring', async () => {
		const { a, b, dm, socket } = await setup();
		const boSocket = await socket(b.bearer);
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		await boSocket.take('call_ring');
		await a.as('POST', `/v1/calls/${body.call.id}/leave`, {});
		expect((await boSocket.take('call_ring_ended')).call_id).toBe(body.call.id);
		expect((await boSocket.take('call_ended')).call_id).toBe(body.call.id);
		expect((await b.as('GET', '/v1/calls')).body.ringing).toEqual([]);
	});
});

describe('liveness', () => {
	test('heartbeats keep a seat; a ring runs out at 45 s; a silent seat is swept at 45 s and its tracks closed', async () => {
		const { hq, a, b, dm, sfu, clock, socket } = await setup();
		const adaSocket = await socket(a.bearer);
		const boSocket = await socket(b.bearer);
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		await publish(a.as, body.call.id);
		await boSocket.take('call_ring');

		// The socket heartbeat is taken without an answer, and keeps the seat.
		clock.advance(30_000);
		adaSocket.send({ type: 'call_heartbeat', call_id: body.call.id });
		await adaSocket.settle();
		expect(adaSocket.types()).not.toContain('error');
		clock.advance(16_000);
		hq.calls.sweep();
		expect((await boSocket.take('call_ring_ended')).call_id).toBe(body.call.id);
		expect((await b.as('GET', '/v1/calls')).body.ringing).toEqual([]);
		expect((await a.as('GET', `/v1/calls/${body.call.id}`)).body.call.ended_at).toBeNull();

		// Reading the roster is a heartbeat too.
		clock.advance(40_000);
		await a.as('GET', `/v1/calls/${body.call.id}`);
		clock.advance(40_000);
		hq.calls.sweep();
		expect((await a.as('GET', `/v1/calls/${body.call.id}`)).body.call.ended_at).toBeNull();

		// Then silence.
		clock.advance(46_000);
		hq.calls.sweep();
		expect((await adaSocket.take('call_ended')).call_id).toBe(body.call.id);
		await hq.calls.idle();
		expect(relayCalls(sfu, '/tracks/close').at(-1)!.body).toEqual({ force: true, tracks: [{ mid: '0' }] });
	});

	test('a restart sweeps seats that went silent while it was down', async () => {
		const dir = mkdtempSync(join(tmpdir(), 'hq-calls-'));
		cleanup.push(() => rmSync(dir, { recursive: true, force: true }));
		const sfu = startFakeSfu();
		cleanup.push(() => sfu.stop());
		const relay = new CloudflareRelay({ appId: sfu.appId, secret: sfu.secret, baseUrl: sfu.url });
		let at = Date.now();
		const options = { dbPath: join(dir, 'hq.sqlite'), calls: { relay, clock: () => at, log: () => {} } };
		const { hq, a, dm, callId } = await (async () => {
			const made = await pair(options);
			const dm = (await made.a.as('POST', '/v1/conversations', { kind: 'dm', person_id: made.b.person.id })).body.conversation;
			const { body } = await start(made.a.as, { kind: 'conversation', conversation_id: dm.id });
			return { ...made, dm, callId: body.call.id as string };
		})();
		expect((await a.as('GET', `/v1/calls/${callId}`)).body.call.ended_at).toBeNull();
		hq.stop();
		at += 60_000;
		const again = createHq(options);
		cleanup.push(() => again.stop());
		const call = (await client(again, a.bearer)('GET', `/v1/calls/${callId}`)).body.call;
		expect(call.ended_at).not.toBeNull();
		expect(call.participants[0].left_at).not.toBeNull();
		expect(dm.id).toBe(call.conversation_id);
	});
});

describe('rejoining and the relay', () => {
	test('a rejoin counts up the generation, clears the flags and ends the old tracks', async () => {
		const { hq, a, dm, sfu } = await setup();
		const first = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		await publish(a.as, first.body.call.id);
		await a.as('POST', `/v1/calls/${first.body.call.id}/state`, { is_muted: true, is_hand_raised: true });
		const again = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		expect(again.body.generation).toBe(2);
		expect(again.body.session_id).not.toBe(first.body.session_id);
		expect(again.body.call.tracks).toEqual([]);
		expect(again.body.call.participants).toHaveLength(1);
		expect(again.body.call.participants[0]).toMatchObject({ is_muted: false, is_hand_raised: false, left_at: null });
		await hq.calls.idle();
		expect(relayCalls(sfu, '/tracks/close').at(-1)!.path).toContain(`/sessions/${first.body.session_id}/`);
		const third = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		expect(third.body.generation).toBe(3);
	});

	test('an answer that comes back after a rejoin is refused and writes nothing', async () => {
		const { a, dm, sfu } = await setup();
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		const release = sfu.hold();
		const late = publish(a.as, body.call.id);
		while (relayCalls(sfu, '/tracks/new').length === 0) await Bun.sleep(1);
		const rejoin = start(a.as, { kind: 'conversation', conversation_id: dm.id });
		await Bun.sleep(5);
		release();
		expect((await late).body).toEqual({ error: 'session_superseded' });
		const rejoined = await rejoin;
		expect(rejoined.body.generation).toBe(2);
		expect((await a.as('GET', `/v1/calls/${body.call.id}`)).body.call.tracks).toEqual([]);
	});

	test('relay requests for one session go one at a time', async () => {
		const { a, dm, sfu } = await setup();
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		const release = sfu.hold();
		const mic = publish(a.as, body.call.id, [{ mid: '0', source: 'mic' }]);
		const screen = publish(a.as, body.call.id, [{ mid: '2', source: 'screen', is_enabled: false }]);
		while (relayCalls(sfu, '/tracks/new').length === 0) await Bun.sleep(1);
		await Bun.sleep(20);
		expect(relayCalls(sfu, '/tracks/new')).toHaveLength(1);
		release();
		expect((await mic).status).toBe(200);
		expect((await screen).status).toBe(200);
		expect(relayCalls(sfu, '/tracks/new')).toHaveLength(2);
	});

	test('a relay that fails takes the seat back out; a call this request made ends; one with people in it goes on', async () => {
		const { a, b, dm, sfu, socket } = await setup();
		const boSocket = await socket(b.bearer);
		sfu.fail('/sessions/new', 500, 1);
		const failed = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		expect(failed).toEqual({ status: 502, body: { error: 'sfu_unavailable' } });
		// Tried once (a session is never asked for twice), and nobody was rung for a call nobody got into.
		expect(relayCalls(sfu, '/sessions/new')).toHaveLength(1);
		await boSocket.settle();
		expect(boSocket.types()).not.toContain('call_ring');
		expect((await a.as('GET', '/v1/calls')).body.calls).toEqual([]);

		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		expect(body.generation).toBe(1);
		sfu.fail('/sessions/new', 400, 1);
		expect(await start(b.as, { kind: 'conversation', conversation_id: dm.id })).toEqual({
			status: 502,
			body: { error: 'sfu_rejected' },
		});
		const call = (await a.as('GET', `/v1/calls/${body.call.id}`)).body.call;
		expect(call.ended_at).toBeNull();
		expect(call.participants.map((p: Frame) => p.person_id)).toEqual([a.person.id]);

		// Publish is never retried.
		sfu.fail('/tracks/new', 500, 1);
		expect((await publish(a.as, body.call.id)).body).toEqual({ error: 'sfu_unavailable' });
		expect(relayCalls(sfu, '/tracks/new')).toHaveLength(1);
		sfu.fail('/tracks/new', 200, 1, { sessionDescription: 'nonsense', tracks: [] });
		expect((await publish(a.as, body.call.id)).body).toEqual({ error: 'sfu_bad_response' });
	});

	test('a track the relay refuses is reported and never reaches the roster', async () => {
		const { a, dm, sfu } = await setup();
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		sfu.fail('/tracks/new', 200, 1, {
			sessionDescription: { type: 'answer', sdp: 'v=0\r\n' },
			tracks: [
				{ mid: '0', trackName: `${a.deviceId}-mic` },
				{ mid: '1', trackName: `${a.deviceId}-cam`, errorCode: 'invalid_codec' },
			],
		});
		const published = await publish(a.as, body.call.id, [
			{ mid: '0', source: 'mic' },
			{ mid: '1', source: 'cam' },
		]);
		expect(published.body.refused).toEqual([{ mid: '1', source: 'cam', error_code: 'invalid_codec' }]);
		await a.as('POST', `/v1/calls/${body.call.id}/state`, { is_camera_on: true });
		const call = (await a.as('GET', `/v1/calls/${body.call.id}`)).body.call;
		expect(call.tracks.map((t: Frame) => t.source)).toEqual(['mic']);
	});
});

describe('a join waiting on the relay', () => {
	test('is already seated, so a sweep meanwhile does not end the new call', async () => {
		const { hq, a, dm, sfu } = await setup();
		const release = sfu.hold();
		const joining = start(a.as, { kind: 'conversation', conversation_id: dm.id });
		while (relayCalls(sfu, '/sessions/new').length === 0) await Bun.sleep(1);
		hq.calls.sweep();
		release();
		const { body } = await joining;
		expect((await a.as('GET', `/v1/calls/${body.call.id}`)).body.call.ended_at).toBeNull();
	});
});

/** Ada calls the room and sends her mic; Bo joins and pulls it. */
async function boPullsAdasMic(env: Awaited<ReturnType<typeof setup>>, conversationId: string) {
	const { a, b } = env;
	const call = (await start(a.as, { kind: 'conversation', conversation_id: conversationId })).body.call;
	await publish(a.as, call.id);
	const bo = (await start(b.as, { kind: 'conversation', conversation_id: conversationId })).body;
	const mic = (await b.as('GET', `/v1/calls/${call.id}`)).body.call.tracks[0];
	const pulled = await b.as('POST', `/v1/calls/${call.id}/subscribe`, {
		tracks: [{ session_id: mic.session_id, track_name: mic.track_name }],
	});
	return { callId: call.id as string, session: bo.session_id as string, mid: pulled.body.tracks[0].mid as string };
}

/** Whether the relay was asked to close `mid` on `session`. */
const closed = (sfu: FakeSfu, session: string, mid: string) =>
	relayCalls(sfu, '/tracks/close').some(
		(r) => r.path.includes(`/sessions/${session}/`) && (r.body!.tracks as { mid: string }[]).some((t) => t.mid === mid),
	);

describe('a seat that goes stops receiving', () => {
	test('someone taken out of the room: what they pulled is closed at the relay', async () => {
		const env = await setup();
		const { hq, sfu, room, bo } = env;
		const { session, mid } = await boPullsAdasMic(env, room.id);
		hq.hub.conversations.removeMember(room.id, bo.id);
		hq.calls.sweep();
		await hq.calls.idle();
		expect(closed(sfu, session, mid)).toBe(true);
	});

	test('leaving, a revoked device and a rejoin close what the seat pulled', async () => {
		const env = await setup();
		const { hq, sfu, b, room, dm } = env;
		let pull = await boPullsAdasMic(env, room.id);
		await b.as('POST', `/v1/calls/${pull.callId}/leave`, {});
		await hq.calls.idle();
		expect(closed(sfu, pull.session, pull.mid)).toBe(true);

		pull = await boPullsAdasMic(env, dm.id);
		await start(b.as, { kind: 'conversation', conversation_id: dm.id });
		await hq.calls.idle();
		expect(closed(sfu, pull.session, pull.mid)).toBe(true);

		const again = (await start(b.as, { kind: 'conversation', conversation_id: dm.id })).body.session_id as string;
		const mic = (await b.as('GET', `/v1/calls/${pull.callId}`)).body.call.tracks[0];
		const mid = (
			await b.as('POST', `/v1/calls/${pull.callId}/subscribe`, {
				tracks: [{ session_id: mic.session_id, track_name: mic.track_name }],
			})
		).body.tracks[0].mid;
		hq.hub.devices.revoke(b.deviceId);
		await hq.calls.idle();
		expect(closed(sfu, again, mid)).toBe(true);
	});

	test('an unsubscribed track is not closed a second time on leaving', async () => {
		const env = await setup();
		const { hq, sfu, b, room } = env;
		const { callId, session, mid } = await boPullsAdasMic(env, room.id);
		await b.as('POST', `/v1/calls/${callId}/unsubscribe`, { mids: [mid] });
		const before = relayCalls(sfu, '/tracks/close').length;
		await b.as('POST', `/v1/calls/${callId}/leave`, {});
		await hq.calls.idle();
		expect(
			relayCalls(sfu, '/tracks/close')
				.slice(before)
				.some((r) => r.path.includes(session)),
		).toBe(false);
	});
});

describe('call frames reach only who may see the call now', () => {
	const callFrames = (c: Connection, from: number) => c.frames.slice(from).filter((f) => f.type.startsWith('call_'));

	test('someone taken out of the room hears nothing more of it', async () => {
		const env = await setup();
		const { hq, a, b, bo, room, socket } = env;
		const boSocket = await socket(b.bearer);
		const { callId } = await boPullsAdasMic(env, room.id);
		await boSocket.settle();
		const from = boSocket.frames.length;
		hq.hub.conversations.removeMember(room.id, bo.id);
		hq.calls.sweep();
		await a.as('POST', `/v1/calls/${callId}/state`, { is_muted: true });
		await a.as('POST', `/v1/calls/${callId}/leave`, {});
		await boSocket.settle();
		expect(callFrames(boSocket, from)).toEqual([]);
	});

	test('a removed person hears nothing more, even on a socket still open', async () => {
		const env = await setup();
		const { hq, a, b, bo, dm, socket } = env;
		const boSocket = await socket(b.bearer);
		const { callId } = await boPullsAdasMic(env, dm.id);
		await boSocket.settle();
		const from = boSocket.frames.length;
		hq.hub.people.setRemoved(bo.id, Date.now());
		hq.calls.sweep();
		await a.as('POST', `/v1/calls/${callId}/state`, { is_muted: true });
		await a.as('POST', `/v1/calls/${callId}/leave`, {});
		await boSocket.settle();
		expect(callFrames(boSocket, from)).toEqual([]);
	});
});

describe('after the review', () => {
	test('a publish a rejoin overtook has its tracks closed at the relay', async () => {
		const { hq, a, dm, sfu } = await setup();
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		const release = sfu.hold();
		const late = publish(a.as, body.call.id);
		while (relayCalls(sfu, '/tracks/new').length === 0) await Bun.sleep(1);
		const rejoin = start(a.as, { kind: 'conversation', conversation_id: dm.id });
		await Bun.sleep(5);
		release();
		expect((await late).body).toEqual({ error: 'session_superseded' });
		await rejoin;
		await hq.calls.idle();
		expect(closed(sfu, body.session_id, '0')).toBe(true);
	});

	test('a join the relay fails leaves the person’s ring ringing', async () => {
		const { a, b, dm, sfu, socket } = await setup();
		const boSocket = await socket(b.bearer);
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		await boSocket.take('call_ring');
		sfu.fail('/sessions/new', 500, 1);
		expect((await start(b.as, { kind: 'conversation', conversation_id: dm.id })).status).toBe(502);
		expect((await b.as('GET', '/v1/calls')).body.ringing.map((r: Frame) => r.call.id)).toEqual([body.call.id]);
		await boSocket.settle();
		expect(boSocket.types()).not.toContain('call_ring_ended');
	});

	test('rejoins are limited per device', async () => {
		const { a, dm, clock } = await setup({ rejoinsPerWindow: 2, rejoinWindowMs: 60_000 });
		await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		for (const generation of [2, 3]) {
			expect((await start(a.as, { kind: 'conversation', conversation_id: dm.id })).body.generation).toBe(generation);
		}
		expect(await start(a.as, { kind: 'conversation', conversation_id: dm.id })).toEqual({
			status: 429,
			body: { error: 'too_many_rejoins' },
		});
		clock.advance(61_000);
		expect((await start(a.as, { kind: 'conversation', conversation_id: dm.id })).body.generation).toBe(4);
	});

	test('a failure listing calls still answers GET /v1/calls, with the meetings', async () => {
		const { hq, a } = await setup();
		await a.as('POST', '/v1/meetings', { title: 'Standup', invitee_person_ids: [] });
		hq.hub.db.exec('ALTER TABLE call_rings RENAME TO call_rings_gone');
		const quiet = spyOn(console, 'error').mockImplementation(() => {});
		try {
			const { status, body } = await a.as('GET', '/v1/calls');
			expect(status).toBe(200);
			expect(body.calls).toEqual([]);
			expect(body.ringing).toEqual([]);
			expect(body.meetings.map((m: Frame) => m.title)).toEqual(['Standup']);
			expect(quiet).toHaveBeenCalled();
		} finally {
			quiet.mockRestore();
			hq.hub.db.exec('ALTER TABLE call_rings_gone RENAME TO call_rings');
		}
	});

	test('a room call in a meeting’s room joins the meeting’s call; started there, it rings no one', async () => {
		const { a, b, events, socket } = await setup();
		const boSocket = await socket(b.bearer);
		const meeting = (await a.as('POST', '/v1/meetings', { title: 'Planning', invitee_person_ids: [b.person.id] })).body.meeting;
		const held = (await start(a.as, { kind: 'meeting', meeting_id: meeting.id })).body.call;
		const joined = (await start(b.as, { kind: 'conversation', conversation_id: meeting.conversation_id })).body.call;
		expect(joined).toMatchObject({ id: held.id, kind: 'meeting', meeting_id: meeting.id });
		await a.as('POST', `/v1/calls/${held.id}/leave`, {});
		await b.as('POST', `/v1/calls/${held.id}/leave`, {});

		const room = (await start(a.as, { kind: 'conversation', conversation_id: meeting.conversation_id })).body.call;
		expect(room).toMatchObject({ kind: 'conversation', meeting_id: null });
		await boSocket.settle();
		expect(boSocket.types()).not.toContain('call_ring');
		expect(events.filter((e) => e.type === 'call.ringing')).toEqual([]);
	});
});

describe('after the re-check', () => {
	const closesOf = (sfu: FakeSfu, from: number, session: string, mid: string) =>
		relayCalls(sfu, '/tracks/close')
			.slice(from)
			.some((r) => r.path.includes(`/sessions/${session}/`) && (r.body!.tracks as { mid: string }[]).some((t) => t.mid === mid));

	test('an unsubscribe the relay fails to close is closed again on leaving', async () => {
		const env = await setup();
		const { hq, sfu, b, room } = env;
		const { callId, session, mid } = await boPullsAdasMic(env, room.id);
		sfu.fail('/tracks/close', 500, 2);
		expect((await b.as('POST', `/v1/calls/${callId}/unsubscribe`, { mids: [mid] })).status).toBe(502);
		const from = relayCalls(sfu, '/tracks/close').length;
		await b.as('POST', `/v1/calls/${callId}/leave`, {});
		await hq.calls.idle();
		expect(closesOf(sfu, from, session, mid)).toBe(true);
	});

	test('leaving the room gives up the seat at once, before any sweep, and closes what it pulled', async () => {
		const env = await setup();
		const { hq, sfu, a, b, bo, room } = env;
		const { callId, session, mid } = await boPullsAdasMic(env, room.id);
		expect((await b.as('DELETE', `/v1/conversations/${room.id}/members/me`)).status).toBe(200);
		await hq.calls.idle();
		expect(closed(sfu, session, mid)).toBe(true);
		const seat = (await a.as('GET', `/v1/calls/${callId}`)).body.call.participants.find((p: Frame) => p.person_id === bo.id);
		expect(seat.left_at).not.toBeNull();
	});

	test('a ring stops at the next sweep once its person is out of the room', async () => {
		const { hq, a, b, bo, room, socket } = await setup();
		const boSocket = await socket(b.bearer);
		await start(a.as, { kind: 'conversation', conversation_id: room.id });
		await boSocket.take('call_ring');
		hq.hub.conversations.removeMember(room.id, bo.id);
		hq.calls.sweep();
		await boSocket.take('call_ring_ended');
		const row = hq.hub.db.query<{ state: string }, [string]>('SELECT state FROM call_rings WHERE person_id = ?').get(bo.id);
		expect(row?.state).toBe('ended');
	});

	test('an app that fails on isMeetingRoom does not fail the join', async () => {
		const broken: AppDefinition = {
			slug: 'broken',
			name: 'Broken',
			description: 'Throws when asked about rooms.',
			isMeetingRoom: () => {
				throw new Error('boom');
			},
		};
		const quiet = spyOn(console, 'error').mockImplementation(() => {});
		try {
			const { a, dm } = await setup({ apps: [meetings, broken] });
			const { status, body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
			expect(status).toBe(200);
			expect(body.call.kind).toBe('conversation');
			expect(quiet).toHaveBeenCalled();
		} finally {
			quiet.mockRestore();
		}
	});
});

describe('who may do what', () => {
	test('only someone in the room sees or joins its call; an archived room reads as missing', async () => {
		const { hq, a, b, room, dm } = await setup();
		const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
		const c = await enrolled(hq, hq.hub.keys.mint(cy.id, 'setup').secret, 'Cy Mac');
		expect(await start(c.as, { kind: 'conversation', conversation_id: dm.id })).toEqual({
			status: 404,
			body: { error: 'not_found' },
		});
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		for (const [method, path] of [
			['GET', ''],
			['GET', '/record'],
			['POST', '/decline'],
			['POST', '/leave'],
			['POST', '/state'],
			['POST', '/retranscribe'],
		] as const) {
			expect((await c.as(method, `/v1/calls/${body.call.id}${path}`, method === 'POST' ? {} : undefined)).status).toBe(404);
		}
		expect((await publish(c.as, body.call.id)).status).toBe(404);
		expect((await c.as('GET', '/v1/calls')).body.calls).toEqual([]);

		const group = await start(a.as, { kind: 'conversation', conversation_id: room.id });
		await a.as('DELETE', `/v1/conversations/${room.id}`);
		expect((await b.as('GET', `/v1/calls/${group.body.call.id}`)).status).toBe(404);
		expect((await start(b.as, { kind: 'conversation', conversation_id: room.id })).status).toBe(404);
		expect((await b.as('GET', '/v1/calls')).body.calls.map((x: Frame) => x.id)).toEqual([body.call.id]);
	});

	test('seats are for devices: a script or MCP key is refused', async () => {
		const { hq, ada, a, dm } = await setup();
		const script = client(hq, ada.key);
		const mcp = client(hq, hq.hub.keys.mint(ada.person.id, 'mcp').secret);
		for (const as of [script, mcp]) {
			expect(await start(as, { kind: 'conversation', conversation_id: dm.id })).toEqual({
				status: 403,
				body: { error: 'device_only' },
			});
		}
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		for (const path of ['/publish', '/subscribe', '/unsubscribe', '/unpublish', '/state', '/leave', '/decline']) {
			expect((await script('POST', `/v1/calls/${body.call.id}${path}`, {})).body).toEqual({ error: 'device_only' });
		}
		expect((await script('PUT', `/v1/calls/${body.call.id}/renegotiate`, {})).body).toEqual({ error: 'device_only' });
		// Reading the call is fine, and touches no seat.
		expect((await script('GET', `/v1/calls/${body.call.id}`)).status).toBe(200);
	});

	test('a device must be seated to send media or flags', async () => {
		const { a, b, dm } = await setup();
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		expect((await publish(b.as, body.call.id)).body).toEqual({ error: 'not_in_call' });
		expect((await b.as('POST', `/v1/calls/${body.call.id}/state`, { is_muted: true })).body).toEqual({ error: 'not_in_call' });
		expect(
			(await b.as('POST', `/v1/calls/${body.call.id}/subscribe`, { tracks: [{ session_id: 's', track_name: 't' }] })).body,
		).toEqual({ error: 'not_in_call' });
	});

	test('a call is full at its cap; a device already in it can still rejoin', async () => {
		const { a, b, dm } = await setup({ maxParticipants: 1 });
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		expect(await start(b.as, { kind: 'conversation', conversation_id: dm.id })).toEqual({
			status: 409,
			body: { error: 'call_full' },
		});
		expect((await start(a.as, { kind: 'conversation', conversation_id: dm.id })).body.generation).toBe(2);
		expect(body.call.id).toMatch(UUID);
	});

	test('starting calls is rate limited per person; joining one is not', async () => {
		const { a, b, dm, room, clock } = await setup({ startsPerWindow: 2, startWindowMs: 60_000 });
		const first = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		await a.as('POST', `/v1/calls/${first.body.call.id}/leave`, {});
		await start(a.as, { kind: 'conversation', conversation_id: room.id });
		expect(await start(a.as, { kind: 'conversation', conversation_id: dm.id })).toEqual({
			status: 429,
			body: { error: 'too_many_calls' },
		});
		// Bo joins Ada's live call: not a start.
		expect((await start(b.as, { kind: 'conversation', conversation_id: room.id })).status).toBe(200);
		clock.advance(61_000);
		expect((await start(a.as, { kind: 'conversation', conversation_id: dm.id })).status).toBe(200);
	});

	test('bodies are capped at 64 KB and checked: sources, mids and track counts', async () => {
		const { a, dm } = await setup();
		const { body } = await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		const url = `/v1/calls/${body.call.id}/publish`;
		const big = { session_description: { type: 'offer', sdp: 'x'.repeat(65 * 1024) }, tracks: [{ mid: '0', source: 'mic' }] };
		expect(await a.as('POST', url, big)).toEqual({ status: 413, body: { error: 'payload_too_large' } });
		const bad = async (tracks: unknown[], sdp = offer([{ mid: '0', source: 'mic' }])) =>
			(await a.as('POST', url, { session_description: { type: 'offer', sdp }, tracks })).body;
		expect(await bad([{ mid: '0', source: 'speaker' }])).toEqual({ error: 'invalid_body' });
		expect(await bad([{ mid: '0 1', source: 'mic' }])).toEqual({ error: 'invalid_body' });
		expect(await bad([])).toEqual({ error: 'invalid_body' });
		expect(
			await bad([
				{ mid: '0', source: 'mic' },
				{ mid: '0', source: 'cam' },
			]),
		).toEqual({ error: 'invalid_body' });
		expect(
			await bad([
				{ mid: '0', source: 'mic' },
				{ mid: '1', source: 'mic' },
			]),
		).toEqual({ error: 'invalid_body' });
		expect(
			await bad([
				{ mid: '0', source: 'mic' },
				{ mid: '1', source: 'cam' },
				{ mid: '2', source: 'screen' },
				{ mid: '3', source: 'cam' },
			]),
		).toEqual({ error: 'invalid_body' });
		const many = Array.from({ length: 65 }, (_, i) => ({ session_id: 's', track_name: `t${i}` }));
		expect((await a.as('POST', `/v1/calls/${body.call.id}/subscribe`, { tracks: many })).body).toEqual({ error: 'invalid_body' });
		expect((await a.as('POST', `/v1/calls/${body.call.id}/state`, { is_muted: 'yes' })).body).toEqual({ error: 'invalid_body' });
		expect((await a.as('POST', `/v1/calls/${body.call.id}/state`, { volume: 3 })).body).toEqual({ error: 'invalid_body' });
	});

	test('a signed-out device, a removed person and someone who left the room lose their seats', async () => {
		const { hq, ada, a, b, bo, room, dm, socket } = await setup();
		const adaSocket = await socket(a.bearer);
		// Signed out: the key's revocation takes the seat at once.
		const call = (await start(b.as, { kind: 'conversation', conversation_id: dm.id })).body.call;
		await start(a.as, { kind: 'conversation', conversation_id: dm.id });
		hq.hub.devices.revoke(b.deviceId);
		const left = await adaSocket.take('call_state', (f) =>
			f.call.participants.some((p: Frame) => p.device_id === b.deviceId && p.left_at !== null),
		);
		expect(left.call.ended_at).toBeNull();

		// Removed: the sweep takes the seat even before any key is revoked.
		const bo2 = await enrolled(hq, hq.hub.keys.mint(bo.id, 'setup').secret, 'Bo Phone');
		await start(bo2.as, { kind: 'conversation', conversation_id: dm.id });
		hq.hub.people.setRemoved(bo.id, Date.now());
		hq.calls.sweep();
		let roster = (await a.as('GET', `/v1/calls/${call.id}`)).body.call;
		expect(roster.participants.filter((p: Frame) => p.left_at === null).map((p: Frame) => p.person_id)).toEqual([ada.person.id]);
		hq.hub.people.setRemoved(bo.id, null);

		// Left the room: the next request, or the sweep, takes the seat.
		const group = (await start(a.as, { kind: 'conversation', conversation_id: room.id })).body.call;
		const bo3 = await enrolled(hq, hq.hub.keys.mint(bo.id, 'setup').secret, 'Bo Pad');
		await start(bo3.as, { kind: 'conversation', conversation_id: room.id });
		hq.hub.conversations.removeMember(room.id, bo.id);
		expect((await bo3.as('GET', `/v1/calls/${group.id}`)).status).toBe(404);
		roster = (await a.as('GET', `/v1/calls/${group.id}`)).body.call;
		expect(roster.participants.find((p: Frame) => p.device_id === bo3.deviceId).left_at).not.toBeNull();
		const bo4 = await enrolled(hq, hq.hub.keys.mint(bo.id, 'setup').secret, 'Bo TV');
		hq.hub.conversations.addMember(room.id, bo.id);
		await start(bo4.as, { kind: 'conversation', conversation_id: room.id });
		hq.hub.conversations.removeMember(room.id, bo.id);
		hq.calls.sweep();
		roster = (await a.as('GET', `/v1/calls/${group.id}`)).body.call;
		expect(roster.participants.find((p: Frame) => p.device_id === bo4.deviceId).left_at).not.toBeNull();
	});

	test('one device sits in one call: joining another leaves the first', async () => {
		const { a, dm, room } = await setup();
		const first = (await start(a.as, { kind: 'conversation', conversation_id: dm.id })).body.call;
		await start(a.as, { kind: 'conversation', conversation_id: room.id });
		expect((await a.as('GET', `/v1/calls/${first.id}`)).body.call.ended_at).not.toBeNull();
	});
});

describe('calls off', () => {
	test('GET /v1/calls still answers with the meetings; POST /v1/calls is 503 not_configured', async () => {
		const { a, dm } = await setup({ off: true });
		await a.as('POST', '/v1/meetings', { title: 'Standup', invitee_person_ids: [] });
		const snapshot = (await a.as('GET', '/v1/calls')).body;
		expect(snapshot.calls).toEqual([]);
		expect(snapshot.ringing).toEqual([]);
		expect(snapshot.meetings.map((m: Frame) => m.title)).toEqual(['Standup']);
		expect(await start(a.as, { kind: 'conversation', conversation_id: dm.id })).toEqual({
			status: 503,
			body: { error: 'not_configured' },
		});
	});
});

describe('calls switched off later', () => {
	test('hide the calls made while they were on', async () => {
		const dir = mkdtempSync(join(tmpdir(), 'hq-calls-'));
		cleanup.push(() => rmSync(dir, { recursive: true, force: true }));
		const sfu = startFakeSfu();
		cleanup.push(() => sfu.stop());
		const dbPath = join(dir, 'hq.sqlite');
		const relay = new CloudflareRelay({ appId: sfu.appId, secret: sfu.secret, baseUrl: sfu.url });
		const made = await pair({ dbPath, calls: { relay, log: () => {} } });
		const dm = (await made.a.as('POST', '/v1/conversations', { kind: 'dm', person_id: made.b.person.id })).body.conversation;
		await start(made.a.as, { kind: 'conversation', conversation_id: dm.id });
		expect((await made.a.as('GET', '/v1/calls')).body.calls).toHaveLength(1);
		made.hq.stop();
		const off = createHq({ dbPath, calls: { relay: null } });
		cleanup.push(() => off.stop());
		expect((await client(off, made.a.bearer)('GET', '/v1/calls')).body).toEqual({ calls: [], meetings: [], ringing: [] });
	});
});

describe('meetings', () => {
	test('joining a meeting’s call puts the person in its room, and meetings never ring', async () => {
		const { a, b, events, socket } = await setup();
		const boSocket = await socket(b.bearer);
		const meeting = (await a.as('POST', '/v1/meetings', { title: 'Planning', invitee_person_ids: [b.person.id] })).body.meeting;
		const joined = await start(a.as, { kind: 'meeting', meeting_id: meeting.id });
		expect(joined.status).toBe(200);
		expect(joined.body.call).toMatchObject({
			kind: 'meeting',
			meeting_id: meeting.id,
			conversation_id: meeting.conversation_id,
			title: 'Planning',
		});
		const bo = await start(b.as, { kind: 'meeting', meeting_id: meeting.id });
		expect(bo.body.call.id).toBe(joined.body.call.id);
		await boSocket.settle();
		expect(boSocket.types()).not.toContain('call_ring');
		expect(events.filter((e) => e.type === 'call.ringing')).toEqual([]);
		await a.as('POST', `/v1/calls/${joined.body.call.id}/leave`, {});
		await b.as('POST', `/v1/calls/${joined.body.call.id}/leave`, {});
		expect(events.find((e) => e.type === 'call.ended')).toMatchObject({ meetingId: meeting.id });
	});

	test('someone who can see a meeting but is not in its room is added to it on joining', async () => {
		const { hq, a, b, room } = await setup();
		hq.hub.conversations.removeMember(room.id, b.person.id);
		// A meeting held in a shared room Bo is invited to, though he is not in the room.
		const { Meetings } = await import('../apps/meetings/store');
		const meeting = new Meetings(hq.hub).schedule({
			title: 'Review',
			startsAt: Date.now(),
			endsAt: Date.now() + 1_800_000,
			roomId: room.id,
			organizerId: a.person.id,
			attendeeIds: [b.person.id],
		});
		expect((await start(b.as, { kind: 'meeting', meeting_id: meeting.id })).status).toBe(200);
		expect(hq.hub.conversations.isMember(room.id, b.person.id)).toBe(true);
	});

	test('a meeting held in a shared room does not ring either', async () => {
		const { hq, a, b, room, events, socket } = await setup();
		const boSocket = await socket(b.bearer);
		const { Meetings } = await import('../apps/meetings/store');
		const meeting = new Meetings(hq.hub).schedule({
			title: 'Sync',
			startsAt: Date.now(),
			endsAt: Date.now() + 1_800_000,
			roomId: room.id,
			organizerId: a.person.id,
			attendeeIds: [b.person.id],
		});
		expect((await start(a.as, { kind: 'meeting', meeting_id: meeting.id })).body.call.kind).toBe('meeting');
		await boSocket.settle();
		expect(boSocket.types()).not.toContain('call_ring');
		expect(events.filter((e) => e.type === 'call.ringing')).toEqual([]);
	});

	test('a Quick Call makes a meeting with its own room; a cancelled or unseen meeting opens no call', async () => {
		const { hq, a, b } = await setup();
		const quick = await start(a.as, { kind: 'meeting' });
		expect(quick.status).toBe(200);
		expect(quick.body.call).toMatchObject({ kind: 'meeting', title: 'Quick call' });
		const listed = (await a.as('GET', '/v1/calls')).body.meetings;
		expect(listed.find((m: Frame) => m.id === quick.body.call.meeting_id).conversation_id).toBe(quick.body.call.conversation_id);
		const people = hq.hub.conversations
			.memberIds(quick.body.call.conversation_id)
			.filter((id) => hq.hub.people.get(id)?.kind === 'human');
		expect(people).toEqual([a.person.id]);

		const hidden = (await a.as('POST', '/v1/meetings', { title: 'Private', invitee_person_ids: [] })).body.meeting;
		expect(await start(b.as, { kind: 'meeting', meeting_id: hidden.id })).toEqual({
			status: 404,
			body: { error: 'meeting_not_found' },
		});
		await a.as('DELETE', `/v1/meetings/${hidden.id}`);
		expect(await start(a.as, { kind: 'meeting', meeting_id: hidden.id })).toEqual({
			status: 409,
			body: { error: 'meeting_cancelled' },
		});
	});

	test('a meeting held in a direct message lets no third person in', async () => {
		const { hq, a, b, dm } = await setup();
		const cy = hq.hub.people.create({ name: 'Cy', handle: 'cy' });
		const c = await enrolled(hq, hq.hub.keys.mint(cy.id, 'setup').secret, 'Cy Mac');
		const { Meetings } = await import('../apps/meetings/store');
		const meeting = new Meetings(hq.hub).schedule({
			title: 'One to one',
			startsAt: Date.now(),
			endsAt: Date.now() + 1_800_000,
			roomId: dm.id,
			organizerId: a.person.id,
			attendeeIds: [b.person.id, cy.id],
		});
		expect(await start(c.as, { kind: 'meeting', meeting_id: meeting.id })).toEqual({
			status: 404,
			body: { error: 'meeting_not_found' },
		});
		expect(hq.hub.conversations.isMember(dm.id, cy.id)).toBe(false);
	});

	test('without a meetings app a meeting call has nowhere to go', async () => {
		const { a } = await setup({ apps: [] });
		expect(await start(a.as, { kind: 'meeting' })).toEqual({ status: 404, body: { error: 'meeting_not_found' } });
	});
});

describe('the calls tables', () => {
	test('are calls/001', async () => {
		const { hq } = await setup();
		expect(hq.hub.db.query("SELECT id FROM _migrations WHERE id LIKE 'calls/%'").all()).toEqual([
			{ id: 'calls/001_calls' },
			{ id: 'calls/002_recordings' },
			{ id: 'calls/003_retranscribe_requests' },
		]);
	});
});
