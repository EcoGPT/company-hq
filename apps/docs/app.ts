import { defineApp, defineTool, HttpError, ToolError, z } from '@hq/sdk';
import { Docs, migrations, SLUG } from './store';

/** The most documents the Files screen lists. */
const SHELF_LIMIT = 500;

const slug = z.string().regex(SLUG, 'kebab-case, like launch-plan');

export default defineApp({
	slug: 'docs',
	name: 'Docs',
	description: "The team's shelf: decisions, processes, running notes.",
	icon: '¶',
	briefing:
		"Docs are the team's shared memory. Check for an existing doc (search_docs) before writing a new one, and fold updates in rather than creating near-duplicates. Write tight Markdown and always send the whole document — write_doc replaces it, and the previous version is kept as a revision.",
	migrations,
	tools: [
		defineTool({
			name: 'list_docs',
			description: 'List every doc on the shelf.',
			input: z.object({}),
			activity: 'Browsing the shelf',
			run: (_, { hub }) =>
				new Docs(hub).list().map(({ slug, title, updated_at }) => ({ slug, title, updated: new Date(updated_at).toISOString() })),
		}),
		defineTool({
			name: 'read_doc',
			description: 'Read a doc by slug.',
			input: z.object({ slug }),
			activity: 'Reading a doc',
			run: ({ slug }, { hub }) => {
				const doc = new Docs(hub).get(slug);
				if (doc === null) throw new ToolError(`no doc ${slug}`);
				return { slug: doc.slug, title: doc.title, body: doc.body };
			},
		}),
		defineTool({
			name: 'search_docs',
			description:
				'Search doc titles and bodies. Exact matches come first, then docs about the same thing when semantic search is on.',
			input: z.object({ query: z.string().min(1) }),
			activity: 'Searching the shelf',
			run: ({ query }, { hub, ai }) => new Docs(hub).find(ai, query),
		}),
		defineTool({
			name: 'write_doc',
			description: 'Create or replace a doc. Send the complete Markdown body; the old version is kept as a revision.',
			input: z.object({ slug, title: z.string().min(1).max(200), body: z.string().max(200_000) }),
			activity: 'Writing a doc',
			run: ({ slug, title, body }, { hub, caller }) => {
				const doc = new Docs(hub).write({ slug, title, body, by: caller.id });
				return { saved: doc.slug };
			},
		}),
	],
	routes: [
		// The app's Files screen. Every signed-in member reads the whole shelf, as they do through the routes below. It has no
		// folders, so `folder_id` is always null.
		{
			method: 'GET',
			path: '/v1/documents',
			mount: 'v1',
			handler: ({ hub }) => ({
				documents: new Docs(hub).shelf(SHELF_LIMIT).map((doc) => ({
					slug: doc.slug,
					title: doc.title,
					updated_at: new Date(doc.updated_at).toISOString(),
					updated_by_name: doc.updated_by_name,
					folder_id: null,
				})),
			}),
		},
		{
			method: 'GET',
			path: '/v1/documents/:slug',
			mount: 'v1',
			handler: ({ hub, params }) => {
				const doc = new Docs(hub).get(params.slug ?? '');
				if (doc === null) throw new HttpError(404, 'doc not found');
				return {
					document: {
						slug: doc.slug,
						title: doc.title,
						content: doc.body,
						updated_at: new Date(doc.updated_at).toISOString(),
						updated_by_name: hub.people.get(doc.updated_by)?.name ?? 'Unknown',
					},
				};
			},
		},
		{ method: 'GET', path: 'docs', handler: ({ hub }) => new Docs(hub).list() },
		{
			method: 'GET',
			path: 'docs/:slug',
			handler: ({ hub, params }) => {
				const store = new Docs(hub);
				const doc = store.get(params.slug ?? '');
				if (doc === null) throw new HttpError(404, 'doc not found');
				return { ...doc, revisions: store.revisions(doc.slug).length };
			},
		},
	],
});
