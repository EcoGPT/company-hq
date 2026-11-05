export function welcome(name: string, handle: string, model: string | null): string {
	return [
		`Welcome to HQ, ${name.split(' ')[0]}. A few things to try:`,
		`- Tag @${handle} in any room: "@${handle} file a task for me to write the launch post, due Friday".`,
		`- DM me for anything you'd rather not say in a room. I answer every message there.`,
		'- I can file tasks, write docs, schedule meetings and set reminders for you: just ask.',
		'- Add teammates with `bun hq invite <handle>`, and build your own app with `bun hq new app <name>`.',
		model === null
			? 'No model is set yet, so I only echo. Run `bun hq setup` again, or set HQ_LLM_* in .env.'
			: `I'm running on ${model}.`,
	].join('\n');
}
