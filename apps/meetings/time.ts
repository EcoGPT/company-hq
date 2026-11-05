import { ToolError } from '@hq/sdk';

const ISO_WITH_OFFSET = /^(\d{4})-(\d{2})-(\d{2})t(\d{2}):(\d{2})(?::(\d{2})(\.\d+)?)?(z|[+-]\d{2}:?\d{2})$/i;

function realDateTime(match: RegExpExecArray): boolean {
	const [y, mo, d, h, mi, s = 0] = match.slice(1, 7).map((part) => (part === undefined ? undefined : Number(part)));
	const day = new Date(Date.UTC(y!, mo! - 1, d!));
	return day.getUTCMonth() === mo! - 1 && day.getUTCDate() === d && h! < 24 && mi! < 60 && s < 60;
}

export function parseTime(raw: string): number {
	const match = ISO_WITH_OFFSET.exec(raw.trim());
	const at = match !== null && realDateTime(match) ? Date.parse(raw.trim()) : Number.NaN;
	if (Number.isNaN(at))
		throw new ToolError(`not a date and time: ${raw} (use ISO 8601 with an offset, like 2026-10-20T15:00:00Z)`);
	return at;
}
