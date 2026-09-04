// Search over the index Messages itself maintains.
//
// Messages keeps no text index of its own; it donates every message, attachment
// and conversation to a private CoreSpotlight domain (com.apple.MobileSMS), and
// its own search field queries that. Querying the same index means search
// arrives with work the device has already done: pictures match by what they
// contain, text recognised inside images is searchable, and spoken content is
// covered. That domain is invisible to mdfind from any other process, which is
// why this runs inside the host app.
//
// Three properties of the index are load-bearing, each learned the hard way:
//
//   * Body text is indexed for *matching* but never returned as a fetchable
//     attribute. A named-attribute predicate (textContent == "dog*") matches
//     nothing; the all-attribute operator **== is what reaches it.
//
//   * The ranked path (CSUserQuery) needs a configured CSUserQueryContext.
//     Passing nil fails with CSSearchQueryErrorDomain -2002.
//
//   * Scope must be pushed into the query (filterQueries on CSUserQuery, a
//     compound predicate on CSSearchQuery). Filtering afterwards leaves a
//     scoped search empty while matches sit further down the ranking.
//
// Attachments are filed under a domain of their own and carry nothing that
// names a conversation, so a scoped search that wants files attributes them by
// membership: list the conversation's items once, then keep the attachments
// whose owning message is among them.
#import "bridge.h"
#import <objc/message.h>

// The client gives up at 20s; stop a little before that so a slow query returns
// partial results (marked truncated) instead of timing out the RPC.
static const NSTimeInterval kSearchBudget = 14.0;
// A scoped file search lists the conversation's items; that listing is the
// expensive part, so it is cached briefly.
static const NSTimeInterval kMembershipTTL = 60.0;

static id sv(id o, NSString *k) {
    if (!o) return nil;
    @try { return [o valueForKey:k]; } @catch (__unused NSException *e) { return nil; }
}

static NSString *svString(id o, NSString *k) {
    id v = sv(o, k);
    return [v isKindOfClass:[NSString class]] && [v length] ? v : nil;
}

// ---------------------------------------------------------------------------
// Hit shape
// ---------------------------------------------------------------------------

