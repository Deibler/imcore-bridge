// Decoding rich balloon payloads: link previews and polls.
//
// A link or poll message carries its content in `payload_data`, a keyed
// archive. Neither needs anything the app does not do itself with the same
// bytes, and neither is unarchived loosely:
//
//   * A link's archive is rooted in Apple's private `RichLink`, which is not
//     loadable here — that is what previously made previews unreachable. The
//     part worth having is its `LPLinkMetadata`, which *is* loadable, so the
//     root is swapped for a stand-in that decodes exactly that one key.
//
//   * A poll's archive is plain Foundation containers. It is unarchived with
//     secure coding and an explicit allow-list, and the poll itself turns out
//     to be base64 JSON carried in a `data:` URL inside it.
#import "bridge.h"
#import <objc/message.h>

// ---------------------------------------------------------------------------
// Link previews
// ---------------------------------------------------------------------------

/// Stands in for a private class whose contents are not wanted.
///
/// The preview's picture is archived as `RichLinkImageAttachmentSubstitute`,
/// which this process cannot load — and that one class is why most link
/// payloads failed to decode at all. It carries no metadata worth reading (the
/// remote URL lives in the separate image metadata object), so it decodes to an
/// empty placeholder and the rest of the archive comes through.
@interface IMBIgnoredStandIn : NSObject <NSSecureCoding>
@end

@implementation IMBIgnoredStandIn
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [super init]; }
- (void)encodeWithCoder:(NSCoder *)coder {}
@end

/// Stands in for the private `RichLink` root object.
///
/// Decoding only reaches for `richLinkMetadata`; everything else in the
/// original object is ignored, so nothing private has to be loadable.
@interface IMBRichLinkStandIn : NSObject <NSSecureCoding>
@property (nonatomic, strong) id metadata;
@end

@implementation IMBRichLinkStandIn
+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (!(self = [super init])) return nil;
    @try {
        // Secure coding is off for this archive (it names unloadable classes),
        // so decode by key and check the type afterwards.
        id decoded = [coder decodeObjectForKey:@"richLinkMetadata"];
        Class metadataClass = NSClassFromString(@"LPLinkMetadata");
        if (!metadataClass || [decoded isKindOfClass:metadataClass]) _metadata = decoded;
    } @catch (NSException *e) {
        IMBLog(@"rich link metadata decode threw: %@", e.reason);
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    // Never re-archived; the bridge only reads.
}
@end

static NSString *urlString(id value) {
    if ([value isKindOfClass:[NSString class]]) return [value length] ? value : nil;
    if ([value respondsToSelector:@selector(absoluteString)]) {
        NSString *s = [value absoluteString];
        return s.length ? s : nil;
    }
    return nil;
}

