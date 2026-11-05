export type Env = Record<string, string | undefined>;

export function envString(env: Env, name: string, fallback: string): string {
	const value = env[name]?.trim();
	return value === undefined || value === '' ? fallback : value;
}

export function envNumber(env: Env, name: string, fallback: number): number {
	const raw = envString(env, name, '');
	const value = Number(raw);
	return raw === '' || !Number.isFinite(value) ? fallback : value;
}

export function listenAddress(env: Env): { hostname: string; port: number } {
	return { hostname: envString(env, 'HQ_HOST', '127.0.0.1'), port: envNumber(env, 'PORT', 8787) };
}

const LOCAL_HOSTS = new Set(['0.0.0.0', '::', '127.0.0.1', '::1', 'localhost']);

export function localUrl(env: Env, port = listenAddress(env).port): string {
	const { hostname } = listenAddress(env);
	const host = LOCAL_HOSTS.has(hostname) ? 'localhost' : hostname.includes(':') ? `[${hostname}]` : hostname;
	return `http://${host}:${port}`;
}
