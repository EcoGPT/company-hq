#!/usr/bin/env bun
import { existsSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { boot } from '../src/boot';
import { envString, localUrl } from '../src/config';
import { verifySecret } from '../src/connectors/define';
import { createVaultKey, vaultKeyPath } from '../src/connectors/vault';
import { normalizePublicUrl } from '../src/hq';
import { resilienceFromEnv } from '../src/llm';
import { welcome } from './welcome';
import { choiceFromFlags, chooseModel, ollamaModels, upsertEnv } from './setup-model';
import { appFiles, automationFile, connectorFile, names, register, SLUG } from './scaffold';

const [command = 'help', ...rest] = process.argv.slice(2);

function flag(name: string): string | undefined {
	const i = rest.indexOf(`--${name}`);
	return i === -1 ? undefined : rest[i + 1];
}

const has = (name: string) => rest.includes(`--${name}`);
const VALUE_FLAGS = new Set([
	'--name',
	'--handle',
	'--label',
	'--app',
	'--base-url',
	'--as',
	'--provider',
	'--model',
	'--api-key',
	'--description',
]);
const positional = () => rest.filter((arg, i) => !arg.startsWith('--') && !VALUE_FLAGS.has(rest[i - 1] ?? ''));
const root = process.env.HQ_ROOT ?? join(import.meta.dir, '..');
const url = () => normalizePublicUrl(process.env.HQ_PUBLIC_URL) ?? localUrl(process.env);
const signIn = (secret: string) => `  Server  ${url()}\n  Key     ${secret}`;

function readSecret(): string {
	if (!process.stdin.isTTY) return (prompt('') ?? '').trim();
	Bun.spawnSync(['stty', '-echo'], { stdin: 'inherit' });
	try {
		return (prompt('') ?? '').trim();
	} finally {
		Bun.spawnSync(['stty', 'echo'], { stdin: 'inherit' });
		process.stderr.write('\n');
	}
}

type Command = { usage: string; summary: string; run(): Promise<void> | void };

const usageError = (name: string) => new Error(`Usage: bun hq ${commands[name]!.usage}`);

const commands: Record<string, Command> = {
	setup: {
		usage: 'setup [--name "Ada Lovelace"] [--handle ada] [--provider ollama|anthropic] [--model m] [--base-url u] [--api-key k]',
		summary: 'Create .env, pick a model, and make the first admin.',
		async run() {
			if (!existsSync('.env')) {
				await Bun.write('.env', existsSync('.env.example') ? await Bun.file('.env.example').text() : '');
			}
			if (envString(process.env, 'HQ_VAULT_KEY', '') === '') {
				const dbPath = envString(process.env, 'HQ_DB', 'data/hq.sqlite');
				if (dbPath !== ':memory:') {
					mkdirSync(dirname(dbPath), { recursive: true });
					if (createVaultKey(dbPath) !== null) console.log(`Wrote a fresh vault key to ${vaultKeyPath(dbPath)}.`);
				}
			}
			if (process.env.HQ_LLM_MODEL === undefined || process.env.HQ_LLM_MODEL === '') {
				const choice =
					choiceFromFlags(flag) ??
					(process.stdin.isTTY
						? await chooseModel(
								(q) => prompt(q),
								(line) => console.log(line),
								await ollamaModels(),
							)
						: null);
				if (choice !== null) {
					await Bun.write('.env', upsertEnv(await Bun.file('.env').text(), choice));
					for (const [key, value] of Object.entries(choice)) if (value !== undefined && value !== '') process.env[key] = value;
					console.log(`Saved the model to .env: ${choice.HQ_LLM_MODEL}`);
				} else if (!process.stdin.isTTY) {
					console.log('No model chosen: the assistant runs on an offline echo model until you set HQ_LLM_* in .env.');
				}
			}
			const { hq, config, provider } = boot();
			if (hq.hub.people.list().some((p) => p.role === 'admin')) {
				console.log('HQ already has an admin. Use `bun hq invite <handle>` to add people.');
				return;
			}
			const handle = flag('handle') ?? (process.env.USER ?? 'admin').toLowerCase().replace(/[^a-z0-9_-]/g, '');
			const person = hq.hub.people.create({ name: flag('name') ?? handle, handle, role: 'admin' });
			hq.hub.conversations.addMember(hq.hub.general().id, person.id);
			const { secret } = hq.hub.keys.mint(person.id, 'setup');
			hq.hub.messages.send({
				conversationId: hq.hub.general().id,
				authorId: hq.assistant.self.id,
				body: welcome(
					person.name,
					config.assistant.handle,
					provider.id === 'mock' ? null : (config.assistant.model ?? provider.defaultModel ?? null),
				),
			});
			console.log(
				`\nYou are @${person.handle} (admin). Sign in from the HQ app with this server and key (the key is private):\n\n${signIn(secret)}\n\nNext: \`bun dev\`, then enter them in the app. Lost the key? \`bun hq invite ${person.handle}\` makes a new one and ends this one.`,
			);
		},
	},
	invite: {
		usage: 'invite <handle> [--name "Bo Chen"] [--admin] [--service]',
		summary: 'Add a person, or give someone a new key, and print the server and key they sign in with.',
		run() {
			const handle = positional()[0]?.replace(/^@/, '');
			if (handle === undefined) throw usageError('invite');
			const { hq } = boot();
			const existing = hq.hub.people.byHandle(handle);
			if (existing !== null && (has('admin') || has('service') || flag('name') !== undefined)) {
				throw new Error(`@${handle} already exists. Run it without --name, --admin or --service to send a new key.`);
			}
			const person =
				existing ??
				hq.hub.people.create({
					name: flag('name') ?? handle,
					handle,
					role: has('admin') ? 'admin' : 'member',
					kind: has('service') ? 'service' : 'human',
				});
			if (existing === null && person.kind === 'human') hq.hub.conversations.addMember(hq.hub.general().id, person.id);
			if (person.removed_at !== null) throw new Error(`@${person.handle} was removed. Restore them from Settings first.`);
			// The newest invite is the only sign-in key, and it ends a setup key too. It signs in devices (a Mac and a phone, say) and nothing else.
			hq.hub.keys.revokeSignIn(person.id);
			const { secret } = hq.hub.keys.mint(person.id, 'invite');
			const days = hq.hub.keys.inviteTtlDays;
			console.log(
				`${existing === null ? `@${person.handle} added.` : `New key for @${person.handle}.`} Send them this server and key for the HQ app. They can add each of their devices with it${days > 0 ? ` for ${days} days; after that, run this again for a new one` : ''}:\n\n${signIn(secret)}`,
			);
		},
	},
	key: {
		usage: 'key <handle> [--label laptop]',
		summary: 'Mint an API key for someone, for MCP or scripts (it cannot sign a device in; use invite for that).',
		run() {
			const [handle] = positional();
			if (handle === undefined) throw usageError('key');
			const { hq } = boot();
			const person = hq.hub.people.byHandle(handle.replace(/^@/, ''));
			if (person === null) throw new Error(`Nobody has the handle @${handle.replace(/^@/, '')}.`);
			if (person.removed_at !== null) throw new Error(`@${person.handle} was removed. Restore them from Settings first.`);
			// The label is a name to read later; it never changes what the key may do.
			console.log(hq.hub.keys.mint(person.id, 'key', { label: flag('label') ?? 'cli' }).secret);
		},
	},
	revoke: {
		usage: 'revoke <handle>',
		summary: "Revoke all of someone's keys and devices. Their open sessions end within a minute.",
		run() {
			const [handle] = positional();
			if (handle === undefined) throw usageError('revoke');
			const { hq } = boot();
			const person = hq.hub.people.byHandle(handle.replace(/^@/, ''));
			if (person === null) throw new Error(`Nobody has the handle @${handle.replace(/^@/, '')}.`);
			const count = hq.hub.keys.revokeAll(person.id);
			console.log(
				count === 0
					? `@${person.handle} had no active keys.`
					: `Revoked ${count} key${count === 1 ? '' : 's'} for @${person.handle}.`,
			);
		},
	},

	connect: {
		usage: 'connect [connector]',
		summary: 'List connectors, or store a secret (typed hidden, or piped on stdin).',
		async run() {
			const [slug] = positional();
			const { hq, config } = boot();
			const connectors = config.connectors ?? [];
			if (slug === undefined) {
				if (!hq.vault.enabled) console.log('The vault is off: run bun hq setup to make a key, or set HQ_VAULT_KEY.\n');
				for (const c of connectors) {
					console.log(`  ${c.slug.padEnd(16)} ${hq.vault.has(c.slug) ? 'connected    ' : 'not connected'}  ${c.description}`);
				}
				console.log('\nbun hq connect <connector> to add a secret, bun hq disconnect <connector> to remove one.');
				return;
			}
			const connector = connectors.find((c) => c.slug === slug);
			if (connector === undefined) {
				throw new Error(`Unknown connector ${slug}. Available: ${connectors.map((c) => c.slug).join(', ') || 'none'}.`);
			}
			if (connector.secretHelp) console.error(connector.secretHelp);
			const what = /secret$/i.test(connector.name) ? connector.name : `${connector.name} secret`;
			console.error(`Paste the ${what} and press Enter${process.stdin.isTTY ? ' (it stays hidden)' : ''}:`);
			const secret = readSecret();
			if (secret === '') throw new Error('No secret given.');
			const warning = await verifySecret(connector, secret);
			if (warning !== null) console.error(warning);
			await hq.vault.set(connector.slug, secret);
			console.log(`${connector.name} connected. Its tools are live on the next turn.`);
		},
	},
	disconnect: {
		usage: 'disconnect <connector>',
		summary: 'Remove a connector secret.',
		run() {
			const [slug] = positional();
			if (slug === undefined) throw usageError('disconnect');
			const { hq, config } = boot();
			const connector = (config.connectors ?? []).find((c) => c.slug === slug);
			if (connector === undefined) throw new Error(`Unknown connector ${slug}. Run \`bun hq connect\` to list them.`);
			console.log(hq.vault.remove(connector.slug) ? `${connector.name} disconnected.` : `${connector.name} was not connected.`);
		},
	},
	new: {
		usage: 'new app|automation|connector <slug> [--description "..."] [--app <app>] [--base-url <url>]',
		summary: 'Scaffold an app, automation or connector and register it.',
		async run() {
			const [kind, slug] = positional();
			if (slug === undefined || !SLUG.test(slug)) throw usageError('new');
			const configPath = join(root, 'hq.config.ts');
			const write = async (path: string, text: string) => {
				if (existsSync(path)) throw new Error(`${path.slice(root.length + 1)} already exists.`);
				await Bun.write(path, text);
				console.log(`  created ${path.slice(root.length + 1)}`);
			};
			if (kind === 'app') {
				const config = register(await Bun.file(configPath).text(), 'apps', names.camel(slug), `./apps/${slug}/app`);
				const dir = join(root, 'apps', slug);
				if (existsSync(dir)) throw new Error(`apps/${slug} already exists.`);
				mkdirSync(dir, { recursive: true });
				for (const [file, text] of Object.entries(appFiles(slug, flag('description')))) await write(join(dir, file), text);
				await Bun.write(configPath, config);
				console.log(`  registered in hq.config.ts\n\nNext: edit apps/${slug}/app.ts, then \`bun test apps/${slug}\`.`);
			} else if (kind === 'automation') {
				const app = flag('app');
				if (app === undefined) throw new Error('Which app owns it? Pass --app <slug>.');
				const appPath = join(root, 'apps', app, 'app.ts');
				if (!existsSync(appPath)) throw new Error(`No app at apps/${app}.`);
				const source = register(await Bun.file(appPath).text(), 'automations', names.camel(slug), `./automations/${slug}`);
				mkdirSync(join(root, 'apps', app, 'automations'), { recursive: true });
				await write(join(root, 'apps', app, 'automations', `${slug}.ts`), automationFile(slug));
				await Bun.write(appPath, source);
				console.log(
					`  registered in apps/${app}/app.ts\n\nRun it now with: curl -XPOST -H "authorization: Bearer $KEY" ${url()}/v1/automations/${app}/${slug}/run`,
				);
			} else if (kind === 'connector') {
				const config = register(await Bun.file(configPath).text(), 'connectors', names.camel(slug), `./connectors/${slug}`);
				await write(join(root, 'connectors', `${slug}.ts`), connectorFile(slug, flag('base-url') ?? `https://api.${slug}.com`));
				await Bun.write(configPath, config);
				console.log(`  registered in hq.config.ts\n\nNext: bun hq connect ${slug}`);
			} else {
				throw usageError('new');
			}
		},
	},
	chat: {
		usage: 'chat [--as <handle>] [--room]',
		summary: 'Talk to the assistant from the terminal.',
		async run() {
			const { hq, config, provider } = boot();
			const handle = flag('as')?.replace(/^@/, '');
			const me =
				handle === undefined
					? hq.hub.people.list().find((p) => p.role === 'admin' && p.kind === 'human')
					: hq.hub.people.byHandle(handle);
			if (me === null) throw new Error(`Nobody has the handle @${handle}.`);
			if (me === undefined) throw new Error('Nobody to chat as. Run `bun hq setup` first, or pass --as <handle>.');
			const self = hq.assistant.self;
			const conversation = has('room')
				? hq.hub.conversations.createRoom({ title: `cli ${new Date().toISOString().slice(0, 16)}`, createdBy: me.id })
				: hq.hub.conversations.dm(me.id, self.id);
			const tag = has('room') ? `@${self.handle} ` : '';
			hq.hub.bus.on((event) => {
				if (event.type === 'assistant.state' && event.conversationId === conversation.id && event.label !== null) {
					process.stdout.write(`\x1b[2m  ${event.label.toLowerCase()}…\x1b[0m\n`);
				}
				if (
					event.type === 'message.created' &&
					event.message.conversation_id === conversation.id &&
					event.message.author_id === self.id
				) {
					console.log(`\n\x1b[1m${config.assistant.name}\x1b[0m ${event.message.body}\n`);
				}
			});
			console.log(`Chatting with ${config.assistant.name} as @${me.handle} on ${provider.id}. Ctrl-D to quit.\n`);
			process.stdout.write('> ');
			for await (const line of console) {
				if (line.trim() !== '') {
					hq.hub.messages.send({ conversationId: conversation.id, authorId: me.id, body: tag + line });
					await hq.assistant.runner.idle();
				}
				process.stdout.write('> ');
			}
		},
	},
	doctor: {
		usage: 'doctor',
		summary: 'Show the model, apps, tools, automations, connectors and recent usage.',
		run() {
			const { hq, config, provider, dbPath } = boot();
			const ctx = { hub: hq.hub, caller: hq.assistant.self };
			const model = config.assistant.model ?? provider.defaultModel ?? 'none (set HQ_LLM_MODEL)';
			console.log(`database    ${dbPath}`);
			console.log(`model       ${provider.id} · ${model}`);
			const resilience = resilienceFromEnv(process.env);
			const fallback = (resilience.fallback ?? []).map((f) => f.model).join(' → ') || 'none';
			const timeout = resilience.timeoutMs ? `${resilience.timeoutMs / 1000}s` : 'off';
			console.log(`            timeout ${timeout} · ${resilience.retries} retries · fallback ${fallback}`);
			const capabilities: Record<string, [string, string]> = {
				embed: ['embeddings', 'HQ_EMBED_MODEL'],
				transcribe: ['speech', 'HQ_STT_MODEL'],
			};
			for (const [capability, info] of Object.entries(hq.ai.describe())) {
				const [label, hint] = capabilities[capability] ?? [];
				if (label === undefined) continue;
				console.log(
					`${label.padEnd(12)}${info === null ? `off (set ${hint})` : `${info.provider} · ${info.model ?? '(no default model)'}`}`,
				);
			}
			console.log(`assistant   ${config.assistant.name} (@${config.assistant.handle}), replies to ${config.assistant.replyIn}`);
			console.log(`people      ${hq.hub.people.list().length}`);
			console.log(`vault       ${hq.vault.enabled ? 'on' : 'off (run bun hq setup or set HQ_VAULT_KEY)'}`);
			console.log('\napps');
			for (const app of config.apps ?? []) {
				const tools = (app.tools ?? []).map((t) => t.name).join(', ') || 'none';
				const jobs = (app.automations ?? []).map((a) => `${a.slug} (${a.schedule})`).join(', ') || 'none';
				console.log(`  ${app.slug.padEnd(12)} tools: ${tools}\n  ${''.padEnd(12)} automations: ${jobs}`);
			}
			console.log('\nconnectors');
			for (const c of config.connectors ?? [])
				console.log(`  ${c.slug.padEnd(12)} ${hq.vault.has(c.slug) ? 'connected' : 'not connected'}`);
			const totals = hq.usage.totals(7);
			console.log('\nusage (7 days)');
			if (totals.length === 0) console.log('  none yet');
			for (const t of totals) {
				const failed = t.failures > 0 ? ` (${t.failures} failed)` : '';
				const tokens =
					t.input_tokens + t.output_tokens > 0
						? ` · ${t.input_tokens.toLocaleString()} in / ${t.output_tokens.toLocaleString()} out tokens`
						: '';
				console.log(`  ${t.capability.padEnd(12)} ${t.provider} · ${t.model}: ${t.calls} calls${failed}${tokens}`);
			}
			const live = hq.registry.specs('assistant', ctx).map((t) => t.name);
			console.log(`\n${live.length} tools live for the assistant: ${live.join(', ')}`);
		},
	},
};

function help() {
	const lines = Object.values(commands).map(({ usage, summary }) => `  ${usage}\n      ${summary}`);
	return `Usage: bun hq <command>\n\n${lines.join('\n\n')}\n`;
}

async function main() {
	const entry = commands[command];
	if (entry !== undefined && (has('help') || rest.includes('-h')))
		return console.log(`Usage: bun hq ${entry.usage}\n\n${entry.summary}`);
	if (entry !== undefined) return entry.run();
	if (['help', '--help', '-h'].includes(command)) return console.log(help());
	console.error(`Unknown command: ${command}\n`);
	console.error(help());
	process.exit(1);
}

main().then(
	() => process.exit(0),
	(error) => {
		console.error(error instanceof Error ? error.message : error);
		process.exit(1);
	},
);
