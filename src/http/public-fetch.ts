import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';

export type Resolve = (host: string) => Promise<string[]>;

const PRIVATE_V4 = [
	/^0\./,
	/^10\./,
	/^127\./,
	/^169\.254\./,
	/^172\.(1[6-9]|2\d|3[01])\./,
	/^192\.168\./,
	/^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./,
	/^198\.1[89]\./,
	/^(22[4-9]|2[3-5]\d)\./,
];

function ipv6Words(host: string): number[] | null {
	let text = host;
	const v4 = /(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(host);
	if (v4) {
		const [, a = 0, b = 0, c = 0, d = 0] = v4.map(Number);
		text = `${host.slice(0, v4.index)}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
	}
	const halves = text.split('::');
	if (halves.length > 2) return null;
	const head = halves[0] ? halves[0].split(':') : [];
	const tail = halves[1] ? halves[1].split(':') : [];
	const gap = 8 - head.length - tail.length;
	if (halves.length === 1 ? gap !== 0 : gap < 1) return null;
	const words = [...head, ...Array<string>(halves.length === 2 ? gap : 0).fill('0'), ...tail];
	if (!words.every((word) => /^[\da-f]{1,4}$/.test(word))) return null;
	return words.map((word) => Number.parseInt(word, 16));
}

export function privateAddress(host: string): boolean {
	if (PRIVATE_V4.some((range) => range.test(host))) return true;
	if (!host.includes(':')) return false;
	const words = ipv6Words(host.toLowerCase());
	if (words === null) return true;
	const [first = 0, second = 0, third = 0] = words;
	const sixToFour = `${second >> 8}.${second & 0xff}.${third >> 8}.${third & 0xff}`;
	return (
		(words.slice(0, 5).every((word) => word === 0) && (words[5] === 0 || words[5] === 0xffff)) ||
		(words.slice(0, 4).every((word) => word === 0) && words[4] === 0xffff && words[5] === 0) ||
		(first === 0x2002 && PRIVATE_V4.some((range) => range.test(sixToFour))) ||
		(first === 0x64 && second === 0xff9b) ||
		(first & 0xfe00) === 0xfc00 ||
		(first & 0xff80) === 0xfe80 ||
		(first & 0xff00) === 0xff00
	);
}

export function publicUrl(input: string): URL | null {
	let url: URL;
	try {
		url = new URL(input);
	} catch {
		return null;
	}
	if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
	const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, '');
	if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || host.endsWith('.internal')) return null;
	if (privateAddress(host)) return null;
	return url;
}

const resolveHost: Resolve = async (host) => {
	try {
		return (await lookup(host, { all: true })).map((a) => a.address.toLowerCase());
	} catch {
		return [];
	}
};

export async function fetchPublic(
	fetchImpl: typeof fetch,
	input: string,
	{ redirects = 3, resolve = resolveHost, ...init }: BunFetchRequestInit & { redirects?: number; resolve?: Resolve } = {},
): Promise<Response> {
	let target = input;
	for (let hop = 0; hop <= redirects; hop++) {
		const url = publicUrl(target);
		if (url === null) throw new Error(`not a public http(s) URL: ${target}`);
		const host = url.hostname.replace(/^\[|\]$/g, '');
		const headers = new Headers(init.headers);
		let address = url;
		let pinned: BunFetchRequestInit = {};
		if (isIP(host) === 0) {
			const addresses = await resolve(host);
			if (addresses.some(privateAddress)) throw new Error(`not a public http(s) URL: ${target}`);
			if (addresses.length === 0) throw new Error(`could not resolve ${host}`);
			address = new URL(url);
			address.hostname = isIP(addresses[0]!) === 6 ? `[${addresses[0]}]` : addresses[0]!;
			headers.set('host', url.host);
			if (url.protocol === 'https:') pinned = { keepalive: false, tls: { ...init.tls, serverName: host } };
		}
		const response = await fetchImpl(address, { ...init, ...pinned, headers, redirect: 'manual' });
		const location = response.headers.get('location');
		if (response.status < 300 || response.status >= 400 || location === null || redirects === 0) return response;
		target = new URL(location, url).toString();
	}
	throw new Error('too many redirects');
}
