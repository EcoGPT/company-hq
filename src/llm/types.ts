export type JsonSchema = Record<string, unknown>;

export type ToolCall = {
	id: string;
	name: string;
	arguments: Record<string, unknown>;
};

export type ChatMessage =
	| { role: 'system'; content: string }
	| { role: 'user'; content: string; name?: string }
	| { role: 'assistant'; content: string; toolCalls?: ToolCall[] }
	| { role: 'tool'; toolCallId: string; name: string; content: string };

export type ToolSpec = {
	name: string;
	description: string;
	parameters: JsonSchema;
};

export type CompletionRequest = {
	model: string;
	messages: ChatMessage[];
	tools?: ToolSpec[];
	toolChoice?: 'auto' | 'none';
	temperature?: number;
	maxTokens?: number;
	signal?: AbortSignal;
};

export type FinishReason = 'stop' | 'tool_calls' | 'length' | 'other';

export type CompletionResult = {
	content: string;
	toolCalls: ToolCall[];
	finishReason: FinishReason;
	usage?: { inputTokens: number; outputTokens: number };
	model?: string;
};

export interface Provider {
	readonly id: string;
	readonly defaultModel?: string;
	complete(request: CompletionRequest): Promise<CompletionResult>;
}

export class ProviderError extends Error {
	constructor(
		readonly provider: string,
		readonly status: number | null,
		message: string,
		readonly retryAfterMs?: number,
		readonly unreachable = false,
	) {
		super(`${provider}: ${message}`);
	}
}

export function defineProvider(provider: Provider): Provider {
	return provider;
}
