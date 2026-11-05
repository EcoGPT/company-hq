import type { Ai } from '../ai/types';
import type { Hub } from '../core/hub';
import type { Message } from '../core/messages';
import type { Person } from '../core/people';
import type { Migration } from '../db/database';
import type { AutomationDefinition } from '../automations/define';
import type { Access, Method, PublicContext, RequestContext } from '../http/router';
import type { Tool } from '../tools/define';
import type { ToolResult } from '../tools/registry';

export type AssistantApi = {
	self: Person;
	post(conversationId: string, body: string, metadata?: Record<string, unknown>): Message;
	ask(prompt: string, options?: { system?: string }): Promise<string>;
};

export type AppSecrets = {
	has(slug: string): boolean;
	get(slug: string): Promise<string | null>;
};

export type AppTools = {
	has(name: string): boolean;
	call(
		name: string,
		args: unknown,
		options?: { caller?: Person; conversationId?: string; viewers?: string[] },
	): Promise<ToolResult>;
};

export type AppContext = {
	slug: string;
	hub: Hub;
	assistant: AssistantApi;
	secrets: AppSecrets;
	fetch: typeof fetch;
	ai: Ai;
	tools: AppTools;
	emit(name: string, data?: unknown): void;
};

export type AppRequestContext = RequestContext & { app: AppContext };

export type AppPublicContext = PublicContext & { app: AppContext };

/**
 * Where a route is served. `'api'` (the default) puts `path` under `/apps/<slug>/api/`. `'v1'` serves it at `path` itself,
 * which must start with `/v1/`, so an app can own part of the app protocol. It is held to what core `/v1` routes are, or it
 * fails at startup: the same sign-in (so not `access: 'public'`, and an `'admin'` route needs a device, as core's people admin
 * does), a 1 MB body at most (`maxBodyBytes` can only lower that), no path under `/v1/conversations`, `/v1/messages` or
 * `/v1/attachments` (core checks membership there), and nothing that can take a request core or another app's route can.
 */
export type AppRouteMount = 'api' | 'v1';

export type AppRoute =
	| {
			method: Method;
			path: string;
			mount?: AppRouteMount;
			access?: Exclude<Access, 'public'>;
			/** Bodies over this are refused with 413 before the handler runs. 1 MB if left out. */
			maxBodyBytes?: number;
			handler(ctx: AppRequestContext): unknown;
	  }
	| {
			method: Method;
			path: string;
			mount?: AppRouteMount;
			access: 'public';
			maxBodyBytes?: number;
			handler(ctx: AppPublicContext): unknown;
	  };

/** What `GET /v1/calls` answers, already in the shapes the app decodes. Core adds its calls and rings; apps add the rest (meetings). */
export type CallsView = { calls: unknown[]; meetings: unknown[]; ringing: unknown[] };

/** One task on a desktop widget: the fields a task card shows. Dates are ISO with milliseconds. */
export type WidgetTask = {
	id: string;
	number: number | null;
	/** `HQ-<number>`, null for a task with no number. */
	ref: string | null;
	title: string;
	status: 'open' | 'in_progress' | 'blocked';
	project_name: string | null;
	comment_count: number;
	due_at: string | null;
	touched_at: string;
};

/**
 * A person's tasks as the desktop widgets draw them. The counts cover every task the person owes; `tasks` holds at most five
 * per status, in_progress then blocked then open.
 */
export type WidgetWork = {
	in_progress: number;
	open: number;
	blocked: number;
	/** Tasks finished in the last seven days. */
	done_week: number;
	next_due: WidgetTask | null;
	tasks: WidgetTask[];
};

/** Where a meeting's call happens: the meeting, and the room the call is held in. */
export type CallTarget = { meetingId: string; conversationId: string; title: string | null };

/** A meeting call's finished transcript, handed to the app that owns meetings (`callRecap`). */
export type CallRecapInput = {
	callId: string;
	meetingId: string;
	/** The room the call was held in. */
	conversationId: string;
	/** `[m:ss] Name: text` lines. What people said, so untrusted text for a model. */
	transcript: string;
	/** This call was recapped before (a retranscribe): redo the summary, but what the first recap filed is already filed. */
	again: boolean;
	/** Posts as the assistant, once per call: a later recap of the same call edits that message instead. */
	post(conversationId: string, body: string, metadata?: Record<string, unknown>): Message;
};

export type AppDefinition = {
	slug: string;
	name: string;
	description: string;
	icon?: string;
	briefing?: string;
	migrations?: Migration[];
	tools?: Tool[];
	routes?: AppRoute[];
	automations?: AutomationDefinition[];
	/**
	 * What this app adds to `GET /v1/calls` for `person`. It must return only what `person` may see: the snapshot goes to whoever
	 * asks. Lists from every app are joined. A hook that throws, or returns anything but lists, adds none of its lists.
	 */
	calls?(app: AppContext, person: Person): Partial<CallsView>;
	/**
	 * Where `person` joins a meeting's call (`POST /v1/calls` with `kind: "meeting"`). With a `meetingId`: that meeting, if
	 * they may see it, after adding them to its room; null if there is none they can see. With null: a meeting made now
	 * (a Quick Call) with its own room. Throw an `HttpError` to refuse (a cancelled meeting). One app should answer; the
	 * first that has the hook is used. Core never imports an app, so this is how calls reach meetings.
	 */
	callTarget?(app: AppContext, person: Person, meetingId: string | null): CallTarget | null;
	/** Whether this room was opened for a meeting, so a call started in it does not ring (meetings never ring). */
	isMeetingRoom?(app: AppContext, conversationId: string): boolean;
	/**
	 * Recaps a meeting's call once its transcript is written down, posting through `input.post`. Returns the summary the
	 * call keeps, or null. Runs only when a chat model is set up; the first app that has the hook is used.
	 */
	callRecap?(app: AppContext, input: CallRecapInput): Promise<string | null>;
	/**
	 * `person`'s own tasks for the desktop widgets (`GET /v1/widgets/summary`). It must return only tasks `person` may see: the
	 * summary goes to anyone holding their widget key. One app should answer; the first that does is used. A hook that
	 * throws leaves the summary's work empty.
	 */
	widgetWork?(app: AppContext, person: Person): WidgetWork;
	setup?(app: AppContext): void | (() => void);
};

const SLUG = /^[a-z][a-z0-9-]{0,31}$/;

export function defineApp(app: AppDefinition): AppDefinition {
	if (!SLUG.test(app.slug)) throw new Error(`app slugs are kebab-case: ${app.slug}`);
	return app;
}
