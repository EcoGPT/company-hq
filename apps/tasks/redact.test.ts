import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { PATTERNS, REDACTED, redactDeep, redactText } from './redact';

// The values are made up and built here so no real-looking key sits in the source.
const key43 = 'Ab1_-'.repeat(9).slice(0, 43);
const long = 'abcdefghijklmnopqrstuvwxyz0123456789';

// One row per pattern, in the list's order: something it must hide (and the part that must be gone), and something close
// to it that must come out unchanged.
const patterns: { name: string; hit: string; gone: RegExp; near: string }[] = [
	{
		name: 'a private key block',
		hit: '-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nabc/+=\n-----END RSA PRIVATE KEY-----',
		gone: /MIIEow|abc\/\+=/,
		near: '-----BEGIN PUBLIC KEY-----\nMIIEow\n-----END PUBLIC KEY-----',
	},
	{
		name: 'an unterminated private key',
		hit: '-----BEGIN PRIVATE KEY-----\nMIIEowIBAAKCAQEA7abc/+=\nxyz123',
		gone: /MIIEow|xyz123/,
		near: 'BEGIN PRIVATE KEY is how a block starts',
	},
	{ name: "this server's own key", hit: `hq_${key43}`, gone: /Ab1_-Ab1/, near: `hq_${key43.slice(0, 39)} and hq_short` },
	{ name: 'an sk- key', hit: `sk-${long}`, gone: /abcdefghijklmnop/, near: 'the task-abcdefghijklmnopqrstuvwxyz list and sk-1' },
	{ name: 'a GitHub token', hit: `ghp_${long}`, gone: /abcdefghijklmnop/, near: 'ghp_short' },
	{ name: 'an AWS access key id', hit: 'AKIAABCDEFGHIJKLMNOP', gone: /ABCDEFGHIJKLMNOP/, near: 'AKIA is a prefix' },
	{ name: 'a Bearer token', hit: `Bearer ${long}.0123`, gone: /abcdefghijklmnop/, near: 'Bearer is a word, and Bearer short' },
	{ name: 'a lowercase bearer token', hit: `bearer ${long}==`, gone: /abcdefghijklmnop/, near: 'bearer of bad news' },
	{
		name: 'a JWT',
		hit: 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r',
		gone: /dBjftJeZ|eyJzdWIi/,
		near: 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0',
	},
	{
		name: 'a JWT that starts mid-word',
		hit: 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r',
		gone: /dBjftJeZ|eyJzdWIi/,
		near: 'xeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r',
	},
	{ name: 'an api_key assignment', hit: 'api_key = "abcdefghijklmnop1234"', gone: /abcdefghijklmnop/, near: 'api_key = short' },
	{ name: 'a token pair', hit: 'MY_TOKEN: abcdefghijklmnopqrst', gone: /abcdefghijklmnop/, near: 'token = short' },
	{ name: 'a password pair', hit: 'db_password=correcthorsebatterystaple', gone: /correcthorse/, near: 'password=hunter2' },
	{
		name: 'a quoted secret key',
		hit: '"client-secret": "abcdefghijklmnopqrstuvwx"',
		gone: /abcdefghijklmnop/,
		near: 'the secret is in the vault',
	},
	{ name: 'a pscale token', hit: `pscale_tkn_${long}`, gone: /abcdefghijklmnop/, near: 'pscale_tkn_short' },
	{
		name: 'a live payment key',
		hit: 'sk_live_abcdefghijklmnopqrstuvwx',
		gone: /abcdefghijklmnop/,
		near: 'sk_test_abcdefghijklmnopqrstuvwx',
	},
	{
		name: 'a restricted payment key',
		hit: 'rk_live_abcdefghijklmnopqrstuvwx',
		gone: /abcdefghijklmnop/,
		near: 'rk_test_abcdefghijklmnopqrstuvwx',
	},
	{ name: 'a webhook secret', hit: 'whsec_abcdefghijklmnopqrstuvwx', gone: /abcdefghijklmnop/, near: 'whsec_short' },
	{ name: 'a Slack token', hit: 'xoxb-1234567890-abcdefghijklmnop', gone: /abcdefghijklmnop/, near: 'xoxo is a hug' },
	{ name: 'a Google API key', hit: 'AIzaSyAbcdefghijklmnopqrstuvwxyz01234', gone: /Abcdefghijklmnop/, near: 'AIza is a prefix' },
	{ name: 'an xai- key', hit: 'xai-abcdefghijklmnopqrstuvwxyz', gone: /abcdefghijklmnop/, near: 'xai-short' },
	{ name: 'a gsk_ key', hit: 'gsk_abcdefghijklmnopqrstuvwxyz', gone: /abcdefghijklmnop/, near: 'gsk_short' },
	{ name: 'a SendGrid key', hit: 'SG.abcdefghijklmnop.qrstuvwxyz0123', gone: /abcdefghijklmnop/, near: 'SG is two letters' },
	{
		name: 'an AWS STS key id',
		hit: 'ASIAABCDEFGHIJKLMNOP',
		gone: /ABCDEFGHIJKLMNOP/,
		near: 'ASIA is the continent. ASIAPACIFIC is not a key.',
	},
	{
		name: 'a Slack webhook',
		hit: 'https://hooks.slack.com/services/T0001/B0002/abcdefghijklmnop',
		gone: /abcdefghijklmnop/,
		near: 'https://hooks.slack.com/docs',
	},
	{
		name: 'an exported env secret',
		hit: 'export SERVICE_KEY="hunter2"',
		gone: /hunter2/,
		near: 'export PATH=/usr/bin and key = value',
	},
	{ name: 'a short env secret on a line', hit: 'API_TOKEN=abc', gone: /=abc/, near: 'cwd=/work PWD is the working directory' },
	{ name: 'MYSQL_PWD', hit: 'MYSQL_PWD=s3cret', gone: /s3cret/, near: 'MYSQL_HOST=localhost' },
	{
		name: 'a URL with a password',
		hit: 'postgres://admin:hunter2@db.example.test:5432/app',
		gone: /hunter2/,
		near: 'visit https://example.test:8080/path and ssh://git@example.test:org/repo.git',
	},
	{
		name: 'a Basic authorization header',
		hit: 'Authorization: Basic dXNlcjpwYXNz',
		gone: /dXNlcjpwYXNz/,
		near: 'The authorization flow is described in the docs.',
	},
	{
		name: 'a Cookie header',
		hit: 'Cookie: session=abc123; theme=dark',
		gone: /abc123/,
		near: 'The cookie banner is shown once.',
	},
	{ name: 'a Set-Cookie header', hit: 'set-cookie: sid=abc123; HttpOnly', gone: /abc123/, near: 'set the cookie later' },
	{
		name: 'curl -u',
		hit: 'curl -u admin:hunter2 https://example.test',
		gone: /hunter2/,
		near: 'curl -s https://example.test | jq .',
	},
	{
		name: 'curl --user',
		hit: 'curl --user admin:hunter2 https://example.test',
		gone: /hunter2/,
		near: 'curl --silent https://example.test',
	},
];

