import type { Server } from 'bun';
import { createHq, type Hq, type HqOptions } from '../src/hq';
import type { SocketData } from '../src/realtime/socket';
import { admin, client } from '../src/testing';

export { admin, client };

/**
 * A person plus a device that has enrolled, as the app does. Only a sign-in key enrolls, so a plain key
 * of the person's is traded for one first, the way `bun hq invite` would hand it over.
 */
export async function enrolled(hq: Hq, key: string, deviceName = 'Test Mac') {
	const owner = hq.hub.keys.check(key);
	const signIn = owner.ok ? hq.hub.keys.mint(owner.person.id, 'setup').secret : key;
	const response = await client(hq)('POST', '/v1/enroll', { key: signIn, device_name: deviceName });
	if (response.status !== 201) throw new Error(`enroll failed: ${JSON.stringify(response.body)}`);
	const { bearer, device_id: deviceId, person } = response.body;
	return { bearer: bearer as string, deviceId: deviceId as string, person, as: client(hq, bearer) };
}

/** Ada (admin) and Bo (member), each signed in on a device, plus a room they share. */
export async function pair(options: HqOptions = {}) {
	const hq = createHq(options);
	const ada = admin(hq);
	const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
	hq.hub.conversations.addMember(hq.hub.general().id, bo.id);
	const a = await enrolled(hq, ada.key, 'Ada Mac');
	const b = await enrolled(hq, hq.hub.keys.mint(bo.id, 'setup').secret, 'Bo Mac');
	const made = await a.as('POST', '/v1/conversations', { kind: 'group', title: 'Launch', person_ids: [b.person.id] });
	return { hq, ada, bo, a, b, room: made.body.conversation };
}

export const say = (
	as: ReturnType<typeof client>,
	conversationId: string,
	content: string,
	extra: Record<string, unknown> = {},
) => as('POST', `/v1/conversations/${conversationId}/messages`, { client_msg_id: crypto.randomUUID(), content, ...extra });

export function fakeFetch(respond: (url: string, init: RequestInit) => unknown) {
	const calls: { url: string; init: RequestInit }[] = [];
	const impl = (async (input: string | URL, init: RequestInit = {}) => {
		const url = String(input);
		calls.push({ url, init });
		const result = await respond(url, init);
		return result instanceof Response ? result : Response.json(result);
	}) as unknown as typeof fetch;
	return { impl, calls };
}

export function serve(hq: Hq): Server<SocketData> {
	return Bun.serve({ port: 0, fetch: hq.fetch, websocket: hq.websocket });
}

export type Frame = Record<string, any> & { type: string };

/** A person-with-a-key's connection: every frame it gets is kept, in order. */
export type Connection = {
	ws: WebSocket;
	frames: Frame[];
	closed: Promise<number>;
	send(frame: unknown): void;
	/** Resolves once everything the server sent before now has arrived (a ping is answered after earlier frames). */
	settle(): Promise<void>;
	/** The next not-yet-taken frame that matches. */
	take(type: string, match?: (frame: Frame) => boolean): Promise<Frame>;
	types(): string[];
};

export async function connect(server: { port?: number | string }, bearer: string): Promise<Connection> {
	// Bun's WebSocket takes request headers, which the DOM typings do not know about.
	const HeaderSocket = WebSocket as unknown as new (url: string, options: { headers: Record<string, string> }) => WebSocket;
	const ws = new HeaderSocket(`ws://localhost:${server.port}/v1/ws`, { headers: { authorization: `Bearer ${bearer}` } });
	const frames: Frame[] = [];
	const taken = new Set<Frame>();
	const listeners = new Set<() => void>();
	let pongs = 0;
	ws.addEventListener('message', (event) => {
		if (event.data === 'pong') pongs += 1;
		else frames.push(JSON.parse(String(event.data)));
		for (const listener of listeners) listener();
	});
	const closed = new Promise<number>((resolve) => ws.addEventListener('close', (event) => resolve(event.code)));
	const until = <T>(look: () => T | undefined) =>
		new Promise<T>((resolve) => {
			const check = () => {
				const found = look();
				if (found === undefined) return;
				listeners.delete(check);
				resolve(found);
			};
			listeners.add(check);
			check();
		});
	const connection: Connection = {
		ws,
		frames,
		closed,
		send: (frame) => ws.send(typeof frame === 'string' ? frame : JSON.stringify(frame)),
		settle: async () => {
			const target = pongs + 1;
			ws.send('ping');
			await until(() => (pongs >= target ? true : undefined));
		},
		take: (type, match = () => true) =>
			until(() => {
				const frame = frames.find((f) => !taken.has(f) && f.type === type && match(f));
				if (frame !== undefined) taken.add(frame);
				return frame;
			}),
		types: () => frames.map((f) => f.type),
	};
	await connection.take('hello');
	return connection;
}
