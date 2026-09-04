// Contact cards.
//
// A handle is a phone number or an email address, and on its own it tells a
// reader nothing: "+15550000000 said this" is not how anyone reads a
// conversation. Messages resolves handles against Contacts to draw a name, and
// this exposes the same card — the name, but also everything else a person has
// on them, which is what turns a number in a transcript into someone you can
// say something about.
//
// The card is fetched rather than read. A CNContact hands out only the keys it
// was fetched with, which is why `pictureData` on a handle is nil in a running
// app: nobody asked for it. Asking is cheap but not free, so the full card is a
// call of its own rather than something folded into every listing.
#import "bridge.h"
#import <objc/message.h>

static id safeGet(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

/// A non-empty string, or nil. Contacts fills absent fields with `@""` rather
/// than leaving them out, so a card built without this is mostly empty strings.
static NSString *nonEmpty(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}

/// Turns Contacts' internal label into the word the app shows.
///
/// Labels are stored as `_$!<Mobile>!$_`; Contacts has a localiser for them, so
/// the displayed word comes from the framework rather than from a table here
/// that would be wrong in every language but one.
static NSString *localizedLabel(NSString *label) {
    if (![label isKindOfClass:[NSString class]] || !label.length) return nil;
    Class labeled = NSClassFromString(@"CNLabeledValue");
    SEL sel = NSSelectorFromString(@"localizedStringForLabel:");
    if ([labeled respondsToSelector:sel]) {
        @try {
            NSString *localized = ((id (*)(id, SEL, id))objc_msgSend)(labeled, sel, label);
            if (localized.length) return localized;
        } @catch (__unused NSException *e) { /* fall through to the raw label */ }
    }
    return label;
}

/// `{ year, month, day }` from date components, dropping the parts that are
/// unset — a birthday recorded without a year is normal, and reporting
/// NSNotFound for it would be worse than leaving it out.
static NSDictionary *dateComponents(id components) {
    if (!components) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *unit in @[@"year", @"month", @"day"]) {
        id value = safeGet(components, unit);
        long long n = [value respondsToSelector:@selector(longLongValue)]
                    ? [value longLongValue] : NSNotFound;
        if (n > 0 && n != NSNotFound) out[unit] = @(n);
    }
    return out.count ? out : nil;
}

