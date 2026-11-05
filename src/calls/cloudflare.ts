import { RelayError, type CallRelay, type RelayTrack, type SessionDescription } from './relay';

export const CLOUDFLARE_REALTIME_URL = 'https://rtc.live.cloudflare.com/v1';

export type CloudflareOptions = {
	appId: string;
	secret: string;
	/** The API root, `https://rtc.live.cloudflare.com/v1` unless a test or a compatible relay stands in. */
	baseUrl?: string;
	fetch?: typeof fetch;
	timeoutMs?: number;
	retryDelayMs?: number;
};

type Json = Record<string, unknown>;

const isDescription = (value: unknown): value is SessionDescription =>
	typeof value === 'object' &&
	value !== null &&
	typeof (value as Json).sdp === 'string' &&
	((value as Json).type === 'offer' || (value as Json).type === 'answer');

function tracksOf(body: Json): RelayTrack[] {
	if (!Array.isArray(body.tracks)) throw new RelayError('sfu_bad_response');
	return body.tracks.map((raw: unknown) => {
		const track = (raw ?? {}) as Json;
		const text = (key: string) => (typeof track[key] === 'string' ? (track[key] as string) : undefined);
		return { mid: text('mid'), trackName: text('trackName'), errorCode: text('errorCode') };
	});
}

/** Cloudflare Realtime's SFU over its HTTPS API: one app (id and secret) for every call on this server. */
export class CloudflareRelay implements CallRelay {
	readonly name = 'cloudflare';
	private readonly base: string;
	private readonly fetch: typeof fetch;
	private readonly timeoutMs: number;
	private readonly retryDelayMs: number;

	constructor(private readonly options: CloudflareOptions) {
		this.base = `${(options.baseUrl ?? CLOUDFLARE_REALTIME_URL).replace(/\/+$/, '')}/apps/${encodeURIComponent(options.appId)}`;
		this.fetch = options.fetch ?? fetch;
		this.timeoutMs = options.timeoutMs ?? 10_000;
		this.retryDelayMs = options.retryDelayMs ?? 300;
	}

	async newSession() {
		// Not retried: after a timeout the first may have made a session, and a second would leave one behind.
		const body = await this.once('POST', '/sessions/new');
		if (typeof body.sessionId !== 'string' || body.sessionId === '') throw new RelayError('sfu_bad_response');
		return { sessionId: body.sessionId };
	}

	async publish(sessionId: string, offer: SessionDescription, tracks: { mid: string; trackName: string }[]) {
		const body = await this.once('POST', `/sessions/${encodeURIComponent(sessionId)}/tracks/new`, {
			sessionDescription: offer,
			tracks: tracks.map((t) => ({ location: 'local', mid: t.mid, trackName: t.trackName })),
		});
		if (!isDescription(body.sessionDescription)) throw new RelayError('sfu_bad_response');
		return { answer: body.sessionDescription, tracks: tracksOf(body) };
	}

	async subscribe(sessionId: string, tracks: { sessionId: string; trackName: string }[]) {
		const body = await this.once('POST', `/sessions/${encodeURIComponent(sessionId)}/tracks/new`, {
			tracks: tracks.map((t) => ({ location: 'remote', sessionId: t.sessionId, trackName: t.trackName })),
		});
		const renegotiate = body.requiresImmediateRenegotiation === true;
		const offer = isDescription(body.sessionDescription) ? body.sessionDescription : null;
		if (renegotiate && offer === null) throw new RelayError('sfu_bad_response');
		return { offer, renegotiate, tracks: tracksOf(body) };
	}

	async renegotiate(sessionId: string, answer: SessionDescription) {
		await this.once('PUT', `/sessions/${encodeURIComponent(sessionId)}/renegotiate`, { sessionDescription: answer });
	}

	async closeTracks(sessionId: string, mids: string[]) {
		await this.idempotent('PUT', `/sessions/${encodeURIComponent(sessionId)}/tracks/close`, {
			force: true,
			tracks: mids.map((mid) => ({ mid })),
		});
	}

	/** Never retried: a second offer on a peer connection that took the first would break it, and a second session is waste. */
	private once(method: string, path: string, body?: unknown): Promise<Json> {
		return this.request(method, path, body);
	}

	/** For closing tracks, the one request that is safe to send twice: retried once after a short wait, and only when the relay could not be reached. */
	private async idempotent(method: string, path: string, body?: unknown): Promise<Json> {
		try {
			return await this.request(method, path, body);
		} catch (error) {
			if (!(error instanceof RelayError) || error.code !== 'sfu_unavailable') throw error;
			await Bun.sleep(this.retryDelayMs);
			return this.request(method, path, body);
		}
	}

	private async request(method: string, path: string, body?: unknown): Promise<Json> {
		let response: Response;
		try {
			response = await this.fetch(`${this.base}${path}`, {
				method,
				headers: { authorization: `Bearer ${this.options.secret}`, 'content-type': 'application/json' },
				body: body === undefined ? undefined : JSON.stringify(body),
				signal: AbortSignal.timeout(this.timeoutMs),
			});
		} catch {
			throw new RelayError('sfu_unavailable');
		}
		if (response.status >= 500) throw new RelayError('sfu_unavailable');
		if (response.status >= 400) throw new RelayError('sfu_rejected');
		let parsed: unknown;
		try {
			parsed = await response.json();
		} catch {
			throw new RelayError('sfu_bad_response');
		}
		if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) throw new RelayError('sfu_bad_response');
		if (typeof (parsed as Json).errorCode === 'string') throw new RelayError('sfu_rejected');
		return parsed as Json;
	}
}
