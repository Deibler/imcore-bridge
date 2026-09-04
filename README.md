# imcore-bridge

Automate and observe the macOS Messages app from Node or Bun: live inbound
message events, conversation context (participants, attachments, transcripts,
delivery and read state), and write operations such as typing indicators.

The goal is that a program reading a conversation through this library sees
what a person reading it in the UI sees — who is speaking, what they said, what
was attached, what was reacted to, and what has been delivered or read.

> **Read this first.** This library works by injecting code into Messages.app
> using private Apple frameworks. It requires disabling macOS security
> features. See [Security posture](#security-posture) and [SECURITY.md](SECURITY.md).

## How it works

A small Objective-C dylib is loaded into Messages.app via
`DYLD_INSERT_LIBRARIES`. Once IMCore is up, the dylib dials a Unix socket owned
by your process and speaks newline-delimited JSON-RPC over it. A TypeScript
client drives that socket directly, so there is no subprocess per operation.

```
your process ──── owns/listens ───▶ ~/Library/Containers/com.apple.MobileSMS/Data/tmp/imcore-bridge.sock
                                              ▲
                                              │ dials out
                        Messages.app + injected dylib (IMCore)
```

The bridge dials out rather than listening because Messages.app is sandboxed
with `com.apple.security.network.client` and no `network.server` entitlement:
inside that sandbox `bind()` succeeds but `listen()` fails with `EPERM`.

## Requirements

- Apple silicon Mac (the dylib is built `arm64e`; build with `UNIVERSAL=1` for Intel)
- Xcode Command Line Tools (`xcode-select --install`)
- **System Integrity Protection disabled**, and the boot argument
  `amfi_get_out_of_my_way=0x1`. Messages.app is signed with the
  `library-validation` flag; without both of these the dylib will not load.
- Full Disk Access for your terminal if you also read the message store

## Quick start

```bash
npm install imcore-bridge
```

The dylib is compiled at install time rather than shipped. A prebuilt binary
that gets injected into Messages.app is not something to accept from a
registry sight unseen, and it would have to be architecture matched and signed
anyway. The sources and the Makefile are in the package, and `postinstall`
runs `make` where it landed.

That build is best effort and never fails the install, because it does not
have to succeed for the package to be useful: reading the message store and
talking to a bridge that is already running need no dylib. If it was skipped,
either because the Xcode Command Line Tools were missing or because you
installed with scripts disabled, build it whenever you like:

```bash
npx imcore-bridge build-native
```

Sending before that has happened fails with the path it looked in and the
command that fixes it, rather than with a missing file.

To work on the bridge itself, or to run it from a checkout:

```bash
git clone https://github.com/Deibler/imcore-bridge.git
cd imcore-bridge
npm ci                      # postinstall builds the dylib
npm run build               # make -C native, then tsc
```

A rebuilt dylib takes effect the next time Messages.app launches. `launch()` quits and relaunches a running Messages.app so the dylib loads; pass `{ restart: false }` to attach to one that already has it.

```ts
import { launch, Effects } from "imcore-bridge";

const bridge = await launch();   // injects into Messages, waits for the handshake

// Capabilities are probed live from the running Messages build — never assumed.
if (bridge.can("typing")) {
  await bridge.setTyping({ chat: "+15551234567", typing: true });
}

const { chat, messages } = await bridge.getHistory({ chat: "+15551234567", limit: 50 });
console.log(chat.displayName, chat.people);

await bridge.send({
  chat: "+15551234567",
  text: "hello",
  replyTo: messages[0]?.guid,          // threads the reply onto that message
  effect: Effects.screen.confetti,
});

// Searches the index Messages itself uses, so photos match what is in them.
const { hits } = await bridge.search({ query: "dog", kinds: ["attachment"] });
console.log(hits[0]?.labels?.map((l) => l.label));   // [ "Dog", "Canine", "Mammal" ]

for await (const event of bridge.events()) {
  if (event.type === "message") {
    console.log(`${event.data.senderName ?? event.data.sender}: ${event.data.text}`);
  }
}
```

Or from a shell:

```bash
imcore-bridge launch
imcore-bridge status                       # capability matrix for this machine
imcore-bridge chats --limit 10
imcore-bridge history --chat "+15551234567" --limit 20
imcore-bridge search "dog" --kind attachment
imcore-bridge archive --chat "+15551234567" --limit 200   # full history, paged
imcore-bridge poll --chat "+15551234567" --question "Lunch?" Pizza Sushi Tacos
imcore-bridge vote --chat "+15551234567" --poll GUID --option Sushi
imcore-bridge later --chat "+15551234567" --text "morning" --in 480
imcore-bridge watch                        # live events as JSON lines
```

**Sending is real and cannot be reliably undone** — unsending applies locally
but does not always reach the recipient. Test against someone who has agreed to
receive test traffic.

## What you get

**Conversations** — GUID, display name, participants resolved to contact names,
group vs 1:1, service (iMessage/SMS), unread count, pinned, muted, last activity.

**Messages** — sender (with name), text, timestamp, delivery/read/played state
with timestamps, mentions, reply target, edit and retraction stamps, expressive
effect, and the balloon kind (`text`, `attachment`, `link`, `poll`, `tapback`,
`app`).

**Attachments** — filename, MIME type, on-disk path, size, sticker flag, and the
on-device audio transcription when Messages has produced one. Image glyphs come
back with the words Messages keeps for them, so a Genmoji reads as what it
depicts rather than as an opaque file.

**Group events** — the grey lines a group conversation is punctuated with:
someone added, a rename, the picture changing. The conversation's own picture
and the participants' contact photos are readable too.

**People, not phone numbers** — every handle in a result carries the name of the
person behind it, and `contact(handle)` returns their whole card: other numbers,
email addresses, birthday, employer, related people, and the photo on request.

**Edits and unsends** — the full version chain of an edited message with the
time of each, and the difference between an unsend that reached the other side
and one that did not.

**Search** — over the private CoreSpotlight domain Messages donates to, which is
what its own search field queries. That brings work the device has already done:
image classification (searching `dog` finds photos of dogs), text recognised
inside images, and spoken content in audio and video. Scope to one conversation
or search everything, filtered by kind. See [docs/SEARCH.md](docs/SEARCH.md).

**Deep history** — the whole archive, not just what the app has loaded, paged
backwards through the message store. Bodies come back readable: most messages
keep their text in an encoded blob rather than a text column, and it is decoded
into text plus the runs that make it up — attachments, mentions and links in
place. See [docs/HISTORY.md](docs/HISTORY.md).

**Rich balloons** — a link's title, summary, site name and preview image, and a
poll's question, options and running tally, decoded from the payload they
arrive in. Reactions and stickers fold onto the message they belong to, the way
the UI draws them rather than the way the store keeps them.

**Polls and Send Later** — create a poll and vote in it, or schedule a message
for later, list what is still waiting, and cancel it before it goes.

**Sending files and stickers** — a file goes out with its text as one message,
to any conversation. `sticker` sends it as a sticker instead, which is not a
separate API: a sticker is a file transfer wearing three pieces of metadata.

**Your own identity** — the Apple ID that is signed in, every address that
reaches it, which one outgoing messages are attributed to, and whether texts
from a paired iPhone are relayed here. Without it there is no way to tell your
own handles from anyone else's.

**Name & Photo cards** — the name and picture someone chose to share over
iMessage, which Messages displays in preference to the contact card. Reading
Contacts alone can give a different name than the one on screen, and a card
exists for people with no Contacts entry at all.

**Conversation state** — mark read or unread, pin and unpin, push a single
message past a recipient's mute or Focus, and set a group's picture.

**Statistics** — counts by person, hour, weekday and month, media by type and
total bytes, and first and last contact, over one conversation or everything.

**Live events** — `message`, `message-sent`, `message-updated` (delivery and read
transitions), `read-receipt`, `typing`, `unread-changed`, `chat-item`.

See [docs/CAPABILITIES.md](docs/CAPABILITIES.md) for the full matrix, including
what is not yet implemented.

## Design notes

- **Capability-gated, never assumed.** Every feature is derived from a live
  `respondsToSelector:` probe and reported in `status`. When a macOS update
  removes a selector, that one feature reports unavailable instead of the
  bridge breaking.
- **Typed errors.** `BridgeUnavailableError`, `UnsupportedFeatureError`,
  `RpcTimeoutError`, `ChatNotFoundError` distinguish "not installed" from "this
  macOS dropped it" from "Messages is wedged".
- **Never crash the host.** Every operation is guarded by a selector check and
  an exception handler; Messages.app is the user's real messaging client.
- **One host only.** The injected code announces itself with a `hello` carrying
  its pid, so a second injected instance is detected and refused rather than
  duplicating every send.

## Security posture

This library requires you to turn off protections that exist for good reasons.

- Disabling SIP and setting `amfi_get_out_of_my_way=0x1` is a real, system-wide
  reduction in security, not a formality. Any process can then inject into
  signed applications.
- It uses private Apple frameworks. There is no compatibility contract; Apple
  can and does change these between releases. No stability is claimed beyond
  the versions listed in the changelog.
- The socket lives inside the Messages container and is created with mode
  `0600`. Anything able to write to it can send messages as you.

Verified on macOS 26.4.1 (build 25E253), Messages 26.0.

## License

MIT

This project is not affiliated with or endorsed by Apple. iMessage, Messages and macOS are trademarks of Apple Inc.
