import type { CompletionRequest, CompletionResult, Provider } from './types';

export type MockStep = Partial<CompletionResult> | ((request: CompletionRequest) => Partial<CompletionResult>);

function complete(partial: Partial<CompletionResult>): CompletionResult {
	const toolCalls = partial.toolCalls ?? [];
	return {
		content: partial.content ?? '',
		toolCalls,
		finishReason: partial.finishReason ?? (toolCalls.length > 0 ? 'tool_calls' : 'stop'),
		...(partial.usage ? { usage: partial.usage } : {}),
		...(partial.model ? { model: partial.model } : {}),
	};
}

export function echo(): Provider {
	return {
		id: 'mock',
		defaultModel: 'echo',
		async complete(request) {
			const last = [...request.messages].reverse().find((m) => m.role === 'user');
			const said = last?.content.replace(/^[^:]+:\s*/, '') ?? '';
			return complete({
				content: `(No model is set up yet. Run bun hq setup, or set HQ_LLM_* in .env.) You said: ${said}`,
			});
		},
	};
}

export function scripted(steps: MockStep[]): Provider & { requests: CompletionRequest[] } {
	const queue = [...steps];
	const requests: CompletionRequest[] = [];
	return {
		id: 'mock',
		defaultModel: 'scripted',
		requests,
		async complete(request) {
			requests.push(structuredClone({ ...request, signal: undefined }));
			const step = queue.shift();
			if (step === undefined) return complete({ content: '' });
			return complete(typeof step === 'function' ? step(request) : step);
		},
	};
}
