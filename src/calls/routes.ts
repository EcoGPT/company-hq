import { z } from 'zod';
import { limitBody } from '../apps/mount';
import { HttpError, Router, type RequestContext } from '../http/router';
import { parse } from '../wire/routes';
import type { CallRecords } from './recording-routes';
import { relayFailure, type Calls } from './service';
import { FLAG_OF, type Source } from './store';

/** An SDP offer is a few kilobytes; nothing a call route takes comes near this. */
export const CALL_BODY_BYTES = 64 * 1024;
const MAX_SDP = 60_000;
/** The most tracks one subscribe or unsubscribe names. The relay takes up to 64 a request. */
const MAX_TRACKS = 64;

const SOURCES = ['mic', 'cam', 'screen'] as const;
/** A transceiver id as WebRTC writes it in SDP (`a=mid:0`). */
const mid = z.string().regex(/^[A-Za-z0-9_.-]{1,32}$/);
const sdp = (type: 'offer' | 'answer') => z.object({ sdp: z.string().min(1).max(MAX_SDP), type: z.literal(type) });
const distinct = (values: string[]) => new Set(values).size === values.length;

const schemas = {
	join: z.object({
		client_build: z.string().max(200).optional(),
		kind: z.enum(['conversation', 'meeting']),
		conversation_id: z.string().min(1).max(64).optional(),
		meeting_id: z.string().min(1).max(64).nullish(),
	}),
	publish: z.object({
		session_description: sdp('offer'),
		tracks: z
			.array(z.object({ mid, source: z.enum(SOURCES), is_enabled: z.boolean().optional() }))
			.min(1)
			.max(SOURCES.length)
			.refine((tracks) => distinct(tracks.map((t) => t.source)) && distinct(tracks.map((t) => t.mid))),
	}),
	subscribe: z.object({
		tracks: z
			.array(z.object({ session_id: z.string().min(1).max(128), track_name: z.string().min(1).max(128) }))
			.min(1)
			.max(MAX_TRACKS),
	}),
	renegotiate: z.object({ session_description: sdp('answer') }),
	unsubscribe: z.object({ mids: z.array(mid).min(1).max(MAX_TRACKS) }),
	unpublish: z.object({ mids: z.array(mid).max(SOURCES.length), sources: z.array(z.enum(SOURCES)).min(1).max(SOURCES.length) }),
	state: z
		.object({
			is_muted: z.boolean().optional(),
			is_camera_on: z.boolean().optional(),
			is_screen_sharing: z.boolean().optional(),
			is_hand_raised: z.boolean().optional(),
		})
		.strict(),
};

const body = <S extends z.ZodType>(ctx: RequestContext, schema: S) => parse(limitBody(ctx.req, CALL_BODY_BYTES), schema);

/** A seat is a device's: a script's or an MCP key cannot sit in a call. */
function deviceOf(ctx: RequestContext) {
	const device = ctx.hub.devices.byKey(ctx.keyId);
	if (device === null) throw new HttpError(403, 'device_only');
	if (!ctx.hub.keys.isActive(ctx.keyId)) throw new HttpError(401, 'unauthorized');
	return device;
}

