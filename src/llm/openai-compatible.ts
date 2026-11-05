import { providerFetch, readProviderJson } from './http';
import { ProviderError, type ChatMessage, type CompletionResult, type FinishReason, type Provider, type ToolCall } from './types';

export type OpenAICompatibleOptions = {
	baseUrl: string;
	apiKey?: string;
	defaultModel?: string;
	headers?: Record<string, string>;
	fetch?: typeof fetch;
};

const ID = 'openai-compatible';

export async function post<T>(
	options: OpenAICompatibleOptions,
	path: string,
	payload: { json: unknown } | { form: FormData },
	signal?: AbortSignal,
): Promise<T> {
	const isJson = 'json' in payload;
	const response = await providerFetch(
		ID,
		`${options.baseUrl.replace(/\/+$/, '')}${path}`,
		{
			method: 'POST',
			signal,
			headers: {
				...(isJson ? { 'content-type': 'application/json' } : {}),
				...(options.apiKey ? { authorization: `Bearer ${options.apiKey}` } : {}),
				...options.headers,
			},
			body: isJson ? JSON.stringify(payload.json) : payload.form,
		},
		options.fetch,
	);
	return readProviderJson<T>(response, ID);
}

type WireToolCall = { id: string; type: 'function'; function: { name: string; arguments: string } };

type WireResponse = {
	choices?: {
		message?: { content?: string | null; tool_calls?: WireToolCall[] };
		finish_reason?: string | null;
	}[];
	usage?: { prompt_tokens?: number; completion_tokens?: number };
};

function toWire(message: ChatMessage): Record<string, unknown> {
	switch (message.role) {
		case 'system':
			return { role: 'system', content: message.content };
		case 'user':
			return { role: 'user', content: message.content, ...(message.name ? { name: message.name } : {}) };
		case 'assistant':
			return {
				role: 'assistant',
				content: message.content === '' && message.toolCalls?.length ? null : message.content,
				...(message.toolCalls?.length
					? {
							tool_calls: message.toolCalls.map((call) => ({
								id: call.id,
								type: 'function',
								function: { name: call.name, arguments: JSON.stringify(call.arguments) },
							})),
						}
					: {}),
			};
		case 'tool':
			return { role: 'tool', tool_call_id: message.toolCallId, content: message.content };
	}
}

function parseArguments(raw: string): Record<string, unknown> {
	if (raw.trim() === '') return {};
	try {
		const parsed = JSON.parse(raw);
		return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed) ? parsed : { _raw: raw };
	} catch {
		return { _raw: raw };
	}
}

function finishReason(raw: string | null | undefined): FinishReason {
	if (raw === 'stop' || raw === 'tool_calls' || raw === 'length') return raw;
	return raw === 'function_call' ? 'tool_calls' : 'other';
}

function rejectsMaxTokens(error: unknown): boolean {
	return (
		error instanceof ProviderError &&
		error.status === 400 &&
		error.message.includes('max_tokens') &&
		/unsupported|not supported/i.test(error.message)
	);
}

export function openAICompatible(options: OpenAICompatibleOptions): Provider {
	let tokenLimitParam: 'max_tokens' | 'max_completion_tokens' = 'max_tokens';
	return {
		id: ID,
		defaultModel: options.defaultModel,
		async complete(request): Promise<CompletionResult> {
			const json = {
				model: request.model,
				messages: request.messages.map(toWire),
				...(request.tools?.length && request.toolChoice !== 'none'
					? {
							tools: request.tools.map((tool) => ({
								type: 'function',
								function: { name: tool.name, description: tool.description, parameters: tool.parameters },
							})),
						}
					: {}),
				...(request.temperature === undefined ? {} : { temperature: request.temperature }),
			};
			const param = tokenLimitParam;
			const send = (key: string) =>
				post<WireResponse>(
					options,
					'/chat/completions',
					{ json: request.maxTokens === undefined ? json : { ...json, [key]: request.maxTokens } },
					request.signal,
				);
			let body: WireResponse;
			try {
				body = await send(param);
			} catch (error) {
				if (request.maxTokens === undefined || param !== 'max_tokens' || !rejectsMaxTokens(error)) throw error;
				tokenLimitParam = 'max_completion_tokens';
				body = await send(tokenLimitParam);
			}
			const choice = body.choices?.[0];
			if (choice === undefined) throw new ProviderError(ID, null, 'no choices returned');
			const toolCalls: ToolCall[] = (choice.message?.tool_calls ?? []).map((call) => ({
				id: call.id,
				name: call.function.name,
				arguments: parseArguments(call.function.arguments),
			}));
			return {
				content: choice.message?.content ?? '',
				toolCalls,
				finishReason: toolCalls.length > 0 ? 'tool_calls' : finishReason(choice.finish_reason),
				...(body.usage
					? { usage: { inputTokens: body.usage.prompt_tokens ?? 0, outputTokens: body.usage.completion_tokens ?? 0 } }
					: {}),
			};
		},
	};
}
