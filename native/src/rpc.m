// JSON-RPC method dispatch.
//
// Every operation is guarded twice: the selector must exist on this macOS
// build, and the call itself is wrapped so an IMCore exception becomes an RPC
// error instead of taking Messages.app down with it.
#import "bridge.h"
#import <objc/message.h>
#include <pthread.h>
#include <unistd.h>

extern NSArray *IMBChatHistory(id chat, NSUInteger limit);
extern void IMBRequestHistoryLoad(id chat, NSUInteger limit);
extern BOOL IMBDownloadAttachments(id chat);
extern void IMBAssignTransfersToMessage(NSArray<NSString *> *guids, id message);
extern void IMBSendAttachmentsForMessage(id chat, id message);

static const NSTimeInterval kMainHopTimeout = 5.0;

static void fail(NSString **code, NSString **message, NSString *c, NSString *m) {
    if (code) *code = c;
    if (message) *message = m;
}

/// Guards a feature behind its live capability probe.
static BOOL requireCapability(NSString *feature, NSString **code, NSString **message) {
    if ([IMBCapabilities()[feature] boolValue]) return YES;
    fail(code, message, @"unsupported_feature",
         [NSString stringWithFormat:@"%@ is not available on this macOS build", feature]);
    return NO;
}

// ---------------------------------------------------------------------------
// Methods
// ---------------------------------------------------------------------------

static id method_status(NSDictionary *params, NSString **code, NSString **message) {
    (void)params; (void)code; (void)message;
    return @{
        @"ready": @(IMBIsIMCoreReady()),
        @"pid": @(getpid()),
        @"protocol": @1,
        @"capabilities": IMBCapabilities(),
        // Enumerated from IMCore rather than listed here, so a caller sees the
        // names this build actually accepts.
        @"textEffects": IMBIsIMCoreReady() ? IMBTextEffectNames() : @[],
    };
}

static id method_listChats(NSDictionary *params, NSString **code, NSString **message) {
    NSNumber *limit = params[@"limit"];
    BOOL timedOut = NO;
    id result = IMBRunOnMain(^id {
        Class cls = NSClassFromString(@"IMChatRegistry");
        SEL shared = NSSelectorFromString(@"sharedInstance");
        if (![cls respondsToSelector:shared]) return nil;
        id reg = ((id (*)(id, SEL))objc_msgSend)(cls, shared);

        NSArray *all = nil;
        @try { all = [reg valueForKey:@"allExistingChats"]; }
        @catch (__unused NSException *e) { return nil; }

        NSMutableArray *out = [NSMutableArray array];
        NSUInteger max = limit ? limit.unsignedIntegerValue : NSUIntegerMax;
        for (id chat in all) {
            if (out.count >= max) break;
            [out addObject:IMBSerializeChat(chat)];
        }
        return out;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (!result)  { fail(code, message, @"internal", @"could not enumerate chats"); return nil; }
    return @{ @"chats": result };
}

static id method_resolveChat(NSDictionary *params, NSString **code, NSString **message) {
    NSString *chatId = params[@"chat"];
    if (![chatId isKindOfClass:[NSString class]] || chatId.length == 0) {
        fail(code, message, @"bad_request", @"missing 'chat'");
        return nil;
    }
    BOOL timedOut = NO;
    id result = IMBRunOnMain(^id {
        id chat = IMBLookupChat(chatId);
        return chat ? IMBSerializeChat(chat) : nil;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (!result)  { fail(code, message, @"chat_not_found",
                        [NSString stringWithFormat:@"no chat matching '%@'", chatId]); return nil; }
    return result;
}

/// Serialises a list of chats under `chats`, on the main thread.
static id serializeChats(NSArray *(^lookup)(void), NSString **code, NSString **message) {
    BOOL timedOut = NO;
    id result = IMBRunOnMain(^id {
        NSMutableArray *out = [NSMutableArray array];
        for (id chat in lookup()) [out addObject:IMBSerializeChat(chat)];
        return @{ @"chats": out };
    }, kMainHopTimeout, &timedOut);
    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    return result;
}

/// Every conversation an identifier resolves to, rather than the first.
static id method_resolveChats(NSDictionary *params, NSString **code, NSString **message) {
    NSString *chatId = params[@"chat"];
    if (![chatId isKindOfClass:[NSString class]] || chatId.length == 0) {
        fail(code, message, @"bad_request", @"missing 'chat'");
        return nil;
    }
    // No chat_not_found here: an empty list is a real answer to "which
    // conversations is this", and a caller checking reachability wants it back
    // rather than an error to catch.
    return serializeChats(^NSArray *{ return IMBLookupChats(chatId); }, code, message);
}

/// Every conversation a handle appears in, groups included.
static id method_chatsWith(NSDictionary *params, NSString **code, NSString **message) {
    NSString *handle = params[@"handle"];
    if (![handle isKindOfClass:[NSString class]] || handle.length == 0) {
        fail(code, message, @"bad_request", @"missing 'handle'");
        return nil;
    }
    return serializeChats(^NSArray *{ return IMBChatsWithHandle(handle); }, code, message);
}

/// Conversations this bridge has turned the typing indicator on for and not
/// yet turned off.
///
/// The indicator is a flag with no expiry, so it outlives whoever set it: a
/// caller that crashes mid-turn leaves the dots showing in a real conversation
/// with nobody left to clear them, and the person on the other end waits for a
/// message that is never coming. Tracking them here lets the disconnect clean
/// up — see IMBClearTypingIndicators, called when the host hangs up.
static NSMutableSet *gTypingChats = nil;
static pthread_mutex_t gTypingLock = PTHREAD_MUTEX_INITIALIZER;

static void rememberTyping(NSString *chatGuid, BOOL typing) {
    if (!chatGuid.length) return;
    pthread_mutex_lock(&gTypingLock);
    if (!gTypingChats) gTypingChats = [NSMutableSet set];
    if (typing) [gTypingChats addObject:chatGuid];
    else        [gTypingChats removeObject:chatGuid];
    pthread_mutex_unlock(&gTypingLock);
}

/// Turns the typing indicator off wherever this bridge left it on.
///
/// Called when the host disconnects, for any reason — a clean close, a crash,
/// a killed process. Clearing an indicator that has already gone is harmless,
/// so this does not try to work out which are still showing.
void IMBClearTypingIndicators(void) {
    pthread_mutex_lock(&gTypingLock);
    NSArray *chats = [gTypingChats allObjects] ?: @[];
    [gTypingChats removeAllObjects];
    pthread_mutex_unlock(&gTypingLock);
    if (!chats.count) return;

    IMBLog(@"clearing %lu typing indicator(s) after disconnect", (unsigned long)chats.count);
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        SEL sel = NSSelectorFromString(@"setLocalUserIsTyping:");
        for (NSString *guid in chats) {
            id chat = IMBLookupChat(guid);
            if (!chat || ![chat respondsToSelector:sel]) continue;
            @try {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(chat, sel, NO);
            } @catch (NSException *e) {
                IMBLog(@"clearing typing on %@ threw: %@", guid, e.reason);
            }
        }
        return @YES;
    }, kMainHopTimeout, &timedOut);
    if (timedOut) IMBLog(@"clearing typing indicators timed out");
}

static id method_setTyping(NSDictionary *params, NSString **code, NSString **message) {
    if (!requireCapability(@"typing", code, message)) return nil;

    NSString *chatId = params[@"chat"];
    if (![chatId isKindOfClass:[NSString class]] || chatId.length == 0) {
        fail(code, message, @"bad_request", @"missing 'chat'");
        return nil;
    }
    BOOL typing = [params[@"typing"] boolValue];

    __block BOOL found = NO;
    // The chat's own GUID, not what the caller addressed it by: a handle or a
    // display name would not resolve the same way at disconnect if the
    // conversation had moved on.
    __block NSString *resolvedGuid = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = IMBLookupChat(chatId);
        if (!chat) return nil;
        // Same invariant as lookupOrFail: never act on a conversation that is
        // not the one addressed. A poisoned resolution used to turn the
        // typing bubble on in the note-to-self thread and report success.
        if (IMBChatMatchesSpec(chatId, chat) != nil) return nil;
        found = YES;
        SEL sel = NSSelectorFromString(@"setLocalUserIsTyping:");
        if ([chat respondsToSelector:sel]) {
            @try {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(chat, sel, typing);
                id guid = [chat valueForKey:@"guid"];
                if ([guid isKindOfClass:[NSString class]]) resolvedGuid = guid;
            } @catch (NSException *e) {
                IMBLog(@"setTyping threw: %@", e.reason);
            }
        }
        return @YES;
    }, kMainHopTimeout, &timedOut);

    rememberTyping(resolvedGuid, typing);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (!found) {
        fail(code, message, @"chat_not_found",
             [NSString stringWithFormat:@"no chat matching '%@'", chatId]);
        return nil;
    }
    return @{ @"typing": @(typing) };
}

