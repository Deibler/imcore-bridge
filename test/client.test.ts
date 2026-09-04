import { test, expect, afterEach } from "bun:test";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import { join } from "node:path";

import { ImcoreBridge } from "../src/client.js";
import {
  BridgeUnavailableError,
  ChatNotFoundError,
  ImcoreBridgeError,
  MessageNotFoundError,
  UnsupportedFeatureError,
} from "../src/errors.js";
import type { Capabilities } from "../src/types.js";

// The real bridge dials the client, so the stub plays the injected side.
// This keeps protocol, capability gating and error mapping testable on a
// machine with no Messages.app injection at all.

const FULL_CAPABILITIES: Capabilities = {
  typing: true, typingData: true, send: true, reply: true, subject: true,
  sendService: true,
  effect: true, effectWithAttachments: true, attachments: true, tapback: true,
  emojiTapback: true, mute: true, deleteHistory: true, reportJunk: true,
  mentions: true, sendAsText: true, shareLocation: true,
  retract: true, edit: true, groupRename: true, groupPhoto: true,
  groupAdd: true, groupRemove: true, groupLeave: true,
  search: true, searchRanked: true, store: true, poll: true,
  avatars: true, sendLater: true, stickers: true, markUnread: true,
  stickerAttach: true, deleteChat: true, shareNameAndPhoto: true,
  groupPreconditions: true,
  notifyAnyway: true, pin: true, account: true, sendingAlias: true,
  nicknames: true, stats: true, events: true,
};

interface Stub {
  socketPath: string;
  connect(capabilities?: Partial<Capabilities>): Promise<void>;
  push(event: string, data: unknown): void;
  handled: { method: string; params: Record<string, unknown> }[];
  respondWith(method: string, response: Record<string, unknown>): void;
  silence(): void;
  close(): void;
}

let cleanups: (() => void)[] = [];
afterEach(() => {
  for (const fn of cleanups) fn();
  cleanups = [];
});

function makeStub(): Stub {
  const socketPath = join(
    fs.mkdtempSync(join(os.tmpdir(), "imcore-test-")),
    "bridge.sock",
  );
  const handled: Stub["handled"] = [];
  const overrides = new Map<string, Record<string, unknown>>();
  let socket: net.Socket | undefined;
  let silent = false;

  const stub: Stub = {
    socketPath,
    handled,
    respondWith(method, response) {
      overrides.set(method, response);
    },
    silence() {
      silent = true;
    },
    async connect(capabilities) {
      socket = net.createConnection(socketPath);
      await new Promise<void>((resolve) => socket!.once("connect", () => resolve()));

      socket.write(
        `${JSON.stringify({
          type: "event",
          event: "hello",
          data: {
            pid: 4242,
            protocol: 1,
            ready: true,
            capabilities: { ...FULL_CAPABILITIES, ...capabilities },
          },
        })}\n`,
      );

      let buffer = "";
      socket.on("data", (chunk) => {
        buffer += chunk.toString();
        let nl: number;
        while ((nl = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, nl);
          buffer = buffer.slice(nl + 1);
          if (!line.trim()) continue;
          const request = JSON.parse(line);
          handled.push({ method: request.method, params: request.params });
          if (silent) continue;

          const override = overrides.get(request.method);
          const reply = override
            ? { id: request.id, ...override }
            : { id: request.id, ok: true, result: { echo: request.method } };
          socket!.write(`${JSON.stringify(reply)}\n`);
        }
      });
    },
    push(event, data) {
      socket?.write(`${JSON.stringify({ type: "event", event, data })}\n`);
    },
    close() {
      socket?.destroy();
    },
  };
  cleanups.push(() => stub.close());
  return stub;
}

test("handshake exposes the capability matrix", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  expect(bridge.isConnected).toBe(true);
  expect(bridge.pid).toBe(4242);
  expect(bridge.can("send")).toBe(true);
});

test("a feature missing on this build is refused before hitting the wire", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect({ edit: false });
  await new Promise((r) => setTimeout(r, 50));

  expect(bridge.can("edit")).toBe(false);
  await expect(
    bridge.edit({ chat: "+15550000000", message: "guid", text: "hi" }),
  ).rejects.toBeInstanceOf(UnsupportedFeatureError);

  // Rejected locally, so nothing was sent.
  expect(stub.handled.find((c) => c.method === "edit")).toBeUndefined();
});

test("wire errors map onto typed errors", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("resolveChat", {
    ok: false,
    error: { code: "chat_not_found", message: "no chat matching 'nobody'" },
  });

  await expect(bridge.resolveChat("nobody")).rejects.toBeInstanceOf(ChatNotFoundError);
});

