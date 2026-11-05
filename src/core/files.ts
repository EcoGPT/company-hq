import { closeSync, mkdirSync, mkdtempSync, openSync, readdirSync, readSync, renameSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';

const SAFE_PART = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

export class TooLarge extends Error {}

/** Uploaded bytes on disk, beside the database. Names are ids this server made, never user text. */
export class FileStore {
	private dir: string | null;

	/** With no directory (an in-memory database) files go to a temporary one, made on first use. */
	constructor(root: string | null) {
		this.dir = root;
	}

	path(...parts: string[]): string {
		for (const part of parts) if (!SAFE_PART.test(part)) throw new Error('unsafe file path');
		this.dir ??= mkdtempSync(join(tmpdir(), 'hq-files-'));
		return join(this.dir, ...parts);
	}

	/**
	 * Streams `body` to `path`, stopping at `max` bytes. Resolves to the size written; nothing is left behind on failure.
	 * `settle` runs the moment the finished file is in place, with nothing able to run in between.
	 */
	async save(path: string, body: ReadableStream<Uint8Array>, max: number, settle?: (path: string) => void): Promise<number> {
		mkdirSync(dirname(path), { recursive: true });
		const partial = `${path}.part`;
		const sink = Bun.file(partial).writer();
		let size = 0;
		try {
			const reader = body.getReader();
			for (let chunk = await reader.read(); !chunk.done; chunk = await reader.read()) {
				size += chunk.value.byteLength;
				if (size > max) {
					void reader.cancel();
					throw new TooLarge();
				}
				sink.write(chunk.value);
			}
			await sink.end();
		} catch (error) {
			try {
				await sink.end();
			} catch {
				// Already closed; the partial file goes either way.
			}
			rmSync(partial, { force: true });
			throw error;
		}
		if (size === 0) {
			rmSync(partial, { force: true });
			return 0;
		}
		renameSync(partial, path);
		settle?.(path);
		return size;
	}

	/** Deletes every other finished file in `path`'s folder: a replaced picture is not kept. An upload still arriving is left alone. */
	keepOnly(path: string): void {
		this.clear(dirname(path), basename(path));
	}

	/** The first `count` bytes of a file, read at once. */
	head(path: string, count: number): Uint8Array {
		const fd = openSync(path, 'r');
		try {
			const bytes = new Uint8Array(count);
			return bytes.subarray(0, readSync(fd, bytes, 0, count, 0));
		} finally {
			closeSync(fd);
		}
	}

	/** Deletes one file, if it is there. */
	remove(path: string): void {
		rmSync(path, { force: true });
	}

	/** Deletes every finished file in a folder. */
	empty(...parts: string[]): void {
		this.clear(this.path(...parts));
	}

	private clear(folder: string, except?: string): void {
		let names: string[];
		try {
			names = readdirSync(folder);
		} catch {
			return;
		}
		for (const name of names) if (name !== except && !name.endsWith('.part')) rmSync(join(folder, name), { force: true });
	}

	/** Drops a temporary directory; a configured one is never touched. */
	dispose(): void {
		if (this.dir !== null && this.dir.startsWith(join(tmpdir(), 'hq-files-'))) rmSync(this.dir, { recursive: true, force: true });
	}
}
