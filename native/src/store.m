// Message-store reader: deep history and search-hit resolution from chat.db.
//
// The store is read with sqlite, opened read-only and *inside* Messages.app.
// Running inside the host matters for two reasons: Messages already holds the
// TCC grant for ~/Library/Messages (no Full Disk Access prompt), and IMCore's
// own message-loading classes (IMDMessageStore and friends) live in imagent,
// not in this process, so there is no in-process API to reuse.
//
// The handle is opened with mode=ro rather than immutable=1 on purpose.
// immutable=1 would take a fixed snapshot by ignoring the WAL, which both
// misses recent messages and risks a torn read while imagent is checkpointing.
// mode=ro follows the WAL like any other reader: consistent rows, current data,
// and never a writer, so the running imagent is never blocked or corrupted.
//
// Every statement is prepared, bounded, and wrapped so a sqlite error becomes
// an RPC error rather than a crash in the host app.
#import "bridge.h"
#include <pthread.h>
#include <pwd.h>
#include <sqlite3.h>
#include <unistd.h>

// One shared connection. sqlite serializes access to a single handle, so a
// mutex makes concurrent history requests safe without a connection pool.
static sqlite3 *gDB;
static pthread_mutex_t gDBLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL gOpenAttempted;

/// The real home directory.
///
/// Inside Messages.app NSHomeDirectory() resolves to the sandbox container, not
/// the real home — and there is no container mirror of the message store. Its
/// files live at the canonical home path, which the sandbox's TCC grant for
/// Messages data does cover.
static NSString *IMBRealHome(void) {
    return @(getpwuid(getuid())->pw_dir);
}

static NSString *IMBChatDBPath(void) {
    return [IMBRealHome() stringByAppendingPathComponent:@"Library/Messages/chat.db"];
}

/// Opens the shared read-only handle, once. Returns NO when the store is
/// unreadable; the caller turns that into a clean RPC error.
static BOOL storeOpen(void) {
    pthread_mutex_lock(&gDBLock);
    if (gDB) { pthread_mutex_unlock(&gDBLock); return YES; }
    if (gOpenAttempted) { pthread_mutex_unlock(&gDBLock); return NO; }
    gOpenAttempted = YES;

    NSString *uri = [NSString stringWithFormat:@"file:%@?mode=ro", IMBChatDBPath()];
    int rc = sqlite3_open_v2([uri UTF8String], &gDB,
                             SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL);
    if (rc != SQLITE_OK) {
        IMBLog(@"chat.db open failed: %d", rc);
        if (gDB) { sqlite3_close(gDB); gDB = NULL; }
        pthread_mutex_unlock(&gDBLock);
        return NO;
    }
    // Tolerate a briefly busy store rather than erroring out of a read.
    sqlite3_busy_timeout(gDB, 5000);
    pthread_mutex_unlock(&gDBLock);
    return YES;
}

// ---------------------------------------------------------------------------
// Row -> JSON
// ---------------------------------------------------------------------------

/// Cocoa epoch (2001-01-01) to Unix epoch (1970-01-01), in seconds.
static const long long kCocoaEpochOffset = 978307200;

