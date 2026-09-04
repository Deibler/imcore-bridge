#!/usr/bin/env node
// Thin CLI over the library, for shell scripts and non-TypeScript callers.
import fs from "node:fs";
import { join } from "node:path";

import { ImcoreBridge } from "../client.js";
import { launch } from "../launch.js";
import { defaultSocketPath, packageRoot } from "../paths.js";
import { ImcoreBridgeError } from "../errors.js";
import type { GroupEvent, SearchKind, StoredMessage, TapbackKind } from "../types.js";

const USAGE = `imcore-bridge — automate the macOS Messages app

Usage:
  imcore-bridge launch                       relaunch Messages with the bridge injected
  imcore-bridge status                       show the capability matrix
  imcore-bridge chats [--limit N]            list conversations
  imcore-bridge history --chat C [--limit N] recent messages, as JSON
  imcore-bridge send --chat C [--text T] [--file PATH]... [--sticker [LABEL]]
                     [--reply-to GUID] [--effect ID] [--subject S]
                     [--service iMessage|SMS]   which one carries this message
                     [--stick-to GUID]   with --sticker, peel-and-stick it onto
                                         that message instead of sending it alone
                     [--key K]           makes a retry of this send safe
                     [--format JSON]  style/mention ranges, e.g.
                     '[{"location":0,"length":5,"styles":["bold"],"textEffect":"Shake"}]'
  imcore-bridge typing --chat C [--off] [--duration SECONDS]
  imcore-bridge tapback --chat C --message GUID --kind love|like|dislike|laugh|emphasize|question [--remove]
  imcore-bridge tapback --chat C --message GUID --kind emoji --emoji "🔥" [--remove]
  imcore-bridge poll --chat C [--question Q] OPTION OPTION [OPTION ...]
  imcore-bridge vote --chat C --poll GUID --option TEXT|INDEX|ID
  imcore-bridge later --chat C --text T --in MINUTES | --at UNIX_SECONDS
  imcore-bridge cancel --chat C --message GUID   cancel a scheduled message
  imcore-bridge retract --chat C --message GUID
  imcore-bridge edit --chat C --message GUID --text T
  imcore-bridge read --chat C                mark a conversation as read
  imcore-bridge unread --chat C [--message GUID]   return it to unread
  imcore-bridge notify --chat C --message GUID     push past a mute or Focus
  imcore-bridge pin --chat C [--off]         pin or unpin a conversation
  imcore-bridge mute --chat C [--off] [--until UNIX_SECONDS]   Hide Alerts
  imcore-bridge mentions --chat C            unread messages mentioning you
  imcore-bridge delete-history --chat C      empty a conversation (local only)
  imcore-bridge delete-chat --chat C         remove the conversation itself
  imcore-bridge send-status GUID             what became of a send
  imcore-bridge share-card --handle H        send your Name & Photo to someone
  imcore-bridge report-junk --chat C         report to Apple; cannot be undone
  imcore-bridge send-as-text --chat C --message GUID           resend over SMS
  imcore-bridge share-location --chat C --seconds N            share for a bounded time
  imcore-bridge group-photo --chat C [--file PATH]  set or clear the picture
  imcore-bridge search QUERY [--chat C] [--limit N] [--kind message|attachment|chat]
  imcore-bridge archive --chat C [--limit N] [--before ROWID]
                                             deep history from the message store
  imcore-bridge archive --since ROWID [--chat C] [--limit N]
                                             what arrived after a cursor, across
                                             every conversation unless --chat
  imcore-bridge resolve CHAT                 every conversation it maps to
  imcore-bridge chats-with HANDLE            every conversation including them
  imcore-bridge message GUID                 one stored message, as JSON
  imcore-bridge scheduled [--chat C]         messages waiting to be delivered
  imcore-bridge details --chat C             conversation photo and flags
  imcore-bridge avatar HANDLE [--out FILE]   a contact picture
  imcore-bridge contact HANDLE [--photo]     everything Contacts holds on them
  imcore-bridge whois HANDLE                 iMessage reachability and Focus
  imcore-bridge account [--alias A]          your identity; --alias changes the sending one
  imcore-bridge card [HANDLE]                the Name & Photo someone shared
  imcore-bridge stats [--chat C] [--since UNIX]    counts and distributions
  imcore-bridge new-chat HANDLE [HANDLE ...] [--name N]   find or start a conversation
  imcore-bridge delete --chat C GUID [GUID ...]           delete locally (not an unsend)
  imcore-bridge watch                        stream live events as JSON lines

Options:
  --socket PATH   override the socket path (default: ${defaultSocketPath()})
  --json          machine-readable output where a table is the default
  --help          print this
  --version       print the installed version

Sending is real and cannot be reliably undone. Test against a recipient who has
agreed to receive test traffic.
`;

