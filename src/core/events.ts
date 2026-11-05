import type { Conversation } from './conversations';
import type { Message } from './messages';
import type { Person } from './people';

/** A socket frame: a `type` and whatever else the app on the other end decodes for it. */
export type WireFrame = { type: string } & Record<string, unknown>;

/**
 * Whatever happens in HQ, said once. The socket turns these into frames and sends each only to the
 * people who can see the conversation. `audience` is fixed when the event is emitted, because a
 * leaver or a freshly archived room has no members left to ask afterwards.
 *
 * `frame` is how a feature outside core reaches the app's socket: the socket sends `frame` as it is to the people it
 * names, and to no one else. Name them one of three ways, and an event that does none is refused when it is emitted:
 * - `audience: [personIds]`, built when you emit from who may see the data.
 * - `conversationId` alone: that room's members now (none once it is archived), like every other room frame.
 * - `audience: 'everyone'`: everyone connected. Only for a frame that carries nothing private (like `presence`); anything a
 *   person could not read through the API is never sent to everyone.
 * `conversationId` with a list sends to those of the list who are in the room now. It cannot be combined with 'everyone'.
 * `app.event` stays internal to the server on purpose: an app's change events are not part of the app's protocol.
 */
export type HubEvent =
	| { type: 'message.created'; message: Message }
	| { type: 'message.updated'; message: Message }
	| { type: 'conversation.created'; conversation: Conversation }
	| { type: 'conversation.changed'; conversationId: string; audience: string[] }
	| { type: 'conversation.removed'; conversationId: string; audience: string[] }
	| { type: 'read'; conversationId: string; personId: string; messageId: string }
	| { type: 'person.updated'; person: Person }
	| { type: 'assistant.state'; conversationId: string; personId: string; label: string | null }
	| { type: 'frame'; audience?: string[] | 'everyone'; frame: WireFrame; conversationId?: string }
	| { type: 'app.event'; app: string; name: string; data: unknown }
	| { type: 'key.revoked'; keyId: string }
	| {
			type: 'call.ringing';
			callId: string;
			conversationId: string;
			callerName: string;
			conversationTitle: string | null;
			expiresAt: string;
			personIds: string[];
	  }
	| { type: 'call.ended'; callId: string; conversationId: string; meetingId: string | null; endedAt: string };

type Listener = (event: HubEvent) => void;

export class Bus {
	private readonly listeners = new Set<Listener>();

	on(listener: Listener): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	emit(event: HubEvent): void {
		if (event.type === 'frame') assertFrameAudience(event);
		for (const listener of this.listeners) {
			try {
				listener(event);
			} catch (error) {
				console.error(`[bus] listener failed on ${event.type}`, error);
			}
		}
	}
}

/** A frame event that names no one fails here, at the emit, so a missing or mistyped audience is never read as everyone. */
function assertFrameAudience({ audience, conversationId }: Extract<HubEvent, { type: 'frame' }>): void {
	const named =
		audience === undefined
			? conversationId !== undefined
			: audience === 'everyone'
				? conversationId === undefined
				: Array.isArray(audience) && audience.every((id) => typeof id === 'string');
	if (!named) {
		throw new Error(
			'a frame event needs an audience (a list of person ids, or "everyone") or a conversationId, and "everyone" cannot have one',
		);
	}
}
