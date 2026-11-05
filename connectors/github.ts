import { connectorTool, defineConnector, readJson, ToolError, z } from '@hq/sdk';

const repo = z
	.string()
	.regex(/^[\w.-]+\/[\w.-]+$/, 'owner/name')
	.refine((value) => !value.split('/').some((part) => /^\.+$/.test(part)), 'owner/name');

const filePath = z
	.string()
	.min(1)
	.refine((value) => !value.split('/').some((part) => part === '.' || part === '..'), 'no . or .. segments');

const api = 'https://api.github.com';

const request = (fetch: typeof globalThis.fetch, secret: string, url: string) =>
	fetch(url, {
		headers: { authorization: `Bearer ${secret}`, accept: 'application/vnd.github+json', 'x-github-api-version': '2022-11-28' },
	});

const gh = (fetch: typeof globalThis.fetch, secret: string, path: string) =>
	request(fetch, secret, `${api}${path}`).then((r) => readJson(r, 'GitHub'));

const nextPage = (response: Response) => {
	const next = response.headers.get('link')?.match(/<([^>]+)>;\s*rel="next"/)?.[1];
	return next?.startsWith(`${api}/`) ? next : undefined;
};

export default defineConnector({
	slug: 'github',
	name: 'GitHub',
	description: 'Read issues, pull requests and files.',
	secretHelp: 'A fine-grained personal access token with read access to the repos you want.',
	async verify(secret, fetch) {
		const response = await request(fetch, secret, `${api}/user`);
		if (response.status === 401) throw new ToolError('GitHub rejected the token (401 Bad credentials)');
		if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
	},
	tools: [
		connectorTool({
			name: 'github_list_issues',
			description: 'List issues or pull requests in a repository.',
			input: z.object({
				repo,
				kind: z.enum(['issues', 'pulls']).default('issues'),
				state: z.enum(['open', 'closed', 'all']).default('open'),
				limit: z.number().int().min(1).max(500).default(30),
			}),
			activity: 'Reading GitHub',
			async run({ repo, kind, state, limit }, { fetch, secret }) {
				const items: {
					number: number;
					title: string;
					state: string;
					user?: { login: string };
					html_url: string;
					pull_request?: unknown;
					merged_at?: string | null;
				}[] = [];
				let url: string | undefined = `${api}/repos/${repo}/${kind}?state=${state}&per_page=${Math.min(limit, 100)}`;
				for (let pages = 0; url && items.length < limit && pages < 10; pages++) {
					const response = await request(fetch, secret, url);
					const page = (await readJson(response, 'GitHub')) as typeof items;
					items.push(...page.filter((item) => kind === 'pulls' || item.pull_request === undefined));
					url = nextPage(response);
				}
				return items.slice(0, limit).map((item) => ({
					number: item.number,
					title: item.title,
					state: item.merged_at ? 'merged' : item.state,
					by: item.user?.login,
					url: item.html_url,
				}));
			},
		}),
		connectorTool({
			name: 'github_read_file',
			description: 'Read a file from a repository.',
			input: z.object({ repo, path: filePath, ref: z.string().optional() }),
			activity: 'Reading a file on GitHub',
			async run({ repo, path, ref }, { fetch, secret }) {
				const file = (await gh(
					fetch,
					secret,
					`/repos/${repo}/contents/${path.split('/').filter(Boolean).map(encodeURIComponent).join('/')}${ref ? `?ref=${encodeURIComponent(ref)}` : ''}`,
				)) as { content?: string; encoding?: string; size?: number } | { name: string; type: string; path: string }[];
				if (Array.isArray(file)) return file.map(({ name, type, path }) => ({ name, type, path }));
				if (file.content === undefined || file.encoding !== 'base64') return file;
				return Buffer.from(file.content, 'base64').toString('utf8');
			},
		}),
	],
});
