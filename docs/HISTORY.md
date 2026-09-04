# Deep history

`getHistory` reads IMCore's in-memory window — what the app has loaded, which is
recent and bounded. `storeHistory` reads the message store itself, so it reaches
the whole archive.

```ts
let cursor: number | undefined;
do {
  const page = await bridge.storeHistory({ chat: "+15550000000", limit: 200, beforeRowID: cursor });
  for (const message of page.messages) console.log(message.text);
  cursor = page.nextBeforeRowID;      // pass back for the next older page
} while (cursor);
```

Pages come back oldest-first so a transcript reads top to bottom, and page
backwards with `nextBeforeRowID`. Paging is keyed on row id rather than date:
timestamps are not unique, and a cursor that is not unique either repeats or
skips messages at the boundary.

## Where it reads from

The store is `~/Library/Messages/chat.db`, opened read-only *inside*
Messages.app. Running inside the host is what makes this work without a Full
Disk Access prompt — Messages already holds that grant — and there is no
in-process alternative: IMCore's own store classes (`IMDMessageStore` and
friends) live in imagent, not in this process.

The handle is opened `mode=ro`, not `immutable=1`. An immutable handle ignores
the write-ahead log, which both misses recent messages and risks a torn read
while imagent is checkpointing. A read-only handle follows the WAL like any
other reader: consistent rows, current data, and never a writer, so the running
app is never blocked.

## Message bodies are encoded

Most rows have no plain `text`. The body lives in `attributedBody`, a typedstream
archive of an attributed string — in one real store, about 96% of rows. Reading
the column and hoping for text yields almost nothing.

The bridge decodes it and returns readable `text`, plus the runs that make up
the body:

```ts
const [message] = page.messages;
message.text;      // "Look at this ￼ from platform.claude.com"
message.parts;     // [{kind:"text",…}, {kind:"attachment", attachmentGuid:"at_0_…"}, …]
message.mentions;  // [{handle:"+15550000000", text:"Ada", location:9, length:5}]
message.links;     // [{url:"https://…", text:"platform.claude.com/…", isRichLink:false}]
```

Runs are how text and attachments interleave: an attachment is a U+FFFC
placeholder in the body tagged with its transfer GUID. That GUID is the same
identifier a search hit carries, so hits and body parts line up without a
lookup.

The raw base64 is returned only when decoding fails, so nothing is ever lost
silently, and a page stays small.

## Rich balloons

Link previews and polls carry their content in `payload_data`, which is decoded
the same way:

```ts
message.link;   // { title, summary, siteName, itemType, url, imageUrl, iconUrl }
message.poll;   // { question, creator, totalVotes, options: [{ id, text, voteCount, voters }] }
```

## Handles resolve to people

The store keeps handles and nothing else, so a page of deep history would read
as a list of phone numbers even for people in Contacts — where the app shows
names throughout. Every handle in a result is resolved once and the name written
alongside it:

```ts
message.senderName;              // "Ada Lovelace", where message.sender is "+15550000000"
message.event?.actorName;        // who performed a group event
message.event?.participantName;  // who it was done to
message.tapbacks?.[0]?.senderName;
```

The handle itself stays put, so anything keyed on it still works. For the whole
card behind a handle — other numbers, email addresses, birthday, employer — use
`contact(handle)`.

## Attachments

A message's files are in another table, and the row itself has no text to stand
in for them — so a page of photos, voice notes or Genmoji reads as a run of
empty messages unless they are joined on:

```ts
message.attachments;
// [{ filename, localPath, mimeType, uti, sizeBytes, transferState,
//    description, stickerSource, isSticker, hidden, sensitive }]
```

`description` is what an image glyph depicts, in words — Messages stores it for
accessibility, and it is the difference between "an image" and knowing a Genmoji
of a shark in a party hat was sent. `stickerSource` names the extension a
sticker came from, which separates a Genmoji from a Memoji from a third-party
pack.

`hidden` and `sensitive` both mean there is nothing at `localPath` to open: the
file was never downloaded, or Communication Safety is holding it back.

The store's own `user_info` column is deliberately not exposed. It holds the
iCloud transfer's URL and decryption key, which say nothing about what was sent.

## Group events

A group conversation is punctuated with lines that are not messages — someone
added, a rename, the picture changing. They are ordinary rows distinguished only
by `item_type` and a few columns that are empty on every real message, so a
reader that ignores them sees people appearing without having been added and a
name that changes with nothing to explain it.