/// A column value is NSNull when the column is NULL, and NSNull answers none of
/// the accessors below. Reading one straight off a row is what turns a NULL
/// handle into an unrecognised-selector abort *inside Messages*, so every read
/// of a decoded row goes through these.
static long long longValue(id value) {
    return [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0;
}

static NSString *stringValue(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}

static id columnValue(sqlite3_stmt *st, int i) {
    switch (sqlite3_column_type(st, i)) {
        case SQLITE_INTEGER: return @(sqlite3_column_int64(st, i));
        case SQLITE_FLOAT:   return @(sqlite3_column_double(st, i));
        case SQLITE_TEXT: {
            const unsigned char *t = sqlite3_column_text(st, i);
            return t ? @( (const char *)t ) : @"";
        }
        case SQLITE_BLOB: {
            const void *b = sqlite3_column_blob(st, i);
            int n = sqlite3_column_bytes(st, i);
            if (!b || n <= 0) return @"";
            NSData *d = [NSData dataWithBytes:b length:(NSUInteger)n];
            return [d base64EncodedStringWithOptions:0];
        }
        default: return [NSNull null];
    }
}

/// Reads one message row into a plain dictionary. Times are converted to Unix
/// seconds and blobs to base64; everything else passes through by name.
///
/// The body gets special handling: most rows have no plain `text` and keep it
/// in `attributedBody`, so that blob is decoded here into readable text and its
/// runs. The raw bytes are only passed through when decoding fails, which keeps
/// pages small without ever losing a message.
static NSDictionary *messageRow(sqlite3_stmt *st) {
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    int cols = sqlite3_column_count(st);
    NSData *bodyBlob = nil, *payloadBlob = nil, *summaryBlob = nil;
    NSString *bundleID = nil;

    // Columns that only exist to describe a group event. They are NULL or 0 on
    // every ordinary message, so they are collected here and reported as one
    // `event` rather than as six mostly-empty fields on every row.
    long long itemType = 0, actionType = 0, shareStatus = 0, shareDirection = 0;
    long long partCount = 0, hasAttachments = 0;
    NSString *groupTitle = nil, *otherHandle = nil;

    for (int i = 0; i < cols; i++) {
        NSString *name = @(sqlite3_column_name(st, i));

        if ([name isEqualToString:@"attributedBody"] ||
            [name isEqualToString:@"payload_data"] ||
            [name isEqualToString:@"message_summary_info"]) {
            const void *b = sqlite3_column_blob(st, i);
            int n = sqlite3_column_bytes(st, i);
            if (b && n > 0) {
                NSData *blob = [NSData dataWithBytes:b length:(NSUInteger)n];
                if ([name isEqualToString:@"attributedBody"]) bodyBlob = blob;
                else if ([name isEqualToString:@"payload_data"]) payloadBlob = blob;
                else summaryBlob = blob;
            }
            continue;
        }

        id v = columnValue(st, i);
        if ([name isEqualToString:@"balloon_bundle_id"] &&
            [v isKindOfClass:[NSString class]] && [v length]) {
            bundleID = v;
        }
        if ([name hasPrefix:@"date"] && [v isKindOfClass:[NSNumber class]]) {
            long long t = [v longLongValue];
            // Store timestamps are Cocoa seconds; some are nanoseconds. Zero
            // means "never" — read, delivered and edited are all 0 until they
            // happen — and shifting it by the epoch would date those events to
            // 2001 instead of leaving them unset.
            if (t > 1000000000000000LL) t /= 1000000000LL;
            v = @(t ? t + kCocoaEpochOffset : 0);
        }

        if ([name isEqualToString:@"part_count"]) partCount = longValue(v);
        if ([name isEqualToString:@"cache_has_attachments"]) hasAttachments = longValue(v);

        if ([name isEqualToString:@"item_type"])        { itemType = longValue(v); }
        else if ([name isEqualToString:@"group_action_type"]) { actionType = longValue(v); continue; }
        else if ([name isEqualToString:@"share_status"])      { shareStatus = longValue(v); continue; }
        else if ([name isEqualToString:@"share_direction"])   { shareDirection = longValue(v); continue; }
        else if ([name isEqualToString:@"group_title"])  { groupTitle = stringValue(v); continue; }
        else if ([name isEqualToString:@"otherHandle"])  { otherHandle = stringValue(v); continue; }
        row[name] = v;
    }

    // The grey lines a group conversation is punctuated with.
    NSDictionary *event = IMBGroupEvent(itemType, actionType, groupTitle,
                                        stringValue(row[@"sender"]), otherHandle,
                                        hasAttachments != 0, shareStatus, shareDirection);
    if (event) row[@"event"] = event;

    // Earlier versions of an edited message, whether an unsend reached the
    // other side, and the time a scheduled message is being held for.
    if (summaryBlob) {
        NSDictionary *summary = IMBDecodeSummaryInfo(summaryBlob, partCount);
        for (NSString *key in summary) row[key] = summary[key];
    }

    // A scheduled message's delivery time is its own timestamp: IMCore dates it
    // into the future and holds it until then. Naming it makes the row read the
    // way the app words it, rather than as a message sent in the future.
    if (longValue(row[@"schedule_type"]) && row[@"date"]) {
        row[@"scheduledFor"] = row[@"date"];
    }

    if (bodyBlob) {
        NSDictionary *decoded = IMBDecodeAttributedBody(bodyBlob);
        if (decoded) {
            // The decoded body is the message text; the stored `text` column is
            // usually empty and never richer than this.
            NSString *text = decoded[@"text"];
            if ([text isKindOfClass:[NSString class]] && text.length) row[@"text"] = text;
            for (NSString *key in @[@"parts", @"mentions", @"links"]) {
                if (decoded[key]) row[key] = decoded[key];
            }
        } else {
            row[@"attributedBody"] = [bodyBlob base64EncodedStringWithOptions:0];
        }
    }

    // A link preview or poll carries its content in the balloon payload.
    if (payloadBlob) {
        NSDictionary *decoded = bundleID ? IMBDecodePayload(payloadBlob, bundleID) : nil;
        if (decoded[@"link"]) row[@"link"] = decoded[@"link"];
        else if (decoded[@"poll"]) row[@"poll"] = decoded[@"poll"];
        else row[@"payload_data"] = [payloadBlob base64EncodedStringWithOptions:0];
    }
    return row;
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

// Message columns worth returning. The store has many bookkeeping columns;
// only the ones a reader needs are selected, and blobs are left base64 for the
// TypeScript side to decode into typed parts.
static NSString *const kMessageColumns =
    @"m.ROWID AS rowid, m.guid, m.text, m.subject, m.attributedBody, h.id AS sender, "
    @"m.service, m.account, m.error, m.date, m.date_read, m.date_delivered, "
    @"m.date_played, m.is_delivered, m.is_finished, m.is_from_me, m.is_read, "
    @"m.is_sent, m.is_played, m.is_audio_message, m.is_spam, m.is_empty, "
    @"m.was_downgraded, m.is_kt_verified, m.is_time_sensitive, "
    @"m.was_delivered_quietly, m.is_expirable, m.expire_state, "
    @"m.associated_message_guid, m.associated_message_type, m.associated_message_emoji, "
    @"m.balloon_bundle_id, m.payload_data, m.expressive_send_style_id, "
    @"m.message_summary_info, m.reply_to_guid, m.thread_originator_guid, "
    @"m.date_edited, m.date_retracted, m.part_count, "
    @"m.schedule_type, m.schedule_state, m.cache_has_attachments, "
    // Group events: NULL or 0 on an ordinary message, folded into `event`.
    @"m.item_type, m.group_action_type, m.group_title, oh.id AS otherHandle, "
    @"m.share_status, m.share_direction";

/// The sender's handle lives in its own table; a bare `handle_id` is a row
/// number nobody can read. `other_handle` names the person a group event is
/// *about*, as opposed to the one who performed it.
static NSString *const kMessageJoins =
    @"LEFT JOIN handle h ON h.ROWID = m.handle_id "
    @"LEFT JOIN handle oh ON oh.ROWID = m.other_handle ";

/// Reads a row whose columns need no decoding, by name.
static NSDictionary *plainRow(sqlite3_stmt *st) {
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    for (int i = 0, cols = sqlite3_column_count(st); i < cols; i++) {
        row[@(sqlite3_column_name(st, i))] = columnValue(st, i);
    }
    return row;
}

static NSArray *runQueryReading(NSString *sql, NSArray *bind,
                                NSDictionary *(^reader)(sqlite3_stmt *),
                                NSString **errCode, NSString **errMessage) {
    if (!storeOpen()) {
        if (errCode) *errCode = @"store_unavailable";
        if (errMessage) *errMessage = @"could not open the message store";
        return nil;
    }

    pthread_mutex_lock(&gDBLock);
    sqlite3_stmt *st = NULL;
    int rc = sqlite3_prepare_v2(gDB, [sql UTF8String], -1, &st, NULL);
    if (rc != SQLITE_OK) {
        IMBLog(@"prepare failed: %d %s", rc, sqlite3_errmsg(gDB));
        pthread_mutex_unlock(&gDBLock);
        if (errCode) *errCode = @"store_error";
        if (errMessage) *errMessage = @"message store query failed";
        return nil;
    }
    // Placeholders are written ?1 ?2 ?3, but sqlite binds by parameter index
    // (1..N in order of appearance), not by the label. A query that skips ?2
    // still expects the second bound value at index 2.
    int i = 1;
    for (id b in bind) {
        if ([b isKindOfClass:[NSNumber class]]) sqlite3_bind_int64(st, i, [b longLongValue]);
        else sqlite3_bind_text(st, i, [[b description] UTF8String], -1, SQLITE_TRANSIENT);
        i++;
    }
    int expected = sqlite3_bind_parameter_count(st);
    if (i - 1 != expected) {
        IMBLog(@"bind count mismatch: bound %d, statement wants %d (%@)",
               i - 1, expected, sql);
        sqlite3_finalize(st);
        pthread_mutex_unlock(&gDBLock);
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = @"query built with the wrong number of parameters";
        return nil;
    }

    NSMutableArray *rows = [NSMutableArray array];
    // Reading a row decodes archives and plists written by other software and
    // by older releases. A malformed one must fail the request, not the host:
    // an uncaught exception here aborts Messages and takes the user's app down
    // mid-conversation.
    @try {
        while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
            [rows addObject:reader(st)];
        }
    } @catch (NSException *e) {
        IMBLog(@"row decode threw: %@ (%@)", e.name, e.reason);
        sqlite3_finalize(st);
        pthread_mutex_unlock(&gDBLock);
        if (errCode) *errCode = @"store_error";
        if (errMessage) *errMessage = @"a stored row could not be decoded";
        return nil;
    }
    int stepRc = rc;
    sqlite3_finalize(st);
    pthread_mutex_unlock(&gDBLock);

    if (stepRc != SQLITE_DONE) {
        IMBLog(@"chat.db read failed: rc=%d (%s) sql=%@", stepRc, sqlite3_errmsg(gDB), sql);
        if (errCode) *errCode = @"store_error";
        if (errMessage) *errMessage = [NSString stringWithFormat:
            @"message store read failed (%s)", sqlite3_errmsg(gDB)];
        return nil;
    }
    return rows;
}

static NSArray *runQuery(NSString *sql, NSArray *bind,
                         NSString **errCode, NSString **errMessage) {
    return runQueryReading(sql, bind, ^(sqlite3_stmt *st) { return messageRow(st); },
                           errCode, errMessage);
}

// ---------------------------------------------------------------------------
// Attachments
// ---------------------------------------------------------------------------

/// Attachment columns worth returning.
///
/// `user_info` is read but never returned. It holds the iCloud transfer's URL
/// and decryption key, which say nothing about what was sent and must not be
/// handed out — but it is also where an audio message's transcript lives, so
/// exactly one key is lifted out of it and the rest is dropped.
static NSString *const kAttachmentColumns =
    @"j.message_id AS messageRowID, a.guid, a.filename, a.uti, a.mime_type, "
    @"a.total_bytes, a.transfer_state, a.is_outgoing, a.is_sticker, "
    @"a.sticker_user_info, a.user_info, a.hide_attachment, a.is_commsafety_sensitive, "
    @"a.emoji_image_content_identifier, a.emoji_image_short_description";

/// Reads an audio message's transcript out of its `user_info` plist.
///
/// Messages transcribes audio messages on device and files the result under
/// `audio-transcription` here, which is the only readable account of what was
/// said: nothing lands in the message's own `text`, whose body is a single
/// attachment placeholder. Without it a reader sees "Audio Message.caf" and an
/// unreadable file where the app shows the words.
///
/// The surrounding plist is the iCloud transfer's URL and decryption key, so
/// this returns the one key and never the dictionary.
static NSString *audioTranscript(NSString *base64) {
    if (!base64.length) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (!data.length) return nil;
    @try {
        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                            options:NSPropertyListImmutable
                                                             format:NULL
                                                              error:NULL];
        id text = [plist isKindOfClass:[NSDictionary class]] ? plist[@"audio-transcription"] : nil;
        return ([text isKindOfClass:[NSString class]] && [text length]) ? text : nil;
    } @catch (NSException *e) {
        return nil;
    }
}

