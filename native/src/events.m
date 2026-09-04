// Inbound push.
//
// IMCore posts in-process notifications the moment a message arrives, so
// subscribers learn about it without polling the message store.
//
// These observers run on IMCore's own threads, including inside its send path.
// An exception raised here does not stay here — it unwinds through IMCore and
// surfaces as a failed send. Every handler is therefore isolated, and the
// userInfo shapes are checked rather than assumed.
#import "bridge.h"

// IMCore's notification names are private and underscore-prefixed. They are
// looked up as strings so a rename degrades to "no events" rather than a crash.
static NSString *const kMessageReceived = @"__kIMChatMessageReceivedNotification";
static NSString *const kMessageSent     = @"__kIMChatMessageSentNotification";
static NSString *const kMessageChanged  = @"__kIMChatMessageDidChangeNotification";
static NSString *const kItemsDidChange  = @"__kIMChatItemsDidChangeNotification";
static NSString *const kUnreadChanged   = @"__kIMChatUnreadCountChangedNotification";
static NSString *const kWatermark       = @"IMChatWatermarkDidUpdateNotification";
static NSString *const kChatValueKey    = @"__kIMChatValueKey";
static NSString *const kItemsInserted   = @"__kIMChatItemsInserted";
static NSString *const kItemsRemoved    = @"__kIMChatItemsRemoved";
static NSString *const kItemsNewItems   = @"__kIMChatItemsNewItems";
static NSString *const kItemsOldItems   = @"__kIMChatItemsOldItems";

static id safeValue(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

/// Registers a notification handler that can never throw into its caller.
static void observe(NSString *name, void (^handler)(NSNotification *note)) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:name object:nil queue:nil
                usingBlock:^(NSNotification *note) {
        @autoreleasepool {
            @try {
                handler(note);
            } @catch (NSException *e) {
                IMBLog(@"observer %@ threw: %@", name, e.reason);
            }
        }
    }];
}

/// Resolves the changed chat items for a change notification.
///
/// The inserted/removed keys hold an NSIndexSet of positions, not the items
/// themselves — the items live under the new/old item arrays.
static NSArray *itemsForChange(NSNotification *note, NSString *indexKey, NSString *itemsKey) {
    id indexes = note.userInfo[indexKey];
    id items = note.userInfo[itemsKey];

    if ([indexes isKindOfClass:[NSArray class]]) return indexes;   // older shape
    if (![indexes isKindOfClass:[NSIndexSet class]] ||
        ![items isKindOfClass:[NSArray class]]) return @[];

    NSArray *itemArray = items;
    NSMutableArray *out = [NSMutableArray array];
    [(NSIndexSet *)indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < itemArray.count) [out addObject:itemArray[idx]];
    }];
    return out;
}

/// Chat items that carry no user-visible content.
static BOOL isNoiseItem(id item) {
    NSString *cls = NSStringFromClass([item class]);
    return [cls isEqualToString:@"IMLoadMoreChatItem"]
        || [cls isEqualToString:@"IMDateChatItem"]
        || [cls isEqualToString:@"IMServiceChatItem"]
        || [cls isEqualToString:@"IMTypingChatItem"];
}

void IMBStartEventObservers(void) {
    // Primary path: one notification per received message, carrying the
    // IMMessage itself.
    observe(kMessageReceived, ^(NSNotification *note) {
        id message = note.userInfo[kChatValueKey];
        if (!message) return;
        IMBBroadcastEvent(@"message", IMBSerializeMessage(message, note.object));
    });

    // Outbound echo, so a subscriber sees its own sends land and can correlate
    // them by GUID.
    observe(kMessageSent, ^(NSNotification *note) {
        id message = note.userInfo[kChatValueKey];
        if (!message) return;
        IMBBroadcastEvent(@"message-sent", IMBSerializeMessage(message, note.object));
    });

    // Delivery and read state changing on an existing message — this is how
    // "Delivered" becomes "Read" in the UI.
    observe(kMessageChanged, ^(NSNotification *note) {
        id message = note.userInfo[kChatValueKey];
        if (!message) return;
        IMBBroadcastEvent(@"message-updated", IMBSerializeMessage(message, note.object));
    });

    // Group read receipts move a per-chat watermark rather than flagging each
    // message individually.
    observe(kWatermark, ^(NSNotification *note) {
        NSString *guid = safeValue(note.object, @"guid");
        if (!guid) return;
        IMBBroadcastEvent(@"read-receipt", @{ @"chatGUID": guid });
    });

    // Messages recomputes unread counts for every chat during its initial
    // sync, which would otherwise emit one event per conversation at startup.
    __block NSDate *armedAt = [NSDate date];
    observe(kUnreadChanged, ^(NSNotification *note) {
        if (!note.object) return;
        if ([[NSDate date] timeIntervalSinceDate:armedAt] < 10.0) return;
        IMBBroadcastEvent(@"unread-changed", IMBSerializeChat(note.object));
    });

    // Fallback and enrichment: fires for edits, retractions, tapbacks and
    // typing, none of which arrive as a "received message".
    observe(kItemsDidChange, ^(NSNotification *note) {
        NSArray *inserted = itemsForChange(note, kItemsInserted, kItemsNewItems);
        NSArray *removed  = itemsForChange(note, kItemsRemoved, kItemsOldItems);
        NSString *chatGUID = safeValue(note.object, @"guid");

        // Typing indicators arrive as their own chat item appearing and then
        // disappearing — that is how the UI knows to show the dots.
        for (id item in inserted) {
            if (![NSStringFromClass([item class]) isEqualToString:@"IMTypingChatItem"]) continue;
            IMBBroadcastEvent(@"typing", @{
                @"chatGUID": chatGUID ?: [NSNull null],
                @"sender": IMBHandleInfo(safeValue(item, @"sender")) ?: [NSNull null],
                @"typing": @YES,
            });
        }
        for (id item in removed) {
            if (![NSStringFromClass([item class]) isEqualToString:@"IMTypingChatItem"]) continue;
            IMBBroadcastEvent(@"typing", @{
                @"chatGUID": chatGUID ?: [NSNull null],
                @"typing": @NO,
            });
        }

        for (id item in inserted) {
            if (isNoiseItem(item)) continue;

            // A part carries neither sender nor body; resolve the message
            // behind it so every event is fully populated.
            id message = IMBUnderlyingMessage(item);
            NSMutableDictionary *payload =
                [IMBSerializeMessage(message ?: item, note.object) mutableCopy];
            payload[@"itemClass"] = NSStringFromClass([item class]);
            if (message) IMBAddRichFields(payload, message);

            IMBBroadcastEvent(@"chat-item", payload);
        }
    });

    IMBLog(@"event observers armed");
}
