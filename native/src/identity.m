// Who you are, and who other people have told you they are.
//
// Two separate things live here because they answer the same question from
// opposite ends.
//
// The account side is the sending identity: which Apple ID is signed in, every
// address messages can arrive at, which of those outgoing messages are
// attributed to, and whether texts from an iPhone are being relayed here.
// Without it there is no way to tell your own handles from anyone else's,
// which is what makes "did I send this" answerable.
//
// The nickname side is the Name & Photo card — the name and picture someone
// chose to share with you over iMessage. Messages displays that in preference
// to the contact card, so reading contacts alone gives a different name than
// the one on screen. Sharing your own card is deliberately not implemented:
// it is outward-facing, it broadcasts a real photo to a real person, and
// nothing about reading a conversation requires it.
#import "bridge.h"
#import <objc/message.h>

static id safeValue(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static id sharedInstanceOf(NSString *className) {
    Class cls = NSClassFromString(className);
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (!cls || ![cls respondsToSelector:shared]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(cls, shared); }
    @catch (__unused NSException *e) { return nil; }
}

static NSArray<NSString *> *strings(id value) {
    if (![value isKindOfClass:[NSArray class]] && ![value isKindOfClass:[NSSet class]]) {
        return @[];
    }
    NSMutableArray *out = [NSMutableArray array];
    for (id entry in value) {
        if ([entry isKindOfClass:[NSString class]]) [out addObject:entry];
    }
    return out;
}

static NSDictionary *describeAccount(id account) {
    if (!account) return nil;

    // Aliases are every address that reaches this account. The vetted subset
    // is the one Apple has confirmed, and only those can be sent from — an
    // unvetted alias is an address someone typed that has not been verified.
    NSArray *aliases = strings(safeValue(account, @"aliases"));
    NSArray *vetted = strings(safeValue(account, @"vettedAliases"));

    NSMutableDictionary *out = [@{
        @"aliases": aliases,
        @"vettedAliases": vetted,
    } mutableCopy];

    NSString *login = safeValue(account, @"strippedLogin");
    if ([login isKindOfClass:[NSString class]] && login.length) out[@"appleID"] = login;

    id handle = safeValue(account, @"loginIMHandle");
    NSString *fullName = safeValue(handle, @"fullName");
    if ([fullName isKindOfClass:[NSString class]] && fullName.length) out[@"name"] = fullName;

    // displayName is the alias outgoing messages are attributed to. It is what
    // recipients see as the sender when an account has several addresses.
    NSString *display = safeValue(account, @"displayName");
    if ([display isKindOfClass:[NSString class]] && display.length) {
        out[@"sendingAs"] = display;
    }

    NSString *status = safeValue(account, @"loginStatusMessage");
    if ([status isKindOfClass:[NSString class]] && status.length) out[@"status"] = status;

    id relayCapable = safeValue(account, @"isSMSRelayCapable");
    id relayOn = safeValue(account, @"allowsSMSRelay");
    if (relayCapable) out[@"smsRelayCapable"] = IMBBool([relayCapable boolValue]);
    if (relayOn) out[@"smsRelayEnabled"] = IMBBool([relayOn boolValue]);

    id registered = safeValue(account, @"isRegistered");
    if (registered) out[@"registered"] = IMBBool([registered boolValue]);

    return out;
}

/// The signed-in messaging identity.
NSDictionary *IMBAccountInfo(void) {
    id controller = sharedInstanceOf(@"IMAccountController");
    if (!controller) return @{};

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSDictionary *imessage = describeAccount(safeValue(controller, @"activeIMessageAccount"));
    if (imessage) out[@"imessage"] = imessage;
    NSDictionary *sms = describeAccount(safeValue(controller, @"activeSMSAccount"));
    if (sms) out[@"sms"] = sms;
    return out;
}

/// Changes which alias outgoing iMessages are attributed to.
///
/// Only a vetted alias is accepted. Setting an unvetted one is not refused by
/// IMCore — it takes the value and then sends fail, which looks like the
/// network being down rather than a bad address.
BOOL IMBSetSendingAlias(NSString *alias, NSString **errCode, NSString **errMessage) {
    id controller = sharedInstanceOf(@"IMAccountController");
    id account = safeValue(controller, @"activeIMessageAccount");
    if (!account) {
        if (errCode) *errCode = @"not_ready";
        if (errMessage) *errMessage = @"no active iMessage account";
        return NO;
    }

    NSArray *vetted = strings(safeValue(account, @"vettedAliases"));
    if (![vetted containsObject:alias]) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = [NSString stringWithFormat:
            @"'%@' is not a vetted alias on this account — expected one of %@",
            alias, [vetted componentsJoinedByString:@", "]];
        return NO;
    }

    SEL sel = NSSelectorFromString(@"setDisplayName:");
    if (![account respondsToSelector:sel]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"setDisplayName: is unavailable on this build";
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(account, sel, alias);
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"setDisplayName: threw: %@", e.reason);
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = e.reason ?: @"could not change the sending alias";
        return NO;
    }
}