/// Coerces an array of unknown element type into plain strings.
///
/// Everything returned from here is JSON-serialised inside Messages.app, and
/// NSJSONSerialization aborts the process on an unsupported type rather than
/// raising — so nothing from the index reaches the wire untyped.
static NSArray *stringsFrom(id value) {
    if (![value isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (id element in (NSArray *)value) {
        if ([element isKindOfClass:[NSString class]]) {
            if ([element length]) [out addObject:element];
        } else if (element) {
            NSString *described = [element description];
            if (described.length) [out addObject:described];
        }
    }
    return out.count ? out : nil;
}

/// Classifies an item by its domain: a message, an attachment, or a chat.
static NSString *kindForItem(NSString *domain, NSString *identifier) {
    if ([domain isEqualToString:@"attachmentDomain"]) return @"attachment";
    if ([domain isEqualToString:@"chatDomain"]) return @"chat";
    if ([domain hasPrefix:@"any;"]) return @"message";
    (void)identifier;
    return nil;
}

/// Attachment identifiers are "at_<part>_<message GUID>"; recover the message.
static NSString *owningMessageGUID(NSString *identifier) {
    if (![identifier hasPrefix:@"at_"]) return nil;
    NSRange under = [identifier rangeOfString:@"_" options:0
                                        range:NSMakeRange(3, identifier.length - 3)];
    if (under.location == NSNotFound) return nil;
    return [identifier substringFromIndex:NSMaxRange(under)];
}

/// Serialises one searchable item into the public hit shape.
static NSDictionary *serializeHit(id item, NSString *kind) {
    id set = sv(item, @"attributeSet");
    NSString *uid = svString(item, @"uniqueIdentifier");
    NSString *domain = svString(item, @"domainIdentifier");
    if (!uid || !kind) return nil;

    NSMutableDictionary *hit = [NSMutableDictionary dictionary];
    hit[@"kind"] = kind;

    if ([kind isEqualToString:@"message"]) {
        hit[@"guid"] = uid;
        hit[@"messageGuid"] = uid;
        // A message's domain identifier *is* the chat GUID.
        if ([domain hasPrefix:@"any;"]) hit[@"chatGuid"] = domain;
    } else if ([kind isEqualToString:@"attachment"]) {
        hit[@"guid"] = uid;
        NSString *owner = owningMessageGUID(uid);
        if (owner) hit[@"messageGuid"] = owner;
        NSRange under = [uid rangeOfString:@"_" options:0
                                     range:NSMakeRange(3, uid.length - 3)];
        if (under.location != NSNotFound) {
            hit[@"partIndex"] = @([[uid substringWithRange:
                NSMakeRange(3, under.location - 3)] longLongValue]);
        }
    } else {
        hit[@"guid"] = uid;
        hit[@"handle"] = uid;
    }

    NSString *snippet = svString(set, @"contentSnippet");
    if (snippet) hit[@"snippet"] = snippet;
    NSString *title = svString(set, @"displayName") ?: svString(set, @"title");
    if (title) hit[@"title"] = title;
    NSString *ct = svString(set, @"contentType");
    if (ct) hit[@"contentType"] = ct;

    id date = sv(set, @"contentCreationDate") ?: sv(set, @"date");
    if ([date isKindOfClass:[NSDate class]]) {
        hit[@"date"] = @([(NSDate *)date timeIntervalSince1970]);
    }

    // Scene labels are how a query matches pictures by what is in them.
    id classifications = sv(set, @"photosSceneClassifications");
    if ([classifications isKindOfClass:[NSArray class]]) {
        NSMutableArray *labels = [NSMutableArray array];
        for (id c in (NSArray *)classifications) {
            NSString *label = svString(c, @"label") ?: svString(c, @"classification");
            // A bare string element is a label in its own right.
            if (!label && [c isKindOfClass:[NSString class]] && [c length]) label = c;
            if (!label) continue;
            NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject:label
                                                                           forKey:@"label"];
            id conf = sv(c, @"confidence");
            if ([conf respondsToSelector:@selector(doubleValue)]) {
                entry[@"confidence"] = @([conf doubleValue]);
            }
            [labels addObject:entry];
        }
        if (labels.count) hit[@"labels"] = labels;
    }

    // These arrays are not guaranteed to hold strings — the index returns hint
    // objects on some builds, which would abort JSON serialisation inside the
    // host app. Coerce to strings rather than trusting the element type.
    NSArray *hints = stringsFrom(sv(set, @"matchingHints"));
    if (hints.count) hit[@"matchedOn"] = hints;

    NSArray *mediaTypes = stringsFrom(sv(set, @"mediaTypes"));
    if (mediaTypes.count) hit[@"mediaTypes"] = mediaTypes;

    return hit;
}

// ---------------------------------------------------------------------------
// Query plumbing
// ---------------------------------------------------------------------------

/// Attributes worth fetching for a hit. Body text is not fetchable, so this
/// lists the metadata and the classification fields.
static NSArray *fetchAttributes(void) {
    return @[@"title", @"displayName", @"contentSnippet", @"contentDescription",
             @"contentType", @"contentCreationDate", @"keywords", @"subject",
             @"photosSceneClassifications", @"matchingHints", @"mediaTypes",
             @"alternateNames", @"information"];
}

/// Drives a query to completion within the budget, invoking consume for each
/// item. Sets *timedOut when the budget lapses with results still arriving.
static void drain(id query, NSTimeInterval timeout, BOOL *timedOut,
                  void (^consume)(id item)) {
    if (timedOut) *timedOut = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    void (^found)(NSArray *) = ^(NSArray *items) {
        @try {
            for (id item in items) consume(item);
        } @catch (__unused NSException *e) {}
    };
    void (^completion)(NSError *) = ^(NSError *e) {
        (void)e;
        dispatch_semaphore_signal(done);
    };

    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(
            query, NSSelectorFromString(@"setFoundItemsHandler:"), found);
        ((void (*)(id, SEL, id))objc_msgSend)(
            query, NSSelectorFromString(@"setCompletionHandler:"), completion);
        ((void (*)(id, SEL))objc_msgSend)(query, NSSelectorFromString(@"start"));
    } @catch (NSException *e) {
        IMBLog(@"query start threw: %@", e.reason);
        return;
    }

    dispatch_time_t deadline =
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(done, deadline) != 0) {
        if (timedOut) *timedOut = YES;
        @try {
            ((void (*)(id, SEL))objc_msgSend)(query, NSSelectorFromString(@"cancel"));
        } @catch (__unused NSException *e) {}
    }
}

