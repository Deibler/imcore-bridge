// Injected entry point: waits for IMCore, dials out to the host's Unix socket,
// and speaks newline-delimited JSON-RPC over that connection.
//
// Two constraints shape this file, both discovered the hard way:
//
//   * Entry is +load, not __attribute__((constructor)). From a constructor dyld
//     holds the image-initializer lock and dispatched work — GCD blocks,
//     NSThread, even detached pthreads — never runs.
//
//   * The bridge connects out; it does not listen. Messages.app is sandboxed
//     with com.apple.security.network.client but without network.server, so
//     bind() succeeds and listen() fails with EPERM. The client owns the
//     socket and this side dials it, reconnecting with backoff.
#import "bridge.h"

#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdarg.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>

// The single live connection back to the host, or -1.
static int gConnFD = -1;
static pthread_mutex_t gConnLock = PTHREAD_MUTEX_INITIALIZER;

// ---------------------------------------------------------------------------
// Paths and logging
// ---------------------------------------------------------------------------

static NSString *IMBContainerDir(void) {
    // Everything the injected code writes must sit inside the Messages
    // container; the app sandbox denies writes elsewhere.
    NSString *home = NSHomeDirectory();
    return [home stringByAppendingPathComponent:@"tmp"];
}

NSString *IMBSocketPath(void) {
    const char *override = getenv("IMCORE_BRIDGE_SOCKET");
    if (override && *override) return [NSString stringWithUTF8String:override];
    return [IMBContainerDir() stringByAppendingPathComponent:@"imcore-bridge.sock"];
}

static NSString *IMBLogPath(void) {
    return [IMBContainerDir() stringByAppendingPathComponent:@"imcore-bridge.log"];
}

void IMBLog(NSString *fmt, ...) {
    if (!getenv("IMCORE_BRIDGE_DEBUG")) return;
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSString *line = [NSString stringWithFormat:@"[%f] %@\n",
                          [[NSDate date] timeIntervalSince1970], msg];
        const char *bytes = [line UTF8String];
        int fd = open([IMBLogPath() fileSystemRepresentation],
                      O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (fd >= 0) { write(fd, bytes, strlen(bytes)); close(fd); }
    }
}

// ---------------------------------------------------------------------------
// Main-thread hop with a deadline
// ---------------------------------------------------------------------------

id IMBRunOnMain(id (^block)(void), NSTimeInterval timeout, BOOL *timedOut) {
    if (timedOut) *timedOut = NO;
    if ([NSThread isMainThread]) return block();

    __block id result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            @try { result = block(); }
            @catch (NSException *e) { IMBLog(@"main-hop exception: %@", e.reason); }
        }
        dispatch_semaphore_signal(sem);
    });

    dispatch_time_t deadline =
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sem, deadline) != 0) {
        if (timedOut) *timedOut = YES;
        return nil;
    }
    return result;
}

BOOL IMBIsIMCoreReady(void) {
    return NSClassFromString(@"IMChatRegistry") != nil
        && NSClassFromString(@"IMChat") != nil
        && NSClassFromString(@"IMMessage") != nil;
}

// ---------------------------------------------------------------------------
// Client connections
// ---------------------------------------------------------------------------

static BOOL write_all(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n > 0) { off += (size_t)n; continue; }
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        return NO;
    }
    return YES;
}

static BOOL send_json(int fd, id object) {
    @autoreleasepool {
        NSError *err = nil;
        // NSJSONSerialization *aborts the process* on an unsupported value
        // rather than raising, and this process is the user's messaging client.
        // Validate first, and on failure report a serialisation error instead
        // of taking Messages.app down with it.
        if (![NSJSONSerialization isValidJSONObject:object]) {
            IMBLog(@"refusing to encode invalid JSON object: %@", [object class]);
            // Keep the request id so the caller's pending call rejects rather
            // than hanging until its timeout.
            id reqId = [object isKindOfClass:[NSDictionary class]]
                     ? (((NSDictionary *)object)[@"id"] ?: [NSNull null])
                     : [NSNull null];
            object = @{ @"id": reqId, @"ok": @NO,
                        @"error": @{ @"code": @"internal",
                                     @"message": @"result was not serialisable" } };
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&err];
        if (!data) { IMBLog(@"encode failed: %@", err); return NO; }
        NSMutableData *line = [data mutableCopy];
        [line appendBytes:"\n" length:1];
        return write_all(fd, line.bytes, line.length);
    }
}

void IMBBroadcastEvent(NSString *type, NSDictionary *data) {
    NSDictionary *payload = @{ @"type": @"event", @"event": type, @"data": data ?: @{} };

    pthread_mutex_lock(&gConnLock);
    int fd = gConnFD;
    BOOL ok = (fd >= 0) ? send_json(fd, payload) : NO;
    if (!ok && fd >= 0) gConnFD = -1;   // reader thread will reconnect
    pthread_mutex_unlock(&gConnLock);
}