test("calling before anything connects fails clearly", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await expect(bridge.status()).rejects.toBeInstanceOf(BridgeUnavailableError);
});

test("an in-flight RPC fails as soon as its connection closes", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({
    socketPath: stub.socketPath,
    timeoutMs: 5_000,
  });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));
  stub.silence();

  const pending = bridge.status();
  await new Promise((r) => setTimeout(r, 20));
  stub.close();

  const outcome = await Promise.race([
    pending.catch((error) => error),
    new Promise((resolve) => setTimeout(() => resolve("still waiting"), 500)),
  ]);
  expect(outcome).toBeInstanceOf(BridgeUnavailableError);
  expect(bridge.pid).toBeUndefined();
});

test("send forwards its options verbatim", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("send", { ok: true, result: { guid: "NEW-GUID" } });
  const result = await bridge.send({
    chat: "+15550000000",
    text: "hello",
    replyTo: "TARGET",
    effect: "com.apple.MobileSMS.expressivesend.gentle",
  });

  expect(result.guid).toBe("NEW-GUID");
  const call = stub.handled.find((c) => c.method === "send");
  expect(call?.params).toMatchObject({
    chat: "+15550000000",
    text: "hello",
    replyTo: "TARGET",
    effect: "com.apple.MobileSMS.expressivesend.gentle",
  });
});

test("events queue rather than drop while the consumer is busy", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  const seen: string[] = [];
  const reader = (async () => {
    for await (const event of bridge.events()) {
      seen.push(event.type);
      if (seen.length === 3) break;
    }
  })();

  await new Promise((r) => setTimeout(r, 20));
  stub.push("message", { guid: "a", text: "one", isFromMe: false });
  stub.push("typing", { chatGUID: "c", typing: true });
  stub.push("read-receipt", { chatGUID: "c" });

  await Promise.race([reader, new Promise((r) => setTimeout(r, 1500))]);
  expect(seen).toEqual(["message", "typing", "read-receipt"]);
});

test("a second injected host is refused so sends are not duplicated", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  const warnings: string[] = [];
  bridge.on("warning", (w: string) => warnings.push(w));

  const second = net.createConnection(stub.socketPath);
  cleanups.push(() => second.destroy());
  await new Promise<void>((resolve) => second.once("connect", () => resolve()));
  await new Promise((r) => setTimeout(r, 100));

  expect(warnings.some((w) => w.includes("second bridge"))).toBe(true);
});

test("search passes scope and kinds through, and unwraps the results", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("search", {
    ok: true,
    result: {
      strategy: "ranked",
      results: [
        { kind: "message", guid: "M1", messageGuid: "M1", chatGuid: "any;+;chat1" },
        { kind: "attachment", guid: "at_0_M2", messageGuid: "M2", partIndex: 0 },
      ],
    },
  });

  const results = await bridge.search({
    query: "dog",
    chat: "any;+;chat1",
    kinds: ["message", "attachment"],
    limit: 10,
  });

  expect(results.strategy).toBe("ranked");
  expect(results.hits).toHaveLength(2);
  expect(results.hits[1]?.messageGuid).toBe("M2");
  // Absent rather than false, so callers can test it directly.
  expect(results.truncated).toBeUndefined();

  const call = stub.handled.find((c) => c.method === "search");
  expect(call?.params).toMatchObject({
    query: "dog",
    chatGuid: "any;+;chat1",
    kinds: ["message", "attachment"],
    limit: 10,
  });
});

test("a poll goes out with its options in order", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("sendPoll", { ok: true, result: { guid: "POLL", options: 3 } });
  const result = await bridge.sendPoll({
    chat: "+15550000000",
    question: "Lunch?",
    options: ["Pizza", "Sushi", "Tacos"],
  });

  expect(result.guid).toBe("POLL");
  expect(stub.handled.find((c) => c.method === "sendPoll")?.params).toMatchObject({
    chat: "+15550000000",
    question: "Lunch?",
    options: ["Pizza", "Sushi", "Tacos"],
  });
});

test("scheduling passes the delivery time through", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  const at = Math.floor(Date.now() / 1000) + 3600;
  stub.respondWith("sendLater", { ok: true, result: { guid: "LATER", at } });
  const result = await bridge.sendLater({ chat: "+15550000000", text: "morning", at });

  expect(result.guid).toBe("LATER");
  expect(stub.handled.find((c) => c.method === "sendLater")?.params).toMatchObject({ at });
});