static id safeValue(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static NSString *safeString(id obj, NSString *key) {
    id v = safeValue(obj, key);
    return [v isKindOfClass:[NSString class]] && [v length] ? v : nil;
}

/// Pulls the readable fields out of an LPLinkMetadata.
static NSDictionary *serializeLinkMetadata(id metadata) {
    if (!metadata) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    NSString *url = urlString(safeValue(metadata, @"URL"));
    if (url) out[@"url"] = url;
    NSString *original = urlString(safeValue(metadata, @"originalURL"));
    if (original && ![original isEqualToString:url ?: @""]) out[@"originalUrl"] = original;

    NSString *title = safeString(metadata, @"title");
    if (title) out[@"title"] = title;
    NSString *summary = safeString(metadata, @"summary");
    if (summary) out[@"summary"] = summary;
    NSString *siteName = safeString(metadata, @"siteName");
    if (siteName) out[@"siteName"] = siteName;
    NSString *itemType = safeString(metadata, @"itemType");
    if (itemType) out[@"itemType"] = itemType;

    // The preview picture and the site's icon. Their bytes live in the
    // attachment table rather than in the payload, so what is available here is
    // the remote URL each was fetched from.
    NSString *image = urlString(safeValue(safeValue(metadata, @"imageMetadata"), @"URL"));
    if (image) out[@"imageUrl"] = image;
    NSString *icon = urlString(safeValue(safeValue(metadata, @"iconMetadata"), @"URL"));
    if (icon) out[@"iconUrl"] = icon;

    return out.count ? out : nil;
}

static NSDictionary *decodeLinkPayload(NSData *payload) {
    NSError *error = nil;
    NSKeyedUnarchiver *unarchiver = nil;
    @try {
        unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:payload error:&error];
    } @catch (NSException *e) {
        IMBLog(@"link payload unarchiver threw: %@", e.reason);
        return nil;
    }
    if (!unarchiver) return nil;

    // The archive names classes this process cannot load. The root decodes as
    // a stand-in that reads only the metadata; the image substitute decodes as
    // an empty placeholder so its presence no longer fails the whole payload.
    [unarchiver setClass:[IMBRichLinkStandIn class] forClassName:@"RichLink"];
    for (NSString *ignored in @[@"RichLinkImageAttachmentSubstitute",
                                @"RichLinkImageAttachment"]) {
        [unarchiver setClass:[IMBIgnoredStandIn class] forClassName:ignored];
    }
    unarchiver.requiresSecureCoding = NO;

    id root = nil;
    @try {
        root = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        [unarchiver finishDecoding];
    } @catch (NSException *e) {
        IMBLog(@"link payload decode threw: %@", e.reason);
        return nil;
    }

    id metadata = [root isKindOfClass:[IMBRichLinkStandIn class]]
        ? [(IMBRichLinkStandIn *)root metadata] : root;
    return serializeLinkMetadata(metadata);
}

// ---------------------------------------------------------------------------
// Polls
// ---------------------------------------------------------------------------

