# imcore-bridge

## 0.2.0

### Minor Changes

- 976b965: Stop guessing whether an operation happened: ask first, retry safely, and check
  afterwards.
  
  **Group membership changes are asked about before they are made.** Removing
  someone from a group of three would leave two, and IMCore declines — by doing
  nothing and saying nothing, which reads as a change that took effect. The docs
  here recorded that as a known partial and left callers to detect it by reading
  the group back. IMCore knows the answer in advance: `canAddParticipants:` and
  `canRemoveParticipants:` are what the app asks before it enables the menu item.
  Both membership calls now ask, and refuse with a reason instead of reporting a
  success that did nothing.
  
  The check is also exposed on its own as `group.canAdd` / `group.canRemove`,
  because it is read-only and therefore the one thing in this area that can be
  verified without a real conversation changing to tell you. Which is how it was
  verified: a three-person group answers no to a removal, a nine-person group
  answers yes, and a 1:1 answers no to an addition. Twenty-eight of the sixty-two
  groups on the machine this was written on have three people in them, so the
  silent case was the common one.
  
  **A send can now be repeated safely, and its fate looked up afterwards.** A send
  that reaches Messages and then loses its reply — a timeout, a dropped socket, a
  client that died in between — left the caller unable to tell whether it went
  out. Retrying sent it twice; not retrying dropped it; neither was fixable
  afterwards, because nothing in the message store tied an attempt to the caller's
  intent. `send` now takes an `idempotencyKey` of the caller's choosing: the same
  key inside the window returns the original GUID marked `duplicate` and sends
  nothing. Verified by sending the same key twice and finding one bubble in the
  store. The record lives in the injected process and is dropped when Messages
  restarts, deliberately — it covers a retry cycle, not a decision to send the
  same thing again hours later.
  
  `sendStatus` answers the other half, by GUID: `unknown`, `pending`, `sent`,
  `delivered`, `read` or `failed`. `unknown` is a real answer rather than a
  failure, since a message not yet written to the store and one that was never
  sent are indistinguishable from here — so it is reported as what it is instead
  of being guessed between.
  
  **A sticker can be stuck onto an existing bubble**, the way peel-and-stick does,
  rather than only sent on its own. A stuck sticker turns out not to be a message
  with a picture in it: it is an _associated_ message, addressed the way a tapback
  is — `p:<part>/<guid>` plus the range it covers — carrying type 1000 and a
  sticker transfer. That shape is in no header; it came from reading the nine
  already in this machine's store. The one factory that takes both a transfer list
  and the association triple is the long initialiser, since every convenience
  method drops one or the other — the same trap the ordinary send path documents.
  Verified by sending one and reading it back with the right type, target and
  sticker flag.
  
  **Deleting a conversation** is now distinct from emptying one. `deleteHistory`
  leaves the conversation in the list with nothing in it, which is not what a
  person means by deleting a chat; `deleteChat` removes the thread itself via
  `-[IMChat remove]`. Both are local — the other party keeps their copy either
  way. Shipped unverified: there is no throwaway conversation on this machine, and
  unlike emptying, this one takes the thread.
  
  **Sharing your Name & Photo** is possible where before only reading other
  people's cards was. It is deliberately an explicit call and never a side effect
  of anything else, because it discloses the name and picture of whoever is
  running this. Shipped unverified for the same reason: testing it means sending a
  real person your profile.
- 976b965: Keep the bridge up without being asked: `supervise()`.
  
  `launch()` is one shot. It owns a socket, injects, and hands back a connected
  bridge — which is right for a script and not enough for a process that has to
  stay reachable for days. The client already survives Messages restarting on its
  own, because the socket outlives the app and the injected side re-dials with
  backoff. Two things it could not do alone are what `supervise()` adds.
  
  **Messages is brought back when nothing else will.** It crashed, the user quit
  it, or it is running without the dylib and so will never dial. Relaunches are
  serialised and backed off, so an app that refuses to start is retried at a
  widening interval instead of in a loop, and concurrent callers collapse into one
  restart rather than several.
  
  **A bridge that stops answering is noticed.** This is the failure that prompted
  it: the socket stays open and `isConnected` keeps reporting true while the
  injected side has stopped serving RPCs. Every call then burns its full timeout
  before failing, and because the connection never dropped there is nothing to
  react to. Asking periodically, with a deadline much shorter than the one real
  sends need, is what separates a quiet bridge from a wedged one — and relaunching
  Messages is the only thing that clears it. `relaunch()` is public for the same
  reason: a send that just timed out is better evidence than the next probe, and
  the host should not have to wait for one.
  
  An already-injected Messages is adopted rather than restarted, so a host that
  restarts often stops closing the user's messaging client every time it comes up.
  `stop()` leaves Messages running — the host exiting is not a reason to quit it.
  
  The bridge handed back is stable across relaunches, so long-lived consumers like
  `events()` keep working and never resubscribe.
