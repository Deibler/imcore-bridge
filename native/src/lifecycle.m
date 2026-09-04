// Chat lifecycle: unread state, forced notifications, pinning, group photo.
//
// Everything here is a context-menu action in Messages' own UI, which is the
// bar set in ops.m: only invoke what the app invokes during ordinary use.
//
// Pinning is the one entry that deserves a second look. There is no "pin this
// chat" call — the only setter replaces the entire pinned list, which is
// shared state that syncs across devices. So a pin is a read-modify-write, and
// a bug that dropped an entry would silently unpin a conversation everywhere.
// It is done here by reading the live list back off the chats themselves
// rather than by tracking identifiers, so the write is always the current set
// plus or minus exactly one chat.
#import "bridge.h"
#import <objc/message.h>

static id safeValue(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static BOOL invokeVoid(id target, NSString *selector, id argument, BOOL hasArgument,
                       NSString **errCode, NSString **errMessage) {
    SEL sel = NSSelectorFromString(selector);
    if (![target respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = [NSString stringWithFormat:
            @"%@ is unavailable on this build", selector];
        return NO;
    }
    @try {
        if (hasArgument) {
            ((void (*)(id, SEL, id))objc_msgSend)(target, sel, argument);
        } else {
            ((void (*)(id, SEL))objc_msgSend)(target, sel);
        }
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"%@ threw: %@", selector, e.reason);
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = e.reason ?: @"call failed";
        return NO;
    }
}

/// Returns a conversation to unread.
///
/// With no GUID this is the app's "Mark as Unread": the last message is the
/// one that gets the dot. Naming a message marks from there instead.
BOOL IMBMarkUnread(id chat, NSString *guid, NSString **errCode, NSString **errMessage) {
    if (!guid.length) {
        return invokeVoid(chat, @"markLastMessageAsUnread", nil, NO, errCode, errMessage);
    }

    id item = IMBFindChatItem(chat, guid);
    id message = IMBUnderlyingMessage(item) ?: item;
    if (!message) {
        if (errCode) *errCode = @"not_found";
        if (errMessage) *errMessage = [NSString stringWithFormat:
            @"no message '%@' in this conversation", guid];
        return NO;
    }
    return invokeVoid(chat, @"markMessageAsUnread:", message, YES, errCode, errMessage);
}

/// Pushes a notification for a message through a silenced conversation.
///
/// This is the "Notify Anyway" button that appears when someone has
/// notifications muted or a Focus is on — it applies to a specific message,
/// not to the conversation as a whole.
BOOL IMBNotifyAnyway(id chat, NSString *guid, NSString **errCode, NSString **errMessage) {
    id item = IMBFindChatItem(chat, guid);
    if (!item) {
        if (errCode) *errCode = @"not_found";
        if (errMessage) *errMessage = [NSString stringWithFormat:
            @"no message '%@' in this conversation", guid];
        return NO;
    }
    return invokeVoid(chat, @"markChatItemAsNotifyRecipient:", item, YES, errCode, errMessage);
}

/// Calls a no-argument method that answers whether it did anything.
static BOOL invokeBool(id target, NSString *selector, BOOL *answer,
                       NSString **errCode, NSString **errMessage) {
    SEL sel = NSSelectorFromString(selector);
    if (![target respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = [NSString stringWithFormat:
            @"%@ is unavailable on this build", selector];
        return NO;
    }
    @try {
        BOOL result = ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
        if (answer) *answer = result;
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"%@ threw: %@", selector, e.reason);
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = e.reason ?: @"call failed";
        return NO;
    }
}

/// Whether a conversation is silenced, and until when.
BOOL IMBIsMuted(id chat) {
    return [safeValue(chat, @"isMuted") boolValue];
}

NSDate *IMBMutedUntil(id chat) {
    id date = safeValue(chat, @"muteUntilDate");
    return [date isKindOfClass:[NSDate class]] ? date : nil;
}

/// Silences a conversation, or lifts the silence.
///
/// Hide Alerts is a date rather than a flag: muting with no end is stored as
/// the distant future, muting for an hour is an hour from now, and clearing it
/// is nil. That is why there is no `setMuted:` to call — a caller that wants
/// the plain on/off gets the distant future, which is what the menu item does.
///
/// `isMuted` is IMCore's own reading of that date, so it is asked afterwards
/// rather than inferred here: a date in the past is a mute that has expired,
/// and reporting it as muted would be wrong.
BOOL IMBSetMuted(id chat, BOOL muted, NSDate *until,
                 NSString **errCode, NSString **errMessage) {
    NSDate *value = muted ? (until ?: [NSDate distantFuture]) : nil;
    return invokeVoid(chat, @"setMuteUntilDate:", value, YES, errCode, errMessage);
}

/// Empties a conversation of its messages, as Delete does in the app.
///
/// This is not an unsend: everyone else keeps their copy and is told nothing.
/// Locally it behaves like `deleteMessages` over the whole conversation — the
/// rows move into the recoverable set macOS keeps for thirty days rather than
/// being destroyed — but it is the whole history at once, so the caller is
/// told how the conversation reads afterwards rather than being left to
/// assume.
BOOL IMBDeleteAllHistory(id chat, NSString **errCode, NSString **errMessage) {
    BOOL deleted = NO;
    if (!invokeBool(chat, @"deleteAllHistory", &deleted, errCode, errMessage)) return NO;
    if (!deleted) {
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = @"Messages refused to delete the history";
        return NO;
    }
    return YES;
}

/// Reports a conversation as junk, which is the app's Report Junk button.
///
/// This leaves the machine: the messages go to Apple, and on SMS the carrier
/// can be included too. It is also one-way — there is no unreport — so it is
/// never inferred from anything, only done when asked for by name.
BOOL IMBReportJunk(id chat, NSString **errCode, NSString **errMessage) {
    BOOL reported = NO;
    if (!invokeBool(chat, @"reportJunk", &reported, errCode, errMessage)) return NO;
    if (!reported) {
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = @"Messages had nothing to report for this conversation";
        return NO;
    }
    return YES;
}

/// Which of this account's unread messages name it in a mention.
///
/// IMCore keeps this itself, which is worth using rather than re-deriving:
/// working it out from bodies means decoding every loaded message and knowing
/// which addresses are yours, and it would still only cover the loaded window.
NSArray<NSString *> *IMBUnreadMentions(id chat) {
    id guids = safeValue(chat, @"messageGuidsForMyUnreadMentions");
    if (![guids isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id guid in guids) {
        if ([guid isKindOfClass:[NSString class]] && [guid length]) [out addObject:guid];
    }
    return out;
}

/// How Messages has filed this conversation, if it has.
///
/// Reported as the raw value IMCore holds. The names behind it are not
/// exposed anywhere this can read, and this build does not persist the
/// category to the store either, so there is nothing to check a guess
/// against — see the note in CAPABILITIES.md on why the matching setter is
/// deliberately absent.
long long IMBFilterCategory(id chat) {
    SEL sel = NSSelectorFromString(@"filterCategory");
    if (![chat respondsToSelector:sel]) return 0;
    @try {
        return ((long long (*)(id, SEL))objc_msgSend)(chat, sel);
    } @catch (__unused NSException *e) {
        return 0;
    }
}

/// Resends a message over SMS, as "Send as Text Message" does.
///
/// This is a retry of something already sent, not a way to address a new
/// message to the SMS service: the button it mirrors appears on a message that
/// failed as an iMessage, and the argument is that message. Sending it for a
/// message that did not fail asks the recipient's carrier to deliver a second
/// copy, so the caller names the message and nothing is inferred.
///
/// Shipped **unverified**: it needs an iMessage that genuinely failed to send,
/// which cannot be produced on demand without messing with someone's delivery.
BOOL IMBDowngradeMessage(id chat, NSString *guid,
                         NSString **errCode, NSString **errMessage) {
    SEL sel = NSSelectorFromString(@"downgradeMessage:manualDowngrade:");
    if (![chat respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"sending as a text message is unavailable on this build";
        return NO;
    }

    id item = IMBFindChatItem(chat, guid);
    id message = IMBUnderlyingMessage(item) ?: item;
    if (!message) {
        if (errCode) *errCode = @"not_found";
        if (errMessage) *errMessage = [NSString stringWithFormat:
            @"no message '%@' in this conversation", guid];
        return NO;
    }

    @try {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(chat, sel, message, YES);
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"downgradeMessage threw: %@", e.reason);
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = e.reason ?: @"could not send as a text message";
        return NO;
    }
}

/// Shares this account's location with a conversation for a bounded time.
///
/// `shareLocationWithDuration:` takes seconds, not one of the menu's three
/// choices — ChatKit's own `locationShareOneHourTimeInterval` is a time
/// interval, which is what settles that. The menu's third option, sharing
/// indefinitely, is deliberately not offered: it would be some sentinel value,
/// nothing reachable names which, and a wrong guess broadcasts someone's
/// real-time location until they notice. A duration is therefore required and
/// must be positive, so the worst a caller can do is share for too short a
/// time.
///
/// Shipped **unverified**: confirming it means actually transmitting a real
/// location to somebody.
BOOL IMBShareLocation(id chat, long long seconds,
                      NSString **errCode, NSString **errMessage) {
    if (seconds <= 0) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage =
            @"'seconds' must be positive — sharing without an end is not offered";
        return NO;
    }

    SEL supports = NSSelectorFromString(@"_supportsShareLocation");
    if ([chat respondsToSelector:supports]) {
        @try {
            if (!((BOOL (*)(id, SEL))objc_msgSend)(chat, supports)) {
                if (errCode) *errCode = @"unsupported_feature";
                if (errMessage) *errMessage =
                    @"this conversation cannot share a location";
                return NO;
            }
        } @catch (__unused NSException *e) {
            // Fall through and let the share itself answer.
        }
    }

    SEL sel = NSSelectorFromString(@"shareLocationWithDuration:");
    if (![chat respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"sharing a location is unavailable on this build";
        return NO;
    }
    @try {
        ((void (*)(id, SEL, long long))objc_msgSend)(chat, sel, seconds);
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"shareLocationWithDuration threw: %@", e.reason);
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = e.reason ?: @"could not share the location";
        return NO;
    }
}

/// Every chat the app currently shows as pinned.
static NSArray *pinnedChats(void) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) return @[];
    id registry = ((id (*)(id, SEL))objc_msgSend)(registryClass,
                                                 NSSelectorFromString(@"sharedInstance"));
    NSMutableArray *pinned = [NSMutableArray array];
    for (id chat in safeValue(registry, @"allExistingChats") ?: @[]) {
        if ([safeValue(chat, @"isPinned") boolValue]) [pinned addObject:chat];
    }
    return pinned;
}