/// Reads the sticker's origin out of its `sticker_user_info` plist.
///
/// A sticker's bytes say nothing about where it came from; the plist names the
/// extension that produced it, which is the difference between a Memoji, a
/// third-party sticker pack and one the sender made from a photo.
static NSString *stickerSource(NSString *base64) {
    if (!base64.length) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (!data.length) return nil;
    @try {
        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                            options:NSPropertyListImmutable
                                                             format:NULL
                                                              error:NULL];
        id pid = [plist isKindOfClass:[NSDictionary class]] ? plist[@"pid"] : nil;
        return [pid isKindOfClass:[NSString class]] ? pid : nil;
    } @catch (NSException *e) {
        return nil;
    }
}

/// Every attachment on the given message rowids, grouped by message.
///
/// Deep history without this reads a photo, a voice note or a Genmoji as an
/// empty message: the row carries no text, and everything that says what was
/// sent lives in another table.
static NSDictionary<NSNumber *, NSMutableArray *> *attachmentsFor(NSArray *messages) {
    NSMutableArray *rowids = [NSMutableArray array];
    for (NSDictionary *message in messages) {
        // `cache_has_attachments` is the row's own answer; asking only for the
        // messages that claim one keeps the IN list short on a text-only page.
        if (longValue(message[@"cache_has_attachments"]) &&
            [message[@"rowid"] isKindOfClass:[NSNumber class]]) {
            [rowids addObject:message[@"rowid"]];
        }
    }
    if (!rowids.count) return @{};

    NSMutableString *placeholders = [NSMutableString string];
    for (NSUInteger i = 0; i < rowids.count; i++) [placeholders appendString:(i ? @",?" : @"?")];

    NSString *sql = [NSString stringWithFormat:
        @"SELECT %@, m.is_audio_message FROM attachment a "
        @"INNER JOIN message_attachment_join j ON j.attachment_id = a.ROWID "
        @"INNER JOIN message m ON m.ROWID = j.message_id "
        @"WHERE j.message_id IN (%@) ORDER BY a.ROWID", kAttachmentColumns, placeholders];

    NSArray *rows = runQueryReading(sql, rowids, ^(sqlite3_stmt *st) { return plainRow(st); },
                                    NULL, NULL);
    NSString *home = IMBRealHome();
    NSMutableDictionary *byMessage = [NSMutableDictionary dictionary];

    for (NSDictionary *row in rows) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"guid"] = row[@"guid"] ?: @"";

        NSString *filename = stringValue(row[@"filename"]);
        if (filename) {
            // Stored paths are written against the real home as "~/Library/…";
            // inside the sandbox that expands to the container, which does not
            // contain them.
            entry[@"localPath"] = [filename hasPrefix:@"~/"]
                ? [home stringByAppendingPathComponent:[filename substringFromIndex:2]]
                : filename;
            entry[@"filename"] = [filename lastPathComponent];
        }
        if (stringValue(row[@"mime_type"])) entry[@"mimeType"] = row[@"mime_type"];
        if (stringValue(row[@"uti"]))       entry[@"uti"] = row[@"uti"];
        entry[@"sizeBytes"] = @(longValue(row[@"total_bytes"]));
        entry[@"transferState"] = @(longValue(row[@"transfer_state"]));
        if (longValue(row[@"is_outgoing"])) entry[@"isOutgoing"] = @YES;
        if (longValue(row[@"is_sticker"]))  entry[@"isSticker"] = @YES;
        // Not downloaded, or withheld by Communication Safety — either way the
        // file at `localPath` is not there to read.
        if (longValue(row[@"hide_attachment"])) entry[@"hidden"] = @YES;
        if (longValue(row[@"is_commsafety_sensitive"])) entry[@"sensitive"] = @YES;

        NSString *source = stickerSource(stringValue(row[@"sticker_user_info"]));
        if (source) entry[@"stickerSource"] = source;

        // Whether this is a recorded voice message rather than an audio file
        // someone attached is a property of the message, but it is answered
        // here so that both read paths describe an attachment the same way.
        if (longValue(row[@"is_audio_message"])) entry[@"isAudioMessage"] = @YES;

        NSString *spoken = audioTranscript(stringValue(row[@"user_info"]));
        if (spoken) entry[@"audioTranscript"] = spoken;

        // What an image glyph depicts, in words. Messages stores it for
        // accessibility; for a reader it is the difference between "an image"
        // and knowing a Genmoji of a shark in a party hat was sent.
        if (stringValue(row[@"emoji_image_short_description"])) {
            entry[@"description"] = row[@"emoji_image_short_description"];
        }
        if (stringValue(row[@"emoji_image_content_identifier"])) {
            entry[@"contentIdentifier"] = row[@"emoji_image_content_identifier"];
        }

        NSNumber *messageID = row[@"messageRowID"];
        NSMutableArray *list = byMessage[messageID];
        if (!list) { list = [NSMutableArray array]; byMessage[messageID] = list; }
        [list addObject:entry];
    }
    return byMessage;
}

