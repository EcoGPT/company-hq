/**
 * A stand-in for Cloudflare Realtime's SFU HTTPS API, for tests and CI's live job: sessions, publish, subscribe, renegotiate
 * and close, in Cloudflare's shapes. It carries no media. A publish answer copies the offer's m-lines and mids, so the app's
 * SDP code has something it can parse; a subscribe offer names a fresh mid per pulled track.
 *
 *     bun test/fake-sfu.ts --port 18791
 *
 * Standalone it serves any app id and, when `HQ_CALLS_SFU_SECRET` is set, only that bearer.
 */

type Json = Record<string, any>;

export type FakeRequest = { method: string; path: string; body: Json | null };

export type FakeSfu = {
	/** What `HQ_CALLS_SFU_URL` should be. */
	url: string;
	appId: string;
	secret: string;
	requests: FakeRequest[];
	/** The next `times` requests whose path ends with `suffix` get `status` (or, for 200, the body given). */
	fail(suffix: string, status: number, times?: number, body?: Json): void;
	/** Holds every answer back until the returned function is called. */
	hold(): () => void;
	/** Tracks published to each session, by name. */
	published: Map<string, Map<string, string>>;
	stop(): void;
};

const ICE = ['a=ice-ufrag:fake', 'a=ice-pwd:fakefakefakefakefakefake', 'a=ice-lite'];
const FINGERPRINT = `a=fingerprint:sha-256 ${Array.from({ length: 32 }, () => 'AB').join(':')}`;

function sections(sdp: string): string[][] {
	const lines = sdp.split(/\r?\n/).filter((line) => line !== '');
	const out: string[][] = [];
	for (const line of lines) {
		if (line.startsWith('m=')) out.push([line]);
		else out.at(-1)?.push(line);
	}
	return out;
}

const header = (mids: string[]) => [
	'v=0',
	`o=- ${Date.now()} 2 IN IP4 127.0.0.1`,
	's=-',
	't=0 0',
	`a=group:BUNDLE ${mids.join(' ')}`,
	...ICE,
	FINGERPRINT,
];

const FLIP: Record<string, string> = {
	'a=sendonly': 'a=recvonly',
	'a=recvonly': 'a=sendonly',
	'a=sendrecv': 'a=sendrecv',
	'a=inactive': 'a=inactive',
};

/** An answer with the offer's sections, mids and codecs, each direction turned round. */
export function answerFor(offer: string): string {
	const media = sections(offer);
	const mids = media.map((s) => s.find((l) => l.startsWith('a=mid:'))?.slice(6) ?? '');
	const body = media.flatMap((section) => [
		section[0]!,
		'c=IN IP4 0.0.0.0',
		'a=setup:passive',
		...section.filter(
			(l) => l.startsWith('a=mid:') || l.startsWith('a=rtpmap:') || l.startsWith('a=fmtp:') || l === 'a=rtcp-mux',
		),
		...section.filter((l) => l in FLIP).map((l) => FLIP[l]!),
	]);
	return [...header(mids), ...body, ''].join('\r\n');
}

/** An offer with one sendonly section per track, audio for `-mic` and video otherwise. */
export function offerFor(tracks: { mid: string; trackName: string }[]): string {
	const body = tracks.flatMap(({ mid, trackName }) =>
		trackName.endsWith('-mic')
			? [
					'm=audio 9 UDP/TLS/RTP/SAVPF 111',
					'c=IN IP4 0.0.0.0',
					`a=mid:${mid}`,
					'a=sendonly',
					'a=rtcp-mux',
					'a=rtpmap:111 opus/48000/2',
				]
			: [
					'm=video 9 UDP/TLS/RTP/SAVPF 96',
					'c=IN IP4 0.0.0.0',
					`a=mid:${mid}`,
					'a=sendonly',
					'a=rtcp-mux',
					'a=rtpmap:96 VP8/90000',
				],
	);
	return [...header(tracks.map((t) => t.mid)), 'a=setup:actpass', ...body, ''].join('\r\n');
}