/// Builds the ranked, natural-language query. A chat scope is pushed into the
/// query via filterQueries so ranking applies within the conversation.
static id makeUserQuery(NSString *text, NSUInteger limit, NSString *chatGuid) {
    Class qcls = NSClassFromString(@"CSUserQuery");
    Class ccls = NSClassFromString(@"CSUserQueryContext");
    if (!qcls || !ccls) return nil;

    SEL ctxSel = NSSelectorFromString(@"userQueryContext");
    id ctx = [ccls respondsToSelector:ctxSel]
        ? ((id (*)(id, SEL))objc_msgSend)(ccls, ctxSel) : nil;
    if (!ctx) ctx = [[ccls alloc] init];

    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        ctx, NSSelectorFromString(@"setEnableRankedResults:"), YES);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(
        ctx, NSSelectorFromString(@"setMaxResultCount:"), (NSInteger)limit);
    @try { [ctx setValue:fetchAttributes() forKey:@"fetchAttributes"]; }
    @catch (__unused NSException *e) {}

    id q = ((id (*)(id, SEL, id, id))objc_msgSend)(
        [qcls alloc], NSSelectorFromString(@"initWithUserQueryString:userQueryContext:"),
        text, ctx);
    if (q && chatGuid) {
        NSString *filter = [NSString stringWithFormat:
            @"_kMDItemDomainIdentifier == \"%@\"", chatGuid];
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(
                q, NSSelectorFromString(@"setFilterQueries:"), @[filter]);
        } @catch (NSException *e) { IMBLog(@"setFilterQueries threw: %@", e.reason); }
    }
    return q;
}

/// Builds the substring fallback. Scope is a compound predicate here.
static id makeSearchQuery(NSString *text, NSString *chatGuid) {
    Class qcls = NSClassFromString(@"CSSearchQuery");
    if (!qcls) return nil;

    NSString *predicate = [NSString stringWithFormat:@"**== \"%@*\"cd", text];
    if (chatGuid) {
        predicate = [NSString stringWithFormat:
            @"(%@) && (_kMDItemDomainIdentifier == \"%@\")", predicate, chatGuid];
    }
    return ((id (*)(id, SEL, id, id))objc_msgSend)(
        [qcls alloc], NSSelectorFromString(@"initWithQueryString:attributes:"),
        predicate, fetchAttributes());
}

// ---------------------------------------------------------------------------
// Attachment attribution
// ---------------------------------------------------------------------------

/// The set of every item GUID in a conversation, cached briefly. Built by a
/// match-all query against the chat's domain; used to test whether an
/// attachment's owning message belongs to the conversation.
static NSSet *chatMembership(NSString *chatGuid, NSTimeInterval timeout) {
    static NSMutableDictionary<NSString *, NSDictionary *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });

    NSDictionary *entry = cache[chatGuid];
    if (entry && [[NSDate date] timeIntervalSinceDate:entry[@"at"]] < kMembershipTTL) {
        return entry[@"set"];
    }

    // A bare domain predicate lists every item in the conversation.
    id query = makeSearchQuery(@"*", chatGuid);
    if (!query) return nil;
    NSMutableSet *set = [NSMutableSet set];
    BOOL timedOut = NO;
    drain(query, timeout, &timedOut, ^(id item) {
        NSString *uid = svString(item, @"uniqueIdentifier");
        if (uid) [set addObject:uid];
    });

    // Only a complete listing is safe to cache; a timed-out one would
    // under-report membership and drop real attachments.
    if (!timedOut && set.count) {
        cache[chatGuid] = @{ @"set": set, @"at": [NSDate date] };
    }
    return set;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

