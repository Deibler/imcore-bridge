// Write operations: send, tapback, retract, edit, group management.
//
// Argument types come from the runtime's own method signatures rather than
// guesswork — passing the wrong type into IMCore crashes the host app, and the
// host app is the user's real messaging client.
//
// ---------------------------------------------------------------------------
// Rule: only invoke what Messages.app itself invokes during ordinary use.
// ---------------------------------------------------------------------------
//
// Every call here must be something the app does routinely to a single chat or
// a single message — send, edit, retract, mark read, set typing. Anything that
// mutates shared state (accounts, registries, identity maps, transfer tables)
// is out of bounds even when it looks like the missing piece, because a mistake
// there does not fail cleanly: it corrupts the running app's view of the user's
// conversations.
//
// Known-harmful, deliberately not called:
//
//   assignTransfer:toMessage:account:
//       Binds a transfer to an account. Corrupted IMCore's chat-to-identity
//       mapping: a conversation rendered under the wrong contact and appeared
//       twice in the sidebar. Stored data was intact; a restart cleared it.
//
//   assignTransfer:toMessage:account: is the only entry that was ever proven
//   harmful. Creating and registering an *outgoing* transfer was on this list
//   too, on the evidence that it left orphaned records and never uploaded.
//   That was a missing step, not a forbidden call: the file has to be staged
//   into the attachment tree before registration, because the daemon uploads
//   from there. With the staging in place the upload starts normally. See
//   transfer.m.
//
// Two further cautions, both learned by breaking the UI:
//
//   loadMessagesBeforeDate:limit: must be given a real date. nil reads as the
//   distant past and empties the chat's loaded window.
//
//   A message carrying attachments needs matching U+FFFC placeholder runs in
//   its body; GUIDs alone leave part splitting inconsistent and blank the
//   transcript.
#import "bridge.h"
#import <objc/message.h>
#include <dlfcn.h>

// IMMessage's flags argument. 1 is a normal outgoing message.
static const unsigned long long kIMMessageFlagsNormal = 1;

/// The association type on a sticker stuck to a bubble, as opposed to the
/// 2000-range reactions. Read off the store: every peel-and-stick sticker in
/// this machine's history carries 1000, a "p:<part>/<guid>" target and a
/// sticker transfer.
static const long long kIMStickerAssociationType = 1000;

static id safeValue(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

/// IMMessage bodies are attributed strings, and every run must be tagged with
/// its message-part index. Without that attribute IMCore enumerates an index
/// set as if it were an array while splitting the body into parts, and the send
/// fails with an unrecognised-selector exception.
static NSAttributedString *attributed(NSString *text) {
    return [[NSAttributedString alloc] initWithString:(text ?: @"")
                                           attributes:@{ @"__kIMMessagePartAttributeName": @0 }];
}

/// Every animated text effect this build knows, by name.
///
/// Enumerated by asking IMCore what each code is called rather than by keeping
/// a list, so a release that adds one is reflected without a change here. The
/// codes are contiguous from 1; 0 means no effect.
NSArray<NSString *> *IMBTextEffectNames(void) {
    static NSArray *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *(*nameFromType)(long long) = dlsym(RTLD_DEFAULT, "IMTextEffectNameFromType");
        if (!nameFromType) { names = @[]; return; }
        NSMutableArray *found = [NSMutableArray array];
        // Stop after a short run of gaps rather than at the first, so a
        // retired code in the middle does not truncate the list.
        NSUInteger misses = 0;
        for (long long code = 1; code < 64 && misses < 4; code++) {
            NSString *name = nil;
            @try { name = nameFromType(code); } @catch (__unused NSException *e) { name = nil; }
            if ([name isKindOfClass:[NSString class]] && name.length) {
                [found addObject:name];
                misses = 0;
            } else {
                misses++;
            }
        }
        names = found;
    });
    return names;
}

/// Applies styling, text effects and mentions over ranges of a body.
///
/// Each entry names a range of the text and what to put on it: any of `bold`,
/// `italic`, `underline`, `strikethrough`; a `textEffect`; or a `handle`, which
/// makes the range a mention of that person.
///
/// Ranges are validated against the body rather than trusted. A range past the
/// end would raise inside IMCore while it split the message into parts, which
/// is a crash in the host rather than a failed send — and character indexes
/// from a caller counting differently (bytes, code points, grapheme clusters)
/// are the ordinary way that happens.
static NSAttributedString *applyFormatting(NSAttributedString *body, NSArray *ranges,
                                           NSString **errCode, NSString **errMessage) {
    if (![ranges isKindOfClass:[NSArray class]] || !ranges.count) return body;

    NSMutableAttributedString *styled = [body mutableCopy];
    for (NSDictionary *entry in ranges) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;

        NSInteger location = [entry[@"location"] integerValue];
        NSInteger length = [entry[@"length"] integerValue];
        if (location < 0 || length <= 0) continue;
        if ((NSUInteger)(location + length) > styled.length) continue;
        NSRange range = NSMakeRange((NSUInteger)location, (NSUInteger)length);

        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        for (NSString *style in entry[@"styles"] ?: @[]) {
            if ([style isEqualToString:@"bold"])          attrs[@"__kIMTextBoldAttributeName"] = @YES;
            else if ([style isEqualToString:@"italic"])   attrs[@"__kIMTextItalicAttributeName"] = @YES;
            else if ([style isEqualToString:@"underline"]) attrs[@"__kIMTextUnderlineAttributeName"] = @YES;
            else if ([style isEqualToString:@"strikethrough"]) {
                attrs[@"__kIMTextStrikethroughAttributeName"] = @YES;
            }
        }

        id effect = entry[@"textEffect"];
        if ([effect isKindOfClass:[NSString class]] && [effect length]) {
            // The attribute holds a code; IMCore ships the name-to-code
            // mapping, so it is asked rather than duplicated here.
            static long long (*typeFromName)(NSString *) = NULL;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                typeFromName = dlsym(RTLD_DEFAULT, "IMTextEffectTypeFromName");
            });
            long long code = 0;
            if (typeFromName) {
                @try { code = typeFromName(effect); }
                @catch (__unused NSException *e) { code = 0; }
            }
            // Zero is "no effect", so an unrecognised name would send a plain
            // message that looked like it worked. The names are case-sensitive
            // and not always what the UI calls them — there is no `shake`, only
            // `shakeVertical` and `shakeHorizontal` — so this has to be an
            // error rather than a silent drop.
            if (code == 0) {
                if (errCode) *errCode = @"bad_request";
                if (errMessage) *errMessage = [NSString stringWithFormat:
                    @"unknown text effect '%@' — expected one of %@",
                    effect, [IMBTextEffectNames() componentsJoinedByString:@", "]];
                return nil;
            }
            attrs[@"__kIMTextEffectAttributeName"] = @(code);
        } else if ([effect respondsToSelector:@selector(longLongValue)]) {
            attrs[@"__kIMTextEffectAttributeName"] = @([effect longLongValue]);
        }

        // A mention is a range naming a participant, which is what makes it
        // notify them rather than merely reading as their name.
        NSString *handle = entry[@"handle"];
        if ([handle isKindOfClass:[NSString class]] && handle.length) {
            attrs[@"__kIMMentionConfirmedMention"] = handle;
        }

        if (attrs.count) [styled addAttributes:attrs range:range];
    }
    return styled;
}

