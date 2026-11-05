import { Database } from 'bun:sqlite';

export type Migration = {
	id: string;
	up: string | ((db: Database) => void);
};

export function openDatabase(path = ':memory:'): Database {
	const db = new Database(path, { create: true, strict: true });
	db.exec('PRAGMA journal_mode = WAL;');
	db.exec('PRAGMA synchronous = NORMAL;');
	db.exec('PRAGMA foreign_keys = ON;');
	db.exec('PRAGMA busy_timeout = 5000;');
	return db;
}

export function migrate(db: Database, migrations: Migration[]): string[] {
	db.exec('CREATE TABLE IF NOT EXISTS _migrations (id TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)');
	const seen = new Set<string>();
	for (const migration of migrations) {
		if (seen.has(migration.id)) throw new Error(`duplicate migration id: ${migration.id}`);
		seen.add(migration.id);
	}
	const applied = new Set(
		db
			.query<{ id: string }, []>('SELECT id FROM _migrations')
			.all()
			.map((row) => row.id),
	);
	const ran: string[] = [];
	for (const migration of migrations) {
		if (applied.has(migration.id)) continue;
		db.transaction(() => {
			if (typeof migration.up === 'string') db.exec(migration.up);
			else migration.up(db);
			db.query('INSERT INTO _migrations (id, applied_at) VALUES ($id, $at)').run({ id: migration.id, at: Date.now() });
		})();
		ran.push(migration.id);
	}
	return ran;
}