// The Mac helper's tests read the same file: what is expected here is what both sides must produce. A case runs through
// `redactText`, or, with `"mode": "json"`, through `redactDeep` on the string (the rule for a value under a secret-named key
// in JSON text).
type Case = { name: string; input: string; expected: string; mode?: 'json' };
const cases: Case[] = JSON.parse(readFileSync(join(import.meta.dir, '../../test/fixtures/redaction-cases.json'), 'utf8'));

describe('the shared redaction cases', () => {
	test.each(cases.map((c) => [c.name, c] as const))('%s', (_name, c) => {
		expect(c.mode === 'json' ? redactDeep(c.input) : redactText(c.input)).toBe(c.expected);
	});

	test('the file says what it means: a case that hides loses its fake, one that keeps changes nothing', () => {
		expect(new Set(cases.map((c) => c.name)).size).toBe(cases.length);
		expect(cases.filter((c) => c.name.startsWith('hides')).length).toBeGreaterThanOrEqual(40);
		expect(cases.filter((c) => c.name.startsWith('keeps')).length).toBeGreaterThanOrEqual(20);
		expect(cases.filter((c) => c.mode === 'json').length).toBeGreaterThanOrEqual(6);
		for (const c of cases) {
			if (c.name.startsWith('hides')) {
				expect([c.name, c.expected.includes(REDACTED), c.expected.includes('FAKEFAKE')]).toEqual([c.name, true, false]);
			}
			if (c.name.startsWith('keeps') && c.mode === undefined) expect(c.expected).toBe(c.input);
		}
	});

	test('it holds the cases where another script’s letters sit next to a key', () => {
		const text = cases.map((c) => c.input).join('\n');
		for (const lead of ['密钥sk-', 'トークンghp_', '令牌hq_', 'cléghp_']) expect(text).toContain(lead);
	});
});