- 66f3dec: Make the package installable from npm. The dylib is now compiled at install
  time by a best effort `postinstall` that never fails the install, and a new
  `imcore-bridge build-native` command builds it later for anyone who installed
  with scripts disabled or without the Xcode Command Line Tools. The missing
  dylib error now names a command a consumer can actually run.
- 976b965: Catch up on what was missed, choose the service, and stop losing conversations
  to a single-answer lookup.
  
  **Reading forwards from a cursor.** `storeHistory` paged backwards only, and
  required a chat. That answers "further into this conversation's past" and
  cannot answer "what happened while I was not running" — you would start at the
  newest message and walk towards the cursor, not knowing when to stop, across
  every conversation separately, because a caller that was away does not know
  which ones have news. It now takes `sinceRowID` and reads forwards, with `chat`
  optional: leaving it out spans every conversation in one scan and stamps each
  message with the `chatGuid` it came from. Passing both cursors is refused
  rather than resolved, since a window bounded at both ends has no single
  position to continue from. Asked with no cursor at all it answers with the
  newest page, whose `nextSinceRowID` is where to start — so a first run begins
  at now instead of replaying years of archive. Two details that only matter in
  use: the cursors are taken from the page as read rather than from what came
  back, so a page that folded entirely into reactions still advances; and a poll
  that finds nothing hands back the cursor it was given rather than zero, so a
  caller storing the reply unconditionally does not reset itself.
  
  **A rowid on live events.** A message event carried no store rowid, so a
  consumer could follow the stream but not record where it got to — which made
  the catch-up above impossible to start from. IMCore calls it `messageID` and it
  is the store's ROWID: verified equal on a few hundred messages across a dozen conversations,
  with none missing it. It is absent until Messages has written the message,
  which for one just received can be a moment after the event fires. Absent is
  the safe direction — a consumer that cannot advance its cursor sees that
  message twice after a restart, where a guessed rowid would move the cursor past
  messages that were never delivered.
  
  **Choosing which service carries a message.** `send` takes `service`, naming
  iMessage or SMS. It routes that one message over the matching account and
  deliberately leaves the conversation's own alone, since rewriting it would
  change where every later message goes, including ones sent from the app by
  hand. The result now names the service that carried it either way, which is the
  only way to learn whether something went out as an iMessage or as a text. An
  unknown name is rejected rather than falling through to the conversation's own
  service and reading as though it had been honoured, and a Mac with no text
  relay is refused rather than quietly sending an iMessage instead — both
  verified, and neither sends anything. Forcing SMS is unverified end to end:
  this machine reports `smsRelayCapable: false`, so there is no SMS account here
  to send on.
  
  **Every conversation an identifier maps to.** `resolveChat` answers with one
  chat, which is fine for addressing a send and wrong for reading: the same
  person can have an iMessage thread and an SMS thread, and a reply sent into the
  quiet one goes somewhere nobody is looking. `resolveChats` returns the set,
  most recently active first. Asking for a plain phone number on the machine this
  was written on turned up two threads for one person — the ordinary one, and a
  second whose GUID embedded the contact's name, last used four months earlier.
  
  **Every conversation a handle appears in.** `chatsWith` answers with all of
  them, groups included. Empty means the address has never been spoken to, which
  is what makes it usable as a check before sending somewhere new rather than
  only as a way to find shared groups — and it is an empty list rather than an
  error, so a caller does not have to tell "no such person" apart from "the
  bridge is down". Numbers match on their national digits, because the same
  person is written `+15551234567` in one chat and `(555) 123-4567` in another
  depending on how the conversation started; a plain string comparison answers
  "never heard of them" for someone you are mid-conversation with. Fewer than ten
  digits is not matched at all, since a short match would put unrelated people in
  the same conversation.
  
  **A typing indicator no longer outlives the client that set it.**
  `setLocalUserIsTyping:` is a flag with no expiry: nothing clears it but an
  explicit stop. A client that died mid-turn left the dots showing in a real
  conversation with nobody to turn them off, and a person on the other end
  waiting for a message that was never coming. The bridge now tracks what it
  switched on and clears it when the host disconnects — a clean close, a crash
  and a kill all reach the injected side the same way, as EOF on the socket. A
  turn that stops the indicator itself leaves nothing to clear.
  
  `hasMore` was reaching callers as `1` rather than `true`, from a C comparison
  boxed as a number. The `send` documentation still described attachments going
  out through Messages' scripting interface as separate messages, which stopped
  being true when they moved to the injected path — they travel with the text as
  one message, to any conversation, group chats included.

### Patch Changes

