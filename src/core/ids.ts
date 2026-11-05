let lastMs = 0;
let sequence = 0;

const hex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');

/**
 * A uuidv7 that sorts as a string in the order it was made, including within
 * one millisecond (a 12-bit counter follows the timestamp) and when the clock
 * steps back. Clients compare ids as plain strings to find the newest message.
 */
export function newId(): string {
	const random = crypto.getRandomValues(new Uint8Array(10));
	let ms = Date.now();
	if (ms > lastMs) {
		// Start the counter low so a busy millisecond has room to count up.
		sequence = ((random[0]! << 8) | random[1]!) & 0x1ff;
	} else {
		ms = lastMs;
		sequence += 1;
		if (sequence > 0xfff) {
			ms += 1;
			sequence = 0;
		}
	}
	lastMs = ms;
	const bytes = new Uint8Array(16);
	new DataView(bytes.buffer).setBigUint64(0, BigInt(ms) << 16n);
	bytes[6] = 0x70 | (sequence >> 8);
	bytes[7] = sequence & 0xff;
	bytes[8] = 0x80 | (random[2]! & 0x3f);
	bytes.set(random.subarray(3), 9);
	const text = hex(bytes);
	return `${text.slice(0, 8)}-${text.slice(8, 12)}-${text.slice(12, 16)}-${text.slice(16, 20)}-${text.slice(20)}`;
}

export function now(): number {
	return Date.now();
}
