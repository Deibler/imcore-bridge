// Decoding message bodies.
//
// Most rows in the message store keep no plain `text`: the body lives in
// `attributedBody`, a typedstream archive of an NSAttributedString whose runs
// carry IMCore's private attributes. Decoding it is what turns deep history
// from a list of empty rows into readable messages — and the same runs hold the
// mentions, links and attachment placeholders a reader needs.
//
// The unarchiving happens inside Messages.app, which is the only place the
// archived classes are loaded, and is exactly what the app does with the same
// bytes when it draws a transcript.
#import "bridge.h"
#import <objc/message.h>
#include <dlfcn.h>

/// Attribute names IMCore puts on message body runs. Anything else found on a
/// run is reported under its own name rather than dropped, so a new attribute
/// in a future release shows up instead of disappearing.
static NSString *const kPartAttribute     = @"__kIMMessagePartAttributeName";
static NSString *const kMentionAttribute  = @"__kIMMentionConfirmedMention";
static NSString *const kMentionName       = @"__kIMMentionAttributeName";
static NSString *const kLinkAttribute     = @"__kIMLinkAttributeName";
static NSString *const kRichLinkAttribute = @"__kIMLinkIsRichLinkAttributeName";
static NSString *const kTransferAttribute = @"__kIMFileTransferGUIDAttributeName";
static NSString *const kBaseWritingDirection = @"__kIMBaseWritingDirectionAttributeName";

/// Styling a person applies from the format bar.
///
/// Two spellings exist for each. The `__kIMText…` names are what the current
/// format bar writes; the shorter ones predate it and still appear on older
/// messages, so both are read and reported as the same field.
static NSString *const kBoldAttribute          = @"__kIMTextBoldAttributeName";
static NSString *const kItalicAttribute        = @"__kIMTextItalicAttributeName";
static NSString *const kUnderlineAttribute     = @"__kIMTextUnderlineAttributeName";
static NSString *const kStrikethroughAttribute = @"__kIMTextStrikethroughAttributeName";
static NSString *const kBoldLegacy             = @"__kIMBoldAttributeName";
static NSString *const kItalicLegacy           = @"__kIMItalicAttributeName";
static NSString *const kUnderlineLegacy        = @"__kIMUnderlineAttributeName";
static NSString *const kStrikethroughLegacy    = @"__kIMStrikethroughAttributeName";

/// An animated text effect, e.g. the words shaking or exploding on arrival.
static NSString *const kTextEffectAttribute = @"__kIMTextEffectAttributeName";

/// A one-time passcode Messages recognised in the text. Worth naming: it is
/// the difference between a reader seeing a number and knowing it is a code.
static NSString *const kOneTimeCodeAttribute = @"__kIMOneTimeCodeAttributeName";

/// What the data detectors found — a flight, a parcel, an address, an amount.
static NSString *const kDataDetectedAttribute = @"__kIMDataDetectedAttributeName";
static NSString *const kDataDetectorResult    = @"__kIMDataDetectorResultAttributeName";

/// The Object Replacement Character, which stands in for an attachment.
static NSString *const kAttachmentPlaceholder = @"￼";

/// Names an animated text effect from the code stored on the run.
///
/// IMCore ships the mapping as a function, so it is asked rather than
/// duplicated here — a table would be one release away from being wrong, and
/// the effects are new enough to still be gaining entries. When the symbol is
/// not exported the raw code is reported instead of a guess.
static NSString *textEffectName(id value) {
    if ([value isKindOfClass:[NSString class]] && [value length]) return value;
    if (![value respondsToSelector:@selector(longLongValue)]) return nil;

    static NSString *(*nameFromType)(long long) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nameFromType = dlsym(RTLD_DEFAULT, "IMTextEffectNameFromType");
    });
    if (nameFromType) {
        @try {
            NSString *name = nameFromType([value longLongValue]);
            if ([name isKindOfClass:[NSString class]] && name.length) return name;
        } @catch (__unused NSException *e) { /* fall through to the code */ }
    }
    return [value stringValue];
}

/// Whether a styling attribute is on. IMCore writes these as a flag rather
/// than a value, but tolerate a value that is merely present.
static BOOL styleIsSet(NSDictionary *attrs, NSString *primary, NSString *legacy) {
    for (NSString *key in @[primary, legacy]) {
        id value = attrs[key];
        if (!value) continue;
        if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
        return YES;
    }
    return NO;
}

/// Unarchives a typedstream body into an NSAttributedString.
///
/// The blob is a classic NSArchiver stream, not a keyed archive, so
/// NSUnarchiver is what reads it. Corrupt or truncated data raises rather than
/// returning nil, hence the guard: a bad row must not take the host down.
static NSAttributedString *unarchiveBody(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) return nil;

    @try {
        Class unarchiver = NSClassFromString(@"NSUnarchiver");
        if (unarchiver) {
            SEL sel = NSSelectorFromString(@"unarchiveObjectWithData:");
            if ([unarchiver respondsToSelector:sel]) {
                id decoded = ((id (*)(id, SEL, id))objc_msgSend)(unarchiver, sel, data);
                if ([decoded isKindOfClass:[NSAttributedString class]]) return decoded;
                // Some rows archive the string alone rather than an attributed one.
                if ([decoded isKindOfClass:[NSString class]]) {
                    return [[NSAttributedString alloc] initWithString:decoded];
                }
            }
        }
    } @catch (NSException *e) {
        IMBLog(@"attributedBody unarchive threw: %@", e.reason);
    }
    return nil;
}

