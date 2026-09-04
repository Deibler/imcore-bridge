# Capability matrix

> **Safety rule.** The injected code only invokes what Messages.app itself
> invokes during ordinary use — operations on a single chat or a single
> message. Calls that mutate shared state (accounts, registries, identity maps,
> transfer tables) are out of bounds even when one looks like the missing
> piece, because a mistake there does not fail cleanly: it corrupts the running
> app's view of the user's conversations. See the "never called" list in
> `native/src/ops.m`.

What the bridge exposes today, what is verified, and what is still missing.
Verified on macOS 26.4.1 (25E253) / Messages 26.0.

Legend: **done** shipped and tested · **partial** works with a stated limit ·
**planned** selector confirmed to exist, not yet wired · **blocked** no API found

Everything under "Reading a conversation" is available on both paths — the live
one (`getHistory`, and the `message` events) and the archive (`storeHistory`).
That is deliberate: a bot reacting to a conversation as it happens should not
see less than one reading it afterwards. The one asymmetry is noted in the table
— the live path can tell a group *picture* change from another kind of icon
change, because the item says so, where the stored row can only infer it.

## Reading a conversation

| Capability | Status | Notes |
|---|---|---|
| List conversations | done | GUID, identifier, service, group vs 1:1 |
| Participants as people | done | Contact name, first name, nickname via `IMHandle` |
| Group display name | done | |
| Unread count, pinned, muted | done | |
| Last activity timestamp | done | |
| Message history | done | Pages in on demand via `loadMessagesBeforeDate:limit:`, passing an explicit far-future date. **Never pass nil** — IMCore reads it as the distant past, loads nothing, and blanks the conversation in the Messages UI until it reloads (stored messages are unaffected). This is IMCore's in-memory window; the full archive comes from the store reader below. |
| Deep history (full archive) | done | `storeHistory` reads chat.db directly, paged backwards by rowid. See [HISTORY.md](HISTORY.md). |
| Catching up after downtime | done | `storeHistory` also pages **forwards** from a `sinceRowID`, and with no `chat` it spans every conversation at once — a caller that was not running does not know which ones have news. Each message then carries its own `chatGuid`. See below. |
| Every conversation an identifier maps to | done | `resolveChats`. A 1:1 legitimately maps to more than one chat, and `resolveChat` answers with a single one. See below. |
| Every conversation a handle appears in | done | `chatsWith`, groups included, newest first. Empty means the address has never been spoken to, which is what makes it usable as a check before sending somewhere new. Numbers match on their national digits, so `+15551234567` and `(555) 123-4567` are one person. |
| Sender identity per message | done | Falls back to the underlying message when a part carries none |
| Delivery / read / played state | done | Flags plus timestamps |
| Mentions | done | Handle, matched text and range, from the `__kIMMentionConfirmedMention` attribute on the body |
| Reply threading | done | `replyToGUID` from `threadOriginator`, plus `threadIdentifier` |
| Edited / retracted stamps | done | Including every prior version of an edited message, per part, with the time each was written — read back against a real edit on this machine, where the store holds 90 of them. An earlier note here said prior versions were not exposed; that stopped being true when the store reader landed and the row was not updated. |
| Expressive effect on a message | done | Effect identifier, e.g. `com.apple.MobileSMS.expressivesend.invisibleink` |
| Attachments | done | Filename, MIME type, local path, size, sticker flag |
| Audio transcription | done | The words of a voice note, on both read paths. Not from `audioTranscriptionText`, which is where ChatKit reads it but is filled in as the balloon is drawn and answers nil for anything unrendered — the text is kept under `audio-transcription` in the attachment's `user_info`. See below. |
| Balloon classification | done | `text`, `attachment`, `link`, `poll`, `tapback`, `app`, `photos`, `findmy` |
| Link preview metadata | done | Title, summary, site name, OpenGraph type and the preview/icon image URLs, decoded from the balloon payload. The payload is rooted in a private `RichLink`, so it is decoded with a stand-in class; the picture inside it is a second private class that made most payloads fail until it was stood in for too. |
| Poll question, options, votes | done | Question, creator and ordered options, decoded from the payload — which carries them as base64 JSON in a `data:` URL. Votes arrive as separate messages and are tallied onto the poll, with the voters per option; a later vote from the same person replaces their earlier one, and options added after the fact are merged in. |
| Reactions folded onto their target | done | In deep history as well as the live path. Reactions targeting a message are looked up rather than taken from the page, since one is written after the message it points at and often falls outside it. |
| Emoji reactions | done | Type 2006 carries an arbitrary emoji rather than one of the six fixed shapes — the emoji and Genmoji pickers send these. Reported as kind `emoji` with the character. |
| Stickers stuck on a message | done | Folded onto the bubble they were placed on, as the UI draws them |
| Tapbacks aggregated onto their target | done | Attached to the message they react to as `tapbacks[]`, each with reactor identity — matching how the UI draws them. They live on the part item as `visibleAssociatedMessageChatItems`, not as separate chat items. A reaction names its target as `p:<index>/<guid>` for a message part or `bp:<guid>` for a whole balloon; handling only the first form silently loses every reaction left on a link or poll. |
| Rich text formatting | done | Bold, italic, underline and strikethrough per run, in both spellings IMCore uses (`__kIMText…` from the current format bar, and the shorter names on older messages). Reported as `styles` on each body run, since that is how it is stored — a message is bold over a range, not as a whole. |
| Animated text effects | done | `textEffect` on a run, named rather than numbered. macOS 26 has twelve: `scaleRipple`, `stretch`, `squish`, `bounce`, `big`, `bloom`, `somersault`, `shakeVertical`, `shakeHorizontal`, `jitter`, `small`, `explode`. The names come from IMCore at runtime, not from a table here. |
| One-time codes | done | `isOneTimeCode` on a run Messages recognised as a passcode — the difference between a reader seeing a number and knowing what it is. |
| Data detectors | partial | `isDataDetected` marks a run the detectors matched (a flight, a parcel, an address, an amount). The payload is an archived scanner result and is not decoded, so the fact is reported and the structure is not. |
| Attachments in deep history | done | Deep history carried none at all until now: a page of photos read as empty messages, because the row holds no text and everything describing the file is in another table. Filename, on-disk path, type, size, transfer state, and the flags that mean the file is not there to read (`hidden`, `sensitive`). |
| Genmoji descriptions | done | `description` on the attachment — the words Messages stores for accessibility ("Poop, White, Trash, White poop, Camping"). The difference between "an image" and knowing what was sent. |
| Sticker provenance | done | `stickerSource` names the extension a sticker came from, which separates a Genmoji (`com.apple.messages.genmoji`) from a Memoji from a third-party pack. |
| Group events | done | The grey lines a group conversation is punctuated with — someone added, a rename, a picture change. IMCore models these as their own item classes rather than messages, and the store distinguishes them only by `item_type` plus columns that are empty on every real message, so both paths returned them blank. Now decoded as `event` on both. The live path can additionally tell a picture change from another icon change (`actionIsGroupPhoto`); the stored row infers it from whether an image came along. |
| Edit history | done | The full version chain per part, with the time of each, decoded from `message_summary_info`'s `ec`. The last entry is the text the message reads as now. (Not in `recoverable_message_part`, which holds unsent messages awaiting deletion and is usually empty.) |
| Failed unsend | done | `unsendFailed` — the "Not Unsent" state, where the recipient still sees the message and it can never be taken back. Nothing else in the row says so. `unsentParts` reports a message unsent one part at a time. |
| Group photo (read) | done | `chatDetails`. The chat's property list names the attachment holding the current picture; the transcript records *when* it changed but not which one is current. |
| Contact avatars | done | `avatar(handle)`. The picture is not on the handle — `pictureData` is nil on every handle in a running app — it belongs to the CNContact, and Contacts hands out only the keys asked for. |
| Names beside handles | done | Every handle a result carries is resolved to the person behind it: message senders, reactors, whoever a group event was about, and conversation participants. The handle stays put and the name sits alongside, so nothing that keys on the handle breaks. |
| Reachability and Focus | done | `whois(handle)` — whether the address is registered on iMessage (`isIMessage`), and whether the person has a Focus on (`hasFocusOn`), which is read from the conversation with them. Both are worth knowing before a send rather than after. |
| Contact cards | done | `contact(handle)` returns everything Contacts holds — names, phone numbers, email addresses, postal addresses, birthday, other dates, employer, job title, related people, social and messaging profiles, URLs, note — with labels already localised (`mobile`, not `_$!<Mobile>!$_`). See below. |
| Conversation background | partial | `hasBackground` only. macOS 26 gives a conversation its own background; it is stored as a remote asset with its decryption material rather than a local file. |
| Search | done | Queries the private CoreSpotlight domain Messages donates to — the index its own search field uses, so it covers message text, text recognised inside images, spoken content, and Apple's image classification (`dog` matches photos of dogs). Scope by conversation and by kind; both go into the query. See [SEARCH.md](SEARCH.md). |
| Search hit → full message | done | `storeMessage(hit.messageGuid)` returns the message and its conversation. A hit can outlive its message, since the index is not pruned on delete; that reports as `message_not_found`. |
| Attachment download state | done | `downloadPurgedAttachments` requests a fetch for files not cached locally, exposed as `downloadAttachments`. |
| Scheduled messages | done | `scheduled()` lists what is still waiting, across every conversation. Worth having on its own: a scheduled message is not in the transcript yet, so nothing reading history finds one — and cancelling needs the chat it actually landed in. |
| Your own identity | done | `account()` — the Apple ID that is signed in, every address that reaches it, which of those are vetted, which one outgoing messages are attributed to, connection state, and whether texts from a paired iPhone are being relayed here. Without this there is no way to tell your own handles from anyone else's, which is what makes "did I send this" answerable rather than inferred. |
| Name & Photo cards | done | `nickname(handle)` — the name and picture someone chose to share with you over iMessage. Messages displays this *in preference to* the contact card, so reading Contacts alone can give a different name than the one on screen, and a card exists for people who have no Contacts entry at all. `nickname()` with no handle returns your own, plus `pending`: the "«Name» updated their photo" prompts waiting on a yes or no. |
| Conversation statistics | done | `stats()` — message counts by person, by hour, by weekday, by month, media broken down by type and total bytes, tapback count, and first and last contact. Scoped to a conversation or run over the whole store. Answers what a person could work out by scrolling, but over the full history rather than the loaded window. |
| Message flags | done | The ones that change what a message means: `is_spam`, `was_downgraded` (sent as SMS after iMessage failed), `is_kt_verified`, `was_delivered_quietly`, `is_expirable` / `expire_state`, `is_time_sensitive`. |