/// Attaches each message's attachments to it.
static NSArray *addAttachments(NSArray *messages) {
    NSDictionary *byMessage = attachmentsFor(messages);
    if (!byMessage.count) return messages;

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:messages.count];
    for (NSDictionary *message in messages) {
        NSArray *attachments = byMessage[message[@"rowid"]];
        if (!attachments.count) { [out addObject:message]; continue; }
        NSMutableDictionary *entry = [message mutableCopy];
        entry[@"attachments"] = attachments;
        [out addObject:entry];
    }
    return out;
}

// ---------------------------------------------------------------------------
// Folding associated messages onto their target
// ---------------------------------------------------------------------------
//
// Reactions, poll votes and poll edits are stored as ordinary messages that
// point at another one. A person reading the conversation never sees them as
// separate entries: a reaction is drawn on the bubble it reacts to, and a vote
// changes the tally inside the poll. Deep history is folded the same way, so a
// page reads like the transcript rather than like the table.

/// A sticker stuck onto a bubble, rather than sent as its own message.
static const long long kStickerAssociation = 1000;

/// Attaches one reaction to the message it reacts to, honouring removals.
static void applyTapback(NSMutableDictionary *target, NSDictionary *reaction) {
    long long type = [reaction[@"associated_message_type"] longLongValue];
    NSString *kind = IMBTapbackName(type);
    if (!kind) return;

    BOOL isFromMe = [reaction[@"is_from_me"] boolValue];
    NSString *sender = [reaction[@"sender"] isKindOfClass:[NSString class]]
        ? reaction[@"sender"] : nil;

    NSString *emoji = [reaction[@"associated_message_emoji"] isKindOfClass:[NSString class]]
        ? reaction[@"associated_message_emoji"] : nil;

    NSMutableArray *tapbacks = [target[@"tapbacks"] mutableCopy] ?: [NSMutableArray array];
    // An emoji reaction is identified by its character too: one person can
    // leave two of them, and removing one must not take the other with it.
    NSUInteger existing = [tapbacks indexOfObjectPassingTest:
        ^BOOL(NSDictionary *t, NSUInteger i, BOOL *stop) {
            return [t[@"kind"] isEqual:kind]
                && [t[@"isFromMe"] boolValue] == isFromMe
                && ((!t[@"sender"] && !sender) || [t[@"sender"] isEqual:sender])
                && ((!t[@"emoji"] && !emoji) || [t[@"emoji"] isEqual:emoji]);
        }];

    if (type >= 3000) {
        if (existing != NSNotFound) [tapbacks removeObjectAtIndex:existing];
    } else if (existing == NSNotFound) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"kind"] = kind;
        entry[@"isFromMe"] = @(isFromMe);
        if (sender) entry[@"sender"] = sender;
        if (emoji) entry[@"emoji"] = emoji;
        [tapbacks addObject:entry];
    }
    target[@"tapbacks"] = tapbacks;
}

/// Attaches a sticker to the bubble it was stuck onto.
///
/// A sticker placed on a message is stored as its own message carrying the
/// image, associated with its target. The UI draws it on the bubble, not as a
/// message of its own, so it folds like a reaction.
static void applySticker(NSMutableDictionary *target, NSDictionary *sticker) {
    NSMutableArray *stickers = [target[@"stickers"] mutableCopy] ?: [NSMutableArray array];
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"guid"] = sticker[@"guid"] ?: @"";
    entry[@"isFromMe"] = @([sticker[@"is_from_me"] boolValue]);
    if ([sticker[@"sender"] isKindOfClass:[NSString class]]) entry[@"sender"] = sticker[@"sender"];
    if (sticker[@"date"]) entry[@"date"] = sticker[@"date"];
    // The image is the sticker; folding the row away without it would leave a
    // note that one was placed and no way to see which.
    if (sticker[@"attachments"]) entry[@"attachments"] = sticker[@"attachments"];
    [stickers addObject:entry];
    target[@"stickers"] = stickers;
}

