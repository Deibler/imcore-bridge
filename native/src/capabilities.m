// Live capability probing.
//
// Selectors move between macOS releases, so nothing here is assumed: every
// feature is derived from respondsToSelector: at runtime and reported to the
// client, which degrades per feature rather than failing wholesale.
#import "bridge.h"

static BOOL classResponds(NSString *className, NSString *selName) {
    Class cls = NSClassFromString(className);
    return cls && [cls respondsToSelector:NSSelectorFromString(selName)];
}

static BOOL instanceResponds(NSString *className, NSString *selName) {
    Class cls = NSClassFromString(className);
    return cls && [cls instancesRespondToSelector:NSSelectorFromString(selName)];
}

NSDictionary *IMBCapabilities(void) {
    if (!IMBIsIMCoreReady()) return @{};

    BOOL send = instanceResponds(@"IMChat", @"sendMessage:")
             && classResponds(@"IMMessage",
                    @"instantMessageWithText:messageSubject:fileTransferGUIDs:flags:threadIdentifier:");

    // Effects and attachments come from different factory methods, and no
    // single one accepts an effect, attachments and a thread together.
    BOOL effect = classResponds(@"IMMessage",
                    @"instantMessageWithText:messageSubject:flags:expressiveSendStyleID:threadIdentifier:");
    BOOL effectWithAttachments = classResponds(@"IMMessage",
                    @"instantMessageWithText:messageSubject:fileTransferGUIDs:flags:balloonBundleID:payloadData:expressiveSendStyleID:");

    return @{
        @"typing":      @(instanceResponds(@"IMChat", @"setLocalUserIsTyping:")),
        @"typingData":  @(instanceResponds(@"IMChat", @"setLocalUserIsComposing:typingIndicatorData:")),
        @"send":        @(send),
        @"reply":       @(send),
        @"subject":     @(send),
        // Choosing which service carries one message needs both the per-send
        // account entry point and the controller that names the accounts. With
        // only the first there is nothing to hand it.
        @"sendService": IMBBool((instanceResponds(@"IMChat", @"sendMessage:onAccount:")
                          && instanceResponds(@"IMAccountController", @"activeSMSAccount")
                          && instanceResponds(@"IMAccountController", @"activeIMessageAccount"))),
        @"effect":      @(effect),
        @"effectWithAttachments": @(effectWithAttachments),
        // Sending a file needs both halves: a message factory that carries
        // transfer GUIDs, and the transfer machinery that gets the bytes to
        // the daemon. Registration is the step that starts the upload, so its
        // absence would mean attachments that silently never arrive.
        @"attachments": IMBBool((classResponds(@"IMMessage",
                            @"instantMessageWithText:messageSubject:fileTransferGUIDs:flags:threadIdentifier:")
                          && instanceResponds(@"IMFileTransferCenter",
                                @"guidForNewOutgoingTransferWithLocalURL:")
                          && instanceResponds(@"IMFileTransferCenter",
                                @"registerTransferWithDaemon:"))),
        // A sticker is an ordinary transfer wearing three extra pieces of
        // metadata; there is no sticker-specific send.
        @"stickers":    IMBBool((instanceResponds(@"IMFileTransfer", @"setIsSticker:")
                          && instanceResponds(@"IMFileTransfer", @"setStickerUserInfo:")
                          && instanceResponds(@"IMFileTransfer", @"setAttributionInfo:"))),
        // Sticking one to an existing bubble needs the initialiser that takes
        // a transfer list and the association triple together; every shorter
        // factory drops one or the other.
        @"stickerAttach": @(instanceResponds(@"IMMessage",
                            @"initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:"
                             "error:guid:subject:associatedMessageGUID:associatedMessageType:"
                             "associatedMessageRange:messageSummaryInfo:threadIdentifier:")),
        // Removing the conversation, as against emptying it.
        @"deleteChat":  @(instanceResponds(@"IMChat", @"remove")),
        // Handing over this account's own name and picture.
        @"shareNameAndPhoto": @(instanceResponds(@"IMNicknameController",
                                  @"sendPersonalNicknameToHandle:")),
        // Asking whether a membership change will be acted on before making
        // it. Without these, both calls still work and still fail silently.
        @"groupPreconditions": IMBBool((instanceResponds(@"IMChat", @"canAddParticipants:")
                          && instanceResponds(@"IMChat", @"canRemoveParticipants:"))),
        // Cast to BOOL: C's || and && yield int, which would box as a JSON
        // number rather than a boolean.
        @"tapback":     IMBBool((instanceResponds(@"IMChat", @"sendMessageAcknowledgment:forChatItem:")
                          || classResponds(@"IMMessage",
                                @"instantMessageWithAssociatedMessageContent:associatedMessageGUID:associatedMessageType:associatedMessageRange:associatedMessageEmoji:messageSummaryInfo:threadIdentifier:"))),
        // Custom-emoji reactions are reported apart from the classic kinds
        // because they are not the same feature wearing a different code: no
        // acknowledgment type carries a character, so they go through IMCore's
        // tapback objects instead and can be absent while tapbacks work.
        @"emojiTapback": IMBBool((instanceResponds(@"IMEmojiTapback", @"initWithEmoji:isRemoved:")
                          && instanceResponds(@"IMTapbackSender",
                                @"initWithTapback:chat:messageGUID:messagePartRange:messageSummaryInfo:threadIdentifier:")
                          && instanceResponds(@"IMTapbackSender", @"send"))),
        // Hide Alerts is a date rather than a flag, so the setter is the whole
        // feature; `isMuted` is only IMCore's reading of that date.
        @"mute":        IMBBool((instanceResponds(@"IMChat", @"setMuteUntilDate:")
                          && instanceResponds(@"IMChat", @"isMuted"))),
        @"deleteHistory": @(instanceResponds(@"IMChat", @"deleteAllHistory")),
        @"reportJunk":  @(instanceResponds(@"IMChat", @"reportJunk")),
        @"mentions":    @(instanceResponds(@"IMChat", @"messageGuidsForMyUnreadMentions")),
        @"sendAsText":  @(instanceResponds(@"IMChat", @"downgradeMessage:manualDowngrade:")),
        @"shareLocation": @(instanceResponds(@"IMChat", @"shareLocationWithDuration:")),
        @"retract":     @(instanceResponds(@"IMChat", @"retractMessagePart:")),
        @"edit":        @(instanceResponds(@"IMChat",
                            @"editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText:")),
        @"groupRename": @(instanceResponds(@"IMChat", @"setDisplayName:")),
        @"groupPhoto":  IMBBool((instanceResponds(@"IMChat", @"sendGroupPhotoUpdate:")
                          && instanceResponds(@"IMFileTransferCenter",
                                @"createNewOutgoingGroupPhotoTransferWithLocalFileURL:"))),
        @"groupAdd":    @(instanceResponds(@"IMChat", @"_addParticipants:withState:")),
        @"groupRemove": @(instanceResponds(@"IMChat", @"removeParticipants:reason:")),
        @"groupLeave":  @(instanceResponds(@"IMChat", @"leave")),
        // Search reuses the index Messages donates to. The ranked path applies
        // Apple's classification and semantic matching; without it, search
        // degrades to substring matching over the same index.
        @"search":       IMBBool((NSClassFromString(@"CSUserQuery") != nil
                          || NSClassFromString(@"CSSearchQuery") != nil)),
        @"searchRanked": IMBBool((NSClassFromString(@"CSUserQuery") != nil)),
        // Deep history reads chat.db directly, which any build with a message
        // store supports; the probe is that the store file is reachable.
        @"store":       @YES,
        // A poll is an app-extension balloon, so it needs the factory that
        // carries a plugin identifier and its payload.
        // Voting needs a second factory: only one method carries a plugin
        // payload and an association at once, and a vote is both.
        @"poll":        IMBBool((classResponds(@"IMMessage",
                            @"instantMessageWithText:messageSubject:fileTransferGUIDs:flags:balloonBundleID:payloadData:expressiveSendStyleID:")
                          && classResponds(@"IMMessage",
                            @"customAcknowledgementMessageWithPayloadData:associatedMessageGUID:balloonBundleID:messageSummaryInfo:threadIdentifier:"))),
        // Contact pictures live on the CNContact rather than the handle.
        @"avatars":     @(instanceResponds(@"IMHandle", @"cnContactWithKeys:")),
        // Send Later builds the message with a delivery time and a schedule
        // type, so the initialiser carrying both is the probe.
        @"sendLater":   IMBBool((instanceResponds(@"IMMessage",
                            @"initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:threadIdentifier:scheduleType:scheduleState:")
                          && instanceResponds(@"IMChat", @"cancelScheduledMessageItem:cancelType:"))),
        @"markUnread":  @(instanceResponds(@"IMChat", @"markLastMessageAsUnread")),
        // "Notify Anyway" — pushing one message past a mute or a Focus.
        @"notifyAnyway": @(instanceResponds(@"IMChat", @"markChatItemAsNotifyRecipient:")),
        // The setter replaces the whole pinned list; there is no per-chat pin.
        @"pin":         IMBBool((classResponds(@"IMPinnedConversationsController", @"sharedInstance")
                          && instanceResponds(@"IMPinnedConversationsController",
                                @"setPinnedChats:withUpdateReason:"))),
        @"account":     @(instanceResponds(@"IMAccountController", @"activeIMessageAccount")),
        @"sendingAlias": IMBBool((instanceResponds(@"IMAccount", @"vettedAliases")
                          && instanceResponds(@"IMAccount", @"setDisplayName:"))),
        // Name & Photo: the card someone shared, which is what Messages shows
        // in preference to the contact card.
        @"nicknames":   @(instanceResponds(@"IMNicknameController", @"nicknameForHandle:")),
        @"stats":       @YES,
        @"events":      @YES,
        // Not a capability probe but a policy this host was launched with:
        // every send to our own address is refused. Reported so a client can
        // see the guard is armed without having to trip it.
        @"blockSelfSends": IMBBool(IMBSelfSendsBlocked()),
    };
}