/// Recent messages for one chat, with identity, attachments and transcripts.
static id method_getHistory(NSDictionary *params, NSString **code, NSString **message) {
    NSString *chatId = params[@"chat"];
    if (![chatId isKindOfClass:[NSString class]] || chatId.length == 0) {
        fail(code, message, @"bad_request", @"missing 'chat'");
        return nil;
    }
    NSNumber *limitNum = params[@"limit"];
    NSUInteger limit = limitNum ? limitNum.unsignedIntegerValue : 50;
    if (limit == 0 || limit > 500) limit = 50;

    // Two phases: ask IMCore to page history in, let it settle, then read.
    // A single pass returns only whatever the UI happened to have loaded.
    __block BOOL found = NO;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = IMBLookupChat(chatId);
        if (!chat) return nil;
        found = YES;
        IMBRequestHistoryLoad(chat, limit);
        return @YES;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (!found) {
        fail(code, message, @"chat_not_found",
             [NSString stringWithFormat:@"no chat matching '%@'", chatId]);
        return nil;
    }
    usleep(1200000);   // let the asynchronous page-in land

    id result = IMBRunOnMain(^id {
        id chat = IMBLookupChat(chatId);
        if (!chat) return nil;
        return @{ @"chat": IMBSerializeChat(chat),
                  @"messages": IMBChatHistory(chat, limit) };
    }, 15.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (!found) {
        fail(code, message, @"chat_not_found",
             [NSString stringWithFormat:@"no chat matching '%@'", chatId]);
        return nil;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Write operations
// ---------------------------------------------------------------------------

/// Resolves the chat named by `params[@"chat"]`, reporting the standard errors.
/// Must be called on the main thread.
static id lookupOrFail(NSDictionary *params, NSString **code, NSString **message) {
    NSString *chatId = params[@"chat"];
    if (![chatId isKindOfClass:[NSString class]] || chatId.length == 0) {
        fail(code, message, @"bad_request", @"missing 'chat'");
        return nil;
    }
    id chat = IMBLookupChat(chatId);
    if (!chat) {
        fail(code, message, @"chat_not_found",
             [NSString stringWithFormat:@"no chat matching '%@'", chatId]);
        return nil;
    }
    // The invariant behind every write op: the conversation we resolved must
    // actually be with the address the caller named. A poisoned registry
    // object — relabelled with our own identity, or resolved onto someone
    // else's thread entirely — refuses here instead of acting on the wrong
    // conversation and reporting success.
    NSString *mismatch = IMBChatMatchesSpec(chatId, chat);
    if (mismatch) {
        fail(code, message, @"chat_mismatch", mismatch);
        return nil;
    }
    return chat;
}

/// Sends already made under a caller's idempotency key: key → the result that
/// was returned, and when.
///
/// A send that reaches Messages and then loses its reply — a timeout, a dropped
/// socket, a client that died between the two — leaves the caller unable to
/// tell whether the message went out. Retrying sends it twice; not retrying
/// drops it. Neither is recoverable afterwards, because there is nothing in the
/// store tying an attempt to the caller's intent.
///
/// A key the caller chooses fixes that: the same key inside the window returns
/// the original GUID and sends nothing. Held in memory deliberately — the
/// window that matters is one retry cycle, and a key surviving a restart of
/// Messages would suppress a send someone deliberately repeated hours later.
static const NSTimeInterval kIdempotencyWindow = 10 * 60;
static const NSUInteger kIdempotencyCapacity = 512;

static NSMutableDictionary *gSendKeys = nil;
static NSMutableArray *gSendKeyOrder = nil;
static pthread_mutex_t gSendKeyLock = PTHREAD_MUTEX_INITIALIZER;

/// The result recorded for a key, or nil if there is none worth reusing.
static NSDictionary *recalledSend(NSString *key) {
    if (!key.length) return nil;
    pthread_mutex_lock(&gSendKeyLock);
    NSDictionary *entry = gSendKeys[key];
    NSDate *at = entry[@"at"];
    if (entry && [[NSDate date] timeIntervalSinceDate:at] > kIdempotencyWindow) {
        [gSendKeys removeObjectForKey:key];
        [gSendKeyOrder removeObject:key];
        entry = nil;
    }
    NSDictionary *result = entry[@"result"];
    pthread_mutex_unlock(&gSendKeyLock);
    return result;
}

static void rememberSend(NSString *key, NSDictionary *result) {
    if (!key.length || !result) return;
    pthread_mutex_lock(&gSendKeyLock);
    if (!gSendKeys) {
        gSendKeys = [NSMutableDictionary dictionary];
        gSendKeyOrder = [NSMutableArray array];
    }
    if (!gSendKeys[key]) [gSendKeyOrder addObject:key];
    gSendKeys[key] = @{ @"result": result, @"at": [NSDate date] };
    // Oldest out first. The cap is a memory bound, not a policy: a caller
    // sending more than this inside the window has already moved past any
    // retry the evicted keys could have covered.
    while (gSendKeyOrder.count > kIdempotencyCapacity) {
        [gSendKeys removeObjectForKey:gSendKeyOrder.firstObject];
        [gSendKeyOrder removeObjectAtIndex:0];
    }
    pthread_mutex_unlock(&gSendKeyLock);
}

static id method_send(NSDictionary *params, NSString **code, NSString **message) {
    if (!requireCapability(@"send", code, message)) return nil;

    NSString *idempotencyKey = [params[@"idempotencyKey"] isKindOfClass:[NSString class]]
        ? params[@"idempotencyKey"] : nil;
    NSDictionary *already = recalledSend(idempotencyKey);
    if (already) {
        // Marked rather than returned bare, so a caller can tell a retry that
        // was absorbed from one that went out.
        NSMutableDictionary *repeat = [already mutableCopy];
        repeat[@"duplicate"] = @YES;
        return repeat;
    }

    NSString *text = params[@"text"];
    NSArray *files = [params[@"files"] isKindOfClass:[NSArray class]] ? params[@"files"] : nil;
    NSArray *attachments = [params[@"attachments"] isKindOfClass:[NSArray class]]
                         ? params[@"attachments"] : nil;
    if (![text isKindOfClass:[NSString class]] && !attachments && !files.count) {
        fail(code, message, @"bad_request", @"need 'text', 'files' or 'attachments'");
        return nil;
    }

    // `sticker` turns the accompanying files into stickers rather than
    // ordinary attachments. It is only meaningful alongside files.
    NSDictionary *sticker = [params[@"sticker"] isKindOfClass:[NSDictionary class]]
                          ? params[@"sticker"]
                          : ([params[@"sticker"] boolValue] ? @{} : nil);
    if (sticker && !files.count) {
        fail(code, message, @"bad_request", @"'sticker' needs 'files'");
        return nil;
    }

    // A sticker can be stuck onto an existing bubble rather than sent on its
    // own, which is what peel-and-stick does in the app.
    NSString *stickTo = [sticker[@"attachTo"] isKindOfClass:[NSString class]]
        ? sticker[@"attachTo"] : nil;
    if (stickTo && !requireCapability(@"stickerAttach", code, message)) return nil;
    if (stickTo && [text isKindOfClass:[NSString class]] && [text length]) {
        // A stuck sticker has no body of its own — the placeholder run is the
        // whole message — so text would be silently dropped.
        fail(code, message, @"bad_request",
             @"a sticker stuck to a message carries no text of its own");
        return nil;
    }

    NSString *subject = [params[@"subject"] isKindOfClass:[NSString class]] ? params[@"subject"] : nil;
    NSString *effect  = [params[@"effect"] isKindOfClass:[NSString class]] ? params[@"effect"] : nil;

    // Which service carries this one message. Checked against the two names
    // IMCore knows rather than passed through, since anything else would fall
    // back to the conversation's own service and read as though it had been
    // honoured.
    NSString *service = [params[@"service"] isKindOfClass:[NSString class]] ? params[@"service"] : nil;
    if (service.length) {
        if ([service caseInsensitiveCompare:@"iMessage"] == NSOrderedSame)  service = @"iMessage";
        else if ([service caseInsensitiveCompare:@"SMS"] == NSOrderedSame)  service = @"SMS";
        else {
            fail(code, message, @"bad_request",
                 [NSString stringWithFormat:@"unknown service '%@' — expected iMessage or SMS",
                  service]);
            return nil;
        }
        if (!requireCapability(@"sendService", code, message)) return nil;
    }
    NSString *replyTo = [params[@"replyTo"] isKindOfClass:[NSString class]] ? params[@"replyTo"] : nil;

    __block NSString *innerCode = nil, *innerMessage = nil;
    __block NSString *guid = nil, *sentOn = nil, *routedTo = nil;
    __block NSDictionary *dryRunResult = nil;
    BOOL timedOut = NO;

    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;

        // Local files become transfers here, but are not handed to the daemon
        // until the message is built — a build that fails then leaves nothing
        // half-uploaded.
        NSMutableArray *transfers = [NSMutableArray array];
        for (id file in files) {
            if (![file isKindOfClass:[NSString class]]) {
                innerCode = @"bad_request";
                innerMessage = @"'files' must be an array of paths";
                return nil;
            }
            NSDictionary *prepared = IMBPrepareTransfer(file, sticker, &innerCode, &innerMessage);
            if (!prepared) return nil;
            [transfers addObject:prepared];
        }
        [transfers addObjectsFromArray:attachments ?: @[]];

        // Sticking it to a bubble is a different message shape entirely: an
        // associated message pointing at a part, not a message with a picture
        // in it. It shares the transfer preparation above and nothing after.
        if (stickTo) {
            id item = IMBFindChatItem(chat, stickTo);
            if (!item) {
                innerCode = @"message_not_found";
                innerMessage = [NSString stringWithFormat:
                    @"no message '%@' in this conversation to stick to", stickTo];
                return nil;
            }
            NSMutableArray *transferGUIDs = [NSMutableArray array];
            for (NSDictionary *transfer in transfers) {
                if (![transfer isKindOfClass:[NSDictionary class]]) continue;
                if (!IMBRegisterTransfer(transfer[@"guid"])) {
                    innerCode = @"internal";
                    innerMessage = [NSString stringWithFormat:
                        @"could not hand '%@' to the transfer daemon", transfer[@"filename"]];
                    return nil;
                }
                if (transfer[@"guid"]) [transferGUIDs addObject:transfer[@"guid"]];
            }
            guid = IMBSendStuckSticker(chat, item, transferGUIDs, &innerCode, &innerMessage);
            if (!guid) return nil;
            return @YES;
        }

        // Replying threads off the target message's identifier.
        NSString *threadIdentifier = nil;
        if (replyTo) {
            id item = IMBFindChatItem(chat, replyTo);
            id target = IMBUnderlyingMessage(item) ?: item;
            // Continue an existing thread if the target is already in one;
            // otherwise start a thread rooted at the target.
            //
            // The identifier is "r:<part>:<part>:<textLength>:<originatorGUID>",
            // read off real threaded replies. The message store records the
            // middle portion separately as thread_originator_part.
            threadIdentifier = [target valueForKey:@"threadIdentifier"];
            if (![threadIdentifier isKindOfClass:[NSString class]] || !threadIdentifier.length) {
                NSString *targetGUID = [target valueForKey:@"guid"] ?: replyTo;
                id body = [target valueForKey:@"text"];
                NSUInteger length = [body respondsToSelector:@selector(length)] ? [body length] : 0;
                threadIdentifier = [NSString stringWithFormat:@"r:0:0:%lu:%@",
                                    (unsigned long)length, targetGUID];
            }
        }

        NSArray *formatting = [params[@"formatting"] isKindOfClass:[NSArray class]]
            ? params[@"formatting"] : nil;
        id built = IMBBuildMessage(text, subject, transfers, effect,
                                   threadIdentifier, formatting, &innerCode, &innerMessage);
        if (!built) return nil;

        // A dry run builds the message and reports its shape without sending,
        // which is the only safe way to check attachment wiring against a real
        // conversation.
        if ([params[@"dryRun"] boolValue]) {
            id body = [built valueForKey:@"text"];
            NSMutableArray *parts = [NSMutableArray array];
            if ([body isKindOfClass:[NSAttributedString class]]) {
                NSAttributedString *as = body;
                [as enumerateAttributesInRange:NSMakeRange(0, as.length) options:0
                                    usingBlock:^(NSDictionary *attrs, NSRange r, BOOL *stop) {
                    [parts addObject:@{
                        @"range": @[@(r.location), @(r.length)],
                        @"text": [as.string substringWithRange:r],
                        @"part": attrs[@"__kIMMessagePartAttributeName"] ?: [NSNull null],
                        @"transferGUID": attrs[@"__kIMFileTransferGUIDAttributeName"] ?: [NSNull null],
                    }];
                }];
            }
            dryRunResult = @{
                @"dryRun": @YES,
                @"guid": [built valueForKey:@"guid"] ?: @"",
                @"transfers": transfers,
                @"bodyParts": parts,
            };
            return @YES;
        }

        // Registration starts the upload, so it happens last — and before the
        // send, because the daemon has to know about the transfer by the time
        // the message referencing it arrives.
        for (NSDictionary *transfer in transfers) {
            if (![transfer isKindOfClass:[NSDictionary class]]) continue;
            if (!IMBRegisterTransfer(transfer[@"guid"])) {
                innerCode = @"internal";
                innerMessage = [NSString stringWithFormat:
                    @"could not hand '%@' to the transfer daemon", transfer[@"filename"]];
                return nil;
            }
        }

        guid = IMBSendMessage(chat, built, service, &innerCode, &innerMessage);
        if (guid) {
            // Which service actually carried it. A forced one is the service
            // asked for; otherwise it is the conversation's own, which is
            // worth reporting because nothing else tells a caller whether a
            // message went out as an iMessage or as a text.
            if (service.length) {
                sentOn = service;
            } else {
                id name = [[chat valueForKey:@"account"] valueForKey:@"serviceName"];
                sentOn = [name isKindOfClass:[NSString class]] ? name : nil;
            }
            // Where IMCore says this conversation routes, captured per send so
            // a misdelivery investigation has the value from the moment it
            // mattered rather than a later reconstruction.
            routedTo = IMBChatRecipientID(chat);
        }
        return guid ? @YES : nil;
    }, 30.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    if (dryRunResult) return dryRunResult;

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"guid"] = guid ?: @"";
    if (sentOn) result[@"service"] = sentOn;
    if (routedTo) result[@"recipient"] = routedTo;
    // Recorded after the send, not before: a key claimed up front would
    // suppress the retry of a send that never happened.
    rememberSend(idempotencyKey, result);
    return result;
}

/// Creates a poll in a conversation.
static id method_sendPoll(NSDictionary *params, NSString **code, NSString **message) {
    if (!requireCapability(@"poll", code, message)) return nil;

    NSArray *options = params[@"options"];
    if (![options isKindOfClass:[NSArray class]] || options.count < 2) {
        fail(code, message, @"bad_request", @"a poll needs at least two options");
        return nil;
    }
    if (options.count > 12) {
        fail(code, message, @"bad_request", @"a poll takes at most twelve options");
        return nil;
    }
    NSString *question = [params[@"question"] isKindOfClass:[NSString class]]
        ? params[@"question"] : @"";

    __block NSString *innerCode = nil, *innerMessage = nil;
    __block NSString *guid = nil;
    BOOL timedOut = NO;

    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;

        // The poll records who created it, and each option who added it. That
        // is this account's own handle, which the chat knows.
        NSString *creator = [chat valueForKey:@"lastAddressedHandleID"];
        if (![creator isKindOfClass:[NSString class]]) creator = nil;

        NSData *payload = IMBBuildPollPayload(question, options, creator);
        if (!payload) {
            innerCode = @"internal";
            innerMessage = @"could not build the poll payload";
            return nil;
        }
        guid = IMBSendPluginMessage(chat, IMBPollBundleID, payload, @"Sent a poll",
                                    &innerCode, &innerMessage);
        return guid ? @YES : nil;
    }, 15.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"guid": guid ?: @"", @"options": @(options.count) };
}