BOOL IMBIsPinned(id chat) {
    return [safeValue(chat, @"isPinned") boolValue];
}

/// Pins or unpins a conversation.
///
/// The list is capped, and exceeding the cap is not refused by IMCore — it
/// just produces a pinned set the app cannot draw. The cap is read from IMCore
/// rather than hard-coded, since it varies with window size on some builds.
BOOL IMBSetPinned(id chat, BOOL pinned, NSString **errCode, NSString **errMessage) {
    Class controllerClass = NSClassFromString(@"IMPinnedConversationsController");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL setSel = NSSelectorFromString(@"setPinnedChats:withUpdateReason:");
    if (!controllerClass || ![controllerClass respondsToSelector:shared]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"pinning is unavailable on this build";
        return NO;
    }
    id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, shared);
    if (![controller respondsToSelector:setSel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"setPinnedChats:withUpdateReason: is unavailable";
        return NO;
    }

    NSMutableArray *next = [pinnedChats() mutableCopy];
    BOOL alreadyPinned = NO;
    for (id existing in next) {
        if (existing == chat || [safeValue(existing, @"guid") isEqual:safeValue(chat, @"guid")]) {
            alreadyPinned = YES;
            break;
        }
    }
    if (pinned == alreadyPinned) return YES;

    if (pinned) {
        SEL maxSel = NSSelectorFromString(@"maximumNumberOfPinnedConversations");
        if ([controllerClass respondsToSelector:maxSel]) {
            NSUInteger limit = ((NSUInteger (*)(id, SEL))objc_msgSend)(controllerClass, maxSel);
            if (limit && next.count >= limit) {
                if (errCode) *errCode = @"bad_request";
                if (errMessage) *errMessage = [NSString stringWithFormat:
                    @"already at the limit of %lu pinned conversations",
                    (unsigned long)limit];
                return NO;
            }
        }
        [next addObject:chat];
    } else {
        NSMutableArray *remaining = [NSMutableArray array];
        for (id existing in next) {
            if (existing == chat || [safeValue(existing, @"guid") isEqual:safeValue(chat, @"guid")]) {
                continue;
            }
            [remaining addObject:existing];
        }
        next = remaining;
    }

    @try {
        // The update reason is an object; 0 is the ordinary user-initiated
        // change the UI itself passes.
        ((void (*)(id, SEL, id, id))objc_msgSend)(controller, setSel, next, @0);
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"setPinnedChats: threw: %@", e.reason);
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = e.reason ?: @"could not update pinned conversations";
        return NO;
    }
}

