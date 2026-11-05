import type { Hub } from '../core/hub';
import type { Message } from '../core/messages';
import { WorkQueue } from './queue';
import type { HubEvent } from '../core/events';
import type { PushDevice, PushTokens, RingDevice } from './store';
import type { PushMessage, PushOptions, PushProvider } from './provider';

/** A push is cut to this many characters, ellipsis included. */
export const BODY_LIMIT = 240;
export const HIDDEN_BODY = 'New message';
const ATTACHMENT_BODY = 'Sent an attachment';
/** Room and sender names are cut to this, so a long one cannot push the payload past the service's size limit. */
export const TITLE_LIMIT = 120;
/** The same failure is logged at most this often. */
const LOG_EVERY_MS = 60_000;
/** An ended call is remembered this long, far past any ring, so a ring still queued for it is not sent. */
const ENDED_KEEP_MS = 10 * 60_000;

function clip(text: string, limit: number): string {
	const characters = [...text];
	return characters.length <= limit
		? text
		: `${characters
				.slice(0, limit - 1)
				.join('')
				.trimEnd()}…`;
}

/** A row that says something happened (someone joined) rather than something a person wrote: its metadata names a `kind`. */
const isSystem = (message: Message) => typeof message.metadata?.kind === 'string';

type Ringing = Extract<HubEvent, { type: 'call.ringing' }>;

/**
 * Turns bus events into pushes. It listens for new messages, reads and rings, works out who may be told, and hands each
 * device to the provider from a queue, so a slow or failing push service never slows a send or a call. Devices that hold an
 * open socket are pushed to as well: the app drops the second copy by message id, and a second ring by call id.
 */
export class PushSender {
	private readonly queue: WorkQueue;
	private readonly logged = new Map<string, number>();
	/** Calls that ended lately, by id, with when the sender heard so. */
	private readonly ended = new Map<string, number>();
	private unsubscribe: (() => void) | null = null;

	constructor(
		private readonly hub: Hub,
		private readonly tokens: PushTokens,
		private readonly provider: PushProvider,
		private readonly options: Omit<PushOptions, 'provider'> = {},
	) {
		this.queue = new WorkQueue(options.concurrency ?? 8, options.maxQueued ?? 1000);
	}

	start(): this {
		this.unsubscribe ??= this.hub.bus.on((event) => {
			if (event.type === 'message.created') {
				const { id } = event.message;
				this.enqueue(() => this.fanOutMessage(id));
			} else if (event.type === 'read') {
				const { conversationId, personId, messageId } = event;
				this.enqueue(() => this.fanOutRead(conversationId, personId, messageId));
			} else if (event.type === 'call.ringing') {
				this.enqueue(() => this.fanOutRing(event));
			} else if (event.type === 'call.ended') {
				this.noteEnded(event.callId);
			}
		});
		return this;
	}

	stop(): void {
		this.unsubscribe?.();
		this.unsubscribe = null;
		this.queue.stop();
		this.provider.close();
	}

	/** Resolves when everything queued so far has been handed to the provider and answered. */
	idle(): Promise<void> {
		return this.queue.idle();
	}

	private fanOutMessage(messageId: string): void {
		const { hub } = this;
		// Read again now: the author may have unsent it since, and the room may have been archived.
		const message = hub.messages.get(messageId);
		if (message === null || message.deleted_at !== null || isSystem(message)) return;
		const conversation = hub.conversations.get(message.conversation_id);
		// An archived room has no open members, so the devices below are none.
		if (conversation === null) return;
		const devices = this.tokens.forMessage(conversation.id, message.author_id);
		if (devices.length === 0) return;

		const sender = hub.people.get(message.author_id)?.name ?? 'Someone';
		const hidden = this.options.preview === 'hidden';
		const text = message.body.replace(/\s+/g, ' ').trim();
		const shown = text !== '' ? text : hub.attachments.forMessage(message.id).length > 0 ? ATTACHMENT_BODY : HIDDEN_BODY;
		const named = conversation.kind === 'room' && conversation.title !== '';
		const push: PushMessage = {
			type: 'message',
			title: clip(hidden || !named ? sender : conversation.title, TITLE_LIMIT),
			body: hidden ? HIDDEN_BODY : clip(named ? `${sender}: ${shown}` : shown, BODY_LIMIT),
			conversationId: conversation.id,
			messageId: message.id,
		};
		const { id, author_id: author } = message;
		this.deliver(
			devices,
			push,
			(device) =>
				hub.messages.get(id)?.deleted_at === null && this.tokens.stillReceives(device.token, conversation.id, { author }),
		);
	}