/**
 * Every command the switch in `main` dispatches, so an unrecognised one can be
 * refused before dialling the socket. Without it a typo waits out the connect
 * timeout and then reports that Messages is unreachable — which is not what
 * went wrong, and sends the reader to look at the injection instead of at what
 * they typed.
 *
 * It is read out of USAGE rather than written twice, so a command cannot be
 * accepted and undocumented. The cost is the other direction — a `case` added
 * to the switch and left out of USAGE would be unreachable — which is what
 * `test/cli.test.ts` checks.
 */
const COMMANDS = new Set(
  [...USAGE.matchAll(/^ {2}imcore-bridge ([a-z-]+)/gm)].map((match) => match[1]!),
);

/** The version npm installed, for `--version`. */
function version(): string {
  const manifest: unknown = JSON.parse(
    fs.readFileSync(join(packageRoot(), "package.json"), "utf8"),
  );
  const value = (manifest as { version?: unknown }).version;
  return typeof value === "string" ? value : "unknown";
}

function parseArgs(argv: string[]): {
  command: string;
  flags: Map<string, string | boolean>;
  repeats: Map<string, string[]>;
  positionals: string[];
} {
  // A leading `--help` or `--version` is a flag, not a command. Taking the
  // first token as the command whatever it looks like is what made `--help`
  // fall through to the connect and spend the timeout before answering with
  // the wrong complaint.
  const leadsWithFlag = argv[0]?.startsWith("-") ?? false;
  const command = leadsWithFlag ? "help" : (argv[0] ?? "help");
  const rest = leadsWithFlag ? argv : argv.slice(1);
  const flags = new Map<string, string | boolean>();
  // A repeated flag keeps every value here; `flags` still holds the last one,
  // so nothing that reads a single value changes behaviour.
  const repeats = new Map<string, string[]>();
  const positionals: string[] = [];
  for (let i = 0; i < rest.length; i++) {
    const token = rest[i]!;
    if (!token.startsWith("--")) {
      positionals.push(token);
      continue;
    }
    const key = token.slice(2);
    const next = rest[i + 1];
    if (next && !next.startsWith("--")) {
      flags.set(key, next);
      repeats.set(key, [...(repeats.get(key) ?? []), next]);
      i++;
    } else {
      flags.set(key, true);
    }
  }
  return { command, flags, repeats, positionals };
}

/** Renders a group event the way the app words it. */
function describeEvent(event: GroupEvent): string {
  const who = event.actorName ?? event.actor ?? "someone";
  const target = event.participantName ?? event.participant ?? "someone";
  switch (event.kind) {
    case "participant-added":
      return `— ${who} added ${target}`;
    case "participant-change":
      return `— ${who} changed ${target} (code ${event.actionCode})`;
    case "group-renamed":
      return `— ${who} named the conversation "${event.name ?? ""}"`;
    case "group-photo-set":
      return `— ${who} changed the conversation photo`;
    case "group-photo-removed":
      return `— ${who} removed the conversation photo`;
    case "group-action":
      return `— ${who} changed the conversation (code ${event.actionCode})`;
    case "share":
      return `— ${who} shared (status ${event.shareStatus})`;
    default:
      return `— unrecognised event (item type ${event.itemType})`;
  }
}