/// Builds a body for a message that carries attachments.
///
/// An attachment is not conveyed by `fileTransferGUIDs` alone: the body must
/// contain one U+FFFC placeholder per file, each tagged with that transfer's
/// GUID and its own part index, exactly as received messages are shaped.
/// Passing the GUIDs without matching placeholders leaves IMCore's part
/// splitting inconsistent — the attachment is silently dropped *and* the
/// transcript fails to rebuild, which shows up as the conversation going blank.
static NSAttributedString *attributedWithAttachments(NSString *text,
                                                     NSArray *attachments) {
    NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];
    NSUInteger part = 0;

    for (id entry in attachments) {
        NSString *guid = entry;
        NSString *filename = nil;
        if ([entry isKindOfClass:[NSDictionary class]]) {
            guid = entry[@"guid"];
            filename = entry[@"filename"];
        }
        if (![guid isKindOfClass:[NSString class]] || guid.length == 0) continue;

        NSMutableDictionary *attrs = [@{
            @"__kIMMessagePartAttributeName": @(part),
            @"__kIMFileTransferGUIDAttributeName": guid,
            // Base writing direction is part of the shape Messages writes for
            // every attachment run. Its absence does not break the send, but
            // it does make the run differ from a natively composed one.
            @"__kIMBaseWritingDirectionAttributeName": @"-1",
        } mutableCopy];
        // The filename rides on the placeholder as well as on the transfer.
        // Without it the bubble renders with an empty name until the transfer
        // finishes resolving.
        if ([filename isKindOfClass:[NSString class]] && filename.length) {
            attrs[@"__kIMFilenameAttributeName"] = filename;
        }

        [body appendAttributedString:
            [[NSAttributedString alloc] initWithString:@"￼" attributes:attrs]];
        part++;
    }

    if (text.length) {
        [body appendAttributedString:
            [[NSAttributedString alloc] initWithString:text
                                           attributes:@{ @"__kIMMessagePartAttributeName": @(part) }]];
    }
    return body;
}

/// Searches the loaded window for the chat item representing `guid`.
static id findLoadedChatItem(id chat, NSString *guid) {
    NSArray *items = safeValue(chat, @"chatItems");
    if (![items isKindOfClass:[NSArray class]]) return nil;

    for (id item in items) {
        if ([guid isEqualToString:safeValue(item, @"guid")]) return item;
        id message = IMBUnderlyingMessage(item);
        if ([guid isEqualToString:safeValue(message, @"guid")]) return item;
    }
    return nil;
}

/// Locates the chat item representing `guid`, which tapback, retract and edit
/// all operate on rather than on the message itself.
///
/// `chatItems` holds only what the UI has loaded, so a message older than that
/// window is not there — which is why these operations used to fail on
/// anything but recent messages. When it is missing, IMCore is asked to page
/// in the messages around that GUID, exactly as the app does when a search
/// result is opened. Unlike loading by date, this is anchored to a real
/// message, so it extends the window rather than replacing it.
id IMBFindChatItem(id chat, NSString *guid) {
    if (!guid.length) return nil;

    id item = findLoadedChatItem(chat, guid);
    if (item) return item;

    // Note: hasStoredMessageWithGUID: is not a store lookup — it answers NO for
    // messages that are plainly in the conversation — so it is not used as a
    // precondition here. An unknown GUID simply loads nothing.
    if (!IMBReloadAround(chat, guid)) return nil;
    return findLoadedChatItem(chat, guid);
}

/// Asks IMCore to page the messages around `guid` into the loaded window.
///
/// This is what the app does when a search result is opened. Unlike loading by
/// date it is anchored to a real message, so it extends the window rather than
/// replacing it.
BOOL IMBReloadAround(id chat, NSString *guid) {
    SEL loadAround = NSSelectorFromString(
        @"loadMessagesBeforeAndAfterGUID:numberOfMessagesToLoadBeforeGUID:"
         "numberOfMessagesToLoadAfterGUID:loadImmediately:threadIdentifier:");
    if (![chat respondsToSelector:loadAround]) return NO;

    @try {
        ((id (*)(id, SEL, id, unsigned long long, unsigned long long, BOOL, id))objc_msgSend)(
            chat, loadAround, guid, 5, 5, YES, nil);
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"loadMessagesBeforeAndAfterGUID threw: %@", e.reason);
        return NO;
    }
}

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

/// Builds an outgoing IMMessage.
///
/// Each entry of `attachments` is either a transfer GUID or a
/// `{ guid, filename }` dictionary; the body carries one placeholder run per
/// entry while IMCore is handed the bare GUIDs.
id IMBBuildMessage(NSString *text, NSString *subject, NSArray *attachments,
                   NSString *effect, NSString *threadIdentifier, NSArray *formatting,
                   NSString **errCode, NSString **errMessage) {
    Class msgCls = NSClassFromString(@"IMMessage");
    if (!msgCls) {
        if (errCode) *errCode = @"not_ready";
        if (errMessage) *errMessage = @"IMMessage unavailable";
        return nil;
    }

    NSMutableArray<NSString *> *guids = [NSMutableArray array];
    for (id entry in attachments) {
        id guid = [entry isKindOfClass:[NSDictionary class]] ? entry[@"guid"] : entry;
        if ([guid isKindOfClass:[NSString class]] && [guid length]) [guids addObject:guid];
    }

    BOOL hasAttachments = guids.count > 0;
    NSAttributedString *body = hasAttachments
        ? attributedWithAttachments(text, attachments)
        : attributed(text);
    if (formatting.count) {
        body = applyFormatting(body, formatting, errCode, errMessage);
        if (!body) return nil;
    }
    BOOL hasEffect = effect.length > 0;
    BOOL hasThread = threadIdentifier.length > 0;

    @try {
        // The class factories each drop one of attachments, effect and thread,
        // which is why this combination used to be reported as impossible. The
        // designated initialiser underneath them takes all three, so the
        // combination is only unreachable through the convenience methods.
        if (hasAttachments && hasEffect && hasThread) {
            SEL sel = NSSelectorFromString(
                @"initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:"
                 "guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:threadIdentifier:");
            if (![msgCls instancesRespondToSelector:sel]) goto unsupported;
            return ((id (*)(id, SEL, id, id, id, id, id, unsigned long long, id, id, id, id, id, id, id))objc_msgSend)(
                [msgCls alloc], sel, nil, nil, body, subject, guids,
                kIMMessageFlagsNormal, nil, nil, nil, nil, nil, effect, threadIdentifier);
        }

        if (hasEffect && !hasAttachments) {
            SEL sel = NSSelectorFromString(
                @"instantMessageWithText:messageSubject:flags:expressiveSendStyleID:threadIdentifier:");
            if (![msgCls respondsToSelector:sel]) goto unsupported;
            return ((id (*)(id, SEL, id, id, unsigned long long, id, id))objc_msgSend)(
                msgCls, sel, body, subject, kIMMessageFlagsNormal, effect, threadIdentifier);
        }

        if (hasEffect && hasAttachments) {
            SEL sel = NSSelectorFromString(
                @"instantMessageWithText:messageSubject:fileTransferGUIDs:flags:balloonBundleID:payloadData:expressiveSendStyleID:");
            if (![msgCls respondsToSelector:sel]) goto unsupported;
            return ((id (*)(id, SEL, id, id, id, unsigned long long, id, id, id))objc_msgSend)(
                msgCls, sel, body, subject, guids,
                kIMMessageFlagsNormal, nil, nil, effect);
        }

        SEL sel = NSSelectorFromString(
            @"instantMessageWithText:messageSubject:fileTransferGUIDs:flags:threadIdentifier:");
        if (![msgCls respondsToSelector:sel]) goto unsupported;
        return ((id (*)(id, SEL, id, id, id, unsigned long long, id))objc_msgSend)(
            msgCls, sel, body, subject, guids,
            kIMMessageFlagsNormal, threadIdentifier);
    } @catch (NSException *e) {
        IMBLog(@"message construction threw: %@", e.reason);
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = e.reason ?: @"could not build message";
        return nil;
    }

unsupported:
    if (errCode) *errCode = @"unsupported_feature";
    if (errMessage) *errMessage = @"this macOS build has no matching send selector";
    return nil;
}

/// Hands a built message to a chat. Returns the message GUID.
/// The account IMCore would send a named service's messages on.
///
/// These are the two the composer's service picker chooses between, read off
/// the account controller rather than constructed. A service the machine is
/// not signed in to answers nil, which is the difference between "this Mac has
/// no SMS relay" and a message that silently goes out over iMessage instead.
static id accountForService(NSString *service) {
    Class controllerCls = NSClassFromString(@"IMAccountController");
    id controller = controllerCls
        ? ((id (*)(id, SEL))objc_msgSend)(controllerCls, NSSelectorFromString(@"sharedInstance"))
        : nil;
    if (!controller) return nil;

    NSString *selName = [service caseInsensitiveCompare:@"SMS"] == NSOrderedSame
        ? @"activeSMSAccount" : @"activeIMessageAccount";
    SEL sel = NSSelectorFromString(selName);
    if (![controller respondsToSelector:sel]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(controller, sel);
    } @catch (NSException *e) {
        IMBLog(@"%@ threw: %@", selName, e.reason);
        return nil;
    }
}