describe('every repeat in every pattern has an upper bound', () => {
	// `*`, `+` and `{n,}` outside a character class and an escape.
	function unbounded(source: string): string[] {
		const found: string[] = [];
		let inClass = false;
		for (let i = 0; i < source.length; i++) {
			const ch = source[i]!;
			if (ch === '\\') i++;
			else if (inClass) inClass = ch !== ']';
			else if (ch === '[') inClass = true;
			else if (ch === '*' || ch === '+') found.push(ch);
			else if (ch === '{') {
				const repeat = /^\{\d+(,\d*)?\}/.exec(source.slice(i));
				if (repeat !== null && repeat[0].endsWith(',}')) found.push(repeat[0]);
			}
		}
		return found;
	}

	test('the checker sees an unbounded repeat', () => {
		expect(unbounded('a+b*[c+]{2,}\\+x{1,5}')).toEqual(['+', '*', '{2,}']);
	});

	test.each(PATTERNS.map((p, i) => [i + 1, p.source] as const))('pattern %i', (_n, source) => {
		expect(unbounded(source)).toEqual([]);
	});

	test('there are 13, and none uses \\b (a word boundary means different things to JavaScript and Swift)', () => {
		expect(PATTERNS).toHaveLength(13);
		for (const p of PATTERNS) expect(p.source).not.toContain('\\b');
	});
});

describe('redactText', () => {
	test.each(patterns)('hides $name', ({ hit, gone }) => {
		const out = redactText(`before ${hit} after`);
		expect(out).toContain(REDACTED);
		expect(out).not.toMatch(gone);
		expect(out.startsWith('before ')).toBe(true);
	});

	test.each(patterns)('leaves what is close to $name alone', ({ near }) => {
		expect(redactText(near)).toBe(near);
	});

	test('hides every occurrence, not just the first', () => {
		const key = `sk-${long}`;
		expect(redactText(`${key} and ${key}`)).toBe(`${REDACTED} and ${REDACTED}`);
	});

	test('a key block that is cut off is hidden up to the next block, and the next block is hidden too', () => {
		const cut = '-----BEGIN PRIVATE KEY-----\nAAAAAAAA!\n';
		const whole = '-----BEGIN PRIVATE KEY-----\nBBBBBBBB\n-----END PRIVATE KEY-----';
		// The search for END stops at the next BEGIN: the "!" after the first block is not swallowed with the second.
		expect(redactText(`before ${cut}${whole} after`)).toBe(`before ${REDACTED}!\n${REDACTED} after`);
		expect(redactText(`${whole} and ${whole}`)).toBe(`${REDACTED} and ${REDACTED}`);
	});

	test('a JWT is found only at the start of a token run', () => {
		const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r';
		for (const before of [' ', '\n', '"', '=', ':', '(']) expect(redactText(`a${before}${jwt}`)).toBe(`a${before}${REDACTED}`);
		for (const before of ['x', '9', '_', '-']) expect(redactText(`a${before}${jwt}`)).toBe(`a${before}${jwt}`);
	});

	test('keeps the host when it hides a URL password', () => {
		expect(redactText('mysql://u:pw@host.example.test/db')).toBe(`${REDACTED}host.example.test/db`);
	});

	test('leaves ordinary text, short values and code alone', () => {
		for (const text of [
			'Can we ship the new contract? 🌳',
			'git push origin fix-login',
			'const skip = skills.filter(Boolean)',
			'The task-id is sk-1 and the key is documented in docs.',
		])
			expect(redactText(text)).toBe(text);
	});

	test('is the same call on the same input every time (the patterns keep no state)', () => {
		const text = `a ${`ghp_${long}`} b`;
		expect(redactText(text)).toBe(redactText(text));
	});
});

