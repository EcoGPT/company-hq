// Secret-looking strings are hidden from everyone but a session's owner. The Mac helper hides the same patterns before it
// uploads, and the server applies them again on every other member's read. This is best effort: no list of patterns
// catches every secret, and the person running the server reads what was stored (see SECURITY.md).

export const REDACTED = '[REDACTED]';

// The same patterns, in the same order, as the helper's. Each one runs over text up to 500,000 characters on the one thread
// that serves everyone, so every repeat has an upper bound: an unbounded run that fails to match is rescanned from every start
// point inside it, which is quadratic (`eyJ-` repeated took 50 seconds). The bounds are far above any real credential.
export const PATTERNS: readonly RegExp[] = [
	// A private key block, or an unterminated one (clipped, or no END line) that loses the base64 body after its header, up
	// to 16 KiB. The search for END stops at the next BEGIN, so a header is never rescanned through every later one.
	/-----BEGIN [A-Z ]{0,40}PRIVATE KEY(?: BLOCK)?-----(?:(?:(?!-----BEGIN)[\s\S]){0,16384}?-----END [A-Z ]{0,40}PRIVATE KEY(?: BLOCK)?-----|[A-Za-z0-9+/=:\s,.-]{0,16384})/g,
	// This server's own keys: `hq_` and 43 base64url characters.
	/(?<![A-Za-z0-9_])hq_[A-Za-z0-9_-]{40,16384}/g,
	/(?<![A-Za-z0-9_])(?:sk-(?:proj-|ant-)?|gh[pousr]_|github_pat_|AKIA)[A-Za-z0-9_-]{16,16384}/g,
	/(?<![A-Za-z0-9_])Bearer\s{1,16}[A-Za-z0-9._~+/-]{16,16384}={0,16}/gi,
	/(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,512}\.[A-Za-z0-9_-]{8,16384}\.[A-Za-z0-9_-]{8,16384}/g,
	// Anchored on the keyword: a variable-length name before it would make every start point in a long run rescan the run.
	/(?:api[_-]?key|(?:secret|private)[_-]?(?:access[_-]?)?key|token|secret|password|passwd|passphrase)(?![A-Za-z0-9_])["']?\s{0,8}[:=]\s{0,8}["']?[A-Za-z0-9_./+~=-]{16,16384}/gi,
	// Other vendors' key prefixes.
	/(?<![A-Za-z0-9_])(?:pscale_(?:tkn|pw)_|[sr]k_live_|whsec_|xox[abposr]-|AIza|xai-|gsk_|SG\.)[A-Za-z0-9._-]{16,16384}/g,
	/(?<![A-Za-z0-9_])ASIA[A-Z0-9]{16}(?![A-Za-z0-9_])/g,
	/(?<![A-Za-z0-9_])hooks\.slack\.com\/services\/[A-Za-z0-9/]{16,512}/g,
	// Env-style lines (`cat .dev.vars`, `export X_KEY=...`): any value, however short, under an upper-case name that holds a
	// secret word.
	/(?<![A-Za-z0-9_])[A-Z0-9_]{0,64}(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|CREDENTIALS?|_PWD)[A-Z0-9_]{0,64}[ \t]{0,8}=[ \t]{0,8}["']?[^\s"']{1,16384}/g,
	// scheme://user:password@host
	/(?<![A-Za-z0-9_])[a-z][a-z0-9+.-]{0,31}:\/\/[^\s:/@]{1,256}:[^\s@/]{1,1024}@/gi,
	// Credential-carrying headers and curl's -u.
	/(?<![A-Za-z0-9_])(?:authorization|cookie|set-cookie)[ \t]{0,8}:[ \t]{0,8}[^\r\n"']{1,16384}/gi,
	/(?<!\S)(?:-u|--user)[ \t]{1,8}[^\s:]{1,256}:\S{1,1024}/g,
];

// A value under a key with one of these words is dropped whole.
const SECRET_KEY = /(api[_-]?key|token|secret|password|authorization|cookie|private[_-]?key)/i;

/** Replaces the credential-shaped parts of one string. */
export function redactText(input: string): string {
	let text = input;
	for (const pattern of PATTERNS) text = text.replace(pattern, REDACTED);
	return text;
}

function redactTree(value: unknown): unknown {
	if (Array.isArray(value)) return value.map(redactTree);
	if (value !== null && typeof value === 'object') {
		const safe: Record<string, unknown> = {};
		for (const [key, child] of Object.entries(value)) safe[key] = SECRET_KEY.test(key) ? REDACTED : redactTree(child);
		return safe;
	}
	return value;
}

// A string that is itself a JSON object or array (a tool's input or result) is checked for secret-named keys too. It is
// rewritten only when a key was hidden, so ordinary text keeps its exact formatting.
function redactString(input: string): string {
	const first = input.trimStart()[0];
	if (first === '{' || first === '[') {
		try {
			const parsed: unknown = JSON.parse(input);
			if (parsed !== null && typeof parsed === 'object') {
				const cleaned = JSON.stringify(redactTree(parsed));
				if (cleaned !== JSON.stringify(parsed)) return redactText(cleaned);
			}
		} catch {
			// Not JSON, or cut off mid-value: the text patterns still apply.
		}
	}
	return redactText(input);
}

function walk(value: unknown): unknown {
	if (typeof value === 'string') return redactString(value);
	if (Array.isArray(value)) return value.map(walk);
	if (value !== null && typeof value === 'object') {
		const safe: Record<string, unknown> = {};
		for (const [key, child] of Object.entries(value)) safe[key] = SECRET_KEY.test(key) ? REDACTED : walk(child);
		return safe;
	}
	return value;
}

/** Every string in a JSON value, and every value under a secret-named key, as a member other than the owner may read it. */
export function redactDeep<T>(value: T): T {
	return walk(value) as T;
}