test("every error carries the code the bridge sent", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("storeMessage", {
    ok: false,
    error: { code: "message_not_found", message: "gone" },
  });

  // The code is on the base class, so branching on it does not require
  // knowing which errors were given a class of their own.
  const error = await bridge
    .storeMessage("GONE")
    .then(() => null)
    .catch((e: ImcoreBridgeError) => e);
  expect(error).toBeInstanceOf(MessageNotFoundError);
  expect(error?.code).toBe("message_not_found");
});

test("deep history pages backwards through the store", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("storeHistory", {
    ok: true,
    result: {
      chatGuid: "any;-;+15550000000",
      nextBeforeRowID: 1200,
      hasMore: true,
      messages: [
        { rowid: 1200, guid: "M1", text: "older" },
        { rowid: 1201, guid: "M2", text: "newer" },
      ],
    },
  });

  const page = await bridge.storeHistory({ chat: "+15550000000", limit: 2 });

  // Oldest first within a page, so a transcript reads top to bottom.
  expect(page.messages[0]?.rowid).toBe(1200);
  expect(page.hasMore).toBe(true);
  // The cursor is what the caller passes back for the next older page.
  expect(page.nextBeforeRowID).toBe(1200);

  const call = stub.handled.find((c) => c.method === "storeHistory");
  expect(call?.params).toMatchObject({ chat: "+15550000000", limit: 2 });
});

test("a search hit resolves to its stored message", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("storeMessage", {
    ok: true,
    result: { rowid: 42, guid: "HIT", text: "found", chatGuid: "any;+;chat1" },
  });

  const message = await bridge.storeMessage("HIT");
  expect(message.chatGuid).toBe("any;+;chat1");
  expect(stub.handled.find((c) => c.method === "storeMessage")?.params).toMatchObject({
    guid: "HIT",
  });
});

test("a hit whose message was deleted reports it as missing", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  // The search index is not pruned when a message is deleted, so this is the
  // ordinary outcome for an old hit rather than a failure.
  stub.respondWith("storeMessage", {
    ok: false,
    error: { code: "message_not_found", message: "no message with that GUID" },
  });

  await expect(bridge.storeMessage("GONE")).rejects.toBeInstanceOf(MessageNotFoundError);
});

test("search is refused when the build cannot reach the index", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect({ search: false });
  await new Promise((r) => setTimeout(r, 50));

  await expect(bridge.search({ query: "dog" })).rejects.toBeInstanceOf(
    UnsupportedFeatureError,
  );
  expect(stub.handled.find((c) => c.method === "search")).toBeUndefined();
});

test("voting names the option however the caller has it", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("votePoll", {
    ok: true,
    result: { guid: "VOTE", optionId: "OPT-2", optionText: "Bravo" },
  });

  // A position rather than the text; the bridge resolves it against the poll.
  const result = await bridge.votePoll({ chat: "+15550000000", poll: "POLL", option: 1 });
  expect(result.optionText).toBe("Bravo");
  expect(stub.handled.find((c) => c.method === "votePoll")?.params).toMatchObject({
    poll: "POLL",
    option: 1,
  });
});

test("scheduled messages report the chat they actually landed in", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  // Called without a chat, because a scheduled message is not always filed
  // under the conversation it was addressed to — and cancelling needs the one
  // it landed in.
  stub.respondWith("scheduled", {
    ok: true,
    result: {
      messages: [
        {
          rowid: 9,
          guid: "LATER",
          text: "soon",
          schedule_type: 2,
          scheduledFor: 1900000000,
          chatGuid: "any;-;e:me@example.com",
        },
      ],
    },
  });

  const { messages } = await bridge.scheduled();
  expect(messages[0]?.chatGuid).toBe("any;-;e:me@example.com");
  expect(messages[0]?.scheduledFor).toBe(1900000000);
  expect(stub.handled.find((c) => c.method === "scheduled")?.params).toEqual({});
});

test("a group event comes back instead of a body", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("storeMessage", {
    ok: true,
    result: {
      rowid: 7,
      guid: "EVT",
      item_type: 2,
      event: { kind: "group-renamed", actor: "+15550000000", name: "Trip" },
    },
  });

  const message = await bridge.storeMessage("EVT");
  expect(message.event?.kind).toBe("group-renamed");
  expect(message.event?.name).toBe("Trip");
  expect(message.text).toBeUndefined();
});

