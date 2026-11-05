import { providerFetch, readProviderJson } from './http';
import type { ChatMessage, CompletionResult, FinishReason, Provider, ToolCall } from './types';

export type AnthropicOptions = {
	apiKey: string;
	baseUrl?: string;
	defaultModel?: string;
	maxTokens?: number;
	version?: string;
	fetch?: typeof fetch;
};

type Block =
	| { type: 'text'; text: string }
	| { type: 'tool_use'; id: string; name: string; input: Record<string, unknown> }
	| { type: 'tool_result'; tool_use_id: string; content: string };

type WireMessage = { role: 'user' | 'assistant'; content: Block[] };

type WireResponse = {
	content?: Block[];
	stop_reason?: string | null;
	usage?: { input_tokens?: number; output_tokens?: number };
};

export function toAnthropic(messages: ChatMessage[]): { system: string; messages: WireMessage[] } {
	const system: string[] = [];
	const out: WireMessage[] = [];
	const push = (role: WireMessage['role'], blocks: Block[]) => {
		if (blocks.length === 0) return;
		const last = out.at(-1);
		if (last?.role === role) last.content.push(...blocks);
		else out.push({ role, content: blocks });
	};
	for (const message of messages) {
		switch (message.role) {
			case 'system':
				system.push(message.content);
				break;
			case 'user':
				push('user', [{ type: 'text', text: message.content }]);
				break;
			case 'assistant':
				push('assistant', [
					...(message.content.trim() === '' ? [] : [{ type: 'text' as const, text: message.content }]),
					...(message.toolCalls ?? []).map((call) => ({
						type: 'tool_use' as const,
						id: call.id,
						name: call.name,
						input: call.arguments,
					})),
				]);
				break;
			case 'tool':
				push('user', [{ type: 'tool_result', tool_use_id: message.toolCallId, content: message.content }]);
				break;
		}
	}
	if (out[0]?.role === 'assistant')
		out.unshift({ role: 'user', content: [{ type: 'text', text: '(Earlier messages are not shown.)' }] });
	return { system: system.join('\n\n'), messages: out };
}

function finishReason(raw: string | null | undefined): FinishReason {
	if (raw === 'end_turn' || raw === 'stop_sequence') return 'stop';
	if (raw === 'tool_use') return 'tool_calls';
	if (raw === 'max_tokens') return 'length';
	return 'other';
}

export function anthropic(options: AnthropicOptions): Provider {
	const baseUrl = (options.baseUrl ?? 'https://api.anthropic.com').replace(/\/+$/, '');
	const doFetch = options.fetch ?? fetch;
	return {
		id: 'anthropic',
		defaultModel: options.defaultModel,
		async complete(request): Promise<CompletionResult> {
			const { system, messages } = toAnthropic(request.messages);
			const response = await providerFetch(
				'anthropic',
				`${baseUrl}/v1/messages`,
				{
					method: 'POST',
					signal: request.signal,
					headers: {
						'content-type': 'application/json',
						'x-api-key': options.apiKey,
						'anthropic-version': options.version ?? '2023-06-01',
					},
					body: JSON.stringify({
						model: request.model,
						max_tokens: request.maxTokens ?? options.maxTokens ?? 4096,
						...(system === '' ? {} : { system }),
						messages,
						...(request.tools?.length
							? {
									tools: request.tools.map((tool) => ({
										name: tool.name,
										description: tool.description,
										input_schema: tool.parameters,
									})),
								}
							: {}),
						...(request.tools?.length && request.toolChoice !== undefined ? { tool_choice: { type: request.toolChoice } } : {}),
						...(request.temperature === undefined ? {} : { temperature: request.temperature }),
					}),
				},
				doFetch,
			);
			const body = await readProviderJson<WireResponse>(response, 'anthropic');
			const blocks = body.content ?? [];
			const toolCalls: ToolCall[] = blocks.flatMap((block) =>
				block.type === 'tool_use' ? [{ id: block.id, name: block.name, arguments: block.input ?? {} }] : [],
			);
			return {
				content: blocks.flatMap((block) => (block.type === 'text' ? [block.text] : [])).join(''),
				toolCalls,
				finishReason: toolCalls.length > 0 ? 'tool_calls' : finishReason(body.stop_reason),
				...(body.usage
					? { usage: { inputTokens: body.usage.input_tokens ?? 0, outputTokens: body.usage.output_tokens ?? 0 } }
					: {}),
			};
		},
	};
}