static NSDictionary *describeNickname(id nickname) {
    if (!nickname) return nil;

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *display = safeValue(nickname, @"displayName");
    if ([display isKindOfClass:[NSString class]] && display.length) out[@"name"] = display;

    for (NSString *key in @[@"firstName", @"lastName"]) {
        NSString *value = safeValue(nickname, key);
        if ([value isKindOfClass:[NSString class]] && value.length) out[key] = value;
    }

    // The avatar is image data on the nickname itself, which is why a shared
    // photo shows up for someone who has no contact card at all.
    id image = safeValue(nickname, @"image") ?: safeValue(nickname, @"avatar");
    NSData *data = [image isKindOfClass:[NSData class]] ? image : safeValue(image, @"imageData");
    if ([data isKindOfClass:[NSData class]] && data.length) {
        out[@"photo"] = [data base64EncodedStringWithOptions:0];
        out[@"photoBytes"] = @(data.length);
    }

    id handle = safeValue(nickname, @"handle");
    NSString *handleID = [handle isKindOfClass:[NSString class]] ? handle : safeValue(handle, @"ID");
    if ([handleID isKindOfClass:[NSString class]] && handleID.length) out[@"handle"] = handleID;

    return out.count ? out : nil;
}

/// The Name & Photo card someone shared, or your own when no handle is named.
NSDictionary *IMBNickname(NSString *handleID, NSString **errCode, NSString **errMessage) {
    id controller = sharedInstanceOf(@"IMNicknameController");
    if (!controller) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"IMNicknameController is unavailable on this build";
        return nil;
    }

    if (!handleID.length) {
        NSDictionary *mine = describeNickname(safeValue(controller, @"personalNickname"));
        return mine ?: @{};
    }

    id handle = IMBLookupHandle(handleID);
    SEL sel = NSSelectorFromString(@"nicknameForHandle:");
    if (!handle || ![controller respondsToSelector:sel]) return @{};

    @try {
        id nickname = ((id (*)(id, SEL, id))objc_msgSend)(controller, sel, handle);
        return describeNickname(nickname) ?: @{};
    } @catch (NSException *e) {
        IMBLog(@"nicknameForHandle: threw: %@", e.reason);
        return @{};
    }
}

/// Name & Photo updates waiting on a yes/no.
///
/// These are the "«Name» updated their photo — keep or update?" prompts. They
/// sit here until answered, so an agent reading a conversation can see that
/// the name it has may be about to change.
NSArray *IMBPendingNicknames(void) {
    id controller = sharedInstanceOf(@"IMNicknameController");
    id pending = safeValue(controller, @"pendingNicknameUpdates");
    if (![pending isKindOfClass:[NSDictionary class]]) return @[];

    NSMutableArray *out = [NSMutableArray array];
    [pending enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
        NSDictionary *described = describeNickname(value);
        if (!described) return;
        NSMutableDictionary *entry = [described mutableCopy];
        if ([key isKindOfClass:[NSString class]]) entry[@"handle"] = key;
        [out addObject:entry];
    }];
    return out;
}
