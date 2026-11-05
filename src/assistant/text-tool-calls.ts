import { stripReasoning } from '../llm/reasoning';
import type { ToolCall } from '../llm/types';

const BLOCK = /<tool_call>\s*([\s\S]*?)\s*<\/tool_call>/g;
const FENCE = /^```(?:json)?\s*([\s\S]*?)\s*```$/;

function parse(text: string): unknown {
	try {
		return JSON.parse(text);
	} catch {
		return undefined;
	}
}

function callsIn(body: string, known: (name: string) => boolean): ToolCall[] | null {
	if (!body.startsWith('{') && !body.startsWith('[')) return null;
	const value = parse(body);
	const candidates = Array.isArray(value) ? value : [value];
	const calls: ToolCall[] = [];
	for (const candidate of candidates) {
		if (typeof candidate !== 'object' || candidate === null) return null;
		const { name, arguments: args, parameters } = candidate as Record<string, unknown>;
		const input = args ?? parameters ?? {};
		const parsed = typeof input === 'string' ? parse(input) : input;
		if (typeof name !== 'string' || !known(name) || typeof parsed !== 'object' || parsed === null || Array.isArray(parsed))
			return null;
		calls.push({ id: `text_${crypto.randomUUID()}`, name, arguments: parsed as Record<string, unknown> });
	}
	return calls;
}

export function toolCallsInText(content: string, known: (name: string) => boolean): ToolCall[] {
	const body = stripReasoning(content);
	const blocks = [...body.matchAll(BLOCK)].map((match) => match[1]!.trim());
	if (blocks.length > 0) {
		const calls: ToolCall[] = [];
		for (const block of blocks) {
			const found = callsIn(block, known);
			if (found === null) return [];
			calls.push(...found);
		}
		return calls;
	}
	return callsIn(FENCE.exec(body)?.[1]?.trim() ?? body, known) ?? [];
}