/// Whether a conversation is known to be on a service other than the one named.
///
/// Unknown deliberately counts as no. A chat whose account is not bound yet —
/// freshly resolved, or Messages only just relaunched — reports no service at
/// all, and reading that as "on a different service" sent the message over the
/// account with `sendMessage:onAccount:` rather than into the chat. That
/// delivered a reply to the sender's own address instead of the recipient.
///
/// Forcing an account is the destructive branch, so it is taken only on
/// positive evidence that the conversation is somewhere else.
static BOOL chatIsOnOtherService(id chat, NSString *service) {
    NSString *current = safeValue(safeValue(chat, @"account"), @"serviceName");
    if (![current isKindOfClass:[NSString class]] || current.length == 0) return NO;
    return [current caseInsensitiveCompare:service] != NSOrderedSame;
}

/// An address with IMCore's type prefix removed — "e:a@b.c" and "a@b.c" are
/// the same address, spelled two ways.
static NSString *bareOwnAddress(NSString *address) {
    if (address.length > 2 && [address characterAtIndex:1] == ':') {
        unichar c0 = [address characterAtIndex:0];
        if (c0 == 'e' || c0 == 'E' || c0 == 'p' || c0 == 'P') {
            return [address substringFromIndex:2];
        }
    }
    return address;
}

/// Whether an address reaches one of the signed-in accounts — an alias, or the
/// login handle itself.
static BOOL isOwnAddress(NSString *address) {
    if (![address isKindOfClass:[NSString class]]) return NO;
    NSString *bare = bareOwnAddress(address);
    if (!bare.length) return NO;
    for (NSString *service in @[ @"iMessage", @"SMS" ]) {
        id account = accountForService(service);
        if (!account) continue;
        NSArray *aliases = safeValue(account, @"aliases");
        if ([aliases isKindOfClass:[NSArray class]]) {
            for (id alias in aliases) {
                if ([alias isKindOfClass:[NSString class]] &&
                    [bare caseInsensitiveCompare:alias] == NSOrderedSame) {
                    return YES;
                }
            }
        }
        NSString *login = safeValue(safeValue(account, @"loginIMHandle"), @"ID");
        if ([login isKindOfClass:[NSString class]] &&
            [bare caseInsensitiveCompare:bareOwnAddress(login)] == NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

/// A 1:1 conversation whose only participant is one of our own addresses,
/// while its identifier names someone else, is a chat the registry has
/// re-registered against our own account — the damage a forced-account send
/// leaves behind inside imagent. Sending into it delivers to the note-to-self
/// thread and reports success; the person the chat is named after sees
/// nothing. Observed live: the chat for a real phone number answered with a
/// participant of "e:<our own iCloud address>" and quietly swallowed a reply.
///
/// The store underneath stays correct — only the registry object is wrong —
/// which is why the error prescribes restarting imagent rather than guessing.
/// Whether the conversation's live routing points at our own address.
///
/// The recipient is the handle IMCore actually routes a 1:1 send to, so it is
/// checked as well as the participant list — a misroute was observed where
/// the participants still read correctly at send time.
static BOOL routingPointsAtSelf(id chat) {
    NSString *recipient = safeValue(safeValue(chat, @"recipient"), @"ID");
    if ([recipient isKindOfClass:[NSString class]] && recipient.length &&
        isOwnAddress(recipient)) {
        return YES;
    }

    NSArray *participants = safeValue(chat, @"participants");
    if ([participants isKindOfClass:[NSArray class]] && participants.count == 1) {
        NSString *participant = safeValue(participants.firstObject, @"ID");
        if ([participant isKindOfClass:[NSString class]] && isOwnAddress(participant)) {
            return YES;
        }
    }
    return NO;
}

static BOOL chatRoutesToSelf(id chat) {
    // Messaging yourself is legitimate, and the identifier says when that is
    // what the conversation is. Poisoning is when it says someone else.
    NSString *identifier = safeValue(chat, @"chatIdentifier");
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) return NO;
    if (isOwnAddress(identifier)) return NO;
    return routingPointsAtSelf(chat);
}

/// Whether this host refuses every send that targets its own address.
///
/// Opt-in through the environment the injector spawns Messages with, because
/// it is a policy, not a safety default: a host driving its own account as an
/// agent has no legitimate self-traffic — anything landing in its own thread
/// is a bug's output — while a person's note-to-self is real use.
BOOL IMBSelfSendsBlocked(void) {
    static BOOL blocked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocked = getenv("IMCORE_BRIDGE_BLOCK_SELF_SENDS") != NULL;
    });
    return blocked;
}

/// Whether the conversation is our own thread by any reading — identifier,
/// routed recipient, or sole participant.
BOOL IMBChatTargetsSelf(id chat) {
    NSString *identifier = safeValue(chat, @"chatIdentifier");
    if ([identifier isKindOfClass:[NSString class]] && identifier.length &&
        isOwnAddress(identifier)) {
        return YES;
    }
    return routingPointsAtSelf(chat);
}

/// The handle a 1:1 conversation currently routes to, for reporting alongside
/// a send. Group chats and unresolved recipients answer nil.
NSString *IMBChatRecipientID(id chat) {
    NSString *recipient = safeValue(safeValue(chat, @"recipient"), @"ID");
    return [recipient isKindOfClass:[NSString class]] && recipient.length ? recipient : nil;
}

/// Sends `message` into `chat`, optionally forcing which service carries it.
///
/// `service` names iMessage or SMS. Naming the one the conversation already
/// uses is the ordinary send; naming the other routes this message — and only
/// this message — over that account, which is what the composer does when a
/// person picks Send as Text Message before hitting return. The chat's own
/// account is deliberately left alone: rewriting it would change where every
/// later message in the conversation goes, including ones sent from the app by
/// hand.
NSString *IMBSendMessage(id chat, id message, NSString *service,
                         NSString **errCode, NSString **errMessage) {
    if (IMBSelfSendsBlocked() && IMBChatTargetsSelf(chat)) {
        if (errCode) *errCode = @"self_send_blocked";
        if (errMessage) *errMessage = [NSString stringWithFormat:
            @"refusing to send: '%@' is this account's own thread, and this "
            @"bridge was launched with IMCORE_BRIDGE_BLOCK_SELF_SENDS — "
            @"nothing may be sent to our own address.",
            safeValue(chat, @"chatIdentifier") ?: @"?"];
        return nil;
    }

    if (chatRoutesToSelf(chat)) {
        if (errCode) *errCode = @"chat_poisoned";
        if (errMessage) *errMessage = [NSString stringWithFormat:
            @"refusing to send: the registry's object for '%@' lists our own "
            @"address as its only participant, so this message would land in "
            @"the note-to-self thread while claiming success. The store is "
            @"intact — restart imagent (`killall imagent`) to rebuild the "
            @"registry, then retry.",
            safeValue(chat, @"chatIdentifier") ?: @"?"];
        return nil;
    }

    SEL sel = NSSelectorFromString(@"sendMessage:");
    if (![chat respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"sendMessage: unavailable";
        return nil;
    }

    // Account forcing is gone, deliberately and permanently. Routing one
    // message over a named account (`sendMessage:onAccount:` — the Send as
    // Text Message mechanism) is the act that re-registers the chat against
    // our own account inside imagent: from then on the registry object's
    // recipient reads as our own address and every send into it lands in the
    // note-to-self thread while reporting success. Every observed poisoning
    // traces back to this call. A message goes however its conversation
    // already sends; a caller that names the OTHER service is told no rather
    // than taking the poisoned route.
    if (service.length && chatIsOnOtherService(chat, service)) {
        if (errCode) *errCode = @"service_mismatch";
        if (errMessage) *errMessage = [NSString stringWithFormat:
            @"refusing to send: '%@' is bound to a different service than the "
            @"requested '%@', and forcing a message over an account was "
            @"removed — it corrupts imagent's registration for the chat "
            @"(the note-to-self poisoning). Omit 'service' to send the way "
            @"the conversation already sends.",
            safeValue(chat, @"chatIdentifier") ?: @"?", service];
        return nil;
    }

    // Send WITHOUT letting IMCore adjust the sender.
    //
    // `sendMessage:` is a wrapper over
    // `_sendMessage:adjustingSender:shouldQueue:`, and the sender adjustment
    // is the step under suspicion: on this account, every bridge send is
    // followed by the chat's recipient and participants being rewritten with
    // the account owner's own address, while the identical message sent by
    // hand from the Messages UI never does that. The UI does not take this
    // path — it goes through CKConversation's
    // `sendMessage:onService:newComposition:`, which resolves the target
    // service first and never asks for a sender adjustment.
    // Dispatch through the chat registry rather than -[IMChat sendMessage:].
    //
    // `sendMessage:` wraps `_sendMessage:adjustingSender:shouldQueue:` with
    // adjustingSender:YES, and that sender adjustment is what makes Messages
    // rewrite this chat afterwards: __kIMChatRecipientDidChangeNotification
    // fires and the chat's identifier, participants and recipient all become
    // our own address. The message that triggered it still lands; the NEXT
    // send into that object misroutes to the note-to-self thread. Sending by
    // hand from the Messages UI never does this, because the UI goes through
    // CKConversation's sendMessage:onService:newComposition: instead.
    //
    // Calling `_sendMessage:adjustingSender:NO` directly does avoid the
    // relabel, but independent reverse engineering (openclaw/imsg) found that
    // path "may silently drop items in some macOS 26 states" — a dropped
    // message is worse than a relabelled chat, which the resolution guard
    // catches. The registry dispatch is what that project moved to, and it is
    // the layer Messages itself ends up in.
    Class regCls = NSClassFromString(@"IMChatRegistry");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    id reg = (regCls && [regCls respondsToSelector:shared])
                 ? ((id (*)(id, SEL))objc_msgSend)(regCls, shared)
                 : nil;
    SEL regSend = NSSelectorFromString(@"_chat:sendMessage:");
    BOOL sentViaRegistry = NO;
    if (reg && [reg respondsToSelector:regSend]) {
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(reg, regSend, chat, message);
            sentViaRegistry = YES;
        } @catch (NSException *e) {
            IMBLog(@"IMChatRegistry _chat:sendMessage: threw: %@ — falling back", e.reason);
        }
    }
    if (sentViaRegistry) return safeValue(message, @"guid");

    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(chat, sel, message);
    } @catch (NSException *e) {
        IMBLog(@"sendMessage threw: %@\n%@", e.reason,
               [e.callStackSymbols componentsJoinedByString:@"\n"]);
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"send failed";
        return nil;
    }
    return safeValue(message, @"guid");
}