/// Applies one poll message to its poll: a vote, or an edit of the options.
///
/// A vote names the option by identifier, and a participant may vote again to
/// change their mind — later votes replace earlier ones. Options can also be
/// added after the fact, which is why a vote can name an option the original
/// poll never listed.
static void applyPollUpdate(NSMutableDictionary *poll, NSDictionary *update) {
    NSDictionary *payload = update[@"poll"];
    long long type = [update[@"associated_message_type"] longLongValue];

    // An edit carries the full option list; take the newer one.
    if (type != 4000 && [payload[@"options"] isKindOfClass:[NSArray class]]) {
        NSMutableArray *options = [poll[@"options"] mutableCopy] ?: [NSMutableArray array];
        NSMutableSet *known = [NSMutableSet set];
        for (NSDictionary *option in options) if (option[@"id"]) [known addObject:option[@"id"]];
        for (NSDictionary *option in payload[@"options"]) {
            if (option[@"id"] && ![known containsObject:option[@"id"]]) {
                [options addObject:option];
                [known addObject:option[@"id"]];
            }
        }
        poll[@"options"] = options;
        if (!poll[@"question"] && payload[@"question"]) poll[@"question"] = payload[@"question"];
        return;
    }

    if (type != 4000) return;
    NSArray *votes = payload[@"votes"];
    if (![votes isKindOfClass:[NSArray class]]) return;

    NSMutableArray *tally = [poll[@"votes"] mutableCopy] ?: [NSMutableArray array];
    for (NSDictionary *vote in votes) {
        NSString *handle = vote[@"handle"];
        NSString *optionID = vote[@"optionId"];
        if (![optionID isKindOfClass:[NSString class]]) continue;

        // One vote per participant: a later one replaces theirs.
        NSUInteger previous = [tally indexOfObjectPassingTest:
            ^BOOL(NSDictionary *v, NSUInteger i, BOOL *stop) {
                return [v[@"handle"] ?: [NSNull null] isEqual:handle ?: [NSNull null]];
            }];
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"optionId"] = optionID;
        if (handle) entry[@"handle"] = handle;
        if (previous != NSNotFound) [tally replaceObjectAtIndex:previous withObject:entry];
        else [tally addObject:entry];
    }
    poll[@"votes"] = tally;
}

/// Counts the final tally onto each option, so a poll reads the way it looks.
static void summarisePoll(NSMutableDictionary *poll) {
    NSArray *votes = poll[@"votes"];
    if (![votes isKindOfClass:[NSArray class]]) return;

    NSMutableArray *options = [NSMutableArray array];
    for (NSDictionary *option in poll[@"options"] ?: @[]) {
        NSMutableDictionary *entry = [option mutableCopy];
        NSMutableArray *voters = [NSMutableArray array];
        for (NSDictionary *vote in votes) {
            if ([vote[@"optionId"] isEqual:option[@"id"]] && vote[@"handle"]) {
                [voters addObject:vote[@"handle"]];
            }
        }
        entry[@"voters"] = voters;
        entry[@"voteCount"] = @(voters.count);
        [options addObject:entry];
    }
    if (options.count) poll[@"options"] = options;
    poll[@"totalVotes"] = @([votes count]);
}

/// Folds reactions and poll updates onto the messages they belong to, and
/// drops them from the top level. `associations` may include rows from outside
/// the page, so a reaction is not lost just because it fell past the boundary.
static NSArray *foldAssociations(NSArray *messages, NSArray *associations) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *byGUID =
        [NSMutableDictionary dictionary];
    NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:messages.count];
    for (NSDictionary *message in messages) {
        NSMutableDictionary *entry = [message mutableCopy];
        NSString *guid = entry[@"guid"];
        if ([guid isKindOfClass:[NSString class]]) byGUID[guid] = entry;
        [ordered addObject:entry];
    }

    // Oldest first, so votes replace in the order they were cast.
    NSArray *sorted = [associations sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [a[@"rowid"] compare:b[@"rowid"]];
    }];

    NSMutableSet *folded = [NSMutableSet set];
    for (NSDictionary *association in sorted) {
        NSString *targetGUID = IMBTapbackTargetGUID(association[@"associated_message_guid"]);
        NSMutableDictionary *target = targetGUID ? byGUID[targetGUID] : nil;
        if (!target) continue;

        long long type = [association[@"associated_message_type"] longLongValue];
        if (IMBTapbackName(type)) {
            applyTapback(target, association);
        } else if (type == kStickerAssociation) {
            applySticker(target, association);
        } else if (target[@"poll"]) {
            NSMutableDictionary *poll = [target[@"poll"] mutableCopy];
            applyPollUpdate(poll, association);
            target[@"poll"] = poll;
        } else {
            continue;   // not something to fold; leave it where it is
        }
        if (association[@"guid"]) [folded addObject:association[@"guid"]];
    }

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:ordered.count];
    for (NSMutableDictionary *entry in ordered) {
        if (entry[@"guid"] && [folded containsObject:entry[@"guid"]]) continue;
        if (entry[@"poll"]) {
            NSMutableDictionary *poll = [entry[@"poll"] mutableCopy];
            summarisePoll(poll);
            entry[@"poll"] = poll;
        }
        [out addObject:entry];
    }
    return out;
}

/// Resolves a chat GUID to its store rowid, or 0 when unknown.
static long long chatRowID(NSString *chatGuid) {
    if (!chatGuid.length) return 0;
    NSString *sql = @"SELECT ROWID FROM chat WHERE guid = ? LIMIT 1";
    id rows = runQuery(sql, @[chatGuid], NULL, NULL);
    NSDictionary *r = [rows isKindOfClass:[NSArray class]] && [rows count] ? rows[0] : nil;
    return [r[@"ROWID"] longLongValue];
}

