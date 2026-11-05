/** An SDP offer or answer, as WebRTC writes it. */
export type SessionDescription = { sdp: string; type: 'offer' | 'answer' };

/** What the relay said about one track: its transceiver id, or why it was not taken. */
export type RelayTrack = { mid?: string; trackName?: string; errorCode?: string };

/**
 * - `sfu_unavailable`: no answer, a timeout or a 5xx; a later try may work.
 * - `sfu_rejected`: the relay refused the request (4xx, or an error code in its answer).
 * - `sfu_bad_response`: an answer that is not the shape it should be.
 */
export type RelayErrorCode = 'sfu_unavailable' | 'sfu_rejected' | 'sfu_bad_response';

export class RelayError extends Error {
	constructor(readonly code: RelayErrorCode) {
		super(code);
	}
}

/**
 * The media relay (a selective forwarding unit) every device in a call sends its tracks to and pulls the others' from. Each
 * device has one session, which is one WebRTC peer connection. Core never names a vendor; `cloudflare.ts` is the adapter.
 */
export interface CallRelay {
	/** For log lines. */
	readonly name: string;
	newSession(): Promise<{ sessionId: string }>;
	/** Sends the device's offer for its local tracks; the answer goes back to the device. */
	publish(
		sessionId: string,
		offer: SessionDescription,
		tracks: { mid: string; trackName: string }[],
	): Promise<{ answer: SessionDescription; tracks: RelayTrack[] }>;
	/** Pulls other sessions' tracks into this one. When `renegotiate` is set the relay's `offer` must be answered. */
	subscribe(
		sessionId: string,
		tracks: { sessionId: string; trackName: string }[],
	): Promise<{ offer: SessionDescription | null; renegotiate: boolean; tracks: RelayTrack[] }>;
	renegotiate(sessionId: string, answer: SessionDescription): Promise<void>;
	/** Stops these transceivers at once, with no SDP exchange. */
	closeTracks(sessionId: string, mids: string[]): Promise<void>;
}
