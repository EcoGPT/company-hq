import { defineApp } from '@hq/sdk';
import { Files, migrations } from './store';

/** The most files one answer lists, newest first. */
const FILES_LIMIT = 500;

export default defineApp({
	slug: 'library',
	name: 'Library',
	description: 'The files people have shared in chat, in one list.',
	icon: '▤',
	migrations,
	routes: [
		// The app's Files screen asks for folders first. This server has none, so the answer is the empty list.
		{ method: 'GET', path: '/v1/library', mount: 'v1', handler: () => ({ folders: [] }) },
		{
			method: 'GET',
			path: '/v1/files',
			mount: 'v1',
			handler: ({ hub, person }) => ({
				files: new Files(hub).visibleTo(person.id, FILES_LIMIT).map((file) => ({
					id: file.id,
					file_name: file.file_name,
					content_type: file.content_type,
					byte_size: file.byte_size,
					conversation_id: file.conversation_id,
					conversation_title: file.conversation_title.trim() === '' ? null : file.conversation_title,
					uploader_name: file.uploader_name,
					created_at: new Date(file.created_at).toISOString(),
					folder_id: null,
				})),
			}),
		},
	],
});
