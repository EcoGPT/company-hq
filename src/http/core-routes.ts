import { z } from 'zod';
import type { CallsView } from '../apps/define';
import type { Presenter } from '../wire/present';
import { HANDLE, type Person } from '../core/people';
import { adminDevice } from '../wire/members';
import { HttpError, readBody, Router } from './router';

/** Health, the roster and adding people. Chat, keys and the rest of the app protocol live in src/wire. */
export function coreRoutes(present: Presenter, calls: (person: Person) => CallsView): Router {
	return (
		new Router()
			.public('GET', '/healthz', () => ({ ok: true }))
			.get('/v1/people', ({ hub }) => ({ people: hub.people.list().map((p) => present.person(p)) }))
			// The app reads calls along with people and conversations and drops all three if any fails, so this must answer,
			// with calls off too. Live calls and rings come from src/calls, meetings from the apps' `calls` hooks.
			.get('/v1/calls', ({ person }) => calls(person))
			.post(
				'/v1/people',
				async (ctx) => {
					const { req, hub } = ctx;
					adminDevice(ctx);
					const body = await readBody(
						req,
						z.object({
							name: z.string().min(1),
							handle: z.string().regex(HANDLE, 'letters, digits, _ and -, up to 32'),
							role: z.enum(['admin', 'member']).optional(),
							kind: z.enum(['human', 'service']).optional(),
						}),
					);
					adminDevice(ctx);
					if (hub.people.byHandle(body.handle) !== null) throw new HttpError(409, 'handle taken');
					const person = hub.people.create(body);
					if (person.kind === 'human') hub.conversations.addMember(hub.general().id, person.id);
					hub.bus.emit({ type: 'person.updated', person });
					return { person: present.person(person), key: hub.keys.mint(person.id, 'invite').secret };
				},
				'admin',
			)
	);
}
