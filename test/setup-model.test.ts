import { describe, expect, test } from 'bun:test';
import { choiceFromFlags, chooseModel, ollamaModels, upsertEnv } from '../bin/setup-model';

describe('upsertEnv', () => {
	test('uncomments, replaces or appends, and skips blanks', () => {
		const env = '# HQ_LLM_MODEL=old\nPORT=8787\nHQ_LLM_BASE_URL=x';
		expect(upsertEnv(env, { HQ_LLM_MODEL: 'qwen3:14b', HQ_LLM_BASE_URL: 'http://y', HQ_LLM_API_KEY: '', NEW: 'v' })).toBe(
			'HQ_LLM_MODEL=qwen3:14b\nPORT=8787\nHQ_LLM_BASE_URL=http://y\nNEW=v\n',
		);
	});

	test('keeps $ in values and the blank lines around them', () => {
		expect(upsertEnv('A=1\n\n# HQ_LLM_API_KEY=\n', { HQ_LLM_API_KEY: "pa$'ss$&w$1" })).toBe(
			"A=1\n\nHQ_LLM_API_KEY=pa$'ss$&w$1\n",
		);
	});
});

describe('choosing a model', () => {
	test('flags win and need no prompt', () => {
		const flags = (v: Record<string, string>) => (name: string) => v[name];
		expect(choiceFromFlags(flags({}))).toBeNull();
		expect(choiceFromFlags(flags({ provider: 'ollama', model: 'qwen3:14b' }))).toEqual({
			HQ_LLM_BASE_URL: 'http://localhost:11434/v1',
			HQ_LLM_MODEL: 'qwen3:14b',
		});
		expect(choiceFromFlags(flags({ provider: 'anthropic', model: 'm', 'api-key': 'k' }))).toEqual({
			HQ_LLM_PROVIDER: 'anthropic',
			HQ_LLM_API_KEY: 'k',
			HQ_LLM_MODEL: 'm',
		});
	});

	test('flags that would save a model HQ cannot run are refused', () => {
		const flags = (v: Record<string, string>) => (name: string) => v[name];
		expect(() => choiceFromFlags(flags({ provider: 'ollama' }), {})).toThrow('Pass --model');
		expect(() => choiceFromFlags(flags({ provider: 'anthropic', model: 'm' }), {})).toThrow('needs --api-key');
		expect(() => choiceFromFlags(flags({ model: 'gpt-5-mini' }), {})).toThrow('Pass --base-url');
		expect(choiceFromFlags(flags({ model: 'gpt-5-mini' }), { HQ_LLM_BASE_URL: 'http://x/v1' })).toEqual({
			HQ_LLM_BASE_URL: undefined,
			HQ_LLM_API_KEY: undefined,
			HQ_LLM_MODEL: 'gpt-5-mini',
		});
		expect(choiceFromFlags(flags({ model: 'm', 'base-url': 'https://api.groq.com/openai/v1' }), {})?.HQ_LLM_BASE_URL).toBe(
			'https://api.groq.com/openai/v1',
		);
	});

	test('the menu offers local Ollama models first', async () => {
		const answers = ['1', '2'];
		const lines: string[] = [];
		const choice = await chooseModel(
			() => answers.shift() ?? null,
			(l) => lines.push(l),
			['llama3', 'qwen3:14b'],
		);
		expect(choice).toEqual({ HQ_LLM_BASE_URL: 'http://localhost:11434/v1', HQ_LLM_MODEL: 'qwen3:14b' });
		expect(lines.join('\n')).toContain('Ollama on this machine (2 models found)');
	});

	test('skipping or leaving the model blank saves nothing', async () => {
		expect(
			await chooseModel(
				() => '3',
				() => {},
				null,
			),
		).toBeNull();
		const blank = ['1', '', 'sk-x', ''];
		expect(
			await chooseModel(
				() => blank.shift() ?? null,
				() => {},
				null,
			),
		).toBeNull();
	});

	test('ollamaModels is null when nothing answers', async () => {
		const down = (async () => {
			throw new Error('ECONNREFUSED');
		}) as unknown as typeof fetch;
		expect(await ollamaModels('http://x', down)).toBeNull();
		const up = (async () => Response.json({ models: [{ name: 'a' }] })) as unknown as typeof fetch;
		expect(await ollamaModels('http://x', up)).toEqual(['a']);
	});
});