/// Votes in an existing poll.
///
/// The caller names the option however it is convenient — its text, its
/// position, or its identifier — because everything a vote actually needs (the
/// poll's session identifier, the option's minted UUID) is buried in the poll's
/// payload and is not something a reader should have to dig out.
static id method_votePoll(NSDictionary *params, NSString **code, NSString **message) {
    if (!requireCapability(@"poll", code, message)) return nil;

    NSString *pollGUID = params[@"poll"];
    if (![pollGUID isKindOfClass:[NSString class]] || pollGUID.length == 0) {
        fail(code, message, @"bad_request", @"missing 'poll'");
        return nil;
    }
    id choice = params[@"option"];
    if (!choice) {
        fail(code, message, @"bad_request", @"missing 'option'");
        return nil;
    }

    NSDictionary *stored = IMBStoreMessage(pollGUID, code, message);
    if (!stored) return nil;
    NSDictionary *poll = stored[@"poll"];
    NSArray *options = poll[@"options"];
    if (![options isKindOfClass:[NSArray class]] || !options.count) {
        fail(code, message, @"bad_request", @"that message is not a poll");
        return nil;
    }
    NSString *sessionID = poll[@"sessionId"];
    if (![sessionID isKindOfClass:[NSString class]] || !sessionID.length) {
        // Older polls, or ones from a plugin version that shaped the payload
        // differently. Without the session there is nothing to vote into.
        fail(code, message, @"unsupported_feature",
             @"this poll carries no session identifier to vote into");
        return nil;
    }

    // Position, identifier, or the option's own text — in that order, so a
    // numeric string is never mistaken for the text of an option.
    NSDictionary *chosen = nil;
    if ([choice isKindOfClass:[NSNumber class]]) {
        NSInteger index = [choice integerValue];
        if (index < 0 || index >= (NSInteger)options.count) {
            fail(code, message, @"bad_request",
                 [NSString stringWithFormat:@"this poll has %lu options",
                  (unsigned long)options.count]);
            return nil;
        }
        chosen = options[(NSUInteger)index];
    } else if ([choice isKindOfClass:[NSString class]]) {
        for (NSDictionary *option in options) {
            if ([option[@"id"] isEqual:choice]) { chosen = option; break; }
        }
        for (NSDictionary *option in options) {
            if (chosen) break;
            if ([option[@"text"] isKindOfClass:[NSString class]] &&
                [option[@"text"] caseInsensitiveCompare:choice] == NSOrderedSame) {
                chosen = option;
            }
        }
    }
    if (!chosen) {
        fail(code, message, @"bad_request", @"no option in this poll matches 'option'");
        return nil;
    }

    __block NSString *innerCode = nil, *innerMessage = nil;
    __block NSString *guid = nil;
    BOOL timedOut = NO;

    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;

        // The poll has to be in the chat's loaded window before the vote is
        // built. IMCore routes an associated message by resolving the message
        // it points at, and when it cannot find it the vote is filed under this
        // account's own conversation instead — delivered, stored, and counted
        // nowhere. It reports no error either way.
        IMBReloadAround(chat, pollGUID);

        // A vote records who cast it; the tally is by participant.
        NSString *handle = [chat valueForKey:@"lastAddressedHandleID"];
        if (![handle isKindOfClass:[NSString class]]) handle = nil;

        NSData *payload = IMBBuildVotePayload(sessionID, handle, chosen[@"id"]);
        if (!payload) {
            innerCode = @"internal";
            innerMessage = @"could not build the vote payload";
            return nil;
        }
        guid = IMBSendPollVote(chat, pollGUID, payload, &innerCode, &innerMessage);
        return guid ? @YES : nil;
    }, 15.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{
        @"guid": guid ?: @"",
        @"optionId": chosen[@"id"] ?: @"",
        @"optionText": chosen[@"text"] ?: @"",
    };
}

