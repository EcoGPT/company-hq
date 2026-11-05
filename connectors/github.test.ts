import { describe, expect, test } from 'bun:test';
import { createHq } from '../src/hq';
import { admin, fakeFetch } from '../test/helpers';
import github from './github';

async function setup(respond: (url: string) => unknown) {
	const { impl, calls } = fakeFetch(respond);
	const hq = createHq({ connectors: [github], vaultKey: 'k', fetch: impl });
	await hq.vault.set('github', 'ghp_x');
	const ctx = { hub: hq.hub, caller: admin(hq).person };
	return { hq, ctx, urls: () => calls.map((c) => c.url) };
}

const pr = (number: number, merged_at: string | null = null, state = 'closed') => ({
	number,
	title: `PR ${number}`,
	state,
	user: { login: 'ada' },
	html_url: `u${number}`,
	merged_at,
});

describe('github connector', () => {
	test('reports merged pull requests as merged', async () => {
		const { hq, ctx } = await setup(() => [pr(1, '2026-10-01T00:00:00Z'), pr(2), pr(3, null, 'open')]);
		const result = await hq.registry.call('github_list_issues', { repo: 'acme/app', kind: 'pulls', state: 'all' }, ctx);
		expect(result.ok && (result.value as { state: string }[]).map((item) => item.state)).toEqual(['merged', 'closed', 'open']);
	});

	test('follows rel=next up to the limit', async () => {
		const pages: Record<string, { items: unknown[]; next?: string }> = {
			'https://api.github.com/repos/acme/app/issues?state=open&per_page=100': {
				items: Array.from({ length: 100 }, (_, i) => ({ ...pr(i), state: 'open' })),
				next: 'https://api.github.com/repositories/1/issues?state=open&per_page=100&page=2',
			},
			'https://api.github.com/repositories/1/issues?state=open&per_page=100&page=2': {
				items: Array.from({ length: 100 }, (_, i) => ({ ...pr(100 + i), state: 'open' })),
				next: 'https://api.github.com/repositories/1/issues?state=open&per_page=100&page=3',
			},
		};
		const { hq, ctx, urls } = await setup((url) => {
			const page = pages[url]!;
			return Response.json(page.items, {
				headers: page.next ? { link: `<${page.next}>; rel="next", <${page.next}>; rel="last"` } : {},
			});
		});
		const result = await hq.registry.call('github_list_issues', { repo: 'acme/app', limit: 150 }, ctx);
		expect(result.ok && (result.value as unknown[]).length).toBe(150);
		expect(urls()).toEqual(Object.keys(pages));
	});

	test('does not follow a next link off api.github.com', async () => {
		const { hq, ctx, urls } = await setup(() =>
			Response.json([pr(1)], { headers: { link: '<https://evil.test/steal>; rel="next"' } }),
		);
		expect((await hq.registry.call('github_list_issues', { repo: 'acme/app', limit: 50 }, ctx)).ok).toBe(true);
		expect(urls()).toEqual(['https://api.github.com/repos/acme/app/issues?state=open&per_page=50']);
	});

	test('stops after ten pages when issues are mostly pull requests', async () => {
		const { hq, ctx, urls } = await setup(() =>
			Response.json([{ ...pr(1), pull_request: {} }], {
				headers: { link: '<https://api.github.com/repositories/1/issues?page=n>; rel="next"' },
			}),
		);
		expect(await hq.registry.call('github_list_issues', { repo: 'acme/app' }, ctx)).toEqual({ ok: true, value: [] });
		expect(urls()).toHaveLength(10);
	});

	test('lists a directory as name, type and path', async () => {
		const { hq, ctx } = await setup(() => [
			{ name: 'a.md', path: 'docs/a.md', type: 'file', sha: 'x', size: 3, _links: {} },
			{ name: 'img', path: 'docs/img', type: 'dir', sha: 'y', size: 0, _links: {} },
		]);
		const result = await hq.registry.call('github_read_file', { repo: 'acme/app', path: 'docs' }, ctx);
		expect(result).toEqual({
			ok: true,
			value: [
				{ name: 'a.md', type: 'file', path: 'docs/a.md' },
				{ name: 'img', type: 'dir', path: 'docs/img' },
			],
		});
	});
});