## Live events

| Event | Status | Notes |
|---|---|---|
| `message` (inbound) | done | Fires in-process the moment a message arrives |
| Store rowid on an event | done | `rowid`, from IMCore's `messageID`, so a consumer can record where it got to and later ask `storeHistory` what it missed. Verified equal to the store's ROWID on a few hundred messages across a dozen conversations, with none missing it. Absent until the message has been written to the store, which for one just received can be a moment after the event — absent is the safe direction, since a guessed rowid moves the cursor past messages that were never delivered. |
| `message-sent` | done | Echo of your own sends, for GUID correlation |
| `message-updated` | done | Delivery and read transitions |
| `read-receipt` | done | Chat watermark moved |
| `unread-changed` | done | Suppressed for 10s after startup to avoid a sync storm |
| `typing` | partial | Emitted from `IMTypingChatItem` insert/remove; not yet observed against a live remote typist |
| `chat-item` | done | Catch-all for edits, retractions, tapbacks |

## Writing

Verified by reading the message store afterwards, not by trusting the call's
return value. Several of these APIs return `void`, so "no exception" does not
mean "it took effect".

Checking whether an unsend landed is subtle, and getting it wrong is easy:

- `date_retracted` is never set. It is not the signal.
- `part_count` dropping to 0 and the body emptying only proves the message was
  removed **locally**. The retraction can still fail to reach the recipient, in
  which case the UI shows "Not Unsent" in red and the other party keeps seeing
  the message.
