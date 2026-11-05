import { describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { boot } from '../src/boot';
import { migrate, openDatabase } from '../src/db/database';
import { createVaultKey, readVaultKey, Vault, VAULT_MIGRATIONS, vaultKeyPath } from '../src/connectors/vault';
import { PEOPLE_MIGRATIONS } from '../src/core/people';

function db() {
	const d = openDatabase();
	migrate(d, [...PEOPLE_MIGRATIONS, ...VAULT_MIGRATIONS]);
	return d;
}

describe('vault', () => {
	test('round-trips secrets, never stores plaintext', async () => {
		const d = db();
		const vault = new Vault(d, 'correct horse battery staple');
		await vault.set('github', 'ghp_supersecret');
		expect(await vault.get('github')).toBe('ghp_supersecret');
		expect(vault.has('github')).toBe(true);
		expect(vault.configured()).toEqual(['github']);
		const raw = d.query<{ ciphertext: Uint8Array }, []>('SELECT ciphertext FROM connector_secrets').get()!;
		expect(Buffer.from(raw.ciphertext).toString()).not.toContain('supersecret');
	});

	test('a different key cannot read it', async () => {
		const d = db();
		await new Vault(d, 'key-one').set('github', 'secret');
		await expect(new Vault(d, 'key-two').get('github')).rejects.toThrow(
			'could not decrypt the github secret: the vault key (HQ_VAULT_KEY or vault.key) is not the key it was stored with',
		);
	});

	test('rows are bound to their slug', async () => {
		const d = db();
		const vault = new Vault(d, 'k');
		await vault.set('a', 'secret-a');
		d.query("UPDATE connector_secrets SET slug = 'b' WHERE slug = 'a'").run();
		await expect(vault.get('b')).rejects.toThrow();
	});

	test('without a key the vault is off', async () => {
		const vault = new Vault(db(), undefined);
		expect(vault.enabled).toBe(false);
		expect(vault.has('github')).toBe(false);
		await expect(vault.set('github', 'x')).rejects.toThrow('HQ_VAULT_KEY');
	});

	test('remove deletes the secret', async () => {
		const vault = new Vault(db(), 'k');
		await vault.set('x', 'y');
		expect(vault.remove('x')).toBe(true);
		expect(await vault.get('x')).toBeNull();
	});

	test('the key file next to the database turns the vault on, and HQ_VAULT_KEY wins over it', async () => {
		const dir = mkdtempSync(join(tmpdir(), 'hq-vault-'));
		try {
			const dbPath = join(dir, 'hq.sqlite');
			expect(boot({ HQ_DB: dbPath }).hq.vault.enabled).toBe(false);
			const key = createVaultKey(dbPath)!;
			expect(createVaultKey(dbPath)).toBeNull();
			expect(readVaultKey(dbPath)).toBe(key);
			await Bun.write(vaultKeyPath(dbPath), '\n');
			expect(readVaultKey(dbPath)).toBeUndefined();
			const fresh = createVaultKey(dbPath)!;
			expect(readVaultKey(dbPath)).toBe(fresh);
			expect(statSync(vaultKeyPath(dbPath)).mode & 0o777).toBe(0o600);
			await boot({ HQ_DB: dbPath }).hq.vault.set('github', 'secret');
			expect(await boot({ HQ_DB: dbPath }).hq.vault.get('github')).toBe('secret');
			await expect(boot({ HQ_DB: dbPath, HQ_VAULT_KEY: 'other' }).hq.vault.get('github')).rejects.toThrow('could not decrypt');
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});
});
