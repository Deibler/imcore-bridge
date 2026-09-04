// Shared declarations for the injected bridge.
#ifndef IMCORE_BRIDGE_H
#define IMCORE_BRIDGE_H

#import <Foundation/Foundation.h>

/// Boxes a condition as a JSON boolean.
///
/// C's comparison and logical operators yield `int`, so `@(a == b)` boxes as a
/// number and reaches the client as 0 or 1 rather than false or true. This has
/// been the cause of that often enough to be worth a name.
static inline NSNumber *IMBBool(BOOL value) { return value ? @YES : @NO; }

/// Absolute path of the Unix socket the bridge listens on.
///
/// Messages.app is sandboxed, so this must live inside its container — an
/// arbitrary path such as /tmp is not writable from inside the host process.
/// Overridable with IMCORE_BRIDGE_SOCKET for tests and side-by-side installs.
NSString *IMBSocketPath(void);

/// Appends a line to the bridge log inside the app container. Safe to call
/// from any thread at any point in the launch sequence.
void IMBLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

/// Runs `block` on the main thread and waits up to `timeout` seconds.
/// IMCore is main-thread affine, but the main thread can be wedged, so every
/// hop is bounded rather than using dispatch_sync (which cannot time out).
/// Returns nil and sets *timedOut if the deadline passes.
id IMBRunOnMain(id (^block)(void), NSTimeInterval timeout, BOOL *timedOut);

/// YES once IMCore's classes are registered in the runtime.
BOOL IMBIsIMCoreReady(void);

/// Dispatches one decoded JSON-RPC request, returning the JSON-serialisable
/// result. On failure returns nil and fills *errCode / *errMessage.
id IMBDispatch(NSString *method, NSDictionary *params,
               NSString **errCode, NSString **errMessage);

/// Turns off every typing indicator this bridge switched on. Called when the
/// host disconnects, so a client that died mid-turn does not leave the dots
/// showing in a real conversation forever.
void IMBClearTypingIndicators(void);

/// Broadcasts an event object to every subscribed client.
void IMBBroadcastEvent(NSString *type, NSDictionary *data);

/// Starts observing IMCore notifications and forwarding them as events.
void IMBStartEventObservers(void);

/// Capability matrix: feature name -> @YES/@NO, from live selector probes.
NSDictionary *IMBCapabilities(void);

/// Resolves an IMChat from a GUID, chat identifier, or bare handle.
/// Returns nil if nothing matches. Must be called on the main thread.
id IMBLookupChat(NSString *identifier);

/// Whether two addresses name the same person, across IMCore's e:/p: type
/// prefixes, email case, and national/+-prefixed phone spellings.
BOOL IMBAddressesMatch(NSString *a, NSString *b);

/// Asserts a resolved chat really is the conversation a spec addressed.
/// Returns nil when it is (or when the spec doesn't name one person — group
/// specs assert nothing); otherwise a human-readable account of the mismatch.
/// This is the invariant that makes a poisoned registry object refuse instead
/// of quietly reaching the wrong thread. Must be called on the main thread.
NSString *IMBChatMatchesSpec(NSString *spec, id chat);

/// Every conversation an identifier resolves to, most recently active first.
/// A 1:1 legitimately maps to more than one — the same person's iMessage
/// thread and SMS thread — so a caller that must act on the live one, or on
/// all of them, needs the set rather than a pick.
NSArray *IMBLookupChats(NSString *identifier);

/// Every conversation a handle appears in, groups included, most recently
/// active first. Empty means this address has never been spoken to.
NSArray *IMBChatsWithHandle(NSString *handle);

/// Serialises an IMMessage/chat item into a plain JSON-safe dictionary.
NSDictionary *IMBSerializeMessage(id message, id chat);

/// Serialises an IMChat (guid, display name, participants) for the client.
NSDictionary *IMBSerializeChat(id chat);

/// Resolves a handle to `{ id, name?, nickname? }` so an agent sees a person
/// rather than a raw phone number.
NSDictionary *IMBHandleInfo(id handle);

/// The contact picture for a handle — Contact Poster, Contacts, or a business
/// brand logo, in that order. Returns nil when none is set.
NSData *IMBHandleAvatar(id handle, NSString **mimeType);

/// The full contact card behind a handle: names, phone numbers, addresses,
/// birthday, and everything else Contacts holds. `includePhoto` adds the
/// picture bytes. Must be called on the main thread.
NSDictionary *IMBContactCard(id handle, BOOL includePhoto);