- The real signal is the **presence of an `rdfp` key** inside the
  `message_summary_info` binary plist. A clean unsend contains only `ust`; a
  failed one adds `otr`, `rdfp` and `rp`. Do not discriminate on blob length —
  it varies with message content and will mislead you.

A "Not Unsent" message cannot be retracted again — the local body is already
gone, so there is nothing left to retract. It is stuck on the recipient's
device permanently.

| Capability | Status | Selector |
|---|---|---|
| Typing indicator | done | `setLocalUserIsTyping:`. The flag has no expiry, so the bridge turns off whatever it left on when the host disconnects — see below. |
| Send text | done | `instantMessageWithText:messageSubject:fileTransferGUIDs:flags:threadIdentifier:` → `sendMessage:` |
| Choose the service | partial | `sendMessage:onAccount:` with `activeSMSAccount` / `activeIMessageAccount`, routing one message without touching the conversation's own account. The refusals are verified — an unknown name and a machine with no relay are both rejected before anything is sent. Forcing SMS **cannot be verified here**: this Mac reports `smsRelayCapable: false`, so there is no SMS account to send on. |
| Subject line | done | same factory |
| Expressive effect | done | `…messageSubject:flags:expressiveSendStyleID:threadIdentifier:`; confirmed as `expressive_send_style_id` in the store |
| Edit a sent message | done | `editMessageItem:atPartIndex:…`; confirmed via `date_edited` |
| Mark chat as read | done | `markAllMessagesAsRead` |
| Group rename | done | `setDisplayName:`; verified live and in the store, and the resulting event decodes on both paths |
| Group add | untested | `_addParticipants:withState:`. Never run — testing it means adding a real person to a real conversation. It is now asked about first, so a conversation that will not take the participants refuses instead of reporting success. |
| Group remove | partial | `removeParticipants:reason:` **reports success and does nothing** when the group would drop below three people. Verified: the call returned, membership was unchanged, and no event row was written. That case is now caught in advance rather than discovered by reading the group back — see below. Whether the removal itself works above the floor is still untested. |
| Will a membership change be acted on | done | `canAddParticipants:` / `canRemoveParticipants:`, which is what the app asks before it enables the menu item. Read-only, so this is the one thing here that could be checked against real conversations without changing any: a three-person group answers no to a removal, a nine-person group answers yes, and a 1:1 answers no to an addition. Half the groups on the test machine are three-person, so the silent case is the common one. |
| Delete a conversation | unverified | `-[IMChat remove]`, as deleting it in the app does — distinct from emptying it, which leaves the conversation in the list with nothing in it. **Not run**: there is no throwaway conversation on this machine to delete, and unlike emptying, this one takes the thread itself. |
| Share your Name & Photo | unverified | `IMNicknameController.sendPersonalNicknameToHandle:`. Reading the cards other people have shared is one thing; handing over your own name and picture is a disclosure about the person running this, so it is for when they ask. **Not run**: testing it means sending a real person your profile. |
| Stick a sticker to a bubble | done | Peel-and-stick. A stuck sticker is not a message with a picture in it but an *associated* message, addressed the way a tapback is — `p:<part>/<guid>` plus a range — carrying type 1000 and a sticker transfer. The shape came from reading the nine already in this machine's store. Verified by sending one and reading it back: type 1000, the right target, `is_sticker` set. |
| Repeating a send safely | done | A caller-chosen `idempotencyKey`. Verified by sending the same key twice: one bubble written, the second call returned the first GUID marked `duplicate`. |
| What became of a send | done | `sendStatus` by GUID → `unknown`, `pending`, `sent`, `delivered`, `read`, `failed`. Verified against real sent messages, which read `read` and `delivered`, and a GUID never sent, which reads `unknown`. |
| Group leave | untested | `leave`. Deliberately not run: there is no way back into a conversation from this side — only someone still in it can add you again. |
| Send formatted text | done | `formatting` on `send`: styles, an animated effect, or a mention, over ranges of the body. Ranges outside the text are ignored rather than passed on — IMCore raises on one while splitting the message into parts, which is a crash in the host, not a failed send. |
| Send a mention | done | A `formatting` range carrying a `handle`. That is what makes it notify the person rather than merely read as their name. |
| Start a conversation | done | `createChat`. IMCore has no separate create: asking the registry for the chat with a set of handles returns the existing one or mints it. Nothing is sent and nobody is notified until a message goes out. |
| Delete messages | done | `deleteMessages`. **Not an unsend** — the recipient keeps their copy and is told nothing. Verified by read-back, because a delete does not remove the row: the message moves out of the conversation into the recoverable set (macOS keeps deleted messages for thirty days), so it is still readable by GUID and only its chat membership is gone. |
| Reply in thread | done | The identifier is `r:0:0:<textLength>:<originatorGUID>`, read off real threaded replies. Confirmed by `thread_originator_guid` and a matching `thread_originator_part` of `0:0:<textLength>`. |
| Tapback add/remove | done | IMCore's own tapback objects — `IMClassicTapback` handed to `IMTapbackSender` — with `sendMessageAcknowledgment:forChatItem:` behind them and a hand-built associated message behind that. The acknowledgment path was the primary route until it was found to return a GUID and store nothing on some messages, reproducibly; because it reports success no fallback could rescue it, so the order is reversed. See below. Verified for add and remove against the store: the row stores with `is_sent`, no error, and a summary matching what the app writes. |
| Emoji reaction add/remove | done | `tapback({ kind: "emoji", emoji })` — reacting with any character rather than one of the six named tapbacks. It cannot go through the acknowledgment path at all, since that is addressed by type code and no code carries a character; IMCore models it as an object instead. See below. Verified for add and remove against the store: `associated_message_type` 2006 then 3006, the character in `associated_message_emoji`, `is_sent` and no error. Reported as its own `emojiTapback` capability, because a build could have the classic path and not this one. |
| Unsend (retract) | partial | `retractMessagePart:`, passing the display chat item. Always removes the message locally, but propagation to the recipient is unreliable: in testing 5 of 10 landed as "Not Unsent" and stayed visible to the other party. The failures were the messages retracted seconds after sending; ones left to settle for minutes propagated cleanly. Read state was irrelevant. Verify with `message_summary_info`, not `part_count`. |
| Send files, photos, audio | done | `send({ files })`, through the injected path. Text travels with the file as a caption in one message rather than as a second message, and any conversation works, group chats included. Confirmed end to end: a PNG arrived with `transfer_state` 5, `is_sent` 1, and reads back with filename and MIME type. |
| Create a poll | done | Sent as an app-extension balloon — see the + menu section below |
| Vote in a poll | done | `votePoll`. Name the option by text, position or identifier — everything the vote actually needs is read out of the poll. See below. |
| Schedule a message (Send Later) | done | `sendLater` / `cancelScheduled` / `scheduled`. Was unreliable until the message stopped being built by hand — see below. The result is still read back from the store rather than assumed. |
| Mark unread | done | `markUnread`. `markLastMessageAsUnread` is the app's own Mark as Unread; naming a message uses `markMessageAsUnread:` instead. Verified by round-trip: the chat's unread count moved 0 → 1 and back. |
| Notify Anyway | done | `notifyAnyway`. `markChatItemAsNotifyRecipient:` pushes one message past the recipient's mute or Focus. The call succeeds; whether the notification actually broke through on the other device is not observable from here. |
| Mute (Hide Alerts) | done | `mute`. Silence is a **date**, not a flag: `setMuteUntilDate:` with the distant future is an indefinite mute, with a date is a timed one, and nil lifts it. Verified by round-trip against `isMuted`, which is IMCore reading that date back — so a mute whose date has passed correctly reads as unmuted. Listings carry `mutedUntil` for the timed case and omit it for the indefinite one, where the stored date would otherwise read as a real deadline. |
| Unread mentions | done | `mentions` — the unread messages in a conversation that name this account, from `messageGuidsForMyUnreadMentions`. IMCore keeps this itself; deriving it instead would mean decoding every body, knowing which addresses are yours, and still only covering the loaded window. |
| Empty a conversation | unverified | `deleteHistory`, from `deleteAllHistory`. Local only — nobody else loses their copy — and recoverable for thirty days as `deleteMessages` is. **Not run against a real conversation**: every conversation on the test machine holds real history, and there is no throwaway one to empty. |
| Report Junk | unverified | `reportJunk`. Sends the conversation to Apple, and the carrier too on SMS. **Deliberately never run**: it leaves the machine and there is no unreport, so a test costs a real report. |
| Send as Text Message | unverified | `sendAsText`, from `downgradeMessage:manualDowngrade:`. A retry of a message that failed as an iMessage, not a way to address a new one to SMS — asking for it on a message that did not fail asks the carrier for a second copy. **Not verified**: it needs a genuinely failed iMessage, which cannot be produced on demand. |
| Share location | unverified | `shareLocation`, from `shareLocationWithDuration:`, which takes **seconds** — ChatKit's own `locationShareOneHourTimeInterval` is what settles that it is a time interval rather than one of the menu's three choices. A duration is required and must be positive: the menu's "indefinitely" would be some sentinel, nothing reachable names which, and a wrong guess broadcasts a real-time location until someone notices. **Not run**: verifying it means actually transmitting a location to somebody. |
| Filter category | read only | A conversation's `filterCategory` is readable, but the matching setter is deliberately absent: the values are not named anywhere reachable, and this build does not persist the category to the store, so there is nothing to check a guess against. Writing an unknown value would mis-file a real conversation. |
| Pin / unpin a conversation | done | `pin`. There is no per-chat pin: the only setter replaces the whole pinned list, which syncs across devices, so this is a read-modify-write. The current set is read back off the live chats immediately before writing so the write is always that set plus or minus one. Verified by round-trip. The maximum is read from IMCore rather than assumed — going over it is not refused, it just produces a set the app cannot draw. |
| Set the group photo | unverified | `setGroupPhoto`. `sendGroupPhotoUpdate:` takes a transfer GUID from its own factory, `createNewOutgoingGroupPhotoTransferWithLocalFileURL:` — a group photo is not a message and never enters the transcript. Passing no file clears it. Deliberately not run against a real group: a wrong result overwrites a picture that cannot be recovered. |
| Change the sending alias | done | `setSendingAlias`. Only a vetted alias is accepted — IMCore takes an unvetted one and then fails every send, which reads as the network being down rather than a bad address. |
| Send a sticker | done | `send({ files, sticker })`. There is no sticker send API, which is what made this look blocked — searching for one finds only ChatKit view controllers that need an on-screen conversation. A sticker is not sent by a sticker API: it is an ordinary file transfer carrying `setIsSticker:`, `setStickerUserInfo:` and `setAttributionInfo:`. Confirmed end to end: Messages recognised it, moved the file into `StickerCache/`, and the row reads back `is_sticker` 1 with the user-generated sticker plugin as its source. Size and dimension limits are enforced, because an oversized sticker is silently delivered as a plain image. |