/// Flattens `[CNLabeledValue]` into `[{ label, value... }]`.
///
/// The value inside is whatever the key holds — a string for an email, an
/// object for a phone number or an address — so the caller passes a block that
/// knows how to read the one it asked for.
static NSArray *labeledValues(id values, NSDictionary *(^readValue)(id value)) {
    if (![values isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (id entry in (NSArray *)values) {
        NSDictionary *body = readValue(safeGet(entry, @"value"));
        if (!body.count) continue;
        NSMutableDictionary *item = [body mutableCopy];
        NSString *label = localizedLabel(safeGet(entry, @"label"));
        if (label) item[@"label"] = label;
        [out addObject:item];
    }
    return out.count ? out : nil;
}

/// The full contact card behind a handle.
///
/// `includePhoto` controls only whether the image bytes come along; the card is
/// otherwise the same. The photo is tens of kilobytes, so it is opt-in.
NSDictionary *IMBContactCard(id handle, BOOL includePhoto) {
    if (!handle) return nil;

    NSMutableDictionary *card = [NSMutableDictionary dictionary];
    NSString *handleID = nonEmpty(safeGet(handle, @"ID"));
    if (handleID) card[@"handle"] = handleID;

    // Everything the card can hold, asked for by name. A CNContact throws when
    // read for a key it was not fetched with, so this list is the contract:
    // anything absent here is unavailable later, however the caller asks.
    NSArray *keys = @[
        @"identifier", @"contactType",
        @"givenName", @"middleName", @"familyName", @"namePrefix", @"nameSuffix",
        @"nickname", @"previousFamilyName",
        @"phoneticGivenName", @"phoneticMiddleName", @"phoneticFamilyName",
        @"organizationName", @"departmentName", @"jobTitle",
        @"birthday", @"nonGregorianBirthday", @"dates", @"note",
        @"phoneNumbers", @"emailAddresses", @"postalAddresses", @"urlAddresses",
        @"contactRelations", @"socialProfiles", @"instantMessageAddresses",
        @"imageDataAvailable", @"imageData", @"thumbnailImageData",
    ];

    id contact = nil;
    SEL fetch = NSSelectorFromString(@"cnContactWithKeys:");
    if ([handle respondsToSelector:fetch]) {
        @try {
            contact = ((id (*)(id, SEL, id))objc_msgSend)(handle, fetch, keys);
            if (!contact) {
                // A handle that has not been used in a conversation has no
                // contact properties loaded, and the keyed fetch answers nil
                // even when Contacts knows the person. Touching `cnContact`
                // makes it load them; then the keyed fetch has something to
                // read.
                (void)safeGet(handle, @"cnContact");
                contact = ((id (*)(id, SEL, id))objc_msgSend)(handle, fetch, keys);
            }
        } @catch (NSException *e) {
            IMBLog(@"contact fetch threw: %@", e.reason);
        }
    }
    if (!contact) {
        // No card, but the handle still knows what Messages draws for it.
        NSDictionary *info = IMBHandleInfo(handle);
        for (NSString *key in info) if (!card[key]) card[key] = info[key];
        return card.count ? card : nil;
    }

    struct { NSString *key; NSString *out; } plain[] = {
        { @"identifier",         @"id" },
        { @"givenName",          @"firstName" },
        { @"middleName",         @"middleName" },
        { @"familyName",         @"lastName" },
        { @"namePrefix",         @"prefix" },
        { @"nameSuffix",         @"suffix" },
        { @"nickname",           @"nickname" },
        { @"previousFamilyName", @"previousLastName" },
        { @"phoneticGivenName",  @"phoneticFirstName" },
        { @"phoneticMiddleName", @"phoneticMiddleName" },
        { @"phoneticFamilyName", @"phoneticLastName" },
        { @"organizationName",   @"organization" },
        { @"departmentName",     @"department" },
        { @"jobTitle",           @"jobTitle" },
        { @"note",               @"note" },
    };
    for (size_t i = 0; i < sizeof(plain)/sizeof(plain[0]); i++) {
        NSString *value = nonEmpty(safeGet(contact, plain[i].key));
        if (value) card[plain[i].out] = value;
    }

    // The name as a person would write it, since callers almost always want one
    // string rather than five fields.
    NSString *full = nonEmpty(safeGet(handle, @"fullName"));
    if (!full) {
        NSArray *parts = @[card[@"firstName"] ?: @"", card[@"lastName"] ?: @""];
        full = nonEmpty([[parts componentsJoinedByString:@" "]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]);
    }
    if (full) card[@"name"] = full;

    id contactType = safeGet(contact, @"contactType");
    if ([contactType respondsToSelector:@selector(longLongValue)]) {
        // Cast to BOOL: C's == yields int, which boxes as a JSON number.
        card[@"isOrganization"] = IMBBool(([contactType longLongValue] == 1));
    }

    NSDictionary *birthday = dateComponents(safeGet(contact, @"birthday"))
                          ?: dateComponents(safeGet(contact, @"nonGregorianBirthday"));
    if (birthday) card[@"birthday"] = birthday;

    NSArray *dates = labeledValues(safeGet(contact, @"dates"), ^(id value) {
        NSDictionary *parts = dateComponents(value);
        return parts ? @{ @"date": parts } : nil;
    });
    if (dates) card[@"dates"] = dates;

    NSArray *phones = labeledValues(safeGet(contact, @"phoneNumbers"), ^(id value) {
        NSString *number = nonEmpty(safeGet(value, @"stringValue"));
        return number ? @{ @"number": number } : nil;
    });
    if (phones) card[@"phoneNumbers"] = phones;

    NSArray *emails = labeledValues(safeGet(contact, @"emailAddresses"), ^(id value) {
        NSString *address = nonEmpty(value);
        return address ? @{ @"address": address } : nil;
    });
    if (emails) card[@"emailAddresses"] = emails;

    NSArray *urls = labeledValues(safeGet(contact, @"urlAddresses"), ^(id value) {
        NSString *url = nonEmpty(value);
        return url ? @{ @"url": url } : nil;
    });
    if (urls) card[@"urls"] = urls;

    NSArray *addresses = labeledValues(safeGet(contact, @"postalAddresses"), ^(id value) {
        NSMutableDictionary *address = [NSMutableDictionary dictionary];
        struct { NSString *key; NSString *out; } fields[] = {
            { @"street",         @"street" },
            { @"subLocality",    @"subLocality" },
            { @"city",           @"city" },
            { @"state",          @"state" },
            { @"postalCode",     @"postalCode" },
            { @"country",        @"country" },
            { @"ISOCountryCode", @"countryCode" },
        };
        for (size_t i = 0; i < sizeof(fields)/sizeof(fields[0]); i++) {
            NSString *v = nonEmpty(safeGet(value, fields[i].key));
            if (v) address[fields[i].out] = v;
        }
        return address.count ? address : nil;
    });
    if (addresses) card[@"postalAddresses"] = addresses;

    NSArray *relations = labeledValues(safeGet(contact, @"contactRelations"), ^(id value) {
        NSString *name = nonEmpty(safeGet(value, @"name"));
        return name ? @{ @"name": name } : nil;
    });
    if (relations) card[@"relations"] = relations;

    NSArray *social = labeledValues(safeGet(contact, @"socialProfiles"), ^(id value) {
        NSMutableDictionary *profile = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"service", @"username", @"urlString"]) {
            NSString *v = nonEmpty(safeGet(value, key));
            if (v) profile[[key isEqualToString:@"urlString"] ? @"url" : key] = v;
        }
        return profile.count ? profile : nil;
    });
    if (social) card[@"socialProfiles"] = social;

    NSArray *messaging = labeledValues(safeGet(contact, @"instantMessageAddresses"), ^(id value) {
        NSMutableDictionary *address = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"service", @"username"]) {
            NSString *v = nonEmpty(safeGet(value, key));
            if (v) address[key] = v;
        }
        return address.count ? address : nil;
    });
    if (messaging) card[@"instantMessageAddresses"] = messaging;

    // `imageDataAvailable` is not trustworthy — it reads false on cards that do
    // have a picture — so the presence of bytes is what decides.
    NSString *mime = nil;
    NSData *picture = IMBHandleAvatar(handle, &mime);
    card[@"hasPhoto"] = IMBBool((picture.length > 0));
    if (includePhoto && picture.length) {
        card[@"photo"] = @{
            @"mimeType": mime ?: @"image/jpeg",
            @"data": [picture base64EncodedStringWithOptions:0],
        };
    }
    return card;
}

