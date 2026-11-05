import http2 from 'node:http2';
import type { PushEnvironment, PushMessage, PushProvider, PushResult, PushTarget } from './provider';

const APPLE: Record<PushEnvironment, string> = {
	development: 'https://api.sandbox.push.apple.com',
	production: 'https://api.push.apple.com',
};

/** Apple wants a provider token no older than an hour and at most one new one per 20 minutes. */
const TOKEN_LIFETIME_MS = 45 * 60_000;
const REQUEST_TIMEOUT_MS = 15_000;
/**
 * After a refusal of the provider token, a new one is made and the push retried at most this often. With a wrong key id or
 * team id every push would be refused, and Apple answers too many new tokens with TooManyProviderTokenUpdates.
 */
const RETRY_TOKEN_EVERY_MS = 20 * 60_000;
/** Apple's answers are a few bytes of JSON; anything past this is not one. */
const MAX_ANSWER_BYTES = 4096;
const STALE_PROVIDER_TOKEN = new Set(['ExpiredProviderToken', 'InvalidProviderToken']);

export type ApnsOptions = {
	/** The .p8 key's PEM text. */
	key: string;
	keyId: string;
	teamId: string;
	/** The app's bundle id. */
	topic: string;
	/** Where to connect, for tests: one origin for both environments, or one each. Defaults to Apple's. */
	baseUrl?: string | Partial<Record<PushEnvironment, string>>;
	/** Passed to `http2.connect`; tests give it the local server's certificate. */
	connect?: http2.SecureClientSessionOptions;
	clock?: () => number;
	requestTimeoutMs?: number;
};

const base64url = (data: string | Uint8Array) => Buffer.from(data).toString('base64url');

/** The provider JWT: ES256 over `{iss, iat}`, made once at a time and kept for about 45 minutes. */
class ProviderToken {
	private signing: Promise<CryptoKey> | null = null;
	private current: { jwt: string; at: number } | null = null;
	private minting: Promise<string> | null = null;

	constructor(private readonly options: Pick<ApnsOptions, 'key' | 'keyId' | 'teamId'> & { clock: () => number }) {}

	get(): Promise<string> {
		const { current } = this;
		if (current !== null && this.options.clock() - current.at < TOKEN_LIFETIME_MS) return Promise.resolve(current.jwt);
		this.minting ??= this.mint().finally(() => {
			this.minting = null;
		});
		return this.minting;
	}

	/** Forgets `jwt` if it is still the cached one; a request that lost a race to a newer token leaves the newer one alone. */
	evict(jwt: string): void {
		if (this.current?.jwt === jwt) this.current = null;
	}

	private async mint(): Promise<string> {
		const at = this.options.clock();
		const header = base64url(JSON.stringify({ alg: 'ES256', kid: this.options.keyId }));
		const claims = base64url(JSON.stringify({ iss: this.options.teamId, iat: Math.floor(at / 1000) }));
		const signed = `${header}.${claims}`;
		const signature = await crypto.subtle.sign(
			{ name: 'ECDSA', hash: 'SHA-256' },
			await this.signingKey(),
			new TextEncoder().encode(signed),
		);
		const jwt = `${signed}.${base64url(new Uint8Array(signature))}`;
		this.current = { jwt, at };
		return jwt;
	}

