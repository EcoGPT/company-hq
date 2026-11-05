import { defineConfig } from '@hq/sdk';
import docs from './apps/docs/app';
import reminders from './apps/reminders/app';
import library from './apps/library/app';
import meetings from './apps/meetings/app';
import tasks from './apps/tasks/app';
import assistant from './assistant/assistant';
import github from './connectors/github';

export default defineConfig({
	assistant,
	apps: [tasks, docs, meetings, reminders, library],
	connectors: [github],
});