/** Every call route but `GET /v1/calls`, which core serves with the apps' lists. */
export function callRoutes(calls: Calls, records: CallRecords): Router {
	/** The call and the caller's live seat in it, read again on every request. */
	const inCall = (ctx: RequestContext) => {
		const device = deviceOf(ctx);
		const call = calls.readable(ctx.person, ctx.params.id ?? '', device.id);
		return { call, seat: calls.seated(call, device.id), device };
	};
	const relay = () => {
		if (calls.relay === null) throw new HttpError(503, 'not_configured');
		return calls.relay;
	};

	return (
		new Router()
			.post('/v1/calls', async (ctx) => {
				deviceOf(ctx);
				const input = await body(ctx, schemas.join);
				// Asked again once the body is in: the device may have been signed out while it arrived.
				const joined = await calls.join(
					{ person: ctx.person, deviceId: deviceOf(ctx).id },
					{ kind: input.kind, conversationId: input.conversation_id, meetingId: input.meeting_id },
				);
				return {
					call: calls.present(joined.call),
					session_id: joined.sessionId,
					generation: joined.seat.generation,
					capabilities: ['quiet_tracks'],
				};
			})
			.get('/v1/calls/:id', (ctx) => {
				const device = ctx.hub.devices.byKey(ctx.keyId);
				const call = calls.readable(ctx.person, ctx.params.id ?? '', device?.id ?? null);
				// Reading the roster is the app's heartbeat over HTTP.
				if (device !== null) calls.heartbeat(call.id, device.id);
				return { call: calls.present(call) };
			})
			.post('/v1/calls/:id/publish', async (ctx) => {
				deviceOf(ctx);
				const input = await body(ctx, schemas.publish);
				const { call, seat, device } = inCall(ctx);
				// The server names every track; a client never picks the name another device subscribes to.
				const tracks = input.tracks.map((t) => ({
					mid: t.mid,
					source: t.source as Source,
					trackName: `${device.id}-${t.source}`,
				}));
				const result = await calls
					.serialized(seat.session_id, () => relay().publish(seat.session_id, input.session_description, tracks))
					.catch(relayFailure);
				const refusedMids = new Map(result.tracks.filter((t) => t.errorCode !== undefined).map((t) => [t.mid, t.errorCode!]));
				const accepted = tracks.filter((t) => !refusedMids.has(t.mid));
				calls.stillOrClose(seat, accepted);
				calls.store.addTracks(seat, seat.session_id, accepted, calls.now());
				calls.sendState(call.id);
				return {
					session_description: result.answer,
					refused: tracks
						.filter((t) => refusedMids.has(t.mid))
						.map((t) => ({ mid: t.mid, source: t.source, error_code: refusedMids.get(t.mid)! })),
				};
			})
			.post('/v1/calls/:id/subscribe', async (ctx) => {
				deviceOf(ctx);
				const input = await body(ctx, schemas.subscribe);
				const { call, seat } = inCall(ctx);
				// Only tracks in this call's roster now: one relay app serves every call, so a session id and a track name from
				// elsewhere must not pull another call's media.
				const roster = new Set(calls.present(call).tracks.map((t) => `${t.session_id} ${t.track_name}`));
				const known = input.tracks.filter((t) => roster.has(`${t.session_id} ${t.track_name}`));
				const unknown = input.tracks
					.filter((t) => !roster.has(`${t.session_id} ${t.track_name}`))
					.map((t) => ({ track_name: t.track_name, error_code: 'unknown_track' }));
				if (known.length === 0) return { tracks: unknown, requires_immediate_renegotiation: false };
				const result = await calls
					.serialized(seat.session_id, () =>
						relay().subscribe(
							seat.session_id,
							known.map((t) => ({ sessionId: t.session_id, trackName: t.track_name })),
						),
					)
					.catch(relayFailure);
				const pulled = result.tracks.flatMap((t) =>
					t.mid !== undefined && t.errorCode === undefined ? [{ mid: t.mid, trackName: t.trackName ?? '' }] : [],
				);
				calls.stillOrClose(seat, pulled);
				// Kept per seat, so whatever takes the seat out also stops what it receives.
				calls.store.addPulls(seat, pulled, calls.now());
				return {
					tracks: [
						...result.tracks.map((t) => ({
							...(t.mid === undefined ? {} : { mid: t.mid }),
							...(t.trackName === undefined ? {} : { track_name: t.trackName }),
							...(t.errorCode === undefined ? {} : { error_code: t.errorCode }),
						})),
						...unknown,
					],
					requires_immediate_renegotiation: result.renegotiate,
					...(result.offer === null ? {} : { session_description: result.offer }),
				};
			})
			.put('/v1/calls/:id/renegotiate', async (ctx) => {
				deviceOf(ctx);
				const input = await body(ctx, schemas.renegotiate);
				const { seat } = inCall(ctx);
				await calls
					.serialized(seat.session_id, () => relay().renegotiate(seat.session_id, input.session_description))
					.catch(relayFailure);
				calls.still(seat);
				return { ok: true };
			})
			.post('/v1/calls/:id/unsubscribe', async (ctx) => {
				deviceOf(ctx);
				const input = await body(ctx, schemas.unsubscribe);
				// The caller's own session, as stored: never one named in the body.
				const { call, seat, device } = inCall(ctx);
				// Ended only once the relay has closed them: a close that fails stays on the seat, and leaving closes it again.
				await calls.serialized(seat.session_id, () => relay().closeTracks(seat.session_id, input.mids)).catch(relayFailure);
				calls.store.endPulls(call.id, device.id, input.mids, calls.now());
				return { ok: true };
			})
			.post('/v1/calls/:id/unpublish', async (ctx) => {
				deviceOf(ctx);
				const input = await body(ctx, schemas.unpublish);
				const { call, seat, device } = inCall(ctx);
				const sources = input.sources as Source[];
				calls.store.endTracks(call.id, device.id, sources, calls.now());
				calls.store.setFlags(
					call.id,
					device.id,
					Object.fromEntries(sources.flatMap((s) => (FLAG_OF[s] === null ? [] : [[FLAG_OF[s], false]]))),
				);
				calls.sendState(call.id);
				if (input.mids.length > 0) {
					await calls.serialized(seat.session_id, () => relay().closeTracks(seat.session_id, input.mids)).catch(relayFailure);
				}
				return { ok: true };
			})
			.post('/v1/calls/:id/state', async (ctx) => {
				deviceOf(ctx);
				const input = await body(ctx, schemas.state);
				const device = deviceOf(ctx);
				const call = calls.readable(ctx.person, ctx.params.id ?? '', device.id);
				const seat = calls.store.seat(call.id, device.id);
				if (call.ended_at !== null || seat === null || seat.left_at !== null) throw new HttpError(409, 'not_in_call');
				calls.store.setFlags(call.id, device.id, input);
				calls.sendState(call.id);
				return { call: calls.present(calls.store.get(call.id)!) };
			})
			.post('/v1/calls/:id/decline', (ctx) => {
				const device = deviceOf(ctx);
				calls.decline(calls.readable(ctx.person, ctx.params.id ?? '', device.id), ctx.person.id);
				return { ok: true };
			})
			.post('/v1/calls/:id/leave', (ctx) => {
				const device = deviceOf(ctx);
				const call = calls.readable(ctx.person, ctx.params.id ?? '', device.id);
				calls.leaveSeat(call.id, device.id);
				return { ok: true };
			})
			// --- recordings, transcripts and recaps (recording-routes.ts) ---
			.get('/v1/calls/:id/record', (ctx) => records.record(calls.readable(ctx.person, ctx.params.id ?? '', null).id))
			.get('/v1/calls/:id/recording/:deviceId', (ctx) => {
				// Audio is for the apps: a script's or an MCP key reads the transcript but cannot download what people said.
				deviceOf(ctx);
				const call = calls.readable(ctx.person, ctx.params.id ?? '', null);
				return records.recording(call.id, ctx.params.deviceId ?? '');
			})
			.post('/v1/calls/:id/retranscribe', async (ctx) => {
				deviceOf(ctx);
				await body(ctx, z.object({}));
				records.transcripts.retranscribe(calls.readable(ctx.person, ctx.params.id ?? '', null).id, ctx.person.id);
				return { ok: true };
			})
		// --- end recordings ---
	);
}
