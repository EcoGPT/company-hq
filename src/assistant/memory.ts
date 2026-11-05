import type { Database } from 'bun:sqlite';
import { z } from 'zod';
import { newId, now } from '../core/ids';
import type { Migration } from '../db/database';
import { canSee, defineTool, ToolError, type Tool, type ToolContext } from '../tools/define';

export type MemoryEntry = {
	id: string;
	content: string;
	created_by: string | null;
	created_at: number;
	conversation_id: string | null;
};

export const MEMORY_MIGRATIONS: Migration[] = [
	{
		id: 'core/005_assistant_memory',
		up: `CREATE TABLE assistant_memory (
			id TEXT PRIMARY KEY,
			content TEXT NOT NULL,
			created_by TEXT REFERENCES people(id),
			created_at INTEGER NOT NULL
		)`,
	},
	{
		id: 'core/010_memory_source',
		up: 'ALTER TABLE assistant_memory ADD COLUMN conversation_id TEXT REFERENCES conversations(id)',
	},
];

const visibleMemory = (ctx: ToolContext, entry: MemoryEntry) =>
	entry.conversation_id === null || canSee(ctx, entry.conversation_id);

export class Memory {
	constructor(private readonly db: Database) {}

	add(content: string, createdBy: string | null = null, conversationId: string | null = null): MemoryEntry {
		const entry: MemoryEntry = {
			id: newId(),
			content: content.trim(),
			created_by: createdBy,
			created_at: now(),
			conversation_id: conversationId,
		};
		this.db
			.query(
				'INSERT INTO assistant_memory (id, content, created_by, created_at, conversation_id) VALUES ($id, $content, $created_by, $created_at, $conversation_id)',
			)
			.run(entry);
		return entry;
	}

	get(id: string): MemoryEntry | null {
		return this.db.query<MemoryEntry, { id: string }>('SELECT * FROM assistant_memory WHERE id = $id').get({ id });
	}

	remove(id: string): boolean {
		return this.db.query('DELETE FROM assistant_memory WHERE id = $id').run({ id }).changes > 0;
	}

	visibleTo(people: string[], limit = 100): MemoryEntry[] {
		return this.db
			.query<MemoryEntry, { people: string; limit: number }>(
				`SELECT * FROM (
					SELECT * FROM assistant_memory m
					WHERE m.conversation_id IS NULL OR NOT EXISTS (
						SELECT 1 FROM json_each($people) p WHERE NOT EXISTS (
							SELECT 1 FROM open_conversation_members c WHERE c.conversation_id = m.conversation_id AND c.person_id = p.value
						)
					)
					ORDER BY id DESC LIMIT $limit
				) ORDER BY id`,
			)
			.all({ people: JSON.stringify([...new Set(people)]), limit });
	}

	list(limit = 100): MemoryEntry[] {
		return this.db
			.query<MemoryEntry, { limit: number }>(
				'SELECT * FROM (SELECT * FROM assistant_memory ORDER BY id DESC LIMIT $limit) ORDER BY id',
			)
			.all({ limit });
	}
}

export function memoryTools(memory: Memory): Tool[] {
	return [
		defineTool({
			name: 'remember',
			description:
				'Save a durable fact for future conversations: a preference, a habit, who owns what. One fact per call, written so it stands alone.',
			input: z.object({ fact: z.string().min(3).max(1000) }),
			audience: 'assistant',
			activity: 'Making a note',
			run: ({ fact }, { caller, conversationId }) => ({ saved: memory.add(fact, caller.id, conversationId ?? null).id }),
		}),
		defineTool({
			name: 'forget',
			description: 'Delete a saved fact by id when it is wrong or no longer true.',
			input: z.object({ id: z.string() }),
			audience: 'assistant',
			activity: 'Updating notes',
			run: ({ id }, ctx) => {
				const entry = memory.get(id);
				if (entry === null || !visibleMemory(ctx, entry) || !memory.remove(id)) throw new ToolError(`no memory ${id}`);
				return { forgot: id };
			},
		}),
	];
}
