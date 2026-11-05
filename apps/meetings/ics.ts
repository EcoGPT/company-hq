export type CalendarEvent = {
	uid: string;
	start: number;
	end: number;
	title: string;
	description?: string;
	location?: string;
	url?: string;
	cancelled?: boolean;
};

const encoder = new TextEncoder();

export function stamp(ms: number): string {
	return new Date(ms)
		.toISOString()
		.replace(/[-:]/g, '')
		.replace(/\.\d{3}/, '');
}

export function escapeText(text: string): string {
	return text
		.replace(/\\/g, '\\\\')
		.replace(/;/g, '\\;')
		.replace(/,/g, '\\,')
		.replace(/\r\n|\r|\n/g, '\\n');
}

export function fold(line: string): string {
	const parts: string[] = [];
	let current = '';
	let bytes = 0;
	for (const char of line) {
		const size = encoder.encode(char).length;
		const limit = parts.length === 0 ? 75 : 74;
		if (bytes + size > limit) {
			parts.push(current);
			current = '';
			bytes = 0;
		}
		current += char;
		bytes += size;
	}
	parts.push(current);
	return parts.join('\r\n ');
}

export function calendar(name: string, events: CalendarEvent[], at = Date.now()): string {
	const lines = [
		'BEGIN:VCALENDAR',
		'VERSION:2.0',
		'PRODID:-//hq-community//meetings//EN',
		'CALSCALE:GREGORIAN',
		`X-WR-CALNAME:${escapeText(name)}`,
	];
	for (const event of events) {
		lines.push(
			'BEGIN:VEVENT',
			`UID:${event.uid}`,
			`DTSTAMP:${stamp(at)}`,
			`DTSTART:${stamp(event.start)}`,
			`DTEND:${stamp(event.end)}`,
			`SUMMARY:${escapeText(event.title)}`,
			`STATUS:${event.cancelled ? 'CANCELLED' : 'CONFIRMED'}`,
		);
		if (event.description) lines.push(`DESCRIPTION:${escapeText(event.description)}`);
		if (event.location) lines.push(`LOCATION:${escapeText(event.location)}`);
		if (event.url) lines.push(`URL:${event.url}`);
		lines.push('END:VEVENT');
	}
	lines.push('END:VCALENDAR');
	return `${lines.map(fold).join('\r\n')}\r\n`;
}
