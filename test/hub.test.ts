import { describe, expect, test } from 'bun:test';
import { Bus, type HubEvent } from '../src/core/events';
import { Hub } from '../src/core/hub';

describe('hub', () => {
	test('writes surface as bus events', () => {
		const hub = Hub.open();
		const events: HubEvent['type'][] = [];
		hub.bus.on((e) => events.push(e.type));
		const ada = hub.people.create({ name: 'Ada', handle: 'ada' });
		const room = hub.conversations.createRoom({ title: 'R', createdBy: ada.id });
		hub.messages.send({ conversationId: room.id, authorId: ada.id, body: 'hi' });
		expect(events).toEqual(['conversation.created', 'message.created']);
	});

	test('a throwing listener does not starve the others', () => {
		const bus = new Bus();
		let reached = false;
		bus.on(() => {
			throw new Error('boom');
		});
		bus.on(() => {
			reached = true;
		});
		const error = console.error;
		console.error = () => {};
		bus.emit({ type: 'assistant.state', conversationId: 'c', personId: 'p', label: null });
		console.error = error;
		expect(reached).toBe(true);
	});

	test('extra migrations run after core', () => {
		const hub = Hub.open(':memory:', [{ id: 'app/x', up: 'CREATE TABLE x (person_id TEXT REFERENCES people(id))' }]);
		expect(hub.db.query("SELECT name FROM sqlite_master WHERE name = 'x'").get()).not.toBeNull();
	});
});
