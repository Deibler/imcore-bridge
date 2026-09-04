// The parts of a stored row that are not plain columns.
//
// Two things a transcript shows are not readable from the message table alone:
//
//   * the earlier versions of an edited message, and whether an unsend actually
//     reached the other side — both buried in the `message_summary_info` plist;
//   * the grey lines a group conversation is punctuated with ("Ada named the
//     conversation Trip"), which are ordinary rows distinguished only by
//     `item_type` and a few columns that are NULL on every other row.
//
// Neither is exotic — the app draws both — but a reader that ignores them sees
// an edited message with no history and a group chat with unexplained gaps.
#import "bridge.h"

/// Cocoa epoch (2001-01-01) to Unix epoch (1970-01-01), in seconds.
static const long long kCocoaEpochOffset = 978307200;

/// Reads a binary plist without letting a malformed one reach the host.
static NSDictionary *parsePlist(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) return nil;
    @try {
        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                            options:NSPropertyListImmutable
                                                             format:NULL
                                                              error:NULL];
        return [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
    } @catch (NSException *e) {
        IMBLog(@"summary info parse threw: %@", e.reason);
        return nil;
    }
}

/// Decodes one archived version of an edited part into `{ text, date }`.
static NSDictionary *editVersion(NSDictionary *version) {
    if (![version isKindOfClass:[NSDictionary class]]) return nil;

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    // The version's body is archived exactly like a live one, so the same
    // decoder reads it — including its mentions and links.
    NSDictionary *body = IMBDecodeAttributedBody(version[@"t"]);
    NSString *text = body[@"text"];
    if ([text isKindOfClass:[NSString class]]) out[@"text"] = text;
    for (NSString *key in @[@"mentions", @"links"]) {
        if (body[key]) out[key] = body[key];
    }

    id when = version[@"d"];
    if ([when respondsToSelector:@selector(doubleValue)]) {
        out[@"date"] = @((long long)[when doubleValue] + kCocoaEpochOffset);
    }
    return out.count ? out : nil;
}

/// Everything worth reading out of a row's `message_summary_info`.
///
/// Only the keys whose meaning has been confirmed against real rows are
/// reported. The blob carries several others — a spam-classifier trace, an
/// encryption flag set on almost every message — which say nothing a reader of
/// the conversation needs.
NSDictionary *IMBSummaryFields(NSDictionary *summary, long long partCount) {
    if (![summary isKindOfClass:[NSDictionary class]] || !summary.count) return nil;

    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    // `ec` holds the full version chain per part index, oldest first, and the
    // last entry is the text the message reads as now. Both are reported: the
    // chain is only meaningful with its endpoint in it.
    NSDictionary *chains = summary[@"ec"];
    if ([chains isKindOfClass:[NSDictionary class]] && chains.count) {
        NSMutableArray *history = [NSMutableArray array];
        NSArray *parts = [chains.allKeys sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [@([a intValue]) compare:@([b intValue])];
        }];
        for (id part in parts) {
            NSArray *versions = chains[part];
            if (![versions isKindOfClass:[NSArray class]]) continue;
            NSMutableArray *decoded = [NSMutableArray array];
            for (NSDictionary *version in versions) {
                NSDictionary *entry = editVersion(version);
                if (entry) [decoded addObject:entry];
            }
            if (decoded.count) {
                [history addObject:@{ @"part": @([part intValue]), @"versions": decoded }];
            }
        }
        if (history.count) out[@"editHistory"] = history;
    }

    // An unsend removes parts locally and records which in `rp`. A message can
    // be unsent a part at a time, so the count that remains is what separates
    // "this bubble is gone" from "one of its parts is".
    NSArray *removed = summary[@"rp"];
    if ([removed isKindOfClass:[NSArray class]] && removed.count) {
        out[@"unsentParts"] = removed;
        if (partCount == 0) out[@"unsent"] = @YES;
    }

    // `rdfp` is the signal that the retraction failed to propagate — the state
    // the app draws as "Not Unsent", where the other party still sees the
    // message and it can never be taken back. Nothing else in the row says so:
    // `date_retracted` stays 0 and the body is empty either way.
    if (summary[@"rdfp"]) out[@"unsendFailed"] = @YES;

    // When the message was scheduled — not when it will go out. The delivery
    // time is the message's own `date`, which IMCore sets to the future; this
    // is the moment the request was made, and the two are easy to confuse.
    id scheduledAt = summary[@"smlmt"];
    if ([scheduledAt isKindOfClass:[NSDate class]]) {
        out[@"scheduledAt"] = @((long long)[scheduledAt timeIntervalSince1970]);
    }

    return out.count ? out : nil;
}

/// The same, from a stored row's binary plist.
///
/// A live IMMessage hands back `messageSummaryInfo` already as a dictionary,
/// so both paths share everything except how they get there.
NSDictionary *IMBDecodeSummaryInfo(NSData *blob, long long partCount) {
    return IMBSummaryFields(parsePlist(blob), partCount);
}

// ---------------------------------------------------------------------------
// Group events
// ---------------------------------------------------------------------------