### Reading a contact

A handle is a phone number or an email address, and on its own it tells a reader
nothing. `contact(handle)` returns the card behind it.

Two things about how Contacts works decide whether this returns a name or a
person, and both are easy to get wrong:

- **A CNContact hands out only the keys it was fetched with.** Not "returns nil
  for the rest" — reading an unfetched key raises. That is why `pictureData` on
  a handle is nil in a running app: nobody asked for it. The key list in
  `contact.m` is therefore the contract; anything missing from it is unavailable
  however the caller asks.
- **A handle that has never been in a conversation has no contact properties
  loaded**, and the keyed fetch answers nil for it — while still knowing the
  person's name, so the result looks like a contact with nothing on it. Reading
  `cnContact` once makes it load them, and the fetch then works. Handles found
  in an open conversation are already loaded, so those are preferred.

The photo is opt-in (`includePhoto`), since it is tens of kilobytes and most
callers want the name. `hasPhoto` answers whether there is one without paying
for it — and it is computed from the bytes, because Contacts'
`imageDataAvailable` reads false on cards that plainly do have a picture.

Verified against real cards for names, phone numbers, email addresses and
pictures. Postal addresses, birthdays, relations and social profiles go through
the same labelled-value path but no card in the address book tested against had
any, so those are decoded but unproven.

