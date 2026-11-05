import type { Database } from 'bun:sqlite';
import type { Migration } from '../db/database';
import { now } from '../core/ids';
import type { PushEnvironment } from './provider';

/** Ids start at `push/001`. The table is this module's: `devices` gets no columns. */
export const PUSH_MIGRATIONS: Migration[] = [
	{
		// One row per device. A token belongs to one device: UNIQUE, and a report that brings a token another device holds moves it.
		// `status` is what the app last said about its push standing, kept so a host can see why a device is silent.
		id: 'push/001_tokens',
		up: `CREATE TABLE push_tokens (
			device_id TEXT PRIMARY KEY REFERENCES devices(id),
			token TEXT UNIQUE,
			environment TEXT CHECK (environment IN ('development', 'production')),
			status TEXT NOT NULL,
			status_at INTEGER NOT NULL,
			CHECK ((token IS NULL) = (environment IS NULL))
		)`,
	},
	{
		// The phone's VoIP (ring) token, beside the alert token. It has its own environment so that Apple refusing one of the
		// two tokens leaves the other one working. Like `token`, it belongs to one device.
		id: 'push/002_voip_tokens',
		up: `ALTER TABLE push_tokens ADD COLUMN voip_token TEXT;
			ALTER TABLE push_tokens ADD COLUMN voip_environment TEXT
				CHECK ((voip_environment IS NULL) = (voip_token IS NULL) AND voip_environment IN ('development', 'production'));
			CREATE UNIQUE INDEX push_tokens_voip_token ON push_tokens (voip_token)`,
	},
];

export type PushDevice = { deviceId: string; token: string; environment: PushEnvironment };

/** Which of a device's two tokens a push goes to. */
export type TokenKind = 'alert' | 'voip';

/**
 * A device and the token a push goes to. A ring picks the VoIP token when there is one, otherwise the alert token; every
 * other push goes to the alert token.
 */
export type RingDevice = PushDevice & { kind: TokenKind };

/**
 * What a device reported. `environment` is the build's, sent with either token: each stored token keeps it, so a phone
 * that refused notifications (no alert token) can still be rung on its VoIP token.
 */
export type PushReport = { status: string; token?: string; voipToken?: string; environment?: PushEnvironment };

/** A device that may be pushed to: its key is live, and its person is a human who has not been removed. */
const LIVE = `
	FROM push_tokens t
	JOIN devices d ON d.id = t.device_id
	JOIN api_keys k ON k.id = d.key_id
	JOIN people p ON p.id = d.person_id
	JOIN open_conversation_members m ON m.person_id = d.person_id AND m.conversation_id = $conversation
	WHERE k.revoked_at IS NULL AND p.removed_at IS NULL AND p.kind = 'human'`;

/**
 * Devices that may be pushed to and hold an alert token. Narrowed by the callers to a conversation's open members (an
 * archived room has none).
 */
const LIVE_DEVICES = `SELECT t.device_id AS deviceId, t.token, t.environment ${LIVE} AND t.token IS NOT NULL`;

/** The same for a ring: either token will do, and the VoIP one wins. */
const RING_DEVICES = `
	SELECT t.device_id AS deviceId,
		CASE WHEN t.voip_token IS NOT NULL THEN 'voip' ELSE 'alert' END AS kind,
		COALESCE(t.voip_token, t.token) AS token,
		CASE WHEN t.voip_token IS NOT NULL THEN t.voip_environment ELSE t.environment END AS environment
	${LIVE} AND (t.voip_token IS NOT NULL OR t.token IS NOT NULL)`;

export class PushTokens {
	constructor(private readonly db: Database) {}