test("an unsend that never reached the other side is distinguishable", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  // Both are unsent locally; only one is still on the recipient's device.
  stub.respondWith("storeMessage", {
    ok: true,
    result: { rowid: 8, guid: "GONE", part_count: 0, unsent: true, unsendFailed: true },
  });

  const message = await bridge.storeMessage("GONE");
  expect(message.unsent).toBe(true);
  expect(message.unsendFailed).toBe(true);
});

test("a contact picture is fetched one handle at a time", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("avatar", {
    ok: true,
    result: { handle: "+15550000000", mimeType: "image/jpeg", data: "AAAA" },
  });

  const picture = await bridge.avatar("+15550000000");
  expect(picture.mimeType).toBe("image/jpeg");
  expect(stub.handled.find((c) => c.method === "avatar")?.params).toMatchObject({
    handle: "+15550000000",
  });
});

test("a group operation reports what actually changed, not that it returned", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  // removeParticipants: returns without complaint and does nothing when the
  // group would drop below three people, so `ok` alone is not the answer.
  stub.respondWith("group.remove", {
    ok: true,
    result: {
      ok: true,
      changed: false,
      participants: ["+15550000001", "+15550000002"],
      displayName: "Trip",
    },
  });

  const result = await bridge.group.removeMembers("any;+;chat1", ["+15550000001"]);
  expect(result.changed).toBe(false);
  expect(result.participants).toContain("+15550000001");
});

test("a live message carries the same edit and unsend detail as history", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("getHistory", {
    ok: true,
    result: {
      messages: [
        {
          guid: "M1",
          isFromMe: false,
          kind: "text",
          text: "I vote yes",
          editHistory: [
            {
              part: 0,
              versions: [{ text: "I vote yet", date: 1 }, { text: "I vote yes", date: 2 }],
            },
          ],
        },
        { guid: "M2", isFromMe: true, kind: "event", event: { kind: "group-renamed", name: "Trip" } },
      ],
    },
  });

  const { messages } = await bridge.getHistory({ chat: "any;+;chat1" });
  expect(messages[0]?.editHistory?.[0]?.versions).toHaveLength(2);
  expect(messages[1]?.kind).toBe("event");
  expect(messages[1]?.event?.name).toBe("Trip");
});

test("a contact card comes back without the photo unless asked", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("contact", {
    ok: true,
    result: {
      handle: "+15550000000",
      name: "Ada Lovelace",
      firstName: "Ada",
      lastName: "Lovelace",
      // Labels arrive localised, not as Contacts' `_$!<Mobile>!$_`.
      phoneNumbers: [{ number: "+15550000000", label: "mobile" }],
      emailAddresses: [{ address: "ada@example.com", label: "work" }],
      birthday: { month: 12, day: 10 },
      hasPhoto: true,
    },
  });

  const card = await bridge.contact("+15550000000");
  expect(card.name).toBe("Ada Lovelace");
  expect(card.phoneNumbers?.[0]?.label).toBe("mobile");
  expect(card.birthday?.year).toBeUndefined();
  expect(card.hasPhoto).toBe(true);
  expect(card.photo).toBeUndefined();
  expect(stub.handled.find((c) => c.method === "contact")?.params).toMatchObject({
    handle: "+15550000000",
    includePhoto: false,
  });
});

test("history resolves handles to the people behind them", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  // The handle stays put — callers key on it — and the name sits alongside.
  stub.respondWith("storeHistory", {
    ok: true,
    result: {
      chatGuid: "any;+;chat1",
      nextBeforeRowID: 0,
      hasMore: false,
      messages: [
        {
          rowid: 1,
          guid: "M1",
          sender: "+15550000000",
          senderName: "Ada Lovelace",
          text: "hello",
          tapbacks: [{ kind: "love", sender: "+15550000001", senderName: "Grace", isFromMe: false }],
        },
      ],
    },
  });

  const page = await bridge.storeHistory({ chat: "any;+;chat1" });
  expect(page.messages[0]?.sender).toBe("+15550000000");
  expect(page.messages[0]?.senderName).toBe("Ada Lovelace");
  expect(page.messages[0]?.tapbacks?.[0]?.senderName).toBe("Grace");
});

test("an unknown text effect is refused rather than sent plain", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  // IMCore reads an unrecognised effect name as "no effect", so the message
  // would go out plain and look like it worked.
  stub.respondWith("send", {
    ok: false,
    error: { code: "bad_request", message: "unknown text effect 'shake'" },
  });

  await expect(
    bridge.send({
      chat: "any;+;chat1",
      text: "hello",
      formatting: [{ location: 0, length: 5, textEffect: "shake" }],
    }),
  ).rejects.toThrow(/unknown text effect/);
  expect(stub.handled.find((c) => c.method === "send")?.params).toMatchObject({
    formatting: [{ location: 0, length: 5, textEffect: "shake" }],
  });
});

