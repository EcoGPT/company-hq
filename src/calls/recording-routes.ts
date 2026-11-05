import type { Hub } from '../core/hub';
import { HttpError } from '../http/router';
import { iso } from '../wire/present';
import { layout, seconds, wavStream } from './recording';
import type { RecordingStore, Segment } from './recording-store';
import type { Calls } from './service';
import type { CallTranscripts } from './transcribe';

/** What `/record`, `/recording/:deviceId` and `/retranscribe` answer. Each takes a call the asker may already read. */
export class CallRecords {
	constructor(
		private readonly hub: Hub,
		private readonly calls: Calls,
		private readonly store: RecordingStore,
		readonly transcripts: CallTranscripts,
	) {}

	/** `{call, summary?, recap_at?, transcript, recordings}`. */
	record(callId: string) {
		const call = this.calls.store.get(callId)!;
		const recap = this.store.recap(callId);
		const lines = recap.transcript_id === null ? [] : this.store.lines(recap.transcript_id);
		const bySeat = new Map<string, Segment[]>();
		for (const segment of this.store.segments(callId)) {
			const seat = bySeat.get(segment.device_id) ?? [];
			seat.push(segment);
			bySeat.set(segment.device_id, seat);
		}
		const people = this.hub.people.byIds([...lines.map((l) => l.person_id), ...[...bySeat.values()].map((s) => s[0]!.person_id)]);
		const name = (id: string) => people.get(id)?.name ?? '?';
		return {
			call: this.calls.present(call),
			...(recap.summary === null ? {} : { summary: recap.summary }),
			...(recap.recap_at === null ? {} : { recap_at: iso(recap.recap_at) }),
			transcript: lines.map((l) => ({ person_id: l.person_id, name: name(l.person_id), text: l.text, at_ms: l.at_ms })),
			recordings: [...bySeat.entries()].map(([deviceId, segments]) => ({
				device_id: deviceId,
				person_id: segments[0]!.person_id,
				name: name(segments[0]!.person_id),
				seconds: seconds(layout(segments).bytes),
			})),
		};
	}

	/** One seat's whole recording as a WAV, streamed from disk. */
	recording(callId: string, deviceId: string): Response {
		const segments = this.store.segments(callId, deviceId);
		if (segments.length === 0) throw new HttpError(404, 'not_found');
		const { bytes, stream } = wavStream(this.hub.files, segments);
		const who = (this.hub.people.get(segments[0]!.person_id)?.handle ?? '').replace(/[^A-Za-z0-9_-]/g, '');
		return new Response(stream, {
			headers: {
				'content-type': 'audio/wav',
				'content-length': String(bytes),
				'content-disposition': `attachment; filename="${who || 'someone'}-call.wav"`,
				'cache-control': 'private, no-store',
			},
		});
	}
}