/// Schedules a message for later delivery.
static id method_sendLater(NSDictionary *params, NSString **code, NSString **message) {
    if (!requireCapability(@"sendLater", code, message)) return nil;

    NSString *text = params[@"text"];
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        fail(code, message, @"bad_request", @"missing 'text'");
        return nil;
    }
    id at = params[@"at"];
    if (![at isKindOfClass:[NSNumber class]]) {
        fail(code, message, @"bad_request", @"missing 'at' (Unix seconds)");
        return nil;
    }
    NSDate *deliverAt = [NSDate dateWithTimeIntervalSince1970:[at doubleValue]];
    if ([deliverAt timeIntervalSinceNow] < 60) {
        fail(code, message, @"bad_request", @"'at' must be at least a minute from now");
        return nil;
    }

    __block NSString *innerCode = nil, *innerMessage = nil;
    __block NSString *guid = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        guid = IMBSendLater(chat, text, deliverAt, &innerCode, &innerMessage);
        return guid ? @YES : nil;
    }, 15.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }

    // Scheduling is not reliably honoured: when a send goes out immediately
    // before this one, IMCore has been observed delivering the message at once
    // — carrying the future timestamp, so it reads as scheduled — and has also
    // been observed filing it under this account's own conversation instead of
    // the intended one. Neither reports an error. So the result is read back
    // from the store rather than assumed, and the caller is told which it got.
    usleep(1500000);
    NSDictionary *stored = IMBStoreMessage(guid, NULL, NULL);
    BOOL scheduled = [stored[@"schedule_type"] longLongValue] != 0
                  && ![stored[@"is_delivered"] boolValue];

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"guid"] = guid ?: @"";
    result[@"at"] = at;
    result[@"scheduled"] = @(scheduled);
    if (stored[@"chatGuid"]) result[@"chatGuid"] = stored[@"chatGuid"];
    if (!scheduled) {
        result[@"warning"] = @"Messages did not hold this message: it was sent immediately.";
    }
    return result;
}

static id method_tapback(NSDictionary *params, NSString **code, NSString **message) {
    if (!requireCapability(@"tapback", code, message)) return nil;

    NSString *target = params[@"message"];
    if (![target isKindOfClass:[NSString class]] || target.length == 0) {
        fail(code, message, @"bad_request", @"missing 'message'");
        return nil;
    }
    NSString *kind = params[@"kind"] ?: @"love";
    BOOL ok = NO;
    long long type = IMBTapbackType(kind, [params[@"remove"] boolValue], &ok);
    if (!ok) {
        fail(code, message, @"bad_request",
             @"kind must be love, like, dislike, laugh, emphasize, question or emoji");
        return nil;
    }

    // The character belongs to the "emoji" kind alone: the others are named
    // entirely by their type code, and quietly ignoring a stray emoji would
    // send a reaction the caller did not ask for.
    NSString *emoji = [params[@"emoji"] isKindOfClass:[NSString class]] &&
                      [params[@"emoji"] length] ? params[@"emoji"] : nil;
    BOOL isEmojiKind = (type == 2006 || type == 3006);
    if (isEmojiKind && !emoji) {
        fail(code, message, @"bad_request", @"kind 'emoji' needs an 'emoji' character");
        return nil;
    }
    if (!isEmojiKind && emoji) {
        fail(code, message, @"bad_request", @"'emoji' is only valid with kind 'emoji'");
        return nil;
    }

    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        id item = IMBFindChatItem(chat, target);
        if (!item) {
            innerCode = @"message_not_found";
            innerMessage = [NSString stringWithFormat:@"no loaded message '%@'", target];
            return nil;
        }
        return IMBSendTapback(chat, item, type, emoji, &innerCode, &innerMessage) ? @YES : nil;
    }, 15.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"kind"] = kind;
    result[@"removed"] = @([params[@"remove"] boolValue]);
    if (emoji) result[@"emoji"] = emoji;
    return result;
}

/// Shared shape for retract and edit, which both act on a loaded chat item.
static id itemOperation(NSDictionary *params, NSString *capability,
                        BOOL (^perform)(id chat, id item, NSString **c, NSString **m),
                        NSString **code, NSString **message) {
    if (!requireCapability(capability, code, message)) return nil;

    NSString *target = params[@"message"];
    if (![target isKindOfClass:[NSString class]] || target.length == 0) {
        fail(code, message, @"bad_request", @"missing 'message'");
        return nil;
    }

    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        id item = IMBFindChatItem(chat, target);
        if (!item) {
            innerCode = @"message_not_found";
            innerMessage = [NSString stringWithFormat:@"no loaded message '%@'", target];
            return nil;
        }
        return perform(chat, item, &innerCode, &innerMessage) ? @YES : nil;
    }, 15.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"message": target };
}

static id method_retract(NSDictionary *params, NSString **code, NSString **message) {
    return itemOperation(params, @"retract", ^BOOL(id chat, id item, NSString **c, NSString **m) {
        return IMBRetract(chat, item, c, m);
    }, code, message);
}

/// Cancels a scheduled message before it goes out.
///
/// The message is always paged in again first, even when the window already
/// holds an item for it. Cancelling one scheduled moments earlier in the same
/// session otherwise operates on the item left over from sending, which reports
/// success and leaves the message scheduled — it still goes out. Re-reading it
/// yields the stored scheduled item, which cancels properly.
static id method_cancelScheduled(NSDictionary *params, NSString **code, NSString **message) {
    if (!requireCapability(@"sendLater", code, message)) return nil;

    NSString *target = params[@"message"];
    if (![target isKindOfClass:[NSString class]] || target.length == 0) {
        fail(code, message, @"bad_request", @"missing 'message'");
        return nil;
    }

    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;

        IMBReloadAround(chat, target);
        id item = IMBFindChatItem(chat, target);
        if (!item) {
            innerCode = @"message_not_found";
            innerMessage = [NSString stringWithFormat:@"no message '%@' to cancel", target];
            return nil;
        }
        return IMBCancelScheduled(chat, item, &innerCode, &innerMessage) ? @YES : nil;
    }, 15.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"message": target };
}

static id method_edit(NSDictionary *params, NSString **code, NSString **message) {
    NSString *newText = params[@"text"];
    if (![newText isKindOfClass:[NSString class]] || newText.length == 0) {
        fail(code, message, @"bad_request", @"missing 'text'");
        return nil;
    }
    long long partIndex = [params[@"partIndex"] longLongValue];
    return itemOperation(params, @"edit", ^BOOL(id chat, id item, NSString **c, NSString **m) {
        return IMBEdit(chat, item, partIndex, newText, c, m);
    }, code, message);
}

/// Asks Messages to fetch attachments that are not cached locally.
static id method_downloadAttachments(NSDictionary *params, NSString **code, NSString **message) {
    __block NSString *innerCode = nil, *innerMessage = nil;
    __block BOOL ok = NO;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        ok = IMBDownloadAttachments(chat);
        return @YES;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    if (!ok) { fail(code, message, @"unsupported_feature", @"attachment download unavailable"); return nil; }
    return @{ @"requested": @YES };
}

static id method_markRead(NSDictionary *params, NSString **code, NSString **message) {
    __block NSString *innerCode = nil, *innerMessage = nil;
    __block BOOL ok = NO;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        ok = IMBMarkRead(chat);
        return @YES;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    if (!ok) { fail(code, message, @"unsupported_feature", @"mark-as-read unavailable"); return nil; }
    return @{ @"marked": @YES };
}

/// The chat's membership and name, as they stand.
static NSDictionary *groupState(id chat) {
    NSMutableArray *members = [NSMutableArray array];
    NSMutableArray *people = [NSMutableArray array];
    for (id handle in [chat valueForKey:@"participants"] ?: @[]) {
        NSDictionary *info = IMBHandleInfo(handle);
        if ([info[@"id"] isKindOfClass:[NSString class]]) [members addObject:info[@"id"]];
        // A bare handle does not say who it is; the resolved person does.
        if (info) [people addObject:info];
    }
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"participants"] = members;
    if (people.count) state[@"people"] = people;
    id name = [chat valueForKey:@"displayName"];
    if ([name isKindOfClass:[NSString class]]) state[@"displayName"] = name;
    return state;
}

