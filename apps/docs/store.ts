import type { Ai, Hub, Migration } from '@hq/sdk';
import { cosine, newId, now } from '@hq/sdk';

export type Doc = { slug: string; title: string; body: string; updated_by: string; updated_at: number };
export type Revision = { id: string; slug: string; title: string; body: string; updated_by: string; updated_at: number };
export type SearchHit = { slug: string; title: string; snippet: string };

export const migrations: Migration[] = [
	{
		id: '001_docs',
		up: `CREATE TABLE docs (
			slug TEXT PRIMARY KEY,
			title TEXT NOT NULL,
			body TEXT NOT NULL,
			updated_by TEXT NOT NULL REFERENCES people(id),
			updated_at INTEGER NOT NULL
		);
		CREATE TABLE doc_revisions (
			id TEXT PRIMARY KEY,
			slug TEXT NOT NULL,
			title TEXT NOT NULL,
			body TEXT NOT NULL,
			updated_by TEXT NOT NULL REFERENCES people(id),
			updated_at INTEGER NOT NULL
		);
		CREATE INDEX doc_revisions_slug ON doc_revisions(slug, id);`,
	},
	{
		id: '002_search_index',
		up: `CREATE INDEX docs_updated ON docs(updated_at);
		CREATE VIRTUAL TABLE docs_fts USING fts5(title, body, content = 'docs', tokenize = 'trigram');
		INSERT INTO docs_fts (docs_fts) VALUES ('rebuild');
		CREATE TRIGGER docs_fts_insert AFTER INSERT ON docs BEGIN
			INSERT INTO docs_fts (rowid, title, body) VALUES (new.rowid, new.title, new.body);
		END;
		CREATE TRIGGER docs_fts_delete AFTER DELETE ON docs BEGIN
			INSERT INTO docs_fts (docs_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
		END;
		CREATE TRIGGER docs_fts_update AFTER UPDATE ON docs BEGIN
			INSERT INTO docs_fts (docs_fts, rowid, title, body) VALUES ('delete', old.rowid, old.title, old.body);
			INSERT INTO docs_fts (rowid, title, body) VALUES (new.rowid, new.title, new.body);
		END;`,
	},
	{
		id: '003_doc_embeddings',
		up: `CREATE TABLE doc_embeddings (
			slug TEXT PRIMARY KEY,
			model TEXT NOT NULL,
			hash TEXT NOT NULL,
			vector BLOB NOT NULL
		)`,
	},
];

const EMBED_CHARS = 8000;

function embeddable(doc: Doc): string {
	return `${doc.title}\n\n${doc.body}`.slice(0, EMBED_CHARS);
}

function snippet(doc: Doc, needle: string): string {
	const at = Math.max(doc.body.toLowerCase().indexOf(needle), 0);
	return doc.body.slice(Math.max(at - 80, 0), at + 160);
}

export const SLUG = /^[a-z0-9][a-z0-9-]{0,79}$/;

export class Docs {
	constructor(private readonly hub: Hub) {}

	get(slug: string): Doc | null {
		return this.hub.db.query<Doc, { slug: string }>('SELECT * FROM docs WHERE slug = $slug').get({ slug });
	}

	list(): Omit<Doc, 'body'>[] {
		return this.hub.db
			.query<Omit<Doc, 'body'>, []>('SELECT slug, title, updated_by, updated_at FROM docs ORDER BY updated_at DESC')
			.all();
	}

	/** The shelf as the Files screen lists it, newest first, with who last wrote each. */
	shelf(limit: number): (Omit<Doc, 'body'> & { updated_by_name: string })[] {
		return this.hub.db
			.query<Omit<Doc, 'body'> & { updated_by_name: string }, { limit: number }>(
				`SELECT d.slug, d.title, d.updated_by, d.updated_at, p.name AS updated_by_name FROM docs d
				JOIN people p ON p.id = d.updated_by ORDER BY d.updated_at DESC, d.slug LIMIT $limit`,
			)
			.all({ limit });
	}

	write(input: { slug: string; title: string; body: string; by: string }): Doc {
		if (!SLUG.test(input.slug)) throw new Error(`doc slugs are kebab-case: ${input.slug}`);
		const doc: Doc = { slug: input.slug, title: input.title.trim(), body: input.body, updated_by: input.by, updated_at: now() };
		this.hub.db.transaction(() => {
			this.archive(input.slug);
			this.hub.db
				.query(
					`INSERT INTO docs (slug, title, body, updated_by, updated_at) VALUES ($slug, $title, $body, $updated_by, $updated_at)
					ON CONFLICT(slug) DO UPDATE SET title = $title, body = $body, updated_by = $updated_by, updated_at = $updated_at`,
				)
				.run(doc);
		})();
		return doc;
	}

