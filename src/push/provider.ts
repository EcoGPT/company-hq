/** Which of a push service's two worlds a device token was issued in. The app reports it with the token. */
export type PushEnvironment = 'development' | 'production';

export type PushTarget = { token: string; environment: PushEnvironment };

/** What a push says, without the shape any one service wants it in. */
export type PushMessage =
	| { type: 'message'; title: string; body: string; conversationId: string; messageId: string }
	/** Silent: tells a person's devices a conversation was read through this message. */
	| { type: 'read'; conversationId: string; readThroughMessageId: string }
	/**
	 * Someone is calling. `voip` goes to the phone's ring token, which the app must report to CallKit; `alert` is an ordinary
	 * banner the app reads as a ring. `expiresAt` is ISO 8601: past it the ring is worth nothing.
	 */
	| {
			type: 'ring';
			channel: 'voip' | 'alert';
			callId: string;
			callerName: string;
			conversationId: string;
			conversationTitle: string | null;
			expiresAt: string;
	  };

/**
 * - `sent`: the service took it.
 * - `invalid_token`: the service says this device is gone for good. The only outcome that clears a stored token.
 * - `config`: our key, topic or token does not fit what the service expects. Retrying will not help, and the token may be fine.
 * - `transient`: the service or the network failed; a later push may work.
 * - `fatal`: anything else.
 */
export type PushOutcome = 'sent' | 'invalid_token' | 'config' | 'transient' | 'fatal';

export type PushResult = { outcome: PushOutcome; reason?: string };

/** A push service. Core never names one; `apns.ts` is the Apple adapter. */
export interface PushProvider {
	/** For log lines. */
	readonly name: string;
	send(target: PushTarget, message: PushMessage): Promise<PushResult>;
	/** Drops open connections. */
	close(): void;
}

export type PushPreview = 'full' | 'hidden';

export type PushOptions = {
	/** Null turns sending off; the token routes keep storing. */
	provider: PushProvider | null;
	/** `hidden` sends the sender's name and "New message" and no text. */
	preview?: PushPreview;
	/** Pushes in flight at once (default 8). */
	concurrency?: number;
	/** Pushes waiting for a turn; past this the newest are dropped (default 1000). */
	maxQueued?: number;
	/** Where the sender's few log lines go (default `console.warn`). */
	log?: (line: string) => void;
};