	private signingKey(): Promise<CryptoKey> {
		this.signing ??= crypto.subtle
			.importKey('pkcs8', pemBody(this.options.key), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
			.catch((error: unknown) => {
				this.signing = null;
				throw error;
			});
		return this.signing;
	}
}

function pemBody(pem: string): Uint8Array<ArrayBuffer> {
	const base64 = pem.replace(/-----(BEGIN|END) [A-Z ]+-----/g, '').replace(/\s+/g, '');
	return new Uint8Array(Buffer.from(base64, 'base64'));
}

type Answer = { status: number; reason: string | undefined };

/** What a status and Apple's `reason` mean for us. Only an `Unregistered` 410 says the device is gone. */
function classify({ status, reason }: Answer): PushResult {
	if (status === 200) return { outcome: 'sent' };
	const why = reason ?? String(status);
	if (status === 410 && reason === 'Unregistered') return { outcome: 'invalid_token', reason: why };
	// A wrong environment or topic is ours to fix and says nothing about the device: never clear a token for it.
	if (reason === 'BadDeviceToken' || reason === 'DeviceTokenNotForTopic') return { outcome: 'config', reason: why };
	if (status === 403) return { outcome: 'config', reason: why };
	if (status === 429 || status >= 500) return { outcome: 'transient', reason: why };
	return { outcome: 'fatal', reason: why };
}

/** The words of a ring's banner, for a device with no ring token. */
export const RING_TITLE = 'Incoming call';
export const ringBody = (callerName: string, conversationTitle: string | null) =>
	conversationTitle === null ? `${callerName} is calling` : `${callerName} is calling in ${conversationTitle}`;

function describe(message: PushMessage, topic: string) {
	if (message.type === 'ring') {
		// Apple keeps trying until then, and drops the push after: a ring that arrives late rings for a call already over.
		const expiration = String(Math.max(0, Math.floor(Date.parse(message.expiresAt) / 1000)));
		if (message.channel === 'voip') {
			return {
				headers: {
					'apns-push-type': 'voip',
					'apns-topic': `${topic}.voip`,
					'apns-priority': '10',
					'apns-expiration': expiration,
				},
				payload: {
					call_id: message.callId,
					caller_name: message.callerName,
					conversation_id: message.conversationId,
					conversation_title: message.conversationTitle,
					expires_at: message.expiresAt,
				},
			};
		}
		return {
			headers: {
				'apns-push-type': 'alert',
				'apns-topic': topic,
				'apns-priority': '10',
				'apns-collapse-id': `ring:${message.callId}`,
				'apns-expiration': expiration,
			},
			payload: {
				// `content-available` wakes the phone to read `GET /v1/calls`, where the ring is and CallKit picks it up.
				aps: {
					alert: { title: RING_TITLE, body: ringBody(message.callerName, message.conversationTitle) },
					sound: 'default',
					'content-available': 1,
				},
				call_id: message.callId,
				conversation_id: message.conversationId,
			},
		};
	}
	if (message.type === 'message') {
		return {
			headers: {
				'apns-push-type': 'alert',
				'apns-topic': topic,
				'apns-priority': '10',
				'apns-collapse-id': message.messageId,
			},
			payload: {
				aps: { alert: { title: message.title, body: message.body }, sound: 'default', 'thread-id': message.conversationId },
				conversation_id: message.conversationId,
				message_id: message.messageId,
			},
		};
	}
	return {
		headers: {
			'apns-push-type': 'background',
			'apns-topic': topic,
			'apns-priority': '5',
			'apns-collapse-id': `read:${message.conversationId}`,
		},
		payload: {
			aps: { 'content-available': 1 },
			conversation_id: message.conversationId,
			read_through_message_id: message.readThroughMessageId,
		},
	};
}

/** Apple Push Notification service over HTTP/2 with a provider token (the .p8 key). */
export class ApnsProvider implements PushProvider {
	readonly name = 'APNs';
	private readonly token: ProviderToken;
	private readonly sessions = new Map<string, http2.ClientHttp2Session>();
	private readonly clock: () => number;
	private lastTokenRetry = -Infinity;
	private closed = false;

	constructor(private readonly options: ApnsOptions) {
		this.clock = options.clock ?? Date.now;
		this.token = new ProviderToken({ ...options, clock: this.clock });
	}

	async send(target: PushTarget, message: PushMessage): Promise<PushResult> {
		const { headers, payload } = describe(message, this.options.topic);
		const origin = this.origin(target.environment);
		const body = JSON.stringify(payload);
		const post = async (jwt: string): Promise<Answer> =>
			this.request(
				origin,
				{
					':method': 'POST',
					':path': `/3/device/${target.token}`,
					'content-type': 'application/json',
					authorization: `bearer ${jwt}`,
					...headers,
				},
				body,
			);

		let jwt: string;
		try {
			jwt = await this.token.get();
		} catch {
			return { outcome: 'config', reason: 'the key could not sign (is it a .p8 key?)' };
		}
		try {
			let answer = await post(jwt);
			if (
				answer.status === 403 &&
				answer.reason !== undefined &&
				STALE_PROVIDER_TOKEN.has(answer.reason) &&
				this.mayRetryWithNewToken()
			) {
				this.token.evict(jwt);
				answer = await post(await this.token.get());
			}
			return classify(answer);
		} catch (error) {
			const code = (error as { code?: string }).code;
			return { outcome: 'transient', reason: `network${code === undefined ? '' : ` ${code}`}` };
		}
	}