- 976b965: Refuse a socket another host is still serving, instead of taking it.
  
  `listen()` unlinked the socket path unconditionally before binding, on the
  assumption that anything there was a leftover. When another host was still
  serving it, that was silent theft: the new host bound a fresh inode, the old one
  kept a socket bound to an inode nothing could reach any more, and the injected
  side dialled whichever had bound last.
  
  The result is a bridge that cannot be diagnosed from either end. In the case that
  prompted this, three throwaway scripts from a debugging session three days
  earlier were still holding the path — owning the socket keeps the process alive,
  so they never exited. The daemon bound after them, was never dialled, and spent
  half an hour relaunching Messages and reporting that SIP must be misconfigured.
  SIP was fine.
  
  `listen()` now probes the path first and refuses with a message naming `lsof`
  when something answers. A file nobody is serving is still reclaimed, so an
  unclean exit does not need manual cleanup. The failure that used to take an
  afternoon now happens at startup and says what to look at.
  
  The launch and relaunch timeout messages also stop blaming SIP for everything.
  They name both causes — a dylib that did not load, and a socket held elsewhere —
  because only one of them was ever printed and it was usually the wrong one.
- 976b965: Remove account forcing, and refuse to act on a chat that is not the one addressed.
  
  `sendMessage:onAccount:` — the Send as Text Message mechanism, reached by
  naming a `service` the chat was not bound to — re-registers the chat against
  our own account inside imagent. From then on the registry object's recipient
  reads as our own address and every send into it lands in the note-to-self
  thread while reporting success. Every observed poisoning traces back to this
  call, so it is gone: a message goes however its conversation already sends,
  and naming the other service is refused with `service_mismatch` instead of
  taking the poisoned route.
  
  Beneath that, resolution now carries an invariant. Every write op asserts the
  chat it resolved really is the conversation the spec addressed — identifier,
  sole participant, or recipient must name the addressed handle, across e:/p:
  type-prefix spellings — and refuses with `chat_mismatch` when the registry's
  object is wrong, including the poison shape where the object has been fully
  relabelled with our own identity (previously invisible to `chat_poisoned`,
  which reads a self-identified chat as legitimate note-to-self). The typing
  indicator honors the same invariant instead of lighting up the wrong thread.
  
  Two propagation paths are closed with it: `IMBLookupHandle` no longer returns
  a poisoned chat's sole participant for an address it does not match (which
  handed our own IMHandle to `createChat`/`whois` and spread the damage), and
  the last-resort registry scan only matches 1:1 conversations by participant,
  so a DM spec can never resolve into a group. Address matching itself now
  strips IMCore's e:/p: prefixes, so both spellings of one address compare
  equal everywhere.
- 976b965: Only force an account when the conversation is known to be somewhere else.
  
  Naming a service routes one message over that service's account, which is what
  the composer does for Send as Text Message. The check for whether that was
  needed asked whether the chat was already on the named service, and a chat whose
  account is not bound yet — freshly resolved, or Messages only just relaunched —
  answers with no service at all. That read as "on a different service", so an
  ordinary reply went out with `sendMessage:onAccount:` instead of into the chat,
  and arrived at the sender's own address rather than the recipient's. It looked
  like a successful send from every angle except the recipient's.
  
  Unknown now counts as "not somewhere else". Forcing an account is the
  destructive branch, so it is taken only on positive evidence that the
  conversation is on another service.

## 0.1.0

### Minor Changes

- Initial release: read conversations, observe them live, and write to them.

  Reading covers participants resolved to contact names, delivery/read/played
  state, reply threading, attachments with Messages' own on-device audio
  transcriptions, and balloon classification for links, polls and tapbacks.
  Events fire in-process as messages arrive, as people start typing, and as
  delivery turns into read.

  Writing covers sending (with subject, expressive effects, and replies threaded
  onto a target message), editing a sent message, and marking a conversation
  read.

  Verified on macOS 26.4.1 (25E253) with Messages 26.0. Capabilities are probed
  from the running build rather than assumed, so a release that moves a selector
  degrades one feature instead of breaking the library.

  Known gaps on this build, documented in `docs/CAPABILITIES.md`: tapbacks and
  attachment sending have no working path, and unsending a message applies
  locally but does not reliably reach the recipient.

- Add search, backed by the index Messages already maintains.

  Messages donates its content to a private CoreSpotlight domain and its own
  search field queries that. Rather than building an index, `search()` queries the
  same one, which brings work the device has already done: image classification
  (searching "dog" returns photographs of dogs whose messages never mention one),
  text recognised inside images, and spoken content in audio and video.

  Searches scope to one conversation or run across everything, filtered by kind
  (`message`, `attachment`, `chat`); the two combine freely. Scope is applied
  inside the query rather than to its results, so a scoped search cannot come back
  empty while matches sit further down the ranking. Attachments are filed under a
  domain of their own and carry nothing naming a conversation, so a scoped search
  that wants files attributes them through their owning message.

  Hits carry a snippet of indexed text, scene labels with confidences, which
  attributes matched, and the owning message. The snippet is useful on its own:
  most rows in the message store keep their body in an encoded blob rather than in
  `text`, and Spotlight returns readable text for them without decoding anything.

  Two properties of the index shape the implementation and are documented in
  `docs/SEARCH.md`: body text is indexed for matching but never returned as a
  fetchable attribute, so the all-attribute operator is required to reach it; and
  the ranked engine needs a configured query context, failing with −2002 without
  one. The index can also outlive the store, so a hit's message is not guaranteed
  to still exist.

