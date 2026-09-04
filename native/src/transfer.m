// Outgoing file transfers.
//
// Sending an attachment is not a matter of handing IMCore a path. The daemon
// uploads from a file it can reach itself, so the file has to be staged into
// the attachment tree *before* the transfer is registered. Skipping that step
// is why an earlier attempt at this looked like it worked and did not: the
// transfer was created, the message referenced its GUID, every call returned
// success, and there was no file where the daemon looked — so the upload never
// started and the message arrived as text alone.
//
// The sequence that does work:
//
//   1. copy the file into the attachment tree
//   2. guidForNewOutgoingTransferWithLocalURL:  (on the staged copy)
//   3. transferForGUID:                          -> IMFileTransfer
//   4. decorate it (sticker flags, filename)
//   5. registerTransferWithDaemon:                -> upload begins
//
// Step 1 is deliberately done first rather than through
// IMDPersistentAttachmentController's _persistentPathForTransfer:…, which is
// the documented route and the one other projects use. On this OS that call
// answers nil when chatGUID is nil, and when given a chat GUID it answers an
// iOS-shaped /var/mobile/… path that does not exist here. Staging into the
// user-visible attachment tree first sidesteps it: that is a location the
// daemon already reads from, so registration alone is enough. The persistent
// path is still attempted opportunistically, since a future build may start
// answering usefully, but nothing depends on it.
//
// Everything here is confined to files this bridge creates. No existing
// transfer is retargeted and no attachment record is rewritten.
#import "bridge.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import <pwd.h>

/// Stickers are rejected by the renderer above these, and a rejected sticker
/// sends as an ordinary image with no indication anything was wrong.
static const unsigned long long kMaxStickerBytes = 500ULL * 1024ULL;
static const NSUInteger kMaxStickerDimension = 618;

/// Native user-generated stickers carry the parent preview width in their
/// geometry. Without a stable way to read the real target layout from here,
/// this is the value Messages itself writes for a full-width bubble.
static NSString *const kStickerParentPreviewWidth = @"163.73095703";

static NSString *const kStickerPluginID =
    @"com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:"
     "com.apple.Stickers.UserGenerated.MessagesExtension";

/// The real home directory, not the sandbox container.
///
/// Messages is sandboxed, so NSHomeDirectory() answers its container path.
/// The attachment tree lives under the actual home, and the container path
/// silently produces a valid-looking directory the daemon never reads.
static NSString *realHomeDirectory(void) {
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir) return @(pw->pw_dir);
    return NSHomeDirectory();
}

static NSString *hexDigest(NSData *data, BOOL sha256) {
    unsigned char out[CC_SHA256_DIGEST_LENGTH];
    NSUInteger length;
    if (sha256) {
        CC_SHA256(data.bytes, (CC_LONG)data.length, out);
        length = CC_SHA256_DIGEST_LENGTH;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // MD5 is not a security choice here: it is the digest Messages writes
        // into a sticker's own metadata, so it has to match byte for byte.
        CC_MD5(data.bytes, (CC_LONG)data.length, out);
#pragma clang diagnostic pop
        length = CC_MD5_DIGEST_LENGTH;
    }
    NSMutableString *hex = [NSMutableString stringWithCapacity:length * 2];
    for (NSUInteger i = 0; i < length; i++) [hex appendFormat:@"%02x", out[i]];
    return hex;
}

NSString *IMBAttachmentStagingRoot(void) {
    return [realHomeDirectory()
        stringByAppendingPathComponent:@"Library/Messages/Attachments/imcore-bridge"];
}

/// Ensures the file is somewhere the daemon will upload from.
///
/// Normally the client has already put it there — it runs outside the sandbox,
/// and Messages' own sandbox denies *writes* into the attachment tree even
/// though it reads from it freely. A file already under the staging root is
/// therefore used as-is. Anything else is copied if this process happens to be
/// allowed to (unsandboxed hosts, tests); when that copy is denied the original
/// path is used and registration is left to try its luck, which is better than
/// refusing a send that may well work.
static NSURL *stageIntoAttachmentTree(NSURL *source, NSString *filename) {
    NSString *root = IMBAttachmentStagingRoot();
    if ([source.path hasPrefix:[root stringByAppendingString:@"/"]]) return source;

    NSString *directory = [root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&error]) {
        IMBLog(@"staging directory refused (%@); sending from %@",
               error.localizedDescription, source.path);
        return source;
    }

    NSURL *staged = [NSURL fileURLWithPath:
        [directory stringByAppendingPathComponent:filename]];
    if (![NSFileManager.defaultManager copyItemAtURL:source toURL:staged error:&error]) {
        IMBLog(@"staging copy refused (%@); sending from %@",
               error.localizedDescription, source.path);
        [NSFileManager.defaultManager removeItemAtPath:directory error:NULL];
        return source;
    }
    return staged;
}

