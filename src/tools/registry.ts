import type { ToolSpec } from '../llm/types';
import { errorMessage, toSpec, ToolError, type Audience, type Tool, type ToolContext } from './define';

export type ToolResult = { ok: true; value: unknown } | { ok: false; error: string };

type Entry = { tool: Tool; source: string };

export class ToolRegistry {
	private readonly entries = new Map<string, Entry>();
	private shared: Partial<ToolContext> = {};

	provide(context: Partial<ToolContext>): this {
		this.shared = { ...this.shared, ...context };
		return this;
	}

	register(tools: Tool[], source = 'core'): this {
		for (const tool of tools) {
			const existing = this.entries.get(tool.name);
			if (existing !== undefined) {
				throw new Error(`tool ${tool.name} from ${source} collides with one from ${existing.source}`);
			}
			this.entries.set(tool.name, { tool, source });
		}
		return this;
	}

	get(name: string): Tool | undefined {
		return this.entries.get(name)?.tool;
	}

	list(audience: Audience, given?: ToolContext): Tool[] {
		const ctx = given === undefined ? undefined : { ...this.shared, ...given };
		return [...this.entries.values()]
			.map((entry) => entry.tool)
			.filter((tool) => audience === 'assistant' || (tool.audience ?? 'everyone') === 'everyone')
			.filter((tool) => ctx === undefined || tool.available === undefined || tool.available(ctx));
	}

	specs(audience: Audience, ctx?: ToolContext): ToolSpec[] {
		return this.list(audience, ctx).map(toSpec);
	}

	async call(name: string, args: unknown, given: ToolContext, audience: Audience = 'assistant'): Promise<ToolResult> {
		const ctx = { ...this.shared, ...given };
		const tool = this.get(name);
		if (tool === undefined || !this.list(audience).includes(tool)) return { ok: false, error: `unknown tool: ${name}` };
		if (tool.available !== undefined && !tool.available(ctx)) return { ok: false, error: `${name} is not configured` };
		const parsed = tool.input.safeParse(resolveRoomRefs(args ?? {}, ctx));
		if (!parsed.success) {
			return {
				ok: false,
				error: `invalid input: ${parsed.error.issues.map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`).join('; ')}`,
			};
		}
		try {
			return { ok: true, value: await tool.run(parsed.data, ctx) };
		} catch (error) {
			if (error instanceof ToolError) return { ok: false, error: error.message };
			console.error(`[tools] ${name} failed`, error);
			return { ok: false, error: `${name} failed: ${errorMessage(error)}` };
		}
	}
}

const ROOM_KEYS = ['conversation_id', 'room_id'];

export function resolveRoomRefs(args: unknown, ctx: ToolContext): unknown {
	if (typeof args !== 'object' || args === null || Array.isArray(args)) return args;
	let out = args as Record<string, unknown>;
	for (const key of ROOM_KEYS) {
		const ref = out[key];
		if (typeof ref !== 'string' || ref === '' || ctx.hub.conversations.get(ref) !== null) continue;
		if (/^(this|here|current)( room| conversation)?$/i.test(ref.trim()) && ctx.conversationId !== undefined) {
			out = { ...out, [key]: ctx.conversationId };
			continue;
		}
		const wanted = ref.trim().replace(/^#/, '').toLowerCase();
		const matches = ctx.hub.conversations
			.listFor(ctx.caller.id)
			.filter((c) => c.kind === 'room' && (c.key?.toLowerCase() === wanted || c.title.toLowerCase() === wanted));
		if (matches.length === 1) out = { ...out, [key]: matches[0]!.id };
	}
	return out;
}

export function formatResult(result: ToolResult, maxChars = 12_000): string {
	const text = result.ok ? stringify(result.value) : JSON.stringify({ error: result.error });
	return text.length > maxChars ? `${text.slice(0, maxChars)}… [truncated ${text.length - maxChars} chars]` : text;
}

function stringify(value: unknown): string {
	if (typeof value === 'string') return value;
	return JSON.stringify(value ?? null) ?? 'null';
}
