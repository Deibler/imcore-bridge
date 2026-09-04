import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs";

import { MESSAGES_BINARY, defaultDylibPath, packageRoot } from "./paths.js";
import { BridgeUnavailableError } from "./errors.js";
import { ImcoreBridge } from "./client.js";
import type { ClientOptions } from "./types.js";

const execFileAsync = promisify(execFile);

/** Whether Messages.app is currently running. */
export async function isMessagesRunning(): Promise<boolean> {
  try {
    await execFileAsync("pgrep", ["-f", "Contents/MacOS/Messages$"]);
    return true;
  } catch {
    return false;
  }
}

/** Quits Messages.app, falling back to a signal if it ignores the request. */
export async function quitMessages(timeoutMs = 10_000): Promise<void> {
  try {
    await execFileAsync("osascript", ["-e", 'tell application "Messages" to quit']);
  } catch {
    /* not running, or refused — the fallback below handles it */
  }

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!(await isMessagesRunning())) return;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  try {
    await execFileAsync("pkill", ["-f", "Contents/MacOS/Messages$"]);
  } catch {
    /* nothing left to kill */
  }
  await new Promise((resolve) => setTimeout(resolve, 1000));
}

export interface LaunchOptions extends ClientOptions {
  /** Path to the dylib. Defaults to the one built into this package. */
  dylibPath?: string;
  /** Quit an already-running Messages.app first. Defaults to true. */
  restart?: boolean;
  /** How long to wait for the bridge to connect. Defaults to 30000. */
  launchTimeoutMs?: number;
}

export interface InjectOptions {
  /** Path to the dylib. Defaults to the one built into this package. */
  dylibPath?: string;
  /** Quit an already-running Messages.app first. Defaults to true. */
  restart?: boolean;
  /**
   * Refuse every send that targets this account's own address. A host driving
   * its own account as an agent has no legitimate self-traffic — anything
   * landing in its own thread is a bug's output — while a person's
   * note-to-self is real use, which is why this is opt-in. Carried to the
   * injected code through its environment, so it applies from the next
   * (re)launch, not to an adopted Messages.
   */
  blockSelfSends?: boolean;
}

/**
 * Resolves the dylib path and fails early if it is not there.
 *
 * Called before the socket is created so a missing dylib does not leave a
 * socket file behind for the next run's `bind()` to trip over.
 */
function resolveDylib(dylibPath?: string): string {
  const resolved = dylibPath ?? defaultDylibPath(packageRoot());
  if (!fs.existsSync(resolved)) {
    throw new BridgeUnavailableError(
      `dylib not found at ${resolved} — run \`npm run build:native\` first`,
    );
  }
  return resolved;
}

/**
 * Spawns Messages.app with the bridge injected and returns without waiting.
 *
 * Messages is exec'd directly rather than opened through LaunchServices:
 * `open` strips `DYLD_*` from the environment, so the dylib would never load.
 *
 * The caller must already own the socket. The injected code dials out as soon
 * as IMCore is up, and although it retries, a listener that is already there
 * turns a relaunch into one dial rather than a wait on the backoff.
 */
export async function injectMessages(options: InjectOptions = {}): Promise<void> {
  const dylibPath = resolveDylib(options.dylibPath);

  if (options.restart !== false && (await isMessagesRunning())) {
    await quitMessages();
  }

  const env: NodeJS.ProcessEnv = { ...process.env, DYLD_INSERT_LIBRARIES: dylibPath };
  if (options.blockSelfSends) env.IMCORE_BRIDGE_BLOCK_SELF_SENDS = "1";

  const child = spawn(MESSAGES_BINARY, [], {
    env,
    detached: true,
    stdio: "ignore",
  });
  child.unref();
}

/**
 * Relaunches Messages.app with the bridge injected, and waits for it to
 * connect.
 *
 * One-shot: it owns a socket, injects, and hands back a connected bridge. For
 * a long-running host that needs the bridge to stay up — across a Messages
 * crash, a user quitting it, or the injected code going unresponsive — use
 * {@link supervise} instead.
 */
export async function launch(options: LaunchOptions = {}): Promise<ImcoreBridge> {
  const dylibPath = resolveDylib(options.dylibPath);

  // Own the socket before injecting, so the bridge finds it on its first dial.
  const bridge = await ImcoreBridge.listenOnly(options);

  try {
    await injectMessages({ dylibPath, restart: options.restart });
  } catch (error) {
    await bridge.close();
    throw error;
  }

  const timeoutMs = options.launchTimeoutMs ?? 30_000;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (bridge.isConnected) return bridge;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  await bridge.close();
  throw new BridgeUnavailableError(
    `Messages.app did not connect within ${timeoutMs}ms. Either the dylib did not ` +
      `load — check that SIP is disabled and boot-args contains ` +
      `amfi_get_out_of_my_way=0x1 — or it dialled a different host on ` +
      `${bridge.socketPath}; \`lsof\` that path to see who holds it.`,
  );
}