/// Pixel dimensions without decoding the image.
static BOOL imageDimensions(NSURL *url, NSUInteger *width, NSUInteger *height) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return NO;
    NSDictionary *properties = (__bridge_transfer NSDictionary *)
        CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!properties) return NO;
    *width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    *height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    return *width > 0 && *height > 0;
}

/// Marks a transfer as a sticker.
///
/// There is no sticker send API. A sticker is an ordinary file transfer with
/// three extra pieces of metadata, and an attachment message referencing it —
/// which is why probing for a "send sticker" selector found nothing and led to
/// the wrong conclusion that stickers could not be sent at all.
static BOOL decorateAsSticker(id transfer, NSURL *staged, NSString *filename,
                              NSString *label, NSString **errCode, NSString **errMessage) {
    for (NSString *name in @[@"setIsSticker:", @"setStickerUserInfo:", @"setAttributionInfo:"]) {
        if (![transfer respondsToSelector:NSSelectorFromString(name)]) {
            if (errCode) *errCode = @"unsupported_feature";
            if (errMessage) *errMessage = [NSString stringWithFormat:
                @"IMFileTransfer has no %@ on this build", name];
            return NO;
        }
    }

    NSData *data = [NSData dataWithContentsOfURL:staged];
    if (!data.length) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = @"sticker file is empty";
        return NO;
    }
    if (data.length > kMaxStickerBytes) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = [NSString stringWithFormat:
            @"sticker is %llu bytes; the limit is %llu",
            (unsigned long long)data.length, kMaxStickerBytes];
        return NO;
    }

    NSUInteger width = 0, height = 0;
    if (!imageDimensions(staged, &width, &height)) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = @"sticker file is not a readable image";
        return NO;
    }
    if (width > kMaxStickerDimension || height > kMaxStickerDimension) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = [NSString stringWithFormat:
            @"sticker is %lux%lu; the limit is %lu on each side",
            (unsigned long)width, (unsigned long)height, (unsigned long)kMaxStickerDimension];
        return NO;
    }

    ((void (*)(id, SEL, BOOL))objc_msgSend)(transfer, NSSelectorFromString(@"setIsSticker:"), YES);

    // sxs/sys place the sticker within its parent at 0.5/0.5 — dead centre —
    // which is where a sticker sent as its own message sits. sro is rotation
    // and ssa scale, both identity. stickerEffectType -1 means no effect.
    ((void (*)(id, SEL, id))objc_msgSend)(transfer, NSSelectorFromString(@"setStickerUserInfo:"), @{
        @"pid": kStickerPluginID,
        @"safi": @0,
        @"sai": @"0",
        @"shash": hexDigest(data, NO),
        @"sid": filename,
        @"sli": @"0",
        @"spv": @0,
        @"spw": kStickerParentPreviewWidth,
        @"sro": @"0.00000000",
        @"ssa": @"1.00000000",
        @"stickerEffectType": @(-1),
        @"suri": [NSString stringWithFormat:@"sticker:///%@", hexDigest(data, YES)],
        @"sxs": @"0.50000000",
        @"sys": @"0.50000000",
    });

    // The accessibility label is what VoiceOver reads and what appears as the
    // sticker's description on the receiving side.
    NSString *text = [label stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (!text.length) text = @"Sticker";
    if (text.length > 150) {
        text = [text substringWithRange:
            [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 150)]];
    }
    ((void (*)(id, SEL, id))objc_msgSend)(transfer, NSSelectorFromString(@"setAttributionInfo:"), @{
        @"accessl": text,
        @"bundle-id": kStickerPluginID,
        @"name": @"Stickers",
        @"pgensh": @(height),
        @"pgensw": @(width),
        @"pgenszc": @{
            @"gm": @NO, @"iaig": @NO, @"mpw": @"600.000000",
            @"mth": @"100.000000", @"mtw": @"100.000000",
            @"s": @"1.000000", @"st": @NO,
        },
    });
    return YES;
}

