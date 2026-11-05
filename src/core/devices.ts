import type { Database } from 'bun:sqlite';
import { newId, now } from './ids';
import type { Keys } from './keys';

export type Device = { id: string; person_id: string; key_id: string; name: string; created_at: number };

/** One sign-in on one phone or computer. Its bearer is an api key, so everything that honours keys honours devices. */
export class Devices {
	constructor(
		private readonly db: Database,
		private readonly keys: Keys,
	) {}

	enroll(personId: string, name: string): { device: Device; bearer: string } {
		return this.db.transaction(() => {
			const { key, secret } = this.keys.mint(personId, 'device');
			const device: Device = { id: newId(), person_id: personId, key_id: key.id, name, created_at: now() };
			this.db
				.query(
					'INSERT INTO devices (id, person_id, key_id, name, created_at) VALUES ($id, $person_id, $key_id, $name, $created_at)',
				)
				.run({ ...device });
			return { device, bearer: secret };
		})();
	}

	get(id: string): Device | null {
		return this.db.query<Device, { id: string }>('SELECT * FROM devices WHERE id = $id').get({ id });
	}

	byKey(keyId: string): Device | null {
		return this.db.query<Device, { id: string }>('SELECT * FROM devices WHERE key_id = $id').get({ id: keyId });
	}

	/** Kills the bearer; open sockets close when the key's revocation reaches them. */
	revoke(id: string): boolean {
		const device = this.get(id);
		return device !== null && this.keys.revoke(device.key_id);
	}
}
