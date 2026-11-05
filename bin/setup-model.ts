export type ModelChoice = {
	HQ_LLM_PROVIDER?: string;
	HQ_LLM_BASE_URL?: string;
	HQ_LLM_API_KEY?: string;
	HQ_LLM_MODEL?: string;
};

export function upsertEnv(text: string, values: Record<string, string | undefined>): string {
	let out = text;
	for (const [key, value] of Object.entries(values)) {
		if (value === undefined || value === '') continue;
		const line = `${key}=${value}`;
		const pattern = new RegExp(`^#?[ \\t]*${key}=.*$`, 'm');
		out = pattern.test(out) ? out.replace(pattern, () => line) : `${out.replace(/\n*$/, '\n')}${line}\n`;
	}
	return out;
}

export async function ollamaModels(base = 'http://localhost:11434', fetchImpl: typeof fetch = fetch): Promise<string[] | null> {
	try {
		const response = await fetchImpl(`${base}/api/tags`, { signal: AbortSignal.timeout(800) });
		if (!response.ok) return null;
		const body = (await response.json()) as { models?: { name: string }[] };
		return (body.models ?? []).map((m) => m.name);
	} catch {
		return null;
	}
}

export function choiceFromFlags(
	flag: (name: string) => string | undefined,
	env: Record<string, string | undefined> = process.env,
): ModelChoice | null {
	const provider = flag('provider');
	const model = flag('model');
	if (provider === undefined && model === undefined) return null;
	if (model === undefined || model === '') throw new Error('Pass --model as well, e.g. --provider ollama --model qwen3:14b.');
	if (provider === 'anthropic') {
		if (!flag('api-key') && !env.HQ_LLM_API_KEY) throw new Error('--provider anthropic needs --api-key.');
		return { HQ_LLM_PROVIDER: 'anthropic', HQ_LLM_API_KEY: flag('api-key'), HQ_LLM_MODEL: model };
	}
	if (provider === 'ollama') {
		return { HQ_LLM_BASE_URL: 'http://localhost:11434/v1', HQ_LLM_MODEL: model };
	}
	if (!flag('base-url') && !env.HQ_LLM_BASE_URL && !env.HQ_LLM_PROVIDER) {
		throw new Error('Pass --base-url for an OpenAI-compatible API, or --provider ollama|anthropic.');
	}
	return { HQ_LLM_BASE_URL: flag('base-url'), HQ_LLM_API_KEY: flag('api-key'), HQ_LLM_MODEL: model };
}

type Ask = (question: string) => string | null;

export async function chooseModel(ask: Ask, say: (line: string) => void, ollama: string[] | null): Promise<ModelChoice | null> {
	say('\nWhich model should the assistant use?');
	const options: { label: string; pick(): ModelChoice | null }[] = [];
	if (ollama !== null && ollama.length > 0) {
		options.push({
			label: `Ollama on this machine (${ollama.length} model${ollama.length === 1 ? '' : 's'} found)`,
			pick: () => {
				ollama.forEach((name, i) => say(`    ${i + 1}) ${name}`));
				const n = Number(ask(`  Model [1-${ollama.length}]:`) ?? '1');
				const model = ollama[(Number.isInteger(n) && n >= 1 && n <= ollama.length ? n : 1) - 1];
				return { HQ_LLM_BASE_URL: 'http://localhost:11434/v1', HQ_LLM_MODEL: model };
			},
		});
	}
	options.push({
		label: 'An OpenAI-compatible API (OpenAI, Groq, Together, Mistral, a vLLM server…)',
		pick: () => ({
			HQ_LLM_BASE_URL: ask('  Base URL [https://api.openai.com/v1]:') || 'https://api.openai.com/v1',
			HQ_LLM_API_KEY: ask('  API key:') ?? undefined,
			HQ_LLM_MODEL: ask('  Model name:') ?? undefined,
		}),
	});
	options.push({
		label: 'Anthropic',
		pick: () => ({
			HQ_LLM_PROVIDER: 'anthropic',
			HQ_LLM_API_KEY: ask('  API key:') ?? undefined,
			HQ_LLM_MODEL: ask('  Model id:') ?? undefined,
		}),
	});
	options.push({ label: 'Skip for now (an offline echo model stands in)', pick: () => null });
	options.forEach((o, i) => say(`  ${i + 1}) ${o.label}`));
	const n = Number(ask(`Choose [1-${options.length}]:`) ?? '1');
	const chosen = options[(Number.isInteger(n) && n >= 1 && n <= options.length ? n : 1) - 1]!;
	const choice = chosen.pick();
	if (choice !== null && (choice.HQ_LLM_MODEL === undefined || choice.HQ_LLM_MODEL === '')) {
		say('  No model name given, so nothing was saved. Set HQ_LLM_MODEL in .env later.');
		return null;
	}
	return choice;
}