/// Schedule types IMCore records on a message. 2 is a message the user asked
/// to be delivered later; the store indexes scheduled messages on exactly that
/// value.
static const unsigned long long kIMScheduleTypeSendLater = 2;
static const unsigned long long kIMScheduleStatePending = 0;

/// Schedules a message for later delivery, as the app's Send Later does.
///
/// Unlike an ordinary send, the delivery time is the message's own timestamp:
/// the same initialiser takes both the date and the schedule type, and IMCore
/// holds the message until then.
NSString *IMBSendLater(id chat, NSString *text, NSDate *deliverAt,
                       NSString **errCode, NSString **errMessage) {
    // A conversation that cannot schedule does not refuse the message: it
    // sends it immediately, carrying the future timestamp, which reads as a
    // successful schedule and is not one. Ask first.
    SEL supports = NSSelectorFromString(@"_supportsSendLater");
    if ([chat respondsToSelector:supports]) {
        if (!((BOOL (*)(id, SEL))objc_msgSend)(chat, supports)) {
            if (errCode) *errCode = @"unsupported_feature";
            if (errMessage) *errMessage =
                @"this conversation cannot schedule messages";
            return nil;
        }
    }

    Class msgCls = NSClassFromString(@"IMMessage");

    // IMCore has a factory made for this, which takes the delivery date and
    // fills in the schedule type and state itself. Preferred over building the
    // message by hand: setting those fields on a message whose time is already
    // in the future is the same information stated twice, and IMCore has been
    // seen honouring one and not the other.
    SEL scheduled = NSSelectorFromString(
        @"instantMessageWithText:messageSubject:flags:threadIdentifier:"
         "associatedMessageGUID:scheduledDate:");
    if ([msgCls respondsToSelector:scheduled]) {
        @try {
            id message = ((id (*)(id, SEL, id, id, unsigned long long, id, id, id))objc_msgSend)(
                msgCls, scheduled, attributed(text), nil, kIMMessageFlagsNormal,
                nil, nil, deliverAt);
            if (message) return IMBSendMessage(chat, message, nil, errCode, errMessage);
            IMBLog(@"scheduled factory returned nil; falling back");
        } @catch (NSException *e) {
            IMBLog(@"scheduled factory threw: %@; falling back", e.reason);
        }
    }

    SEL sel = NSSelectorFromString(
        @"initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:"
         "balloonBundleID:payloadData:expressiveSendStyleID:threadIdentifier:scheduleType:"
         "scheduleState:");
    if (![msgCls instancesRespondToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"scheduled sending unavailable on this macOS build";
        return nil;
    }

    @try {
        id message = ((id (*)(id, SEL, id, id, id, id, id, unsigned long long, id, id, id,
                              id, id, id, id, unsigned long long, unsigned long long))objc_msgSend)(
            [msgCls alloc], sel,
            nil,                    // sender: this account
            deliverAt,              // time: when it should go out
            attributed(text),
            nil,                    // messageSubject
            @[],                    // fileTransferGUIDs
            kIMMessageFlagsNormal,
            nil,                    // error
            nil,                    // guid: assigned for us
            nil,                    // subject
            nil,                    // balloonBundleID
            nil,                    // payloadData
            nil,                    // expressiveSendStyleID
            nil,                    // threadIdentifier
            kIMScheduleTypeSendLater,
            kIMScheduleStatePending);
        if (!message) {
            if (errCode) *errCode = @"internal";
            if (errMessage) *errMessage = @"could not build the scheduled message";
            return nil;
        }
        return IMBSendMessage(chat, message, nil, errCode, errMessage);
    } @catch (NSException *e) {
        IMBLog(@"scheduled message construction threw: %@", e.reason);
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"scheduling failed";
        return nil;
    }
}

/// Cancels a message that has not gone out yet.
///
/// The UI's cancel retracts the pending parts rather than flipping a flag:
/// `cancelScheduledMessageItem:cancelType:` returns without complaint and
/// leaves the message scheduled, which looks like success and is not.
BOOL IMBCancelScheduled(id chat, id chatItem, NSString **errCode, NSString **errMessage) {
    SEL retractParts = NSSelectorFromString(@"retractScheduledMessagePartIndexes:fromChatItem:");
    if ([chat respondsToSelector:retractParts]) {
        @try {
            NSIndexSet *parts = [NSIndexSet indexSetWithIndex:0];
            ((void (*)(id, SEL, id, id))objc_msgSend)(chat, retractParts, parts, chatItem);
            return YES;
        } @catch (NSException *e) {
            IMBLog(@"retractScheduledMessagePartIndexes threw: %@", e.reason);
        }
    }

    SEL sel = NSSelectorFromString(@"cancelScheduledMessageItem:cancelType:");
    if (![chat respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"cancelling scheduled messages unavailable";
        return NO;
    }
    id item = safeValue(chatItem, @"_item") ?: chatItem;
    @try {
        ((void (*)(id, SEL, id, unsigned long long))objc_msgSend)(chat, sel, item, 1);
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"cancelScheduledMessageItem threw: %@", e.reason);
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"cancel failed";
        return NO;
    }
}

/// Sends an app-extension balloon: a poll, or anything else carried as a
/// plugin payload rather than as text.
///
/// The same factory that carries attachments and an effect also takes a
/// balloon identifier and its payload, so a plugin message is an ordinary send
/// with those two fields filled in. `summary` is the line shown wherever the
/// balloon cannot be drawn — a notification, a reply preview.
NSString *IMBSendPluginMessage(id chat, NSString *bundleID, NSData *payload,
                               NSString *summary,
                               NSString **errCode, NSString **errMessage) {
    Class msgCls = NSClassFromString(@"IMMessage");
    SEL sel = NSSelectorFromString(
        @"instantMessageWithText:messageSubject:fileTransferGUIDs:flags:balloonBundleID:"
         "payloadData:expressiveSendStyleID:");
    if (![msgCls respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"plugin messages unavailable on this macOS build";
        return nil;
    }

    @try {
        id built = ((id (*)(id, SEL, id, id, id, unsigned long long, id, id, id))objc_msgSend)(
            msgCls, sel, attributed(summary ?: @""), nil, @[],
            kIMMessageFlagsNormal, bundleID, payload, nil);
        if (!built) {
            if (errCode) *errCode = @"internal";
            if (errMessage) *errMessage = @"could not build the plugin message";
            return nil;
        }
        return IMBSendMessage(chat, built, nil, errCode, errMessage);
    } @catch (NSException *e) {
        IMBLog(@"plugin message construction threw: %@", e.reason);
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"plugin send failed";
        return nil;
    }
}

/// Finds or starts a conversation with the given people.
///
/// IMCore has no separate "create": asking the registry for the chat with a set
/// of handles returns the existing one if there is one and mints it if there is
/// not. Nothing is sent, and nobody is notified, until a message goes out — a
/// conversation with no messages is local to this Mac.
id IMBCreateChat(NSArray<NSString *> *handleIDs, NSString *name,
                 NSString **errCode, NSString **errMessage) {
    Class registryCls = NSClassFromString(@"IMChatRegistry");
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    if (![registryCls respondsToSelector:sharedSel]) {
        if (errCode) *errCode = @"not_ready";
        if (errMessage) *errMessage = @"IMChatRegistry unavailable";
        return nil;
    }

    NSMutableArray *handles = [NSMutableArray array];
    for (NSString *handleID in handleIDs) {
        id handle = IMBLookupHandle(handleID);
        if (!handle) {
            if (errCode) *errCode = @"bad_request";
            if (errMessage) *errMessage = [NSString stringWithFormat:
                @"could not resolve '%@' to a handle", handleID];
            return nil;
        }
        [handles addObject:handle];
    }
    if (!handles.count) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = @"no handles to start a conversation with";
        return nil;
    }

    id registry = ((id (*)(id, SEL))objc_msgSend)(registryCls, sharedSel);
    @try {
        // One person is a direct message rather than a one-person group, and
        // IMCore models those differently: the group factory on a single handle
        // produces a chat the app will not thread with the existing DM.
        if (handles.count == 1 && !name.length) {
            SEL sel = NSSelectorFromString(@"chatForIMHandle:");
            if ([registry respondsToSelector:sel]) {
                return ((id (*)(id, SEL, id))objc_msgSend)(registry, sel, handles[0]);
            }
        }
        SEL sel = NSSelectorFromString(@"chatForIMHandles:chatName:");
        if ([registry respondsToSelector:sel]) {
            return ((id (*)(id, SEL, id, id))objc_msgSend)(registry, sel, handles, name);
        }
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"starting a conversation is unavailable on this build";
        return nil;
    } @catch (NSException *e) {
        IMBLog(@"chat creation threw: %@", e.reason);
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = e.reason ?: @"could not start the conversation";
        return nil;
    }
}

/// Removes messages from this Mac.
///
/// This is a local delete, not an unsend: the recipient keeps their copy and is
/// told nothing. It is what the app's own Delete does, and it is not
/// recoverable through this API.
BOOL IMBDeleteMessages(id chat, NSArray *chatItems, NSString **errCode, NSString **errMessage) {
    SEL sel = NSSelectorFromString(@"deleteChatItems:");
    if (![chat respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"deleting messages is unavailable on this build";
        return NO;
    }
    if (!chatItems.count) {
        if (errCode) *errCode = @"message_not_found";
        if (errMessage) *errMessage = @"none of those messages are in this conversation";
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(chat, sel, chatItems);
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"deleteChatItems threw: %@", e.reason);
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = e.reason ?: @"deleting failed";
        return NO;
    }
}

/// Casts a vote in an existing poll.
///
/// A vote is two things at once — an app-extension balloon carrying the choice,
/// and an association pointing at the poll — and only one factory takes both:
/// `customAcknowledgementMessageWithPayloadData:…`, IMCore's route for a plugin
/// acknowledging another message. The ordinary plugin factory has nowhere to
/// put the association, and the association factory has nowhere to put the
/// payload; either one alone produces a message that sends and is never counted.
///
/// The association names the poll's GUID bare, with none of the `p:0/` or `bp:`
/// prefixes a reaction uses, and the type is 4000.
NSString *IMBSendPollVote(id chat, NSString *pollGUID, NSData *payload,
                          NSString **errCode, NSString **errMessage) {
    Class msgCls = NSClassFromString(@"IMMessage");
    SEL sel = NSSelectorFromString(
        @"customAcknowledgementMessageWithPayloadData:associatedMessageGUID:"
         "balloonBundleID:messageSummaryInfo:threadIdentifier:");
    if (![msgCls respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"poll voting unavailable on this macOS build";
        return nil;
    }

    // What the notification says, and which plugin drew the thing being voted
    // in. Real votes carry exactly these.
    NSDictionary *summaryInfo = @{
        @"amc": @9,
        @"amd": @"Polls",
        @"ams": @"Sent a vote",
        @"amb": IMBPollBundleID,
    };

    @try {
        id built = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
            msgCls, sel, payload, pollGUID, IMBPollBundleID, summaryInfo, nil);
        if (!built) {
            if (errCode) *errCode = @"internal";
            if (errMessage) *errMessage = @"could not build the vote";
            return nil;
        }

        // The factory does not take an association type, and the default is not
        // the one a vote uses. Setting it is what the store reads back as 4000
        // — without it the vote lands as an unrecognised association and no
        // tally moves.
        SEL setType = NSSelectorFromString(@"_associatedMessageType:");
        if ([built respondsToSelector:setType]) {
            ((void (*)(id, SEL, long long))objc_msgSend)(built, setType, 4000);
        }
        return IMBSendMessage(chat, built, nil, errCode, errMessage);
    } @catch (NSException *e) {
        IMBLog(@"vote construction threw: %@", e.reason);
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"vote send failed";
        return nil;
    }
}

// ---------------------------------------------------------------------------
// Attachments
// ---------------------------------------------------------------------------

/// Asks Messages to fetch attachments that are not cached locally, so their
/// `localPath` becomes readable.
BOOL IMBDownloadAttachments(id chat) {
    SEL sel = NSSelectorFromString(@"downloadPurgedAttachments");
    if (![chat respondsToSelector:sel]) return NO;
    @try {
        ((void (*)(id, SEL))objc_msgSend)(chat, sel);
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"downloadPurgedAttachments threw: %@", e.reason);
        return NO;
    }
}