```ts
message.event;  // { kind: "group-renamed", actor: "+15550000000", name: "Trip" }
```

Kinds: `participant-added`, `participant-change`, `group-renamed`,
`group-photo-set`, `group-photo-removed`, `share`, `unknown`.

Only codes confirmed against real rows are named; anything else keeps its raw
`actionCode` or `itemType` rather than being guessed at or dropped. A picture
change is one of several codes whose individual meanings are not established —
macOS 26 appears to reuse the same row for conversation backgrounds — but the
distinction that matters reads off the row itself: a change carrying an image
sets one, a change carrying none clears it.

The picture a group currently uses is not in the transcript at all. It is named
in the chat's own property list, and `chatDetails` reads it:

```ts
const details = await bridge.chatDetails("any;+;chat123");
details.groupPhoto;      // { guid, filename, localPath, mimeType, sizeBytes }
details.hasBackground;   // a conversation background is set
details.archived; details.filtered; details.blocked;
```

## Edits and unsends

The earlier versions of an edited message are in `message_summary_info`, not in
the recoverable-parts table (which holds unsent messages awaiting deletion and
is usually empty):

```ts
message.editHistory;
// [{ part: 0, versions: [{ text: "I vote yet", date }, { text: "I vote yes", date }] }]
```

The chain includes the current text as its last entry — it is only meaningful
with its endpoint in it.

An unsend is subtler, and getting it wrong is easy:

```ts
message.unsent;        // every part removed from this side
message.unsentParts;   // [0] — a message can be unsent one part at a time
message.unsendFailed;  // the retraction never reached the other side
```

`unsendFailed` is the state the app draws as **"Not Unsent"**: the recipient
still sees the message and it can never be taken back. Nothing else in the row
says so — `date_retracted` stays 0 and the body is empty either way.

## Scheduled messages

A message being held for later delivery is not in the conversation yet, so
nothing reading a transcript will find one:

```ts
const { messages } = await bridge.scheduled();   // every conversation
messages[0].scheduledFor;   // when it goes out
messages[0].scheduledAt;    // when it was scheduled — not the same thing
messages[0].chatGuid;       // where it actually landed
```

Call it without a chat. Messages does not always file a scheduled message under
the conversation it was addressed to, and cancelling needs the one it landed in.

## Reactions, votes and stickers fold onto their target

Reactions, poll votes and stickers are each stored as an ordinary message
pointing at another one. Nobody reading a conversation sees them that way: a
reaction is drawn on the bubble it reacts to, a vote changes the tally inside
the poll, a sticker sits on the message it was placed on. History folds them the
same way, so a page reads like the transcript rather than like the table.

```ts
message.tapbacks;  // [{ kind: "laugh", sender: "+15550000000", isFromMe: false }]
message.stickers;  // [{ guid, sender, isFromMe, date }]
message.poll;      // votes already tallied onto the options
```

Two details this depends on, both of which silently lose data if missed:

- A reaction is written *after* the message it points at, so it often falls
  outside the page. They are looked up rather than read from the page.
- The target is named `p:<index>/<guid>` for a message part but `bp:<guid>` for
  a whole balloon. Handling only the first form drops every reaction left on a
  link or a poll.

Reaction kinds are the six fixed shapes plus `emoji`, which carries an arbitrary
character — that is what the emoji and Genmoji pickers send.

A reaction whose target is not in the page stays as its own entry rather than
being dropped, so nothing is lost at a page boundary.

`storeMessage` folds the same way, so reading a poll by GUID returns its tally
rather than an empty poll.

## Limits

- **Reading only.** Nothing here writes to the store; the bridge never opens it
  for writing.
- **Deleted messages are gone.** Unlike the search index, which can outlive the
  store, a deleted row is not returned. `storeMessage` reports
  `message_not_found`, which for an old search hit means "deleted", not "error".
- **Times are Unix seconds.** The store keeps Cocoa seconds (and sometimes
  nanoseconds); both are converted on the way out.
- **`hasMore` is per page.** It reports whether the page filled its limit, so a
  final page that exactly fills it takes one more request to confirm the end.
- **A zero date means never.** `date_read`, `date_delivered`, `date_edited` and
  the rest are 0 until they happen, and are left at 0 rather than shifted into
  1970 or 2001.
- **A malformed row fails the request, not the app.** Rows carry archives and
  plists written by other software and older releases; decoding runs inside
  Messages, where an uncaught exception aborts the user's app mid-conversation.
  One bad row reports `store_error` instead.