/// Finds the IMHandle for a phone number or email address, via the account and
/// falling back to open conversations. Must be called on the main thread.
id IMBLookupHandle(NSString *handleID);

/// A conversation's own details: its picture, and the flags that are not
/// messages. Read from the store, where the chat names its current photo.
NSDictionary *IMBStoreChatDetails(NSString *chatGuid,
                                  NSString **errCode, NSString **errMessage);

/// Attachments on a message: filename, mime type, on-disk path, byte size, and
/// the on-device audio transcription when Messages has produced one.
NSArray *IMBSerializeAttachments(id message);

/// The IMMessage behind a chat item (a message surfaces as several parts).
id IMBUnderlyingMessage(id item);

/// Adds link/poll/effect/threading/tapback fields to a serialised message,
/// including mentions and URLs read from the attributed body.
void IMBAddRichFields(NSMutableDictionary *out, id message);

/// Searches the CoreSpotlight index Messages itself maintains, covering
/// message text, text recognised inside images, spoken content, and Apple's
/// own image classification. `chatGuid` and `kinds` are optional filters.
NSDictionary *IMBSearch(NSString *text, NSUInteger limit, NSString *chatGuid,
                        NSArray *kindFilter, NSString **errCode, NSString **errMessage);

/// Decodes a stored `attributedBody` blob into readable text plus its runs
/// (parts, mentions, links). Returns nil when the archive cannot be read.
NSDictionary *IMBDecodeAttributedBody(NSData *data);

/// Decodes a rich balloon payload (link preview, poll) into readable content.
/// Returns nil for plugins whose payload has no documented shape.
NSDictionary *IMBDecodePayload(NSData *payload, NSString *bundleID);

/// Builds the payload for a new poll, giving each option a fresh identifier.
NSData *IMBBuildPollPayload(NSString *question, NSArray<NSString *> *options,
                            NSString *creator);

/// The plugin identifier a poll message carries.
extern NSString *const IMBPollBundleID;

/// Builds the payload for a vote in an existing poll. `sessionID` must be the
/// poll's own; a vote carrying a fresh one is not counted.
NSData *IMBBuildVotePayload(NSString *sessionID, NSString *handle, NSString *optionID);

/// Casts a vote in the poll named by `pollGUID`. Returns the vote's GUID.
NSString *IMBSendPollVote(id chat, NSString *pollGUID, NSData *payload,
                          NSString **errCode, NSString **errMessage);

/// Sends an app-extension balloon (a poll) as its plugin payload.
NSString *IMBSendPluginMessage(id chat, NSString *bundleID, NSData *payload,
                               NSString *summary,
                               NSString **errCode, NSString **errMessage);

/// Schedules a message for later delivery. Returns its GUID.
NSString *IMBSendLater(id chat, NSString *text, NSDate *deliverAt,
                       NSString **errCode, NSString **errMessage);

/// Cancels a scheduled message that has not gone out yet.
BOOL IMBCancelScheduled(id chat, id chatItem, NSString **errCode, NSString **errMessage);

/// Finds or starts a conversation with the given handles. Nothing is sent and
/// nobody is notified until a message goes out.
id IMBCreateChat(NSArray<NSString *> *handleIDs, NSString *name,
                 NSString **errCode, NSString **errMessage);

/// Removes messages from this Mac. A local delete, not an unsend: the
/// recipient keeps their copy and is told nothing.
BOOL IMBDeleteMessages(id chat, NSArray *chatItems, NSString **errCode, NSString **errMessage);

/// Pages the messages around `guid` into the chat's loaded window.
BOOL IMBReloadAround(id chat, NSString *guid);

/// Deep history from the message store, paged by rowid. Reaches the full
/// archive. `beforeRowID` pages backwards through older slices; `sinceRowID`
/// pages forwards through what arrived after a cursor, and a nil `chatGuid`
/// then spans every conversation. Pass one cursor or neither, never both.
NSDictionary *IMBStoreHistory(NSString *chatGuid, NSUInteger limit, long long beforeRowID,
                              long long sinceRowID, NSString **errCode, NSString **errMessage);

/// One message from the store by GUID, with its chat. Used to read a search
/// hit in full. Returns message_not_found for hits that outlived their message.
NSDictionary *IMBStoreMessage(NSString *guid, NSString **errCode, NSString **errMessage);

/// Messages being held for later delivery, optionally for one chat only.
/// Reports the chat each one actually landed in, which cancelling needs.
NSDictionary *IMBStoreScheduled(NSString *chatGuid,
                                NSString **errCode, NSString **errMessage);