static void handle_line(int fd, NSString *line) {
    @autoreleasepool {
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSError *err = nil;
        id req = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (![req isKindOfClass:[NSDictionary class]]) {
            send_json(fd, @{ @"ok": @NO,
                             @"error": @{ @"code": @"bad_request",
                                          @"message": @"malformed JSON request" } });
            return;
        }

        id reqId  = req[@"id"] ?: [NSNull null];
        NSString *method = req[@"method"];
        NSDictionary *params = [req[@"params"] isKindOfClass:[NSDictionary class]]
                             ? req[@"params"] : @{};

        if (![method isKindOfClass:[NSString class]]) {
            send_json(fd, @{ @"id": reqId, @"ok": @NO,
                             @"error": @{ @"code": @"bad_request",
                                          @"message": @"missing method" } });
            return;
        }

        NSString *code = nil, *message = nil;
        id result = IMBDispatch(method, params, &code, &message);
        if (code) {
            send_json(fd, @{ @"id": reqId, @"ok": @NO,
                             @"error": @{ @"code": code, @"message": message ?: @"" } });
        } else {
            send_json(fd, @{ @"id": reqId, @"ok": @YES, @"result": result ?: @{} });
        }
    }
}

/// Reads requests until the host hangs up.
static void serve_connection(int fd) {
    NSMutableData *buf = [NSMutableData data];
    char chunk[4096];

    for (;;) {
        ssize_t n = read(fd, chunk, sizeof chunk);
        if (n == 0) break;
        if (n < 0) { if (errno == EINTR) continue; break; }
        [buf appendBytes:chunk length:(NSUInteger)n];

        // Newline-delimited framing: consume every complete line in the buffer.
        for (;;) {
            const char *bytes = buf.bytes;
            NSUInteger len = buf.length, nl = NSNotFound;
            for (NSUInteger i = 0; i < len; i++) {
                if (bytes[i] == '\n') { nl = i; break; }
            }
            if (nl == NSNotFound) break;

            @autoreleasepool {
                NSData *lineData = [NSData dataWithBytes:buf.bytes length:nl];
                NSString *line = [[NSString alloc] initWithData:lineData
                                                       encoding:NSUTF8StringEncoding];
                if (line.length) handle_line(fd, line);
            }
            [buf replaceBytesInRange:NSMakeRange(0, nl + 1) withBytes:NULL length:0];
        }
    }
}

// ---------------------------------------------------------------------------
// Dial-out loop
// ---------------------------------------------------------------------------

static int dial(NSString *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, [path fileSystemRepresentation], sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void *connect_thread(void *arg) {
    (void)arg;

    // IMCore is not registered at +load time; it appears about a second in.
    for (int i = 0; i < 240 && !IMBIsIMCoreReady(); i++) usleep(250000);
    if (!IMBIsIMCoreReady()) {
        IMBLog(@"IMCore never became ready; bridge not starting");
        return NULL;
    }
    IMBStartEventObservers();

    NSString *path = IMBSocketPath();
    IMBLog(@"IMCore ready; dialling %@ (pid %d)", path, getpid());

    useconds_t backoff = 250000;                 // 0.25s, capped at 5s
    const useconds_t maxBackoff = 5000000;

    for (;;) {
        int fd = dial(path);
        if (fd < 0) {
            usleep(backoff);
            backoff = (backoff * 2 > maxBackoff) ? maxBackoff : backoff * 2;
            continue;
        }
        backoff = 250000;

        pthread_mutex_lock(&gConnLock);
        gConnFD = fd;
        pthread_mutex_unlock(&gConnLock);

        // Announce ourselves so the host can spot a second injected instance
        // and refuse it rather than double-sending every message.
        @autoreleasepool {
            send_json(fd, @{ @"type": @"event", @"event": @"hello",
                             @"data": @{ @"pid": @(getpid()),
                                         @"protocol": @1,
                                         @"capabilities": IMBCapabilities() } });
        }
        IMBLog(@"connected to host");

        serve_connection(fd);

        pthread_mutex_lock(&gConnLock);
        if (gConnFD == fd) gConnFD = -1;
        pthread_mutex_unlock(&gConnLock);
        close(fd);

        // Anything left switched on belongs to a client that is no longer
        // there. The typing indicator is the one with a person on the other
        // end of it: left showing, it says a reply is coming from a process
        // that has died.
        IMBClearTypingIndicators();
        IMBLog(@"host disconnected; will redial");
    }
    return NULL;
}

@interface IMCoreBridgeLoader : NSObject
@end

@implementation IMCoreBridgeLoader

+ (void)load {
    static BOOL started = NO;
    if (started) return;   // +load can fire twice in one process
    started = YES;

    pthread_t tid;
    if (pthread_create(&tid, NULL, connect_thread, NULL) == 0) pthread_detach(tid);
}

@end
