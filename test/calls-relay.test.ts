import { afterEach, describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { callsFromEnv, CloudflareRelay, RelayError } from '../src/calls';
import { answerFor, offerFor, startFakeSfu } from './fake-sfu';
import { fakeFetch } from './helpers';

// The Cloudflare adapter on its own: where it sends what, which requests it retries, and how failures read. And the
// environment settings that turn calls on.

const stops: (() => void)[] = [];
afterEach(() => {
	for (const stop of stops.splice(0)) stop();
});

const offer = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=sendonly\r\na=rtpmap:111 opus/48000/2\r\n';

async function code(promise: Promise<unknown>): Promise<string> {
	try {
		await promise;
	} catch (error) {
		if (error instanceof RelayError) return error.code;
		throw error;
	}
	return 'ok';
}

describe('the Cloudflare relay', () => {
	test('speaks the HTTPS API: the app in the path, the secret as a bearer, local and remote tracks', async () => {
		const fake = fakeFetch((url) =>
			url.endsWith('/sessions/new')
				? { sessionId: 's1' }
				: url.endsWith('/tracks/new')
					? { sessionDescription: { type: 'answer', sdp: 'v=0' }, tracks: [{ mid: '0', trackName: 'd-mic' }] }
					: {},
		);
		const relay = new CloudflareRelay({
			appId: 'app 1',
			secret: 'shh',
			baseUrl: 'https://relay.example.test/v1/',
			fetch: fake.impl,
		});
		expect(await relay.newSession()).toEqual({ sessionId: 's1' });
		await relay.publish('s1', { type: 'offer', sdp: offer }, [{ mid: '0', trackName: 'd-mic' }]);
		await relay.renegotiate('s1', { type: 'answer', sdp: 'v=0' });
		await relay.closeTracks('s1', ['0']);
		expect(fake.calls.map((c) => [c.init.method, c.url])).toEqual([
			['POST', 'https://relay.example.test/v1/apps/app%201/sessions/new'],
			['POST', 'https://relay.example.test/v1/apps/app%201/sessions/s1/tracks/new'],
			['PUT', 'https://relay.example.test/v1/apps/app%201/sessions/s1/renegotiate'],
			['PUT', 'https://relay.example.test/v1/apps/app%201/sessions/s1/tracks/close'],
		]);
		expect(new Headers(fake.calls[0]!.init.headers).get('authorization')).toBe('Bearer shh');
		expect(JSON.parse(String(fake.calls[1]!.init.body))).toEqual({
			sessionDescription: { type: 'offer', sdp: offer },
			tracks: [{ location: 'local', mid: '0', trackName: 'd-mic' }],
		});
		expect(JSON.parse(String(fake.calls[3]!.init.body))).toEqual({ force: true, tracks: [{ mid: '0' }] });
	});

	test('retries once, only what is safe to send twice', async () => {
		let failing = 0;
		const fake = fakeFetch(() => (failing-- > 0 ? new Response('down', { status: 503 }) : { sessionId: 's' }));
		const relay = new CloudflareRelay({
			appId: 'a',
			secret: 's',
			baseUrl: 'https://r.example.test',
			fetch: fake.impl,
			retryDelayMs: 1,
		});
		failing = 1;
		expect(await code(relay.closeTracks('s', ['0']))).toBe('ok');
		expect(fake.calls).toHaveLength(2);
		failing = 2;
		expect(await code(relay.closeTracks('s', ['0']))).toBe('sfu_unavailable');
		expect(fake.calls).toHaveLength(4);
		// A session asked for twice could leave one behind, and a second offer would break the connection.
		for (const call of [
			() => relay.newSession(),
			() => relay.publish('s', { type: 'offer', sdp: offer }, [{ mid: '0', trackName: 'd-mic' }]),
			() => relay.subscribe('s', [{ sessionId: 'o', trackName: 'd-mic' }]),
			() => relay.renegotiate('s', { type: 'answer', sdp: 'v=0' }),
		]) {
			failing = 1;
			const before = fake.calls.length;
			expect(await code(call())).toBe('sfu_unavailable');
			expect(fake.calls.length - before).toBe(1);
		}
		// A refusal is never retried, safe or not.
		const refusing = fakeFetch(() => new Response('no', { status: 401 }));
		const strict = new CloudflareRelay({
			appId: 'a',
			secret: 's',
			baseUrl: 'https://r.example.test',
			fetch: refusing.impl,
			retryDelayMs: 1,
		});
		expect(await code(strict.closeTracks('s', ['0']))).toBe('sfu_rejected');
		expect(refusing.calls).toHaveLength(1);
	});

	test('reads every failure as one of three codes', async () => {
		const answer = (body: unknown, status = 200) =>
			new CloudflareRelay({
				appId: 'a',
				secret: 's',
				baseUrl: 'https://r.example.test',
				retryDelayMs: 1,
				fetch: fakeFetch(() => (typeof body === 'string' ? new Response(body, { status }) : Response.json(body, { status })))
					.impl,
			});
		expect(await code(answer({}, 500).publish('s', { type: 'offer', sdp: offer }, []))).toBe('sfu_unavailable');
		expect(await code(answer({}, 404).publish('s', { type: 'offer', sdp: offer }, []))).toBe('sfu_rejected');
		expect(await code(answer({ errorCode: 'bad_sdp' }).publish('s', { type: 'offer', sdp: offer }, []))).toBe('sfu_rejected');
		expect(await code(answer('not json').publish('s', { type: 'offer', sdp: offer }, []))).toBe('sfu_bad_response');
		expect(await code(answer({ tracks: [] }).publish('s', { type: 'offer', sdp: offer }, []))).toBe('sfu_bad_response');
		expect(await code(answer({}).newSession())).toBe('sfu_bad_response');
		expect(await code(answer({ requiresImmediateRenegotiation: true, tracks: [] }).subscribe('s', []))).toBe('sfu_bad_response');
		expect(await code(answer([1, 2]).renegotiate('s', { type: 'answer', sdp: 'v=0' }))).toBe('sfu_bad_response');
		const thrown = new CloudflareRelay({
			appId: 'a',
			secret: 's',
			retryDelayMs: 1,
			fetch: (() => Promise.reject(new TypeError('offline'))) as unknown as typeof fetch,
		});
		expect(await code(thrown.subscribe('s', []))).toBe('sfu_unavailable');
	});

	test('gives up after its timeout', async () => {
		const hanging = ((_: unknown, init: RequestInit) =>
			new Promise((_, reject) =>
				init.signal?.addEventListener('abort', () => reject(init.signal!.reason)),
			)) as unknown as typeof fetch;
		const relay = new CloudflareRelay({ appId: 'a', secret: 's', fetch: hanging, timeoutMs: 20 });
		const began = Date.now();
		expect(await code(relay.publish('s', { type: 'offer', sdp: offer }, []))).toBe('sfu_unavailable');
		expect(Date.now() - began).toBeLessThan(2_000);
	});

	test('works end to end against the fake SFU, which refuses a wrong secret', async () => {
		const sfu = startFakeSfu();
		stops.push(sfu.stop);
		const relay = new CloudflareRelay({ appId: sfu.appId, secret: sfu.secret, baseUrl: sfu.url });
		const { sessionId } = await relay.newSession();
		const { answer } = await relay.publish(sessionId, { type: 'offer', sdp: offer }, [{ mid: '0', trackName: 'd-mic' }]);
		expect(answer.sdp).toContain('a=mid:0');
		expect(answer.sdp).toContain('a=recvonly');
		const other = (await relay.newSession()).sessionId;
		const pulled = await relay.subscribe(other, [{ sessionId, trackName: 'd-mic' }]);
		expect(pulled.renegotiate).toBe(true);
		expect(pulled.offer?.sdp).toContain(`a=mid:${pulled.tracks[0]!.mid}`);
		const wrong = new CloudflareRelay({ appId: sfu.appId, secret: 'wrong', baseUrl: sfu.url });
		expect(await code(wrong.newSession())).toBe('sfu_rejected');
	});

	test('the fake’s SDP keeps the offer’s sections and mids', () => {
		const answer = answerFor('v=0\r\nm=audio 9 X 111\r\na=mid:a\r\na=sendonly\r\nm=video 9 X 96\r\na=mid:b\r\na=sendonly\r\n');
		expect(answer).toContain('a=group:BUNDLE a b');
		expect(answer.match(/a=recvonly/g)).toHaveLength(2);
		expect(offerFor([{ mid: '7', trackName: 'd-cam' }])).toContain('m=video');
	});
});

describe('calls from the environment', () => {
	const run = (env: Record<string, string>) => {
		const lines: string[] = [];
		const options = callsFromEnv(env, (line) => lines.push(line));
		return { options, lines };
	};

	test('are off and silent when nothing is set', () => {
		const { options, lines } = run({});
		expect(options.relay).toBeNull();
		expect(options.maxParticipants).toBe(20);
		expect(lines).toEqual([]);
	});

	test('say in one line what is missing, and stay off', () => {
		expect(run({ HQ_CALLS_SFU_APP_ID: 'app' }).lines).toEqual([
			'[calls] off: HQ_CALLS_SFU_SECRET or HQ_CALLS_SFU_SECRET_FILE not set',
		]);
		expect(run({ HQ_CALLS_SFU_SECRET: 'very-secret' }).lines).toEqual(['[calls] off: HQ_CALLS_SFU_APP_ID not set']);
		expect(run({ HQ_CALLS_SFU_URL: 'http://127.0.0.1:1/v1' }).lines).toEqual([
			'[calls] off: HQ_CALLS_SFU_APP_ID, HQ_CALLS_SFU_SECRET or HQ_CALLS_SFU_SECRET_FILE not set',
		]);
		expect(run({ HQ_CALLS_SFU_APP_ID: 'a', HQ_CALLS_SFU_SECRET: 'x', HQ_CALLS_SFU_SECRET_FILE: '/x' }).options.relay).toBeNull();
		expect(run({ HQ_CALLS_SFU_APP_ID: 'a', HQ_CALLS_SFU_SECRET: 'x', HQ_CALLS_SFU_URL: 'ftp://x' }).lines).toEqual([
			'[calls] off: HQ_CALLS_SFU_URL is not an http(s) URL',
		]);
		expect(run({ HQ_CALLS_SFU_APP_ID: 'a', HQ_CALLS_SFU_SECRET_FILE: '/nowhere/at/all' }).lines).toEqual([
			'[calls] off: HQ_CALLS_SFU_SECRET_FILE cannot be read',
		]);
	});

	test('turn on with an app id and a secret, from the environment or a file, and never log the secret', () => {
		const on = run({ HQ_CALLS_SFU_APP_ID: 'app-1', HQ_CALLS_SFU_SECRET: 'very-secret', HQ_CALLS_MAX_PARTICIPANTS: '8' });
		expect(on.options.relay?.name).toBe('cloudflare');
		expect(on.options.maxParticipants).toBe(8);
		expect(on.lines).toEqual(['[calls] on: Cloudflare Realtime app app-1 at https://rtc.live.cloudflare.com']);
		const dir = mkdtempSync(join(tmpdir(), 'hq-sfu-'));
		stops.push(() => rmSync(dir, { recursive: true, force: true }));
		writeFileSync(join(dir, 'secret'), 'from-a-file\n');
		const file = run({
			HQ_CALLS_SFU_APP_ID: 'app-1',
			HQ_CALLS_SFU_SECRET_FILE: join(dir, 'secret'),
			HQ_CALLS_SFU_URL: 'http://127.0.0.1:9/v1',
		});
		expect(file.options.relay).not.toBeNull();
		expect(file.lines).toEqual(['[calls] on: Cloudflare Realtime app app-1 at http://127.0.0.1:9']);
		for (const line of [...on.lines, ...file.lines]) {
			expect(line).not.toContain('very-secret');
			expect(line).not.toContain('from-a-file');
		}
	});
});
