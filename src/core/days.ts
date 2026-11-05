const WEEKDAYS = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];

function localDate(at: Date, timeZone: string): { y: number; m: number; d: number; weekday: number } {
	const parts = Object.fromEntries(
		new Intl.DateTimeFormat('en-US', { timeZone, year: 'numeric', month: 'numeric', day: 'numeric', weekday: 'long' })
			.formatToParts(at)
			.map((p) => [p.type, p.value]),
	);
	return {
		y: Number(parts.year),
		m: Number(parts.month),
		d: Number(parts.day),
		weekday: WEEKDAYS.indexOf(String(parts.weekday).toLowerCase()),
	};
}

function iso(y: number, m: number, d: number, plus: number): string {
	return new Date(Date.UTC(y, m - 1, d + plus)).toISOString().slice(0, 10);
}

export function resolveDay(text: string, timeZone: string, now: Date = new Date()): string | null {
	const input = text.trim().toLowerCase().replace(/\s+/g, ' ');
	const date = /^(\d{4})-(\d{2})-(\d{2})$/.exec(input);
	if (date !== null) return iso(Number(date[1]), Number(date[2]), Number(date[3]), 0) === input ? input : null;
	const today = localDate(now, timeZone);
	if (input === 'today') return iso(today.y, today.m, today.d, 0);
	if (input === 'tomorrow') return iso(today.y, today.m, today.d, 1);
	const inDays = /^in (\d{1,3}) days?$/.exec(input);
	if (inDays !== null) return iso(today.y, today.m, today.d, Number(inDays[1]));
	const weekday = /^(?:this |next )?(sunday|monday|tuesday|wednesday|thursday|friday|saturday)$/.exec(input);
	if (weekday !== null) {
		const target = WEEKDAYS.indexOf(weekday[1] ?? '');
		const ahead = (target - today.weekday + 7) % 7 || 7;
		return iso(today.y, today.m, today.d, ahead);
	}
	return null;
}