NSDictionary *IMBSearch(NSString *text, NSUInteger limit, NSString *chatGuid,
                        NSArray *kindFilter, NSString **errCode, NSString **errMessage) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = @"missing query";
        return nil;
    }
    if (limit == 0 || limit > 500) limit = 50;

    NSSet *kinds = [kindFilter isKindOfClass:[NSArray class]] && kindFilter.count
        ? [NSSet setWithArray:kindFilter] : nil;
    BOOL wantsAttachments = !kinds || [kinds containsObject:@"attachment"];
    BOOL wantsMessages    = !kinds || [kinds containsObject:@"message"];
    BOOL wantsChats       = !kinds || [kinds containsObject:@"chat"];
    BOOL wantsOthers = wantsMessages || wantsChats;

    BOOL ranked = NSClassFromString(@"CSUserQuery") != nil;
    NSString *strategy = ranked ? @"ranked" : @"substring";

    // Attachments first, and only when a scope makes a second query necessary:
    // otherwise messages fill every slot and files never appear. They get a
    // capped share of the limit so a message match always has room.
    NSUInteger attachmentCap = limit;
    if (chatGuid && wantsAttachments && wantsOthers) {
        attachmentCap = MAX((NSUInteger)1, limit / 2);
    }

    NSMutableArray *hits = [NSMutableArray array];
    BOOL truncated = NO;

    // -- attachments in scope -------------------------------------------------
    if (chatGuid && wantsAttachments) {
        NSSet *members = chatMembership(chatGuid, kSearchBudget);
        if (members) {
            // Unscoped query, fetched deeper than the limit, filtered to the
            // conversation by testing the owning message's GUID.
            NSUInteger depth = MIN(MAX(limit, 25) * 40, 2000);
            id q = ranked ? makeUserQuery(text, depth, nil)
                          : makeSearchQuery(text, nil);
            if (q) {
                BOOL timedOut = NO;
                __block NSUInteger kept = 0;
                drain(q, kSearchBudget, &timedOut, ^(id item) {
                    if (kept >= attachmentCap) return;
                    NSString *domain = svString(item, @"domainIdentifier");
                    NSString *kind = kindForItem(domain, svString(item, @"uniqueIdentifier"));
                    if (![kind isEqualToString:@"attachment"]) return;
                    NSString *uid = svString(item, @"uniqueIdentifier");
                    NSString *owner = owningMessageGUID(uid);
                    if ((uid && [members containsObject:uid]) ||
                        (owner && [members containsObject:owner])) {
                        NSDictionary *hit = serializeHit(item, kind);
                        if (hit) { [hits addObject:hit]; kept++; }
                    }
                });
                truncated = truncated || timedOut;
            }
        }
    }

    // -- messages, chats, and unscoped attachments ----------------------------
    if (wantsOthers || (!chatGuid && wantsAttachments)) {
        id q = ranked ? makeUserQuery(text, limit, chatGuid)
                      : makeSearchQuery(text, chatGuid);
        if (q) {
            BOOL timedOut = NO;
            NSUInteger remaining = (limit > hits.count) ? limit - hits.count : 0;
            __block NSUInteger kept = 0;
            drain(q, kSearchBudget, &timedOut, ^(id item) {
                if (kept >= remaining) return;
                NSString *domain = svString(item, @"domainIdentifier");
                NSString *uid = svString(item, @"uniqueIdentifier");
                NSString *kind = kindForItem(domain, uid);
                if (!kind) return;
                if (kinds && ![kinds containsObject:kind]) return;
                // Attachments in scope were handled above with attribution.
                if (chatGuid && [kind isEqualToString:@"attachment"]) return;
                NSDictionary *hit = serializeHit(item, kind);
                if (hit) { [hits addObject:hit]; kept++; }
            });
            truncated = truncated || timedOut;
        }
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"results"] = hits;
    out[@"strategy"] = strategy;
    if (chatGuid) out[@"scope"] = chatGuid;
    if (truncated) out[@"truncated"] = @YES;
    return out;
}
