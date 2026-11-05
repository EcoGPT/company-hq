import { wire } from '../../test/wire-fixture';

/**
 * For tests: what is wrong with `value` as the app's Swift struct `name` would decode it, from the fixture files. A key the
 * app does not decode, a missing or null key it requires, a time that is not ISO 8601, and the same for nested structs.
 */
export function decodeProblems(name: string, value: unknown, path = name): string[] {
	const spec = wire.structs[name];
	if (spec === undefined) return [`${path}: the fixture has no struct ${name}`];
	if (typeof value !== 'object' || value === null || Array.isArray(value)) return [`${path}: expected an object`];
	const object = value as Record<string, unknown>;
	const problems: string[] = [];
	for (const key of Object.keys(object)) {
		if (key !== 'type' && !(key in spec)) problems.push(`${path}.${key}: the app does not decode this`);
	}
	for (const [key, field] of Object.entries(spec)) {
		const present = object[key];
		if (present === undefined || present === null) {
			if (field.required) problems.push(`${path}.${key}: the app requires this`);
			continue;
		}
		if (key.endsWith('_at') && Number.isNaN(Date.parse(String(present)))) problems.push(`${path}.${key}: not an ISO time`);
		if (field.of === undefined) continue;
		if (!field.list) problems.push(...decodeProblems(field.of, present, `${path}.${key}`));
		else if (!Array.isArray(present)) problems.push(`${path}.${key}: expected a list`);
		else present.forEach((item, i) => problems.push(...decodeProblems(field.of!, item, `${path}.${key}[${i}]`)));
	}
	return problems;
}