/// Decodes the parts of `message_summary_info` whose meaning is established:
/// the version chain of an edited message, whether an unsend failed to
/// propagate, and a scheduled message's delivery time. Returns nil if empty.
NSDictionary *IMBDecodeSummaryInfo(NSData *blob, long long partCount);

/// The same, from the dictionary a live IMMessage already holds.
NSDictionary *IMBSummaryFields(NSDictionary *summary, long long partCount);

/// A group event read off a live transcript item. IMCore models these as their
/// own item classes rather than messages, so they arrive with no text.
NSDictionary *IMBGroupEventForItem(id item);

/// Describes a transcript line that is not a message — someone added to a
/// group, a rename, a picture change. Returns nil for an ordinary message.
NSDictionary *IMBGroupEvent(long long itemType, long long actionType,
                            NSString *groupTitle, NSString *actor,
                            NSString *participant, BOOL hasAttachment,
                            long long shareStatus, long long shareDirection);

/// Human-readable name for an IMCore tapback type code, or nil.
NSString *IMBTapbackName(long long type);

/// The plain message GUID a tapback targets ("p:0/<guid>" -> "<guid>").
NSString *IMBTapbackTargetGUID(NSString *associatedGUID);

/// Locates the loaded chat item for a message GUID (tapback, retract and edit
/// all operate on the item rather than the message).
id IMBFindChatItem(id chat, NSString *guid);

/// Builds an outgoing IMMessage, or fails when the requested combination of
/// attachments, effect and reply thread has no matching factory method.
/// Every animated text effect this build knows, by name, asked of IMCore
/// rather than kept as a list here.
NSArray<NSString *> *IMBTextEffectNames(void);

/// `formatting` applies styles, text effects and mentions over ranges of the
/// body; ranges outside it are ignored rather than raising inside IMCore.
/// Stages a local file into the attachment tree and creates a transfer for it,
/// returning `{ guid, filename }`. Pass `sticker` (optionally carrying a
/// `label`) to send the file as a sticker rather than an ordinary attachment.
///
/// The transfer is not yet registered with the daemon, so a caller that fails
/// after this point leaves nothing uploading. Follow with IMBRegisterTransfer.
NSDictionary *IMBPrepareTransfer(NSString *path, NSDictionary *sticker,
                                 NSString **errCode, NSString **errMessage);

/// Hands a prepared transfer to the daemon, which starts the upload. Call only
/// once the message referencing it has been built.
BOOL IMBRegisterTransfer(NSString *guid);

/// Builds an outgoing IMMessage. Each entry of `attachments` is either a
/// transfer GUID or a `{ guid, filename }` dictionary as returned by
/// IMBPrepareTransfer.
id IMBBuildMessage(NSString *text, NSString *subject, NSArray *attachments,
                   NSString *effect, NSString *threadIdentifier, NSArray *formatting,
                   NSString **errCode, NSString **errMessage);

/// Sends a message into a chat. `service` names iMessage or SMS to route this
/// one message over that account without changing the conversation's own; nil
/// sends the way the conversation already sends.
NSString *IMBSendMessage(id chat, id message, NSString *service,
                         NSString **errCode, NSString **errMessage);
/// The handle a 1:1 conversation currently routes to; nil for groups.
NSString *IMBChatRecipientID(id chat);
/// Whether this host refuses every send that targets its own address
/// (IMCORE_BRIDGE_BLOCK_SELF_SENDS in the injected environment).
BOOL IMBSelfSendsBlocked(void);
/// Whether the conversation is our own thread by any reading.
BOOL IMBChatTargetsSelf(id chat);
long long IMBTapbackType(NSString *kind, BOOL remove, BOOL *ok);
/// Reacts to a message. `emoji` carries the character for the custom-emoji
/// kinds (2006 and 3006) and must be nil for every other type.
/// Whether IMCore would act on a membership change, without making it. This is
/// what the app asks before it enables the menu item, and it is the only way to
/// learn the answer without a conversation changing underneath you.
BOOL IMBGroupChangeAllowed(id chat, BOOL adding, NSArray<NSString *> *ids,
                           NSString **errCode, NSString **errMessage);

/// Removes a conversation outright, as deleting it in the app does — not the
/// same as emptying it, which leaves it in the list with nothing in it.
BOOL IMBDeleteChat(id chat, NSString **errCode, NSString **errMessage);

/// Sends this account's Name & Photo to a handle, as tapping Share does.
BOOL IMBShareNameAndPhoto(NSString *handleID, NSString **errCode, NSString **errMessage);