// ---------------------------------------------------------------------------
// Tapback
// ---------------------------------------------------------------------------

/// Maps a tapback name to IMCore's acknowledgment type.
///
/// Adding uses 2000-2006; removing the same reaction uses 3000-3006. The kind
/// "emoji" is the custom-emoji reaction the emoji and Genmoji pickers send: it
/// carries a character rather than being described by its code alone, so it
/// needs an emoji alongside it and travels a different route to the others.
long long IMBTapbackType(NSString *kind, BOOL remove, BOOL *ok) {
    NSDictionary<NSString *, NSNumber *> *kinds = @{
        @"love": @2000, @"like": @2001, @"dislike": @2002,
        @"laugh": @2003, @"emphasize": @2004, @"question": @2005,
        @"emoji": @2006,
    };
    NSNumber *base = kinds[[kind lowercaseString]];
    if (!base) { if (ok) *ok = NO; return 0; }
    if (ok) *ok = YES;
    return base.longLongValue + (remove ? 1000 : 0);
}

/// Presents an IMCore chat item the way ChatKit's items look.
///
/// `sendMessageAcknowledgment:forChatItem:` is the path the UI itself uses, but
/// it is written against ChatKit's chat items: it asks its argument for
/// `IMChatItem` (the accessor returning the underlying IMCore item) and for
/// `isEditedMessageHistory`. IMCore's own `chatItems` answer neither, which is
/// what made every earlier attempt fail.
///
/// This proxy answers those two and forwards everything else — `messageItem`,
/// `index` and the rest — to the real item, so IMCore receives exactly the
/// object it expects and does the sending itself.
@interface IMBChatItemAdapter : NSProxy
@property (nonatomic, strong) id item;
@property (nonatomic, strong) id storage;
@end

