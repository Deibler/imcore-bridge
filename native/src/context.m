// Conversation context: identity, attachments, transcripts and history.
//
// The goal is that a caller reading one chat gets what a person reading it
// would get — who is speaking (a name, not a phone number), what was attached
// (with a path it can open), and what was said in audio (Messages' own
// on-device transcription).
//
// Deliberately not attempted: video/image understanding. IMCore exposes no
// transcript or summary API for them, so this file surfaces `localPath` and
// `mimeType` and lets the caller run its own tooling over the file.
#import "bridge.h"
#import <objc/message.h>

static id safeValue(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static NSString *safeString(id obj, NSString *key) {
    id v = safeValue(obj, key);
    return [v isKindOfClass:[NSString class]] && [v length] ? v : nil;
}

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

NSDictionary *IMBHandleInfo(id handle) {
    if (!handle) return nil;
    if ([handle isKindOfClass:[NSString class]]) return @{ @"id": handle };

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *hid = safeString(handle, @"ID");
    if (hid) out[@"id"] = hid;

    // fullName comes from Contacts; it is nil for unknown numbers.
    NSString *name = safeString(handle, @"fullName");
    if (name) out[@"name"] = name;

    NSString *first = safeString(handle, @"firstName");
    if (first) out[@"firstName"] = first;

    NSString *nickname = safeString(handle, @"nickname");
    if (nickname) out[@"nickname"] = nickname;

    return out.count ? out : nil;
}

/// The contact picture for a handle, if there is one.
///
/// Three sources, in the order the UI prefers them:
///
///   * `customPictureData` — a picture set on the conversation itself;
///   * the contact's own image, which is the usual case. It is *not* on the
///     handle: `pictureData` is nil on every handle in a running app. The
///     picture belongs to the CNContact, and Contacts hands out only the keys
///     that were asked for, so it has to be fetched by name;
///   * a brand logo, for a business rather than a person.
///
/// Returns nil when none is set; `mimeType` is filled when asked for.
NSData *IMBHandleAvatar(id handle, NSString **mimeType) {
    if (!handle || [handle isKindOfClass:[NSString class]]) return nil;

    NSData *picture = nil;
    for (NSString *key in @[@"customPictureData", @"pictureData", @"brandSquareLogoImageData"]) {
        id data = safeValue(handle, key);
        if ([data isKindOfClass:[NSData class]] && [data length]) { picture = data; break; }
    }

    if (!picture) {
        SEL sel = NSSelectorFromString(@"cnContactWithKeys:");
        if ([handle respondsToSelector:sel]) {
            @try {
                // The literal Contacts key names, so the framework does not
                // have to be linked for three strings.
                id contact = ((id (*)(id, SEL, id))objc_msgSend)(handle, sel,
                    @[@"imageData", @"thumbnailImageData", @"imageDataAvailable"]);
                for (NSString *key in @[@"imageData", @"thumbnailImageData"]) {
                    id data = safeValue(contact, key);
                    if ([data isKindOfClass:[NSData class]] && [data length]) {
                        picture = data;
                        break;
                    }
                }
            } @catch (NSException *e) {
                IMBLog(@"contact picture fetch threw: %@", e.reason);
            }
        }
    }
    if (!picture) return nil;

    if (mimeType) {
        // Sniffed rather than assumed: Contacts stores JPEG, but a poster and
        // a brand logo are often PNG.
        const unsigned char *bytes = [picture bytes];
        *mimeType = (picture.length > 3 && bytes[0] == 0x89 && bytes[1] == 'P')
                  ? @"image/png" : @"image/jpeg";
    }
    return picture;
}

// ---------------------------------------------------------------------------
// Attachments
// ---------------------------------------------------------------------------

static id fileTransferForGUID(NSString *guid) {
    Class centerCls = NSClassFromString(@"IMFileTransferCenter");
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    if (![centerCls respondsToSelector:sharedSel]) return nil;

    id center = ((id (*)(id, SEL))objc_msgSend)(centerCls, sharedSel);
    SEL lookup = NSSelectorFromString(@"transferForGUID:");
    if (![center respondsToSelector:lookup]) return nil;

    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(center, lookup, guid);
    } @catch (NSException *e) {
        IMBLog(@"transferForGUID threw: %@", e.reason);
        return nil;
    }
}

