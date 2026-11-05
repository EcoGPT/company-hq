import { defineAssistant } from '@hq/sdk';
import persona from './persona.md' with { type: 'text' };

export default defineAssistant({
	name: 'Atlas',
	handle: 'atlas',
	persona,
	replyIn: 'mentions',
	surfaces: {
		general: 'This is the whole-team room. Keep replies extra short.',
	},
});