test("deleting reports what left the conversation, not what was asked for", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  // A delete does not remove the row — the message moves to the recoverable
  // set — so the count is read back rather than assumed.
  stub.respondWith("deleteMessages", {
    ok: true,
    result: { deleted: 2, requested: 3, matched: 3 },
  });

  const result = await bridge.deleteMessages({
    chat: "any;+;chat1",
    messages: ["A", "B", "C"],
  });
  expect(result.deleted).toBe(2);
  expect(result.requested).toBe(3);
});

test("whois says whether a handle can receive an iMessage at all", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("whois", {
    ok: true,
    result: {
      id: "+15550000000",
      name: "Ada Lovelace",
      service: "SMS",
      isIMessage: false,
      hasFocusOn: true,
    },
  });

  const who = await bridge.whois("+15550000000");
  expect(who.isIMessage).toBe(false);
  expect(who.hasFocusOn).toBe(true);
});

// ---------------------------------------------------------------------------
// Attachments, chat lifecycle, identity, statistics
// ---------------------------------------------------------------------------

/// Staging writes real files, so tests point it at a scratch directory. Every
/// test below that sends a file goes through here.
function withScratchStaging(): string {
  const directory = fs.mkdtempSync(join(os.tmpdir(), "imcore-staging-"));
  const previous = process.env["IMCORE_BRIDGE_STAGING_DIR"];
  process.env["IMCORE_BRIDGE_STAGING_DIR"] = directory;
  cleanups.push(() => {
    if (previous === undefined) delete process.env["IMCORE_BRIDGE_STAGING_DIR"];
    else process.env["IMCORE_BRIDGE_STAGING_DIR"] = previous;
    fs.rmSync(directory, { recursive: true, force: true });
  });
  return directory;
}

test("a file and its text go out as one message", async () => {
  const staging = withScratchStaging();
  const source = join(staging, "source.txt");
  fs.writeFileSync(source, "hello");

  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());
  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("send", { ok: true, result: { guid: "G" } });
  await bridge.send({ chat: "CHAT", text: "caption", files: [source] });

  // One call, not a separate file send followed by a text send.
  const calls = stub.handled.filter((c) => c.method === "send");
  expect(calls.length).toBe(1);
  expect(calls[0]?.params["text"]).toBe("caption");

  // The path handed over is the staged copy, not the original: the daemon
  // uploads from the attachment tree and will not reach anywhere else.
  const files = calls[0]?.params["files"] as string[];
  expect(files.length).toBe(1);
  expect(files[0]).toStartWith(staging);
  expect(files[0]).not.toBe(source);
  expect(fs.readFileSync(files[0] as string, "utf8")).toBe("hello");
});

test("staging refuses a path that is not a file", async () => {
  withScratchStaging();
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());
  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  await expect(
    bridge.send({ chat: "CHAT", files: ["/nonexistent/nope.png"] }),
  ).rejects.toThrow(/no file at/);
});

test("sticker rides along with the files it applies to", async () => {
  const staging = withScratchStaging();
  const source = join(staging, "sticker.png");
  fs.writeFileSync(source, "png");

  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());
  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("send", { ok: true, result: { guid: "G" } });
  await bridge.send({ chat: "CHAT", files: [source], sticker: { label: "wave" } });

  const call = stub.handled.find((c) => c.method === "send");
  expect(call?.params["sticker"]).toMatchObject({ label: "wave" });
});

test("markUnread names a message only when given one", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());
  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("markUnread", { ok: true, result: { unread: true } });
  await bridge.markUnread("CHAT");
  await bridge.markUnread("CHAT", "GUID");

  const calls = stub.handled.filter((c) => c.method === "markUnread");
  expect(calls[0]?.params).toEqual({ chat: "CHAT" });
  expect(calls[1]?.params).toEqual({ chat: "CHAT", message: "GUID" });
});

test("pin defaults to pinning and reports the state back", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());
  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("pin", { ok: true, result: { pinned: true } });
  expect(await bridge.pin("CHAT")).toEqual({ pinned: true });
  expect(stub.handled.find((c) => c.method === "pin")?.params).toEqual({
    chat: "CHAT",
    pinned: true,
  });
});

