import { EventEmitter } from "node:events";

import { ImcoreBridge } from "./client.js";
import { injectMessages, type InjectOptions } from "./launch.js";
import type { ClientOptions } from "./types.js";

export interface SuperviseOptions extends ClientOptions {
  /** Path to the dylib. Defaults to the one built into this package. */
  dylibPath?: string;
  /**
   * Refuse every send targeting this account's own address. Applied to each
   * relaunch this supervisor performs. See {@link InjectOptions.blockSelfSends}.
   */
  blockSelfSends?: boolean;
  /**
   * How long to wait for an already-injected Messages.app to dial in before
   * relaunching it. Defaults to 8000, just over the injected side's 5s
   * reconnect ceiling.
   */
  adoptTimeoutMs?: number;
  /** How long a relaunched Messages.app has to hand shake. Defaults to 30000. */
  launchTimeoutMs?: number;
  /**
   * How often to prove a connected bridge still answers. Defaults to 30000.
   * Zero disables liveness probing, leaving only socket closes to act on.
   */
  healthIntervalMs?: number;
  /** How long a probe may take before it counts as missed. Defaults to 5000. */
  healthTimeoutMs?: number;
  /** Consecutive missed probes before Messages is relaunched. Defaults to 2. */
  healthFailureThreshold?: number;
  /** Delay before the first relaunch retry, doubling from there. Defaults to 2000. */
  minBackoffMs?: number;
  /** Ceiling for the relaunch backoff. Defaults to 60000. */
  maxBackoffMs?: number;
  /** Replaces the injection step. For tests; defaults to {@link injectMessages}. */
  inject?: (options: InjectOptions) => Promise<void>;
}

/**
 * Keeps an injected Messages.app connected for as long as the host runs.
 *
 * The client already survives Messages restarting on its own: the socket stays
 * listening and the injected side re-dials with backoff. Two things it cannot
 * do alone are what this adds.
 *
 * The first is bringing Messages back when nothing else will — it crashed, the
 * user quit it, or it is running without the dylib and so will never dial.
 *
 * The second is the failure that motivated this: the socket stays open and
 * `isConnected` keeps reporting true while the injected side has stopped
 * answering. Every call then burns its full timeout before failing, and
 * because the connection never dropped there is no close to react to. Only
 * asking — periodically, with a short deadline — distinguishes a quiet bridge
 * from a wedged one, and only relaunching Messages clears it.
 *
 * Relaunches are serialised and backed off, so a Messages that refuses to come
 * up is retried at a widening interval rather than in a loop.
 */
export class Supervisor extends EventEmitter {
  /**
   * The supervised bridge. Stable across relaunches — the socket outlives
   * Messages, so long-lived consumers such as `events()` keep working and do
   * not need to resubscribe.
   */
  readonly bridge: ImcoreBridge;

  private readonly options: SuperviseOptions;
  private readonly inject: (options: InjectOptions) => Promise<void>;
  private readonly healthIntervalMs: number;
  private readonly healthTimeoutMs: number;
  private readonly healthFailureThreshold: number;
  private readonly minBackoffMs: number;
  private readonly maxBackoffMs: number;

  private healthTimer?: NodeJS.Timeout;
  private cycle?: Promise<void>;
  private probing = false;
  private missed = 0;
  private backoffMs: number;
  private sleepTimer?: NodeJS.Timeout;
  private wakeSleep?: () => void;
  private stopped = false;
  /** Monotonic hello count. A relaunch must observe a newer handshake, not
   * merely an old socket whose close event has not reached this process yet. */
  private connectionGeneration = 0;