NSArray *IMBSerializeAttachments(id message) {
    NSArray *guids = safeValue(message, @"fileTransferGUIDs");
    if (![guids isKindOfClass:[NSArray class]] || guids.count == 0) return @[];

    NSMutableArray *out = [NSMutableArray array];
    for (NSString *guid in guids) {
        if (![guid isKindOfClass:[NSString class]]) continue;

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"guid"] = guid;

        id transfer = fileTransferForGUID(guid);
        if (!transfer) { [out addObject:entry]; continue; }

        NSString *filename = safeString(transfer, @"filename")
                          ?: safeString(transfer, @"originalFilename");
        if (filename) entry[@"filename"] = filename;

        NSString *mime = safeString(transfer, @"mimeType");
        if (mime) entry[@"mimeType"] = mime;

        // Prefer the permanent path; the transient one disappears.
        NSString *path = safeString(transfer, @"permanentHighQualityLocalPath")
                      ?: safeString(transfer, @"localPath");
        if (path) entry[@"localPath"] = path;

        id size = safeValue(transfer, @"totalBytes");
        if ([size respondsToSelector:@selector(longLongValue)]) {
            entry[@"sizeBytes"] = @([size longLongValue]);
        }

        // Messages transcribes audio messages on device, and the result is the
        // only readable account of what was said: an audio message's body is a
        // bare attachment placeholder, so without this a reader sees an
        // unplayable file where the app shows the words.
        //
        // `audioTranscriptionText` is where the UI reads it from, but it is
        // populated as the balloon is drawn rather than when the message
        // arrives, so on a message nobody has looked at it answers nil. The
        // transfer's own user info is where the text is actually kept, under
        // the same key the store holds it under, so that is preferred and the
        // property is the fallback rather than the other way round.
        NSString *transcript = nil;
        id info = safeValue(transfer, @"userInfo");
        if ([info isKindOfClass:[NSDictionary class]]) {
            id text = info[@"audio-transcription"];
            if ([text isKindOfClass:[NSString class]] && [text length]) transcript = text;
        }
        if (!transcript) transcript = safeString(transfer, @"audioTranscriptionText");
        if (transcript) entry[@"audioTranscript"] = transcript;

        // Not `isOpusAudioMessage`: that is true only of the newer encoding,
        // and answers no for the .caf recordings the app has been sending for
        // years, which are audio messages in every sense that matters here.
        id isAudio = safeValue(message, @"isAudioMessage");
        if ([isAudio respondsToSelector:@selector(boolValue)] && [isAudio boolValue]) {
            entry[@"isAudioMessage"] = @YES;
        }

        id sticker = safeValue(transfer, @"isSticker");
        if ([sticker respondsToSelector:@selector(boolValue)] && [sticker boolValue]) {
            entry[@"isSticker"] = @YES;
        }

        // What an image glyph depicts, in words. IMCore calls a Genmoji an
        // "adaptive image glyph"; without this a live reader sees an opaque
        // attachment where the store reader sees "a shark in a party hat".
        NSString *described = safeString(transfer, @"adaptiveImageGlyphContentDescription");
        if (described) entry[@"description"] = described;
        NSString *glyphID = safeString(transfer, @"adaptiveImageGlyphContentIdentifier");
        if (glyphID) entry[@"contentIdentifier"] = glyphID;

        // Which extension produced a sticker — the difference between a
        // Genmoji, a Memoji and a third-party pack.
        id stickerInfo = safeValue(transfer, @"stickerUserInfo");
        if ([stickerInfo isKindOfClass:[NSDictionary class]] &&
            [stickerInfo[@"pid"] isKindOfClass:[NSString class]]) {
            entry[@"stickerSource"] = stickerInfo[@"pid"];
        }

        [out addObject:entry];
    }
    return out;
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

/// Names IMCore's tapback type codes. 2000-2006 add a reaction; 3000-3006
/// remove the matching one.
///
/// 2006 is a reaction carrying an arbitrary emoji rather than one of the six
/// fixed shapes, which is what the emoji and Genmoji pickers send. It has no
/// name of its own — the emoji is the reaction — so the character is reported
/// alongside it.
NSString *IMBTapbackName(long long type) {
    switch (type >= 3000 ? type - 1000 : type) {
        case 2000: return @"love";
        case 2001: return @"like";
        case 2002: return @"dislike";
        case 2003: return @"laugh";
        case 2004: return @"emphasize";
        case 2005: return @"question";
        case 2006: return @"emoji";
        default:   return nil;
    }
}

