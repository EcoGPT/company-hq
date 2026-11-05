import { describe, expect, test } from 'bun:test';
import { migrate, openDatabase } from '../src/db/database';
import { Keys, KEY_MIGRATIONS } from '../src/core/keys';
import { People, PEOPLE_MIGRATIONS } from '../src/core/people';

function setup() {
	const db = openDatabase();
	migrate(db, [...PEOPLE_MIGRATIONS, ...KEY_MIGRATIONS]);
	return { db, people: new People(db), keys: new Keys(db) };
}

describe('people', () => {
	test('handles are unique, case-insensitive', () => {
		const { people } = setup();
		people.create({ name: 'Ada', handle: 'ada' });
		expect(() => people.create({ name: 'Other', handle: 'ADA' })).toThrow();
		expect(people.byHandle('Ada')?.name).toBe('Ada');
	});

	test('ensure is idempotent and follows renames', () => {
		const { people } = setup();
		const first = people.ensure({ name: 'Atlas', handle: 'atlas', kind: 'assistant' });
		const again = people.ensure({ name: 'Echo', handle: 'atlas', kind: 'assistant' });
		expect(again.id).toBe(first.id);
		expect(people.get(first.id)?.name).toBe('Echo');
		expect(people.list()).toHaveLength(1);
	});

	test('ensure will not turn someone of another kind into the assistant', () => {
		const { people } = setup();
		const bo = people.create({ name: 'Bo', handle: 'bo' });
		expect(() => people.ensure({ name: 'Helper', handle: 'BO', kind: 'assistant' })).toThrow('already belongs to a human');
		expect(people.get(bo.id)?.name).toBe('Bo');
	});

	test('byIds looks people up in one go', () => {
		const { people } = setup();
		const ada = people.create({ name: 'Ada', handle: 'ada' });
		const bo = people.create({ name: 'Bo', handle: 'bo' });
		const found = people.byIds([bo.id, ada.id, bo.id, 'nobody']);
		expect([...found.keys()].sort()).toEqual([ada.id, bo.id].sort());
		expect(found.get(bo.id)).toEqual(people.get(bo.id)!);
		expect(people.byIds([]).size).toBe(0);
	});

	test('rejects bad handles', () => {
		expect(() => setup().people.create({ name: 'x', handle: 'has space' })).toThrow();
	});
});

describe('keys', () => {
	test('a minted key authenticates until revoked', () => {
		const { people, keys } = setup();
		const ada = people.create({ name: 'Ada', handle: 'ada' });
		const { key, secret } = keys.mint(ada.id, 'key', { label: 'laptop' });
		expect(keys.authenticate(secret)?.id).toBe(ada.id);
		expect(keys.list(ada.id)[0]?.last_used_at).not.toBeNull();
		expect(keys.revoke(key.id)).toBe(true);
		expect(keys.authenticate(secret)).toBeNull();
	});

	test('last_used_at is written at most once a minute', () => {
		const { db, people, keys } = setup();
		const ada = people.create({ name: 'Ada', handle: 'ada' });
		const { secret } = keys.mint(ada.id);
		const usedAt = () => keys.list(ada.id)[0]!.last_used_at!;
		const writes = () => db.query<{ n: number }, []>('SELECT total_changes() AS n').get()!.n;
		expect(keys.authenticate(secret)).toEqual(people.get(ada.id)!);
		const first = usedAt();
		const before = writes();
		for (let i = 0; i < 5; i++) expect(keys.authenticate(secret)?.id).toBe(ada.id);
		expect(writes()).toBe(before);
		expect(usedAt()).toBe(first);
		db.query('UPDATE api_keys SET last_used_at = last_used_at - 61000').run();
		keys.authenticate(secret);
		expect(usedAt()).toBeGreaterThanOrEqual(first);
	});

	test('unknown secrets do not authenticate', () => {
		expect(setup().keys.authenticate('hq_nope')).toBeNull();
		expect(setup().keys.authenticate('nope')).toBeNull();
	});
});