/// Decodes a stored body into readable text plus its runs.
///
/// Returns nil when the blob cannot be read, which the caller reports by
/// passing the raw bytes through instead of silently losing the message.
NSDictionary *IMBDecodeAttributedBody(NSData *data) {
    NSAttributedString *body = unarchiveBody(data);
    if (!body) return nil;

    NSString *plain = body.string ?: @"";
    NSMutableArray *mentions = [NSMutableArray array];
    NSMutableArray *links = [NSMutableArray array];
    NSMutableArray *parts = [NSMutableArray array];

    [body enumerateAttributesInRange:NSMakeRange(0, body.length)
                             options:0
                          usingBlock:^(NSDictionary<NSString *, id> *attrs,
                                       NSRange range, BOOL *stop) {
        NSString *substring = NSMaxRange(range) <= plain.length
            ? [plain substringWithRange:range] : @"";

        NSMutableDictionary *part = [NSMutableDictionary dictionary];
        part[@"text"] = substring;
        part[@"location"] = @(range.location);
        part[@"length"] = @(range.length);

        id index = attrs[kPartAttribute];
        if ([index respondsToSelector:@selector(longLongValue)]) {
            part[@"partIndex"] = @([index longLongValue]);
        }

        // An attachment appears in the body as a placeholder character tagged
        // with its transfer GUID; that is how the text and its files interleave.
        NSString *transfer = attrs[kTransferAttribute];
        if ([transfer isKindOfClass:[NSString class]] && transfer.length) {
            part[@"attachmentGuid"] = transfer;
            part[@"kind"] = @"attachment";
        } else if ([substring isEqualToString:kAttachmentPlaceholder]) {
            part[@"kind"] = @"attachment";
        }

        NSString *handle = attrs[kMentionAttribute];
        if (![handle isKindOfClass:[NSString class]]) handle = attrs[kMentionName];
        if ([handle isKindOfClass:[NSString class]] && handle.length) {
            part[@"kind"] = @"mention";
            part[@"handle"] = handle;
            [mentions addObject:@{
                @"handle": handle,
                @"text": substring,
                @"location": @(range.location),
                @"length": @(range.length),
            }];
        }

        id link = attrs[kLinkAttribute];
        if (link) {
            NSString *url = [link isKindOfClass:[NSString class]]
                          ? link
                          : ([link respondsToSelector:@selector(absoluteString)]
                             ? [link absoluteString] : nil);
            if (url.length) {
                part[@"kind"] = @"link";
                part[@"url"] = url;
                [links addObject:@{
                    @"url": url,
                    @"text": substring,
                    @"isRichLink": @([attrs[kRichLinkAttribute] boolValue]),
                }];
            }
        }

        if (!part[@"kind"]) part[@"kind"] = @"text";

        // Styling from the format bar. Reported per run, which is how it is
        // stored: a message is bold over a range, not as a whole.
        NSMutableArray *styles = [NSMutableArray array];
        if (styleIsSet(attrs, kBoldAttribute, kBoldLegacy))                   [styles addObject:@"bold"];
        if (styleIsSet(attrs, kItalicAttribute, kItalicLegacy))               [styles addObject:@"italic"];
        if (styleIsSet(attrs, kUnderlineAttribute, kUnderlineLegacy))         [styles addObject:@"underline"];
        if (styleIsSet(attrs, kStrikethroughAttribute, kStrikethroughLegacy)) [styles addObject:@"strikethrough"];
        if (styles.count) part[@"styles"] = styles;

        NSString *effect = textEffectName(attrs[kTextEffectAttribute]);
        if (effect) part[@"textEffect"] = effect;

        // A run Messages recognised as a passcode. The text is already in
        // `text`; this says what it is.
        if (attrs[kOneTimeCodeAttribute]) part[@"isOneTimeCode"] = @YES;

        // A detected flight, parcel, address or amount. The payload is an
        // archived scanner result, so only the fact and any plain value it
        // carries are reported rather than a half-decoded object.
        id detected = attrs[kDataDetectedAttribute] ?: attrs[kDataDetectorResult];
        if (detected) {
            part[@"isDataDetected"] = @YES;
            if ([detected isKindOfClass:[NSString class]]) part[@"detected"] = detected;
        }

        // Anything else IMCore tagged the run with, reported rather than
        // dropped, so a new attribute surfaces instead of vanishing.
        NSMutableDictionary *extra = [NSMutableDictionary dictionary];
        for (NSString *key in attrs) {
            if ([key isEqualToString:kPartAttribute] ||
                [key isEqualToString:kMentionAttribute] ||
                [key isEqualToString:kLinkAttribute] ||
                [key isEqualToString:kRichLinkAttribute] ||
                [key isEqualToString:kTransferAttribute] ||
                [key isEqualToString:kBaseWritingDirection] ||
                [key isEqualToString:kMentionName] ||
                [key isEqualToString:kBoldAttribute] ||
                [key isEqualToString:kItalicAttribute] ||
                [key isEqualToString:kUnderlineAttribute] ||
                [key isEqualToString:kStrikethroughAttribute] ||
                [key isEqualToString:kBoldLegacy] ||
                [key isEqualToString:kItalicLegacy] ||
                [key isEqualToString:kUnderlineLegacy] ||
                [key isEqualToString:kStrikethroughLegacy] ||
                [key isEqualToString:kTextEffectAttribute] ||
                [key isEqualToString:kOneTimeCodeAttribute] ||
                [key isEqualToString:kDataDetectedAttribute] ||
                [key isEqualToString:kDataDetectorResult]) continue;
            id value = attrs[key];
            if ([value isKindOfClass:[NSString class]] ||
                [value isKindOfClass:[NSNumber class]]) {
                extra[key] = value;
            }
        }
        if (extra.count) part[@"attributes"] = extra;

        [parts addObject:part];
    }];

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"text"] = plain;
    if (parts.count) out[@"parts"] = parts;
    if (mentions.count) out[@"mentions"] = mentions;
    if (links.count) out[@"links"] = links;
    return out;
}