	delete(slug: string): boolean {
		return this.hub.db.transaction(() => {
			this.archive(slug);
			this.hub.db.query('DELETE FROM doc_embeddings WHERE slug = $slug').run({ slug });
			return this.hub.db.query('DELETE FROM docs WHERE slug = $slug').run({ slug }).changes > 0;
		})();
	}

	revisions(slug: string): Revision[] {
		return this.hub.db
			.query<Revision, { slug: string }>('SELECT * FROM doc_revisions WHERE slug = $slug ORDER BY id DESC')
			.all({ slug });
	}

	search(query: string, limit = 10): SearchHit[] {
		const needle = query.trim().toLowerCase();
		if (needle === '') return [];
		const page = this.hub.db.query<Doc, { match: string | null; limit: number; offset: number }>(
			`SELECT * FROM docs
			WHERE $match IS NULL OR rowid IN (SELECT rowid FROM docs_fts WHERE docs_fts MATCH $match)
			ORDER BY updated_at DESC LIMIT $limit OFFSET $offset`,
		);
		const match = [...needle].length < 3 ? null : `"${needle.replaceAll('"', '""')}"`;
		const hits: SearchHit[] = [];
		for (let offset = 0, size = limit; hits.length < limit; offset += size, size *= 2) {
			const rows = page.all({ match, limit: size, offset });
			for (const doc of rows) {
				if (hits.length === limit) break;
				if (!doc.title.toLowerCase().includes(needle) && !doc.body.toLowerCase().includes(needle)) continue;
				hits.push({ slug: doc.slug, title: doc.title, snippet: snippet(doc, needle) });
			}
			if (rows.length < size) break;
		}
		return hits;
	}

	async semanticSearch(ai: Ai, query: string, limit = 5): Promise<(SearchHit & { score: number })[]> {
		const model = ai.describe().embed?.model ?? 'default';
		const docs = this.hub.db.query<Doc, []>('SELECT * FROM docs').all();
		if (docs.length === 0) return [];
		const indexed = new Map(
			this.hub.db
				.query<{ slug: string; model: string; hash: string; vector: Uint8Array }, []>('SELECT * FROM doc_embeddings')
				.all()
				.map((row) => [row.slug, row]),
		);
		const stale = docs.flatMap((doc) => {
			const hash = Bun.hash(embeddable(doc)).toString(36);
			const row = indexed.get(doc.slug);
			return row !== undefined && row.model === model && row.hash === hash ? [] : [{ doc, hash }];
		});
		const vectors = new Map<string, number[]>();
		for (const [slug, row] of indexed) {
			vectors.set(slug, Array.from(new Float32Array(new Uint8Array(row.vector).buffer)));
		}
		const [queryVector = [], ...fresh] = await ai.embed([query, ...stale.map(({ doc }) => embeddable(doc))]);
		const upsert = this.hub.db.query(
			`INSERT INTO doc_embeddings (slug, model, hash, vector) VALUES ($slug, $model, $hash, $vector)
			ON CONFLICT(slug) DO UPDATE SET model = $model, hash = $hash, vector = $vector`,
		);
		this.hub.db.transaction(() => {
			stale.forEach(({ doc, hash }, i) => {
				const vector = fresh[i];
				if (vector === undefined) return;
				vectors.set(doc.slug, vector);
				upsert.run({ slug: doc.slug, model, hash, vector: new Uint8Array(new Float32Array(vector).buffer) });
			});
		})();
		const needle = query.trim().toLowerCase();
		return docs
			.map((doc) => ({ doc, score: cosine(queryVector, vectors.get(doc.slug) ?? []) }))
			.sort((a, b) => b.score - a.score)
			.slice(0, limit)
			.map(({ doc, score }) => ({
				slug: doc.slug,
				title: doc.title,
				snippet: snippet(doc, needle),
				score: Math.round(score * 1000) / 1000,
			}));
	}

	async find(ai: Ai | undefined, query: string, limit = 10): Promise<SearchHit[]> {
		const keyword = this.search(query, limit);
		if (ai === undefined || !ai.has('embed')) return keyword;
		let semantic: SearchHit[] = [];
		try {
			semantic = await this.semanticSearch(ai, query, limit);
		} catch (error) {
			console.warn(`[docs] semantic search failed, using keywords: ${error instanceof Error ? error.message : error}`);
		}
		const seen = new Set(keyword.map((hit) => hit.slug));
		return [...keyword, ...semantic.filter((hit) => !seen.has(hit.slug))].slice(0, limit);
	}

	private archive(slug: string): void {
		const current = this.get(slug);
		if (current === null) return;
		this.hub.db
			.query(
				'INSERT INTO doc_revisions (id, slug, title, body, updated_by, updated_at) VALUES ($id, $slug, $title, $body, $updated_by, $updated_at)',
			)
			.run({ id: newId(), ...current });
	}
}
