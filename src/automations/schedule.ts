export type Schedule =
	| { kind: 'manual' }
	| { kind: 'every'; ms: number }
	| {
			kind: 'cron';
			minute: Set<number>;
			hour: Set<number>;
			dom: Set<number>;
			month: Set<number>;
			dow: Set<number>;
			domAny: boolean;
			dowAny: boolean;
	  };

const ALIASES: Record<string, string> = {
	'@hourly': '0 * * * *',
	'@daily': '0 0 * * *',
	'@weekly': '0 0 * * 0',
	'@monthly': '0 0 1 * *',
	'@weekdays': '0 9 * * 1-5',
};

const UNITS: Record<string, number> = { s: 1_000, m: 60_000, h: 3_600_000, d: 86_400_000 };

function field(raw: string, min: number, max: number, name: string): Set<number> {
	const values = new Set<number>();
	for (const part of raw.split(',')) {
		if (part === '') throw new Error(`empty entry in ${name}: ${raw}`);
		const [range = '', stepRaw] = part.split('/');
		const step = stepRaw === undefined ? 1 : Number(stepRaw);
		if (!Number.isInteger(step) || step < 1) throw new Error(`bad step in ${name}: ${part}`);
		let lo = min;
		let hi = max;
		if (range !== '*') {
			const [a, b] = range.split('-');
			lo = Number(a);
			hi = b === undefined ? (stepRaw === undefined ? lo : max) : Number(b);
		}
		if (!Number.isInteger(lo) || !Number.isInteger(hi) || lo < min || hi > max || lo > hi) {
			throw new Error(`bad ${name}: ${part} (allowed ${min}-${max})`);
		}
		for (let v = lo; v <= hi; v += step) values.add(v);
	}
	return values;
}

export function parseSchedule(input: string): Schedule {
	const text = input.trim().toLowerCase();
	if (text === 'manual' || text === '') return { kind: 'manual' };
	const every = /^@every\s+(\d+)\s*([smhd])$/.exec(text);
	if (every !== null) {
		const ms = Number(every[1]) * UNITS[every[2]!]!;
		if (ms < 10_000) throw new Error('@every must be at least 10s');
		return { kind: 'every', ms };
	}
	const parts = (ALIASES[text] ?? text).split(/\s+/);
	if (parts.length !== 5) throw new Error(`expected 5 cron fields, @alias, @every or manual: ${input}`);
	const [m, h, dom, mon, dow] = parts as [string, string, string, string, string];
	const dowSet = field(dow, 0, 7, 'day-of-week');
	if (dowSet.delete(7)) dowSet.add(0);
	return {
		kind: 'cron',
		minute: field(m, 0, 59, 'minute'),
		hour: field(h, 0, 23, 'hour'),
		dom: field(dom, 1, 31, 'day-of-month'),
		month: field(mon, 1, 12, 'month'),
		dow: dowSet,
		domAny: dom === '*',
		dowAny: dow === '*',
	};
}

function matchesDay(schedule: Extract<Schedule, { kind: 'cron' }>, date: Date): boolean {
	if (!schedule.month.has(date.getUTCMonth() + 1)) return false;
	const domHit = schedule.dom.has(date.getUTCDate());
	const dowHit = schedule.dow.has(date.getUTCDay());
	if (schedule.domAny || schedule.dowAny) return domHit && dowHit;
	return domHit || dowHit;
}

export function matches(schedule: Extract<Schedule, { kind: 'cron' }>, date: Date): boolean {
	return schedule.minute.has(date.getUTCMinutes()) && schedule.hour.has(date.getUTCHours()) && matchesDay(schedule, date);
}

export function nextRun(schedule: Schedule, after: Date, lastRun: Date | null = null): Date | null {
	if (schedule.kind === 'manual') return null;
	if (schedule.kind === 'every') {
		return lastRun === null ? after : new Date(lastRun.getTime() + schedule.ms);
	}
	const cursor = new Date(after.getTime());
	cursor.setUTCSeconds(0, 0);
	if (cursor.getTime() <= after.getTime()) cursor.setUTCMinutes(cursor.getUTCMinutes() + 1);
	const end = new Date(cursor.getTime());
	end.setUTCFullYear(end.getUTCFullYear() + 8);
	while (cursor < end) {
		if (!matchesDay(schedule, cursor)) cursor.setUTCHours(24, 0);
		else if (!schedule.hour.has(cursor.getUTCHours())) cursor.setUTCHours(cursor.getUTCHours() + 1, 0);
		else if (schedule.minute.has(cursor.getUTCMinutes())) return cursor;
		else cursor.setUTCMinutes(cursor.getUTCMinutes() + 1);
	}
	return null;
}