/// Recovers the message GUID an association points at.
///
/// The target is addressed in one of two forms, and missing the second one
/// silently drops every reaction on a rich balloon:
///
///   "p:<index>/<guid>"  a message part — text, an attachment
///   "bp:<guid>"         a balloon message as a whole — a link, a poll
///
/// Both are prefixes ending in ':' or '/', and a GUID contains neither, so the
/// GUID is whatever follows the last of them.
NSString *IMBTapbackTargetGUID(NSString *associatedGUID) {
    if (![associatedGUID isKindOfClass:[NSString class]]) return nil;
    NSRange separator = [associatedGUID rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:@":/"]
                                                        options:NSBackwardsSearch];
    if (separator.location == NSNotFound) return associatedGUID;
    return [associatedGUID substringFromIndex:NSMaxRange(separator)];
}

/// Collects the reactions attached to one message part.
///
/// Tapbacks do not appear as their own entries in `chatItems`; IMCore hangs
/// them off the part they react to, which is also how the UI draws them.
static NSArray *tapbacksForItem(id item) {
    id associated = safeValue(item, @"visibleAssociatedMessageChatItems");
    if (![associated isKindOfClass:[NSArray class]] || [associated count] == 0) return nil;

    NSMutableArray *out = [NSMutableArray array];
    for (id reaction in associated) {
        id underlying = IMBUnderlyingMessage(reaction) ?: reaction;
        id typeValue = safeValue(underlying, @"associatedMessageType");
        if (![typeValue respondsToSelector:@selector(longLongValue)]) continue;

        long long type = [typeValue longLongValue];
        NSString *kind = IMBTapbackName(type);
        // A removal is not shown, and custom emoji reactions have no code.
        if (!kind || type >= 3000) continue;

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"kind"] = kind;

        NSDictionary *sender = IMBHandleInfo(safeValue(underlying, @"sender"));
        if (sender[@"id"]) entry[@"sender"] = sender[@"id"];
        if (sender[@"name"]) entry[@"senderName"] = sender[@"name"];

        NSString *emoji = safeString(underlying, @"associatedMessageEmoji");
        if (emoji) entry[@"emoji"] = emoji;

        id fromMe = safeValue(underlying, @"isFromMe");
        entry[@"isFromMe"] = @([fromMe boolValue]);

        [out addObject:entry];
    }
    return out.count ? out : nil;
}

/// Chat items that carry no user-visible content.
static BOOL isNoiseItem(id item) {
    NSString *cls = NSStringFromClass([item class]);
    return [cls isEqualToString:@"IMLoadMoreChatItem"]
        || [cls isEqualToString:@"IMDateChatItem"]
        || [cls isEqualToString:@"IMServiceChatItem"]
        || [cls isEqualToString:@"IMTypingChatItem"];
}

/// The IMMessage behind a chat item.
///
/// A single message surfaces as several part-items (text, attachment, plugin),
/// and identity and payload live on the message rather than the part — reading
/// the part alone is what produced entries with no sender and no text.
id IMBUnderlyingMessage(id item) {
    if (!item) return nil;
    if ([NSStringFromClass([item class]) isEqualToString:@"IMMessage"]) return item;

    for (NSString *key in @[@"message", @"_item", @"_message", @"item"]) {
        id candidate = safeValue(item, key);
        if (!candidate) continue;
        // An IMMessageItem is the storage form; prefer its IMMessage wrapper.
        id wrapped = safeValue(candidate, @"message");
        if (wrapped && safeValue(wrapped, @"guid")) return wrapped;
        if (safeValue(candidate, @"guid")) return candidate;
    }
    return nil;
}

/// Classifies a message by its balloon plugin, so callers can branch on kind
/// rather than string-matching bundle identifiers.
static NSString *balloonKind(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    if ([bundleID containsString:@"URLBalloonProvider"]) return @"link";
    if ([bundleID containsString:@"com.apple.messages.Polls"]) return @"poll";
    if ([bundleID containsString:@"PhotosMessagesApp"]) return @"photos";
    if ([bundleID containsString:@"FindMyMessagesApp"]) return @"findmy";
    if ([bundleID containsString:@"MSMessageExtensionBalloonPlugin"]) return @"app";
    return @"app";
}