test("stats passes its scope through and account takes none", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());
  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("stats", { ok: true, result: { messages: 3 } });
  stub.respondWith("account", { ok: true, result: { imessage: { aliases: [] } } });
  await bridge.stats({ chat: "CHAT", since: 1700000000 });
  await bridge.account();

  expect(stub.handled.find((c) => c.method === "stats")?.params).toEqual({
    chat: "CHAT",
    since: 1700000000,
  });
  expect(stub.handled.find((c) => c.method === "account")?.params).toEqual({});
});

test("nickname asks for your own card when no handle is given", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());
  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("nickname", { ok: true, result: { name: "Ada" } });
  await bridge.nickname();
  await bridge.nickname("+15550000000");

  const calls = stub.handled.filter((c) => c.method === "nickname");
  expect(calls[0]?.params).toEqual({});
  expect(calls[1]?.params).toEqual({ handle: "+15550000000" });
});

test("the new operations are gated on their capability", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect({
    markUnread: false, notifyAnyway: false, pin: false,
    account: false, sendingAlias: false, nicknames: false, stats: false,
  });
  await new Promise((r) => setTimeout(r, 50));

  await expect(bridge.markUnread("CHAT")).rejects.toBeInstanceOf(UnsupportedFeatureError);
  await expect(bridge.notifyAnyway("CHAT", "G")).rejects.toBeInstanceOf(UnsupportedFeatureError);
  await expect(bridge.pin("CHAT")).rejects.toBeInstanceOf(UnsupportedFeatureError);
  await expect(bridge.account()).rejects.toBeInstanceOf(UnsupportedFeatureError);
  await expect(bridge.setSendingAlias("a@b.c")).rejects.toBeInstanceOf(UnsupportedFeatureError);
  await expect(bridge.nickname()).rejects.toBeInstanceOf(UnsupportedFeatureError);
  await expect(bridge.stats()).rejects.toBeInstanceOf(UnsupportedFeatureError);
});

test("an emoji reaction is gated apart from the classic tapbacks", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  // A build can send the six named reactions and still not know the emoji
  // ones, so the two are gated separately rather than together.
  await stub.connect({ tapback: true, emojiTapback: false });
  await new Promise((r) => setTimeout(r, 50));

  await expect(
    bridge.tapback({ chat: "any;+;chat1", message: "M1", kind: "emoji", emoji: "🔥" }),
  ).rejects.toBeInstanceOf(UnsupportedFeatureError);

  stub.respondWith("tapback", { ok: true, result: { kind: "love", removed: false } });
  await bridge.tapback({ chat: "any;+;chat1", message: "M1", kind: "love" });
});

test("an emoji reaction carries its character through to the bridge", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("tapback", {
    ok: true,
    result: { kind: "emoji", removed: true, emoji: "🔥" },
  });

  await bridge.tapback({
    chat: "any;+;chat1", message: "M1", kind: "emoji", emoji: "🔥", remove: true,
  });

  // The character is the whole content of this reaction: dropping it here
  // would send a reaction the caller never asked for.
  expect(stub.handled.find((c) => c.method === "tapback")?.params).toMatchObject({
    message: "M1", kind: "emoji", emoji: "🔥", remove: true,
  });
});

test("mute reports the state it read back, not the one it asked for", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  // An indefinite mute comes back without a date; a mute whose date has
  // already passed comes back unmuted, which is why this is not an echo.
  stub.respondWith("mute", { ok: true, result: { muted: true } });
  expect(await bridge.mute("any;+;chat1")).toEqual({ muted: true });

  // Only what the caller gave is sent; muting is the default at the far end,
  // so a bare mute() carries no `muted` and no `until`.
  const params = stub.handled.find((c) => c.method === "mute")?.params;
  expect(params).toMatchObject({ chat: "any;+;chat1" });
  expect(params).not.toHaveProperty("until");

  stub.respondWith("mute", { ok: true, result: { muted: false } });
  await bridge.mute("any;+;chat1", { muted: false });
  expect(stub.handled.filter((c) => c.method === "mute")[1]?.params).toMatchObject({
    muted: false,
  });
});