/// Group operations share validation; only the action differs.
///
/// Every one of these returns void, so "no exception" does not mean "it took
/// effect" — `removeParticipants:reason:` in particular reports success and
/// changes nothing when the group would drop below three people. The state is
/// therefore read back and returned, and `changed` says whether anything
/// actually moved. Do not treat the call returning as the answer.
static id groupOperation(NSDictionary *params, NSString *capability,
                         BOOL (^perform)(id chat, NSString **c, NSString **m),
                         NSString **code, NSString **message) {
    if (!requireCapability(capability, code, message)) return nil;

    __block NSString *innerCode = nil, *innerMessage = nil;
    __block NSDictionary *before = nil, *after = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        before = groupState(chat);
        return perform(chat, &innerCode, &innerMessage) ? @YES : nil;
    }, 15.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }

    // Let the change settle before reading it back. This waits on the worker
    // thread, never the main one: sleeping on main would freeze the app's UI
    // for the duration.
    usleep(1500000);
    IMBRunOnMain(^id {
        id chat = IMBLookupChat(params[@"chat"]);
        if (chat) after = groupState(chat);
        return @YES;
    }, kMainHopTimeout, &timedOut);

    NSMutableDictionary *result = [after mutableCopy] ?: [NSMutableDictionary dictionary];
    result[@"ok"] = @YES;
    // Cast to BOOL: C's ! yields int, which would box as a JSON number rather
    // than a boolean.
    result[@"changed"] = IMBBool(![after isEqualToDictionary:before ?: @{}]);
    return result;
}

static id method_groupRename(NSDictionary *params, NSString **code, NSString **message) {
    NSString *name = params[@"name"];
    if (![name isKindOfClass:[NSString class]]) {
        fail(code, message, @"bad_request", @"missing 'name'");
        return nil;
    }
    return groupOperation(params, @"groupRename", ^BOOL(id chat, NSString **c, NSString **m) {
        return IMBGroupRename(chat, name, c, m);
    }, code, message);
}

static id method_groupAdd(NSDictionary *params, NSString **code, NSString **message) {
    NSArray *members = params[@"members"];
    if (![members isKindOfClass:[NSArray class]] || members.count == 0) {
        fail(code, message, @"bad_request", @"missing 'members'");
        return nil;
    }
    return groupOperation(params, @"groupAdd", ^BOOL(id chat, NSString **c, NSString **m) {
        return IMBGroupAddMembers(chat, members, c, m);
    }, code, message);
}

static id method_groupRemove(NSDictionary *params, NSString **code, NSString **message) {
    NSArray *members = params[@"members"];
    if (![members isKindOfClass:[NSArray class]] || members.count == 0) {
        fail(code, message, @"bad_request", @"missing 'members'");
        return nil;
    }
    return groupOperation(params, @"groupRemove", ^BOOL(id chat, NSString **c, NSString **m) {
        return IMBGroupRemoveMembers(chat, members, c, m);
    }, code, message);
}

/// Whether a membership change would be acted on, without making it.
///
/// Read-only, so it is the one way to find out what IMCore will do here
/// without a real conversation changing to tell you.
static id method_groupCanChange(NSDictionary *params, BOOL adding,
                                NSString **code, NSString **message) {
    NSArray *members = params[@"members"];
    if (![members isKindOfClass:[NSArray class]] || members.count == 0) {
        fail(code, message, @"bad_request", @"missing 'members'");
        return nil;
    }
    __block NSString *innerCode = nil, *innerMessage = nil;
    __block BOOL allowed = NO;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        allowed = IMBGroupChangeAllowed(chat, adding, members, &innerCode, &innerMessage);
        return @YES;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    // A refusal is an answer; only a chat we could not find, or a build that
    // cannot say, is an error.
    if (innerCode && ![innerCode isEqualToString:@"internal"]) {
        if (!allowed && ([innerCode isEqualToString:@"chat_not_found"] ||
                         [innerCode isEqualToString:@"bad_request"] ||
                         [innerCode isEqualToString:@"unsupported_feature"])) {
            fail(code, message, innerCode, innerMessage);
            return nil;
        }
    }
    return @{ @"allowed": IMBBool(allowed) };
}

static id method_groupLeave(NSDictionary *params, NSString **code, NSString **message) {
    return groupOperation(params, @"groupLeave", ^BOOL(id chat, NSString **c, NSString **m) {
        return IMBGroupLeave(chat, c, m);
    }, code, message);
}

/// Search runs off the main thread. CoreSpotlight is asynchronous and answers
/// on its own queue, so hopping to the main thread would block Messages' UI
/// for the life of the query and gain nothing.
static id method_search(NSDictionary *params, NSString **code, NSString **message) {
    NSString *query = params[@"query"];
    NSString *chatGuid = [params[@"chatGuid"] isKindOfClass:[NSString class]]
        ? params[@"chatGuid"] : nil;
    NSArray *kinds = [params[@"kinds"] isKindOfClass:[NSArray class]] ? params[@"kinds"] : nil;
    NSUInteger limit = [params[@"limit"] isKindOfClass:[NSNumber class]]
        ? [params[@"limit"] unsignedIntegerValue] : 50;

    // A chat GUID may arrive as a handle or a display name; resolve it to the
    // real GUID, which is what the index keys results by.
    if (chatGuid) {
        BOOL timedOut = NO;
        NSString *resolved = IMBRunOnMain(^id {
            id chat = IMBLookupChat(chatGuid);
            return chat ? [chat valueForKey:@"guid"] : nil;
        }, kMainHopTimeout, &timedOut);
        if ([resolved isKindOfClass:[NSString class]]) chatGuid = resolved;
    }

    return IMBSearch(query, limit, chatGuid, kinds, code, message);
}

/// How many distinct handles one result will resolve to names. A conversation
/// has a handful; the cap only bounds a pathological page.
static const NSUInteger kMaxNamesPerResult = 64;

static void collectHandle(NSMutableSet *into, id value) {
    if ([value isKindOfClass:[NSString class]] && [value length]) [into addObject:value];
}

/// Resolves every handle in a result to the person behind it.
///
/// The store keeps handles and nothing else, so a page of deep history reads as
/// a list of phone numbers even for people in Contacts — where the same
/// conversation in the app shows names throughout. This resolves each distinct
/// handle once and writes the name alongside, leaving the handle in place so
/// nothing that keyed on it breaks.
static NSArray *withNames(NSArray *messages) {
    if (![messages isKindOfClass:[NSArray class]] || !messages.count) return messages;

    NSMutableSet *handles = [NSMutableSet set];
    for (NSDictionary *message in messages) {
        if (![message isKindOfClass:[NSDictionary class]]) continue;
        collectHandle(handles, message[@"sender"]);
        NSDictionary *event = message[@"event"];
        if ([event isKindOfClass:[NSDictionary class]]) {
            collectHandle(handles, event[@"actor"]);
            collectHandle(handles, event[@"participant"]);
        }
        for (NSString *key in @[@"tapbacks", @"stickers"]) {
            for (NSDictionary *entry in message[key] ?: @[]) {
                if ([entry isKindOfClass:[NSDictionary class]]) collectHandle(handles, entry[@"sender"]);
            }
        }
        if (handles.count >= kMaxNamesPerResult) break;
    }
    if (!handles.count) return messages;

    BOOL timedOut = NO;
    NSDictionary *names = IMBRunOnMain(^id {
        NSMutableDictionary *resolved = [NSMutableDictionary dictionary];
        for (NSString *handleID in handles) {
            NSDictionary *info = IMBHandleInfo(IMBLookupHandle(handleID));
            NSString *name = info[@"name"] ?: info[@"nickname"];
            if ([name isKindOfClass:[NSString class]] && name.length) resolved[handleID] = name;
        }
        return resolved;
    }, kMainHopTimeout, &timedOut);
    // A wedged main thread costs names, not the request.
    if (timedOut || ![names isKindOfClass:[NSDictionary class]] || !names.count) return messages;

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:messages.count];
    for (NSDictionary *message in messages) {
        if (![message isKindOfClass:[NSDictionary class]]) { [out addObject:message]; continue; }
        NSMutableDictionary *entry = [message mutableCopy];

        NSString *senderName = names[entry[@"sender"] ?: @""];
        if (senderName) entry[@"senderName"] = senderName;

        NSDictionary *event = entry[@"event"];
        if ([event isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *named = [event mutableCopy];
            if (names[event[@"actor"] ?: @""]) named[@"actorName"] = names[event[@"actor"]];
            if (names[event[@"participant"] ?: @""]) {
                named[@"participantName"] = names[event[@"participant"]];
            }
            entry[@"event"] = named;
        }

        for (NSString *key in @[@"tapbacks", @"stickers"]) {
            NSArray *list = entry[key];
            if (![list isKindOfClass:[NSArray class]] || !list.count) continue;
            NSMutableArray *namedList = [NSMutableArray arrayWithCapacity:list.count];
            for (NSDictionary *item in list) {
                if (![item isKindOfClass:[NSDictionary class]]) { [namedList addObject:item]; continue; }
                NSString *name = names[item[@"sender"] ?: @""];
                if (!name) { [namedList addObject:item]; continue; }
                NSMutableDictionary *namedItem = [item mutableCopy];
                namedItem[@"senderName"] = name;
                [namedList addObject:namedItem];
            }
            entry[key] = namedList;
        }
        [out addObject:entry];
    }
    return out;
}

/// Applies name resolution to a `{ messages: [...] }` result.
static id namedResult(NSDictionary *result) {
    if (![result isKindOfClass:[NSDictionary class]] || !result[@"messages"]) return result;
    NSMutableDictionary *out = [result mutableCopy];
    out[@"messages"] = withNames(result[@"messages"]);
    return out;
}

