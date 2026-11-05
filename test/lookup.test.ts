import { describe, expect, test } from 'bun:test';
import { Hub } from '../src/core/hub';
import { ToolError } from '../src/tools/define';
import { asToolError, personByHandle, roomFor } from '../src/tools/lookup';

describe('shared lookups', () => {
	test('personByHandle accepts @handles and names the missing one', () => {
		const hub = Hub.open();
		const ada = hub.people.create({ name: 'Ada', handle: 'ada' });
		expect(personByHandle(hub, ' @ada').id).toBe(ada.id);
		expect(() => personByHandle(hub, '@ghost')).toThrow(new ToolError('nobody has the handle @ghost'));
	});

	test('roomFor only returns rooms everyone in the conversation can see', () => {
		const hub = Hub.open();
		const ada = hub.people.create({ name: 'Ada', handle: 'ada' });
		const bo = hub.people.create({ name: 'Bo', handle: 'bo' });
		const room = hub.conversations.createRoom({ title: 'Ada only', createdBy: ada.id });
		const dm = hub.conversations.dm(ada.id, bo.id);
		expect(roomFor({ hub, caller: ada }, room.id).id).toBe(room.id);
		expect(() => roomFor({ hub, caller: ada, viewers: [bo.id] }, room.id)).toThrow('that you are in');
		expect(() => roomFor({ hub, caller: ada }, dm.id)).toThrow('that you are in');
		expect(() => roomFor({ hub, caller: ada }, undefined)).toThrow('pass conversation_id');
	});

	test('asToolError turns any failure into a ToolError', async () => {
		await expect(asToolError(async () => Promise.reject(new Error('timeout')))).rejects.toThrow(new ToolError('timeout'));
		expect(await asToolError(async () => 1)).toBe(1);
	});
});