test("the conversation-state operations are gated on their capability", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect({
    mute: false, deleteHistory: false, reportJunk: false,
    mentions: false, sendAsText: false,
  });
  await new Promise((r) => setTimeout(r, 50));

  await expect(bridge.mute("CHAT")).rejects.toBeInstanceOf(UnsupportedFeatureError);
  await expect(bridge.deleteHistory("CHAT")).rejects.toBeInstanceOf(UnsupportedFeatureError);
  await expect(bridge.reportJunk("CHAT")).rejects.toBeInstanceOf(UnsupportedFeatureError);
  await expect(bridge.mentions("CHAT")).rejects.toBeInstanceOf(UnsupportedFeatureError);
  await expect(bridge.sendAsText("CHAT", "G")).rejects.toBeInstanceOf(UnsupportedFeatureError);

  // Refused locally, so nothing reached a conversation.
  expect(stub.handled.find((c) => c.method === "deleteHistory")).toBeUndefined();
  expect(stub.handled.find((c) => c.method === "reportJunk")).toBeUndefined();
});

// A consumer that was not running has to be able to ask what it missed. Paging
// backwards cannot answer that: it would walk the archive from the newest
// message until the cursor came into view.
test("catching up reads forwards from a cursor, across every conversation", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("storeHistory", {
    ok: true,
    result: {
      nextBeforeRowID: 900,
      nextSinceRowID: 902,
      hasMore: false,
      messages: [
        { rowid: 900, guid: "M1", text: "one", chatGuid: "any;-;+15550000000" },
        { rowid: 902, guid: "M2", text: "two", chatGuid: "iMessage;+;chat42" },
      ],
    },
  });

  const page = await bridge.storeHistory({ sinceRowID: 899, limit: 500 });

  // No chat filter went out: the caller does not know which chats have news.
  const call = stub.handled.find((c) => c.method === "storeHistory");
  expect(call?.params).toMatchObject({ sinceRowID: 899, limit: 500 });
  expect(call?.params.chat).toBeUndefined();

  // Each message says which conversation it came from, which is the only way
  // to route a page that spans several.
  expect(page.messages.map((m) => m.chatGuid)).toEqual([
    "any;-;+15550000000",
    "iMessage;+;chat42",
  ]);
  // The cursor to resume from is the newest rowid read.
  expect(page.nextSinceRowID).toBe(902);
});

test("a window bounded at both ends is refused before it reaches the wire", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  // Thrown rather than rejected, matching how every other capability and
  // argument check on this client refuses a call.
  expect(() => bridge.storeHistory({ sinceRowID: 10, beforeRowID: 90 })).toThrow(
    ImcoreBridgeError,
  );
  expect(stub.handled.find((c) => c.method === "storeHistory")).toBeUndefined();
});

test("a message can be routed over a named service, and reports what carried it", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("send", { ok: true, result: { guid: "G", service: "SMS" } });
  const result = await bridge.send({ chat: "+15550000000", text: "hi", service: "SMS" });

  expect(result.service).toBe("SMS");
  expect(stub.handled.find((c) => c.method === "send")?.params).toMatchObject({ service: "SMS" });
});

test("a build that cannot choose a service refuses before sending", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect({ sendService: false });
  await new Promise((r) => setTimeout(r, 50));

  await expect(
    bridge.send({ chat: "+15550000000", text: "hi", service: "SMS" }),
  ).rejects.toBeInstanceOf(UnsupportedFeatureError);
  // Refusing locally matters here: sending anyway would have gone out over
  // iMessage while reporting success for a text.
  expect(stub.handled.find((c) => c.method === "send")).toBeUndefined();

  // Without a service named, the same send is fine.
  stub.respondWith("send", { ok: true, result: { guid: "G" } });
  await bridge.send({ chat: "+15550000000", text: "hi" });
  expect(stub.handled.find((c) => c.method === "send")).toBeDefined();
});

test("one person can map to several conversations", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("resolveChats", {
    ok: true,
    result: {
      chats: [
        { guid: "iMessage;-;+15550000000", participants: ["+15550000000"], isGroup: false },
        { guid: "SMS;-;+15550000000", participants: ["+15550000000"], isGroup: false },
      ],
    },
  });

  const chats = await bridge.resolveChats("+15550000000");
  // Most recently active first, so the head is the thread to answer in.
  expect(chats.map((c) => c.guid)).toEqual([
    "iMessage;-;+15550000000",
    "SMS;-;+15550000000",
  ]);
});

test("an address nobody has spoken to comes back empty rather than as an error", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("chatsWith", { ok: true, result: { chats: [] } });

  // Empty is the answer a send-time check needs — an error would have to be
  // caught and distinguished from the bridge being down.
  expect(await bridge.chatsWith("+15559999999")).toEqual([]);
  expect(stub.handled.find((c) => c.method === "chatsWith")?.params).toMatchObject({
    handle: "+15559999999",
  });
});