  /** @internal Use {@link supervise}. */
  constructor(bridge: ImcoreBridge, options: SuperviseOptions) {
    super();
    this.bridge = bridge;
    this.options = options;
    this.inject = options.inject ?? injectMessages;
    this.healthIntervalMs = options.healthIntervalMs ?? 30_000;
    this.healthTimeoutMs = options.healthTimeoutMs ?? 5_000;
    this.healthFailureThreshold = options.healthFailureThreshold ?? 2;
    this.minBackoffMs = options.minBackoffMs ?? 2_000;
    this.maxBackoffMs = options.maxBackoffMs ?? 60_000;
    this.backoffMs = this.minBackoffMs;

    this.bridge.on("connected", () => {
      this.connectionGeneration += 1;
      this.missed = 0;
      this.backoffMs = this.minBackoffMs;
    });

    this.bridge.on("disconnected", () => {
      if (this.stopped) return;
      this.emit("disconnected");
      // The injected side re-dials on its own, so a Messages that is merely
      // busy comes back without help. Relaunching is for when it does not:
      // waiting out the adopt window first keeps a live app from being killed
      // for a connection that was about to return.
      void this.relaunch("lost the connection to Messages", {
        adoptFirst: true,
      });
    });
  }

  /** True while an injected Messages.app is connected and handshaken. */
  get isConnected(): boolean {
    return this.bridge.isConnected;
  }

  /**
   * Relaunches Messages.app, unless a relaunch is already running — in which
   * case this joins it rather than starting a second one.
   *
   * Worth calling directly when the host has better evidence than a probe can
   * get: a real send that timed out says the bridge is wedged now, without
   * waiting up to `healthIntervalMs` to find out.
   */
  relaunch(reason: string, options: { adoptFirst?: boolean } = {}): Promise<void> {
    if (this.stopped) return Promise.resolve();
    if (this.cycle) return this.cycle;
    this.cycle = this.runCycle(reason, options.adoptFirst === true).finally(() => {
      this.cycle = undefined;
    });
    return this.cycle;
  }

  /**
   * Stops supervising and releases the socket.
   *
   * Messages.app is left running. It is the user's messaging client, and the
   * host exiting is not a reason to close it.
   */
  async stop(): Promise<void> {
    this.stopped = true;
    if (this.healthTimer) clearInterval(this.healthTimer);
    this.healthTimer = undefined;
    // Cut short a backoff wait so stopping is immediate rather than up to
    // maxBackoffMs away.
    if (this.sleepTimer) clearTimeout(this.sleepTimer);
    this.wakeSleep?.();
    await this.cycle?.catch(() => {});
    await this.bridge.close();
  }

  /** @internal Called by {@link supervise} once listeners are attached. */
  async start(): Promise<void> {
    if (!(await this.waitForConnection(this.options.adoptTimeoutMs ?? 8_000))) {
      await this.relaunch("no injected Messages.app dialled in");
    }
    this.startProbing();
  }

  private startProbing(): void {
    if (this.healthIntervalMs <= 0 || this.healthTimer) return;
    this.healthTimer = setInterval(() => void this.probe(), this.healthIntervalMs);
    // Never a reason on its own to hold the process open.
    this.healthTimer.unref?.();
  }

  private async probe(): Promise<void> {
    // A relaunch in flight already knows the bridge is not serving, and
    // overlapping probes would count one stall as several.
    if (this.stopped || this.cycle || this.probing) return;
    // A closed socket is the disconnect path's to handle.
    if (!this.bridge.isConnected) return;

    this.probing = true;
    try {
      if (await this.answersWithin(this.healthTimeoutMs)) {
        this.missed = 0;
        return;
      }
      this.missed += 1;
      this.emit("unhealthy", this.missed, this.healthFailureThreshold);
      if (this.missed >= this.healthFailureThreshold) {
        const missed = this.missed;
        this.missed = 0;
        await this.relaunch(`bridge stopped answering (${missed} missed probes)`);
      }
    } finally {
      this.probing = false;
    }
  }