- Read the whole archive, decode what messages actually contain, and send
  tapbacks.

  `storeHistory` reads the message store directly and pages backwards through it,
  so history is no longer limited to the window the app happens to have loaded.
  `storeMessage` resolves one message by GUID, which is what turns a search hit
  into something readable. Both run inside Messages, where the store is already
  reachable, and open it read-only following the write-ahead log rather than
  snapshotting around it.

  Message bodies are decoded. Most rows keep no plain text — the body is a
  typedstream archive, in one real store about 96% of rows — so a reader
  that trusts the text column sees almost nothing. Bodies now come back as text
  plus the runs behind them, which is also where attachments, mentions and links
  sit. An attachment run carries the same identifier a search hit does, so the two
  line up without a lookup.

  Link previews and polls are decoded from their payloads: a link's title,
  summary, site name, type and image URLs; a poll's question, creator and ordered
  options. The link payload is rooted in a private class, and holds a second one
  for the preview picture — that second class is why most link payloads could not
  be read at all, and both are now stood in for.

  Tapbacks can be sent and removed. IMCore's own acknowledgment path is written
  against ChatKit's chat items, so an IMCore item is adapted to that shape: it
  answers the two accessors the API reaches for, and to ChatKit's name for
  whatever it wraps. Without the second part a reaction still sends and delivers
  but is summarised as though it were on an attachment, which is invisible unless
  the stored summary is read. Building an associated message instead — the
  obvious approach — is accepted without error and stores nothing.

  Tapback, retract and edit now work on any message, not only recent ones: when a
  message is outside the loaded window, IMCore is asked to page in the messages
  around it, as the app does when a search result is opened.

  Also fixed: a result carrying a value JSON could not encode would abort the
  host. `NSJSONSerialization` aborts the process rather than raising, and the host
  here is the user's messaging client, so results are validated before encoding
  and the values that caused it are normalised at the source.

- Fold reactions and votes onto their targets, create polls, and schedule
  messages.

  Reactions, poll votes and stickers are each stored as an ordinary message
  pointing at another one, and nobody reading a conversation sees them that way.
  Deep history now folds them the way the UI draws them: a reaction onto the
  bubble it reacts to, a sticker onto the message it was placed on, a vote into
  the poll's tally with the voters per option. A later vote from the same person
  replaces their earlier one, and options added after the poll was created are
  merged in.

  Three things that were being dropped silently:

  - A reaction names its target as `p:<index>/<guid>` for a message part but
    `bp:<guid>` for a whole balloon. Only the first was handled, so every
    reaction left on a link or a poll was lost.
  - Type 2006 is a reaction carrying an arbitrary emoji rather than one of the
    six fixed shapes — what the emoji and Genmoji pickers send. It was
    unrecognised; it is now reported as kind `emoji` with the character.
  - Reactions are written after the message they point at, so one to the oldest
    message on a page falls outside it. They are looked up rather than read from
    the page.

  Rows also carry the sender's handle, which previously came back as a bare row
  number, and the schedule columns.

  Polls can be created. A poll is an app-extension balloon, and the factory that
  carries attachments and an effect also takes a plugin identifier and its
  payload, so creating one is an ordinary send with those filled in. The question
  and options are JSON in a `data:` URL inside the payload; each option gets the
  identifier a vote later names. The payload includes the nested
  `MSMessageLiveLayout` archive — without it the poll delivers correctly and
  cannot be voted on.

  Messages can be scheduled and cancelled, with a caveat the API surfaces rather
  than hides. Scheduling is not reliably honoured: after another send, IMCore has
  been seen delivering the message immediately while keeping the future
  timestamp, and filing it under this account's own conversation instead of the
  one addressed. Neither raises. `sendLater` therefore reads the row back and
  reports `scheduled` and the `chatGuid` it actually landed in. Cancelling has
  its own traps: `cancelScheduledMessageItem:cancelType:` reports success and
  leaves the message scheduled, and cancelling one scheduled moments earlier acts
  on a stale item and also still sends — so the message is paged in again first
  and the parts are retracted.

  Every error now carries the `code` the bridge sent, not only the ones without a
  class of their own.

  Stickers, Genmoji, Image Playground and #images remain unavailable, and share
  one cause rather than four: each ends in an attachment upload, which does not
  start from inside the host. Every sticker selector on IMCore and ChatKit is
  display or repositioning — there is no send.

