import type { Hq } from './hq';

export { createHq } from './hq';
export type { Hq, HqOptions } from './hq';
export { echo, scripted, type MockStep } from './llm';
export { hashEmbedder, scriptedTranscriber } from './ai';

export function client(hq: Hq, key?: string) {
	return async (method: string, path: string, body?: unknown) => {
		const response = await hq.fetch(
			new Request(`http://hq.test${path}`, {
				method,
				headers: { 'content-type': 'application/json', ...(key ? { authorization: `Bearer ${key}` } : {}) },
				body: body === undefined ? undefined : JSON.stringify(body),
			}),
		);
		if (response === undefined) throw new Error('unexpected upgrade');
		const text = await response.text();
		return { status: response.status, body: text === '' ? null : JSON.parse(text) };
	};
}

export function admin(hq: Hq) {
	const person = hq.hub.people.create({ name: 'Ada', handle: 'ada', role: 'admin' });
	hq.hub.conversations.addMember(hq.hub.general().id, person.id);
	return { person, key: hq.hub.keys.mint(person.id).secret };
}