/// Pulls mentions, links and detected data out of the message body.
///
/// The body is an attributed string whose runs carry IMCore's private
/// attributes. Reading them is how a caller learns who was @-mentioned and
/// which URL a rich link points at — the link balloon's own payload archives a
/// private `RichLink` class that is not loadable here, so this is the reliable
/// route to the URL.
static void addTextFeatures(NSMutableDictionary *out, id message) {
    id body = safeValue(message, @"text");
    if (![body isKindOfClass:[NSAttributedString class]]) return;

    NSAttributedString *attributed = body;
    if (attributed.length == 0) return;

    NSMutableArray *mentions = [NSMutableArray array];
    NSMutableArray *links = [NSMutableArray array];
    NSString *plain = attributed.string;

    [attributed enumerateAttributesInRange:NSMakeRange(0, attributed.length)
                                   options:0
                                usingBlock:^(NSDictionary<NSString *, id> *attrs,
                                             NSRange range, BOOL *stop) {
        NSString *substring = @"";
        if (NSMaxRange(range) <= plain.length) substring = [plain substringWithRange:range];

        id handle = attrs[@"__kIMMentionConfirmedMention"];
        if ([handle isKindOfClass:[NSString class]]) {
            [mentions addObject:@{
                @"handle": handle,
                @"text": substring,
                @"location": @(range.location),
                @"length": @(range.length),
            }];
        }

        id link = attrs[@"__kIMLinkAttributeName"];
        if (link) {
            NSString *url = [link isKindOfClass:[NSString class]]
                          ? link : [link absoluteString];
            if (url.length) {
                [links addObject:@{
                    @"url": url,
                    @"text": substring,
                    @"isRichLink": @([attrs[@"__kIMLinkIsRichLinkAttributeName"] boolValue]),
                }];
            }
        }
    }];

    if (mentions.count) out[@"mentions"] = mentions;
    if (links.count) out[@"links"] = links;
}

/// Rich-payload fields: link previews, polls, effects, stickers and threading.
void IMBAddRichFields(NSMutableDictionary *out, id message) {
    if (!message) return;
    addTextFeatures(out, message);

    NSString *bundleID = safeString(message, @"balloonBundleID");
    if (bundleID) {
        out[@"balloonBundleID"] = bundleID;
        NSString *kind = balloonKind(bundleID);
        if (kind) out[@"kind"] = kind;
    }

    // Messages computes a human-readable summary for plugin balloons (the poll
    // question, the link title), which is exactly what a reader needs.
    NSString *summary = safeString(message, @"summaryString");
    if (summary) out[@"summary"] = summary;

    id isRichLink = safeValue(message, @"isRichLinkMessage");
    if ([isRichLink respondsToSelector:@selector(boolValue)] && [isRichLink boolValue]) {
        out[@"kind"] = @"link";
    }

    // Link previews and polls carry their content in the balloon payload.
    // Decoded here so a reader gets the title, or the question and its options,
    // rather than a blob it has to understand itself. The raw bytes are passed
    // through only for plugins with no decoder.
    id payload = safeValue(message, @"payloadData");
    if ([payload isKindOfClass:[NSData class]] && [payload length]) {
        NSDictionary *decoded = bundleID ? IMBDecodePayload(payload, bundleID) : nil;
        if (decoded[@"link"]) out[@"link"] = decoded[@"link"];
        else if (decoded[@"poll"]) out[@"poll"] = decoded[@"poll"];
        else out[@"payloadData"] = [(NSData *)payload base64EncodedStringWithOptions:0];
    }

    NSString *effect = safeString(message, @"expressiveSendStyleID");
    if (effect) out[@"effect"] = effect;

    NSString *thread = safeString(message, @"threadIdentifier");
    if (thread) out[@"threadIdentifier"] = thread;

    // Tapbacks and replies both point at another message.
    NSString *assocGuid = safeString(message, @"associatedMessageGUID");
    if (assocGuid) out[@"associatedMessageGUID"] = assocGuid;

    NSString *assocEmoji = safeString(message, @"associatedMessageEmoji");
    if (assocEmoji) out[@"associatedMessageEmoji"] = assocEmoji;

    id assocType = safeValue(message, @"associatedMessageType");
    if ([assocType respondsToSelector:@selector(longLongValue)] &&
        [assocType longLongValue] != 0) {
        out[@"associatedMessageType"] = @([assocType longLongValue]);
        out[@"kind"] = @"tapback";
    }

    id edited = safeValue(message, @"dateEdited");
    if ([edited isKindOfClass:[NSDate class]]) {
        out[@"dateEdited"] = @([(NSDate *)edited timeIntervalSince1970]);
    }
    id retracted = safeValue(message, @"dateRetracted");
    if ([retracted isKindOfClass:[NSDate class]]) {
        out[@"dateRetracted"] = @([(NSDate *)retracted timeIntervalSince1970]);
        out[@"kind"] = @"retracted";
    }

    // Everything an edit or an unsend leaves behind lives in the summary info,
    // which a live message already holds as a dictionary — the version chain,
    // and whether a retraction reached the other side. Deep history has
    // reported these for a while; without them here, a reader watching a
    // conversation as it happens sees strictly less than one reading it later.
    id summaryInfo = safeValue(message, @"messageSummaryInfo");
    if ([summaryInfo isKindOfClass:[NSDictionary class]]) {
        // A message with every part retracted is unsent; IMCore keeps the
        // indexes rather than a count.
        id retractedParts = safeValue(message, @"retractedPartIndexes");
        long long remaining = 1;
        if ([retractedParts respondsToSelector:@selector(count)]) {
            id partCount = safeValue(message, @"partCount");
            long long parts = [partCount respondsToSelector:@selector(longLongValue)]
                            ? [partCount longLongValue] : 0;
            remaining = parts ? parts : ([retractedParts count] ? 0 : 1);
        }
        NSDictionary *fields = IMBSummaryFields(summaryInfo, remaining);
        for (NSString *key in fields) out[key] = fields[key];
    }

    // A message being held for later delivery, as Send Later leaves it.
    id scheduleType = safeValue(message, @"scheduleType");
    if ([scheduleType respondsToSelector:@selector(longLongValue)] &&
        [scheduleType longLongValue] != 0) {
        out[@"scheduleType"] = @([scheduleType longLongValue]);
        id when = safeValue(message, @"time");
        if ([when isKindOfClass:[NSDate class]]) {
            out[@"scheduledFor"] = @([(NSDate *)when timeIntervalSince1970]);
        }
    }
}