/// Deep history from the message store. Runs off the main thread: sqlite reads
/// are independent of IMCore and do not touch its main-thread-affine objects.
static id method_storeHistory(NSDictionary *params, NSString **code, NSString **message) {
    NSUInteger limit = [params[@"limit"] isKindOfClass:[NSNumber class]]
        ? [params[@"limit"] unsignedIntegerValue] : 200;
    long long before = [params[@"beforeRowID"] isKindOfClass:[NSNumber class]]
        ? [params[@"beforeRowID"] longLongValue] : 0;
    long long since = [params[@"sinceRowID"] isKindOfClass:[NSNumber class]]
        ? [params[@"sinceRowID"] longLongValue] : 0;

    // `chat` is optional: without it this reads across every conversation,
    // which is the only way to catch up on what arrived while nobody was
    // listening — a caller that was away does not know which chats to ask
    // about.
    NSString *chatId = params[@"chat"];
    NSString *resolved = nil;
    if ([chatId isKindOfClass:[NSString class]] && chatId.length) {
        // Resolve handle or display name to the store's chat GUID.
        BOOL timedOut = NO;
        resolved = IMBRunOnMain(^id {
            id chat = IMBLookupChat(chatId);
            return chat ? [chat valueForKey:@"guid"] : nil;
        }, kMainHopTimeout, &timedOut);
        if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
        if (![resolved isKindOfClass:[NSString class]]) {
            fail(code, message, @"chat_not_found",
                 [NSString stringWithFormat:@"no chat matching '%@'", chatId]);
            return nil;
        }
    }

    return namedResult(IMBStoreHistory(resolved, limit, before, since, code, message));
}

/// Reads one stored message by GUID, e.g. to resolve a search hit.
static id method_storeMessage(NSDictionary *params, NSString **code, NSString **message) {
    NSString *guid = params[@"guid"];
    if (![guid isKindOfClass:[NSString class]] || guid.length == 0) {
        fail(code, message, @"bad_request", @"missing 'guid'");
        return nil;
    }
    NSDictionary *stored = IMBStoreMessage(guid, code, message);
    if (!stored) return nil;
    // Reuse the page path by wrapping the single message, then unwrap.
    return [withNames(@[stored]) firstObject];
}

/// What became of a send, by GUID.
///
/// The other half of surviving a lost reply. An idempotency key stops a retry
/// from sending twice; this answers the question the caller still has, which is
/// whether the message actually arrived. It is deliberately a small answer
/// rather than the whole stored row: the states a caller branches on are few,
/// and reading them out of eight integer columns is where callers get it wrong.
///
/// `unknown` is a real answer, not a failure. A message Messages has not
/// written yet reads as unknown for a moment after a successful send, and so
/// does a GUID that was never sent at all — the two are indistinguishable from
/// here, so the caller is told that rather than told "no".
static id method_sendStatus(NSDictionary *params, NSString **code, NSString **message) {
    NSString *guid = params[@"guid"];
    if (![guid isKindOfClass:[NSString class]] || guid.length == 0) {
        fail(code, message, @"bad_request", @"missing 'guid'");
        return nil;
    }

    NSString *storeCode = nil, *storeMessage = nil;
    NSDictionary *row = IMBStoreMessage(guid, &storeCode, &storeMessage);
    if (!row) {
        // Only a missing message is an answer; a store that would not open is
        // an error, because "unknown" would read as "not sent" and it is not.
        if (storeCode && ![storeCode isEqualToString:@"message_not_found"]) {
            fail(code, message, storeCode, storeMessage);
            return nil;
        }
        return @{ @"guid": guid, @"state": @"unknown" };
    }

    long long error = [row[@"error"] longLongValue];
    BOOL sent      = [row[@"is_sent"] boolValue];
    BOOL delivered = [row[@"is_delivered"] boolValue];
    BOOL read      = [row[@"is_read"] boolValue];

    // Most-advanced state wins: a read message is also delivered and sent, and
    // reporting the weakest true one would lose what the caller asked for.
    NSString *state = @"pending";
    if (error != 0)      state = @"failed";
    else if (read)       state = @"read";
    else if (delivered)  state = @"delivered";
    else if (sent)       state = @"sent";

    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:@{
        @"guid": guid,
        @"state": state,
        @"rowid": row[@"rowid"] ?: @0,
    }];
    if (error != 0) out[@"error"] = @(error);
    for (NSString *stamp in @[@"date", @"date_delivered", @"date_read"]) {
        if (row[stamp] && ![row[stamp] isEqual:[NSNull null]]) out[stamp] = row[stamp];
    }
    if (row[@"chatGuid"]) out[@"chatGuid"] = row[@"chatGuid"];
    return out;
}

/// Finds or starts a conversation with the given people.
static id method_createChat(NSDictionary *params, NSString **code, NSString **message) {
    NSArray *handles = params[@"handles"];
    if (![handles isKindOfClass:[NSArray class]] || handles.count == 0) {
        fail(code, message, @"bad_request", @"missing 'handles'");
        return nil;
    }
    NSString *name = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : nil;

    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    id result = IMBRunOnMain(^id {
        // Whether this opens something new is decided by what existed a moment
        // ago, not by whether the returned chat has messages loaded: the loaded
        // window of an untouched conversation is empty too, which made every
        // existing chat report as new.
        NSMutableSet *before = [NSMutableSet set];
        Class registryCls = NSClassFromString(@"IMChatRegistry");
        id registry = [registryCls respondsToSelector:NSSelectorFromString(@"sharedInstance")]
            ? ((id (*)(id, SEL))objc_msgSend)(registryCls, NSSelectorFromString(@"sharedInstance"))
            : nil;
        @try {
            for (id existing in [registry valueForKey:@"allExistingChats"] ?: @[]) {
                id guid = [existing valueForKey:@"guid"];
                if ([guid isKindOfClass:[NSString class]]) [before addObject:guid];
            }
        } @catch (__unused NSException *e) { /* leave `before` empty */ }

        id chat = IMBCreateChat(handles, name, &innerCode, &innerMessage);
        if (!chat) return nil;
        NSMutableDictionary *out = [IMBSerializeChat(chat) mutableCopy];
        NSString *guid = out[@"guid"];
        out[@"isNew"] = IMBBool(before.count > 0 && guid && ![before containsObject:guid]);
        return out;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return result;
}

/// Deletes messages from this Mac. Not an unsend — see the ops comment.
static id method_deleteMessages(NSDictionary *params, NSString **code, NSString **message) {
    NSArray *guids = params[@"messages"];
    if (![guids isKindOfClass:[NSArray class]] || guids.count == 0) {
        fail(code, message, @"bad_request", @"missing 'messages'");
        return nil;
    }

    __block NSString *innerCode = nil, *innerMessage = nil;
    __block NSUInteger deleted = 0;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;

        NSMutableArray *items = [NSMutableArray array];
        for (NSString *guid in guids) {
            if (![guid isKindOfClass:[NSString class]]) continue;
            // Page the message in first: the loaded window holds only what the
            // UI has shown, so an older message is otherwise simply not found.
            IMBReloadAround(chat, guid);
            id item = IMBFindChatItem(chat, guid);
            if (item) [items addObject:item];
        }
        deleted = items.count;
        return IMBDeleteMessages(chat, items, &innerCode, &innerMessage) ? @YES : nil;
    }, 15.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }

    // Verified by reading back, because a delete does not remove the row. The
    // message is moved out of the conversation into the recoverable set — macOS
    // keeps deleted messages for thirty days — so the row is still there and
    // still readable by GUID. What changes is that it is no longer joined to
    // any chat, which is what `chatGuid` coming back empty means.
    usleep(1500000);
    NSUInteger gone = 0;
    for (NSString *guid in guids) {
        if (![guid isKindOfClass:[NSString class]]) continue;
        NSDictionary *stored = IMBStoreMessage(guid, NULL, NULL);
        if (!stored || !stored[@"chatGuid"]) gone++;
    }
    return @{ @"deleted": @(gone), @"requested": @(guids.count), @"matched": @(deleted) };
}