	private fanOutRead(conversationId: string, readerId: string, messageId: string): void {
		const devices = this.tokens.forReader(conversationId, readerId);
		this.deliver(devices, { type: 'read', conversationId, readThroughMessageId: messageId }, (device) =>
			this.tokens.stillReceives(device.token, conversationId, { reader: readerId }),
		);
	}

	/**
	 * A ring goes to every device of each rung person that can still see the room: a VoIP push where the phone reported a
	 * ring token (CallKit shows it with the app closed), otherwise an alert push the app reads as a ring. A hidden preview
	 * keeps the room's title back, as it does for messages; the caller's name stays.
	 */
	private fanOutRing(event: Ringing): void {
		// Not a date is never sent either: `Date.now() < NaN` is false.
		const expiresAt = Date.parse(event.expiresAt);
		const callerName = clip(event.callerName.trim() || 'Someone', TITLE_LIMIT);
		const shown = this.options.preview === 'hidden' ? '' : (event.conversationTitle?.trim() ?? '');
		const title = shown === '' ? null : clip(shown, TITLE_LIMIT);
		const ring = (channel: 'voip' | 'alert'): PushMessage => ({
			type: 'ring',
			channel,
			callId: event.callId,
			callerName,
			conversationId: event.conversationId,
			conversationTitle: title,
			expiresAt: event.expiresAt,
		});
		for (const personId of new Set(event.personIds)) {
			for (const device of this.tokens.forRing(event.conversationId, personId)) {
				// Checked again at its turn: the person may have left the room, the token moved, or the ring run out or the call
				// ended. A decline has no server event yet; the declining person's other devices learn it from the app's own poll.
				this.enqueue(() =>
					this.send(
						device,
						ring(device.kind),
						() => Date.now() < expiresAt && !this.ended.has(event.callId) && this.tokens.stillRings(device, event.conversationId),
					),
				);
			}
		}
	}

	/** Remembers an ended call for a while; older ones are forgotten as new ones come, so the list stays short. */
	private noteEnded(callId: string): void {
		const at = Date.now();
		for (const [id, endedAt] of this.ended) if (at - endedAt > ENDED_KEEP_MS) this.ended.delete(id);
		this.ended.set(callId, at);
	}

	/** Queues work; past the limit it is dropped, and the log says so (never what the work was). */
	private enqueue(task: () => void | Promise<void>): void {
		if (!this.queue.add(task) && !this.queue.stopped) this.warn('too many pushes waiting; dropping new ones');
	}

	/** `stillWanted` is asked just before each send: a push can wait in the queue a long time. */
	private deliver(devices: PushDevice[], message: PushMessage, stillWanted: (device: PushDevice) => boolean): void {
		for (const device of devices) this.enqueue(() => this.send({ ...device, kind: 'alert' }, message, stillWanted));
	}

	/** `device.kind` names the token the push goes to, and so the one a `410` clears. */
	private async send(device: RingDevice, message: PushMessage, stillWanted: (device: PushDevice) => boolean): Promise<void> {
		// The audience was worked out when the message was made. Since then the token may have moved to another device (a phone
		// that changed hands), or the person, device, membership or room may have changed: text must not reach any of those.
		if (!stillWanted(device)) return;
		let result;
		try {
			const { kind: _kind, ...target } = device;
			result = await this.provider.send(target, message);
		} catch {
			return this.warn(`${this.provider.name} adapter failed`);
		}
		const { outcome, reason } = result;
		if (outcome === 'sent') return;
		// Only the service saying the device is gone clears a token; every other failure leaves it for the next push.
		if (outcome === 'invalid_token') return this.tokens.forget(device.deviceId, device.token, device.kind);
		this.warn(`${this.provider.name} ${outcome}${reason === undefined ? '' : `: ${reason}`}`);
	}

	private warn(line: string): void {
		const at = Date.now();
		if (at - (this.logged.get(line) ?? -Infinity) < LOG_EVERY_MS) return;
		this.logged.set(line, at);
		(this.options.log ?? console.warn)(`[push] ${line}`);
	}
}
