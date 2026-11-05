import { z } from 'zod';
import { HttpError, Router, type RequestContext } from '../http/router';
import { parse } from '../wire/routes';
import type { PushTokens } from './store';

/** The lower-case hex the app sends. */
const hexToken = z.string().regex(/^[0-9a-f]{16,200}$/);

const report = z
	.object({
		environment: z.enum(['development', 'production']).optional(),
		status: z.string().min(1).max(120).optional(),
		token: hexToken.optional(),
		// The phone's ring token (PushKit).
		voip_token: hexToken.optional(),
	})
	// The app sends the environment with either token and only then: a token without one cannot be sent to.
	.refine((body) => (body.token === undefined && body.voip_token === undefined) === (body.environment === undefined));

/** Only a signed-in device has a push standing; a script's or an MCP key does not. */
function deviceOf(ctx: RequestContext) {
	const device = ctx.hub.devices.byKey(ctx.keyId);
	if (device === null) throw new HttpError(403, 'device_only');
	return device;
}

export function pushRoutes(tokens: PushTokens): Router {
	return new Router()
		.post('/v1/devices/apns-token', async (ctx) => {
			const device = deviceOf(ctx);
			const body = await parse(ctx.req, report);
			tokens.report(device.id, {
				status: body.status ?? (body.token === undefined ? 'unregistered' : 'authorized'),
				token: body.token,
				voipToken: body.voip_token,
				environment: body.environment,
			});
			return { ok: true };
		})
		.delete('/v1/devices/apns-token', (ctx) => {
			tokens.clear(deviceOf(ctx).id);
			return { ok: true };
		});
}
