import { describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { migrate, openDatabase } from '../src/db/database';

describe('migrate', () => {
	test('applies each step once, in order', () => {
		const db = openDatabase();
		const ladder = [
			{ id: 'a', up: 'CREATE TABLE t (x INTEGER)' },
			{ id: 'b', up: 'ALTER TABLE t ADD COLUMN y INTEGER' },
		];
		expect(migrate(db, ladder)).toEqual(['a', 'b']);
		expect(migrate(db, ladder)).toEqual([]);
		expect(migrate(db, [...ladder, { id: 'c', up: 'CREATE TABLE u (z TEXT)' }])).toEqual(['c']);
	});

	test('rolls back a failing step', () => {
		const db = openDatabase();
		expect(() => migrate(db, [{ id: 'bad', up: 'CREATE TABLE t (x INTEGER); NOT SQL' }])).toThrow();
		expect(db.query('SELECT name FROM sqlite_master WHERE name = $n').get({ n: 't' })).toBeNull();
		expect(migrate(db, [{ id: 'bad', up: 'CREATE TABLE t (x INTEGER)' }])).toEqual(['bad']);
	});

	test('accepts function steps', () => {
		const db = openDatabase();
		migrate(db, [{ id: 'fn', up: (d) => d.exec('CREATE TABLE f (x INTEGER)') }]);
		expect(db.query('SELECT name FROM sqlite_master WHERE name = $n').get({ n: 'f' })).not.toBeNull();
	});

	test('refuses duplicate ids', () => {
		expect(() =>
			migrate(openDatabase(), [
				{ id: 'x', up: 'SELECT 1' },
				{ id: 'x', up: 'SELECT 1' },
			]),
		).toThrow('duplicate');
	});
});

describe('openDatabase', () => {
	test('file databases use WAL with synchronous = NORMAL', () => {
		const dir = mkdtempSync(join(tmpdir(), 'hq-db-'));
		try {
			const db = openDatabase(join(dir, 'hq.sqlite'));
			expect(db.query<{ journal_mode: string }, []>('PRAGMA journal_mode').get()?.journal_mode).toBe('wal');
			expect(db.query<{ synchronous: number }, []>('PRAGMA synchronous').get()?.synchronous).toBe(1);
			expect(db.query<{ foreign_keys: number }, []>('PRAGMA foreign_keys').get()?.foreign_keys).toBe(1);
			db.close();
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});
});
