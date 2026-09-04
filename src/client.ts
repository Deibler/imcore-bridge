import net from "node:net";
import fs from "node:fs";
import { dirname } from "node:path";
import { EventEmitter } from "node:events";

import { defaultSocketPath } from "./paths.js";
import { stageAttachment } from "./attachments.js";
import {
  BridgeUnavailableError,
  ImcoreBridgeError,
  RpcTimeoutError,
  UnsupportedFeatureError,
  errorFromWire,
} from "./errors.js";
import type {
  Account,
  BridgeEvent,
  BridgeStatus,
  Capabilities,
  Capability,
  Chat,
  ChatDetails,
  ClientOptions,
  Contact,
  ContactAvatar,
  GroupResult,
  Message,
  NameAndPhoto,
  SearchHit,
  SearchOptions,
  SearchResults,
  SendOptions,
  SendStatus,
  StoreHistory,
  StoreHistoryOptions,
  Stats,
  StoredMessage,
  TapbackKind,
} from "./types.js";

/**
 * Whether something is still answering on a socket path.
 *
 * Distinguishes a live owner from a file left behind by a process that died —
 * the two are indistinguishable by stat, and treating the first as the second
 * is how one host silently takes the bridge from another.
 */
async function socketIsLive(socketPath: string, timeoutMs = 400): Promise<boolean> {
  if (!fs.existsSync(socketPath)) return false;
  return new Promise<boolean>((resolve) => {
    const probe = net.createConnection(socketPath);
    const settle = (live: boolean) => {
      clearTimeout(timer);
      probe.destroy();
      resolve(live);
    };
    const timer = setTimeout(() => settle(false), timeoutMs);
    timer.unref?.();
    probe.once("connect", () => settle(true));
    probe.once("error", () => settle(false));
  });
}

interface PendingCall {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
  method: string;
}

// Native `send` may wait up to 30s for Messages' main thread. The client must
// not give up first: doing so lets a retry enter the native queue while the
// original request can still complete, needlessly extending a wedge (the
// idempotency key prevents a duplicate bubble, but not the extra contention).
const DEFAULT_TIMEOUT_MS = 35_000;

/**
 * Talks to the code injected into Messages.app.
 *
 * This process owns the socket and the bridge dials in, rather than the other
 * way around: Messages.app is sandboxed without `network.server`, so code
 * inside it can connect out but cannot listen.
 */
export class ImcoreBridge extends EventEmitter {
  readonly socketPath: string;
  private readonly timeoutMs: number;

  private server?: net.Server;
  private connection?: net.Socket;
  private buffer = "";
  private nextId = 1;
  private readonly pending = new Map<number, PendingCall>();
  private capabilities?: Capabilities;
  private hostPid?: number;
  private closed = false;