@implementation IMBChatItemAdapter

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSString *name = NSStringFromSelector(sel);
    if ([name isEqualToString:@"IMChatItem"]) {
        return [NSMethodSignature signatureWithObjCTypes:"@@:"];
    }
    if ([name isEqualToString:@"isEditedMessageHistory"]) {
        return [NSMethodSignature signatureWithObjCTypes:"B@:"];
    }
    NSMethodSignature *signature = [self.item methodSignatureForSelector:sel];
    return signature ?: [self.storage methodSignatureForSelector:sel];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    NSString *name = NSStringFromSelector(invocation.selector);

    if ([name isEqualToString:@"IMChatItem"]) {
        id value = self.item;
        [invocation setReturnValue:&value];
        return;
    }
    if ([name isEqualToString:@"isEditedMessageHistory"]) {
        BOOL no = NO;
        [invocation setReturnValue:&no];
        return;
    }
    if ([self.item respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:self.item];
        return;
    }
    if ([self.storage respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:self.storage];
        return;
    }
    IMBLog(@"tapback adapter has no answer for %@", name);
}

- (BOOL)respondsToSelector:(SEL)sel {
    NSString *name = NSStringFromSelector(sel);
    if ([name isEqualToString:@"IMChatItem"] ||
        [name isEqualToString:@"isEditedMessageHistory"]) return YES;
    return [self.item respondsToSelector:sel] || [self.storage respondsToSelector:sel];
}

- (Class)class { return [self.item class]; }
- (NSString *)description { return [self.item description]; }

/// Answers to the ChatKit name for the wrapped item as well as its own.
///
/// Before writing the reaction, IMCore asks the item what sort of part it is —
/// `CKTextMessagePartChatItem`, `CKAttachmentMessagePartChatItem`,
/// `CKTranscriptPluginChatItem` — to build the summary that a notification
/// quotes. An IMCore item is none of those, so every answer was no and the
/// summary came out empty: the reaction landed on the right message but read as
/// "Laughed at an attachment" instead of quoting the text.
///
/// ChatKit's items are named for IMCore's with a different prefix, so the
/// equivalent name is derived rather than hard-coded per class.
- (BOOL)isKindOfClass:(Class)cls {
    if ([self.item isKindOfClass:cls]) return YES;

    NSString *mine = NSStringFromClass([self.item class]);
    if (![mine hasPrefix:@"IM"]) return NO;
    NSString *chatKitName = [@"CK" stringByAppendingString:[mine substringFromIndex:2]];
    return [NSStringFromClass(cls) isEqualToString:chatKitName];
}

@end

/// Works out what a reaction has to say about the message it attaches to.
///
/// Both routes below need the same four answers, and each one was a source of
/// silently dropped reactions before it was right: the part GUID naming the
/// target, the range of text the reaction covers, the summary a notification
/// quotes, and the thread IMCore files the reaction under.
static BOOL tapbackTarget(id chatItem, NSString **partGUID, NSRange *range,
                          NSDictionary **summary, NSString **thread,
                          NSString **errCode, NSString **errMessage) {
    // Tapbacks target a message *part*, addressed as "p:<index>/<message GUID>".
    id message = IMBUnderlyingMessage(chatItem) ?: chatItem;
    NSString *targetGUID = safeValue(message, @"guid");
    if (!targetGUID) {
        if (errCode) *errCode = @"message_not_found";
        if (errMessage) *errMessage = @"could not resolve the target message";
        return NO;
    }
    *partGUID = [NSString stringWithFormat:@"p:0/%@", targetGUID];

    // Real tapbacks record the range of the text they attach to; an empty
    // range is silently rejected rather than stored.
    NSString *targetText = nil;
    id targetBody = safeValue(message, @"text");
    if ([targetBody isKindOfClass:[NSAttributedString class]]) {
        targetText = [(NSAttributedString *)targetBody string];
    } else if ([targetBody isKindOfClass:[NSString class]]) {
        targetText = targetBody;
    }
    *range = NSMakeRange(0, targetText.length);

    // Every real tapback carries a summary of the message it reacts to, and
    // that is what was missing when earlier attempts sent cleanly and stored
    // nothing: without it the reaction is built, handed over, and dropped.
    //
    //   amc — the count of message parts summarised, always 1 here
    //   ams — the target's text, which is what the UI quotes in a notification
    //   ampt — the same text attributed, which only Messages can archive
    //   ust — set on every summary Messages writes
    //
    // Messages builds this itself from the chat item, and asking it to is the
    // only way to get `ampt`: the value is an archived attributed string, and
    // a hand-built summary carries the plain `ams` alone. It is a ChatKit
    // category on IMChat, so it wants a ChatKit-shaped item, which the proxy
    // above already answers for.
    NSDictionary *built = nil;
    SEL configureSel = NSSelectorFromString(@"configureMessageSummaryInfoForChatItem:");
    Class chatCls = NSClassFromString(@"IMChat");
    if ([chatCls respondsToSelector:configureSel]) {
        IMBChatItemAdapter *adapter = [IMBChatItemAdapter alloc];
        adapter.item = chatItem;
        adapter.storage = safeValue(chatItem, @"_item");
        @try {
            id result = ((id (*)(id, SEL, id))objc_msgSend)(chatCls, configureSel, adapter);
            if ([result isKindOfClass:[NSDictionary class]] && [result count]) {
                built = result;
            }
        } @catch (NSException *e) {
            IMBLog(@"configureMessageSummaryInfoForChatItem threw: %@", e.reason);
        }
    }

    *summary = built ?: @{
        @"amc": @1,
        @"ams": targetText ?: @"",
        @"ust": @YES,
    };

    // IMCore computes the thread identifier a tapback needs; it is not the
    // target's own threadIdentifier, which is what earlier attempts sent.
    id threadForTapback = safeValue(chatItem, @"threadIdentifierForTapback");
    if (![threadForTapback isKindOfClass:[NSString class]]) {
        threadForTapback = safeValue(message, @"threadIdentifier");
    }
    *thread = [threadForTapback isKindOfClass:[NSString class]] ? threadForTapback : nil;
    return YES;
}

/// Sends a reaction the way IMCore models one: as an object rather than a
/// number.
///
/// This is the only route a custom-emoji reaction has. The acknowledgment API
/// is addressed entirely by type code and no code carries a character, so an
/// emoji has nowhere to travel: the variant whose name suggests otherwise,
/// `…forChatItem:languageIdentifier:`, takes a BCP-47 language for localising
/// the notification, and passing an emoji there returns a GUID and stores
/// nothing. Nor does hand-building the message work, as it does for the
/// classic kinds — a 2006 built that way is dropped just as quietly.
///
/// `IMTapback` has a subclass per family: IMEmojiTapback carries a character,
/// IMClassicTapback one of the named six. Either is handed to IMTapbackSender,
/// which is what Messages itself uses. The sender wants IMCore's own values
/// throughout, so no ChatKit item is involved and the proxy above is not needed
/// here; it also asks the tapback to adjust the summary for sending, which is
/// what writes the character into the copy the recipient sees.
static BOOL sendViaTapbackSender(id chat, id chatItem, long long type, NSString *emoji,
                                 NSString **errCode, NSString **errMessage) {
    Class tapbackCls = NSClassFromString(emoji ? @"IMEmojiTapback" : @"IMClassicTapback");
    Class senderCls = NSClassFromString(@"IMTapbackSender");
    SEL initTapback = emoji ? NSSelectorFromString(@"initWithEmoji:isRemoved:")
                            : NSSelectorFromString(@"initWithAssociatedMessageType:");
    SEL initSender = NSSelectorFromString(
        @"initWithTapback:chat:messageGUID:messagePartRange:messageSummaryInfo:"
         "threadIdentifier:");
    SEL sendSel = NSSelectorFromString(@"send");
    if (![tapbackCls instancesRespondToSelector:initTapback] ||
        ![senderCls instancesRespondToSelector:initSender] ||
        ![senderCls instancesRespondToSelector:sendSel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = emoji
            ? @"emoji reactions unavailable on this macOS build"
            : @"tapbacks unavailable on this macOS build";
        return NO;
    }

    NSString *partGUID = nil, *thread = nil;
    NSDictionary *summary = nil;
    NSRange range = NSMakeRange(0, 0);
    if (!tapbackTarget(chatItem, &partGUID, &range, &summary, &thread,
                       errCode, errMessage)) {
        return NO;
    }

    @try {
        // An emoji reaction is removed by rebuilding it with its removed flag
        // set, which is what turns the 2006 into a 3006; a classic one carries
        // the removal in the type code it is built from.
        id tapback = emoji
            ? ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
                  [tapbackCls alloc], initTapback, emoji, type >= 3000)
            : ((id (*)(id, SEL, long long))objc_msgSend)(
                  [tapbackCls alloc], initTapback, type);
        if (!tapback) {
            if (errCode) *errCode = @"internal";
            if (errMessage) *errMessage = @"could not build the reaction";
            return NO;
        }

        id sender = ((id (*)(id, SEL, id, id, id, NSRange, id, id))objc_msgSend)(
            [senderCls alloc], initSender, tapback, chat, partGUID, range, summary,
            thread);
        if (!sender) {
            if (errCode) *errCode = @"internal";
            if (errMessage) *errMessage = @"could not build the reaction sender";
            return NO;
        }

        if (((id (*)(id, SEL))objc_msgSend)(sender, sendSel)) return YES;
        IMBLog(@"tapback sender returned nothing");
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = @"Messages did not accept the reaction";
        return NO;
    } @catch (NSException *e) {
        IMBLog(@"tapback sender threw: %@", e.reason);
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"reaction failed";
        return NO;
    }
}