// The patterns run on every other member's read, on the one thread that serves everyone, over text up to 500,000
// characters. A run that fails to match must not be rescanned from every start point inside it. Each of the 13 patterns has
// input built to make it do that: the marker it starts on, repeated, or a near-miss repeated, or one long run. Every
// input is at least 500,000 characters and must finish within one second.
const BUDGET_MS = 1000;
const SIZE = 500_000;
const fill = (unit: string) => unit.repeat(Math.ceil(SIZE / unit.length));
const adversarial: { pattern: number; name: string; text: string }[] = [
	{
		pattern: 1,
		name: 'a key header, then one long run of other characters',
		text: '-----BEGIN PRIVATE KEY-----' + '!'.repeat(SIZE),
	},
	{ pattern: 1, name: 'a key header and "!", repeated', text: fill('-----BEGIN PRIVATE KEY-----!') },
	{ pattern: 1, name: 'a header with a long name', text: '-----BEGIN ' + 'A'.repeat(SIZE) },
	{ pattern: 1, name: 'headers with no end', text: fill('-----BEGIN PRIVATE KEY-----') },
	{ pattern: 2, name: 'hq_ and one character short of a key, repeated', text: fill('hq_' + 'a'.repeat(39) + '!') },
	{ pattern: 2, name: 'hq_ then one long run', text: 'hq_' + 'a'.repeat(SIZE) },
	{ pattern: 3, name: 'sk- repeated', text: fill('sk-') },
	{ pattern: 3, name: 'sk- and one character short, repeated', text: fill('sk-' + 'a'.repeat(15) + '!') },
	{ pattern: 4, name: 'Bearer and a space, repeated', text: fill('Bearer ') },
	{ pattern: 4, name: 'Bearer then one long run of spaces', text: 'Bearer' + ' '.repeat(SIZE) },
	{ pattern: 4, name: 'Bearer and a short token, repeated', text: fill('Bearer abcdefgh!') },
	{ pattern: 5, name: 'eyJ- repeated', text: fill('eyJ-') },
	{ pattern: 5, name: 'eyJ, eight characters and a dot, repeated', text: fill('eyJaaaaaaaa.aaaaaaaa.') },
	{ pattern: 5, name: 'eyJ then one long run', text: 'eyJ' + 'a'.repeat(SIZE) },
	{ pattern: 5, name: 'a JWT header and one long middle with no second dot', text: 'eyJaaaaaaaa.' + 'b'.repeat(SIZE) },
	{ pattern: 5, name: 'a JWT header, a middle, and one long signature', text: 'eyJaaaaaaaa.bbbbbbbb.' + 'c'.repeat(SIZE) },
	{ pattern: 5, name: 'blocks of 128 eyJ- ending in a dot', text: fill('eyJ-'.repeat(128) + '.') },
	{
		pattern: 5,
		name: 'a header, a dot and a long run, then a hyphen, repeated',
		text: fill('eyJaaaaaaaa.' + 'b'.repeat(2000) + '-'),
	},
	{ pattern: 6, name: 'a keyword then one long run of spaces', text: 'token' + ' '.repeat(SIZE) },
	{ pattern: 6, name: 'a keyword and a value one character short, repeated', text: fill('token=' + 'a'.repeat(15) + '!') },
	{ pattern: 6, name: 'keywords joined by hyphens', text: fill('password-') },
	{ pattern: 7, name: 'a vendor prefix and one character short, repeated', text: fill('pscale_pw_' + 'a'.repeat(15) + '!') },
	{ pattern: 7, name: 'gsk_ repeated', text: fill('gsk_') },
	{ pattern: 8, name: 'ASIA and fifteen letters, repeated', text: fill('ASIA' + 'A'.repeat(15) + '!') },
	{ pattern: 8, name: 'ASIA then one long run', text: 'ASIA' + 'A'.repeat(SIZE) },
	{
		pattern: 9,
		name: 'a webhook address one character short, repeated',
		text: fill('hooks.slack.com/services/' + 'a'.repeat(15) + '!'),
	},
	{ pattern: 9, name: 'a webhook address then one long run', text: 'hooks.slack.com/services/' + 'a'.repeat(SIZE) },
	{ pattern: 10, name: 'KEY repeated', text: fill('KEY') },
	{ pattern: 10, name: 'an env name and "= " , repeated', text: fill('X_KEY= ') },
	{ pattern: 10, name: 'a long upper-case name', text: 'A'.repeat(SIZE) },
	{ pattern: 11, name: 'a://b: repeated', text: fill('a://b:') },
	{ pattern: 11, name: 'a scheme and one long user name', text: 'a://' + 'b'.repeat(SIZE) },
	{ pattern: 11, name: 'a user and one long password with no @', text: 'a://b:' + 'c'.repeat(SIZE) },
	{ pattern: 11, name: '://a: repeated', text: fill('://a:') },
	{ pattern: 12, name: 'cookie then one long run of spaces', text: 'cookie:' + ' '.repeat(SIZE) },
	{ pattern: 12, name: 'cookie: and a quote, repeated', text: fill('cookie: "') },
	{ pattern: 12, name: 'cookie names with no colon', text: fill('cookie ') },
	{ pattern: 13, name: '-u and a space, repeated', text: fill('-u ') },
	{ pattern: 13, name: '-u and one long run with no colon', text: '-u ' + 'a'.repeat(SIZE) },
	{ pattern: 13, name: '-u then one long run of spaces', text: '-u' + ' '.repeat(SIZE) },
	{ pattern: 13, name: 'curl repeated', text: fill('curl ') },
];