/// Finds the `data:` URL a poll hides its content in, anywhere in the graph.
static NSString *findDataURL(id node, NSUInteger depth) {
    if (depth > 8 || !node) return nil;

    NSString *candidate = urlString(node);
    if ([candidate hasPrefix:@"data:"]) return candidate;

    if ([node isKindOfClass:[NSDictionary class]]) {
        for (id key in (NSDictionary *)node) {
            NSString *found = findDataURL(((NSDictionary *)node)[key], depth + 1);
            if (found) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id element in (NSArray *)node) {
            NSString *found = findDataURL(element, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

/// Decodes the base64 JSON body of a `data:` URL.
static NSDictionary *decodeDataURL(NSString *dataURL) {
    NSRange comma = [dataURL rangeOfString:@","];
    if (comma.location == NSNotFound) return nil;
    NSString *body = [dataURL substringFromIndex:NSMaxRange(comma)];

    // Trailing query parameters are not part of the payload.
    NSRange query = [body rangeOfString:@"?"];
    if (query.location != NSNotFound) body = [body substringToIndex:query.location];

    // Base64 without padding is common here.
    NSUInteger remainder = body.length % 4;
    if (remainder) {
        body = [body stringByPaddingToLength:body.length + (4 - remainder)
                                  withString:@"=" startingAtIndex:0];
    }
    NSData *json = [[NSData alloc] initWithBase64EncodedString:body
        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!json.length) return nil;

    id parsed = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    return [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
}

static NSDictionary *decodePollPayload(NSData *payload) {
    NSError *error = nil;
    id root = nil;
    @try {
        // Plain Foundation containers, so an allow-list is enough: nothing in
        // the archive needs a class the bridge has to trust.
        NSSet *allowed = [NSSet setWithArray:@[
            [NSDictionary class], [NSArray class], [NSString class],
            [NSNumber class], [NSData class], [NSDate class],
            [NSURL class], [NSUUID class], [NSNull class],
        ]];
        root = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowed
                                                   fromData:payload
                                                      error:&error];
    } @catch (NSException *e) {
        IMBLog(@"poll payload unarchive threw: %@", e.reason);
        return nil;
    }
    if (!root) return nil;

    NSDictionary *body = decodeDataURL(findDataURL(root, 0));
    id item = body[@"item"];
    if (![item isKindOfClass:[NSDictionary class]]) return nil;

    NSMutableDictionary *poll = [NSMutableDictionary dictionary];

    // A vote is its own message carrying only the choice it names. The poll it
    // belongs to is the message it is associated with, so the caller folds
    // these onto that poll rather than showing them as entries of their own.
    id castVotes = item[@"votes"];
    if ([castVotes isKindOfClass:[NSArray class]]) {
        NSMutableArray *votes = [NSMutableArray array];
        for (id vote in (NSArray *)castVotes) {
            if (![vote isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            NSString *handle = vote[@"participantHandle"];
            if ([handle isKindOfClass:[NSString class]]) entry[@"handle"] = handle;
            NSString *optionID = vote[@"voteOptionIdentifier"];
            if ([optionID isKindOfClass:[NSString class]]) entry[@"optionId"] = optionID;
            id at = vote[@"serverVoteTime"];
            if ([at respondsToSelector:@selector(doubleValue)]) {
                // Cocoa seconds, like every other time in the store.
                entry[@"time"] = @([at doubleValue] + 978307200.0);
            }
            if (entry.count) [votes addObject:entry];
        }
        if (votes.count) poll[@"votes"] = votes;
    }
    NSString *title = item[@"title"];
    if ([title isKindOfClass:[NSString class]] && title.length) poll[@"question"] = title;
    NSString *creator = item[@"creatorHandle"];
    if ([creator isKindOfClass:[NSString class]] && creator.length) poll[@"creator"] = creator;

    NSMutableArray *options = [NSMutableArray array];
    id ordered = item[@"orderedPollOptions"];
    if ([ordered isKindOfClass:[NSArray class]]) {
        for (id option in (NSArray *)ordered) {
            if (![option isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            NSString *text = option[@"text"] ?: option[@"attributedText"];
            if ([text isKindOfClass:[NSString class]]) entry[@"text"] = text;
            NSString *identifier = option[@"optionIdentifier"];
            if ([identifier isKindOfClass:[NSString class]]) entry[@"id"] = identifier;
            NSString *optionCreator = option[@"creatorHandle"];
            if ([optionCreator isKindOfClass:[NSString class]]) entry[@"creator"] = optionCreator;
            if (entry.count) [options addObject:entry];
        }
    }
    if (options.count) poll[@"options"] = options;

    // The session identifier is what ties a vote to its poll: both carry the
    // same one, and a vote built without it is not counted.
    id session = [root isKindOfClass:[NSDictionary class]] ? root[@"sessionIdentifier"] : nil;
    if ([session isKindOfClass:[NSUUID class]]) poll[@"sessionId"] = [session UUIDString];

    return poll.count ? poll : nil;
}

// ---------------------------------------------------------------------------
// Building a poll
// ---------------------------------------------------------------------------

/// The plugin identifier a poll message carries.
NSString *const IMBPollBundleID =
    @"com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.messages.Polls";

/// Builds the payload for a new poll.
///
/// A poll is an app-extension balloon, and its content is not archived as
/// objects: the question and options are JSON, base64-encoded into a `data:`
/// URL that sits in the payload alongside the presentation fields. That is the
/// same shape received polls arrive in, read back from real ones.
///
/// Each option gets a fresh identifier, which is what a vote later names.
NSData *IMBBuildPollPayload(NSString *question, NSArray<NSString *> *options,
                            NSString *creator) {
    if (!options.count) return nil;

    NSMutableArray *ordered = [NSMutableArray array];
    for (NSString *option in options) {
        if (![option isKindOfClass:[NSString class]] || !option.length) continue;
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"optionIdentifier"] = [[NSUUID UUID] UUIDString];
        entry[@"text"] = option;
        entry[@"attributedText"] = option;
        entry[@"canBeEdited"] = @NO;
        if (creator.length) entry[@"creatorHandle"] = creator;
        [ordered addObject:entry];
    }
    if (!ordered.count) return nil;

    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[@"title"] = question ?: @"";
    item[@"orderedPollOptions"] = ordered;
    if (creator.length) item[@"creatorHandle"] = creator;

    NSData *json = [NSJSONSerialization dataWithJSONObject:@{ @"version": @1, @"item": item }
                                                   options:0 error:NULL];
    if (!json) return nil;

    // `c` is the option count and `src` marks it as a poll; both appear on
    // every real poll URL.
    NSString *url = [NSString stringWithFormat:@"data:,%@?src=p&c=%lu",
                     [json base64EncodedStringWithOptions:0],
                     (unsigned long)ordered.count];

    // A poll is drawn by a *live* layout — that is what makes the bubble
    // interactive rather than a static card, and it is what lets recipients
    // vote in place. It is carried as its own nested archive.
    NSError *error = nil;
    NSData *liveLayout = [NSKeyedArchiver archivedDataWithRootObject:
        @{ @"layoutClass": @"MSMessageLiveLayout", @"userInfo": @{} }
                                              requiringSecureCoding:NO
                                                              error:&error];
    if (!liveLayout) IMBLog(@"live layout archive failed: %@", error);

    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:@{
        @"layoutClass": @"MSMessageTemplateLayout",
        @"an": @"Polls",
        @"ldtext": @"Sent a poll",
        @"sessionIdentifier": [NSUUID UUID],
        @"URL": [NSURL URLWithString:url],
        @"userInfo": @{
            @"caption": @"Sent a poll",
            @"subcaption": @"",
            @"secondary-subcaption": @"",
            @"tertiary-subcaption": @"",
            @"image-title": @"",
            @"image-subtitle": @"",
        },
    }];
    if (liveLayout) payload[@"liveLayoutInfo"] = liveLayout;

    // Real polls also carry `ai`, a rendered preview of the bubble. It is only
    // a fallback image for contexts that cannot run the plugin, and the poll
    // draws from the URL, so it is left out rather than faked.

    NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:payload
                                            requiringSecureCoding:NO
                                                            error:&error];
    if (!archived) IMBLog(@"poll payload archive failed: %@", error);
    return archived;
}

/// Builds the payload for a vote in an existing poll.
///
/// A vote is a much smaller thing than the poll it belongs to: no layout, no
/// preview, no options — just the session it belongs to and the choice made.
/// The two fields that matter are the session identifier, which must be the
/// poll's own (a vote carrying a fresh one is not counted), and the option
/// identifier, which the poll minted when it was created.
///
/// One vote is sent per participant per message. Voting again replaces the
/// earlier choice rather than adding to it, which is why the array holds one.
NSData *IMBBuildVotePayload(NSString *sessionID, NSString *handle, NSString *optionID) {
    if (!sessionID.length || !optionID.length) return nil;

    NSUUID *session = [[NSUUID alloc] initWithUUIDString:sessionID];
    if (!session) return nil;

    NSMutableDictionary *vote = [NSMutableDictionary dictionary];
    vote[@"voteOptionIdentifier"] = optionID;
    if (handle.length) vote[@"participantHandle"] = handle;

    NSData *json = [NSJSONSerialization dataWithJSONObject:
        @{ @"version": @1, @"item": @{ @"votes": @[vote] } } options:0 error:NULL];
    if (!json) return nil;

    // A vote's URL carries no query string, unlike a poll's.
    NSString *url = [NSString stringWithFormat:@"data:,%@",
                     [json base64EncodedStringWithOptions:0]];

    NSError *error = nil;
    NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:@{
        @"sessionIdentifier": session,
        @"URL": [NSURL URLWithString:url],
        @"an": @"Polls",
    } requiringSecureCoding:NO error:&error];
    if (!archived) IMBLog(@"vote payload archive failed: %@", error);
    return archived;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Decodes a balloon payload into readable content, chosen by plugin.
/// Returns nil for plugins whose payload has no documented shape.
NSDictionary *IMBDecodePayload(NSData *payload, NSString *bundleID) {
    if (![payload isKindOfClass:[NSData class]] || payload.length == 0) return nil;

    if ([bundleID containsString:@"URLBalloonProvider"]) {
        NSDictionary *link = decodeLinkPayload(payload);
        return link ? @{ @"kind": @"link", @"link": link } : nil;
    }
    if ([bundleID containsString:@"com.apple.messages.Polls"]) {
        NSDictionary *poll = decodePollPayload(payload);
        return poll ? @{ @"kind": @"poll", @"poll": poll } : nil;
    }
    return nil;
}