  /**
   * Whether `status` comes back inside `timeoutMs`.
   *
   * Raced rather than awaited because the per-request timeout is the client's,
   * and it is deliberately long enough for real sends. A liveness check wants a
   * much shorter deadline. The underlying call is left to settle on its own —
   * both outcomes are handled here, so it cannot surface as an unhandled
   * rejection.
   */
  private answersWithin(timeoutMs: number): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => resolve(false), timeoutMs);
      timer.unref?.();
      this.bridge.status().then(
        () => {
          clearTimeout(timer);
          resolve(true);
        },
        () => {
          clearTimeout(timer);
          resolve(false);
        },
      );
    });
  }

  private async runCycle(reason: string, adoptFirst: boolean): Promise<void> {
    if (adoptFirst) {
      const adoptMs = this.options.adoptTimeoutMs ?? 8_000;
      if (await this.waitForConnection(adoptMs)) return;
    }

    for (let attempt = 1; !this.stopped; attempt += 1) {
      this.emit("relaunching", reason, attempt);
      try {
        const generationBeforeLaunch = this.connectionGeneration;
        await this.inject({
          dylibPath: this.options.dylibPath,
          blockSelfSends: this.options.blockSelfSends,
        });
        if (
          await this.waitForConnection(
            this.options.launchTimeoutMs ?? 30_000,
            generationBeforeLaunch,
          )
        ) {
          this.backoffMs = this.minBackoffMs;
          this.emit("connected", this.bridge.pid);
          return;
        }
        throw new Error(
          "Messages.app did not connect after relaunch. Either the dylib did not " +
            "load — check that SIP is disabled and boot-args contains " +
            "amfi_get_out_of_my_way=0x1 — or something else is on the socket; " +
            `\`lsof ${this.bridge.socketPath}\` shows who holds it.`,
        );
      } catch (error) {
        if (this.stopped) return;
        const retryInMs = this.backoffMs;
        this.backoffMs = Math.min(this.backoffMs * 2, this.maxBackoffMs);
        this.emit("relaunch-failed", error, attempt, retryInMs);
        await this.sleep(retryInMs);
      }
    }
  }

  /**
   * Resolves true as soon as the bridge is connected, false at the deadline.
   * When `afterGeneration` is supplied, only a newer hello qualifies. A stale
   * pre-launch socket can remain apparently connected until Node receives its
   * close event, and accepting it made relaunch report success before the
   * replacement Messages process had connected.
   */
  private waitForConnection(timeoutMs: number, afterGeneration?: number): Promise<boolean> {
    const ready = () =>
      this.bridge.isConnected &&
      (afterGeneration === undefined || this.connectionGeneration > afterGeneration);
    if (ready()) return Promise.resolve(true);
    return new Promise<boolean>((resolve) => {
      const settle = (value: boolean) => {
        clearTimeout(timer);
        this.bridge.off("connected", onConnected);
        resolve(value);
      };
      const onConnected = () => {
        if (ready()) settle(true);
      };
      const timer = setTimeout(() => settle(false), timeoutMs);
      timer.unref?.();
      this.bridge.on("connected", onConnected);
    });
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      this.wakeSleep = resolve;
      this.sleepTimer = setTimeout(resolve, ms);
      this.sleepTimer.unref?.();
    }).then(() => {
      this.sleepTimer = undefined;
      this.wakeSleep = undefined;
    });
  }
}

/**
 * Owns the socket and keeps an injected Messages.app connected to it.
 *
 * An already-injected Messages is adopted rather than restarted, so a host that
 * restarts often does not close the user's app each time it comes up. If
 * nothing dials in within `adoptTimeoutMs`, Messages is relaunched with the
 * dylib inserted.
 *
 * ```ts
 * const supervisor = await supervise();
 * supervisor.on("relaunching", (reason) => console.warn(`bridge: ${reason}`));
 *
 * await supervisor.bridge.send({ chat: "+15551234567", text: "hello" });
 * ```
 */
export async function supervise(options: SuperviseOptions = {}): Promise<Supervisor> {
  const bridge = await ImcoreBridge.listenOnly(options);
  const supervisor = new Supervisor(bridge, options);
  try {
    await supervisor.start();
  } catch (error) {
    await supervisor.stop();
    throw error;
  }
  return supervisor;
}
