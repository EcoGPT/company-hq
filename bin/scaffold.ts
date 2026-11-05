const title = (slug: string) =>
	slug
		.split('-')
		.map((w) => w.charAt(0).toUpperCase() + w.slice(1))
		.join(' ');
const camel = (slug: string) => slug.replace(/-([a-z0-9])/g, (_, c: string) => c.toUpperCase());
const snake = (slug: string) => slug.replace(/-/g, '_');
const pascal = (slug: string) => title(slug).replace(/ /g, '');

const quote = (text: string) => `'${text.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\n/g, ' ')}'`;

export const SLUG = /^(?=.{1,32}$)[a-z](?:-?[a-z0-9])*$/;

export function appFiles(slug: string, description?: string): Record<string, string> {
	const name = title(slug);
	const table = `${snake(slug)}_items`;
	const store = `${pascal(slug)}Store`;
	return {
		'store.ts': `import type { Hub, Migration } from '@hq/sdk';
import { newId, now } from '@hq/sdk';

export type Item = { id: string; body: string; created_by: string; created_at: number };

export const migrations: Migration[] = [
	{
		id: '001_items',
		up: \`CREATE TABLE ${table} (
			id TEXT PRIMARY KEY,
			body TEXT NOT NULL,
			created_by TEXT NOT NULL REFERENCES people(id),
			created_at INTEGER NOT NULL
		);\`,
	},
];

export class ${store} {
	constructor(private readonly hub: Hub) {}

	add(body: string, createdBy: string): Item {
		const item: Item = { id: newId(), body: body.trim(), created_by: createdBy, created_at: now() };
		this.hub.db
			.query(
				\`INSERT INTO ${table} (id, body, created_by, created_at)
				VALUES ($id, $body, $created_by, $created_at)\`,
			)
			.run(item);
		return item;
	}

	list(limit = 100): Item[] {
		return this.hub.db
			.query<Item, { limit: number }>(
				\`SELECT * FROM ${table}
				ORDER BY id DESC LIMIT $limit\`,
			)
			.all({ limit });
	}
}
`,
		'app.ts': `import { defineApp, defineTool, readBody, z, type Hub } from '@hq/sdk';
import { ${store}, migrations, type Item } from './store';

const changed = (hub: Hub, item: Item) => {
	hub.bus.emit({ type: 'app.event', app: '${slug}', name: 'changed', data: { id: item.id } });
	return item;
};

export default defineApp({
	slug: '${slug}',
	name: '${name}',
	description: ${quote(description ?? `Notes the team keeps in ${name}.`)},
	icon: '◆',
	briefing:
		'When someone asks to save something to ${name}, use ${snake(slug)}_add. To answer questions about it, read it with ${snake(slug)}_list first.',
	migrations,
	tools: [
		defineTool({
			name: '${snake(slug)}_add',
			description: 'Add an item to ${name}.',
			input: z.object({ body: z.string().min(1).max(2000) }),
			activity: 'Updating ${name}',
			run: ({ body }, { hub, caller }) => changed(hub, new ${store}(hub).add(body, caller.id)),
		}),
		defineTool({
			name: '${snake(slug)}_list',
			description: 'List the latest ${name} items, newest first.',
			input: z.object({}),
			activity: 'Reading ${name}',
			run: (_, { hub }) => new ${store}(hub).list(),
		}),
	],
	routes: [
		{ method: 'GET', path: 'items', handler: ({ hub }) => new ${store}(hub).list() },
		{
			method: 'POST',
			path: 'items',
			handler: async ({ hub, req, person }) => {
				const { body } = await readBody(req, z.object({ body: z.string().min(1).max(2000) }));
				return changed(hub, new ${store}(hub).add(body, person.id));
			},
		},
	],
	automations: [],
});
`,
		[`${slug}.test.ts`]: `import { describe, expect, test } from 'bun:test';
import { createHq } from '@hq/sdk/testing';
import app from './app';

describe('${slug}', () => {
	test('add and list', async () => {
		const hq = createHq({ apps: [app] });
		const ctx = { hub: hq.hub, caller: hq.assistant.self };
		expect((await hq.registry.call('${snake(slug)}_add', { body: 'first' }, ctx)).ok).toBe(true);
		const listed = await hq.registry.call('${snake(slug)}_list', {}, ctx);
		expect(listed.ok && (listed.value as { body: string }[]).map((i) => i.body)).toEqual(['first']);
	});
});
`,
	};
}

export function automationFile(slug: string): string {
	return `import { defineAutomation } from '@hq/sdk';

export default defineAutomation({
	slug: '${slug}',
	name: '${title(slug)}',
	description: 'What this does, when, and what it never does.',
	schedule: '0 14 * * 1-5',
	async run({ hub, assistant, log }) {
		log('starting');
		const text = await assistant.ask('Write a one-line note for the team.');
		assistant.post(hub.general().id, text);
		return 'posted';
	},
});
`;
}

export function connectorFile(slug: string, baseUrl: string): string {
	return `import { httpConnector } from '@hq/sdk';

export default httpConnector({
	slug: '${slug}',
	name: '${title(slug)}',
	description: 'What the assistant can read from ${title(slug)}.',
	baseUrl: '${baseUrl}',
	auth: 'bearer',
	secretHelp: 'Where to create a ${title(slug)} API key.',
});
`;
}

function addImport(source: string, line: string): string {
	if (source.includes(line)) return source;
	const imports = [...source.matchAll(/^import .*;$/gm)];
	const last = imports.at(-1);
	if (last === undefined) return `${line}\n${source}`;
	const at = last.index + last[0].length;
	return `${source.slice(0, at)}\n${line}${source.slice(at)}`;
}

function addToArray(source: string, key: string, name: string): string {
	const pattern = new RegExp(`(${key}:\\s*\\[)([^\\]]*)(\\])`);
	const match = pattern.exec(source);
	if (match === null) throw new Error(`could not find \`${key}: [...]\`. Add \`${key}: [],\` and run this again.`);
	const items = match[2]!
		.split(',')
		.map((s) => s.trim())
		.filter(Boolean);
	if (items.includes(name)) return source;
	return source.replace(pattern, `$1${[...items, name].join(', ')}$3`);
}

const RESERVED = new Set(
	'arguments await break case catch class const continue debugger default delete do else enum eval export extends false finally for function if implements import in instanceof interface let new null package private protected public return static super switch this throw true try typeof var void while with yield'.split(
		' ',
	),
);

export function register(source: string, key: 'apps' | 'connectors' | 'automations', name: string, from: string): string {
	if (RESERVED.has(name)) throw new Error(`${name} is a reserved word in TypeScript. Pick another slug.`);
	const line = `import ${name} from '${from}';`;
	const bindings = [...source.matchAll(/^import\s+([^'"]+?)\s+from\s/gm)].map((m) => m[1]!);
	if (!source.includes(line) && bindings.some((b) => new RegExp(`\\b${name}\\b`).test(b))) {
		throw new Error(`${name} is already imported in this file. Pick another slug.`);
	}
	const declared = new RegExp(
		`^(?:export\\s+)?(?:const|let|var|(?:async\\s+)?function\\*?|class|type|interface|enum)\\s+${name}\\b`,
		'm',
	);
	if (declared.test(source)) {
		throw new Error(`${name} is already declared in this file. Pick another slug.`);
	}
	return addToArray(addImport(source, line), key, name);
}

export const names = { camel, pascal, snake, title };
