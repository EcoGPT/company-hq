import type { AppContext, AppDefinition, WidgetWork } from '../apps/define';
import type { Person } from '../core/people';

export const EMPTY_WORK: WidgetWork = { in_progress: 0, open: 0, blocked: 0, done_week: 0, next_due: null, tasks: [] };

/** `person`'s work from the first app that has a `widgetWork` hook. With none, or if it fails, nothing is owed. */
export function widgetWork(mounted: { app: AppDefinition; context: AppContext }[], person: Person): WidgetWork {
	for (const { app, context } of mounted) {
		if (app.widgetWork === undefined) continue;
		try {
			return app.widgetWork(context, person);
		} catch (error) {
			console.error(`[apps] ${app.slug} widgetWork hook failed`, error);
			break;
		}
	}
	return EMPTY_WORK;
}