  private constructor(options: ClientOptions = {}) {
    super();
    this.socketPath = options.socketPath ?? defaultSocketPath();
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  /**
   * Listens for an already-injected Messages.app to connect.
   *
   * Rejects if nothing connects before `timeoutMs`, which usually means
   * Messages is running without the bridge — use {@link launch} for that.
   */
  static async connect(options: ClientOptions = {}): Promise<ImcoreBridge> {
    const bridge = new ImcoreBridge(options);
    await bridge.listen();
    await bridge.waitForHello(options.timeoutMs ?? DEFAULT_TIMEOUT_MS);
    return bridge;
  }

  /**
   * Starts listening without waiting for a connection.
   *
   * Use when you want to relaunch Messages yourself, or to keep the socket up
   * across restarts of the host app.
   */
  static async listenOnly(options: ClientOptions = {}): Promise<ImcoreBridge> {
    const bridge = new ImcoreBridge(options);
    await bridge.listen();
    return bridge;
  }

  private async listen(): Promise<void> {
    fs.mkdirSync(dirname(this.socketPath), { recursive: true });

    // Refuse to take a socket somebody else is still serving.
    //
    // Unlinking unconditionally was silent theft. Whoever bound last owned the
    // path, and every earlier host kept a socket bound to an inode nothing
    // could reach any more — so the injected side dialled the newest owner
    // while an older one waited forever for a connection it would never get.
    //
    // In practice: three throwaway scripts from a debugging session three days
    // earlier were still holding this path, because owning the socket keeps the
    // process alive. The daemon bound after them, could not be reached, and
    // spent half an hour relaunching Messages and reporting that SIP must be
    // misconfigured. Failing loudly here would have named the real problem on
    // the first attempt.
    if (await socketIsLive(this.socketPath)) {
      throw new BridgeUnavailableError(
        `another process is already serving ${this.socketPath} — the bridge takes ` +
          `exactly one host. Find it with \`lsof ${this.socketPath}\` and stop it first.`,
      );
    }
    // Nothing answered, so anything here is a leftover file that would block bind().
    try {
      fs.unlinkSync(this.socketPath);
    } catch {
      /* nothing to clean up */
    }

    return new Promise((resolve, reject) => {
      const server = net.createServer((socket) => this.adopt(socket));
      server.on("error", reject);
      server.listen(this.socketPath, () => {
        fs.chmodSync(this.socketPath, 0o600);
        this.server = server;
        resolve();
      });
    });
  }

  private adopt(socket: net.Socket): void {
    if (this.connection && !this.connection.destroyed) {
      // A second injected Messages would duplicate every send. Refuse it.
      this.emit("warning", "refused a second bridge connection");
      socket.destroy();
      return;
    }

    // A replacement can arrive in the narrow window after the old Socket is
    // marked destroyed but before its asynchronous `close` event. Calls on the
    // old connection still cannot complete; fail them now rather than leaving
    // them to consume the full RPC timeout.
    if (this.connection) {
      this.rejectPending(
        new BridgeUnavailableError(
          "Messages replaced the bridge connection before the request completed",
          "bridge_unavailable",
        ),
      );
    }

    this.connection = socket;
    this.buffer = "";

    socket.on("data", (chunk) => this.onData(chunk));
    socket.on("error", () => socket.destroy());
    socket.on("close", () => {
      // An old socket may close after its replacement has already been
      // adopted. It no longer owns state and must not disconnect the new one.
      if (this.connection !== socket) return;
      this.connection = undefined;
      this.capabilities = undefined;
      this.hostPid = undefined;
      this.rejectPending(
        new BridgeUnavailableError(
          "Messages closed the bridge connection before the request completed",
          "bridge_unavailable",
        ),
      );
      this.emit("disconnected");
    });
  }

  private rejectPending(error: Error): void {
    for (const [id, call] of this.pending) {
      clearTimeout(call.timer);
      call.reject(error);
      this.pending.delete(id);
    }
  }

  private onData(chunk: Buffer): void {
    this.buffer += chunk.toString("utf8");
    let newline: number;
    while ((newline = this.buffer.indexOf("\n")) !== -1) {
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      if (line.trim()) this.onLine(line);
    }
  }

  private onLine(line: string): void {
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(line) as Record<string, unknown>;
    } catch {
      this.emit("warning", `unparseable line from bridge: ${line.slice(0, 120)}`);
      return;
    }

    if (parsed["type"] === "event") {
      const event = { type: parsed["event"], data: parsed["data"] } as BridgeEvent;
      if (event.type === "hello") {
        const status = event.data as BridgeStatus;
        this.capabilities = status.capabilities;
        this.hostPid = status.pid;
        this.emit("connected", status);
      }
      this.emit("event", event);
      this.emit(String(event.type), event.data);
      return;
    }

    const id = parsed["id"];
    if (typeof id !== "number") return;
    const call = this.pending.get(id);
    if (!call) return;
    this.pending.delete(id);
    clearTimeout(call.timer);

    if (parsed["ok"] === true) {
      call.resolve(parsed["result"] ?? {});
    } else {
      const wire = (parsed["error"] ?? {}) as { code?: string; message?: string };
      call.reject(
        errorFromWire(wire.code ?? "unknown", wire.message ?? "request failed", call.method),
      );
    }
  }

