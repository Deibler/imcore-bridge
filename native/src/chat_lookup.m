// Resolving chats, and turning IMCore objects into JSON-safe dictionaries.
#import "bridge.h"
#import <objc/message.h>

/// Sends a zero-argument message and returns the object result, or nil.
static id call0(id target, NSString *selName) {
    if (!target) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, sel);
    } @catch (NSException *e) {
        IMBLog(@"call0 %@ threw: %@", selName, e.reason);
        return nil;
    }
}

static id call1(id target, NSString *selName, id arg) {
    if (!target) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) return nil;
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(target, sel, arg);
    } @catch (NSException *e) {
        IMBLog(@"call1 %@ threw: %@", selName, e.reason);
        return nil;
    }
}

static id registry(void) {
    Class cls = NSClassFromString(@"IMChatRegistry");
    return call0(cls, @"sharedInstance");
}

/// Best-effort KVC read that never throws for a missing key.
static id safeValue(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

// Defined below, used by the lookups that sit above their definitions.
static BOOL addressesMatch(NSString *a, NSString *b);
static NSString *digitsOf(NSString *address);
static NSString *handleID(id handle);

id IMBLookupChat(NSString *identifier) {
    if (identifier.length == 0) return nil;
    id reg = registry();
    if (!reg) return nil;

    // Exact GUID first ("iMessage;-;+15551234567" or "any;-;…").
    id chat = call1(reg, @"existingChatWithGUID:", identifier);
    if (chat) return chat;

    // Then the chat identifier (a bare handle for 1:1, an opaque id for groups).
    chat = call1(reg, @"existingChatWithChatIdentifier:", identifier);
    if (chat) return chat;

    // Finally scan every known chat, matching guid/identifier/participants so a
    // caller can address a conversation by a plain phone number or email.
    // Participant matching is restricted to 1:1 conversations, the same rule
    // IMBLookupChats applies: a handle appearing inside a group does not make
    // that group the chat the caller asked for — a DM addressed by handle must
    // never resolve into a room full of other people.
    NSArray *all = safeValue(reg, @"allExistingChats");
    for (id candidate in all) {
        if ([identifier isEqualToString:safeValue(candidate, @"guid")] ||
            [identifier isEqualToString:safeValue(candidate, @"chatIdentifier")]) {
            return candidate;
        }
        NSArray *participants = safeValue(candidate, @"participants") ?: @[];
        if (participants.count != 1) continue;
        if (addressesMatch(identifier, handleID(participants.firstObject))) return candidate;
    }
    return nil;
}

/// The handle a DM-shaped spec addresses, or nil when the spec does not name
/// one person. "any;-;+1555…" and "iMessage;-;a@b.c" address the handle after
/// the ";-;" (the "-" marks a 1:1; groups use ";+;"); a spec with no
/// service prefix is the handle itself. Group GUIDs and opaque group
/// identifiers return nil — they name rooms, not people.
static NSString *dmSpecHandle(NSString *spec) {
    if (!spec.length) return nil;
    NSRange dm = [spec rangeOfString:@";-;" options:NSBackwardsSearch];
    if (dm.location != NSNotFound) {
        NSString *handle = [spec substringFromIndex:dm.location + dm.length];
        return handle.length ? handle : nil;
    }
    if ([spec containsString:@";"]) return nil; // ";+;" group form, or malformed
    // A bare token is a handle when it looks like one: an email, or a phone
    // number (digits with no letters — "chat869…", a group's opaque
    // identifier, has letters and is a room, not a person).
    if ([spec containsString:@"@"]) return spec;
    for (NSUInteger i = 0; i < spec.length; i++) {
        unichar c = [spec characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) return nil;
    }
    return digitsOf(spec) ? spec : nil;
}

NSString *IMBChatMatchesSpec(NSString *spec, id chat) {
    NSString *addressed = dmSpecHandle(spec);
    if (!addressed) return nil; // group spec, or not handle-shaped — nothing to assert
    NSString *identifier = safeValue(chat, @"chatIdentifier");
    NSArray *participants = safeValue(chat, @"participants");
    if (![participants isKindOfClass:[NSArray class]]) participants = @[];

    // A spec that names one person must land on a 1:1 conversation.
    if (participants.count > 1) {
        return [NSString stringWithFormat:
            @"'%@' addresses one person but resolved to a group of %lu ('%@')",
            spec, (unsigned long)participants.count, identifier ?: @"?"];
    }

    // The conversation is the addressed person's if ANY of its identities
    // match: the identifier, its sole participant, or the routing recipient.
    if ([identifier isKindOfClass:[NSString class]] &&
        IMBAddressesMatch(addressed, identifier)) return nil;
    if (participants.count == 1 &&
        IMBAddressesMatch(addressed, safeValue(participants.firstObject, @"ID"))) return nil;
    NSString *recipient = safeValue(safeValue(chat, @"recipient"), @"ID");
    if ([recipient isKindOfClass:[NSString class]] &&
        IMBAddressesMatch(addressed, recipient)) return nil;

    return [NSString stringWithFormat:
        @"'%@' resolved to a conversation that is not with that address "
        @"(identifier '%@', participant '%@', recipient '%@') — the registry's "
        @"object is wrong, and acting on it would reach the wrong person. "
        @"Restart imagent (`killall imagent`) to rebuild the registry.",
        spec,
        identifier ?: @"?",
        participants.count == 1 ? (safeValue(participants.firstObject, @"ID") ?: @"?") : @"(none)",
        recipient ?: @"?"];
}

static NSString *handleID(id handle);

/// Just the digits of an address, or nil if it does not look like a number.
///
/// The same person's number is written a dozen ways — `+1 (555) 123-4567`,
/// `5551234567`, `+15551234567` — and which one is stored depends on how the
/// conversation started. Comparing digits is what makes "have we ever spoken to
/// this number" answerable; an exact string match answers no to a number the
/// user is mid-conversation with.
static NSString *digitsOf(NSString *address) {
    if ([address containsString:@"@"]) return nil;
    NSMutableString *digits = [NSMutableString stringWithCapacity:address.length];
    for (NSUInteger i = 0; i < address.length; i++) {
        unichar c = [address characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
    }
    // Anything shorter is not a number worth matching on: a three-digit
    // "match" would put unrelated people in the same conversation.
    return digits.length >= 7 ? digits : nil;
}

/// An address with IMCore's type prefix removed — "e:a@b.c" and "a@b.c" are
/// the same address spelled two ways, as are "p:+1555…" and "+1555…". IMCore
/// grows the prefixed spelling as a second handle row, and comparisons that
/// don't strip it treat one person as two.
static NSString *bareAddress(NSString *address) {
    if (address.length > 2 && [address characterAtIndex:1] == ':') {
        unichar c0 = [address characterAtIndex:0];
        if (c0 == 'e' || c0 == 'E' || c0 == 'p' || c0 == 'P') {
            return [address substringFromIndex:2];
        }
    }
    return address;
}

/// Whether two addresses name the same person.
///
/// Type prefixes are stripped first, then exact, then case-insensitively for
/// email, then by national number: two numbers match when one's digits end
/// with the other's, which is what makes a local number and its +1 form the
/// same person without treating every number sharing a suffix as equal — the
/// shorter side has to be a full national number for the comparison to run at
/// all.
BOOL IMBAddressesMatch(NSString *a, NSString *b) {
    if (!a.length || !b.length) return NO;
    a = bareAddress(a);
    b = bareAddress(b);
    if ([a isEqualToString:b]) return YES;
    if ([a caseInsensitiveCompare:b] == NSOrderedSame) return YES;

    NSString *da = digitsOf(a), *db = digitsOf(b);
    if (!da || !db) return NO;
    NSString *longer = da.length >= db.length ? da : db;
    NSString *shorter = da.length >= db.length ? db : da;
    if (shorter.length < 10) return NO;
    return [longer hasSuffix:shorter];
}

static BOOL addressesMatch(NSString *a, NSString *b) {
    return IMBAddressesMatch(a, b);
}

/// Every chat the registry knows, newest conversation first.
static NSArray *allChatsByRecency(void) {
    id reg = registry();
    NSArray *all = safeValue(reg, @"allExistingChats");
    if (![all isKindOfClass:[NSArray class]]) return @[];
    return [all sortedArrayUsingComparator:^NSComparisonResult(id x, id y) {
        id dx = safeValue(x, @"lastFinishedMessageDate");
        id dy = safeValue(y, @"lastFinishedMessageDate");
        NSTimeInterval tx = [dx isKindOfClass:[NSDate class]] ? [dx timeIntervalSince1970] : 0;
        NSTimeInterval ty = [dy isKindOfClass:[NSDate class]] ? [dy timeIntervalSince1970] : 0;
        if (tx == ty) return NSOrderedSame;
        return tx > ty ? NSOrderedAscending : NSOrderedDescending;
    }];
}

NSArray *IMBLookupChats(NSString *identifier) {
    if (identifier.length == 0) return @[];

    // Ordered by last activity, so the first entry is the live one. A DM
    // legitimately maps to more than one conversation — the same person has an
    // iMessage thread and an SMS thread, and which one is current changes with
    // whether they have signal — and picking one silently is how a reply lands
    // in the thread nobody is looking at.
    NSMutableArray *matches = [NSMutableArray array];
    for (id candidate in allChatsByRecency()) {
        NSString *guid = safeValue(candidate, @"guid");
        NSString *chatIdent = safeValue(candidate, @"chatIdentifier");
        if ([identifier isEqualToString:guid] || [identifier isEqualToString:chatIdent]) {
            [matches addObject:candidate];
            continue;
        }
        // Only 1:1 conversations are addressable by a participant: a handle
        // matching someone inside a group does not make that group the chat
        // the caller asked for.
        NSArray *participants = safeValue(candidate, @"participants") ?: @[];
        if (participants.count != 1) continue;
        if (addressesMatch(identifier, handleID(participants.firstObject))) {
            [matches addObject:candidate];
        }
    }
    return matches;
}

NSArray *IMBChatsWithHandle(NSString *handle) {
    if (handle.length == 0) return @[];

    // Every conversation this person appears in, groups included — which is
    // both "have we ever spoken to this address", answered by whether the
    // result is empty, and "what do we share", answered by the groups in it.
    NSMutableArray *matches = [NSMutableArray array];
    for (id candidate in allChatsByRecency()) {
        for (id participant in (NSArray *)safeValue(candidate, @"participants") ?: @[]) {
            if (addressesMatch(handle, handleID(participant))) {
                [matches addObject:candidate];
                break;
            }
        }
    }
    return matches;
}

/// Extracts the plain-text body from an IMMessage or a chat item.
static NSString *messageText(id message) {
    id text = safeValue(message, @"plainBody");
    if ([text isKindOfClass:[NSString class]] && [text length]) return text;

    // `text` is an NSAttributedString on IMMessage but a plain string elsewhere.
    id raw = safeValue(message, @"text");
    if ([raw isKindOfClass:[NSString class]]) return raw;
    if ([raw respondsToSelector:@selector(string)]) return [raw string];

    id body = safeValue(message, @"body");
    if ([body isKindOfClass:[NSString class]]) return body;
    if ([body respondsToSelector:@selector(string)]) return [body string];
    return nil;
}

static NSString *handleID(id handle) {
    if (!handle) return nil;
    if ([handle isKindOfClass:[NSString class]]) return handle;
    id ident = safeValue(handle, @"ID");
    return [ident isKindOfClass:[NSString class]] ? ident : nil;
}

NSDictionary *IMBSerializeMessage(id message, id chat) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    NSString *guid = safeValue(message, @"guid");
    if (guid) out[@"guid"] = guid;

    // The store rowid, so a consumer of the event stream can record where it
    // got to and later ask what it missed. IMCore calls it messageID and fills
    // it in when the message is written to the store, which for something just
    // received can be a moment after the event fires — hence the zero check,
    // and hence this being absent rather than guessed at.
    //
    // Absent is the safe direction: a caller that cannot advance its cursor
    // asks for that message again next time and sees it twice, where a made-up
    // rowid would move the cursor past messages that were never delivered.
    id rowid = safeValue(message, @"messageID");
    if ([rowid respondsToSelector:@selector(longLongValue)] && [rowid longLongValue] > 0) {
        out[@"rowid"] = @([rowid longLongValue]);
    }

    NSString *text = messageText(message);
    if (text) out[@"text"] = text;

    id senderHandle = safeValue(message, @"sender");
    NSString *sender = handleID(senderHandle);
    if (sender) out[@"sender"] = sender;

    // Resolve the handle to a person where Contacts knows one, so callers see
    // a name instead of a bare phone number.
    NSDictionary *senderInfo = IMBHandleInfo(senderHandle);
    if (senderInfo[@"name"]) out[@"senderName"] = senderInfo[@"name"];

    NSArray *attachments = IMBSerializeAttachments(message);
    if (attachments.count) out[@"attachments"] = attachments;

    id fromMe = safeValue(message, @"isFromMe");
    out[@"isFromMe"] = [fromMe respondsToSelector:@selector(boolValue)]
                     ? @([fromMe boolValue]) : @NO;

    id subject = safeValue(message, @"subject");
    if ([subject isKindOfClass:[NSString class]] && [subject length]) {
        out[@"subject"] = subject;
    }

    NSString *thread = safeValue(message, @"threadIdentifier");
    if (thread.length) out[@"threadIdentifier"] = thread;

    id date = safeValue(message, @"time");
    if ([date isKindOfClass:[NSDate class]]) {
        out[@"time"] = @([(NSDate *)date timeIntervalSince1970]);
    }

    // Bubble state a person reads off the UI: Delivered / Read / Played.
    struct { NSString *key; NSString *out; } flags[] = {
        { @"isDelivered", @"isDelivered" },
        { @"isRead",      @"isRead" },
        { @"isSent",      @"isSent" },
        { @"isPlayed",    @"isPlayed" },
        { @"hasMention",  @"hasMention" },
    };
    for (size_t i = 0; i < sizeof(flags)/sizeof(flags[0]); i++) {
        id v = safeValue(message, flags[i].key);
        if ([v respondsToSelector:@selector(boolValue)] && [v boolValue]) {
            out[flags[i].out] = @YES;
        }
    }

    struct { NSString *key; NSString *out; } stamps[] = {
        { @"timeDelivered", @"timeDelivered" },
        { @"timeRead",      @"timeRead" },
        { @"timePlayed",    @"timePlayed" },
    };
    for (size_t i = 0; i < sizeof(stamps)/sizeof(stamps[0]); i++) {
        id v = safeValue(message, stamps[i].key);
        // IMCore uses the zero date for "never", which would read as 1970.
        if ([v isKindOfClass:[NSDate class]] && [(NSDate *)v timeIntervalSince1970] > 0) {
            out[stamps[i].out] = @([(NSDate *)v timeIntervalSince1970]);
        }
    }

    // The message this one replies to, so a caller can rebuild the thread.
    id originator = safeValue(message, @"threadOriginator");
    NSString *originatorGUID = safeValue(originator, @"guid");
    if (originatorGUID) out[@"replyToGUID"] = originatorGUID;

    id err = safeValue(message, @"error");
    if ([err respondsToSelector:@selector(longLongValue)] && [err longLongValue] != 0) {
        out[@"error"] = @([err longLongValue]);
    }

    // Tapbacks arrive as associated messages rather than as their own text.
    id assocType = safeValue(message, @"associatedMessageType");
    if ([assocType respondsToSelector:@selector(longLongValue)] &&
        [assocType longLongValue] != 0) {
        out[@"associatedMessageType"] = @([assocType longLongValue]);
        NSString *assocGuid = safeValue(message, @"associatedMessageGUID");
        if (assocGuid) out[@"associatedMessageGUID"] = assocGuid;
    }

    if (chat) {
        NSString *chatGuid = safeValue(chat, @"guid");
        if (chatGuid) out[@"chatGUID"] = chatGuid;
        NSString *chatId = safeValue(chat, @"chatIdentifier");
        if (chatId) out[@"chatIdentifier"] = chatId;
    }
    return out;
}

NSDictionary *IMBSerializeChat(id chat) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *guid = safeValue(chat, @"guid");
    if (guid) out[@"guid"] = guid;
    NSString *ident = safeValue(chat, @"chatIdentifier");
    if (ident) out[@"chatIdentifier"] = ident;
    NSString *name = safeValue(chat, @"displayName");
    if (name.length) out[@"displayName"] = name;

    NSMutableArray *members = [NSMutableArray array];
    NSMutableArray *people = [NSMutableArray array];
    for (id handle in (NSArray *)safeValue(chat, @"participants") ?: @[]) {
        NSString *hid = handleID(handle);
        if (hid) [members addObject:hid];
        NSDictionary *info = IMBHandleInfo(handle);
        if (info) [people addObject:info];
    }
    out[@"participants"] = members;
    // Named participants, so a caller can address people by name.
    if (people.count) out[@"people"] = people;
    out[@"isGroup"] = @(members.count > 1);

    id unread = safeValue(chat, @"unreadMessageCount") ?: safeValue(chat, @"dbUnreadCount");
    if ([unread respondsToSelector:@selector(longLongValue)]) {
        out[@"unreadCount"] = @([unread longLongValue]);
    }

    // Sidebar state: pinned and muted change how a person treats a thread.
    for (NSString *flag in @[@"isPinned", @"isMuted"]) {
        id v = safeValue(chat, flag);
        if ([v respondsToSelector:@selector(boolValue)]) out[flag] = @([v boolValue]);
    }

    // Mute is held as a date, so a silenced thread can be silenced until a
    // particular time rather than forever. The indefinite case is stored as
    // the distant future and reported as no date at all, since answering with
    // a year in the far future would read as a real deadline.
    id mutedUntil = safeValue(chat, @"muteUntilDate");
    if ([mutedUntil isKindOfClass:[NSDate class]]) {
        NSTimeInterval ahead = [(NSDate *)mutedUntil timeIntervalSinceNow];
        if (ahead > 0 && ahead < 60 * 60 * 24 * 365 * 50) {
            out[@"mutedUntil"] = @([(NSDate *)mutedUntil timeIntervalSince1970]);
        }
    }

    id lastDate = safeValue(chat, @"lastFinishedMessageDate");
    if ([lastDate isKindOfClass:[NSDate class]] &&
        [(NSDate *)lastDate timeIntervalSince1970] > 0) {
        out[@"lastActivity"] = @([(NSDate *)lastDate timeIntervalSince1970]);
    }

    NSArray *mentions = safeValue(chat, @"messageGuidsForMyUnreadMentions");
    if ([mentions isKindOfClass:[NSArray class]] && mentions.count) {
        out[@"unreadMentionGUIDs"] = mentions;
    }

    id service = safeValue(chat, @"account");
    NSString *serviceName = safeValue(service, @"serviceName");
    if (serviceName) out[@"service"] = serviceName;

    return out;
}