- Read everything the transcript shows: attachments, group events, edit history,
  the conversation picture and contact avatars — and vote in a poll.

  Deep history returned no attachments at all. The row carries no text and
  everything describing the file is in another table, so a page of photos, voice
  notes or Genmoji read as a run of empty messages. Attachments now come back with
  their filename, path, type, size and transfer state, along with three things
  that were in the store and never surfaced: `description`, the words Messages
  keeps for accessibility, which is the difference between "an image" and knowing
  a Genmoji of a shark in a party hat was sent; `stickerSource`, the extension a
  sticker came from, which separates a Genmoji from a Memoji from a third-party
  pack; and `hidden` / `sensitive`, which both mean there is nothing at
  `localPath` to open. The store's `user_info` is deliberately still not exposed —
  it holds the transfer's decryption key and says nothing about what was sent.

  Group conversations are punctuated with lines that are not messages — someone
  added, a rename, the picture changing. They are ordinary rows distinguished only
  by `item_type` and columns that are empty on every real message, and they came
  back blank, so a group chat read with people appearing without having been added
  and a name that changed with nothing to explain it. They are now reported as
  `event`. Only codes confirmed against real rows are named; anything else keeps
  its raw code rather than being guessed at.

  The picture a group currently uses is not in the transcript at all — the chat's
  own property list names it — and contact pictures are not on the handle:
  `pictureData` is nil on every handle in a running app, because the picture
  belongs to the CNContact and Contacts hands out only the keys asked for. Both
  are now readable, through `chatDetails` and `avatar`.

  Edits and unsends both leave their evidence in `message_summary_info` rather
  than in a column. `editHistory` returns the full version chain per part with the
  time of each, and `unsendFailed` reports the state the app draws as "Not
  Unsent" — where the recipient still sees the message and it can never be taken
  back. Nothing else in the row says so: `date_retracted` stays 0 and the body is
  empty either way. `unsentParts` covers a message unsent one part at a time.

  `scheduled()` lists what is still waiting to go out. A scheduled message is not
  in the conversation yet, so nothing reading a transcript finds one, and
  cancelling needs the chat it actually landed in rather than the one it was
  addressed to.

  Polls can be voted in. A vote is two things at once — a plugin balloon carrying
  the choice and an association pointing at the poll — and exactly one factory
  takes both. Name the option by text, position or identifier; the poll is read
  for the session identifier and the option UUID a vote actually needs. The trap
  worth knowing: IMCore routes an associated message by resolving the message it
  points at, and when the poll is not in the chat's loaded window the vote is
  filed under this account's own conversation — sent, delivered, counted nowhere,
  no error — so the poll is paged in first. This is the same failure Send Later
  shows and the same one that made cancelling a scheduled message silently
  no-op.

  Three fixes to what was already there. A NULL column reached a string selector
  and aborted Messages mid-request; every decoded value is now coerced, and a
  malformed row fails the request rather than the host. Zero timestamps were
  shifted into 2001 instead of being left unset. And `storeMessage` did not fold
  associations, so reading a poll by GUID returned it with no tally.

- Bring the live path up to what deep history reports, make Send Later reliable,
  and stop group operations claiming success they did not have.

  A bot reacting to a conversation as it happens was seeing strictly less than one
  reading the same conversation afterwards. Group events arrived as blank
  messages, a Genmoji as an opaque attachment, an edited message with no history,
  and a failed unsend as an ordinary one. The live path now reports all of it:
  `event`, `editHistory`, `unsent` / `unsentParts` / `unsendFailed`, an
  attachment's `description`, `contentIdentifier` and `stickerSource`, and
  `scheduleType` / `scheduledFor` on a message being held.

  Everything is read in-process rather than by looking the message up in the
  store, which would race the write on a message that has only just arrived.
  IMCore hands back what is needed: `messageSummaryInfo` as a dictionary, and
  `adaptiveImageGlyphContentDescription` on the file transfer — its name for what
  a Genmoji depicts. The live path can also tell a group _picture_ change from
  another icon change, which a stored row cannot: the item answers
  `actionIsGroupPhoto`, where history has to infer it from whether an image came
  along. That case is reported as the new `group-action` kind.

  Send Later is reliable now, and the cause was the construction rather than
  anything about scheduling. Building the message by hand states the delivery time
  twice — once as the message's own time, once as a schedule type and state — and
  IMCore was observed honouring one and not the other, either sending immediately
  while keeping the future timestamp or filing the message under this account's
  own conversation. `instantMessageWithText:…scheduledDate:` is the factory made
  for this and takes the date alone. The reproduction that failed every time
  before now succeeds; the hand-built initialiser remains as a fallback. The
  result is still read back and reported, which is what would make a regression
  visible rather than silent.

  Group operations return void inside IMCore, so nothing they did was ever
  verified. They now read the chat back and report `participants`, `displayName`
  and whether anything `changed`. That immediately surfaced a real one:
  `removeParticipants:reason:` **reports success and does nothing** when the group
  would drop below three people — the call returns, membership is unchanged, and
  no event is written. Renaming is verified working end to end, including the
  event it produces on both paths. Adding a participant remains untested, and
  leaving deliberately so: there is no way back into a conversation from this
  side.