/// Sticks a sticker onto an existing message part, as peel-and-stick does.
/// Returns the GUID of the sticker message, not of the message it stuck to.
NSString *IMBSendStuckSticker(id chat, id chatItem, NSArray<NSString *> *transferGUIDs,
                              NSString **errCode, NSString **errMessage);

BOOL IMBSendTapback(id chat, id chatItem, long long type, NSString *emoji,
                    NSString **errCode, NSString **errMessage);
BOOL IMBRetract(id chat, id chatItem, NSString **errCode, NSString **errMessage);
BOOL IMBEdit(id chat, id chatItem, long long partIndex, NSString *newText,
             NSString **errCode, NSString **errMessage);
BOOL IMBMarkRead(id chat);
BOOL IMBGroupRename(id chat, NSString *name, NSString **errCode, NSString **errMessage);
BOOL IMBGroupAddMembers(id chat, NSArray<NSString *> *ids, NSString **errCode, NSString **errMessage);
BOOL IMBGroupRemoveMembers(id chat, NSArray<NSString *> *ids, NSString **errCode, NSString **errMessage);
BOOL IMBGroupLeave(id chat, NSString **errCode, NSString **errMessage);

// --- chat lifecycle --------------------------------------------------------

/// Returns a conversation to unread, from `guid` or from its last message.
BOOL IMBMarkUnread(id chat, NSString *guid, NSString **errCode, NSString **errMessage);

/// Pushes a notification for one message through a silenced conversation.
BOOL IMBNotifyAnyway(id chat, NSString *guid, NSString **errCode, NSString **errMessage);

/// Whether the app currently shows this conversation as pinned.
BOOL IMBIsPinned(id chat);

/// Whether a conversation is silenced, and the date the silence runs to.
BOOL IMBIsMuted(id chat);
NSDate *IMBMutedUntil(id chat);

/// Silences a conversation or lifts the silence. Mute is held as a date, so
/// `until` nil with `muted` set means indefinitely.
BOOL IMBSetMuted(id chat, BOOL muted, NSDate *until,
                 NSString **errCode, NSString **errMessage);

/// Empties a conversation of its messages. Local only — nobody else loses
/// their copy — and recoverable for thirty days, as `deleteMessages` is.
BOOL IMBDeleteAllHistory(id chat, NSString **errCode, NSString **errMessage);

/// Reports a conversation to Apple as junk. Leaves the machine, and one-way.
BOOL IMBReportJunk(id chat, NSString **errCode, NSString **errMessage);

/// The unread messages in this conversation that mention this account.
NSArray<NSString *> *IMBUnreadMentions(id chat);

/// How Messages has filed this conversation, as the raw value IMCore holds.
long long IMBFilterCategory(id chat);

/// Shares this account's location with a conversation for `seconds`, which
/// must be positive — sharing with no end is deliberately not offered.
BOOL IMBShareLocation(id chat, long long seconds,
                      NSString **errCode, NSString **errMessage);

/// Resends a failed iMessage over SMS, as "Send as Text Message" does.
BOOL IMBDowngradeMessage(id chat, NSString *guid,
                         NSString **errCode, NSString **errMessage);

/// Pins or unpins a conversation. Rewrites the shared pinned list; see
/// lifecycle.m for why that is done by reading the live set back.
BOOL IMBSetPinned(id chat, BOOL pinned, NSString **errCode, NSString **errMessage);

/// Sets a group conversation's photo, or clears it when `path` is empty.
BOOL IMBSetGroupPhoto(id chat, NSString *path, NSString **errCode, NSString **errMessage);

// --- identity --------------------------------------------------------------

/// The signed-in messaging identity: Apple ID, aliases, SMS relay state.
NSDictionary *IMBAccountInfo(void);

/// Changes which vetted alias outgoing iMessages are attributed to.
BOOL IMBSetSendingAlias(NSString *alias, NSString **errCode, NSString **errMessage);

/// The Name & Photo card a handle shared, or your own when `handleID` is nil.
NSDictionary *IMBNickname(NSString *handleID, NSString **errCode, NSString **errMessage);

/// Name & Photo updates waiting to be accepted or declined.
NSArray *IMBPendingNicknames(void);

// --- statistics ------------------------------------------------------------

/// Counts and distributions over one conversation, or the whole store.
NSDictionary *IMBStats(NSString *chatGuid, long long sinceUnix,
                       NSString **errCode, NSString **errMessage);

#endif
