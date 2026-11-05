import type { Attachment } from '../core/attachments';
import type { Conversation } from '../core/conversations';
import type { Hub } from '../core/hub';
import type { Message } from '../core/messages';
import type { Person } from '../core/people';

/** Bumped only when a field is removed or changes meaning; adding fields never bumps it. */
export const WIRE_VERSION = 1;

const EDIT_HISTORY_SHOWN = 20;

export const iso = (ms: number) => new Date(ms).toISOString();

const PERSON_KIND = { human: 'person', assistant: 'bot', service: 'service' } as const;

/** The JSON the native app decodes, built from rows. Keys are snake_case; times are ISO strings. */
export class Presenter {
	constructor(private readonly hub: Hub) {}

	person(person: Person) {
		return {
			id: person.id,
			name: person.name,
			kind: PERSON_KIND[person.kind],
			is_admin: person.role === 'admin',
			avatar_id: person.avatar_id,
			removed_at: person.removed_at === null ? null : iso(person.removed_at),
		};
	}

	attachment(attachment: Attachment) {
		return {
			id: attachment.id,
			file_name: attachment.file_name,
			content_type: attachment.content_type,
			byte_size: attachment.byte_size,
			width: attachment.width,
			height: attachment.height,
		};
	}

	/** A payload carries the last `EDIT_HISTORY_SHOWN` versions of an edit; every version stays in the database. */
	message(message: Message, options: { history?: boolean } = {}) {
		const { hub } = this;
		const unsent = message.deleted_at !== null;
		const quoted = message.reply_to_message_id === null ? null : hub.messages.get(message.reply_to_message_id);
		return {
			id: message.id,
			conversation_id: message.conversation_id,
			sender_person_id: message.author_id,
			sender_name: this.nameOf(message.author_id),
			content: message.body,
			created_at: iso(message.created_at),
			edited_at: message.edited_at === null ? null : iso(message.edited_at),
			deleted_at: unsent ? iso(message.deleted_at!) : null,
			// An unsent message takes its tapbacks, files and earlier drafts with it.
			edit_history:
				unsent || message.edited_at === null || options.history === false
					? []
					: hub.messages
							.history(message.id, EDIT_HISTORY_SHOWN)
							.map((r) => ({ content: r.content, edited_at: iso(r.edited_at) })),
			reactions: unsent ? [] : hub.reactions.forMessage(message.id),
			attachments: unsent ? [] : hub.attachments.forMessage(message.id).map((a) => this.attachment(a)),
			reply_to: quoted === null ? null : { id: quoted.id, content: quoted.body, sender_name: this.nameOf(quoted.author_id) },
			kind: null,
			via: null,
		};
	}

	/** One person's copy: the unread count and the title are theirs. */
	conversation(conversation: Conversation, viewerId: string) {
		const { hub } = this;
		const last = hub.messages.latest(conversation.id);
		return {
			id: conversation.id,
			kind: conversation.kind === 'dm' ? 'dm' : 'group',
			title: conversation.kind === 'dm' || conversation.title === '' ? null : conversation.title,
			member_ids: hub.conversations.memberIds(conversation.id),
			created_at: iso(conversation.created_at),
			// The list shows a preview, so it carries no edit history however often the message was edited.
			last_message: last === null ? null : this.message(last, { history: false }),
			unread_count: hub.reads.unreadCount(conversation.id, viewerId),
			read_marks: hub.reads.marks(conversation.id),
			// A keyed room (General) is a standing room: it cannot be renamed, left or deleted.
			room_slug: conversation.kind === 'room' ? conversation.key : null,
			avatar_id: conversation.avatar_id,
		};
	}

	private nameOf(personId: string): string {
		return this.hub.people.get(personId)?.name ?? '?';
	}
}