/// What is known about a handle before sending to it.
///
/// Two questions worth answering in advance: whether the address is reachable
/// on iMessage at all, and whether the person has Focus on — the difference
/// between a message that arrives and one that sits silently.
static id method_whois(NSDictionary *params, NSString **code, NSString **message) {
    NSString *handleID = params[@"handle"];
    if (![handleID isKindOfClass:[NSString class]] || handleID.length == 0) {
        fail(code, message, @"bad_request", @"missing 'handle'");
        return nil;
    }

    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    id result = IMBRunOnMain(^id {
        id handle = IMBLookupHandle(handleID);
        if (!handle) {
            innerCode = @"not_found";
            innerMessage = [NSString stringWithFormat:@"no handle matching '%@'", handleID];
            return nil;
        }
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        NSDictionary *info = IMBHandleInfo(handle);
        for (NSString *key in info) out[key] = info[key];

        // The service the address is registered on. `iMessage` means it is
        // reachable as an iMessage; anything else means SMS or nothing.
        id service = [handle valueForKey:@"service"];
        NSString *serviceName = [service isKindOfClass:[NSString class]]
            ? service : [service valueForKey:@"internalName"];
        if ([serviceName isKindOfClass:[NSString class]]) {
            out[@"service"] = serviceName;
            out[@"isIMessage"] = IMBBool([serviceName caseInsensitiveCompare:@"iMessage"] == NSOrderedSame);
        }

        id status = [handle valueForKey:@"status"];
        if ([status respondsToSelector:@selector(longLongValue)]) {
            out[@"status"] = @([status longLongValue]);
        }
        NSString *statusMessage = [handle valueForKey:@"statusMessage"];
        if ([statusMessage isKindOfClass:[NSString class]] && statusMessage.length) {
            out[@"statusMessage"] = statusMessage;
        }

        // Focus is reported per conversation rather than per person, so it is
        // read from the chat with them when there is one.
        id chat = IMBLookupChat(handleID);
        id silenced = [chat valueForKey:@"participantDNDContactHandles"];
        if ([silenced isKindOfClass:[NSArray class]] || [silenced isKindOfClass:[NSSet class]]) {
            out[@"hasFocusOn"] = IMBBool([silenced count] > 0);
        }
        return out;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return result;
}

/// A conversation's picture and its own flags.
static id method_chatDetails(NSDictionary *params, NSString **code, NSString **message) {
    NSString *chatId = params[@"chat"];
    if (![chatId isKindOfClass:[NSString class]] || chatId.length == 0) {
        fail(code, message, @"bad_request", @"missing 'chat'");
        return nil;
    }
    BOOL timedOut = NO;
    NSString *resolved = IMBRunOnMain(^id {
        id chat = IMBLookupChat(chatId);
        return chat ? [chat valueForKey:@"guid"] : nil;
    }, kMainHopTimeout, &timedOut);
    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (![resolved isKindOfClass:[NSString class]]) {
        fail(code, message, @"chat_not_found",
             [NSString stringWithFormat:@"no chat matching '%@'", chatId]);
        return nil;
    }
    return IMBStoreChatDetails(resolved, code, message);
}

/// One contact picture, as base64. Fetched singly rather than folded into every
/// listing: an avatar is tens of kilobytes and most callers want none of them.
static id method_avatar(NSDictionary *params, NSString **code, NSString **message) {
    NSString *handleID = params[@"handle"];
    if (![handleID isKindOfClass:[NSString class]] || handleID.length == 0) {
        fail(code, message, @"bad_request", @"missing 'handle'");
        return nil;
    }

    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    id result = IMBRunOnMain(^id {
        id handle = IMBLookupHandle(handleID);
        if (!handle) {
            innerCode = @"not_found";
            innerMessage = [NSString stringWithFormat:@"no handle matching '%@'", handleID];
            return nil;
        }
        NSString *mime = nil;
        NSData *picture = IMBHandleAvatar(handle, &mime);
        if (!picture) {
            innerCode = @"not_found";
            innerMessage = @"no contact picture is set for that handle";
            return nil;
        }
        NSDictionary *info = IMBHandleInfo(handle);
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        out[@"handle"] = info[@"id"] ?: handleID;
        if (info[@"name"]) out[@"name"] = info[@"name"];
        out[@"mimeType"] = mime ?: @"image/jpeg";
        out[@"data"] = [picture base64EncodedStringWithOptions:0];
        return out;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return result;
}

/// The full contact card behind a handle.
///
/// A number in a transcript says nothing on its own. This is what turns it into
/// a person: the name Messages draws, and everything else Contacts holds —
/// other numbers, email addresses, birthday, employer, postal addresses.
static id method_contact(NSDictionary *params, NSString **code, NSString **message) {
    NSString *handleID = params[@"handle"];
    if (![handleID isKindOfClass:[NSString class]] || handleID.length == 0) {
        fail(code, message, @"bad_request", @"missing 'handle'");
        return nil;
    }
    BOOL includePhoto = [params[@"includePhoto"] boolValue];

    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    id result = IMBRunOnMain(^id {
        id handle = IMBLookupHandle(handleID);
        if (!handle) {
            innerCode = @"not_found";
            innerMessage = [NSString stringWithFormat:@"no handle matching '%@'", handleID];
            return nil;
        }
        NSDictionary *card = IMBContactCard(handle, includePhoto);
        if (!card) {
            innerCode = @"not_found";
            innerMessage = @"no contact card for that handle";
            return nil;
        }
        return card;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return result;
}

/// Messages still waiting to be delivered. `chat` is optional; without it this
/// covers every conversation, which is the only way to find one that IMCore
/// filed somewhere other than where it was addressed.
static id method_scheduled(NSDictionary *params, NSString **code, NSString **message) {
    NSString *chatId = params[@"chat"];
    NSString *resolved = nil;

    if ([chatId isKindOfClass:[NSString class]] && chatId.length) {
        BOOL timedOut = NO;
        resolved = IMBRunOnMain(^id {
            id chat = IMBLookupChat(chatId);
            return chat ? [chat valueForKey:@"guid"] : nil;
        }, kMainHopTimeout, &timedOut);
        if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
        if (![resolved isKindOfClass:[NSString class]]) {
            fail(code, message, @"chat_not_found",
                 [NSString stringWithFormat:@"no chat matching '%@'", chatId]);
            return nil;
        }
    }
    return namedResult(IMBStoreScheduled(resolved, code, message));
}

// ---------------------------------------------------------------------------
// Table
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// Chat lifecycle, identity, statistics
// ---------------------------------------------------------------------------

/// Returns a conversation to unread. Without `message`, the last one is used.
static id method_markUnread(NSDictionary *params, NSString **code, NSString **message) {
    NSString *guid = [params[@"message"] isKindOfClass:[NSString class]] ? params[@"message"] : nil;
    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        return IMBMarkUnread(chat, guid, &innerCode, &innerMessage) ? @YES : nil;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"unread": @YES };
}

/// Pushes a notification for one message past a mute or a Focus.
static id method_notifyAnyway(NSDictionary *params, NSString **code, NSString **message) {
    NSString *guid = params[@"message"];
    if (![guid isKindOfClass:[NSString class]] || !guid.length) {
        fail(code, message, @"bad_request", @"missing 'message'");
        return nil;
    }
    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        return IMBNotifyAnyway(chat, guid, &innerCode, &innerMessage) ? @YES : nil;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"notified": @YES };
}

/// Pins or unpins a conversation. Reports the state either way.
static id method_pin(NSDictionary *params, NSString **code, NSString **message) {
    BOOL pinned = params[@"pinned"] ? [params[@"pinned"] boolValue] : YES;
    __block NSString *innerCode = nil, *innerMessage = nil;
    __block BOOL nowPinned = NO;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        if (!IMBSetPinned(chat, pinned, &innerCode, &innerMessage)) return nil;
        nowPinned = IMBIsPinned(chat);
        return @YES;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"pinned": IMBBool(nowPinned) };
}

/// Silences a conversation or lifts the silence.
///
/// `until` is a Unix time; without one, muting has no end date. The state is
/// read back off the chat afterwards rather than echoed, because a mute whose
/// date has already passed is not a mute.
static id method_mute(NSDictionary *params, NSString **code, NSString **message) {
    BOOL muted = params[@"muted"] ? [params[@"muted"] boolValue] : YES;
    NSDate *until = nil;
    id untilParam = params[@"until"];
    if ([untilParam isKindOfClass:[NSNumber class]]) {
        until = [NSDate dateWithTimeIntervalSince1970:[untilParam doubleValue]];
    }
    if (until && !muted) {
        fail(code, message, @"bad_request", @"'until' has no meaning when unmuting");
        return nil;
    }

    __block NSString *innerCode = nil, *innerMessage = nil;
    __block BOOL nowMuted = NO;
    __block NSDate *nowUntil = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        if (!IMBSetMuted(chat, muted, until, &innerCode, &innerMessage)) return nil;
        nowMuted = IMBIsMuted(chat);
        nowUntil = IMBMutedUntil(chat);
        return @YES;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"muted"] = IMBBool(nowMuted);
    // The distant future is how an indefinite mute is stored; reporting it as
    // a date would have a caller show "muted until the year 4001".
    if (nowUntil && [nowUntil timeIntervalSinceNow] < 60 * 60 * 24 * 365 * 50) {
        result[@"until"] = @([nowUntil timeIntervalSince1970]);
    }
    return result;
}

/// Empties a conversation of its messages.
static id method_deleteHistory(NSDictionary *params, NSString **code, NSString **message) {
    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        return IMBDeleteAllHistory(chat, &innerCode, &innerMessage) ? @YES : nil;
    }, 30.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"deleted": @YES };
}

/// Removes the conversation itself, rather than emptying it.
static id method_deleteChat(NSDictionary *params, NSString **code, NSString **message) {
    if (!requireCapability(@"deleteChat", code, message)) return nil;
    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        return IMBDeleteChat(chat, &innerCode, &innerMessage) ? @YES : nil;
    }, 30.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"deleted": @YES };
}

/// Shares this account's Name & Photo with someone.
static id method_shareNameAndPhoto(NSDictionary *params, NSString **code, NSString **message) {
    if (!requireCapability(@"shareNameAndPhoto", code, message)) return nil;
    NSString *handle = params[@"handle"];
    if (![handle isKindOfClass:[NSString class]] || handle.length == 0) {
        fail(code, message, @"bad_request", @"missing 'handle'");
        return nil;
    }
    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        return IMBShareNameAndPhoto(handle, &innerCode, &innerMessage) ? @YES : nil;
    }, 30.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"shared": @YES };
}