describe('redactText stays fast on hostile input', () => {
	test('every one of the 13 patterns has input built against it', () => {
		for (let n = 1; n <= 13; n++) expect(adversarial.some((a) => a.pattern === n)).toBe(true);
		for (const { name, text } of adversarial) expect([name, text.length >= SIZE]).toEqual([name, true]);
	});

	test.each(adversarial.map((a) => [`pattern ${a.pattern}: ${a.name}`, a.text] as const))(
		'finishes in time on %s',
		(_name, text) => {
			const started = performance.now();
			redactText(text);
			expect(performance.now() - started).toBeLessThan(BUDGET_MS);
		},
	);

	test.each([
		['a hyphen-joined run', 'a-'.repeat(250_000)],
		['a base64url blob', 'Ab1_'.repeat(125_000)],
		['hyphenated ids', '123a4567-a89b-12d3-a456-426614174000-'.repeat(13_500)],
		['blank lines', '\n'.repeat(SIZE)],
		['ordinary prose', 'plain words go here. '.repeat(25_000)],
	])('finishes in time on %s', (_name, text) => {
		const started = performance.now();
		redactText(text);
		expect(performance.now() - started).toBeLessThan(BUDGET_MS);
	});

	// Where a repeat has a bound, a run longer than it is hidden up to the bound and no further. (Timing cannot show that
	// these bounds exist: a match that succeeds consumes its run, so those patterns were never quadratic. The bound is what
	// keeps one match from swallowing the rest of a 500,000-character message.)
	test.each([
		[2, 'hq_', 16384, 'a'],
		[3, 'sk-', 16384, 'a'],
		[4, 'Bearer ', 16384, 'a'],
		[6, 'token=', 16384, 'a'],
		[7, 'gsk_', 16384, 'a'],
		[9, 'hooks.slack.com/services/', 512, 'a'],
		[10, 'X_KEY=', 16384, 'a'],
		[12, 'cookie: ', 16384, 'a'],
		[13, '-u me:', 1024, 'a'],
	])('pattern %i: a run past its bound is cut there (%s then %i)', (_n, lead, bound, ch) => {
		const out = redactText(lead + ch.repeat(bound + 10));
		expect(out).toBe(REDACTED + ch.repeat(10));
	});

	test('pattern 1: a key name of 40 letters and a body of 16,384 characters are hidden; one more of either is not all hidden', () => {
		const block = (name: string, body: string) => `-----BEGIN ${name}PRIVATE KEY-----\n${body}\n-----END ${name}PRIVATE KEY-----`;
		expect(redactText(block('A'.repeat(39) + ' ', 'x'))).toBe(REDACTED);
		const longName = block('A'.repeat(41) + ' ', 'x');
		expect(redactText(longName)).toBe(longName);
		expect(redactText(block('', 'x'.repeat(16_000)))).toBe(REDACTED);
		// The newline is the first of the 16,384 characters the body may take.
		const cut = `-----BEGIN PRIVATE KEY-----\n${'M'.repeat(16_383)}${'N'.repeat(10)}`;
		expect(redactText(cut)).toBe(`${REDACTED}${'N'.repeat(10)}`);
	});

	test('pattern 5: each JWT segment is hidden up to its bound and not past it', () => {
		const jwt = (a: number, b: number, c: number) => `eyJ${'a'.repeat(a)}.${'b'.repeat(b)}.${'c'.repeat(c)}`;
		for (const [a, b, c] of [
			[512, 16_384, 16_384],
			[8, 5000, 8],
			[8, 8, 10_000],
			[8, 8, 8],
		] as const) {
			expect(redactText(jwt(a, b, c))).toBe(REDACTED);
		}
		// A header or a middle past its bound is no JWT at all. A signature past its bound is hidden up to the bound: no
		// lookahead after it, so it never makes a long token fail outright.
		for (const [a, b] of [
			[513, 20],
			[20, 16_385],
		] as const) {
			expect(redactText(jwt(a, b, 20))).toBe(jwt(a, b, 20));
		}
		expect(redactText(jwt(20, 20, 16_395))).toBe(REDACTED + 'c'.repeat(11));
	});

	// Known gap, on purpose: a JWT right after a hyphen (token-eyJ...) is not found. Allowing it makes `eyJ-` repeated 500,000
	// characters take about 0.5 s here (14 ms without), and the helper's regex engine was several seconds on that input.
	test('a JWT right after a hyphen is not found (a documented gap)', () => {
		const jwt = 'eyJFAKEFAKE.FAKEFAKE.FAKEFAKE';
		expect(redactText(`token-${jwt}`)).toBe(`token-${jwt}`);
		expect(redactText(`id=my-${jwt}`)).toBe(`id=my-${jwt}`);
	});

	test('pattern 11: a password or user name past its bound is not taken for one', () => {
		expect(redactText(`a://u:${'p'.repeat(1025)}@h`)).toBe(`a://u:${'p'.repeat(1025)}@h`);
		expect(redactText(`a://${'u'.repeat(257)}:p@h`)).toBe(`a://${'u'.repeat(257)}:p@h`);
		expect(redactText(`a://${'u'.repeat(256)}:${'p'.repeat(1024)}@h`)).toBe(`${REDACTED}h`);
	});

	test('the bounds still hide a real credential of any usual size', () => {
		const jwt = `eyJ${'a'.repeat(300)}.${'b'.repeat(2000)}.${'c'.repeat(600)}`;
		expect(redactText(`x ${jwt} y`)).toBe(`x ${REDACTED} y`);
		const key = `-----BEGIN RSA PRIVATE KEY-----\n${'MIIEowIBAAKCAQEA'.repeat(500)}\n-----END RSA PRIVATE KEY-----`;
		expect(redactText(`x ${key} y`)).toBe(`x ${REDACTED} y`);
		expect(redactText(`curl -u admin:${'p'.repeat(900)} z`)).toBe(`curl ${REDACTED} z`);
	});
});

