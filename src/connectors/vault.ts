import type { Database } from 'bun:sqlite';
import { chmodSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { now } from '../core/ids';
import type { Migration } from '../db/database';

export const VAULT_MIGRATIONS: Migration[] = [
	{
		id: 'core/007_connector_secrets',
		up: `CREATE TABLE connector_secrets (
			slug TEXT PRIMARY KEY,
			iv BLOB NOT NULL,
			ciphertext BLOB NOT NULL,
			updated_by TEXT REFERENCES people(id),
			updated_at INTEGER NOT NULL
		)`,
	},
];

export const vaultKeyPath = (dbPath: string) => join(dirname(dbPath), 'vault.key');

export function readVaultKey(dbPath: string): string | undefined {
	if (dbPath === ':memory:' || !existsSync(vaultKeyPath(dbPath))) return undefined;
	return readFileSync(vaultKeyPath(dbPath), 'utf8').trim() || undefined;
}

export function createVaultKey(dbPath: string): string | null {
	if (readVaultKey(dbPath) !== undefined) return null;
	const key = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url');
	const path = vaultKeyPath(dbPath);
	writeFileSync(path, `${key}\n`, { mode: 0o600, flag: existsSync(path) ? 'w' : 'wx' });
	chmodSync(path, 0o600);
	return key;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const cipher = (slug: string, iv: Uint8Array<ArrayBuffer>): AesGcmParams => ({
	name: 'AES-GCM',
	iv,
	additionalData: encoder.encode(slug),
});

async function importKey(material: string): Promise<CryptoKey> {
	const digest = await crypto.subtle.digest('SHA-256', encoder.encode(material));
	return crypto.subtle.importKey('raw', digest, 'AES-GCM', false, ['encrypt', 'decrypt']);
}

export class Vault {
	private readonly key: Promise<CryptoKey> | null;

	constructor(
		private readonly db: Database,
		material: string | undefined,
	) {
		this.key = material === undefined || material.trim() === '' ? null : importKey(material.trim());
	}

	get enabled(): boolean {
		return this.key !== null;
	}

	has(slug: string): boolean {
		return this.enabled && this.db.query('SELECT 1 FROM connector_secrets WHERE slug = $slug').get({ slug }) !== null;
	}

	configured(): string[] {
		if (!this.enabled) return [];
		return this.db
			.query<{ slug: string }, []>('SELECT slug FROM connector_secrets ORDER BY slug')
			.all()
			.map((row) => row.slug);
	}

	async set(slug: string, secret: string, by: string | null = null): Promise<void> {
		if (this.key === null) throw new Error('the vault is off: run bun hq setup or set HQ_VAULT_KEY to store connector secrets');
		const iv = crypto.getRandomValues(new Uint8Array(12));
		const ciphertext = new Uint8Array(await crypto.subtle.encrypt(cipher(slug, iv), await this.key, encoder.encode(secret)));
		this.db
			.query(
				`INSERT INTO connector_secrets (slug, iv, ciphertext, updated_by, updated_at) VALUES ($slug, $iv, $ciphertext, $by, $at)
				ON CONFLICT(slug) DO UPDATE SET iv = $iv, ciphertext = $ciphertext, updated_by = $by, updated_at = $at`,
			)
			.run({ slug, iv, ciphertext, by, at: now() });
	}

	async get(slug: string): Promise<string | null> {
		if (this.key === null) return null;
		const row = this.db
			.query<{ iv: Uint8Array<ArrayBuffer>; ciphertext: Uint8Array<ArrayBuffer> }, { slug: string }>(
				'SELECT iv, ciphertext FROM connector_secrets WHERE slug = $slug',
			)
			.get({ slug });
		if (row === null) return null;
		try {
			return decoder.decode(await crypto.subtle.decrypt(cipher(slug, row.iv), await this.key, row.ciphertext));
		} catch {
			throw new Error(
				`could not decrypt the ${slug} secret: the vault key (HQ_VAULT_KEY or vault.key) is not the key it was stored with. Restore that key, or set the secret again with bun hq connect ${slug}`,
			);
		}
	}

	remove(slug: string): boolean {
		return this.db.query('DELETE FROM connector_secrets WHERE slug = $slug').run({ slug }).changes > 0;
	}
}