/// Every reaction, vote and poll edit pointing at any message in `messages`.
///
/// These are looked up rather than taken from the page, because an association
/// is written after the message it refers to and can therefore fall outside it
/// — a reaction to the oldest message on a page usually does. Reading only the
/// page would silently lose them.
///
/// A `chatID` of 0 means every conversation, for a page that was not restricted
/// to one. The chat join goes away entirely in that case rather than becoming
/// unconstrained: a message can be joined to more than one chat, and an
/// unconstrained join would return its associations once per chat.
static NSArray *associationsFor(NSArray *messages, long long chatID) {
    NSMutableArray *guids = [NSMutableArray array];
    for (NSDictionary *message in messages) {
        NSString *guid = message[@"guid"];
        if ([guid isKindOfClass:[NSString class]] && guid.length) [guids addObject:guid];
    }
    if (!guids.count) return @[];

    NSMutableString *placeholders = [NSMutableString string];
    for (NSUInteger i = 0; i < guids.count; i++) {
        [placeholders appendString:(i ? @",?" : @"?")];
    }

    // The target is named in one of three forms, and the prefix has to come off
    // before comparing. Matching only the first of these silently loses every
    // reaction left on a link or a poll:
    //
    //   "p:<index>/<guid>"  a message part
    //   "bp:<guid>"         a balloon message as a whole
    //   "<guid>"            a poll vote, which names the poll outright
    //
    // A GUID contains neither ':' nor '/', so the first occurrence of either is
    // the end of the prefix. This mirrors IMBTapbackTargetGUID, which does the
    // same thing to the rows once they are read.
    NSString *sql = [NSString stringWithFormat:
        @"SELECT %@ FROM message m %@%@"
        @"WHERE %@m.associated_message_guid IS NOT NULL "
        @"AND (CASE "
        @"      WHEN instr(m.associated_message_guid, '/') > 0 "
        @"        THEN substr(m.associated_message_guid, "
        @"                    instr(m.associated_message_guid, '/') + 1) "
        @"      WHEN instr(m.associated_message_guid, ':') > 0 "
        @"        THEN substr(m.associated_message_guid, "
        @"                    instr(m.associated_message_guid, ':') + 1) "
        @"      ELSE m.associated_message_guid END) IN (%@) "
        @"ORDER BY m.ROWID",
        kMessageColumns,
        chatID ? @"INNER JOIN chat_message_join j ON j.message_id = m.ROWID " : @"",
        kMessageJoins,
        chatID ? @"j.chat_id = ? AND " : @"",
        placeholders];

    NSMutableArray *bind = [NSMutableArray array];
    if (chatID) [bind addObject:@(chatID)];
    [bind addObjectsFromArray:guids];
    return runQuery(sql, bind, NULL, NULL) ?: @[];
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Messages from the store, oldest first within the page, keyed for pagination.
///
/// Two directions, and they answer different questions:
///
///   * `beforeRowID` pages **backwards** — pass the smallest rowid from the
///     previous page to fetch the next older slice. This is how you read an
///     archive, and it reaches past the in-memory window IMCore keeps.
///
///   * `sinceRowID` pages **forwards** — everything written after a rowid a
///     caller recorded earlier. This is how a consumer that was not running
///     finds out what it missed. Reading that with `beforeRowID` would mean
///     walking the whole archive backwards until the cursor came into view.
///
/// `chatGuid` is optional, and only useful to leave out in the forward
/// direction: after downtime a caller does not know which conversations have
/// news, so restricting the scan to one would mean asking every chat in turn.
/// Each message then carries the `chatGuid` it belongs to.
NSDictionary *IMBStoreHistory(NSString *chatGuid, NSUInteger limit, long long beforeRowID,
                              long long sinceRowID, NSString **errCode, NSString **errMessage) {
    // A window bounded at both ends has no one cursor to continue from, and
    // which end the caller means is not guessable. Refuse rather than pick.
    if (beforeRowID > 0 && sinceRowID > 0) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = @"pass beforeRowID or sinceRowID, not both";
        return nil;
    }

    long long chatID = 0;
    if (chatGuid.length) {
        chatID = chatRowID(chatGuid);
        if (!chatID) {
            if (errCode) *errCode = @"chat_not_found";
            if (errMessage) *errMessage = @"no chat with that GUID in the store";
            return nil;
        }
    }
    if (limit == 0 || limit > 1000) limit = 200;
    // Only an explicit `sinceRowID` reads forwards. Asked with no cursor at
    // all, this answers with the newest page — whose `nextSinceRowID` is the
    // cursor to start from, so a caller with no saved position begins at now
    // rather than replaying the archive from its first message.
    BOOL forward = sinceRowID > 0;

    // Unfiltered, the chat a message belongs to comes from a subquery rather
    // than a join: chat_message_join can hold a message more than once, and a
    // join would then return the message once per chat it is filed under.
    NSMutableString *sql = [NSMutableString stringWithFormat:
        @"SELECT %@%@ FROM message m %@%@WHERE %@",
        kMessageColumns,
        chatID ? @"" : @", (SELECT c.guid FROM chat_message_join j2 "
                        @"INNER JOIN chat c ON c.ROWID = j2.chat_id "
                        @"WHERE j2.message_id = m.ROWID LIMIT 1) AS chatGuid",
        chatID ? @"INNER JOIN chat_message_join j ON j.message_id = m.ROWID " : @"",
        kMessageJoins,
        chatID ? @"j.chat_id = ? " : @"1 = 1 "];
    NSMutableArray *bind = [NSMutableArray array];
    if (chatID) [bind addObject:@(chatID)];
    if (beforeRowID > 0) {
        [sql appendString:@"AND m.ROWID < ? "];
        [bind addObject:@(beforeRowID)];
    }
    if (sinceRowID > 0) {
        [sql appendString:@"AND m.ROWID > ? "];
        [bind addObject:@(sinceRowID)];
    }
    [sql appendFormat:@"ORDER BY m.ROWID %@ LIMIT ?", forward ? @"ASC" : @"DESC"];
    [bind addObject:@(limit)];

    NSArray *rows = runQuery(sql, bind, errCode, errMessage);
    if (!rows) return nil;

    // Oldest-first within the page either way, so a transcript reads top to
    // bottom. Paging forwards already reads in that order.
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.count];
    if (forward) {
        [out addObjectsFromArray:rows];
    } else {
        for (NSDictionary *r in [rows reverseObjectEnumerator]) [out addObject:r];
    }

    // Attachments first: a sticker folded onto a bubble should carry its image
    // with it, and a reaction's own row is dropped by the fold.
    NSArray *withFiles = addAttachments(out);
    NSArray *associations = addAttachments(associationsFor(out, chatID));
    NSArray *folded = foldAssociations(withFiles, associations);

    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:@{
        @"messages": folded,
        // Reported from the page actually read, not from what folding left, so
        // a page of reactions still advances the cursor. Boxed through IMBBool
        // because C's == yields an int, which reaches a caller as 1 rather
        // than true.
        @"hasMore": IMBBool(rows.count == limit),
    }];
    if (chatGuid.length) result[@"chatGuid"] = chatGuid;
    // Both cursors are reported from the page as read. A page that folded away
    // to nothing still moves them, or a run of reactions would be read forever.
    if (out.count) {
        result[@"nextBeforeRowID"] = out.firstObject[@"rowid"] ?: @0;
        result[@"nextSinceRowID"] = out.lastObject[@"rowid"] ?: @0;
    } else {
        result[@"nextBeforeRowID"] = @0;
        // Nothing new: leaving the cursor where the caller had it means the
        // next call asks the same question rather than skipping to zero and
        // replaying the entire archive.
        result[@"nextSinceRowID"] = @(sinceRowID);
    }
    return result;
}