// A send that reaches Messages and loses its reply leaves the caller unable to
// tell whether it landed. The key is what makes the retry safe.
test("a repeated send carries its idempotency key through", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("send", { ok: true, result: { guid: "G", duplicate: true } });
  const result = await bridge.send({
    chat: "+15550000000",
    text: "only once",
    idempotencyKey: "turn-42",
  });

  // The caller can tell an absorbed retry from a fresh send.
  expect(result.duplicate).toBe(true);
  expect(stub.handled.find((c) => c.method === "send")?.params).toMatchObject({
    idempotencyKey: "turn-42",
  });
});

test("a send's fate can be looked up by guid", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("sendStatus", {
    ok: true,
    result: { guid: "G", state: "delivered", rowid: 900, date_delivered: 1785000000 },
  });

  const status = await bridge.sendStatus("G");
  expect(status.state).toBe("delivered");
  expect(status.rowid).toBe(900);
  expect(stub.handled.find((c) => c.method === "sendStatus")?.params).toMatchObject({ guid: "G" });
});

test("a guid the store has never seen is unknown, not an error", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("sendStatus", { ok: true, result: { guid: "NOPE", state: "unknown" } });

  // Unknown covers both "not written yet" and "never sent", so it has to come
  // back as an answer the caller can retry on rather than as a rejection.
  expect((await bridge.sendStatus("NOPE")).state).toBe("unknown");
});

test("a sticker can be stuck to a message, and is gated separately", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect({ stickerAttach: false });
  await new Promise((r) => setTimeout(r, 50));

  // Sending a sticker still works; only sticking one to a bubble is missing.
  await expect(
    bridge.send({ chat: "C", files: ["/tmp/s.png"], sticker: { attachTo: "TARGET" } }),
  ).rejects.toBeInstanceOf(UnsupportedFeatureError);
  expect(stub.handled.find((c) => c.method === "send")).toBeUndefined();
});

test("deleting a conversation is a different call from emptying one", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));

  stub.respondWith("deleteChat", { ok: true, result: { deleted: true } });
  stub.respondWith("deleteHistory", { ok: true, result: { deleted: true } });

  await bridge.deleteChat("CHAT");
  await bridge.deleteHistory("CHAT");

  // Two distinct methods reach the bridge: one takes the thread, the other
  // leaves it in the list with nothing in it.
  expect(stub.handled.filter((c) => c.method === "deleteChat")).toHaveLength(1);
  expect(stub.handled.filter((c) => c.method === "deleteHistory")).toHaveLength(1);
});

test("the disclosing actions are refused when the build cannot make them", async () => {
  const stub = makeStub();
  const bridge = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void bridge.close());

  await stub.connect({ deleteChat: false, shareNameAndPhoto: false });
  await new Promise((r) => setTimeout(r, 50));

  await expect(bridge.deleteChat("CHAT")).rejects.toBeInstanceOf(UnsupportedFeatureError);
  await expect(bridge.shareNameAndPhoto("+15550000000")).rejects.toBeInstanceOf(
    UnsupportedFeatureError,
  );
  // Neither reached a conversation or another person.
  expect(stub.handled.find((c) => c.method === "deleteChat")).toBeUndefined();
  expect(stub.handled.find((c) => c.method === "shareNameAndPhoto")).toBeUndefined();
});

test("a socket another host is still serving is refused, not stolen", async () => {
  const stub = makeStub();
  const first = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void first.close());

  // Unlinking unconditionally was silent theft: the second host bound a fresh
  // inode, the first kept one nothing could reach, and the injected side dialled
  // whichever came last. Three abandoned scripts held a path for three days that
  // way, and the daemon that could not be reached blamed SIP.
  await expect(ImcoreBridge.listenOnly({ socketPath: stub.socketPath })).rejects.toBeInstanceOf(
    BridgeUnavailableError,
  );
  await expect(ImcoreBridge.listenOnly({ socketPath: stub.socketPath })).rejects.toThrow(
    /already serving/,
  );

  // The original is untouched and still serving.
  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));
  expect(first.isConnected).toBe(true);
});

test("a socket left behind by a dead host is reclaimed", async () => {
  const stub = makeStub();
  const first = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  await first.close();
  // close() unlinks, so put a stale file back the way an unclean exit would.
  fs.writeFileSync(stub.socketPath, "");

  const second = await ImcoreBridge.listenOnly({ socketPath: stub.socketPath });
  cleanups.push(() => void second.close());
  await stub.connect();
  await new Promise((r) => setTimeout(r, 50));
  expect(second.isConnected).toBe(true);
});