/// Sends a tapback through the acknowledgment API the UI uses.
///
/// Building an associated message and sending it normally — the obvious route,
/// and what this did before — is accepted without complaint and then dropped:
/// nothing reaches the store and nothing reaches the recipient. IMCore's own
/// acknowledgment path does land, and only needs its argument adapted.
///
/// Custom-emoji reactions cannot go this way at all; see sendViaTapbackSender.
///
/// Which is why the acknowledgment path is no longer the primary route. It has
/// a failure of its own — on some messages it returns a GUID and stores
/// nothing, reproducibly and across restarts, the same silent success it was
/// adopted to cure — and because it reports success, nothing after it ever
/// runs. IMCore's tapback objects store on exactly those messages, and now
/// that the summary is built by Messages rather than by hand they store the
/// same `ampt` too, so there is nothing left that the acknowledgment path did
/// better. It stays as the first fallback rather than the first choice.
BOOL IMBSendTapback(id chat, id chatItem, long long type, NSString *emoji,
                    NSString **errCode, NSString **errMessage) {
    // Errors from the attempts that have something after them are dropped: a
    // caller only needs to hear about a failure that was not recovered from.
    if (sendViaTapbackSender(chat, chatItem, type, emoji,
                             emoji ? errCode : NULL, emoji ? errMessage : NULL)) {
        return YES;
    }
    // No other route can carry a character, so there is nothing to fall back to.
    if (emoji) return NO;

    SEL ackSel = NSSelectorFromString(@"sendMessageAcknowledgment:forChatItem:");
    if ([chat respondsToSelector:ackSel]) {
        IMBChatItemAdapter *adapter = [IMBChatItemAdapter alloc];
        adapter.item = chatItem;
        adapter.storage = safeValue(chatItem, @"_item");

        @try {
            id guid = ((id (*)(id, SEL, long long, id))objc_msgSend)(
                chat, ackSel, type, adapter);
            if (guid) return YES;
            IMBLog(@"acknowledgment returned no guid");
        } @catch (NSException *e) {
            IMBLog(@"sendMessageAcknowledgment threw: %@", e.reason);
        }
        // Fall through, so a build whose acknowledgment path differs still has
        // something to try.
    }

    Class msgCls = NSClassFromString(@"IMMessage");
    SEL sel = NSSelectorFromString(
        @"instantMessageWithAssociatedMessageContent:associatedMessageGUID:associatedMessageType:"
         "associatedMessageRange:associatedMessageEmoji:messageSummaryInfo:threadIdentifier:");
    if (![msgCls respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"tapbacks unavailable on this macOS build";
        return NO;
    }

    NSString *partGUID = nil, *threadForTapback = nil;
    NSDictionary *summary = nil;
    NSRange range = NSMakeRange(0, 0);
    if (!tapbackTarget(chatItem, &partGUID, &range, &summary, &threadForTapback,
                       errCode, errMessage)) {
        return NO;
    }

    @try {
        id tapback = ((id (*)(id, SEL, id, id, long long, NSRange, id, id, id))objc_msgSend)(
            msgCls, sel, nil, partGUID, type, range, nil, summary,
            threadForTapback);
        if (!tapback) {
            if (errCode) *errCode = @"internal";
            if (errMessage) *errMessage = @"could not build tapback";
            return NO;
        }
        return IMBSendMessage(chat, tapback, nil, errCode, errMessage) != nil;
    } @catch (NSException *e) {
        IMBLog(@"tapback construction threw: %@", e.reason);
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"tapback failed";
        return NO;
    }
}

/// Sticks a sticker onto an existing bubble, as peel-and-stick does.
///
/// A stuck sticker is not a message with a picture in it: it is an *associated*
/// message, addressed the same way a tapback is — "p:<part>/<guid>" plus the
/// range it covers — carrying type 1000 and a sticker transfer. Reading the
/// nine of them in this machine's store is what settled the shape; the code is
/// nowhere in a header.
///
/// The one factory that takes both a transfer list and the association triple
/// is the long initialiser; every convenience method drops one or the other,
/// which is the same trap the ordinary send path documents.
NSString *IMBSendStuckSticker(id chat, id chatItem, NSArray<NSString *> *transferGUIDs,
                              NSString **errCode, NSString **errMessage) {
    Class msgCls = NSClassFromString(@"IMMessage");
    SEL sel = NSSelectorFromString(
        @"initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:"
         "associatedMessageGUID:associatedMessageType:associatedMessageRange:"
         "messageSummaryInfo:threadIdentifier:");
    if (![msgCls instancesRespondToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"sticking a sticker to a message is unavailable";
        return nil;
    }

    NSString *partGUID = nil, *thread = nil;
    NSDictionary *summary = nil;
    NSRange range = NSMakeRange(0, 0);
    if (!tapbackTarget(chatItem, &partGUID, &range, &summary, &thread, errCode, errMessage)) {
        return nil;
    }

    // The body is the placeholder run the transfer hangs off, exactly as an
    // ordinary attachment send needs; without it the parts split inconsistently
    // and the bubble draws blank.
    NSAttributedString *body = attributedWithAttachments(nil, transferGUIDs);

    @try {
        id sticker = ((id (*)(id, SEL, id, id, id, id, id, unsigned long long, id, id, id,
                              id, long long, NSRange, id, id))objc_msgSend)(
            [msgCls alloc], sel, nil, nil, body, nil, transferGUIDs,
            kIMMessageFlagsNormal, nil, nil, nil,
            partGUID, kIMStickerAssociationType, range, summary, thread);
        if (!sticker) {
            if (errCode) *errCode = @"internal";
            if (errMessage) *errMessage = @"could not build the sticker message";
            return nil;
        }
        return IMBSendMessage(chat, sticker, nil, errCode, errMessage);
    } @catch (NSException *e) {
        IMBLog(@"stuck sticker construction threw: %@", e.reason);
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"sticking the sticker failed";
        return nil;
    }
}

// ---------------------------------------------------------------------------
// Retract and edit
// ---------------------------------------------------------------------------

BOOL IMBRetract(id chat, id chatItem, NSString **errCode, NSString **errMessage) {
    SEL sel = NSSelectorFromString(@"retractMessagePart:");
    if (![chat respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"unsend unavailable on this macOS build";
        return NO;
    }
    // Pass the display item: retract asks its argument for `messageItem`,
    // which the unwrapped storage item does not answer.
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(chat, sel, chatItem);
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"retractMessagePart threw: %@", e.reason);
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"unsend failed";
        return NO;
    }
}

BOOL IMBEdit(id chat, id chatItem, long long partIndex, NSString *newText,
             NSString **errCode, NSString **errMessage) {
    SEL sel = NSSelectorFromString(
        @"editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText:");
    if (![chat respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"edit unavailable on this macOS build";
        return NO;
    }

    // The edit API operates on the storage item, not the display item. The
    // translation argument is not an attributed string — passing one makes
    // IMCore ask it for a dictionaryRepresentation and throw.
    id item = safeValue(chatItem, @"_item") ?: chatItem;
    NSAttributedString *body = attributed(newText);
    @try {
        ((void (*)(id, SEL, id, long long, id, id, id))objc_msgSend)(
            chat, sel, item, partIndex, body, nil, newText);
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"editMessageItem threw: %@", e.reason);
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"edit failed";
        return NO;
    }
}

BOOL IMBMarkRead(id chat) {
    SEL sel = NSSelectorFromString(@"markAllMessagesAsRead");
    if (![chat respondsToSelector:sel]) return NO;
    @try {
        ((void (*)(id, SEL))objc_msgSend)(chat, sel);
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"markAllMessagesAsRead threw: %@", e.reason);
        return NO;
    }
}