describe('redactDeep', () => {
	test('walks objects and lists and drops values under secret-named keys', () => {
		const out = redactDeep({
			title: `Deploy with ghp_${long}`,
			messages: [{ id: 'm1', text: 'ok', authorization: 'anything at all', Cookie: 'a=b' }],
			count: 3,
			ok: true,
			none: null,
		});
		expect(out).toEqual({
			title: `Deploy with ${REDACTED}`,
			messages: [{ id: 'm1', text: 'ok', authorization: REDACTED, Cookie: REDACTED }],
			count: 3,
			ok: true,
			none: null,
		});
	});

	test('looks inside a string that is itself JSON', () => {
		const input = JSON.stringify({ command: 'ls', env: { API_KEY: 'x', PATH: '/bin' } });
		const out = redactDeep({ input }) as { input: string };
		expect(JSON.parse(out.input)).toEqual({ command: 'ls', env: { API_KEY: REDACTED, PATH: '/bin' } });
	});

	test('keeps the exact text of a JSON string with nothing to hide', () => {
		const input = '{ "command" : "ls",   "cwd": "/work" }';
		expect(redactDeep({ input })).toEqual({ input });
	});

	test('still applies the text patterns to JSON cut off mid-value', () => {
		const clipped = '{"api_key":"abcdefghijklmnopqrstuvwxyz0123456';
		expect(redactDeep({ output: clipped })).toEqual({ output: `{"${REDACTED}` });
	});

	test('does not change what it is given', () => {
		const original = { text: `sk-${long}` };
		redactDeep(original);
		expect(original.text).toContain('sk-abc');
	});
});
