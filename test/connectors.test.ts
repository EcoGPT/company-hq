import { describe, expect, test } from 'bun:test';
import github from '../connectors/github';
import { verifySecret } from '../src/connectors/define';
import { httpConnector } from '../src/connectors/http';
import { createHq } from '../src/hq';
import { admin, client, fakeFetch } from './helpers';

describe('connectors', () => {
	test('tools appear only once a key is set, and the key never reaches the model', async () => {
		const { impl, calls: seen } = fakeFetch(() => [
			{ number: 7, title: 'Bug', state: 'open', user: { login: 'ada' }, html_url: 'u' },
		]);
		const hq = createHq({ connectors: [github], vaultKey: 'test-key', fetch: impl });
		const ada = admin(hq);
		const ctx = { hub: hq.hub, caller: ada.person };
		expect(hq.registry.specs('assistant', ctx).map((t) => t.name)).not.toContain('github_list_issues');

		const as = client(hq, ada.key);
		expect((await as('PUT', '/v1/connectors/github', { secret: 'ghp_x' })).body).toEqual({ connected: true });
		expect((await as('GET', '/v1/connectors')).body.connectors[0]).toMatchObject({ slug: 'github', connected: true });
		expect(hq.registry.specs('assistant', ctx).map((t) => t.name)).toContain('github_list_issues');

		const result = await hq.registry.call('github_list_issues', { repo: 'acme/app' }, ctx);
		expect(result).toEqual({ ok: true, value: [{ number: 7, title: 'Bug', state: 'open', by: 'ada', url: 'u' }] });
		expect(seen.map((s) => s.url)).toEqual([
			'https://api.github.com/user',
			'https://api.github.com/repos/acme/app/issues?state=open&per_page=30',
		]);
		expect((seen[1]?.init.headers as Record<string, string>).authorization).toBe('Bearer ghp_x');
		expect(JSON.stringify(result)).not.toContain('ghp_x');
	});

	test('members cannot set keys; the vault must be on', async () => {
		const hq = createHq({ connectors: [github] });
		const ada = admin(hq);
		const bo = hq.hub.people.create({ name: 'Bo', handle: 'bo' });
		expect((await client(hq, hq.hub.keys.mint(bo.id).secret)('PUT', '/v1/connectors/github', { secret: 's' })).status).toBe(403);
		expect((await client(hq, ada.key)('PUT', '/v1/connectors/github', { secret: 's' })).status).toBe(409);
	});

	test('a secret the service rejects is not stored', async () => {
		const rejections = [{ connector: github, reply: Response.json({ message: 'Bad credentials' }, { status: 401 }) }];
		for (const { connector, reply } of rejections) {
			const { impl } = fakeFetch(() => reply.clone());
			const hq = createHq({ connectors: [connector], vaultKey: 'k', fetch: impl });
			const res = await client(hq, admin(hq).key)('PUT', `/v1/connectors/${connector.slug}`, { secret: 'not-a-real-token' });
			expect(res.status).toBe(400);
			expect(res.body.error).toContain(`${connector.name} rejected`);
			expect(hq.vault.has(connector.slug)).toBe(false);
		}
	});

	test('a secret that cannot be checked is stored with a warning', async () => {
		const offline = (async () => {
			throw new TypeError('Unable to connect');
		}) as unknown as typeof fetch;
		const hq = createHq({ connectors: [github], vaultKey: 'k', fetch: offline });
		const res = await client(hq, admin(hq).key)('PUT', '/v1/connectors/github', { secret: 'ghp_x' });
		expect(res.body).toEqual({ connected: true, warning: 'Could not check the GitHub secret: Unable to connect' });
		expect(hq.vault.has('github')).toBe(true);
	});

	test('a service that never answers only delays the save by the timeout', async () => {
		const hang = (() => new Promise<Response>(() => {})) as unknown as typeof fetch;
		expect(await verifySecret(github, 'ghp_x', hang, 20)).toBe('Could not check the GitHub secret: no answer after 0.02s');
	});

	test('httpConnector: GET-only by default, auth header, base URL pinned', async () => {
		const { impl, calls: seen } = fakeFetch(() => ({ ok: 1 }));
		const weather = httpConnector({
			slug: 'weather',
			name: 'Weather',
			description: 'Forecasts.',
			baseUrl: 'https://api.weather.test/v2',
			auth: { header: 'x-api-key' },
		});
		const hq = createHq({ connectors: [weather], vaultKey: 'k', fetch: impl });
		await hq.vault.set('weather', 'w-key');
		const ctx = { hub: hq.hub, caller: admin(hq).person };
		expect(await hq.registry.call('weather_request', { path: '/forecast?city=oslo' }, ctx)).toEqual({
			ok: true,
			value: { ok: 1 },
		});
		expect(seen[0]?.url).toBe('https://api.weather.test/v2/forecast?city=oslo');
		expect((seen[0]?.init.headers as Record<string, string>)['x-api-key']).toBe('w-key');
		expect((await hq.registry.call('weather_request', { method: 'POST', path: '/x' }, ctx)).ok).toBe(false);
		expect((await hq.registry.call('weather_request', { path: '/../../evil' }, ctx)).ok).toBe(false);
		expect((await hq.registry.call('weather_request', { path: '/..%2F..%2Fevil' }, ctx)).ok).toBe(false);
	});

	test('httpConnector follows redirects only while they stay under the base URL', async () => {
		const seen: string[] = [];
		const impl = (async (input: string | URL) => {
			const url = String(input);
			seen.push(url);
			if (url.endsWith('/moved')) return new Response(null, { status: 301, headers: { location: '/v2/here' } });
			if (url.endsWith('/away')) return new Response(null, { status: 302, headers: { location: 'https://evil.test/steal' } });
			return Response.json({ at: url });
		}) as unknown as typeof fetch;
		const weather = httpConnector({
			slug: 'weather',
			name: 'Weather',
			description: 'd',
			baseUrl: 'https://api.weather.test/v2',
			auth: { header: 'x-api-key' },
		});
		const hq = createHq({ connectors: [weather], vaultKey: 'k', fetch: impl });
		await hq.vault.set('weather', 'w-key');
		const ctx = { hub: hq.hub, caller: admin(hq).person };

		expect(await hq.registry.call('weather_request', { path: '/moved' }, ctx)).toEqual({
			ok: true,
			value: { at: 'https://api.weather.test/v2/here' },
		});
		const away = await hq.registry.call('weather_request', { path: '/away' }, ctx);
		expect(away).toEqual({ ok: false, error: 'redirected outside the base URL' });
		expect(seen.some((url) => url.includes('evil.test'))).toBe(false);
	});

	test('github paths cannot climb out of the repo', async () => {
		const { impl, calls: seen } = fakeFetch(() => ({ content: '', encoding: 'base64' }));
		const hq = createHq({ connectors: [github], vaultKey: 'k', fetch: impl });
		await hq.vault.set('github', 'ghp_x');
		const ctx = { hub: hq.hub, caller: admin(hq).person };
		expect((await hq.registry.call('github_read_file', { repo: 'acme/app', path: '../../../user' }, ctx)).ok).toBe(false);
		expect((await hq.registry.call('github_list_issues', { repo: '../user' }, ctx)).ok).toBe(false);
		expect((await hq.registry.call('github_read_file', { repo: 'acme/app', path: 'docs/a b.md' }, ctx)).ok).toBe(true);
		expect(seen.map((s) => s.url)).toEqual(['https://api.github.com/repos/acme/app/contents/docs/a%20b.md']);
	});
});