### The + menu

What the app offers behind the **+** button, and where each one stands:

| + menu item | Status | Notes |
|---|---|---|
| Photos | done | Through the injected path — see below |
| Polls | done | `sendPoll` to create, `votePoll` to vote |
| Send Later | done | `sendLater` / `cancelScheduled` / `scheduled` |
| Message Effects | done | Bubble and screen effects, on `send` |
| Stickers | done | Sent as a file transfer wearing sticker metadata — see above |
| Genmoji | blocked | Generating one needs the on-device model behind the extension UI. Sending an existing one means an adaptive image glyph in the body, which is an attachment. |
| Image Playground | blocked | Generation runs in the app extension; `IMPluginPayload` carries only a `generativePlaygroundRecipeData` field for the result |
| #images | blocked | An image-search extension: the result is an attachment |

Genmoji, Image Playground and #images share one wall, and it is *generation*,
not sending: each runs its model inside an app extension whose UI is the only
entry point. Their results are attachments, so a file already produced by one
sends normally with `send({ files })` — it just arrives as an ordinary image
rather than as a glyph.

**Polls.** A poll is an `MSMessageExtensionBalloonPlugin` message, and the
factory that carries attachments and an effect also takes a plugin identifier
and its payload — so creating one is an ordinary send with those two filled in.
The content is not archived as objects: the question and options are JSON,
base64-encoded into a `data:` URL inside the payload. Each option gets a fresh
identifier, which is what a vote later names.

Two payload fields decide how the bubble draws:

- `liveLayoutInfo`, a nested archive of `MSMessageLiveLayout`, is what makes
  the poll interactive rather than a static card. Omitting it sends something
  that stores and delivers correctly and cannot be voted on.
- `ai` is a rendered preview image, used only where the plugin cannot run. It
  is left out rather than faked.

**Voting.** A vote is two things at once — an app-extension balloon carrying
the choice, and an association pointing at the poll — and exactly one factory
takes both: `customAcknowledgementMessageWithPayloadData:…`, IMCore's route for
a plugin acknowledging another message. The ordinary plugin factory has nowhere
to put the association and the association factory has nowhere to put the
payload; either alone produces a message that sends and is never counted. The
factory takes no association *type*, so 4000 is set on the built message
afterwards.