- Show the person behind every handle, and add `contact` for their whole card.

  A phone number in a transcript says nothing. Results now carry the name
  alongside the handle wherever one appears — message senders, whoever left a
  reaction or a sticker, the actor and subject of a group event, and conversation
  participants. The handle itself stays where it was, so anything keyed on it
  still works; the name is added, not substituted. Distinct handles are resolved
  once per result and a wedged main thread costs the names rather than the
  request.

  `contact(handle)` returns everything Contacts holds: names in all their parts,
  phone numbers, email addresses, postal addresses, birthday and other dates,
  employer, job title, related people, social and messaging profiles, URLs, and
  the note. Labels come back the way the app displays them — `mobile`, not
  `_$!<Mobile>!$_` — localised by Contacts rather than by a table here that would
  be right in one language. The photo is opt-in with `includePhoto`, since it is
  tens of kilobytes and most callers want the name; `hasPhoto` answers whether
  there is one without paying for it, computed from the bytes because Contacts'
  own `imageDataAvailable` reads false on cards that plainly have a picture.

  Two things about Contacts decide whether this returns a name or a person, and
  both are silent when missed. A CNContact hands out only the keys it was fetched
  with — reading an unfetched key raises rather than returning nil — so the key
  list is the contract. And a handle that has never been in a conversation has no
  contact properties loaded: the keyed fetch answers nil for it while still
  knowing the person's name, which looks exactly like a contact with nothing on
  them. Reading `cnContact` once makes it load, and handles already in an open
  conversation are preferred because they are loaded already.

  Verified against real cards for names, phone numbers, email addresses and
  pictures. Postal addresses, birthdays, relations and social profiles go through
  the same path but no card in the address book tested against had any.

- Read and send formatted text and animated effects, start conversations, delete
  messages, and ask what a handle can receive.

  **Formatting.** Bold, italic, underline and strikethrough are reported per body
  run, in both spellings IMCore uses — the `__kIMText…` names the current format
  bar writes, and the shorter ones still on older messages. An earlier note here
  said no styling attribute had been identified because none appeared in a sampled
  message; that was the wrong conclusion from a small sample.

  **Animated text effects.** Reported by name rather than by code, and accepted by
  name on send. The names come from IMCore at runtime rather than a table here,
  which is what turned up that they are not what the UI calls them: there is no
  `shake`, only `shakeVertical` and `shakeHorizontal`, and no `nod` at all. This
  matters because IMCore reads an unrecognised name as _no effect_ — a message
  would go out plain and look like it worked — so an unknown name is now rejected
  with the list of valid ones, and `status().textEffects` reports what this build
  accepts.

  **Sending formatted text and mentions.** `formatting` on `send` applies styles,
  an effect, or a mention over ranges of the body. A mention is a range naming a
  handle: that is what makes it notify the person rather than merely read as their
  name. Ranges outside the text are dropped rather than passed on, since IMCore
  raises on one while splitting the message into parts — a crash in the host, not
  a failed send.

  **One-time codes and data detectors.** A run Messages recognised as a passcode is
  marked, as is one the detectors matched — a flight, a parcel, an address, an
  amount. The detector payload is an archived scanner result and is not decoded,
  so the fact is reported and the structure is not.

  **Starting a conversation.** `createChat` — previously there was no way to begin
  one at all. IMCore has no separate create: asking the registry for the chat with
  a set of handles returns the existing one or mints it, and `isNew` says which.
  That flag is computed against the conversations that existed a moment before,
  because the obvious test — whether the returned chat has messages loaded — reads
  true for every untouched conversation.

  **Deleting messages.** `deleteMessages`, which is _not_ an unsend: the recipient
  keeps their copy and is told nothing. Verified by reading back, because a delete
  does not remove the row — the message moves out of the conversation into the
  recoverable set, since macOS keeps deleted messages for thirty days. It stays
  readable by GUID and only its chat membership goes.

  **`whois`.** Whether an address is reachable on iMessage, and whether the person
  has a Focus on. Both are things worth knowing before a send rather than after.

  Booleans built from C comparisons were reaching clients as `0` and `1` rather
  than `false` and `true`, in the capability matrix, the contact card and the
  group result. There is now one helper for it.

  The sticker row is corrected rather than closed. It was blocked on the grounds
  that sending one needs an attachment upload; that reasoning was wrong, since a
  cached sticker already has a transfer GUID. The real obstacle is that no
  IMCore-level send exists at all — every sticker send lives on ChatKit's view
  controllers, and nothing exposes one for a conversation that is not open on
  screen.