/// What a conversation carries beyond its messages.
///
/// The picture a group is drawn with is not a message and not a column: the
/// chat's property list names the attachment holding it, and the bytes are in
/// the attachment table like any other file. The transcript does record when it
/// changed — that is the `group-photo-set` event — but the event says nothing
/// about which picture is current, so this reads the chat's own answer.
NSDictionary *IMBStoreChatDetails(NSString *chatGuid,
                                  NSString **errCode, NSString **errMessage) {
    NSArray *rows = runQueryReading(
        @"SELECT ROWID AS chatRowID, guid, display_name, group_id, style, "
        @"is_archived, is_filtered, is_blackholed, properties "
        @"FROM chat WHERE guid = ? LIMIT 1",
        @[chatGuid ?: @""], ^(sqlite3_stmt *st) { return plainRow(st); },
        errCode, errMessage);
    if (!rows) return nil;
    if (!rows.count) {
        if (errCode) *errCode = @"chat_not_found";
        if (errMessage) *errMessage = @"no chat with that GUID in the store";
        return nil;
    }

    NSDictionary *row = rows[0];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"chatGuid"] = row[@"guid"] ?: chatGuid ?: @"";
    if (stringValue(row[@"display_name"])) out[@"displayName"] = row[@"display_name"];
    if (longValue(row[@"is_archived"]))   out[@"archived"] = @YES;
    // Filed under Unknown Senders, or blocked outright.
    if (longValue(row[@"is_filtered"]))   out[@"filtered"] = @YES;
    if (longValue(row[@"is_blackholed"])) out[@"blocked"] = @YES;

    NSData *properties = nil;
    NSString *encoded = stringValue(row[@"properties"]);
    if (encoded) properties = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    if (!properties.length) return out;

    NSDictionary *plist = nil;
    @try {
        id parsed = [NSPropertyListSerialization propertyListWithData:properties
                                                             options:NSPropertyListImmutable
                                                              format:NULL error:NULL];
        plist = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
    } @catch (NSException *e) {
        IMBLog(@"chat properties parse threw: %@", e.reason);
    }
    if (!plist) return out;

    NSString *photoGUID = stringValue(plist[@"groupPhotoGuid"]);
    if (photoGUID) {
        NSArray *photos = runQueryReading(
            [NSString stringWithFormat:
                @"SELECT %@ FROM attachment a "
                @"INNER JOIN message_attachment_join j ON j.attachment_id = a.ROWID "
                @"WHERE a.guid = ? LIMIT 1", kAttachmentColumns],
            @[photoGUID], ^(sqlite3_stmt *st) { return plainRow(st); }, NULL, NULL);
        if (photos.count) {
            NSString *filename = stringValue(photos[0][@"filename"]);
            NSMutableDictionary *photo = [NSMutableDictionary dictionary];
            photo[@"guid"] = photoGUID;
            if (filename) {
                photo[@"localPath"] = [filename hasPrefix:@"~/"]
                    ? [IMBRealHome() stringByAppendingPathComponent:[filename substringFromIndex:2]]
                    : filename;
                photo[@"filename"] = [filename lastPathComponent];
            }
            if (stringValue(photos[0][@"mime_type"])) photo[@"mimeType"] = photos[0][@"mime_type"];
            photo[@"sizeBytes"] = @(longValue(photos[0][@"total_bytes"]));
            out[@"groupPhoto"] = photo;
        } else {
            // The chat names a picture the attachment table no longer holds.
            out[@"groupPhoto"] = @{ @"guid": photoGUID };
        }
    }

    // macOS 26 gives a conversation its own background. It is stored the way
    // an attachment in flight is — as a remote URL with its decryption
    // material — so only the fact that one is set is reported.
    if ([plist[@"backgroundProperties"] isKindOfClass:[NSDictionary class]]) {
        out[@"hasBackground"] = @YES;
    }
    return out;
}

/// Messages that are being held for later delivery.
///
/// Worth having on its own rather than as a filter over history, for two
/// reasons. A scheduled message is not in the conversation yet, so nothing
/// reading the transcript will find it; and cancelling one needs the chat it
/// actually landed in, which is not always the chat it was addressed to.
///
/// `pending` is `schedule_type != 0` together with `is_delivered = 0`. The type
/// alone is not enough: a scheduled message that has already gone out keeps it,
/// and so does one that IMCore sent immediately despite the future timestamp.
NSDictionary *IMBStoreScheduled(NSString *chatGuid,
                                NSString **errCode, NSString **errMessage) {
    NSMutableString *sql = [NSMutableString stringWithFormat:
        @"SELECT %@, c.guid AS chatGuid FROM message m "
        @"INNER JOIN chat_message_join j ON j.message_id = m.ROWID "
        @"INNER JOIN chat c ON c.ROWID = j.chat_id %@"
        @"WHERE m.schedule_type != 0 AND m.is_delivered = 0 ", kMessageColumns, kMessageJoins];
    NSMutableArray *bind = [NSMutableArray array];
    if (chatGuid.length) {
        [sql appendString:@"AND c.guid = ? "];
        [bind addObject:chatGuid];
    }
    [sql appendString:@"ORDER BY m.date"];

    NSArray *rows = runQuery(sql, bind, errCode, errMessage);
    if (!rows) return nil;
    return @{ @"messages": addAttachments(rows) };
}