// ---------------------------------------------------------------------------
// Group management
// ---------------------------------------------------------------------------

/// Wraps handle strings in IMHandle objects bound to the active account, which
/// is what the participant APIs expect.
static NSArray *handlesForIDs(NSArray<NSString *> *ids) {
    Class controllerCls = NSClassFromString(@"IMAccountController");
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    if (![controllerCls respondsToSelector:sharedSel]) return nil;

    id controller = ((id (*)(id, SEL))objc_msgSend)(controllerCls, sharedSel);
    id account = safeValue(controller, @"activeIMessageAccount")
              ?: safeValue(controller, @"activeAccount");
    if (!account) return nil;

    Class handleCls = NSClassFromString(@"IMHandle");
    SEL initSel = NSSelectorFromString(@"initWithAccount:ID:alreadyCanonical:");
    if (!handleCls || ![handleCls instancesRespondToSelector:initSel]) return nil;

    NSMutableArray *out = [NSMutableArray array];
    for (NSString *hid in ids) {
        @try {
            id handle = [handleCls alloc];
            handle = ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                handle, initSel, account, hid, YES);
            if (handle) [out addObject:handle];
        } @catch (NSException *e) {
            IMBLog(@"handle creation threw for %@: %@", hid, e.reason);
        }
    }
    return out.count ? out : nil;
}

BOOL IMBGroupRename(id chat, NSString *name, NSString **errCode, NSString **errMessage) {
    SEL sel = NSSelectorFromString(@"setDisplayName:");
    if (![chat respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"rename unavailable";
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(chat, sel, name);
        return YES;
    } @catch (NSException *e) {
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"rename failed";
        return NO;
    }
}

/// Whether IMCore will act on a membership change, asked before making it.
///
/// Both membership calls return void and both are willing to do nothing:
/// removing below the three-person floor reports success and leaves the group
/// untouched, which reads as a change that happened. IMCore knows the answer
/// in advance — `canAddParticipants:` and `canRemoveParticipants:` are what the
/// app asks before it enables the menu item — so the refusal can be a refusal
/// rather than a silent no-op discovered by reading the group back.
///
/// A build without the check answers YES: the call is no worse off than it was
/// before, and refusing on a missing selector would break a working operation.
BOOL IMBGroupChangeAllowed(id chat, BOOL adding, NSArray<NSString *> *ids,
                           NSString **errCode, NSString **errMessage) {
    NSString *selName = adding ? @"canAddParticipants:" : @"canRemoveParticipants:";
    if (![chat respondsToSelector:NSSelectorFromString(selName)]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"this build cannot say in advance";
        return NO;
    }
    NSArray *handles = handlesForIDs(ids);
    if (!handles) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = @"could not resolve those handles";
        return NO;
    }
    @try {
        return ((BOOL (*)(id, SEL, id))objc_msgSend)(chat, NSSelectorFromString(selName), handles);
    } @catch (NSException *e) {
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = e.reason ?: @"could not ask";
        return NO;
    }
}

static BOOL groupChangeAllowed(id chat, NSString *selName, NSArray *handles) {
    SEL sel = NSSelectorFromString(selName);
    if (![chat respondsToSelector:sel]) return YES;
    @try {
        return ((BOOL (*)(id, SEL, id))objc_msgSend)(chat, sel, handles);
    } @catch (NSException *e) {
        IMBLog(@"%@ threw: %@", selName, e.reason);
        return YES;
    }
}

BOOL IMBGroupAddMembers(id chat, NSArray<NSString *> *ids,
                        NSString **errCode, NSString **errMessage) {
    SEL sel = NSSelectorFromString(@"_addParticipants:withState:");
    if (![chat respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"adding members unavailable";
        return NO;
    }
    NSArray *handles = handlesForIDs(ids);
    if (!handles) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = @"could not resolve those handles";
        return NO;
    }
    if (!groupChangeAllowed(chat, @"canAddParticipants:", handles)) {
        if (errCode) *errCode = @"refused";
        if (errMessage) *errMessage =
            @"this conversation will not take those participants — an SMS group, "
             "one you have left, or an address that cannot be added";
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id, unsigned long long))objc_msgSend)(chat, sel, handles, 0);
        return YES;
    } @catch (NSException *e) {
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"adding members failed";
        return NO;
    }
}

BOOL IMBGroupRemoveMembers(id chat, NSArray<NSString *> *ids,
                           NSString **errCode, NSString **errMessage) {
    SEL sel = NSSelectorFromString(@"removeParticipants:reason:");
    if (![chat respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"removing members unavailable";
        return NO;
    }
    NSArray *handles = handlesForIDs(ids);
    if (!handles) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = @"could not resolve those handles";
        return NO;
    }
    // The floor is three people: removing anyone from a group of three would
    // leave two, and IMCore declines rather than turning it into a 1:1. It
    // declines by doing nothing and saying nothing, so this is the difference
    // between a reported refusal and a caller believing the group changed.
    if (!groupChangeAllowed(chat, @"canRemoveParticipants:", handles)) {
        if (errCode) *errCode = @"refused";
        if (errMessage) *errMessage =
            @"this conversation will not give up those participants — usually a "
             "group that would drop below three people";
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(chat, sel, handles, nil);
        return YES;
    } @catch (NSException *e) {
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"removing members failed";
        return NO;
    }
}

/// Removes the conversation itself, as deleting it in the app does.
///
/// Distinct from emptying it: `deleteAllHistory` leaves the conversation in the
/// list with no messages in it, which is not what a person means by deleting a
/// chat. Both are local — the other party keeps their copy either way.
BOOL IMBDeleteChat(id chat, NSString **errCode, NSString **errMessage) {
    SEL sel = NSSelectorFromString(@"remove");
    if (![chat respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"deleting a conversation unavailable";
        return NO;
    }
    @try {
        ((void (*)(id, SEL))objc_msgSend)(chat, sel);
        return YES;
    } @catch (NSException *e) {
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"deleting the conversation failed";
        return NO;
    }
}

/// Sends this account's Name & Photo to someone, as tapping Share does.
///
/// Reading the cards other people have shared is one thing; handing over your
/// own name and picture is a disclosure, so this exists to be called when a
/// person asks for it and not as a side effect of anything else.
BOOL IMBShareNameAndPhoto(NSString *handleID, NSString **errCode, NSString **errMessage) {
    Class controllerCls = NSClassFromString(@"IMNicknameController");
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    SEL sendSel = NSSelectorFromString(@"sendPersonalNicknameToHandle:");
    if (!controllerCls || ![controllerCls respondsToSelector:sharedSel] ||
        ![controllerCls instancesRespondToSelector:sendSel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"sharing your Name & Photo unavailable";
        return NO;
    }

    NSArray *handles = handlesForIDs(@[handleID]);
    if (!handles.count) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = @"could not resolve that handle";
        return NO;
    }

    id controller = ((id (*)(id, SEL))objc_msgSend)(controllerCls, sharedSel);
    if (!controller) {
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = @"no nickname controller";
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, sendSel, handles.firstObject);
        return YES;
    } @catch (NSException *e) {
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"sharing failed";
        return NO;
    }
}

BOOL IMBGroupLeave(id chat, NSString **errCode, NSString **errMessage) {
    SEL sel = NSSelectorFromString(@"leave");
    if (![chat respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"leaving unavailable";
        return NO;
    }
    @try {
        ((void (*)(id, SEL))objc_msgSend)(chat, sel);
        return YES;
    } @catch (NSException *e) {
        if (errCode) *errCode = @"send_failed";
        if (errMessage) *errMessage = e.reason ?: @"leave failed";
        return NO;
    }
}
