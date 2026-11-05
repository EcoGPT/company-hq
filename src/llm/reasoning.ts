export function stripReasoning(text: string): string {
	return text
		.replace(/<think>[\s\S]*?(<\/think>|$)/g, '')
		.replace(/^[\s\S]*<\/think>/, '')
		.trim();
}