/// Finds the IMHandle for a phone number or email address.
///
/// There is no handle registry in this process, so this takes the two routes
/// there are, and the order matters. A handle already in a conversation has had
/// its contact properties loaded; one minted by the account has not, and
/// answers nil for its card even when Contacts knows the person perfectly well
/// — it will give you the name and nothing else. So conversations are searched
/// first, and the account is the fallback that covers an address you have never
/// exchanged a message with.
///
/// Must be called on the main thread.
id IMBLookupHandle(NSString *handleID) {
    if (![handleID isKindOfClass:[NSString class]] || !handleID.length) return nil;

    id chat = IMBLookupChat(handleID);
    NSArray *participants = safeGet(chat, @"participants");
    for (id handle in participants ?: @[]) {
        if ([nonEmpty(safeGet(handle, @"ID")) isEqualToString:handleID]) return handle;
    }
    // A single conversation with one other person: that person is the handle,
    // whatever SPELLING of their address was asked for — but it must still be
    // the same address. Returning the participant unchecked turned one
    // poisoned registry object (sole participant rewritten to our own
    // address) into our own IMHandle answered for someone else's number,
    // which then re-created the note-to-self chat via chatForIMHandle: and
    // spread the damage into createChat, whois, and contact lookups.
    if (participants.count == 1) {
        id only = participants.firstObject;
        if (IMBAddressesMatch(handleID, nonEmpty(safeGet(only, @"ID")))) return only;
    }

    Class controller = NSClassFromString(@"IMAccountController");
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    if ([controller respondsToSelector:sharedSel]) {
        @try {
            id shared = ((id (*)(id, SEL))objc_msgSend)(controller, sharedSel);
            for (NSString *accessor in @[@"activeIMessageAccount", @"activeSMSAccount"]) {
                id account = safeGet(shared, accessor);
                SEL lookup = NSSelectorFromString(@"imHandleWithID:");
                if (!account || ![account respondsToSelector:lookup]) continue;
                id handle = ((id (*)(id, SEL, id))objc_msgSend)(account, lookup, handleID);
                if (handle) return handle;
            }
        } @catch (NSException *e) {
            IMBLog(@"handle lookup threw: %@", e.reason);
        }
    }
    return nil;
}
