import type { AppContext } from '../apps/define';
import { parseSchedule } from './schedule';

export type AutomationContext = AppContext & {
	runId: string;
	trigger: 'schedule' | 'manual';
	signal: AbortSignal;
	log(line: string): void;
};

export type AutomationDefinition = {
	slug: string;
	name: string;
	description: string;
	schedule: string;
	run(ctx: AutomationContext): Promise<string | void> | string | void;
};

export function defineAutomation(automation: AutomationDefinition): AutomationDefinition {
	if (!/^[a-z][a-z0-9-]{0,31}$/.test(automation.slug)) throw new Error(`automation slugs are kebab-case: ${automation.slug}`);
	parseSchedule(automation.schedule);
	return automation;
}
