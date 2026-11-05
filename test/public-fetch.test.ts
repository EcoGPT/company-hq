import { describe, expect, test } from 'bun:test';
import { fetchPublic, privateAddress, publicUrl } from '../src/http/public-fetch';

describe('publicUrl', () => {
	test.each([
		'http://0.1.2.3/',
		'http://100.64.0.1/',
		'http://198.18.0.1/',
		'http://198.19.255.255/',
		'http://224.0.0.1/',
		'http://239.255.255.250/',
		'http://240.0.0.1/',
		'http://255.255.255.255/',
		'http://[::]/',
		'http://[::1]/',
		'http://[::127.0.0.1]/',
		'http://[::7f00:1]/',
		'http://[::ffff:127.0.0.1]/',
		'http://[::ffff:7f00:1]/',
		'http://[0:0:0:0:0:ffff:a9fe:a9fe]/',
		'http://[::ffff:0:7f00:1]/',
		'http://[2002:7f00:1::]/',
		'http://[2002:a9fe:a9fe::1]/',
		'http://[64:ff9b::a00:1]/',
		'http://[fd00::1]/',
		'http://[fe80::1]/',
		'http://[ff02::1]/',
	])('refuses %s', (url) => {
		expect(publicUrl(url)).toBeNull();
	});

	test.each([
		'http://8.8.8.8/',
		'http://198.20.0.1/',
		'http://223.255.255.255/',
		'http://[2606:4700::1111]/',
		'http://[2002:808:808::1]/',
	])('allows %s', (url) => {
		expect(publicUrl(url)).not.toBeNull();
	});
});

describe('privateAddress', () => {
	test.each([
		['::ffff:127.0.0.1', true],
		['::FFFF:10.0.0.1', true],
		['0:0:0:0:0:0:0:1', true],
		['fe80::1%en0', true],
		['2001:4860:4860::8888', false],
		['93.184.216.34', false],
	] as const)('%s -> %p', (address, expected) => {
		expect(privateAddress(address)).toBe(expected);
	});
});

describe('fetchPublic', () => {
	test('connects https to the checked address and verifies TLS for the hostname', async () => {
		const calls: [string, BunFetchRequestInit][] = [];
		const fetchImpl = (async (input: URL, init: BunFetchRequestInit) => {
			calls.push([input.toString(), init]);
			return new Response('ok');
		}) as unknown as typeof fetch;
		let lookups = 0;
		const resolve = async () => (lookups++ === 0 ? ['93.184.216.34'] : ['127.0.0.1']);
		await fetchPublic(fetchImpl, 'https://rebind.example/path', { resolve });
		const [url, init] = calls[0]!;
		expect(lookups).toBe(1);
		expect(url).toBe('https://93.184.216.34/path');
		expect(new Headers(init.headers).get('host')).toBe('rebind.example');
		expect(init.tls?.serverName).toBe('rebind.example');
		expect(init.keepalive).toBe(false);
	});

	test('refuses host names that resolve to private addresses, redirects included', async () => {
		const hits: string[] = [];
		const fetchImpl = (async (input: URL, init: BunFetchRequestInit) => {
			hits.push(input.toString());
			return new Headers(init.headers).get('host') === 'hop.example'
				? new Response(null, { status: 302, headers: { location: 'http://metadata.example/latest' } })
				: new Response('ok');
		}) as unknown as typeof fetch;
		const resolve = async (host: string) =>
			host === 'public.example' || host === 'hop.example'
				? ['93.184.216.34']
				: host === 'v6.example'
					? ['::ffff:127.0.0.1']
					: host === 'nat64.example'
						? ['64:ff9b::7f00:1']
						: ['10.0.0.7'];
		for (const url of ['http://private.example/', 'http://v6.example/', 'http://nat64.example/', 'http://hop.example/']) {
			await expect(fetchPublic(fetchImpl, url, { resolve })).rejects.toThrow('not a public http(s) URL');
		}
		expect(hits).toEqual(['http://93.184.216.34/']);
		expect(await (await fetchPublic(fetchImpl, 'http://public.example/', { resolve })).text()).toBe('ok');
	});

	test('connects plain http to the checked address, so DNS cannot change it in between', async () => {
		const seen: { url: string; host: string | null }[] = [];
		const fetchImpl = (async (input: URL, init: BunFetchRequestInit) => {
			seen.push({ url: input.toString(), host: new Headers(init.headers).get('host') });
			return new Response('ok');
		}) as unknown as typeof fetch;
		const answers = [['93.184.216.34'], ['127.0.0.1']];
		await fetchPublic(fetchImpl, 'http://rebind.example:8080/path?x=1', { resolve: async () => answers.shift() ?? [] });
		expect(seen).toEqual([{ url: 'http://93.184.216.34:8080/path?x=1', host: 'rebind.example:8080' }]);
	});

	test('refuses a hostname that does not resolve', async () => {
		const fetchImpl = (async () => new Response('ok')) as unknown as typeof fetch;
		await expect(fetchPublic(fetchImpl, 'https://nowhere.example/', { resolve: async () => [] })).rejects.toThrow(
			'could not resolve',
		);
	});
});