/// One message by GUID — used to read a search hit in full. Returns nil with a
/// message_not_found error when the GUID is absent (a hit can outlive its
/// message, since the index is not pruned on delete).
NSDictionary *IMBStoreMessage(NSString *guid, NSString **errCode, NSString **errMessage) {
    if (!guid.length) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = @"missing guid";
        return nil;
    }
    NSString *sql = [NSString stringWithFormat:
        @"SELECT %@ FROM message m %@WHERE m.guid = ? LIMIT 1",
        kMessageColumns, kMessageJoins];
    NSArray *rows = runQuery(sql, @[guid], errCode, errMessage);
    if (!rows) return nil;
    if (rows.count == 0) {
        if (errCode) *errCode = @"message_not_found";
        if (errMessage) *errMessage = @"no message with that GUID in the store";
        return nil;
    }
    // Attach the conversation so a hit can be placed back in context.
    NSArray *withFiles = addAttachments(rows);
    NSMutableDictionary *row = [withFiles.firstObject mutableCopy];
    id chatRows = runQueryReading(
        @"SELECT c.guid AS chatGuid, c.ROWID AS chatRowID FROM chat c "
        @"INNER JOIN chat_message_join j ON j.chat_id = c.ROWID "
        @"WHERE j.message_id = ? LIMIT 1",
        @[row[@"rowid"]], ^(sqlite3_stmt *st) { return plainRow(st); }, NULL, NULL);

    if ([chatRows isKindOfClass:[NSArray class]] && [chatRows count]) {
        row[@"chatGuid"] = chatRows[0][@"chatGuid"];

        // Fold on whatever points at this message, the same way a page does.
        // Reading one message on its own is how a search hit and a poll are
        // resolved, and without this a poll comes back with no tally and a
        // message with no reactions — present in history, missing here.
        long long chatID = longValue(chatRows[0][@"chatRowID"]);
        NSArray *associations = addAttachments(associationsFor(withFiles, chatID));
        NSArray *folded = foldAssociations(withFiles, associations);
        if (folded.count) row = [folded.firstObject mutableCopy];
        row[@"chatGuid"] = chatRows[0][@"chatGuid"];
    }
    return row;
}

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

/// Normalises `message.date` to Unix seconds inside SQL.
///
/// The column holds nanoseconds since the 2001 epoch on current releases and
/// whole seconds on older ones, and a store that has been migrated contains
/// both. The threshold is the same one the row reader uses.
static NSString *const kDateToUnix =
    @"(CASE WHEN m.date > 1000000000000000 THEN m.date / 1000000000 ELSE m.date END + 978307200)";

/// Counts and distributions over a conversation, or over the whole store.
///
/// This is a reader: it answers questions a person could answer by scrolling,
/// but over the full history rather than the loaded window — who talks most,
/// when, and with what.
NSDictionary *IMBStats(NSString *chatGuid, long long sinceUnix,
                       NSString **errCode, NSString **errMessage) {
    // One scope clause, reused by every query below, so a chat filter and a
    // time filter cannot drift apart between sections.
    NSMutableString *scope = [NSMutableString stringWithString:@" WHERE 1=1"];
    NSMutableArray *bind = [NSMutableArray array];
    if (chatGuid.length) {
        [scope appendString:
            @" AND m.ROWID IN (SELECT j.message_id FROM chat_message_join j"
             " INNER JOIN chat c ON c.ROWID = j.chat_id WHERE c.guid = ?)"];
        [bind addObject:chatGuid];
    }
    if (sinceUnix > 0) {
        [scope appendFormat:@" AND %@ >= ?", kDateToUnix];
        [bind addObject:@(sinceUnix)];
    }

    NSDictionary *(^reader)(sqlite3_stmt *) = ^NSDictionary *(sqlite3_stmt *st) {
        return plainRow(st);
    };

    NSArray *totals = runQueryReading([NSString stringWithFormat:
        @"SELECT COUNT(*) AS messages,"
        @" SUM(m.is_from_me) AS sent,"
        @" SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) AS received,"
        @" SUM(CASE WHEN m.cache_has_attachments = 1 THEN 1 ELSE 0 END) AS withAttachments,"
        @" SUM(CASE WHEN m.associated_message_type BETWEEN 2000 AND 3999 THEN 1 ELSE 0 END) AS tapbacks,"
        @" MIN(%@) AS firstAt, MAX(%@) AS lastAt"
        @" FROM message m%@", kDateToUnix, kDateToUnix, scope],
        bind, reader, errCode, errMessage);
    if (!totals) return nil;

    // Sender identity lives on handle for received messages; anything from me
    // has no handle row, so it is labelled here rather than coming back null.
    NSArray *people = runQueryReading([NSString stringWithFormat:
        @"SELECT CASE WHEN m.is_from_me = 1 THEN NULL ELSE h.id END AS handle,"
        @" m.is_from_me AS fromMe, COUNT(*) AS messages,"
        @" MAX(%@) AS lastAt"
        @" FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id%@"
        @" GROUP BY handle, fromMe ORDER BY messages DESC", kDateToUnix, scope],
        bind, reader, NULL, NULL);

    NSArray *byHour = runQueryReading([NSString stringWithFormat:
        @"SELECT CAST(strftime('%%H', %@, 'unixepoch', 'localtime') AS INTEGER) AS hour,"
        @" COUNT(*) AS messages FROM message m%@ GROUP BY hour ORDER BY hour",
        kDateToUnix, scope], bind, reader, NULL, NULL);

    NSArray *byWeekday = runQueryReading([NSString stringWithFormat:
        @"SELECT CAST(strftime('%%w', %@, 'unixepoch', 'localtime') AS INTEGER) AS weekday,"
        @" COUNT(*) AS messages FROM message m%@ GROUP BY weekday ORDER BY weekday",
        kDateToUnix, scope], bind, reader, NULL, NULL);

    NSArray *byMonth = runQueryReading([NSString stringWithFormat:
        @"SELECT strftime('%%Y-%%m', %@, 'unixepoch', 'localtime') AS month,"
        @" COUNT(*) AS messages FROM message m%@ GROUP BY month ORDER BY month",
        kDateToUnix, scope], bind, reader, NULL, NULL);

    NSArray *media = runQueryReading([NSString stringWithFormat:
        @"SELECT a.mime_type AS mimeType, COUNT(*) AS count, SUM(a.total_bytes) AS bytes"
        @" FROM attachment a"
        @" INNER JOIN message_attachment_join mj ON mj.attachment_id = a.ROWID"
        @" INNER JOIN message m ON m.ROWID = mj.message_id%@"
        @" GROUP BY mimeType ORDER BY count DESC", scope],
        bind, reader, NULL, NULL);

    NSArray *services = runQueryReading([NSString stringWithFormat:
        @"SELECT m.service AS service, COUNT(*) AS messages FROM message m%@"
        @" GROUP BY service ORDER BY messages DESC", scope],
        bind, reader, NULL, NULL);

    NSMutableDictionary *out = [totals.firstObject mutableCopy] ?: [NSMutableDictionary dictionary];
    out[@"people"] = people ?: @[];
    out[@"byHour"] = byHour ?: @[];
    out[@"byWeekday"] = byWeekday ?: @[];
    out[@"byMonth"] = byMonth ?: @[];
    out[@"media"] = media ?: @[];
    out[@"services"] = services ?: @[];
    if (chatGuid.length) out[@"chatGuid"] = chatGuid;
    return out;
}