The payload is much smaller than a poll's — no layout, no preview, no options,
just `{sessionIdentifier, URL, an}`. Two fields decide whether it counts:

- the **session identifier must be the poll's own**. Both carry the same one;
  a vote with a fresh one is stored, delivered, and tallied nowhere.
- the option identifier is the UUID the poll minted when it was created, which
  is why voting reads the poll first rather than making the caller find it.

**The vote must be paged in first, and this is the trap.** IMCore routes an
associated message by resolving the message it points at. When the poll is not
in the chat's loaded window it cannot, and the vote is filed under *this
account's own conversation* — sent, delivered, stored, counted nowhere, no
error. It also comes back with a different GUID than the one the send returned,
so even reading it back finds nothing. Paging the poll in first
(`loadMessagesBeforeAndAfterGUID:`) fixes the routing and the GUID together.

Worth noting that this is the same failure Send Later shows, and the same one
that made cancelling a scheduled message silently no-op. Three different
operations, one cause: IMCore resolving a destination for itself and falling
back to the self-chat when it cannot.

**Send Later.** The delivery time is the message's own timestamp: IMCore dates
the message into the future and holds it until then, storing it with
`schedule_type` 2 and `schedule_state` 0.

This was unreliable for a long time, and the cause was the construction rather
than anything about scheduling. Building the message by hand — through the
initialiser that takes the time, the schedule type and the schedule state
separately — states the same thing twice, and IMCore was observed honouring one
and not the other. Both failure modes were silent:

- delivering the message immediately while keeping the future timestamp, so the
  row read like a scheduled message that had already been sent; and
- filing it under this account's own conversation rather than the one it was
  addressed to.

Neither raised, and `_supportsSendLater` answered yes in both cases, so nothing
predicted it. The reproduction was reliable: sending an ordinary message
immediately before the scheduled one failed every time.

`instantMessageWithText:messageSubject:flags:threadIdentifier:associatedMessageGUID:scheduledDate:`
is the factory made for this. It takes the delivery date and fills in the type
and state itself, and the same reproduction now succeeds — three for three,
scheduled and filed in the conversation it was addressed to. The hand-built
initialiser is kept as a fallback for builds without the factory.

`sendLater` still reads the row back and reports `scheduled` and the `chatGuid`
it landed in. That is cheap, and it is what turns a silent failure into a
visible one if a future release regresses.

Three operations have now hit the same wall — a scheduled message filed under
the self-chat, a poll vote filed under the self-chat, and a cancel acting on the
wrong item. In each case IMCore was resolving something for itself from
incomplete state and falling back silently rather than failing. It is worth
assuming, for any new write, that a call returning means nothing until the
result is read back.

Cancelling has two traps of its own:

- `cancelScheduledMessageItem:cancelType:` returns without complaint and leaves
  the message scheduled — it still sends.
  `retractScheduledMessagePartIndexes:fromChatItem:` is the one that works, and
  a cancelled message is removed from the store entirely.
- The message must be paged in again first. Cancelling one scheduled moments
  earlier in the same session otherwise acts on the item left over from
  sending, which also reports success and also still sends.

Verify a cancel by the row being gone, not by the call returning.

### How a tapback is sent

`sendMessageAcknowledgment:forChatItem:` is IMCore's own reaction path, but it
expects a ChatKit chat item, and `IMChat.chatItems` yields IMCore ones. Two
things are missing, and each fails differently:

- It asks the argument for `IMChatItem` — ChatKit's accessor for the underlying
  IMCore item — and for `isEditedMessageHistory`. Neither exists on an IMCore
  item, so the call raises. A proxy answering those two and forwarding the rest
  (`messageItem`, `index`) is accepted, and the reaction sends and delivers.

- Before writing the reaction, IMCore asks the item *what sort of part it is*,
  by testing it against `CKTextMessagePartChatItem`,
  `CKAttachmentMessagePartChatItem` and `CKTranscriptPluginChatItem`. An IMCore
  item answers no to all three, and the summary comes out empty: the reaction
  still lands on the right message, but the recipient's notification reads
  "Laughed at an attachment" instead of quoting the text. The proxy therefore
  also answers to ChatKit's name for whatever it wraps, which is IMCore's name
  with a different prefix. With that in place `message_summary_info` matches
  what the app itself writes — `amc: 1`, the quoted `ams`, and the `ampt` part.

The failure mode worth remembering: a reaction that sends, delivers, and is
subtly mis-summarised looks identical to a correct one unless the stored
summary is read.

**This is no longer the primary route, because it has a silent failure of its
own.** On some messages it returns a GUID and stores nothing — the same silent
success it was adopted to cure. Reproducible across restarts, on messages whose
neighbours in the same conversation took reactions normally. Because it reports
success, nothing after it ever runs, so no fallback can rescue it.

IMCore's tapback objects (see the next section) store on exactly those
messages, and they are now the first thing tried. What kept them second was
fidelity rather than reliability — they were writing `amc`/`ams`/`ust` without
the `ampt` rich-text part — and that is now settled: the summary is built by
`+[IMChat configureMessageSummaryInfoForChatItem:]` for both routes, which is
where `ampt` comes from, and the proxy below is what lets that call accept an
IMCore item.