/// Reports a conversation to Apple as junk.
static id method_reportJunk(NSDictionary *params, NSString **code, NSString **message) {
    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        return IMBReportJunk(chat, &innerCode, &innerMessage) ? @YES : nil;
    }, 30.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"reported": @YES };
}

/// The unread messages in a conversation that mention this account.
static id method_mentions(NSDictionary *params, NSString **code, NSString **message) {
    __block NSString *innerCode = nil, *innerMessage = nil;
    __block NSArray *guids = @[];
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        guids = IMBUnreadMentions(chat);
        return @YES;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"messages": guids ?: @[] };
}

/// Resends a message over SMS.
static id method_sendAsText(NSDictionary *params, NSString **code, NSString **message) {
    NSString *target = params[@"message"];
    if (![target isKindOfClass:[NSString class]] || target.length == 0) {
        fail(code, message, @"bad_request", @"missing 'message'");
        return nil;
    }
    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        return IMBDowngradeMessage(chat, target, &innerCode, &innerMessage) ? @YES : nil;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"requested": @YES };
}

/// Shares this account's location with a conversation for a bounded time.
static id method_shareLocation(NSDictionary *params, NSString **code, NSString **message) {
    id secondsParam = params[@"seconds"];
    if (![secondsParam isKindOfClass:[NSNumber class]]) {
        fail(code, message, @"bad_request",
             @"missing 'seconds' — sharing without an end is not offered");
        return nil;
    }
    long long seconds = [secondsParam longLongValue];

    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        return IMBShareLocation(chat, seconds, &innerCode, &innerMessage) ? @YES : nil;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"sharing": @YES, @"seconds": @(seconds) };
}

/// Sets a group conversation's photo, or clears it when no path is given.
static id method_setGroupPhoto(NSDictionary *params, NSString **code, NSString **message) {
    NSString *path = [params[@"file"] isKindOfClass:[NSString class]] ? params[@"file"] : nil;
    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        id chat = lookupOrFail(params, &innerCode, &innerMessage);
        if (!chat) return nil;
        return IMBSetGroupPhoto(chat, path, &innerCode, &innerMessage) ? @YES : nil;
    }, 30.0, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"updated": @YES, @"cleared": IMBBool(path.length == 0) };
}

/// The signed-in messaging identity.
static id method_account(NSDictionary *params, NSString **code, NSString **message) {
    __block NSDictionary *info = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id { info = IMBAccountInfo(); return @YES; }, kMainHopTimeout, &timedOut);
    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    return info ?: @{};
}

/// Changes which vetted alias outgoing iMessages are attributed to.
static id method_setSendingAlias(NSDictionary *params, NSString **code, NSString **message) {
    NSString *alias = params[@"alias"];
    if (![alias isKindOfClass:[NSString class]] || !alias.length) {
        fail(code, message, @"bad_request", @"missing 'alias'");
        return nil;
    }
    __block NSString *innerCode = nil, *innerMessage = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        return IMBSetSendingAlias(alias, &innerCode, &innerMessage) ? @YES : nil;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }
    return @{ @"sendingAs": alias };
}

/// The Name & Photo card a handle shared, or your own, plus anything pending.
static id method_nickname(NSDictionary *params, NSString **code, NSString **message) {
    NSString *handle = [params[@"handle"] isKindOfClass:[NSString class]] ? params[@"handle"] : nil;
    __block NSString *innerCode = nil, *innerMessage = nil;
    __block NSDictionary *card = nil;
    __block NSArray *pending = nil;
    BOOL timedOut = NO;
    IMBRunOnMain(^id {
        card = IMBNickname(handle, &innerCode, &innerMessage);
        if (!card) return nil;
        if (!handle.length) pending = IMBPendingNicknames();
        return @YES;
    }, kMainHopTimeout, &timedOut);

    if (timedOut) { fail(code, message, @"timeout", @"Messages did not respond"); return nil; }
    if (innerCode) { fail(code, message, innerCode, innerMessage); return nil; }

    NSMutableDictionary *out = [card mutableCopy];
    if (pending) out[@"pending"] = pending;
    return out;
}

/// Counts and distributions over a conversation, or over the whole store.
static id method_stats(NSDictionary *params, NSString **code, NSString **message) {
    NSString *chatGuid = [params[@"chat"] isKindOfClass:[NSString class]] ? params[@"chat"] : nil;
    long long since = [params[@"since"] respondsToSelector:@selector(longLongValue)]
        ? [params[@"since"] longLongValue] : 0;
    return IMBStats(chatGuid, since, code, message);
}

id IMBDispatch(NSString *method, NSDictionary *params,
               NSString **code, NSString **message) {
    if (!IMBIsIMCoreReady() && ![method isEqualToString:@"status"]) {
        fail(code, message, @"not_ready", @"IMCore is not loaded yet");
        return nil;
    }

    if ([method isEqualToString:@"status"])      return method_status(params, code, message);
    if ([method isEqualToString:@"listChats"])   return method_listChats(params, code, message);
    if ([method isEqualToString:@"resolveChat"]) return method_resolveChat(params, code, message);
    if ([method isEqualToString:@"resolveChats"]) return method_resolveChats(params, code, message);
    if ([method isEqualToString:@"chatsWith"])   return method_chatsWith(params, code, message);
    if ([method isEqualToString:@"setTyping"])   return method_setTyping(params, code, message);
    if ([method isEqualToString:@"getHistory"])  return method_getHistory(params, code, message);
    if ([method isEqualToString:@"send"])        return method_send(params, code, message);
    if ([method isEqualToString:@"tapback"])     return method_tapback(params, code, message);
    if ([method isEqualToString:@"sendPoll"])    return method_sendPoll(params, code, message);
    if ([method isEqualToString:@"votePoll"])    return method_votePoll(params, code, message);
    if ([method isEqualToString:@"sendLater"])   return method_sendLater(params, code, message);
    if ([method isEqualToString:@"cancelScheduled"])
        return method_cancelScheduled(params, code, message);
    if ([method isEqualToString:@"retract"])     return method_retract(params, code, message);
    if ([method isEqualToString:@"edit"])        return method_edit(params, code, message);
    if ([method isEqualToString:@"markRead"])    return method_markRead(params, code, message);
    if ([method isEqualToString:@"search"])      return method_search(params, code, message);
    if ([method isEqualToString:@"storeHistory"]) return method_storeHistory(params, code, message);
    if ([method isEqualToString:@"storeMessage"]) return method_storeMessage(params, code, message);
    if ([method isEqualToString:@"scheduled"])    return method_scheduled(params, code, message);
    if ([method isEqualToString:@"chatDetails"])  return method_chatDetails(params, code, message);
    if ([method isEqualToString:@"avatar"])       return method_avatar(params, code, message);
    if ([method isEqualToString:@"contact"])      return method_contact(params, code, message);
    if ([method isEqualToString:@"whois"])        return method_whois(params, code, message);
    if ([method isEqualToString:@"createChat"])   return method_createChat(params, code, message);
    if ([method isEqualToString:@"deleteMessages"])
        return method_deleteMessages(params, code, message);
    if ([method isEqualToString:@"downloadAttachments"])
        return method_downloadAttachments(params, code, message);
    if ([method isEqualToString:@"markUnread"])   return method_markUnread(params, code, message);
    if ([method isEqualToString:@"notifyAnyway"]) return method_notifyAnyway(params, code, message);
    if ([method isEqualToString:@"pin"])          return method_pin(params, code, message);
    if ([method isEqualToString:@"mute"])         return method_mute(params, code, message);
    if ([method isEqualToString:@"deleteHistory"]) return method_deleteHistory(params, code, message);
    if ([method isEqualToString:@"deleteChat"])   return method_deleteChat(params, code, message);
    if ([method isEqualToString:@"shareNameAndPhoto"]) {
        return method_shareNameAndPhoto(params, code, message);
    }
    if ([method isEqualToString:@"sendStatus"])   return method_sendStatus(params, code, message);
    if ([method isEqualToString:@"reportJunk"])   return method_reportJunk(params, code, message);
    if ([method isEqualToString:@"mentions"])     return method_mentions(params, code, message);
    if ([method isEqualToString:@"sendAsText"])   return method_sendAsText(params, code, message);
    if ([method isEqualToString:@"shareLocation"]) return method_shareLocation(params, code, message);
    if ([method isEqualToString:@"setGroupPhoto"]) return method_setGroupPhoto(params, code, message);
    if ([method isEqualToString:@"account"])      return method_account(params, code, message);
    if ([method isEqualToString:@"setSendingAlias"])
        return method_setSendingAlias(params, code, message);
    if ([method isEqualToString:@"nickname"])     return method_nickname(params, code, message);
    if ([method isEqualToString:@"stats"])        return method_stats(params, code, message);
    if ([method isEqualToString:@"group.rename"]) return method_groupRename(params, code, message);
    if ([method isEqualToString:@"group.add"])    return method_groupAdd(params, code, message);
    if ([method isEqualToString:@"group.remove"]) return method_groupRemove(params, code, message);
    if ([method isEqualToString:@"group.leave"])  return method_groupLeave(params, code, message);
    if ([method isEqualToString:@"group.canAdd"]) {
        return method_groupCanChange(params, YES, code, message);
    }
    if ([method isEqualToString:@"group.canRemove"]) {
        return method_groupCanChange(params, NO, code, message);
    }

    fail(code, message, @"unknown_method",
         [NSString stringWithFormat:@"no such method '%@'", method]);
    return nil;
}