/// Asks IMCore to page older messages into memory.
///
/// `chatItems` only holds what the UI has loaded — typically a handful of rows
/// for a chat nobody has opened — so reading it directly returns almost
/// nothing. This primes it; the load is asynchronous, so the caller reads back
/// after a short delay.
void IMBRequestHistoryLoad(id chat, NSUInteger limit) {
    SEL beforeDate = NSSelectorFromString(@"loadMessagesBeforeDate:limit:");
    if ([chat respondsToSelector:beforeDate]) {
        @try {
            // Pass an explicit far-future date, never nil. A nil date reads as
            // the distant past, so IMCore loads "messages before the beginning
            // of time" — nothing — and replaces the chat's loaded window with
            // an empty one. The stored messages are untouched, but the
            // conversation renders blank in Messages.app until it reloads.
            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
                chat, beforeDate, [NSDate distantFuture], limit);
            return;
        } @catch (NSException *e) {
            IMBLog(@"loadMessagesBeforeDate threw: %@", e.reason);
        }
    }
    IMBLog(@"no history-loading selector available");
}

/// The most recent `limit` messages for a chat, newest first.
///
/// One message can appear as several chat items (a text part, an attachment
/// part, a plugin part). They are merged back into a single entry keyed by the
/// message GUID so callers see one message per message, with its text and all
/// of its attachments together.
NSArray *IMBChatHistory(id chat, NSUInteger limit) {
    NSArray *items = safeValue(chat, @"chatItems");
    if (![items isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *byGUID =
        [NSMutableDictionary dictionary];

    for (id item in items) {
        if (order.count >= limit) break;
        if (isNoiseItem(item)) continue;

        id message = IMBUnderlyingMessage(item);
        // Prefer the message's GUID; fall back to the item's so a part with no
        // resolvable message is still reported rather than silently dropped.
        NSString *guid = safeString(message, @"guid") ?: safeString(item, @"guid");
        if (!guid) continue;

        // A group event is not a message and carries no text, so it would
        // otherwise land in the transcript as a blank entry where the app draws
        // "Ada added Ben".
        NSDictionary *event = IMBGroupEventForItem(item);

        NSMutableDictionary *entry = byGUID[guid];
        if (!entry) {
            entry = [NSMutableDictionary dictionary];
            entry[@"guid"] = guid;
            byGUID[guid] = entry;
            [order addObject:guid];
        }
        if (event) {
            entry[@"event"] = event;
            entry[@"kind"] = @"event";
        }

        // Identity and body come from the message; parts often carry neither.
        NSMutableDictionary *base =
            [IMBSerializeMessage(message ?: item, chat) mutableCopy];
        for (NSString *key in base) {
            id value = base[key];
            if (value && !entry[key]) entry[key] = value;
        }
        if (message) IMBAddRichFields(entry, message);

        // A part may hold text the parent message does not (multi-part bodies).
        if (!entry[@"text"]) {
            NSString *partText = safeString(item, @"text");
            if (partText) entry[@"text"] = partText;
        }

        NSArray *attachments = IMBSerializeAttachments(message ?: item);
        if (attachments.count == 0) attachments = IMBSerializeAttachments(item);
        if (attachments.count) {
            NSMutableArray *merged = [entry[@"attachments"] mutableCopy] ?: [NSMutableArray array];
            NSMutableSet *seen = [NSMutableSet set];
            for (NSDictionary *a in merged) if (a[@"guid"]) [seen addObject:a[@"guid"]];
            for (NSDictionary *a in attachments) {
                if (a[@"guid"] && [seen containsObject:a[@"guid"]]) continue;
                if (a[@"guid"]) [seen addObject:a[@"guid"]];
                [merged addObject:a];
            }
            entry[@"attachments"] = merged;
        }

        // Reactions live on the part, so collect them while we have it.
        NSArray *tapbacks = tapbacksForItem(item);
        if (tapbacks.count) {
            NSMutableArray *merged = [entry[@"tapbacks"] mutableCopy] ?: [NSMutableArray array];
            [merged addObjectsFromArray:tapbacks];
            entry[@"tapbacks"] = merged;
        }

        NSMutableArray *classes = entry[@"itemClasses"] ?: [NSMutableArray array];
        NSString *cls = NSStringFromClass([item class]);
        if (![classes containsObject:cls]) [classes addObject:cls];
        entry[@"itemClasses"] = classes;
    }

    // Fold tapbacks onto the messages they react to. A person sees "❤️ ×2" on a
    // bubble, not two extra rows in the transcript, so they are attached to the
    // target and dropped from the top level.
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:order.count];
    for (NSString *guid in order) {
        NSMutableDictionary *entry = byGUID[guid];
        if (!entry[@"kind"]) {
            entry[@"kind"] = entry[@"attachments"] ? @"attachment" : @"text";
        }

        NSString *targetGUID = IMBTapbackTargetGUID(entry[@"associatedMessageGUID"]);
        NSMutableDictionary *target = targetGUID ? byGUID[targetGUID] : nil;
        if (target && entry[@"associatedMessageType"]) {
            long long type = [entry[@"associatedMessageType"] longLongValue];
            BOOL removed = type >= 3000;
            NSString *kind = IMBTapbackName(type);

            NSMutableArray *tapbacks = target[@"tapbacks"] ?: [NSMutableArray array];
            // A removal cancels the matching reaction from the same person.
            NSUInteger existing = [tapbacks indexOfObjectPassingTest:
                ^BOOL(NSDictionary *t, NSUInteger i, BOOL *stop) {
                    return [t[@"kind"] isEqual:kind] &&
                           [t[@"sender"] ?: [NSNull null] isEqual:entry[@"sender"] ?: [NSNull null]];
                }];
            if (removed) {
                if (existing != NSNotFound) [tapbacks removeObjectAtIndex:existing];
            } else if (existing == NSNotFound && kind) {
                NSMutableDictionary *tapback = [NSMutableDictionary dictionary];
                tapback[@"kind"] = kind;
                if (entry[@"sender"]) tapback[@"sender"] = entry[@"sender"];
                if (entry[@"senderName"]) tapback[@"senderName"] = entry[@"senderName"];
                if (entry[@"associatedMessageEmoji"]) {
                    tapback[@"emoji"] = entry[@"associatedMessageEmoji"];
                }
                tapback[@"isFromMe"] = entry[@"isFromMe"] ?: @NO;
                [tapbacks addObject:tapback];
            }
            target[@"tapbacks"] = tapbacks;
            continue;   // handled: do not surface the reaction as its own message
        }

        [out addObject:entry];
    }
    return out;
}