/** One transcript line: whatever the bubble would actually show. */
function summarise(message: StoredMessage): string {
  if (message.event) return `${message.rowid} ${describeEvent(message.event)}`;

  const who = message.is_from_me ? "me" : (message.senderName ?? message.sender ?? "them");
  const files = (message.attachments ?? []).map(
    (a) => `[${a.description ?? a.filename ?? a.mimeType ?? "attachment"}]`,
  );
  // A poll's own text is the notification line ("Sent a poll"); the question
  // is what the bubble actually shows.
  const poll = message.poll;
  const tally = poll?.options
    ?.map((o) => `${o.text}${o.voteCount ? ` ${o.voteCount}` : ""}`)
    .join(" / ");
  const body =
    (poll ? `[poll] ${poll.question ?? ""}${tally ? ` — ${tally}` : ""}` : undefined) ??
    message.text ??
    message.link?.title ??
    (files.length ? "" : message.unsent ? "[unsent]" : "[no text]");

  const marks: string[] = [];
  if (message.editHistory) marks.push(`edited ×${message.editHistory[0]!.versions.length - 1}`);
  if (message.unsendFailed) marks.push("NOT UNSENT");
  if (message.tapbacks?.length) {
    marks.push(message.tapbacks.map((t) => t.emoji ?? t.kind).join(" "));
  }
  if (message.stickers?.length) marks.push(`${message.stickers.length} sticker(s)`);

  const line = [body, ...files].filter(Boolean).join(" ").replace(/\s+/g, " ").slice(0, 120);
  return `${message.rowid} ${who}: ${line}${marks.length ? `  (${marks.join(", ")})` : ""}`;
}

function str(flags: Map<string, string | boolean>, key: string): string | undefined {
  const value = flags.get(key);
  return typeof value === "string" ? value : undefined;
}

function num(flags: Map<string, string | boolean>, key: string): number | undefined {
  const value = str(flags, key);
  return value === undefined ? undefined : Number(value);
}

function require_(flags: Map<string, string | boolean>, key: string): string {
  const value = str(flags, key);
  if (!value) {
    console.error(`error: --${key} is required`);
    process.exit(2);
  }
  return value;
}

async function connect(flags: Map<string, string | boolean>): Promise<ImcoreBridge> {
  return ImcoreBridge.connect({ socketPath: str(flags, "socket") });
}

