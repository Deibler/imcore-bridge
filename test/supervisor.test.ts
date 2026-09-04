import { test, expect, afterEach } from "bun:test";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import { join } from "node:path";

import { Supervisor, supervise } from "../src/supervisor.js";
import type { InjectOptions } from "../src/launch.js";

// The real bridge dials the client and Messages.app is relaunched out of
// process, so the stub plays both: the injected side that dials in, and an
// `inject` that stands in for relaunching the app. That makes supervision
// testable — including the wedge, which is a connection that stays open and
// stops answering, and cannot be reproduced by closing a socket.

let cleanups: (() => void | Promise<void>)[] = [];
afterEach(async () => {
  for (const fn of cleanups.reverse()) await fn();
  cleanups = [];
});

const settle = (ms = 60) => new Promise((r) => setTimeout(r, ms));

interface Stub {
  socketPath: string;
  /** Connects and hand shakes, as the injected side does once IMCore is up. */
  dial(options?: { silent?: boolean }): Promise<void>;
  /** Drops the connection, as a Messages.app that exited would. */
  drop(): void;
  /** Keeps the connection open but stops answering. This is the wedge. */
  silence(): void;
  /** Methods the stub was asked for, in order. */
  requests: string[];
  /** How many times the injected side has dialled in. */
  dials: number;
}

/** Waits for a host to finish binding, so a dial cannot race the bind. */
async function waitForSocket(socketPath: string, attempts = 200): Promise<void> {
  for (let i = 0; i < attempts; i += 1) {
    if (fs.existsSync(socketPath)) return;
    await new Promise((r) => setTimeout(r, 10));
  }
}

/**
 * Connects, retrying briefly.
 *
 * The injected side dials whenever the socket appears rather than in step with
 * the host, so a dial can still arrive mid-bind even after `waitForSocket`.
 */
async function connectWithRetry(socketPath: string, attempts = 50): Promise<net.Socket> {
  for (let attempt = 0; ; attempt += 1) {
    try {
      const socket = net.createConnection(socketPath);
      await new Promise<void>((resolve, reject) => {
        socket.once("connect", () => resolve());
        socket.once("error", reject);
      });
      return socket;
    } catch (error) {
      if (attempt >= attempts) throw error;
      await new Promise((r) => setTimeout(r, 10));
    }
  }
}

function makeStub(): Stub {
  const socketPath = join(fs.mkdtempSync(join(os.tmpdir(), "imcore-sup-")), "bridge.sock");
  const requests: string[] = [];
  let socket: net.Socket | undefined;
  let silent = false;
  let dials = 0;

  const stub: Stub = {
    socketPath,
    requests,
    get dials() {
      return dials;
    },
    async dial(options = {}) {
      // A real relaunch replaces the process, so the old connection goes first.
      socket?.destroy();
      silent = options.silent === true;
      await waitForSocket(socketPath);
      const next = await connectWithRetry(socketPath);
      socket = next;
      dials += 1;
      next.write(
        `${JSON.stringify({
          type: "event",
          event: "hello",
          data: { pid: 4242 + dials, protocol: 1, ready: true, capabilities: { events: true } },
        })}\n`,
      );

      let buffer = "";
      next.on("error", () => next.destroy());
      next.on("data", (chunk) => {
        buffer += chunk.toString();
        let nl: number;
        while ((nl = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, nl);
          buffer = buffer.slice(nl + 1);
          if (!line.trim()) continue;
          const request = JSON.parse(line) as { id: number; method: string };
          requests.push(request.method);
          if (silent) continue;
          next.write(`${JSON.stringify({ id: request.id, ok: true, result: {} })}\n`);
        }
      });
    },
    drop() {
      socket?.destroy();
    },
    silence() {
      silent = true;
    },
  };

  cleanups.push(() => void socket?.destroy());
  return stub;
}

/** An `inject` that records its calls, and optionally dials in as the app would. */
function fakeInject(stub: Stub | null, options: { fail?: number } = {}) {
  const calls: InjectOptions[] = [];
  let failures = options.fail ?? 0;
  const inject = async (opts: InjectOptions) => {
    calls.push(opts);
    if (failures > 0) {
      failures -= 1;
      throw new Error("Messages.app refused to start");
    }
    if (stub) await stub.dial();
  };
  /** Makes the next `n` relaunch attempts fail, from here rather than at setup. */
  const failNext = (n: number) => {
    failures = n;
  };
  return { inject, calls, failNext };
}

async function superviseWith(
  stub: Stub,
  inject: (options: InjectOptions) => Promise<void>,
  overrides: Record<string, number> = {},
): Promise<Supervisor> {
  const supervisor = await supervise({
    socketPath: stub.socketPath,
    inject,
    adoptTimeoutMs: 150,
    launchTimeoutMs: 400,
    healthIntervalMs: 40,
    healthTimeoutMs: 40,
    healthFailureThreshold: 2,
    minBackoffMs: 20,
    maxBackoffMs: 60,
    ...overrides,
  });
  cleanups.push(() => supervisor.stop());
  return supervisor;
}

test("an already-injected Messages is adopted rather than restarted", async () => {
  const stub = makeStub();
  const { inject, calls } = fakeInject(stub);

  // Dials as soon as the socket appears, the way a Messages that is already
  // running with the dylib does — which is while the adopt window is open, not
  // after it closes.
  const supervising = supervise({
    socketPath: stub.socketPath,
    inject,
    adoptTimeoutMs: 1_000,
    healthIntervalMs: 0,
  });
  await stub.dial();
  const supervisor = await supervising;
  cleanups.push(() => supervisor.stop());
  await settle();

  expect(supervisor.isConnected).toBe(true);
  // The user's app was left alone.
  expect(calls).toHaveLength(0);
});

