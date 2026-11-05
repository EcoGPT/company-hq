import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export type WireFixture = {
	structs: Record<string, Record<string, { required: boolean; of?: string; list?: boolean }>>;
	frames: Record<string, string>;
	ignored: Record<string, string[]>;
};

/** One fixture file. A feature's own also says, in `sent_by`, which test file sends each of its frames. */
export type FixturePart = { file: string; fixture: Partial<WireFixture> & { sent_by?: Record<string, string> } };

const SECTIONS = ['structs', 'frames', 'ignored'] as const;

/** The parts side by side. A name two parts both define is an error, so a later file can never quietly change an earlier one. */
export function mergeWire(parts: FixturePart[]): WireFixture {
	const merged: WireFixture = { structs: {}, frames: {}, ignored: {} };
	for (const { file, fixture } of parts) {
		for (const section of SECTIONS) {
			for (const [name, value] of Object.entries(fixture[section] ?? {})) {
				if (name in merged[section]) throw new Error(`${file}: ${section}.${name} is already defined`);
				Object.assign(merged[section], { [name]: value });
			}
		}
	}
	return merged;
}

const DIR = join(import.meta.dir, 'fixtures');
const read = (file: string): FixturePart['fixture'] => JSON.parse(readFileSync(join(DIR, file), 'utf8'));
const BASE = 'swift-wire.json';

/** What the app decodes: `swift-wire.json`, then every `swift-wire.<lane>.json` beside it, so each feature adds its own file. */
const extras = readdirSync(DIR)
	.filter((file) => /^swift-wire\..+\.json$/.test(file))
	.sort();
export const extraParts: FixturePart[] = extras.map((file) => ({ file, fixture: read(file) }));
export const wire = mergeWire([{ file: BASE, fixture: read(BASE) }, ...extraParts]);

/** The frames in `swift-wire.json` itself: the socket test must see every one. */
export const baseFrames = Object.keys(read(BASE).frames ?? {});
/** The frames in the feature files: their own tests send them. */
export const extraFrames = new Set(extraParts.flatMap(({ fixture }) => Object.keys(fixture.frames ?? {})));

const readRepoFile = (path: string): string | null => {
	try {
		return readFileSync(join(import.meta.dir, '..', path), 'utf8');
	} catch {
		return null;
	}
};

/**
 * `file: frame` for each frame in a feature's fixture file that no test is shown to send: `sent_by` must name a `.test.ts`
 * file that exists and has the frame's type in quotes. A frame the fixture describes but nothing sends is a frame nothing
 * has checked against the app's decoder.
 */
export function unsentFrames(parts: FixturePart[] = extraParts, read: (path: string) => string | null = readRepoFile): string[] {
	return parts.flatMap(({ file, fixture }) =>
		Object.keys(fixture.frames ?? {})
			.filter((frame) => {
				const test = fixture.sent_by?.[frame];
				const text = test?.endsWith('.test.ts') ? read(test) : null;
				return text === null || ![`'${frame}'`, `"${frame}"`, `\`${frame}\``].some((quoted) => text.includes(quoted));
			})
			.map((frame) => `${file}: ${frame}`),
	);
}
