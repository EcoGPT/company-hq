import { describe, expect, test } from 'bun:test';
import { CORE_MIGRATIONS, Hub } from '../../src/core/hub';
import { migrate } from '../../src/db/database';
import docs from './app';
import { Docs, migrations } from './store';
import { admin, client, createHq, hashEmbedder } from '@hq/sdk/testing';

describe('docs app', () => {
	test('writes keep every earlier version', async () => {
		const hq = createHq({ apps: [docs] });
		const ctx = { hub: hq.hub, caller: hq.assistant.self };
		await hq.registry.call('write_doc', { slug: 'launch-plan', title: 'Launch plan', body: 'v1' }, ctx);
		await hq.registry.call('write_doc', { slug: 'launch-plan', title: 'Launch plan', body: 'v2: ship friday' }, ctx);
		expect(await hq.registry.call('read_doc', { slug: 'launch-plan' }, ctx)).toEqual({
			ok: true,
			value: { slug: 'launch-plan', title: 'Launch plan', body: 'v2: ship friday' },
		});
		expect(new Docs(hq.hub).revisions('launch-plan').map((r) => r.body)).toEqual(['v1']);
		const found = await hq.registry.call('search_docs', { query: 'friday' }, ctx);
		expect(found.ok && (found.value as { slug: string }[])[0]?.slug).toBe('launch-plan');
	});

	test('search matches titles and bodies and follows rewrites and deletes', () => {
		const hq = createHq({ apps: [docs] });
		const store = new Docs(hq.hub);
		const by = hq.assistant.self.id;
		store.write({ slug: 'launch', title: 'Launch Plan', body: 'Ship on Friday.', by });
		store.write({ slug: 'oncall', title: 'On-call', body: 'Page the LAUNCH captain.\nThen wait.', by });
		store.write({ slug: 'menu', title: 'Lunch', body: 'Tacos "al pastor"', by });
		const slugs = (q: string, limit?: number) => store.search(q, limit).map((hit) => hit.slug);
		expect(slugs('launch').sort()).toEqual(['launch', 'oncall']);
		expect(slugs('launch', 1)).toHaveLength(1);
		expect(slugs('FRIDAY')).toEqual(['launch']);
		expect(slugs('"al')).toEqual(['menu']);
		expect(slugs('Fr')).toEqual(['launch']);
		expect(slugs('nothing here')).toEqual([]);
		expect(store.search('captain')[0]?.snippet).toContain('Page the LAUNCH captain.');

		store.write({ slug: 'launch', title: 'Launch Plan', body: 'Ship on Monday.', by });
		expect(slugs('friday')).toEqual([]);
		expect(slugs('monday')).toEqual(['launch']);
		store.delete('menu');
		expect(slugs('tacos')).toEqual([]);
	});

	test('the search index backfills docs written before it existed', () => {
		const [create, ...rest] = migrations;
		const hub = Hub.open(':memory:', [create!]);
		const by = hub.people.create({ name: 'Ada', handle: 'ada' }).id;
		new Docs(hub).write({ slug: 'old', title: 'Old roadmap', body: 'from before', by });
		migrate(hub.db, [...CORE_MIGRATIONS, create!, ...rest]);
		expect(new Docs(hub).search('roadmap').map((hit) => hit.slug)).toEqual(['old']);
	});

	test('deleting a doc keeps its last version as a revision', () => {
		const hq = createHq({ apps: [docs] });
		const store = new Docs(hq.hub);
		store.write({ slug: 'old', title: 'Old', body: 'keep me', by: hq.assistant.self.id });
		expect(store.delete('old')).toBe(true);
		expect(store.get('old')).toBeNull();
		expect(store.revisions('old')[0]?.body).toBe('keep me');
	});

	test('write_doc refuses slugs that are not kebab-case; the page reads a doc and counts its revisions', async () => {
		const hq = createHq({ apps: [docs] });
		const ctx = { hub: hq.hub, caller: hq.assistant.self };
		expect((await hq.registry.call('write_doc', { slug: 'Not A Slug', title: 't', body: '' }, ctx)).ok).toBe(false);
		await hq.registry.call('write_doc', { slug: 'faq', title: 'FAQ', body: 'Q?' }, ctx);
		const as = client(hq, admin(hq).key);
		expect((await as('GET', '/apps/docs/api/docs/faq')).body).toMatchObject({ title: 'FAQ', revisions: 0 });
		expect((await as('GET', '/apps/docs/api/docs/missing')).status).toBe(404);
	});

	test('semantic search finds docs by meaning and only re-embeds what changed', async () => {
		const embedder = hashEmbedder();
		const hq = createHq({ apps: [docs], ai: { embed: embedder } });
		const ctx = { hub: hq.hub, caller: hq.assistant.self };
		await hq.registry.call(
			'write_doc',
			{ slug: 'launch-plan', title: 'Launch plan', body: 'Beta launches on Friday after the demo.' },
			ctx,
		);
		await hq.registry.call('write_doc', { slug: 'lunch', title: 'Lunch', body: 'Tacos on Tuesdays.' }, ctx);

		const first = await hq.registry.call('search_docs', { query: 'when do we launch?' }, ctx);
		expect(first.ok && (first.value as { slug: string }[])[0]?.slug).toBe('launch-plan');
		expect(embedder.calls.map((c) => c.length)).toEqual([3]);

		await hq.registry.call('search_docs', { query: 'tacos' }, ctx);
		expect(embedder.calls.at(-1)).toEqual(['tacos']);

		await hq.registry.call('write_doc', { slug: 'lunch', title: 'Lunch', body: 'Pizza on Tuesdays.' }, ctx);
		await hq.registry.call('search_docs', { query: 'pizza' }, ctx);
		expect(embedder.calls.at(-1)).toEqual(['pizza', 'Lunch\n\nPizza on Tuesdays.']);
	});

	test('exact matches lead; a broken embedder falls back to keywords', async () => {
		const hq = createHq({
			apps: [docs],
			ai: { embed: { id: 'down', defaultModel: 'm', embed: async () => Promise.reject(new Error('offline')) } },
		});
		const store = new Docs(hq.hub);
		store.write({ slug: 'faq', title: 'FAQ', body: 'How to reset a password', by: hq.assistant.self.id });
		expect(await store.find(hq.ai, 'password')).toEqual([{ slug: 'faq', title: 'FAQ', snippet: 'How to reset a password' }]);
		expect(await store.find(undefined, 'nothing here')).toEqual([]);
	});
});