  private waitForHello(timeoutMs: number): Promise<void> {
    if (this.capabilities) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.off("connected", onConnected);
        reject(
          new BridgeUnavailableError(
            `no injected Messages.app connected within ${timeoutMs}ms — ` +
              `is it running with the bridge loaded?`,
          ),
        );
      }, timeoutMs);
      const onConnected = () => {
        clearTimeout(timer);
        resolve();
      };
      this.once("connected", onConnected);
    });
  }

  /** True once an injected Messages.app is connected. */
  get isConnected(): boolean {
    return !!this.connection && !this.connection.destroyed && !!this.capabilities;
  }

  /** Process id of the connected Messages.app, if any. */
  get pid(): number | undefined {
    return this.hostPid;
  }

  /**
   * Whether the running Messages build supports a feature.
   *
   * Derived from live selector probes, so this is the honest answer for this
   * machine rather than a compile-time assumption.
   */
  can(feature: Capability): boolean {
    return this.capabilities?.[feature] === true;
  }

  /** The full capability matrix, or undefined before the handshake. */
  getCapabilities(): Capabilities | undefined {
    return this.capabilities;
  }

  private call<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    if (!this.connection || this.connection.destroyed) {
      return Promise.reject(
        new BridgeUnavailableError("no injected Messages.app is connected"),
      );
    }

    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new RpcTimeoutError(method, this.timeoutMs));
      }, this.timeoutMs);

      this.pending.set(id, {
        resolve: resolve as (value: unknown) => void,
        reject,
        timer,
        method,
      });
      this.connection!.write(`${JSON.stringify({ id, method, params })}\n`);
    });
  }

  private requireCapability(feature: Capability): void {
    if (this.capabilities && !this.can(feature)) {
      throw new UnsupportedFeatureError(feature);
    }
  }

  // -- reading -------------------------------------------------------------

  status(): Promise<BridgeStatus> {
    return this.call<BridgeStatus>("status");
  }

  async listChats(options: { limit?: number } = {}): Promise<Chat[]> {
    const result = await this.call<{ chats: Chat[] }>("listChats", { ...options });
    return result.chats;
  }

  resolveChat(chat: string): Promise<Chat> {
    return this.call<Chat>("resolveChat", { chat });
  }

  /**
   * Every conversation an identifier resolves to, most recently active first.
   *
   * A 1:1 legitimately maps to more than one: the same person has an iMessage
   * thread and an SMS thread, and which one is current changes with whether
   * they have signal. {@link resolveChat} answers with one of them, which is
   * fine for addressing a send and wrong for reading — a reply sent to the
   * quiet thread goes somewhere nobody is looking.
   *
   * An unknown identifier is an empty list, not an error.
   */
  async resolveChats(chat: string): Promise<Chat[]> {
    const result = await this.call<{ chats: Chat[] }>("resolveChats", { chat });
    return result.chats;
  }

  /**
   * Every conversation a handle appears in, groups included, most recently
   * active first.
   *
   * Empty means this address has never been spoken to — which is what makes
   * this usable as a check before sending somewhere new, rather than only as a
   * way to find shared groups.
   *
   * Numbers are matched by their national digits, so the same person written
   * `+15551234567` and `(555) 123-4567` is one person; email is matched
   * case-insensitively.
   */
  async chatsWith(handle: string): Promise<Chat[]> {
    const result = await this.call<{ chats: Chat[] }>("chatsWith", { handle });
    return result.chats;
  }

  /**
   * Recent messages for a conversation, newest first.
   *
   * Pages history into IMCore on demand, so this reaches beyond whatever the
   * UI happened to have loaded — but it is still a recent window, not the full
   * archive.
   */
  getHistory(options: { chat: string; limit?: number }): Promise<{ chat: Chat; messages: Message[] }> {
    return this.call("getHistory", { ...options });
  }

  // -- writing -------------------------------------------------------------

  /**
   * Sends a message, optionally with files.
   *
   * Files travel with `text` as one message, so the text reads as a caption
   * rather than arriving separately, and they can go to any conversation
   * `chat` resolves to, group chats included.
   *
   * The result names the service that carried it, which is the only way to
   * learn whether something went out as an iMessage or as a text.
   */
  async send(
    options: SendOptions,
  ): Promise<{ guid: string; service?: string; duplicate?: boolean; recipient?: string }> {
    this.requireCapability("send");
    if (options.service) this.requireCapability("sendService");
    if (typeof options.sticker === "object" && options.sticker.attachTo) {
      this.requireCapability("stickerAttach");
    }

    // Files are staged out here, where there is no sandbox, and go over the
    // socket as paths the daemon can already reach. Everything then travels as
    // one message: the text is a caption on the attachment rather than a
    // second message arriving after it, and the chat is addressed by GUID
    // rather than by picking a participant to send to.
    const files = options.files?.map(stageAttachment);

    const { files: _files, ...rest } = options;
    return this.call<{ guid: string; service?: string; duplicate?: boolean; recipient?: string }>("send", {
      ...rest,
      ...(files ? { files } : {}),
    });
  }

  /**
   * What became of a send, by GUID.
   *
   * The other half of {@link SendOptions.idempotencyKey}: the key stops a retry
   * from sending twice, and this answers the question you still have, which is
   * whether the message actually arrived.
   *
   * `unknown` means the message store has no row for that GUID — which covers
   * both a message written a moment from now and one that was never sent, so
   * treat it as "ask again" rather than as "no".
   */
  sendStatus(guid: string): Promise<SendStatus> {
    return this.call<SendStatus>("sendStatus", { guid });
  }

  /**
   * Shows or clears the typing indicator. Sends no message.
   *
   * The indicator has no expiry of its own — it stays until something turns it
   * off. If this client goes away without doing so, the bridge clears whatever
   * it left showing when the connection drops, so a crash mid-turn does not
   * leave the dots up in a real conversation.
   */
  async setTyping(options: { chat: string; typing: boolean }): Promise<void> {
    this.requireCapability("typing");
    await this.call("setTyping", { ...options });
  }

  /**
   * Reacts to a message, or takes a reaction back with `remove`.
   *
   * `kind: "emoji"` is the custom-emoji reaction the emoji picker sends, and
   * needs `emoji` to carry the character. The six classic kinds are named by
   * themselves, so passing `emoji` with any of them is rejected rather than
   * ignored.
   */
  async tapback(options: {
    chat: string;
    message: string;
    kind: TapbackKind;
    /** Required for `kind: "emoji"`, and invalid with any other kind. */
    emoji?: string;
    remove?: boolean;
  }): Promise<void> {
    this.requireCapability(options.kind === "emoji" ? "emojiTapback" : "tapback");
    await this.call("tapback", { ...options });
  }

  /**
   * Creates a poll, as the Polls item in the app's + menu does.
   *
   * Between two and twelve options. Recipients vote in the Messages UI; the
   * votes come back through {@link storeHistory}, tallied onto the poll.
   */
  sendPoll(options: {
    chat: string;
    question?: string;
    options: string[];
  }): Promise<{ guid: string; options: number }> {
    this.requireCapability("poll");
    return this.call("sendPoll", { ...options });
  }

  /**
   * Votes in an existing poll.
   *
   * Name the option however is convenient — its text, its position, or its
   * identifier. Everything the vote actually needs is read out of the poll.
   *
   * Voting again replaces your earlier choice, as it does in the app.
   */
  votePoll(options: {
    chat: string;
    /** GUID of the poll message. */
    poll: string;
    /** Option text, zero-based position, or option id. */
    option: string | number;
  }): Promise<{ guid: string; optionId: string; optionText: string }> {
    this.requireCapability("poll");
    return this.call("votePoll", { ...options });
  }

  /**
   * Schedules a message for later delivery, as Send Later does.
   *
   * `at` is Unix seconds and must be at least a minute out. The message sits
   * in the conversation as pending until then; cancel it with
   * {@link cancelScheduled} while it is still waiting.
   *
   * **Check `scheduled` on the result.** Messages does not always honour the
   * request — when another message goes out just before, it has been seen
   * delivering this one immediately instead, which reports no error and looks
   * identical. The result is read back from the store, so `scheduled: false`
   * means it has already been sent and there is nothing left to cancel.
   *
   * `chatGuid` reports where it actually landed, which is not always the
   * conversation asked for.
   */
  sendLater(options: {
    chat: string;
    text: string;
    at: number;
  }): Promise<{
    guid: string;
    at: number;
    scheduled: boolean;
    chatGuid?: string;
    warning?: string;
  }> {
    this.requireCapability("sendLater");
    return this.call("sendLater", { ...options });
  }

  /**
   * Cancels a scheduled message before it goes out.
   *
   * Pass the conversation it actually landed in — the `chatGuid` from
   * {@link sendLater} — which is not always the one it was addressed to.
   */
  async cancelScheduled(options: { chat: string; message: string }): Promise<void> {
    this.requireCapability("sendLater");
    await this.call("cancelScheduled", { ...options });
  }

  /**
   * Unsends a message.
   *
   * Always removes it locally, but propagation to the recipient is not
   * guaranteed — a failed retraction shows as "Not Unsent" in the UI and the
   * other party keeps seeing the message. Do not rely on this as an undo.
   */
  async retract(options: { chat: string; message: string }): Promise<void> {
    this.requireCapability("retract");
    await this.call("retract", { ...options });
  }

  async edit(options: {
    chat: string;
    message: string;
    text: string;
    partIndex?: number;
  }): Promise<void> {
    this.requireCapability("edit");
    await this.call("edit", { ...options });
  }

  /** Clears the unread state for a conversation. */
  async markRead(chat: string): Promise<void> {
    await this.call("markRead", { chat });
  }

  /**
   * Returns a conversation to unread.
   *
   * With no `message` this is the app's own Mark as Unread, which puts the dot
   * on the last message. Naming one marks from there instead.
   */
  async markUnread(chat: string, message?: string): Promise<void> {
    this.requireCapability("markUnread");
    await this.call("markUnread", { chat, ...(message ? { message } : {}) });
  }

  /**
   * Pushes a notification for one message past a mute or a Focus.
   *
   * This is the Notify Anyway button. It applies to a single message rather
   * than to the conversation, and there is no way to observe from here whether
   * the notification actually broke through on the other device.
   */
  async notifyAnyway(chat: string, message: string): Promise<void> {
    this.requireCapability("notifyAnyway");
    await this.call("notifyAnyway", { chat, message });
  }

  /**
   * Pins or unpins a conversation, returning the state afterwards.
   *
   * IMCore has no per-chat pin: the only setter replaces the entire pinned
   * list, which syncs across devices. The list is read back off the live chats
   * immediately before writing, so the write is always the current set plus or
   * minus this one conversation.
   */
  async pin(chat: string, pinned = true): Promise<{ pinned: boolean }> {
    this.requireCapability("pin");
    return this.call<{ pinned: boolean }>("pin", { chat, pinned });
  }

  /**
   * Silences a conversation, or lifts the silence — the app's Hide Alerts.
   *
   * Mute is held as a date rather than a flag, so `until` (a Unix time) mutes
   * to that moment and omitting it mutes indefinitely. The state is read back
   * off the conversation rather than echoed, since a mute whose date has
   * already passed is not a mute; `until` comes back only when the silence
   * really does end.
   */
  async mute(
    chat: string,
    options: { muted?: boolean; until?: number } = {},
  ): Promise<{ muted: boolean; until?: number }> {
    this.requireCapability("mute");
    return this.call<{ muted: boolean; until?: number }>("mute", { chat, ...options });
  }

  /**
   * Empties a conversation of its messages.
   *
   * Not an unsend: everyone else keeps their copy and is told nothing. Local
   * deletion is recoverable for thirty days, as `deleteMessages` is, but this
   * is the whole conversation at once.
   */
  async deleteHistory(chat: string): Promise<{ deleted: boolean }> {
    this.requireCapability("deleteHistory");
    return this.call<{ deleted: boolean }>("deleteHistory", { chat });
  }

  /**
   * Removes a conversation, as deleting it in the app does.
   *
   * Not the same as {@link deleteHistory}, which empties a conversation and
   * leaves it in the list with nothing in it. Both are local — the other party
   * keeps their copy either way — but this one takes the thread itself, and
   * macOS keeps deleted messages for thirty days rather than forever.
   */
  async deleteChat(chat: string): Promise<{ deleted: boolean }> {
    this.requireCapability("deleteChat");
    return this.call<{ deleted: boolean }>("deleteChat", { chat });
  }

  /**
   * Sends this account's Name & Photo to someone, as tapping Share does.
   *
   * Reading the cards other people have shared is one thing; handing over your
   * own name and picture is a disclosure about the person running this. Call it
   * when they ask for it, not as a step in something else.
   */
  async shareNameAndPhoto(handle: string): Promise<{ shared: boolean }> {
    this.requireCapability("shareNameAndPhoto");
    return this.call<{ shared: boolean }>("shareNameAndPhoto", { handle });
  }

  /**
   * Reports a conversation to Apple as junk.
   *
   * This leaves the machine and cannot be undone, so it is never a side effect
   * of anything else.
   */
  async reportJunk(chat: string): Promise<{ reported: boolean }> {
    this.requireCapability("reportJunk");
    return this.call<{ reported: boolean }>("reportJunk", { chat });
  }

  /**
   * Shares this account's location with a conversation for `seconds`.
   *
   * The duration is required and must be positive. The app's third choice —
   * sharing indefinitely — is deliberately not offered: it would be some
   * sentinel value, nothing reachable names which one, and a wrong guess
   * broadcasts a real-time location until someone notices.
   *
   * Shipped unverified: confirming it means actually transmitting a location.
   */
  async shareLocation(
    chat: string,
    seconds: number,
  ): Promise<{ sharing: boolean; seconds: number }> {
    this.requireCapability("shareLocation");
    return this.call<{ sharing: boolean; seconds: number }>("shareLocation", {
      chat,
      seconds,
    });
  }

  /** The unread messages in a conversation that mention this account. */
  async mentions(chat: string): Promise<string[]> {
    this.requireCapability("mentions");
    const result = await this.call<{ messages: string[] }>("mentions", { chat });
    return result.messages ?? [];
  }

  /**
   * Resends a message over SMS — the app's "Send as Text Message".
   *
   * This is a retry of a message that failed as an iMessage, not a way to
   * address a new one to SMS. Asking for it on a message that did not fail
   * asks the carrier to deliver a second copy.
   *
   * Shipped unverified: it needs a genuinely failed iMessage to act on.
   */
  async sendAsText(chat: string, message: string): Promise<{ requested: boolean }> {
    this.requireCapability("sendAsText");
    return this.call<{ requested: boolean }>("sendAsText", { chat, message });
  }

  /**
   * Sets a group conversation's photo, or clears it when `file` is omitted.
   *
   * Unverified: the selectors are present and the transfer registers, but this
   * has not been run against a real group, because a wrong result would
   * overwrite a photo that cannot be recovered.
   */
  async setGroupPhoto(chat: string, file?: string): Promise<void> {
    this.requireCapability("groupPhoto");
    await this.call("setGroupPhoto", { chat, ...(file ? { file: stageAttachment(file) } : {}) });
  }

  /**
   * The signed-in messaging identity: Apple ID, aliases, SMS relay state.
   *
   * Among other things this is how to tell your own handles from everyone
   * else's, which is what makes "did I send this" answerable without guessing.
   */
  async account(): Promise<Account> {
    this.requireCapability("account");
    return this.call<Account>("account");
  }

  /**
   * Changes which alias outgoing iMessages are attributed to.
   *
   * Only a vetted alias is accepted — IMCore takes an unvetted one and then
   * fails every send, which reads as the network being down.
   */
  async setSendingAlias(alias: string): Promise<{ sendingAs: string }> {
    this.requireCapability("sendingAlias");
    return this.call<{ sendingAs: string }>("setSendingAlias", { alias });
  }

  /**
   * The Name & Photo card a handle shared, or your own when none is given.
   *
   * Messages shows this in preference to the contact card, so reading Contacts
   * alone can give a different name than the one on screen. Your own card also
   * carries `pending`: the updates waiting to be accepted or declined.
   */
  async nickname(handle?: string): Promise<NameAndPhoto> {
    this.requireCapability("nicknames");
    return this.call<NameAndPhoto>("nickname", { ...(handle ? { handle } : {}) });
  }

  /**
   * Counts and distributions over a conversation, or the whole store.
   *
   * Answers what a person could work out by scrolling, but over the full
   * history rather than the loaded window. `since` is Unix seconds.
   */
  async stats(options: { chat?: string; since?: number } = {}): Promise<Stats> {
    this.requireCapability("stats");
    return this.call<Stats>("stats", { ...options });
  }

  /**
   * Searches the index Messages already maintains.
   *
   * This is the same index the app's own search field queries, so it arrives
   * with work the device has already done: pictures are matched by what they
   * contain, text recognised inside images is searchable, and spoken content
   * in audio and video is covered. A query for "dog" finds photographs of dogs
   * whose messages never mention one.
   *
   * Hits are references, not full messages. Use `messageGuid` with the message
   * store to read one in its conversation.
   */
  async search(options: SearchOptions): Promise<SearchResults> {
    this.requireCapability("search");
    const { query, limit, chat, kinds } = options;
    const result = await this.call<{
      results: SearchHit[];
      strategy: SearchResults["strategy"];
      truncated?: boolean;
    }>("search", { query, limit, chatGuid: chat, kinds });
    return {
      hits: result.results,
      strategy: result.strategy,
      ...(result.truncated ? { truncated: true } : {}),
    };
  }

  // -- message store ---------------------------------------------------------

  /**
   * Deep history from the message store, oldest page first.
   *
   * Unlike {@link getHistory}, which reads IMCore's in-memory window, this
   * reaches the full archive. It pages two ways, and they answer different
   * questions:
   *
   * **Backwards**, with `chat` and `beforeRowID` — reading further into one
   * conversation's past. Pass the previous page's `nextBeforeRowID`.
   *
   * **Forwards**, with `sinceRowID` and usually no `chat` — collecting what
   * arrived while nothing was listening. Pass the previous page's
   * `nextSinceRowID`, or the highest `rowid` seen on the event stream. Leaving
   * `chat` out is the point: after downtime a caller does not know which
   * conversations have news, and each message carries its own `chatGuid`.
   *
   * With no cursor at all it answers with the newest page, whose
   * `nextSinceRowID` is the position to start from — so a first run begins at
   * now rather than replaying years of archive.
   *
   * Rows carry their encoded blobs (`attributedBody`, `payload_data`) as
   * base64; most messages have no plain `text` and keep their body in
   * `attributedBody`.
   */
  storeHistory(options: StoreHistoryOptions = {}): Promise<StoreHistory> {
    this.requireCapability("store");
    if (options.beforeRowID && options.sinceRowID) {
      throw new ImcoreBridgeError(
        "bad_request",
        "pass beforeRowID or sinceRowID, not both — a window bounded at both " +
          "ends has no single cursor to continue from",
      );
    }
    return this.call("storeHistory", { ...options });
  }

  /**
   * Reads one stored message by GUID — the way to resolve a search hit.
   *
   * A hit's `messageGuid` is not guaranteed to resolve: the search index can
   * outlive the store, so a missing message means it was deleted.
   */
  storeMessage(guid: string): Promise<StoredMessage> {
    this.requireCapability("store");
    return this.call("storeMessage", { guid });
  }

  /**
   * A conversation's own details: its picture, and the flags that are not
   * messages — archived, filtered into Unknown Senders, blocked.
   *
   * The transcript records when a group photo changed, but not which one is
   * current; this reads the chat's own answer.
   */
  chatDetails(chat: string): Promise<ChatDetails> {
    this.requireCapability("store");
    return this.call("chatDetails", { chat });
  }

  /**
   * One contact picture, base64-encoded.
   *
   * Fetched one handle at a time rather than folded into every listing: the
   * picture belongs to the contact rather than the handle, so answering even
   * "is there one" means a Contacts lookup. Rejects with `not_found` when the
   * contact has no picture.
   */
  avatar(handle: string): Promise<ContactAvatar> {
    return this.call("avatar", { handle });
  }

  /**
   * Everything Contacts holds about the person behind a handle: names, other
   * numbers, email addresses, birthday, employer, postal addresses, related
   * people.
   *
   * This is what turns a number in a transcript into someone you can say
   * something about. Pass `includePhoto` for the picture bytes as well —
   * `hasPhoto` says whether there is one without paying for it.
   *
   * A card hands out only the fields that were asked for, so anything absent
   * here is unavailable however it is requested. Rejects with `not_found` when
   * the handle matches nobody in Contacts.
   */
  contact(handle: string, options: { includePhoto?: boolean } = {}): Promise<Contact> {
    return this.call("contact", { handle, includePhoto: options.includePhoto === true });
  }

  /**
   * Finds or starts a conversation with the given people.
   *
   * IMCore has no separate "create": this returns the existing conversation if
   * there is one and mints it if there is not, which `isNew` distinguishes.
   * Nothing is sent and nobody is notified until a message goes out — a
   * conversation with no messages is local to this Mac.
   */
  createChat(handles: string[], name?: string): Promise<Chat & { isNew: boolean }> {
    return this.call("createChat", name ? { handles, name } : { handles });
  }

  /**
   * Deletes messages from this Mac.
   *
   * **This is not an unsend.** The recipient keeps their copy and is told
   * nothing; it is what the app's own Delete does. Use `retract` to try to take
   * a message back from the other side. Not recoverable through this API.
   *
   * `deleted` is verified by reading back, not assumed: a delete does not
   * remove the row. The message moves out of the conversation into the
   * recoverable set — macOS keeps deleted messages for thirty days — so it is
   * still readable by GUID and only its conversation membership is gone.
   * `matched` is how many of the requested GUIDs were found to act on.
   */
  deleteMessages(options: {
    chat: string;
    messages: string[];
  }): Promise<{ deleted: number; requested: number; matched: number }> {
    return this.call("deleteMessages", { ...options });
  }

  /**
   * What is known about a handle before sending to it: whether it is reachable
   * on iMessage, and whether the person has Focus on.
   *
   * `isIMessage` false means a message would go as SMS or not at all.
   * `hasFocusOn` is read from the conversation with them, so it is absent when
   * there is no conversation yet.
   */
  whois(handle: string): Promise<{
    id: string;
    name?: string;
    service?: string;
    isIMessage?: boolean;
    status?: number;
    statusMessage?: string;
    hasFocusOn?: boolean;
  }> {
    return this.call("whois", { handle });
  }

  /**
   * Messages still waiting to go out, oldest delivery time first.
   *
   * A scheduled message is not in the conversation yet, so nothing reading a
   * transcript will find one. Called without a chat this covers every
   * conversation, which is the only way to find one Messages filed somewhere
   * other than where it was addressed — and cancelling needs the chat it
   * actually landed in.
   *
   * `scheduledFor` on each message is the delivery time it is being held for.
   */
  scheduled(chat?: string): Promise<{ messages: StoredMessage[] }> {
    this.requireCapability("store");
    return this.call("scheduled", chat ? { chat } : {});
  }

  /**
   * Group membership and naming.
   *
   * Every one of these returns void inside IMCore, so the call returning is not
   * evidence it took effect. Membership changes are now asked about first —
   * IMCore knows in advance whether it will act, and a change it will not make
   * is refused with a reason instead of reported as success. The commonest is
   * removing someone from a group of three, which would leave two, and which
   * IMCore declines by doing nothing at all.
   *
   * That check needs `groupPreconditions`; without it the old behaviour stands.
   * Either way each result is read back from the chat afterwards, so
   * **check `changed`** and the `participants` list rather than assuming.
   */
  readonly group = {
    rename: async (chat: string, name: string): Promise<GroupResult> => {
      this.requireCapability("groupRename");
      return this.call("group.rename", { chat, name });
    },
    addMembers: async (chat: string, members: string[]): Promise<GroupResult> => {
      this.requireCapability("groupAdd");
      return this.call("group.add", { chat, members });
    },
    removeMembers: async (chat: string, members: string[]): Promise<GroupResult> => {
      this.requireCapability("groupRemove");
      return this.call("group.remove", { chat, members });
    },
    /**
     * Leaves the conversation. There is no way back in from this side — only
     * someone still in the group can add you again.
     */
    leave: async (chat: string): Promise<GroupResult> => {
      this.requireCapability("groupLeave");
      return this.call("group.leave", { chat });
    },

    /**
     * Whether a membership change would be acted on, without making it.
     *
     * This is what Messages itself asks before it enables the menu item, and
     * it is read-only — the one way to find out what IMCore will do without a
     * real conversation changing to tell you. `addMembers` and `removeMembers`
     * ask it themselves and refuse when the answer is no, so this is for
     * callers that want to know beforehand.
     */
    canAdd: async (chat: string, members: string[]): Promise<boolean> => {
      this.requireCapability("groupPreconditions");
      const result = await this.call<{ allowed: boolean }>("group.canAdd", { chat, members });
      return result.allowed;
    },
    canRemove: async (chat: string, members: string[]): Promise<boolean> => {
      this.requireCapability("groupPreconditions");
      const result = await this.call<{ allowed: boolean }>("group.canRemove", { chat, members });
      return result.allowed;
    },
  };

  // -- events --------------------------------------------------------------

  /**
   * Async iterator over live events.
   *
   * Events that arrive while the consumer is busy are queued, so nothing is
   * dropped between iterations.
   */
  async *events(): AsyncGenerator<BridgeEvent> {
    const queue: BridgeEvent[] = [];
    let wake: (() => void) | undefined;

    const onEvent = (event: BridgeEvent) => {
      queue.push(event);
      wake?.();
    };
    this.on("event", onEvent);

    try {
      while (!this.closed) {
        while (queue.length) yield queue.shift()!;
        await new Promise<void>((resolve) => {
          wake = resolve;
        });
        wake = undefined;
      }
    } finally {
      this.off("event", onEvent);
    }
  }

  /** Stops listening and releases the socket. */
  async close(): Promise<void> {
    this.closed = true;
    this.rejectPending(new BridgeUnavailableError("client closed", "bridge_unavailable"));
    this.capabilities = undefined;
    this.hostPid = undefined;
    this.connection?.destroy();
    await new Promise<void>((resolve) => {
      if (!this.server) return resolve();
      this.server.close(() => resolve());
    });
    try {
      fs.unlinkSync(this.socketPath);
    } catch {
      /* already gone */
    }
  }
}