	/** What a device last reported. A report with no token means it has none now, so any token it held is dropped. */
	report(deviceId: string, report: PushReport): void {
		const { token = null, voipToken = null, status } = report;
		const environment = report.environment ?? null;
		const at = now();
		this.db.transaction(() => {
			// The phone may have changed hands: the last device to report a token is the one that holds it.
			if (token !== null) {
				this.db
					.query(
						`UPDATE push_tokens SET token = NULL, environment = NULL, status = 'unregistered', status_at = $at
						WHERE token = $token AND device_id != $device`,
					)
					.run({ token, device: deviceId, at });
			}
			if (voipToken !== null) {
				this.db
					.query(
						`UPDATE push_tokens SET voip_token = NULL, voip_environment = NULL
						WHERE voip_token = $voip AND device_id != $device`,
					)
					.run({ voip: voipToken, device: deviceId });
			}
			this.db
				.query(
					`INSERT INTO push_tokens (device_id, token, environment, voip_token, voip_environment, status, status_at)
					VALUES ($device, $token, $environment, $voip, $voipEnvironment, $status, $at)
					ON CONFLICT (device_id) DO UPDATE
					SET token = $token, environment = $environment, voip_token = $voip, voip_environment = $voipEnvironment,
						status = $status, status_at = $at`,
				)
				.run({
					device: deviceId,
					token,
					environment: token === null ? null : environment,
					voip: voipToken,
					voipEnvironment: voipToken === null ? null : environment,
					status,
					at,
				});
		})();
	}

	/** Sign-out: this device is no longer pushed to, by either token. */
	clear(deviceId: string): void {
		this.db.query('DELETE FROM push_tokens WHERE device_id = $device').run({ device: deviceId });
	}

	/** The service said the device is gone. Only if it still holds that token: it may have registered a new one since. */
	forget(deviceId: string, token: string, kind: TokenKind): void {
		const sql =
			kind === 'alert'
				? `UPDATE push_tokens SET token = NULL, environment = NULL, status = 'unregistered', status_at = $at
					WHERE device_id = $device AND token = $token`
				: `UPDATE push_tokens SET voip_token = NULL, voip_environment = NULL, status_at = $at
					WHERE device_id = $device AND voip_token = $token`;
		this.db.query(sql).run({ device: deviceId, token, at: now() });
	}

	/** Every device of the conversation's other members. */
	forMessage(conversationId: string, authorId: string): PushDevice[] {
		return this.db
			.query<PushDevice, { conversation: string; author: string }>(`${LIVE_DEVICES} AND d.person_id != $author`)
			.all({ conversation: conversationId, author: authorId });
	}

	/**
	 * Whether this token is still held by a live recipient of the conversation: asked right before a queued push is sent,
	 * because since the audience was worked out the token may have moved to another device (a phone that changed hands), or
	 * its person, device, membership or room may have changed. A token belongs to one device, so the token is the device.
	 * `person` is the author (never a recipient) or the reader (the only one).
	 */
	stillReceives(token: string, conversationId: string, person: { author: string } | { reader: string }): boolean {
		const who = 'author' in person ? { op: '!=', id: person.author } : { op: '=', id: person.reader };
		const sql = `${LIVE_DEVICES} AND d.person_id ${who.op} $person AND t.token = $token`;
		return (
			this.db
				.query<unknown, { conversation: string; person: string; token: string }>(sql)
				.get({ conversation: conversationId, person: who.id, token }) !== null
		);
	}

	/** A reader's devices, if they can still see the conversation. */
	forReader(conversationId: string, readerId: string): PushDevice[] {
		return this.db
			.query<PushDevice, { conversation: string; reader: string }>(`${LIVE_DEVICES} AND d.person_id = $reader`)
			.all({ conversation: conversationId, reader: readerId });
	}

	/** The devices to ring of one person, if they can still see the conversation. */
	forRing(conversationId: string, personId: string): RingDevice[] {
		return this.db
			.query<RingDevice, { conversation: string; person: string }>(`${RING_DEVICES} AND d.person_id = $person`)
			.all({ conversation: conversationId, person: personId });
	}

	/**
	 * Whether a queued ring may still go out: this token is still held as the same kind, by a device whose person can still
	 * see the conversation. A token belongs to one device, so the token is the device. Asked right before sending, as
	 * `stillReceives` is for messages.
	 */
	stillRings(device: RingDevice, conversationId: string): boolean {
		const column = device.kind === 'voip' ? 't.voip_token' : 't.token';
		return (
			this.db
				.query<unknown, { conversation: string; token: string }>(`${RING_DEVICES} AND ${column} = $token`)
				.get({ conversation: conversationId, token: device.token }) !== null
		);
	}
}