async function main(): Promise<void> {
  const { command, flags, repeats, positionals } = parseArgs(process.argv.slice(2));

  if (flags.has("version")) {
    console.log(version());
    return;
  }

  if (command === "help" || flags.has("help")) {
    process.stdout.write(USAGE);
    return;
  }

  if (!COMMANDS.has(command)) {
    console.error(`unknown command '${command}'\n`);
    process.stdout.write(USAGE);
    process.exitCode = 2;
    return;
  }

  if (command === "launch") {
    const bridge = await launch({ socketPath: str(flags, "socket") });
    const status = await bridge.status();
    console.log(`bridge connected (Messages pid ${status.pid})`);
    await bridge.close();
    return;
  }

  const bridge = await connect(flags);
  try {
    switch (command) {
      case "status": {
        const status = await bridge.status();
        if (flags.has("json")) {
          console.log(JSON.stringify(status, null, 2));
          break;
        }
        console.log(`ready: ${status.ready}   pid: ${status.pid}   protocol: ${status.protocol}`);
        const entries = Object.entries(status.capabilities).sort(([a], [b]) => a.localeCompare(b));
        for (const [name, available] of entries) {
          console.log(`  ${available ? "✓" : "·"} ${name}`);
        }
        break;
      }

      case "chats": {
        const chats = await bridge.listChats({ limit: num(flags, "limit") });
        if (flags.has("json")) {
          console.log(JSON.stringify(chats, null, 2));
          break;
        }
        for (const chat of chats) {
          // Name and handle together: the name is who it is, the handle is what
          // every other command takes as an argument.
          const who =
            chat.people?.map((p) => (p.name ? `${p.name} (${p.id})` : p.id)).join(", ") ??
            chat.participants.join(", ");
          const title = chat.displayName ? `${chat.displayName} — ` : "";
          const unread = chat.unreadCount ? ` (${chat.unreadCount} unread)` : "";
          console.log(`${chat.guid}\n    ${title}${who}${unread}`);
        }
        break;
      }

      case "history": {
        const result = await bridge.getHistory({
          chat: require_(flags, "chat"),
          limit: num(flags, "limit"),
        });
        if (flags.has("json")) {
          console.log(JSON.stringify(result, null, 2));
          break;
        }
        for (const message of [...result.messages].reverse()) {
          const who = message.senderName ?? message.sender ?? (message.isFromMe ? "me" : "?");
          const body = message.text ?? message.summary ?? `[${message.kind ?? "no text"}]`;
          console.log(`${who}: ${body}`);
        }
        break;
      }

      case "send": {
        // --file may be repeated; positionals are treated as files too, so
        // `send --chat C --text hi photo.png` does what it looks like.
        const files = [...(repeats.get("file") ?? []), ...positionals];
        const label = flags.get("sticker");
        const stickTo = str(flags, "stick-to");
        if (stickTo && label === undefined) {
          console.error("error: --stick-to needs --sticker");
          process.exit(2);
        }
        const service = str(flags, "service");
        if (service && service !== "iMessage" && service !== "SMS") {
          console.error(`error: --service must be iMessage or SMS, not '${service}'`);
          process.exit(2);
        }
        const result = await bridge.send({
          chat: require_(flags, "chat"),
          text: str(flags, "text"),
          subject: str(flags, "subject"),
          effect: str(flags, "effect"),
          replyTo: str(flags, "reply-to"),
          formatting: str(flags, "format") ? JSON.parse(str(flags, "format")!) : undefined,
          ...(files.length ? { files } : {}),
          ...(label === undefined
            ? {}
            : {
                sticker: {
                  ...(typeof label === "string" ? { label } : {}),
                  ...(stickTo ? { attachTo: stickTo } : {}),
                },
              }),
          ...(service ? { service: service as "iMessage" | "SMS" } : {}),
          ...(str(flags, "key") ? { idempotencyKey: str(flags, "key")! } : {}),
        });
        const notes = [result.service, result.duplicate ? "already sent" : undefined]
          .filter(Boolean)
          .join(", ");
        console.log(notes ? `${result.guid} (${notes})` : result.guid);
        break;
      }

      case "unread": {
        await bridge.markUnread(require_(flags, "chat"), str(flags, "message"));
        break;
      }

      case "notify": {
        await bridge.notifyAnyway(require_(flags, "chat"), require_(flags, "message"));
        break;
      }

      case "pin": {
        const result = await bridge.pin(require_(flags, "chat"), !flags.has("off"));
        console.log(result.pinned ? "pinned" : "not pinned");
        break;
      }

      case "mute": {
        const until = str(flags, "until");
        const result = await bridge.mute(require_(flags, "chat"), {
          muted: !flags.has("off"),
          ...(until ? { until: Number(until) } : {}),
        });
        console.log(
          result.muted
            ? result.until
              ? `muted until ${new Date(result.until * 1000).toLocaleString()}`
              : "muted"
            : "not muted",
        );
        break;
      }

      case "delete-history": {
        await bridge.deleteHistory(require_(flags, "chat"));
        console.log("history deleted");
        break;
      }

      case "delete-chat": {
        await bridge.deleteChat(require_(flags, "chat"));
        console.log("conversation deleted");
        break;
      }

      case "send-status": {
        const status = await bridge.sendStatus(positionals[0] ?? require_(flags, "guid"));
        if (flags.has("json")) {
          console.log(JSON.stringify(status, null, 2));
          break;
        }
        console.log(status.state);
        // "unknown" is not "no" — the row may simply not be written yet.
        if (status.state === "unknown" || status.state === "failed") process.exitCode = 1;
        break;
      }

      case "share-card": {
        await bridge.shareNameAndPhoto(positionals[0] ?? require_(flags, "handle"));
        console.log("shared");
        break;
      }

      case "report-junk": {
        await bridge.reportJunk(require_(flags, "chat"));
        console.log("reported as junk");
        break;
      }

      case "mentions": {
        const guids = await bridge.mentions(require_(flags, "chat"));
        if (!guids.length) console.log("no unread mentions");
        for (const guid of guids) console.log(guid);
        break;
      }

      case "send-as-text": {
        await bridge.sendAsText(require_(flags, "chat"), require_(flags, "message"));
        console.log("requested");
        break;
      }

      case "share-location": {
        const seconds = Number(require_(flags, "seconds"));
        await bridge.shareLocation(require_(flags, "chat"), seconds);
        console.log(`sharing location for ${seconds}s`);
        break;
      }

      case "group-photo": {
        await bridge.setGroupPhoto(require_(flags, "chat"), str(flags, "file"));
        break;
      }

      case "account": {
        const alias = str(flags, "alias");
        if (alias) {
          const result = await bridge.setSendingAlias(alias);
          console.log(`sending as ${result.sendingAs}`);
          break;
        }
        console.log(JSON.stringify(await bridge.account(), null, 2));
        break;
      }

      case "card": {
        const card = await bridge.nickname(positionals[0]);
        if (flags.has("json")) {
          console.log(JSON.stringify(card, null, 2));
          break;
        }
        // The photo is base64 and would bury everything else.
        const { photo: _photo, ...rest } = card;
        console.log(JSON.stringify(rest, null, 2));
        break;
      }

      case "stats": {
        const result = await bridge.stats({
          chat: str(flags, "chat"),
          since: num(flags, "since"),
        });
        console.log(JSON.stringify(result, null, 2));
        break;
      }

      case "typing": {
        const chat = require_(flags, "chat");
        const on = !flags.has("off");
        await bridge.setTyping({ chat, typing: on });
        const duration = num(flags, "duration");
        if (on && duration) {
          await new Promise((resolve) => setTimeout(resolve, duration * 1000));
          await bridge.setTyping({ chat, typing: false });
        }
        break;
      }

      case "tapback": {
        await bridge.tapback({
          chat: require_(flags, "chat"),
          message: require_(flags, "message"),
          kind: require_(flags, "kind") as TapbackKind,
          emoji: str(flags, "emoji"),
          remove: flags.has("remove"),
        });
        break;
      }

      case "retract": {
        await bridge.retract({
          chat: require_(flags, "chat"),
          message: require_(flags, "message"),
        });
        console.error("note: removed locally; propagation to the recipient is not guaranteed");
        break;
      }

      case "edit": {
        await bridge.edit({
          chat: require_(flags, "chat"),
          message: require_(flags, "message"),
          text: require_(flags, "text"),
        });
        break;
      }

      case "read": {
        await bridge.markRead(require_(flags, "chat"));
        break;
      }

      case "search": {
        const query = positionals.join(" ").trim() || str(flags, "query");
        if (!query) {
          console.error("error: a search query is required");
          process.exit(2);
        }
        const kind = str(flags, "kind");
        const results = await bridge.search({
          query,
          limit: num(flags, "limit"),
          chat: str(flags, "chat"),
          kinds: kind ? (kind.split(",") as SearchKind[]) : undefined,
        });
        if (flags.has("json")) {
          console.log(JSON.stringify(results, null, 2));
          break;
        }
        if (results.truncated) console.error("note: results truncated at the query deadline");
        for (const hit of results.hits) {
          const where = hit.title ?? hit.chatGuid ?? "";
          console.log(`[${hit.kind}] ${hit.guid}${where ? `  ${where}` : ""}`);
          if (hit.snippet) console.log(`    ${hit.snippet.replace(/\s+/g, " ").slice(0, 100)}`);
          if (hit.labels?.length) {
            console.log(`    labels: ${hit.labels.map((l) => l.label).join(", ")}`);
          }
        }
        break;
      }

      case "poll": {
        const choices = positionals.filter((p) => p.trim().length);
        if (choices.length < 2) {
          console.error("error: a poll needs at least two options");
          process.exit(2);
        }
        const result = await bridge.sendPoll({
          chat: require_(flags, "chat"),
          question: str(flags, "question"),
          options: choices,
        });
        console.log(`sent poll ${result.guid} with ${result.options} options`);
        break;
      }

      case "vote": {
        const raw = require_(flags, "option");
        const result = await bridge.votePoll({
          chat: require_(flags, "chat"),
          poll: require_(flags, "poll"),
          // A bare number names the option's position; anything else its text.
          option: /^\d+$/.test(raw) ? Number(raw) : raw,
        });
        console.log(`voted ${result.optionText || result.optionId} (${result.guid})`);
        break;
      }

      case "later": {
        const minutes = num(flags, "in");
        const at = num(flags, "at") ?? (minutes ? Math.floor(Date.now() / 1000) + minutes * 60 : undefined);
        if (!at) {
          console.error("error: pass --in MINUTES or --at UNIX_SECONDS");
          process.exit(2);
        }
        const result = await bridge.sendLater({
          chat: require_(flags, "chat"),
          text: require_(flags, "text"),
          at,
        });
        console.log(`scheduled ${result.guid} for ${new Date(at * 1000).toLocaleString()}`);
        break;
      }

      case "cancel": {
        await bridge.cancelScheduled({
          chat: require_(flags, "chat"),
          message: require_(flags, "message"),
        });
        console.log("cancelled");
        break;
      }

      case "archive": {
        // `--chat` is required going backwards and optional going forwards:
        // catching up means asking every conversation at once, since a caller
        // that was away does not know which ones have news.
        const since = num(flags, "since");
        const page = await bridge.storeHistory({
          chat: since === undefined ? require_(flags, "chat") : str(flags, "chat"),
          limit: num(flags, "limit"),
          beforeRowID: num(flags, "before"),
          sinceRowID: since,
        });
        if (flags.has("json")) {
          console.log(JSON.stringify(page, null, 2));
          break;
        }
        for (const message of page.messages) console.log(summarise(message));
        if (page.hasMore) {
          console.error(
            since === undefined
              ? `note: more history available — pass --before ${page.nextBeforeRowID}`
              : `note: more waiting — pass --since ${page.nextSinceRowID}`,
          );
        } else if (since !== undefined) {
          console.error(`note: caught up — resume from --since ${page.nextSinceRowID}`);
        }
        break;
      }

      case "chats-with": {
        const chats = await bridge.chatsWith(positionals[0] ?? require_(flags, "handle"));
        if (flags.has("json")) {
          console.log(JSON.stringify(chats, null, 2));
          break;
        }
        if (chats.length === 0) {
          console.error("no conversation has ever included that address");
          process.exitCode = 1;
          break;
        }
        for (const chat of chats) {
          const who = chat.displayName ?? chat.participants.join(", ");
          console.log(`${chat.isGroup ? "group" : "dm   "}  ${chat.guid}  ${who}`);
        }
        break;
      }

      case "resolve": {
        const chats = await bridge.resolveChats(positionals[0] ?? require_(flags, "chat"));
        if (flags.has("json")) {
          console.log(JSON.stringify(chats, null, 2));
          break;
        }
        // First is the most recently active — the thread to answer in.
        for (const [i, chat] of chats.entries()) {
          console.log(`${i === 0 ? "*" : " "} ${chat.guid}  ${chat.service ?? ""}`);
        }
        break;
      }

      case "details": {
        console.log(JSON.stringify(await bridge.chatDetails(require_(flags, "chat")), null, 2));
        break;
      }

      case "avatar": {
        const picture = await bridge.avatar(positionals[0] ?? require_(flags, "handle"));
        const out = str(flags, "out");
        if (!out) {
          console.log(JSON.stringify(picture, null, 2));
          break;
        }
        await import("node:fs").then((fs) =>
          fs.writeFileSync(out, Buffer.from(picture.data, "base64")),
        );
        console.log(`wrote ${out} (${picture.mimeType})`);
        break;
      }

      case "contact": {
        const card = await bridge.contact(positionals[0] ?? require_(flags, "handle"), {
          includePhoto: flags.has("photo"),
        });
        if (flags.has("json") || flags.has("photo")) {
          console.log(JSON.stringify(card, null, 2));
          break;
        }
        const lines: string[] = [card.name ?? card.handle ?? "(no name)"];
        if (card.organization) {
          lines.push(`  ${[card.jobTitle, card.organization].filter(Boolean).join(", ")}`);
        }
        if (card.nickname) lines.push(`  nickname: ${card.nickname}`);
        for (const phone of card.phoneNumbers ?? []) {
          lines.push(`  phone (${phone.label ?? "other"}): ${phone.number}`);
        }
        for (const email of card.emailAddresses ?? []) {
          lines.push(`  email (${email.label ?? "other"}): ${email.address}`);
        }
        if (card.birthday) {
          const { year, month, day } = card.birthday;
          lines.push(`  birthday: ${[year, month, day].filter(Boolean).join("-")}`);
        }
        for (const date of card.dates ?? []) {
          const { year, month, day } = date.date;
          lines.push(`  ${date.label ?? "date"}: ${[year, month, day].filter(Boolean).join("-")}`);
        }
        for (const address of card.postalAddresses ?? []) {
          const parts = [address.street, address.city, address.state, address.postalCode];
          lines.push(`  address (${address.label ?? "other"}): ${parts.filter(Boolean).join(", ")}`);
        }
        for (const url of card.urls ?? []) lines.push(`  url (${url.label ?? "other"}): ${url.url}`);
        for (const relation of card.relations ?? []) {
          lines.push(`  ${relation.label ?? "related"}: ${relation.name}`);
        }
        if (card.note) lines.push(`  note: ${card.note}`);
        lines.push(`  photo: ${card.hasPhoto ? "yes (--photo to fetch)" : "none"}`);
        console.log(lines.join("\n"));
        break;
      }

      case "whois": {
        const who = await bridge.whois(positionals[0] ?? require_(flags, "handle"));
        console.log(JSON.stringify(who, null, 2));
        break;
      }

      case "new-chat": {
        const chat = await bridge.createChat(positionals, str(flags, "name"));
        console.log(`${chat.isNew ? "started" : "existing"} ${chat.guid}`);
        break;
      }

      case "delete": {
        const result = await bridge.deleteMessages({
          chat: require_(flags, "chat"),
          messages: positionals,
        });
        console.log(`deleted ${result.deleted} of ${result.requested} (matched ${result.matched})`);
        break;
      }

      case "scheduled": {
        const { messages } = await bridge.scheduled(str(flags, "chat"));
        if (flags.has("json")) {
          console.log(JSON.stringify(messages, null, 2));
          break;
        }
        if (messages.length === 0) {
          console.log("nothing scheduled");
          break;
        }
        for (const message of messages) {
          const when = message.scheduledFor
            ? new Date(message.scheduledFor * 1000).toISOString()
            : "unknown time";
          console.log(`${when}  ${message.chatGuid ?? "?"}  ${message.guid}`);
          console.log(`  ${(message.text ?? "").replace(/\s+/g, " ").slice(0, 120)}`);
        }
        break;
      }

      case "message": {
        const guid = positionals[0] ?? str(flags, "guid");
        if (!guid) {
          console.error("error: a message GUID is required");
          process.exit(2);
        }
        console.log(JSON.stringify(await bridge.storeMessage(guid), null, 2));
        break;
      }

      case "watch": {
        for await (const event of bridge.events()) {
          console.log(JSON.stringify(event));
        }
        break;
      }

      // Unreachable for anything a user types, since `main` refuses a command
      // USAGE does not list before connecting. It catches the reverse drift: a
      // command documented above with no case here.
      default:
        console.error(`'${command}' is documented but not implemented\n`);
        process.exitCode = 2;
    }
  } finally {
    if (command !== "watch") await bridge.close();
  }
}

main().catch((error: unknown) => {
  if (error instanceof ImcoreBridgeError) {
    console.error(`${error.name}: ${error.message}`);
    process.exit(1);
  }
  throw error;
});