The proxy therefore still earns its keep: it is what makes the summary right,
even though the acknowledgment call it was written for is now only a fallback.

Whether `ampt` appears at all is a property of the target, not of the route.
Measured over several hundred reactions in one real store: plain-text targets carry it,
attachment targets mostly do not, and reactions **this** account sends to
incoming text messages have essentially never carried it — 53 of 55 lack it,
including ones the Messages UI itself wrote long before this bridge existed.
Outgoing-text targets carry it every time. The route now matches that
distribution, which is the only sense in which "matching what Messages writes"
can be checked.

### How an emoji reaction is sent

Reacting with an arbitrary character is not the same feature wearing a
different code, and none of the ways of reaching the classic six extend to it:

- `sendMessageAcknowledgment:forChatItem:` is addressed entirely by type code,
  and no code carries a character. The variant whose name suggests otherwise,
  `…forChatItem:languageIdentifier:`, takes a BCP-47 language for localising
  the recipient's notification — passing an emoji there returns a GUID and
  stores nothing.
- Hand-building the associated message, the fallback that does store a classic
  tapback, is accepted and dropped for a 2006 even with the character set on
  the message and echoed into the summary.

IMCore models this reaction as an object rather than a number. `IMEmojiTapback`
— a subclass of `IMTapback`, alongside `IMClassicTapback` for the named six —
holds the character via `initWithEmoji:isRemoved:`, and `IMTapbackSender` is
what Messages hands it to:

```objc
initWithTapback:chat:messageGUID:messagePartRange:messageSummaryInfo:threadIdentifier:
```

then `send`. The sender wants IMCore's own values throughout, so nothing here
needs a ChatKit item. Removing is the same object built with its removed flag
set, which is what turns the 2006 into a 3006.

The summary is the one place a ChatKit item is still wanted, and it is worth
the detour: `+[IMChat configureMessageSummaryInfoForChatItem:]` builds it the
way Messages does, including the `ampt` archived attributed string that cannot
be produced by hand. It is a ChatKit category, so it is given the same proxy
the acknowledgment path uses. Without it the summary is `amc`/`ams`/`ust` and
`ampt` is simply absent.

Since `IMTapbackSender` takes `IMClassicTapback` just as readily, this is now
the route for **every** reaction, not just the emoji ones — see the note above
on why the acknowledgment path lost the primary slot.

The character is carried in `associated_message_emoji`, not in the summary:
a stored reaction whose summary looks right but whose column is empty is not
one the recipient can see.

### Reading what arrived while nothing was listening

A consumer that goes away — a restart, a crash, a machine asleep — comes back
needing one thing: everything that happened since. Paging backwards cannot
answer it. You would start at the newest message and walk towards the cursor,
not knowing when to stop, across every conversation separately, because a
caller that was away does not know which ones have news.

So `storeHistory` pages both ways, and which cursor you pass decides:

- `beforeRowID` reads **backwards** into one conversation's past. `chat` is
  required, since reading "everything older" across all of them is the whole
  archive.
- `sinceRowID` reads **forwards** from a position recorded earlier. `chat` is
  optional and usually left out, and each message then carries the `chatGuid`
  it belongs to.

Passing both is refused rather than resolved: a window bounded at both ends has
no single cursor to continue from, and which end the caller meant is not
guessable.

Where the first cursor comes from is the awkward part, and the answer is to ask
with no cursor at all. That returns the newest page, whose `nextSinceRowID` is
the position to start from — so a first run begins at now rather than replaying
years of history one page at a time.

Two details that only show up in use:

**The cursors come from the page as read, not from what came back.** Reactions
are folded onto the messages they react to, so their own rows vanish from the
result. A page that folded away entirely still moves the cursor, or a run of
reactions would be read forever.

**Nothing new holds the cursor where it was.** An idle poll answers with the
`sinceRowID` it was given rather than zero, so a caller that stores the reply
unconditionally does not reset itself and replay the archive.

The live event stream carries the same rowid on each message, so the two fit
together: follow events while connected, record the highest `rowid` seen, and
ask for everything after it on the way back up.

### One person, more than one conversation

`resolveChat` answers with a single chat, and for addressing a send that is
fine. For reading it is not: the same person can have an iMessage thread and an
SMS thread, and which one is current changes with whether they have signal. A
reply sent into the quiet one goes somewhere nobody is looking.

`resolveChats` returns the whole set, most recently active first — so the head
is the live thread and the tail is still there to be read. On the machine this
was written on, asking for a plain phone number turned up two threads for the
same person: the ordinary one, and a second whose GUID embedded the contact's
name from however that conversation was first created, last used four months
earlier.

Numbers are matched on their national digits, because the same person is
written `+15551234567` in one chat and `(555) 123-4567` in another depending on
how the conversation started. An exact string comparison answers "never heard
of them" for someone you are mid-conversation with. Email is matched
case-insensitively, and a string of fewer than ten digits is not matched at all
— a short "match" would put unrelated people in the same conversation.

### A typing indicator outlives whoever set it

`setLocalUserIsTyping:` is a flag, not a timer. Nothing expires it; it stays
until something turns it off. That is the right shape for an API — an explicit
stop beats a heartbeat — but it means a client that dies mid-turn leaves the
dots showing in a real conversation, with nobody left to clear them and a
person on the other end waiting for a message that is never coming.

