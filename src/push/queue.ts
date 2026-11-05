type Task = () => Promise<void> | void;

/**
 * Work that runs after the code that asked for it has finished, a few tasks at a time. `add` never runs a task itself, so
 * whoever calls it (the bus's emit, in the middle of a request) is never held up by the work. When tasks pile up past
 * `maxQueued` the newest are dropped, and `dropped` counts them.
 */
export class WorkQueue {
	dropped = 0;
	private readonly waiting: Task[] = [];
	private running = 0;
	private scheduled = false;
	private halted = false;
	private idleWaiters: (() => void)[] = [];

	constructor(
		private readonly concurrency: number,
		private readonly maxQueued: number,
	) {}

	get stopped(): boolean {
		return this.halted;
	}

	add(task: Task): boolean {
		if (this.halted) return false;
		if (this.waiting.length >= this.maxQueued) {
			this.dropped += 1;
			return false;
		}
		this.waiting.push(task);
		this.schedule();
		return true;
	}

	/** Drops what has not started. Tasks already running finish. */
	stop(): void {
		this.halted = true;
		this.waiting.length = 0;
		this.settle();
	}

	/** Resolves when nothing is waiting, scheduled or running. */
	idle(): Promise<void> {
		if (this.isIdle()) return Promise.resolve();
		return new Promise((resolve) => this.idleWaiters.push(resolve));
	}

	private isIdle(): boolean {
		return this.waiting.length === 0 && this.running === 0 && !this.scheduled;
	}

	private schedule(): void {
		if (this.scheduled) return;
		this.scheduled = true;
		setTimeout(() => {
			this.scheduled = false;
			this.pump();
		}, 0);
	}

	private pump(): void {
		while (this.running < this.concurrency) {
			const task = this.waiting.shift();
			if (task === undefined) break;
			this.running += 1;
			void Promise.resolve()
				.then(task)
				.catch((error: unknown) => console.error('[push] task failed', error))
				.finally(() => {
					this.running -= 1;
					this.pump();
					this.settle();
				});
		}
		this.settle();
	}

	private settle(): void {
		if (!this.isIdle()) return;
		for (const resolve of this.idleWaiters.splice(0)) resolve();
	}
}
