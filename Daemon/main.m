#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <bsm/audit.h>
#include <unistd.h>
#import "Runtime.h"
#import "ReleaseAssets.h"
#import "../Shared/LocalFridaService.h"
#import "../Shared/ScriptOverlayService.h"

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateWithAuditToken(CFAllocatorRef allocator, audit_token_t token);
extern CFStringRef SecTaskCopySigningIdentifier(SecTaskRef task, CFErrorRef *error);

@interface NSXPCConnection (LocalFridaAuditToken)
- (audit_token_t)auditToken;
@end

static BOOL FLAuthorize(NSXPCConnection *connection, NSString *executable, NSString *identity) {
    if (connection.effectiveUserIdentifier != 501 || ![connection respondsToSelector:@selector(auditToken)]
        || !FLProcessMatches(connection.processIdentifier, executable)) return NO;
    audit_token_t token = connection.auditToken;
    SecTaskRef task = SecTaskCreateWithAuditToken(NULL, token);
    if (!task) return NO;
    NSString *signingID = CFBridgingRelease(SecTaskCopySigningIdentifier(task, NULL));
    CFRelease(task);
    return [signingID isEqualToString:identity];
}

typedef void (^FLReply)(NSData * _Nullable, NSString * _Nullable);

@protocol FLInstallService
- (void)startServerWithReply:(FLReply)reply;
@end

static int FLStartInstalledServer(void) {
    NSXPCConnection *connection = geteuid() == 0 ? FLCreateServiceConnection(FLSelectedProtocolMajor()) : nil;
    if (!connection) {
        fputs("Unable to open the Frida Local installation service.\n", stderr);
        return EXIT_FAILURE;
    }
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(FLInstallService)];
    [connection resume];

    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block NSString *failure = nil;
    id<FLInstallService> service = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        failure = error.localizedDescription;
        dispatch_semaphore_signal(finished);
    }];
    [service startServerWithReply:^(NSData *data, NSString *error) {
        failure = error ?: (data ? nil : @"Startup returned no status.");
        dispatch_semaphore_signal(finished);
    }];

    if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) {
        [connection invalidate];
        fputs("Timed out waiting for Frida Local to start.\n", stderr);
        return EXIT_FAILURE;
    }
    [connection invalidate];
    if (failure) fprintf(stderr, "%s\n", failure.UTF8String);
    return failure ? EXIT_FAILURE : EXIT_SUCCESS;
}

@interface FLService : NSObject <LocalFridaService, FLInstallService, FLScriptOverlayService>
- (instancetype)initWithRuntime:(FLRuntime *)runtime queue:(dispatch_queue_t)queue owner:(NSUUID *)owner;
@end

@implementation FLService {
    FLRuntime *_runtime;
    dispatch_queue_t _queue;
    NSUUID *_owner;
}

- (instancetype)initWithRuntime:(FLRuntime *)runtime queue:(dispatch_queue_t)queue owner:(NSUUID *)owner {
    if (!(self = [super init])) return nil;
    _runtime = runtime;
    _queue = queue;
    _owner = owner;
    return self;
}

- (void)reply:(FLReply)reply json:(NSDictionary *)json {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    reply(data, error.localizedDescription);
}

- (void)perform:(NSString *(^)(FLRuntime *))operation reply:(FLReply)reply {
    dispatch_async(_queue, ^{
        NSString *error = operation(self->_runtime);
        if (error) reply(nil, error);
        else [self reply:reply json:[self->_runtime status]];
    });
}

- (void)statusWithReply:(FLReply)reply {
    dispatch_async(_queue, ^{ [self reply:reply json:[self->_runtime status]]; });
}

- (void)startServerWithReply:(FLReply)reply {
    [self perform:^NSString *(FLRuntime *runtime) { return [runtime startServer]; } reply:reply];
}

- (void)stopServerWithReply:(FLReply)reply {
    [self perform:^NSString *(FLRuntime *runtime) { return [runtime stopServer]; } reply:reply];
}

- (void)updateAddress:(NSString *)address port:(NSInteger)port withReply:(FLReply)reply {
    [self perform:^NSString *(FLRuntime *runtime) { return [runtime updateAddress:address port:port]; } reply:reply];
}

- (void)updateOverlayTransparency:(double)transparency withReply:(FLReply)reply {
    [self perform:^NSString *(FLRuntime *runtime) { return [runtime updateOverlayTransparency:transparency]; } reply:reply];
}

- (void)updateOverlayEnabled:(BOOL)enabled withReply:(FLReply)reply {
    [self perform:^NSString *(FLRuntime *runtime) { return [runtime updateOverlayEnabled:enabled]; } reply:reply];
}

