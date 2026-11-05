import { HttpError, Router } from '../http/router';
import type { Scheduler } from './scheduler';

export function automationRoutes(scheduler: Scheduler): Router {
	const find = (params: Record<string, string>) => {
		const { app = '', slug = '' } = params;
		if (!scheduler.has(app, slug)) throw new HttpError(404, 'automation not found');
		return { app, slug };
	};
	return new Router()
		.get('/v1/automations', ({ person }) =>
			person.role === 'admin'
				? scheduler.list()
				: scheduler.list().map(({ last_run, ...automation }) => ({
						...automation,
						last_run:
							last_run === null
								? null
								: { status: last_run.status, started_at: last_run.started_at, finished_at: last_run.finished_at },
					})),
		)
		.get(
			'/v1/automations/:app/:slug/runs',
			({ params }) => {
				const { app, slug } = find(params);
				return scheduler.runs(app, slug);
			},
			'admin',
		)
		.post(
			'/v1/automations/:app/:slug/run',
			({ params }) => {
				const { app, slug } = find(params);
				void scheduler.run(app, slug, 'manual');
				return Response.json({ started: true }, { status: 202 });
			},
			'admin',
		);
}