export function startFakeSfu(options: { port?: number; appId?: string; secret?: string; anyApp?: boolean } = {}): FakeSfu {
	const appId = options.appId ?? 'fake-app';
	const secret = options.secret ?? crypto.randomUUID();
	const requests: FakeRequest[] = [];
	const failures: { suffix: string; status: number; times: number; body?: Json }[] = [];
	const published = new Map<string, Map<string, string>>();
	const nextMid = new Map<string, number>();
	let held: Promise<void> | null = null;

	const mid = (session: string) => {
		const n = nextMid.get(session) ?? 100;
		nextMid.set(session, n + 1);
		return String(n);
	};

	async function handle(req: Request): Promise<Response> {
		const url = new URL(req.url);
		const text = req.method === 'GET' ? '' : await req.text();
		const body = text === '' ? null : (JSON.parse(text) as Json);
		requests.push({ method: req.method, path: url.pathname, body });
		if (held !== null) await held;
		if (req.headers.get('authorization') !== `Bearer ${secret}` && !(options.anyApp && options.secret === undefined)) {
			return Response.json({ errorCode: 'unauthorized' }, { status: 401 });
		}
		const failure = failures.find((f) => url.pathname.endsWith(f.suffix));
		if (failure !== undefined) {
			failure.times -= 1;
			if (failure.times <= 0) failures.splice(failures.indexOf(failure), 1);
			return failure.status === 200 ? Response.json(failure.body ?? {}) : new Response('nope', { status: failure.status });
		}
		const match = /^\/v1\/apps\/([^/]+)\/sessions\/(new|[^/]+)(?:\/(.*))?$/.exec(url.pathname);
		if (match === null || (!options.anyApp && match[1] !== appId))
			return Response.json({ errorCode: 'not_found' }, { status: 404 });
		const [, , session, rest] = match;
		if (session === 'new' && req.method === 'POST') {
			const sessionId = crypto.randomUUID().replaceAll('-', '');
			published.set(sessionId, new Map());
			return Response.json({ sessionId });
		}
		const own = published.get(session!);
		if (own === undefined) return Response.json({ errorCode: 'session_not_found' }, { status: 404 });
		if (rest === 'tracks/new' && req.method === 'POST') {
			const tracks = (body?.tracks ?? []) as Json[];
			if (tracks.every((t) => t.location === 'local')) {
				const sdp = String(body?.sessionDescription?.sdp ?? '');
				for (const t of tracks) own.set(String(t.trackName), String(t.mid));
				return Response.json({
					requiresImmediateRenegotiation: false,
					sessionDescription: { type: 'answer', sdp: answerFor(sdp) },
					tracks: tracks.map((t) => ({ mid: t.mid, trackName: t.trackName })),
				});
			}
			const pulled = tracks.map((t) => {
				const found = published.get(String(t.sessionId))?.has(String(t.trackName));
				return found
					? { mid: mid(session!), trackName: String(t.trackName), sessionId: t.sessionId }
					: { trackName: String(t.trackName), errorCode: 'not_found', errorDescription: 'no such track' };
			});
			const ok = pulled.filter((t) => t.mid !== undefined) as { mid: string; trackName: string }[];
			return Response.json({
				requiresImmediateRenegotiation: ok.length > 0,
				...(ok.length > 0 ? { sessionDescription: { type: 'offer', sdp: offerFor(ok) } } : {}),
				tracks: pulled,
			});
		}
		if (rest === 'renegotiate' && req.method === 'PUT') return Response.json({});
		if (rest === 'tracks/close' && req.method === 'PUT') {
			const mids = new Set(((body?.tracks ?? []) as Json[]).map((t) => String(t.mid)));
			for (const [name, m] of own) if (mids.has(m)) own.delete(name);
			return Response.json({ requiresImmediateRenegotiation: false, tracks: [...mids].map((m) => ({ mid: m })) });
		}
		return Response.json({ errorCode: 'not_found' }, { status: 404 });
	}

	const server = Bun.serve({ port: options.port ?? 0, hostname: '127.0.0.1', fetch: handle });
	return {
		url: `http://127.0.0.1:${server.port}/v1`,
		appId,
		secret,
		requests,
		published,
		fail: (suffix, status, times = 1, body) => void failures.push({ suffix, status, times, body }),
		hold: () => {
			let release!: () => void;
			held = new Promise((resolve) => (release = resolve));
			return () => {
				held = null;
				release();
			};
		},
		stop: () => void server.stop(true),
	};
}

if (import.meta.main) {
	const at = process.argv.indexOf('--port');
	const port = at === -1 ? 18791 : Number(process.argv[at + 1]);
	const secret = process.env.HQ_CALLS_SFU_SECRET?.trim() || undefined;
	const fake = startFakeSfu({ port, secret, anyApp: true });
	console.log(`fake SFU on ${fake.url}${secret === undefined ? ' (any bearer)' : ''}`);
}
