import type { Database } from 'bun:sqlite';
import type { Migration } from '../db/database';
import type { Provider } from './types';

export const USAGE_MIGRATIONS: Migration[] = [
	{
		id: 'ai/001_usage',
		up: `CREATE TABLE ai_usage (
			day TEXT NOT NULL,
			capability TEXT NOT NULL,
			provider TEXT NOT NULL,
			model TEXT NOT NULL,
			calls INTEGER NOT NULL DEFAULT 0,
			failures INTEGER NOT NULL DEFAULT 0,
			input_tokens INTEGER NOT NULL DEFAULT 0,
			output_tokens INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (day, capability, provider, model)
		)`,
	},
];

export type UsageEvent = {
	capability: string;
	provider: string;
	model: string;
	ok: boolean;
	inputTokens?: number;
	outputTokens?: number;
};

export type UsageTotals = {
	capability: string;
	provider: string;
	model: string;
	calls: number;
	failures: number;
	input_tokens: number;
	output_tokens: number;
};

export class Usage {
	constructor(
		private readonly db: Database,
		private readonly clock: () => Date = () => new Date(),
	) {}

	record(event: UsageEvent): void {
		this.db
			.query(
				`INSERT INTO ai_usage (day, capability, provider, model, calls, failures, input_tokens, output_tokens)
				VALUES ($day, $capability, $provider, $model, 1, $failed, $input, $output)
				ON CONFLICT (day, capability, provider, model) DO UPDATE SET
					calls = calls + 1, failures = failures + $failed,
					input_tokens = input_tokens + $input, output_tokens = output_tokens + $output`,
			)
			.run({
				day: this.clock().toISOString().slice(0, 10),
				capability: event.capability,
				provider: event.provider,
				model: event.model,
				failed: event.ok ? 0 : 1,
				input: event.inputTokens ?? 0,
				output: event.outputTokens ?? 0,
			});
	}

	totals(days = 7): UsageTotals[] {
		const since = new Date(this.clock().getTime() - (days - 1) * 86_400_000).toISOString().slice(0, 10);
		return this.db
			.query<UsageTotals, { since: string }>(
				`SELECT capability, provider, model, SUM(calls) AS calls, SUM(failures) AS failures,
					SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens
				FROM ai_usage WHERE day >= $since GROUP BY capability, provider, model ORDER BY capability, calls DESC`,
			)
			.all({ since });
	}
}

export function metered(provider: Provider, usage: Usage): Provider {
	return {
		id: provider.id,
		defaultModel: provider.defaultModel,
		async complete(request) {
			try {
				const result = await provider.complete(request);
				usage.record({
					capability: 'chat',
					provider: provider.id,
					model: result.model ?? request.model,
					ok: true,
					inputTokens: result.usage?.inputTokens,
					outputTokens: result.usage?.outputTokens,
				});
				return result;
			} catch (error) {
				if (request.signal?.aborted !== true)
					usage.record({ capability: 'chat', provider: provider.id, model: request.model, ok: false });
				throw error;
			}
		},
	};
}