/// The transcript lines that are not messages.
///
/// `item_type` distinguishes them; every other row is 0. The codes below are
/// the ones confirmed against real rows in a store — an unrecognised one is
/// reported with its raw code rather than guessed at or dropped, so a type
/// introduced by a future release still surfaces.
NSDictionary *IMBGroupEvent(long long itemType, long long actionType,
                            NSString *groupTitle, NSString *actor,
                            NSString *participant, BOOL hasAttachment,
                            long long shareStatus, long long shareDirection) {
    if (itemType == 0) return nil;

    // A NULL column reads back as NSNull, which answers none of the selectors
    // below. Coercing here rather than trusting the caller keeps one missing
    // handle from aborting the host.
    if (![actor isKindOfClass:[NSString class]]) actor = nil;
    if (![participant isKindOfClass:[NSString class]]) participant = nil;
    if (![groupTitle isKindOfClass:[NSString class]]) groupTitle = nil;

    NSMutableDictionary *event = [NSMutableDictionary dictionary];
    if (actor.length) event[@"actor"] = actor;

    switch (itemType) {
        case 1:
            // Someone joined or left. Action 0 is an addition, seen on every
            // such row in a store where people were added; the removal code is
            // reported rather than named, having never been observed.
            event[@"kind"] = actionType == 0 ? @"participant-added" : @"participant-change";
            if (participant.length) event[@"participant"] = participant;
            if (actionType != 0) event[@"actionCode"] = @(actionType);
            break;

        case 2:
            event[@"kind"] = @"group-renamed";
            if (groupTitle.length) event[@"name"] = groupTitle;
            break;

        case 3:
            // The conversation's picture changed. Which of the several action
            // codes means what is not established — macOS 26 appears to reuse
            // this row for conversation backgrounds as well — but the one
            // distinction that matters reads off the row itself: a change that
            // carries an image sets one, and a change that carries none clears
            // it.
            event[@"kind"] = hasAttachment ? @"group-photo-set" : @"group-photo-removed";
            event[@"actionCode"] = @(actionType);
            break;

        case 4:
            event[@"kind"] = @"share";
            event[@"shareStatus"] = @(shareStatus);
            event[@"shareDirection"] = @(shareDirection);
            if (participant.length) event[@"participant"] = participant;
            break;

        default:
            event[@"kind"] = @"unknown";
            event[@"itemType"] = @(itemType);
            if (actionType) event[@"actionCode"] = @(actionType);
            if (participant.length) event[@"participant"] = participant;
            if (groupTitle.length) event[@"name"] = groupTitle;
            break;
    }
    return event;
}

// ---------------------------------------------------------------------------
// The same events, live
// ---------------------------------------------------------------------------

static id itemValue(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static long long itemNumber(id obj, NSString *key) {
    id v = itemValue(obj, key);
    return [v respondsToSelector:@selector(longLongValue)] ? [v longLongValue] : 0;
}

static NSString *itemString(id obj, NSString *key) {
    id v = itemValue(obj, key);
    return [v isKindOfClass:[NSString class]] && [v length] ? v : nil;
}

/// A group event read off a live transcript item, rather than a stored row.
///
/// IMCore models these as their own item classes rather than as messages, which
/// is why they arrive with no text: a reader that only looks for a body sees a
/// blank entry where the app draws "Ada added Ben".
///
/// The live path can also answer one thing the stored row cannot. A picture
/// change carries several action codes whose meanings are not established, and
/// macOS 26 appears to reuse the same item for conversation backgrounds — but
/// the item itself knows, via `actionIsGroupPhoto`. History has to infer it
/// from whether an image came along.
NSDictionary *IMBGroupEventForItem(id item) {
    if (!item) return nil;

    // A chat item wraps the IMItem that carries the detail; either may be
    // passed in, so unwrap when needed.
    id subject = item;
    NSString *cls = NSStringFromClass([subject class]);
    if (![cls hasSuffix:@"ChangeItem"] && ![cls hasSuffix:@"ActionItem"]) {
        for (NSString *key in @[@"_item", @"item"]) {
            id inner = itemValue(subject, key);
            NSString *innerCls = inner ? NSStringFromClass([inner class]) : nil;
            if ([innerCls hasSuffix:@"ChangeItem"] || [innerCls hasSuffix:@"ActionItem"]) {
                subject = inner;
                cls = innerCls;
                break;
            }
        }
    }

    NSMutableDictionary *event = [NSMutableDictionary dictionary];
    NSString *actor = itemString(itemValue(subject, @"sender"), @"ID")
                   ?: itemString(subject, @"sender");
    if (actor) event[@"actor"] = actor;

    NSString *other = itemString(itemValue(subject, @"otherHandle"), @"ID")
                   ?: itemString(subject, @"otherHandle")
                   ?: itemString(subject, @"otherUnformattedID");

    if ([cls isEqualToString:@"IMParticipantChangeItem"]) {
        long long change = itemNumber(subject, @"changeType");
        event[@"kind"] = change == 0 ? @"participant-added" : @"participant-change";
        if (other) event[@"participant"] = other;
        if (change != 0) event[@"actionCode"] = @(change);
        return event;
    }

    if ([cls isEqualToString:@"IMGroupTitleChangeItem"]) {
        event[@"kind"] = @"group-renamed";
        NSString *title = itemString(subject, @"title");
        if (title) event[@"name"] = title;
        return event;
    }

    if ([cls isEqualToString:@"IMGroupActionItem"]) {
        id isPhoto = itemValue(subject, @"actionIsGroupPhoto");
        BOOL photo = [isPhoto respondsToSelector:@selector(boolValue)] && [isPhoto boolValue];
        NSArray *transfers = itemValue(subject, @"fileTransferGUIDs");
        BOOL carriesImage = [transfers isKindOfClass:[NSArray class]] && transfers.count > 0;

        if (photo) {
            event[@"kind"] = carriesImage ? @"group-photo-set" : @"group-photo-removed";
        } else {
            // Something else drawn the same way — a conversation background, on
            // the releases that have them. Named for what is known.
            event[@"kind"] = @"group-action";
        }
        event[@"actionCode"] = @(itemNumber(subject, @"actionType"));
        return event;
    }

    return nil;
}