- Send attachments and stickers through the injected path, and add unread state,
  pinning, forced notifications, account identity, Name & Photo cards, and
  conversation statistics.

  Two things documented here as impossible turn out not to be, and both failed
  for the same reason.

  **Attachments** used to go out through Messages' scripting interface, because
  the IMCore route reported success at every step and the upload never started.
  The calls were right; the file was in the wrong place. The transfer daemon
  uploads from inside the attachment tree and will not reach anywhere else, so
  the file has to be staged under `~/Library/Messages/Attachments/` _before_ the
  transfer is created against it — and then `registerTransferWithDaemon:`, the
  call that actually starts the upload, has to be made. With both in place the
  upload runs and the attachment row appears with its MIME type and size.

  The staging happens in the client rather than in the injected code, because
  Messages is sandboxed: it reads the attachment tree but is refused writes into
  it. `IMDPersistentAttachmentController -_persistentPathForTransfer:…`, the
  documented way to find that location, is not usable here — it answers nil with
  a nil chat GUID and an iOS-shaped `/var/mobile/…` path otherwise — so it is
  attempted opportunistically and nothing depends on it.

  This removes both trade-offs the scripting route had: a file and its text now
  travel as one message rather than two, and any conversation can be addressed by
  GUID instead of by picking a participant to send to.

  **Stickers** looked blocked because searching for a sticker send API finds only
  ChatKit view controllers that need a conversation open on screen. There is no
  sticker send API because a sticker is not sent by one: it is an ordinary file
  transfer carrying `setIsSticker:`, `setStickerUserInfo:` and
  `setAttributionInfo:`. `send({ files, sticker })` sends one, and enforces the
  size and dimension limits — over them, the sticker is silently delivered as a
  plain image instead.

  Relatedly, the documented constraint that attachments, an expressive effect and
  a reply thread cannot be combined applied to the class factories, not to
  IMCore. The designated initialiser underneath them takes all three, and is now
  used for that case.

  New operations, all gated on live selector probes:

  - `markUnread` — the app's own Mark as Unread, or from a named message.
  - `notifyAnyway` — pushes one message past a recipient's mute or Focus.
  - `pin` — pins or unpins a conversation. IMCore has no per-chat pin: the only
    setter replaces the whole pinned list, which syncs across devices, so the
    current set is read back off the live chats immediately before writing.
  - `setGroupPhoto` — sets or clears a group's picture, through its own transfer
    factory. Shipped **unverified**: running it against a real group would
    overwrite a picture that cannot be recovered.
  - `account` / `setSendingAlias` — the signed-in Apple ID, every address that
    reaches it, which are vetted, which one outgoing messages are attributed to,
    and SMS relay state. This is what makes "did I send this" answerable rather
    than inferred.
  - `nickname` — the Name & Photo card someone shared over iMessage. Messages
    displays this in preference to the contact card, so reading Contacts alone
    can give a different name than the one on screen, and a card exists for
    people with no Contacts entry at all. Your own card also carries the updates
    waiting to be accepted or declined. Sharing your own profile is deliberately
    not implemented.
  - `stats` — counts by person, hour, weekday and month, media by type and total
    bytes, tapback count, and first and last contact, over a conversation or the
    whole store.

  The test suite is now type-checked, which it was not before.

- React with any emoji, not just the six named tapbacks.

  `tapback({ kind: "emoji", emoji: "🔥" })` sends the reaction the emoji and
  Genmoji pickers send, and `remove: true` takes it back off again.

  This looked like the classic tapbacks with a different code, and it is not.
  Every route that reaches the named six is addressed by type code, and no code
  carries a character, so there is nowhere for the emoji to travel:
  `sendMessageAcknowledgment:forChatItem:` cannot express it, and the variant
  whose name suggests it can — `…forChatItem:languageIdentifier:` — takes a
  BCP-47 language for localising the recipient's notification. Passing an emoji
  there returns a GUID and stores nothing. Hand-building the associated message,
  the fallback that does store a classic tapback, is likewise accepted and
  dropped for a 2006 even with the character set on the message.

  IMCore models this reaction as an object rather than a number. `IMEmojiTapback`
  holds the character, and `IMTapbackSender` is what Messages hands it to; going
  through the sender is also what keeps the summary honest, since it asks the
  tapback to adjust the summary for sending. No ChatKit item is involved, so the
  proxy the classic path needs is not used here.

  Verified end to end against the store rather than by the call returning, which
  is what every earlier attempt did successfully while storing nothing: the row
  lands with `associated_message_type` 2006, the character in
  `associated_message_emoji`, `is_sent` and no error; removing writes the 3006;
  and the reaction reads back on its target as `{ kind: "emoji", emoji }`.

  Reported as its own `emojiTapback` capability rather than folded into
  `tapback`, since it depends on different classes and could be absent on a build
  where the named reactions work. The character is required for `kind: "emoji"`
  and refused on every other kind, so a caller cannot quietly send a reaction it
  did not intend.

  **The classic reactions now go the same way, which fixes a silent failure in
  them.** `sendMessageAcknowledgment:forChatItem:` — the path they used, and the
  one adopted precisely because hand-built messages vanished — turns out to
  return a GUID and store nothing on some messages itself, reproducibly and
  across restarts. Because it reports success, no fallback behind it could ever
  run. The tapback objects store on exactly those messages, so they are now tried
  first, with the acknowledgment path behind them.

  What had kept them second was the stored summary: they were writing
  `amc`/`ams`/`ust` without the `ampt` archived attributed string. That is
  resolved rather than traded away — the summary for both routes is now built by
  `+[IMChat configureMessageSummaryInfoForChatItem:]`, which is where `ampt` comes
  from, and the ChatKit proxy already in the codebase is what lets that call
  accept an IMCore item.

  Whether `ampt` appears is a property of the target rather than the route, which
  is measurable: across several hundred reactions in a real store, plain-text targets
  carry it and attachment targets mostly do not, and reactions this account sends
  to incoming text messages have essentially never carried one — 53 of 55 lack
  it, including reactions the Messages UI itself wrote. The new route reproduces
  that distribution.