/// Best-effort move into IMD's own attachment location.
///
/// Not load-bearing: the staged copy is already somewhere the daemon reads
/// from. This only runs so that a build where the persistent path works again
/// puts the file exactly where Messages would have.
static void tryPersistentPath(id center, id transfer, NSString *guid,
                              NSURL *staged, NSString *filename) {
    Class controller = NSClassFromString(@"IMDPersistentAttachmentController");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL pathFor = NSSelectorFromString(
        @"_persistentPathForTransfer:filename:highQuality:chatGUID:storeAtExternalPath:");
    SEL retarget = NSSelectorFromString(@"retargetTransfer:toPath:");
    if (!controller || ![controller respondsToSelector:shared]) return;
    if (![center respondsToSelector:retarget]) return;

    @try {
        id instance = ((id (*)(id, SEL))objc_msgSend)(controller, shared);
        if (![instance respondsToSelector:pathFor]) return;
        NSString *path = ((id (*)(id, SEL, id, id, BOOL, id, BOOL))objc_msgSend)(
            instance, pathFor, transfer, filename, YES, nil, YES);
        if (!path.length || [path hasPrefix:@"/var/mobile"]) return;

        NSURL *destination = [NSURL fileURLWithPath:path];
        [NSFileManager.defaultManager
            createDirectoryAtURL:destination.URLByDeletingLastPathComponent
             withIntermediateDirectories:YES attributes:nil error:NULL];
        if (![NSFileManager.defaultManager moveItemAtURL:staged toURL:destination error:NULL]) return;

        ((void (*)(id, SEL, id, id))objc_msgSend)(center, retarget, guid, path);
        SEL setURL = NSSelectorFromString(@"_setLocalURL:");
        if ([transfer respondsToSelector:setURL]) {
            ((void (*)(id, SEL, id))objc_msgSend)(transfer, setURL, destination);
        }
    } @catch (NSException *e) {
        IMBLog(@"persistent path attempt threw: %@", e.reason);
    }
}

NSDictionary *IMBPrepareTransfer(NSString *path, NSDictionary *sticker,
                                 NSString **errCode, NSString **errMessage) {
    Class centerClass = NSClassFromString(@"IMFileTransferCenter");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL guidFor = NSSelectorFromString(@"guidForNewOutgoingTransferWithLocalURL:");
    if (!centerClass || ![centerClass respondsToSelector:shared]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"IMFileTransferCenter unavailable";
        return nil;
    }
    id center = ((id (*)(id, SEL))objc_msgSend)(centerClass, shared);
    if (![center respondsToSelector:guidFor]) {
        if (errCode) *errCode = @"unsupported_feature";
        if (errMessage) *errMessage = @"guidForNewOutgoingTransferWithLocalURL: unavailable";
        return nil;
    }

    NSString *expanded = path.stringByExpandingTildeInPath;
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:expanded isDirectory:&isDirectory]
        || isDirectory) {
        if (errCode) *errCode = @"bad_request";
        if (errMessage) *errMessage = [NSString stringWithFormat:@"no file at '%@'", path];
        return nil;
    }

    NSString *filename = expanded.lastPathComponent;
    NSURL *staged = stageIntoAttachmentTree([NSURL fileURLWithPath:expanded], filename);

    @try {
        NSString *guid = ((id (*)(id, SEL, id))objc_msgSend)(center, guidFor, staged);
        if (!guid.length) {
            if (errCode) *errCode = @"internal";
            if (errMessage) *errMessage = @"no transfer GUID was issued";
            return nil;
        }

        SEL forGUID = NSSelectorFromString(@"transferForGUID:");
        id transfer = [center respondsToSelector:forGUID]
            ? ((id (*)(id, SEL, id))objc_msgSend)(center, forGUID, guid) : nil;
        if (!transfer) {
            if (errCode) *errCode = @"internal";
            if (errMessage) *errMessage = @"transfer was not created";
            return nil;
        }

        SEL setName = NSSelectorFromString(@"setTransferredFilename:");
        if ([transfer respondsToSelector:setName]) {
            ((void (*)(id, SEL, id))objc_msgSend)(transfer, setName, filename);
        }

        if (sticker) {
            NSString *label = [sticker[@"label"] isKindOfClass:NSString.class]
                ? sticker[@"label"] : nil;
            if (!decorateAsSticker(transfer, staged, filename, label, errCode, errMessage)) {
                return nil;
            }
        }

        tryPersistentPath(center, transfer, guid, staged, filename);
        return @{ @"guid": guid, @"filename": filename };
    } @catch (NSException *e) {
        IMBLog(@"transfer preparation threw: %@", e.reason);
        if (errCode) *errCode = @"internal";
        if (errMessage) *errMessage = e.reason ?: @"could not prepare transfer";
        return nil;
    }
}

BOOL IMBRegisterTransfer(NSString *guid) {
    Class centerClass = NSClassFromString(@"IMFileTransferCenter");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL registerSel = NSSelectorFromString(@"registerTransferWithDaemon:");
    if (!centerClass || ![centerClass respondsToSelector:shared]) return NO;

    @try {
        id center = ((id (*)(id, SEL))objc_msgSend)(centerClass, shared);
        if (![center respondsToSelector:registerSel]) return NO;
        ((void (*)(id, SEL, id))objc_msgSend)(center, registerSel, guid);
        return YES;
    } @catch (NSException *e) {
        IMBLog(@"registerTransferWithDaemon: threw: %@", e.reason);
        return NO;
    }
}
