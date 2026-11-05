export type AssistantDefinition = {
	name: string;
	handle: string;
	persona: string;
	model?: string;
	replyIn?: 'mentions' | 'everything';
	maxHops?: number;
	historyLimit?: number;
	temperature?: number;
	surfaces?: Record<string, string>;
	timezone?: string;
};

export type ResolvedAssistant = Required<Omit<AssistantDefinition, 'model' | 'temperature'>> &
	Pick<AssistantDefinition, 'model' | 'temperature'>;

export function defaultTimezone(): string {
	const configured = process.env.HQ_TIMEZONE?.trim();
	return configured === undefined || configured === '' ? Intl.DateTimeFormat().resolvedOptions().timeZone : configured;
}

export function defineAssistant(definition: AssistantDefinition): ResolvedAssistant {
	const timezone = definition.timezone ?? defaultTimezone();
	try {
		new Intl.DateTimeFormat('en-US', { timeZone: timezone });
	} catch {
		throw new Error(`unknown time zone "${timezone}" (use an IANA name like America/New_York)`);
	}
	return {
		replyIn: 'mentions',
		maxHops: 24,
		historyLimit: 40,
		surfaces: {},
		...definition,
		timezone,
		persona: definition.persona.trim(),
	};
}