- Read what voice notes say, and silence a conversation.

  **Audio messages are no longer opaque.** One carries no text of its own — the
  body is a single attachment placeholder — so anything reading a conversation
  saw an empty bubble where the app shows a sentence. Messages transcribes them
  on device and files the result under `audio-transcription` in the attachment's
  `user_info`, which is the plist deliberately withheld from callers because it
  also holds the iCloud transfer's URL and decryption key. Exactly one key is
  lifted out of it and the dictionary is never returned, the way
  `sticker_user_info` is already handled. Both read paths carry it, and both now
  agree on which attachments are voice notes.

  `IMFileTransfer.audioTranscriptionText` is where ChatKit reads it from and
  looks like the obvious source, but it is filled in as the balloon is drawn: on
  a message nobody has scrolled to it answers nil. Detection is `isAudioMessage`
  on the message rather than `isOpusAudioMessage` on the transfer, which is true
  only of the newer encoding and answers no for the `.caf` recordings the app has
  sent for years.

  **Mute** — `mute()` is the app's Hide Alerts. Silence is a date rather than a
  flag, so muting with no end is the distant future, muting until a time is that
  time, and lifting it is nil; listings gained `mutedUntil` for the timed case
  and omit it for the indefinite one, where the stored date would read as a real
  deadline. Verified by round-trip against `isMuted`, which is IMCore reading
  that date back.

  **Unread mentions** — `mentions()` returns the unread messages naming this
  account, which IMCore already tracks. Deriving it instead would mean decoding
  every body, knowing which addresses are yours, and still only covering the
  loaded window.

  Three more are implemented and **shipped unverified**, each for a reason that
  does not go away by trying harder: `deleteHistory()` (every conversation on the
  test machine holds real history and there is no throwaway one to empty),
  `reportJunk()` (it leaves the machine and there is no unreport, so a test costs
  a real report), and `sendAsText()` (it needs an iMessage that genuinely failed,
  which cannot be produced on demand).

  `shareLocation()` shares this account's location for a bounded time. The
  duration is seconds — `locationShareOneHourTimeInterval` in ChatKit is what
  settles that it is an interval and not one of the menu's three choices — and it
  is required and must be positive. Sharing indefinitely is deliberately not
  offered: it would be some sentinel value, nothing reachable names which one,
  and a wrong guess broadcasts a real-time location until someone notices. Also
  unverified, for the same reason as the others: confirming it means transmitting
  a real location.

  Deliberately not implemented: setting a conversation's filter category. It is
  readable, but the values are not named anywhere reachable and this build does
  not persist them, so there is nothing to check a guess against and a wrong one
  mis-files a real conversation. Sending a true voice message is likewise absent
  — a `.caf` sends as an ordinary attachment, and `isAudioMessage` is read-only
  everywhere with no setter to be found, so what makes one is not established.

- Answer `--help`, `--version` and a mistyped command without a running bridge.

  The CLI took its first argument as the command whatever it looked like, so
  `--help` was read as a command named `--help`. It matched nothing, fell past the
  help check, and went on to dial the socket — meaning the first thing anyone
  types after installing spent the connect timeout and then answered
  `BridgeUnavailableError: no injected Messages.app connected`. The usage text was
  unreachable until the very thing the usage text explains how to set up was
  already working. A leading token starting with `-` is now a flag rather than a
  command, so `--help`, `-h` and bare `imcore-bridge` all print the usage.

  `--version` is new, and reports what npm installed rather than what the source
  tree says, since those differ for anyone who did not clone this.

  A mistyped command is also refused before connecting. It used to reach the
  switch's default case, which is on the far side of the connect, so `chatz`
  reported that Messages was unreachable — sending the reader to look at the
  injection rather than at what they typed. The accepted commands are read out of
  the usage text rather than listed a second time, so one cannot be accepted and
  undocumented; a test covers the other direction, where a command is implemented
  and left out of the usage.

  `packageRoot` moved from `launch.ts` to `paths.ts`, which is where the rest of
  the questions about where the package is are answered.
