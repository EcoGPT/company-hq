export const FREQUENCIES = ['daily', 'weekdays', 'weekly', 'biweekly', 'monthly'] as const;
export type Frequency = (typeof FREQUENCIES)[number];

/** How a meeting repeats. `weekdays` is 0 = Sunday to 6 = Saturday and only matters for weekly and biweekly. */
export type Rule = { freq: Frequency; timezone: string; weekdays: number[] };

const DAY = 86_400_000;
const NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const formatters = new Map<string, Intl.DateTimeFormat>();

export function validTimezone(timezone: string): boolean {
	try {
		formatter(timezone);
		return true;
	} catch {
		return false;
	}
}

function formatter(timezone: string): Intl.DateTimeFormat {
	let known = formatters.get(timezone);
	if (known === undefined) {
		known = new Intl.DateTimeFormat('en-US', {
			timeZone: timezone,
			hourCycle: 'h23',
			year: 'numeric',
			month: 'numeric',
			day: 'numeric',
			hour: 'numeric',
			minute: 'numeric',
			second: 'numeric',
		});
		formatters.set(timezone, known);
	}
	return known;
}

/** How far ahead of UTC the zone's clock is at that moment. */
function offsetAt(timezone: string, ms: number): number {
	const parts = formatter(timezone).formatToParts(ms);
	const part = (type: string) => Number(parts.find((p) => p.type === type)?.value);
	const wall = Date.UTC(part('year'), part('month') - 1, part('day'), part('hour') % 24, part('minute'), part('second'));
	return wall - Math.floor(ms / 1000) * 1000;
}

/** The clock on a zone's wall at that moment, read as if it were UTC. */
function wallClock(timezone: string, ms: number): Date {
	return new Date(ms + offsetAt(timezone, ms));
}

/** The moment a zone's clock reads this date and time. The second pass settles a time next to a clock change. */
function atWall(timezone: string, date: Date, time: Date): number {
	const wall = Date.UTC(
		date.getUTCFullYear(),
		date.getUTCMonth(),
		date.getUTCDate(),
		time.getUTCHours(),
		time.getUTCMinutes(),
		time.getUTCSeconds(),
		time.getUTCMilliseconds(),
	);
	return wall - offsetAt(timezone, wall - offsetAt(timezone, wall));
}

const daysInMonth = (year: number, month: number) => new Date(Date.UTC(year, month + 1, 0)).getUTCDate();

/**
 * The first start after `after` that the rule gives, counting from the first meeting at `anchor`, or null if none is found
 * within a few years. The wall-clock time of the anchor is kept, so a 10:00 meeting stays at 10:00 when the clocks change.
 * Weekly and biweekly repeat on the anchor's weekday unless the rule names others; a monthly one that lands on a day the
 * month does not have takes the month's last day.
 */
export function nextStart(rule: Rule, anchor: number, after: number): number | null {
	const { timezone } = rule;
	const first = wallClock(timezone, anchor);
	const firstDay = Math.floor(first.getTime() / DAY);
	const firstWeekday = first.getUTCDay();
	const floor = Math.max(anchor, after);
	if (rule.freq === 'monthly') {
		for (let k = 0; k < 12 * 100; k += 1) {
			const month = first.getUTCMonth() + k;
			const year = first.getUTCFullYear() + Math.floor(month / 12);
			const m = month % 12;
			const day = new Date(Date.UTC(year, m, Math.min(first.getUTCDate(), daysInMonth(year, m))));
			const at = atWall(timezone, day, first);
			if (at > floor) return at;
		}
		return null;
	}
	const days = rule.weekdays.length > 0 ? rule.weekdays : [firstWeekday];
	const matches = (day: number, weekday: number) => {
		switch (rule.freq) {
			case 'daily':
				return true;
			case 'weekdays':
				return weekday >= 1 && weekday <= 5;
			case 'weekly':
				return days.includes(weekday);
			case 'biweekly':
				return days.includes(weekday) && Math.floor((day - (firstDay - firstWeekday)) / 7) % 2 === 0;
		}
	};
	const begin = Math.max(firstDay, Math.floor(wallClock(timezone, floor).getTime() / DAY) - 1);
	for (let day = begin; day < begin + 800; day += 1) {
		const date = new Date(day * DAY);
		if (!matches(day, date.getUTCDay())) continue;
		const at = atWall(timezone, date, first);
		if (at > floor) return at;
	}
	return null;
}

/** The rule in words, the way the app shows it: "Weekly on Mon at 10:00". The time is the zone's own clock. */
export function describe(rule: Rule, anchor: number): string {
	const first = wallClock(rule.timezone, anchor);
	const time = `${String(first.getUTCHours()).padStart(2, '0')}:${String(first.getUTCMinutes()).padStart(2, '0')}`;
	const on = (rule.weekdays.length > 0 ? rule.weekdays : [first.getUTCDay()]).map((d) => NAMES[d]).join(', ');
	switch (rule.freq) {
		case 'daily':
			return `Daily at ${time}`;
		case 'weekdays':
			return `Weekdays at ${time}`;
		case 'weekly':
			return `Weekly on ${on} at ${time}`;
		case 'biweekly':
			return `Every 2 weeks on ${on} at ${time}`;
		case 'monthly':
			return `Monthly on day ${first.getUTCDate()} at ${time}`;
	}
}