	private mayRetryWithNewToken(): boolean {
		const at = this.clock();
		if (at - this.lastTokenRetry < RETRY_TOKEN_EVERY_MS) return false;
		this.lastTokenRetry = at;
		return true;
	}

	/** Closes every connection. A push still being made afterwards fails instead of opening a new one. */
	close(): void {
		this.closed = true;
		for (const session of this.sessions.values()) session.close();
		this.sessions.clear();
	}

	private origin(environment: PushEnvironment): string {
		const { baseUrl } = this.options;
		return typeof baseUrl === 'string' ? baseUrl : (baseUrl?.[environment] ?? APPLE[environment]);
	}

	private session(origin: string): http2.ClientHttp2Session {
		if (this.closed) throw Object.assign(new Error('closed'), { code: 'ECLOSED' });
		const known = this.sessions.get(origin);
		if (known !== undefined && !known.closed && !known.destroyed) return known;
		const session = http2.connect(origin, this.options.connect);
		session.on('error', () => this.drop(origin, session));
		session.on('close', () => this.drop(origin, session));
		// A goaway lets what is in flight finish; new pushes go to a new connection.
		session.on('goaway', () => this.retire(origin, session));
		// An idle connection must not keep a command-line run from exiting.
		session.unref();
		this.sessions.set(origin, session);
		return session;
	}

	/** Stops using a connection for new pushes and lets what is in flight on it finish. */
	private retire(origin: string, session: http2.ClientHttp2Session): void {
		if (this.sessions.get(origin) === session) this.sessions.delete(origin);
		if (!session.closed) session.close();
	}

	/** Forgets a connection and closes it (what is in flight on it fails, and the next push connects afresh). */
	private drop(origin: string, session: http2.ClientHttp2Session): void {
		if (this.sessions.get(origin) === session) this.sessions.delete(origin);
		if (!session.destroyed) session.destroy();
	}

	/** One request. A connection that went stale between pushes is replaced once, before anything is sent. */
	private async request(origin: string, headers: http2.OutgoingHttpHeaders, body: string): Promise<Answer> {
		let session = this.session(origin);
		let stream: http2.ClientHttp2Stream;
		try {
			stream = session.request(headers);
		} catch {
			this.drop(origin, session);
			session = this.session(origin);
			stream = session.request(headers);
		}
		const timeoutMs = this.options.requestTimeoutMs ?? REQUEST_TIMEOUT_MS;
		return new Promise<Answer>((resolve, reject) => {
			let status = 0;
			let size = 0;
			const chunks: Buffer[] = [];
			let settled = false;
			const settle = (finish: () => void) => {
				if (settled) return;
				settled = true;
				clearTimeout(timer);
				finish();
			};
			const timer = setTimeout(
				() =>
					settle(() => {
						stream.close(http2.constants.NGHTTP2_CANCEL);
						// A connection that went quiet without closing would time out every push after this one too. The other
						// pushes on it are not at fault, so they are left to finish (or time out themselves).
						this.retire(origin, session);
						reject(Object.assign(new Error('timed out'), { code: 'ETIMEDOUT' }));
					}),
				timeoutMs,
			);
			stream.on('response', (received) => {
				status = Number(received[':status']);
			});
			stream.on('data', (chunk: Buffer) => {
				size += chunk.length;
				if (size <= MAX_ANSWER_BYTES) chunks.push(chunk);
			});
			stream.on('end', () =>
				settle(() =>
					status === 0
						? // A stream that ended with no response never reached Apple (refused, or a certificate we do not trust).
							reject(Object.assign(new Error('no response'), { code: 'ECONNRESET' }))
						: resolve({ status, reason: reasonOf(Buffer.concat(chunks).toString('utf8')) }),
				),
			);
			stream.on('error', (error) => settle(() => reject(error)));
			stream.on('close', () => settle(() => reject(Object.assign(new Error('closed'), { code: 'ECONNRESET' }))));
			stream.end(body);
		});
	}
}

function reasonOf(text: string): string | undefined {
	try {
		const reason = (JSON.parse(text) as { reason?: unknown }).reason;
		return typeof reason === 'string' ? reason : undefined;
	} catch {
		return undefined;
	}
}