test("Messages is relaunched when nothing dials in", async () => {
  const stub = makeStub();
  const { inject, calls } = fakeInject(stub);

  const supervisor = await superviseWith(stub, inject);
  await settle();

  expect(calls).toHaveLength(1);
  expect(supervisor.isConnected).toBe(true);
});

test("a bridge that stops answering is relaunched", async () => {
  // The failure this exists for: the socket never closed, so nothing dropped,
  // and every call was left to burn its own timeout instead.
  const stub = makeStub();
  const { inject, calls } = fakeInject(stub);
  const supervisor = await superviseWith(stub, inject);
  await settle();
  expect(calls).toHaveLength(1);

  const unhealthy: number[] = [];
  supervisor.on("unhealthy", (missed: number) => unhealthy.push(missed));

  stub.silence();
  await settle(400);

  // It was asked, it did not answer, and it was relaunched.
  expect(stub.requests).toContain("status");
  expect(unhealthy.length).toBeGreaterThanOrEqual(2);
  expect(calls.length).toBeGreaterThanOrEqual(2);
  expect(supervisor.isConnected).toBe(true);
});

test("a bridge that answers is left alone", async () => {
  const stub = makeStub();
  const { inject, calls } = fakeInject(stub);
  const supervisor = await superviseWith(stub, inject);
  await settle();
  expect(calls).toHaveLength(1);

  await settle(300);

  // Probed repeatedly, answered every time, never restarted for it.
  expect(stub.requests.filter((m) => m === "status").length).toBeGreaterThanOrEqual(2);
  expect(calls).toHaveLength(1);
  expect(supervisor.isConnected).toBe(true);
});

test("a connection that comes back on its own does not cost a relaunch", async () => {
  const stub = makeStub();
  const { inject, calls } = fakeInject(stub);
  const supervisor = await superviseWith(stub, inject, { healthIntervalMs: 0 });
  await settle();
  const before = calls.length;

  // The injected side re-dials with backoff; dropping and returning inside the
  // adopt window is that, and must not restart the app.
  stub.drop();
  await settle(20);
  await stub.dial();
  await settle(250);

  expect(calls).toHaveLength(before);
  expect(supervisor.isConnected).toBe(true);
});

test("a relaunch that fails is retried with backoff", async () => {
  const stub = makeStub();
  const { inject, calls, failNext } = fakeInject(stub);
  const supervisor = await superviseWith(stub, inject, { healthIntervalMs: 0 });
  await settle();
  const before = calls.length;

  const failures: { attempt: number; retryInMs: number }[] = [];
  supervisor.on("relaunch-failed", (_err: unknown, attempt: number, retryInMs: number) =>
    failures.push({ attempt, retryInMs }),
  );

  failNext(2);
  await supervisor.relaunch("forced");

  // Two refusals, then it came up — and it kept trying rather than giving up.
  expect(calls).toHaveLength(before + 3);
  expect(failures).toHaveLength(2);
  expect(failures.map((f) => f.attempt)).toEqual([1, 2]);
  // Widening, not fixed.
  expect(failures[1]!.retryInMs).toBeGreaterThan(failures[0]!.retryInMs);
  expect(supervisor.isConnected).toBe(true);
});

test("concurrent relaunches collapse into one", async () => {
  const stub = makeStub();
  const { inject, calls } = fakeInject(stub);
  const supervisor = await superviseWith(stub, inject, { healthIntervalMs: 0 });
  await settle();
  const before = calls.length;

  await Promise.all([
    supervisor.relaunch("first"),
    supervisor.relaunch("second"),
    supervisor.relaunch("third"),
  ]);

  // Three callers, one restart of the user's app.
  expect(calls).toHaveLength(before + 1);
});

test("relaunch waits for a replacement handshake, not the old connection", async () => {
  const stub = makeStub();
  let launches = 0;
  let replacement: Promise<void> | null = null;
  const inject = async () => {
    launches += 1;
    if (launches === 1) {
      await stub.dial();
      return;
    }
    // Real injection can return before the old socket's close event and the
    // replacement Messages process's hello reach the host.
    replacement = (async () => {
      await settle(80);
      stub.drop();
      await settle(10);
      await stub.dial();
    })();
  };
  const supervisor = await superviseWith(stub, inject, { healthIntervalMs: 0 });
  await settle();
  const firstPid = supervisor.bridge.pid;

  await supervisor.relaunch("forced delayed replacement");
  await replacement;

  expect(stub.dials).toBe(2);
  expect(supervisor.bridge.pid).not.toBe(firstPid);
  expect(supervisor.isConnected).toBe(true);
});

test("stopping ends supervision instead of relaunching", async () => {
  const stub = makeStub();
  const { inject, calls } = fakeInject(stub);
  const supervisor = await superviseWith(stub, inject, { healthIntervalMs: 0 });
  await settle();
  const before = calls.length;

  await supervisor.stop();
  stub.drop();
  await settle(300);

  expect(calls).toHaveLength(before);
});

test("relaunch is reported with the reason that prompted it", async () => {
  const stub = makeStub();
  const { inject } = fakeInject(stub);
  const supervisor = await superviseWith(stub, inject, { healthIntervalMs: 0 });
  await settle();

  const reasons: string[] = [];
  supervisor.on("relaunching", (reason: string) => reasons.push(reason));

  await supervisor.relaunch("send timed out");
  expect(reasons).toEqual(["send timed out"]);
});
