/**
 * At most `limit` admitted attempts per key in any `windowMs`. Refused attempts are not counted, so waiting always works.
 * The table is kept in order of last use, so making room only ever looks at the oldest entries and costs the same
 * at any size; it never holds more than `maxKeys` sources.
 */
export class RateLimiter {
	private readonly attempts = new Map<string, number[]>();

	constructor(
		private readonly limit: number,
		private readonly windowMs: number,
		private readonly clock: () => number = Date.now,
		private readonly maxKeys = 10_000,
	) {}

	get size(): number {
		return this.attempts.size;
	}

	/** 0 when admitted; otherwise the whole seconds until an attempt would be. */
	admit(key: string): number {
		const at = this.clock();
		const recent = (this.attempts.get(key) ?? []).filter((t) => t > at - this.windowMs);
		// Taken out and put back last, so the map stays ordered by when each source was last seen.
		this.attempts.delete(key);
		this.makeRoom(at);
		if (recent.length >= this.limit) {
			this.attempts.set(key, recent);
			return Math.max(1, Math.ceil((recent[0]! + this.windowMs - at) / 1000));
		}
		recent.push(at);
		this.attempts.set(key, recent);
		return 0;
	}

	/**
	 * Drops sources that have been quiet for a whole window, oldest first. A full table also drops its oldest tenth, so
	 * the clean-up happens once in a while rather than on every attempt.
	 */
	private makeRoom(at: number): void {
		const keep = this.attempts.size >= this.maxKeys ? Math.floor(this.maxKeys * 0.9) : this.maxKeys;
		for (const [key, times] of this.attempts) {
			if (this.attempts.size <= keep && times.at(-1)! > at - this.windowMs) return;
			this.attempts.delete(key);
		}
	}
}