- (void)installVersion:(NSString *)version checksum:(NSString *)checksum withReply:(FLReply)reply {
    [self perform:^NSString *(FLRuntime *runtime) { return [runtime installVersion:version checksum:checksum]; } reply:reply];
}

- (void)downloadProgressForVersion:(NSString *)version withReply:(FLReply)reply {
    [self reply:reply json:FLReleaseDownloadProgress(version)];
}

- (void)selectVersion:(NSString *)version replacing:(NSString *)previous restart:(BOOL)restart withReply:(FLReply)reply {
    [self perform:^NSString *(FLRuntime *runtime) {
        return [runtime selectVersion:version replacing:previous restart:restart];
    } reply:reply];
}

- (void)stopForVersionChangeWithReply:(FLReply)reply {
    [self perform:^NSString *(FLRuntime *runtime) { return [runtime stopForVersionChange]; } reply:reply];
}

- (void)listTargetsForSpawn:(BOOL)spawn withReply:(FLReply)reply {
    dispatch_async(_queue, ^{
        NSString *failure = nil;
        NSArray *targets = [self->_runtime listTargetsForSpawn:spawn failure:&failure];
        if (targets) [self reply:reply json:@{ @"targets": targets }];
        else reply(nil, failure);
    });
}

- (void)runScript:(NSString *)source name:(NSString *)name bundle:(NSString *)bundle pid:(NSInteger)pid
    spawn:(BOOL)spawn withReply:(FLReply)reply {
    if (!source || !name) { reply(nil, @"缺少脚本或目标。"); return; }
    [self perform:^NSString *(FLRuntime *runtime) {
        return [runtime runScript:source name:name bundle:bundle pid:pid spawn:spawn owner:self->_owner];
    } reply:reply];
}

- (void)stopSessionWithReply:(FLReply)reply {
    [self perform:^NSString *(FLRuntime *runtime) { return [runtime stopSession]; } reply:reply];
}

- (void)consoleAfter:(NSInteger)cursor withReply:(FLReply)reply {
    dispatch_async(_queue, ^{ [self reply:reply json:[self->_runtime consoleAfter:cursor]]; });
}

- (void)scriptOverlayAfter:(NSInteger)cursor session:(NSString *)sessionID withReply:(FLOverlayReply)reply {
    dispatch_async(_queue, ^{ [self reply:reply json:[self->_runtime scriptOverlayAfter:cursor session:sessionID]]; });
}

- (void)stopOverlaySession:(NSString *)sessionID withReply:(FLOverlayReply)reply {
    dispatch_async(_queue, ^{
        NSString *error = [self->_runtime stopOverlaySession:sessionID];
        if (error) reply(nil, error);
        else [self reply:reply json:@{}];
    });
}
@end

@interface FLListener : NSObject <NSXPCListenerDelegate>
@end

@implementation FLListener {
    FLRuntime *_runtime;
    dispatch_queue_t _queue;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _runtime = [FLRuntime new];
    _queue = dispatch_queue_create("dev.fridalocal.runtime", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    Protocol *protocol = nil;
    if (connection.effectiveUserIdentifier == 0
        && FLProcessMatches(connection.processIdentifier, FLPath(@"/usr/bin/fridalocald"))) {
        protocol = @protocol(FLInstallService);
    } else if (FLAuthorize(connection, FLPath(@"/Applications/FridaLocal.app/FridaLocal"), @"dev.fridalocal.app")) {
        protocol = @protocol(LocalFridaService);
    } else if (FLAuthorize(connection, @"/System/Library/CoreServices/SpringBoard.app/SpringBoard", @"com.apple.springboard")) {
        protocol = @protocol(FLScriptOverlayService);
    }
    if (!protocol) return NO;
    NSUUID *owner = [NSUUID UUID];
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:protocol];
    connection.exportedObject = [[FLService alloc] initWithRuntime:_runtime queue:_queue owner:owner];
    connection.invalidationHandler = ^{
        dispatch_async(self->_queue, ^{ [self->_runtime clientDisconnected:owner]; });
    };
    [connection resume];
    return YES;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--reap-orphans") == 0) {
            NSInteger reaped = FLReapManagedOrphans();
            if (reaped > 0) printf("Cleaned up %ld orphaned Frida Local server process(es).\n", (long)reaped);
            return reaped >= 0 ? EXIT_SUCCESS : EXIT_FAILURE;
        }
        if (argc == 2 && strcmp(argv[1], "--start-installed-server") == 0) return FLStartInstalledServer();
        FLListener *delegate = [FLListener new];
        NSXPCListener *listener = FLCreateServiceListener(FL_PROTOCOL_MAJOR);
        if (!listener) return EXIT_FAILURE;
        [listener setDelegate:delegate];
        [listener resume];
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