/// Sets or clears a group conversation's photo.
///
/// The photo is an ordinary file transfer, but through its own factory rather
/// than the attachment one — a group photo is not a message and never appears
/// in the transcript. Passing no path clears the photo back to the default.
BOOL IMBSetGroupPhoto(id chat, NSString *path, NSString **errCode, NSString **errMessage) {
    SEL sendSel = NSSelectorFromString(@"sendGroupPhotoUpdate:");
    if (![chat respondsToSelector:sendSel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"sendGroupPhotoUpdate: is unavailable on this build";
        return NO;
    }

    if (!path.length) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(chat, sendSel, nil);
            return YES;
        } @catch (NSException *e) {
            IMBLog(@"clearing group photo threw: %@", e.reason);
            if (errCode) *errCode = @"internal";
            if (errMessage) *errMessage = e.reason ?: @"could not clear the group photo";
            return NO;
        }
    }

    NSString *expanded = path.stringByExpandingTildeInPath;
    if (![NSFileManager.defaultManager fileExistsAtPath:expanded]) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = [NSString stringWithFormat:@"no file at '%@'", path];
        return NO;
    }

    Class centerClass = NSClassFromString(@"IMFileTransferCenter");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL createSel = NSSelectorFromString(@"createNewOutgoingGroupPhotoTransferWithLocalFileURL:");
    if (!centerClass || ![centerClass respondsToSelector:shared]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"IMFileTransferCenter unavailable";
        return NO;
    }
    id center = ((id (*)(id, SEL))objc_msgSend)(centerClass, shared);
    if (![center respondsToSelector:createSel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"no group-photo transfer factory on this build";
        return NO;
    }

    @try {
        id transfer = ((id (*)(id, SEL, id))objc_msgSend)(
            center, createSel, [NSURL fileURLWithPath:expanded]);
        NSString *guid = safeValue(transfer, @"guid");
        if (!guid.length) {
            if (errCode) *errCode = @"internal";
            if (errMessage) *errMessage = @"the group-photo transfer was not created";
            return NO;
        }
        if (!IMBRegisterTransfer(guid)) {
            if (errCode) *errCode = @"internal";
            if (errMessage) *errMessage = @"could not hand the photo to the transfer daemon";
            return NO;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(chat, sendSel, guid);
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"group photo update threw: %@", e.reason);
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = e.reason ?: @"could not set the group photo";
        return NO;
    }
}