The bridge tracks which conversations it switched on and clears them when the
host disconnects, for any reason: a clean close, a crash, a killed process. All
of them look the same from inside the injected app — the socket reaches EOF —
so one hook covers every case. An ordinary turn that turns the indicator off
itself leaves nothing to clear, and the cleanup is a no-op.

### Where an audio message's words are

An audio message carries no text of its own. Its body is a single U+FFFC
placeholder and its attachment is `Audio Message.caf`, so a reader that only
looks at `text` sees an empty bubble where the app shows a sentence — which
makes voice notes invisible to anything reading the conversation.

Messages transcribes them on device, and the result is filed under
`audio-transcription` in the attachment's **`user_info`** plist. That is the
same column deliberately withheld from callers, because it also holds the
iCloud transfer's URL and decryption key. So exactly one key is lifted out of
it and the dictionary is never returned, which is how `sticker_user_info` is
already handled.

`IMFileTransfer.audioTranscriptionText` looks like the obvious source and is
where ChatKit reads it from, but it is populated as the balloon is drawn: on a
message nobody has scrolled to it answers nil. The live path therefore prefers
the transfer's `userInfo` — the same key, present whether or not anything has
been rendered — and keeps the property as a fallback.

Detection is `isAudioMessage` on the message, not `isOpusAudioMessage` on the
transfer: the latter is true only of the newer encoding and answers no for the
`.caf` recordings the app has sent for years.

Two limits worth knowing:

- **Not every audio message has one.** Of 19 in a real store, 16 do. A message
  that arrived without a transcript does not acquire one later.
- **Sending is not the same feature.** Sending a `.caf` produces an ordinary
  attachment — it uploads and plays, but `is_audio_message` stays 0, so it is
  not the expiring voice-message balloon. `isAudioMessage` is read-only on both
  `IMMessage` and `IMFileTransfer` and no setter exists anywhere reachable, so
  what makes one is not established and is not guessed at here. Outgoing audio
  also carries no transcript: the receiving device is what transcribes.

### How attachments get uploaded

This was documented here for a long time as impossible, on the evidence that
every call in the sequence reported success and the transfer still sat at state
0 with no `attachment` row ever created. The calls were right. What was missing
was where the file lived.

**The daemon uploads from the attachment tree, not from wherever the caller
left the file.** So the order is: copy the file under
`~/Library/Messages/Attachments/`, *then* create the transfer against the
staged copy, then `registerTransferWithDaemon:` — which is the call that
actually starts the upload, and the one that was never being made. With the
file in place and that call made, the upload runs normally: `transfer_state`
reaches 5 and the attachment row appears with its MIME type and size.

Two details that cost time:

- `IMDPersistentAttachmentController -_persistentPathForTransfer:…` is the
  documented way to find that location and it does not work here. With a nil
  chat GUID it answers nil; with one it answers an iOS-shaped `/var/mobile/…`
  path that does not exist on macOS. Staging into the user-visible attachment
  tree first sidesteps it entirely — the daemon reads from there too. The call
  is still attempted opportunistically in case a later build fixes it.
- Staging happens in the **client**, not in the injected code. Messages is
  sandboxed: it reads the attachment tree but is refused writes into it, so a
  copy attempted from inside fails with a permission error.

`assignTransfer:toMessage:account:` still looked like a missing binding step
along the way. It is not, and it is actively harmful: it corrupted IMCore's
in-memory chat-to-identity mapping, so a conversation rendered under the wrong
contact and appeared twice in the sidebar. The stored data was unaffected and a
restart cleared it, but that call is not used.

### Sending safely

`sendMessage:` really does send, and **retract is not a reliable undo**. It
removes the message from your side while often leaving it on the recipient's,
with no way to retry. Do not treat it as a way to clean up after a test.

Test against a recipient who has agreed to receive test traffic, send as few
messages as the check actually needs, and assume every one of them is
permanent. If you do retract, leave the message to settle for a minute first —
retracting immediately after sending is what failed here.

### Class factories drop a field; the initialiser does not

No single *factory* method accepts attachments, an expressive effect and a reply
thread together — each of the three drops one:

- `…fileTransferGUIDs:flags:threadIdentifier:` — attachments + thread, no effect
- `…messageSubject:flags:expressiveSendStyleID:threadIdentifier:` — effect + thread, no attachments
- `…fileTransferGUIDs:flags:balloonBundleID:payloadData:expressiveSendStyleID:` — attachments + effect, no thread

This was documented as a hard constraint, and it is not one. The designated
initialiser those factories sit on top of takes all three:

```
-[IMMessage initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:
   error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:
   threadIdentifier:]
```

so the combination is only unreachable through the convenience methods. The
send API uses the initialiser for that case and the factories for the rest,
which are the proven paths.

## Known effect identifiers

Two families, both observed in real messages:

- Bubble: `com.apple.MobileSMS.expressivesend.` + `impact`, `loud`, `gentle`, `invisibleink`
- Screen: `com.apple.messages.effect.CK` + `EchoEffect`, `ConfettiEffect`,
  `HappyBirthdayEffect`, `FireworksEffect`, `LasersEffect`, `BalloonsEffect`,
  `SpotlightEffect`, `ShootingStarEffect`, `HeartEffect`, `SparklesEffect`
