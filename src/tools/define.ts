import { z } from 'zod';
import type { Ai } from '../ai/types';
import type { Hub } from '../core/hub';
import type { Person } from '../core/people';
import { ProviderError, type JsonSchema, type ToolSpec } from '../llm/types';

export type ToolContext = {
	hub: Hub;
	caller: Person;
	conversationId?: string;
	viewers?: string[];
	requester?: string;
	signal?: AbortSignal;
	ai?: Ai;
	timezone?: string;
};

export function canSee(ctx: ToolContext, conversationId: string): boolean {
	const { conversations } = ctx.hub;
	if (!conversations.isMember(conversationId, ctx.caller.id)) return false;
	return (ctx.viewers ?? []).every((id) => conversations.isMember(conversationId, id));
}

export type Audience = 'assistant' | 'everyone';

export type Tool<S extends z.ZodType = z.ZodType> = {
	name: string;
	description: string;
	input: S;
	activity?: string;
	audience?: Audience;
	available?(ctx: ToolContext): boolean;
	run(input: z.infer<S>, ctx: ToolContext): unknown;
};

export class ToolError extends Error {}

/** An error as members may see it: a provider's own message can echo key material, so only its id and status show. */
export function errorMessage(error: unknown): string {
	if (error instanceof ProviderError) return `model provider error: ${error.provider} (${error.status ?? 'no response'})`;
	return error instanceof Error ? error.message : String(error);
}

const NAME = /^[a-z][a-z0-9_]{0,63}$/;

export function defineTool<S extends z.ZodType>(tool: Tool<S>): Tool<S> {
	if (!NAME.test(tool.name)) throw new Error(`tool names are snake_case: ${tool.name}`);
	try {
		toSpec(tool);
	} catch (error) {
		throw new Error(`tool ${tool.name} has an input the model can't be shown: ${error instanceof Error ? error.message : error}`);
	}
	return tool;
}

export function toSpec(tool: Tool): ToolSpec {
	const { $schema: _, ...parameters } = z.toJSONSchema(tool.input, { io: 'input' }) as JsonSchema;
	return { name: tool.name, description: tool.description, parameters };
}
