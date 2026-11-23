#import "Runtime.h"
#import "ReleaseAssets.h"
#import <roothide.h>
#import <frida-core.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
extern int proc_pidpath(int pid, void *buffer, uint32_t size);

#ifndef FL_PROTOCOL_MAJOR
#error Frida protocol major is required
#endif

static const NSInteger FLDefaultPort = 27042;
static NSString *const FLLoopbackAddress = @"127.0.0.1";
static NSString *const FLAllInterfacesAddress = @"0.0.0.0";
static const NSUInteger FLMaximumScriptSize = 512 * 1024;
static NSString *const FLStateDirectory = @"/var/lib/fridalocal";

static NSInteger FLProbePort(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct sockaddr_in address = {
        .sin_len = sizeof(address),
        .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    socklen_t length = sizeof(address);
    BOOL assigned = bind(fd, (struct sockaddr *)&address, length) == 0
        && getsockname(fd, (struct sockaddr *)&address, &length) == 0;
    close(fd);
    return assigned ? ntohs(address.sin_port) : 0;
}

NSString *FLPath(NSString *path) {
    return jbroot(path);
}

BOOL FLProcessMatches(pid_t pid, NSString *executable) {
    char path[4096] = {0};
    if (pid < 2 || proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    struct stat actual, expected;
    return stat(path, &actual) == 0 && stat(FLPath(executable).fileSystemRepresentation, &expected) == 0
        && actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino;
}

static int FLOpenServerLock(void) {
    NSString *directory = FLPath(FLStateDirectory);
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                   attributes:@{ NSFilePosixPermissions: @0700 } error:NULL]) return -1;
    NSString *lock = [directory stringByAppendingPathComponent:@"server.lock"];
    int fd = open(lock.fileSystemRepresentation, O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_RDWR, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) == 0) return fd;
    close(fd);
    return -1;
}

static NSString *FLCanonicalPath(const char *path) {
    char resolved[PATH_MAX];
    if (!path || !realpath(path, resolved)) return nil;
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
}

static NSString *FLThirdPartyAppPath(FridaApplication *app, NSString *bundle, NSString *jailbreakAppsPrefix) {
    if ([bundle.lowercaseString hasPrefix:@"com.apple."]) return nil;
    GHashTable *parameters = frida_application_get_parameters(app);
    GVariant *value = parameters ? g_hash_table_lookup(parameters, "path") : NULL;
    if (!value || !g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) return nil;
    NSString *path = FLCanonicalPath(g_variant_get_string(value, NULL));
    if (![path.pathExtension.lowercaseString isEqualToString:@"app"]) return nil;
    if ([path hasPrefix:@"/private/var/containers/Bundle/Application/"]
        || [path hasPrefix:@"/var/containers/Bundle/Application/"]
        || (jailbreakAppsPrefix && [path hasPrefix:jailbreakAppsPrefix])) return path;
    return nil;
}

static BOOL FLIsThirdPartyAppProcess(pid_t pid, NSSet<NSString *> *appPaths) {
    char path[4096] = {0};
    if (pid < 2 || !appPaths.count || proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    NSString *executable = FLCanonicalPath(path);
    for (NSString *directory = executable.stringByDeletingLastPathComponent;
         directory.length > 1; directory = directory.stringByDeletingLastPathComponent) {
        if ([appPaths containsObject:directory]) return YES;
    }
    return NO;
}

static BOOL FLIsManagedOrphan(const struct kinfo_proc *process, NSSet<NSString *> *paths) {
    pid_t pid = process->kp_proc.p_pid;
    if (pid < 2 || process->kp_eproc.e_ppid != 1 || process->kp_eproc.e_ucred.cr_uid != 0
        || strcmp(process->kp_proc.p_comm, "frida-server") != 0) return NO;
    char path[4096] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    NSString *canonical = FLCanonicalPath(path);
    return canonical && [paths containsObject:canonical];
}

static BOOL FLOrphanStillMatches(const struct kinfo_proc *previous, NSSet<NSString *> *paths) {
    struct kinfo_proc current = {0};
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, previous->kp_proc.p_pid };
    size_t size = sizeof(current);
    return sysctl(mib, 4, &current, &size, NULL, 0) == 0 && size == sizeof(current)
        && current.kp_proc.p_pid == previous->kp_proc.p_pid
        && timercmp(&current.kp_proc.p_starttime, &previous->kp_proc.p_starttime, ==)
        && FLIsManagedOrphan(&current, paths);
}

// The server lock must be held. A live helper or a server installed outside this package stays out of scope.
static NSInteger FLReapManagedOrphansWithLock(void) {
    NSMutableSet<NSString *> *paths = [NSMutableSet new];
    for (NSString *version in FLInstalledReleases()) {
        NSString *path = FLCanonicalPath(FLPath(FLReleaseExecutable(version)).fileSystemRepresentation);
        if (path) [paths addObject:path];
    }
    if (!paths.count) return 0;

    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t bytes = 0;
    if (sysctl(mib, 4, NULL, &bytes, NULL, 0) != 0 || !bytes) return 0;
    bytes += 32 * sizeof(struct kinfo_proc);
    struct kinfo_proc *processes = malloc(bytes);
    if (!processes) return 0;
    if (sysctl(mib, 4, processes, &bytes, NULL, 0) != 0) {
        free(processes);
        return 0;
    }

    NSInteger reaped = 0;
    for (size_t index = 0; index < bytes / sizeof(*processes); index++) {
        const struct kinfo_proc *process = &processes[index];
        if (!FLIsManagedOrphan(process, paths) || !FLOrphanStillMatches(process, paths)) continue;
        pid_t pid = process->kp_proc.p_pid;
        kill(pid, SIGTERM);
        for (NSUInteger i = 0; i < 10 && FLOrphanStillMatches(process, paths); i++) usleep(50000);
        if (FLOrphanStillMatches(process, paths)) {
            kill(pid, SIGKILL);
            for (NSUInteger i = 0; i < 10 && FLOrphanStillMatches(process, paths); i++) usleep(50000);
        }
        if (FLOrphanStillMatches(process, paths)) {
            reaped = -1;
            break;
        }
        reaped++;
    }
    free(processes);
    return reaped;
}

NSInteger FLReapManagedOrphans(void) {
    if (geteuid() != 0) return -1;
    int lock = FLOpenServerLock();
    if (lock < 0) return -1;
    NSInteger reaped = FLReapManagedOrphansWithLock();
    close(lock);
    return reaped;
}

static NSString *FLText(const gchar *text) {
    return text ? ([NSString stringWithUTF8String:text] ?: @"") : @"";
}

static NSString *FLFridaError(GError **error, NSString *fallback) {
    if (!*error) return fallback;
    NSString *message = FLText((*error)->message);
    g_clear_error(error);
    return message.length ? message : fallback;
}

// Frida's synchronous API runs on its GLib thread. Cancellation runs independently of XPC.
static void FLWithDeadline(NSTimeInterval seconds, void (^operation)(GCancellable *)) {
    GCancellable *cancellable = g_cancellable_new();
    dispatch_source_t timeout = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                         dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timeout, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(timeout, ^{ g_cancellable_cancel(cancellable); });
    dispatch_source_set_cancel_handler(timeout, ^{ g_object_unref(cancellable); });
    dispatch_activate(timeout);
    operation(cancellable);
    dispatch_source_cancel(timeout);
}

@interface FLConsole : NSObject
@property (nonatomic, readonly) NSString *epoch;
- (void)append:(NSString *)text kind:(NSString *)kind;
- (NSArray *)entriesAfter:(NSInteger)cursor;
@end

@implementation FLConsole {
    NSLock *_lock;
    NSMutableArray *_entries;
    NSInteger _sequence;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _epoch = NSUUID.UUID.UUIDString;
    _lock = [NSLock new];
    _entries = [NSMutableArray new];
    return self;
}
- (void)append:(NSString *)text kind:(NSString *)kind {
    if (text.length > 4096) {
        NSRange range = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 4096)];
        text = [text substringWithRange:range];
        text = [text stringByAppendingString:@"…"];
    }
    [_lock lock];
    if (_entries.count >= 180) [_entries removeObjectAtIndex:0];
    [_entries addObject:@{ @"id": @(++_sequence), @"text": text, @"kind": kind }];
    [_lock unlock];
}
- (NSArray *)entriesAfter:(NSInteger)cursor {
    [_lock lock];
    if (cursor > _sequence) cursor = 0;
    NSMutableArray *entries = [NSMutableArray new];
    for (NSDictionary *entry in _entries) {
        if ([entry[@"id"] integerValue] > cursor) [entries addObject:entry];
    }
    [_lock unlock];
    return entries;
}
@end

static void FLReleaseContext(gpointer context, GClosure *closure) {
    CFRelease(context);
}

static void FLMessage(FridaScript *script, const gchar *message, GBytes *bytes, gpointer context) {
    @autoreleasepool {
        FLConsole *console = (__bridge FLConsole *)context;
        NSString *raw = FLText(message);
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding]
                                                               options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class]) {
            [console append:raw kind:@"message"];
            return;
        }
        NSString *type = json[@"type"];
        id payload = json[@"payload"];
        NSString *text = raw;
        if ([type isEqualToString:@"error"]) {
            text = json[@"stack"] ?: json[@"description"] ?: raw;
        } else if ([payload isKindOfClass:NSString.class]) {
            text = payload;
        } else if (payload) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingFragmentsAllowed error:nil];
            if (data) text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: raw;
        }
        if (bytes) text = [text stringByAppendingFormat:@" (%zu bytes)", g_bytes_get_size(bytes)];
        [console append:text kind:([type isEqualToString:@"error"] || [json[@"level"] isEqual:@"error"]) ? @"error" : @"message"];
    }
}

static void FLDetached(FridaSession *session, FridaSessionDetachReason reason, FridaCrash *crash, gpointer context) {
    @autoreleasepool {
        FLConsole *console = (__bridge FLConsole *)context;
        NSString *message = @"会话已断开。";
        switch (reason) {
            case FRIDA_SESSION_DETACH_REASON_APPLICATION_REQUESTED: return;
            case FRIDA_SESSION_DETACH_REASON_PROCESS_REPLACED: message = @"目标进程已被替换。"; break;
            case FRIDA_SESSION_DETACH_REASON_PROCESS_TERMINATED: message = @"目标进程已退出。"; break;
            case FRIDA_SESSION_DETACH_REASON_CONNECTION_TERMINATED: message = @"与 frida-server 的连接已断开。"; break;
            case FRIDA_SESSION_DETACH_REASON_DEVICE_LOST: message = @"Frida 设备连接已丢失。"; break;
        }
        if (crash) message = [message stringByAppendingFormat:@" %@", FLText(frida_crash_get_summary(crash))];
        [console append:message kind:@"error"];
    }
}

@implementation FLRuntime {
    NSInteger _port;
    NSString *_address;
    pid_t _serverPID;
    int _serverOutput;
    int _serverLock;
    BOOL _stoppingServer;
    FridaDeviceManager *_manager;
    FridaDevice *_device;
    FridaSession *_session;
    FridaScript *_script;
    gulong _messageHandler;
    gulong _detachHandler;
    NSString *_serverError;
    NSString *_sessionName;
    NSUUID *_owner;
    FLConsole *_console;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    frida_init();
    _console = [FLConsole new];
    _serverOutput = -1;
    _serverLock = -1;
    _port = FLDefaultPort;
    _address = FLLoopbackAddress;
    return self;
}

- (NSString *)settingsPath {
    return [FLPath(FLStateDirectory) stringByAppendingPathComponent:@"settings.plist"];
}

- (NSString *)selectedVersion:(NSDictionary *)settings {
    NSString *version = settings[@"version"];
    NSInteger major = [version isKindOfClass:NSString.class] ? FLReleaseMajor(version) : 0;
    return major == 16 || major == 17 ? version : FLBundledVersion;
}

- (NSString *)persistAddress:(NSString *)address port:(NSInteger)port version:(NSString *)version {
    NSError *error;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:FLPath(FLStateDirectory)
                                  withIntermediateDirectories:YES attributes:@{ NSFilePosixPermissions: @0700 } error:&error]) {
        return error.localizedDescription;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{ @"address": address, @"port": @(port), @"version": version }
                     format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!data || ![data writeToFile:[self settingsPath] options:NSDataWritingAtomic error:&error]) {
        return error.localizedDescription ?: @"无法保存配置。";
    }
    return nil;
}

- (NSDictionary *)status {
    [self refreshServer];
    if (_session && frida_session_is_detached(_session)) [self closeSession];
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:[self settingsPath]];
    if (_serverPID <= 0) {
        NSInteger saved = [settings[@"port"] integerValue];
        _port = saved >= 1024 && saved <= 65535 ? saved : FLDefaultPort;
        _address = [settings[@"address"] isEqual:FLAllInterfacesAddress] ? FLAllInterfacesAddress : FLLoopbackAddress;
    }
    NSMutableDictionary *status = [@{ @"running": (_serverPID > 0 && _device != NULL && !_stoppingServer) ? @YES : @NO,
        @"address": _address, @"port": @(_port), @"version": [self selectedVersion:settings], @"installedVersions": FLInstalledReleases() } mutableCopy];
    if (_session) {
        status[@"sessionPID"] = @(frida_session_get_pid(_session));
        status[@"sessionName"] = _sessionName;
    }
    if (_serverError) status[@"serverError"] = _serverError;
    return status;
}

- (NSDictionary *)consoleAfter:(NSInteger)cursor {
    return @{ @"epoch": _console.epoch, @"status": [self status], @"entries": [_console entriesAfter:cursor] };
}

- (void)readServerOutput {
    if (_serverOutput < 0) return;
    char bytes[1024];
    for (NSUInteger i = 0; i < 8; i++) {
        ssize_t count = read(_serverOutput, bytes, sizeof(bytes));
        if (count <= 0) break;
        NSString *text = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)count encoding:NSUTF8StringEncoding];
        text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (text.length) {
            _serverError = text;
            [_console append:text kind:@"error"];
        }
    }
}

- (void)refreshServer {
    if (_serverPID <= 0) return;
    [self readServerOutput];
    int result = 0;
    pid_t exited = waitpid(_serverPID, &result, WNOHANG);
    if (exited != _serverPID && !(exited < 0 && errno == ECHILD)) return;
    _serverPID = 0;
    [self releaseServerLock];
    close(_serverOutput);
    _serverOutput = -1;
    [self closeConnection];
    if (!_stoppingServer) {
        if (!_serverError) {
            _serverError = WIFSIGNALED(result)
                ? [NSString stringWithFormat:@"frida-server 被信号 %d 终止。", WTERMSIG(result)]
                : [NSString stringWithFormat:@"frida-server 已退出（%d）。", WEXITSTATUS(result)];
        }
        [_console append:_serverError kind:@"error"];
    }
    _stoppingServer = NO;
}

- (void)releaseServerLock {
    if (_serverLock >= 0) close(_serverLock);
    _serverLock = -1;
}

- (NSString *)launchServerAt:(NSString *)address port:(NSInteger)port version:(NSString *)version {
    [self refreshServer];
    if (_serverPID > 0) return @"上一个 frida-server 实例尚未退出。";
    NSString *serverPath = FLPath(FLReleaseExecutable(version));
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:serverPath]) {
        return @"软件包中缺少 frida-server。";
    }
    _serverLock = FLOpenServerLock();
    if (_serverLock < 0) return @"已有 Frida Local 服务实例在运行。";
    NSInteger reaped = FLReapManagedOrphansWithLock();
    if (reaped < 0) {
        [self releaseServerLock];
        return @"无法清理上次退出后残留的 Frida Local 服务。";
    }
    if (reaped > 0) [_console append:@"已清理上次退出后残留的 Frida Local 服务。" kind:@"status"];
    _serverError = nil;
    NSString *endpoint = [NSString stringWithFormat:@"%@:%ld", address, (long)port];
    NSString *portConflict = [NSString stringWithFormat:@"地址 %@ 已被其他进程占用。请在设置中选择其他端口。", endpoint];
    NSString *localEndpoint = [NSString stringWithFormat:@"%@:%ld", FLLoopbackAddress, (long)port];
    NSString *token = [NSUUID.UUID.UUIDString stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *listen = [@"--listen=" stringByAppendingString:endpoint];
    NSString *authorization = [@"--token=" stringByAppendingString:token];
    const char *executable = serverPath.fileSystemRepresentation;
    char *arguments[] = { (char *)executable, (char *)listen.UTF8String, (char *)authorization.UTF8String,
        "--disable-preload", "--ignore-crashes", NULL };
    int output[2];
    if (pipe(output) != 0) {
        [self releaseServerLock];
        return @"无法创建 frida-server 日志管道。";
    }
    fcntl(output[0], F_SETFL, O_NONBLOCK);
    fcntl(output[0], F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t actions;
    int result = posix_spawn_file_actions_init(&actions);
    if (!result) {
        result = posix_spawn_file_actions_adddup2(&actions, output[1], STDERR_FILENO);
        if (!result) result = posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
        if (!result) result = posix_spawn_file_actions_addclose(&actions, output[1]);
        if (!result) result = posix_spawn(&_serverPID, executable, &actions, NULL, arguments, environ);
        posix_spawn_file_actions_destroy(&actions);
    }
    close(output[1]);
    if (result) {
        close(output[0]);
        _serverPID = 0;
        [self releaseServerLock];
        return [NSString stringWithFormat:@"无法启动 frida-server（%s）。", strerror(result)];
    }
    _serverOutput = output[0];
    const uint64_t deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + 6 * NSEC_PER_SEC;
    NSString *probeError = nil;
    do {
        [self refreshServer];
        if (_serverPID <= 0) {
            if ([_serverError localizedCaseInsensitiveContainsString:@"Address already in use"]) return portConflict;
            return _serverError ?: @"frida-server 已退出。";
        }
        probeError = [self connectTo:localEndpoint token:token];
        if (!probeError) {
            [self refreshServer];
            if (_serverPID <= 0) return _serverError ?: @"frida-server 已退出。";
            return nil;
        }
        usleep(160000);
    } while (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) < deadline);
    NSString *message = _serverError ?: probeError ?: @"未能连接到 frida-server。";
    if ([message localizedCaseInsensitiveContainsString:@"Address already in use"]) message = portConflict;
    [self terminateServer];
    return message;
}

- (NSString *)connectTo:(NSString *)endpoint token:(NSString *)token {
    _manager = frida_device_manager_new_with_socket_backend_only();
    FridaRemoteDeviceOptions *options = frida_remote_device_options_new();
    frida_remote_device_options_set_token(options, token.UTF8String);
    __block GError *error = NULL;
    __block GHashTable *parameters = NULL;
    FLWithDeadline(1, ^(GCancellable *cancellable) {
        self->_device = frida_device_manager_add_remote_device_sync(self->_manager, endpoint.UTF8String, options,
                                                                   cancellable, &error);
        if (self->_device) parameters = frida_device_query_system_parameters_sync(self->_device, cancellable, &error);
    });
    g_object_unref(options);
    if (parameters) {
        g_hash_table_unref(parameters);
        return nil;
    }
    NSString *message = FLFridaError(&error, @"Frida 握手失败。");
    [self closeConnection];
    return message;
}

- (NSString *)terminateServer {
    [self refreshServer];
    _stoppingServer = _serverPID > 0;
    [self closeConnection];
    if (_serverPID <= 0) return nil;
    kill(_serverPID, SIGTERM);
    for (NSUInteger attempt = 0; _serverPID > 0 && attempt < 20; attempt++) {
        usleep(50000);
        [self refreshServer];
    }
    if (_serverPID > 0) {
        kill(_serverPID, SIGKILL);
        for (NSUInteger attempt = 0; _serverPID > 0 && attempt < 20; attempt++) {
            usleep(50000);
            [self refreshServer];
        }
    }
    return _serverPID > 0 ? @"无法停止 frida-server。" : nil;
}

- (void)logStartedVersion:(NSString *)version {
    NSString *text = [NSString stringWithFormat:@"Frida %@ 已在 %@:%ld 启动。", version, _address, (long)_port];
    [_console append:text kind:@"status"];
}

- (NSString *)startServer {
    NSDictionary *status = [self status];
    NSString *version = status[@"version"];
    if (FLReleaseMajor(version) != FL_PROTOCOL_MAJOR) return @"所选版本使用另一个 Frida 客户端。";
    if ([status[@"running"] boolValue]) return nil;
    _serverError = [self launchServerAt:_address port:_port version:version];
    if (!_serverError) [self logStartedVersion:version];
    return _serverError;
}

- (NSString *)stopServer {
    _serverError = [self terminateServer];
    if (!_serverError) [_console append:@"frida-server 已停止。" kind:@"status"];
    return _serverError;
}

- (NSString *)installVersion:(NSString *)version checksum:(NSString *)checksum {
    if (FLReleaseMajor(version) != FL_PROTOCOL_MAJOR) return @"此版本与当前 Frida 客户端不兼容。";
    return FLInstallRelease(version, checksum);
}

- (NSString *)stopForVersionChange {
    [self status];
    if (_session) return @"请先停止当前会话。";
    return [self stopServer];
}

- (NSString *)selectVersion:(NSString *)version replacing:(NSString *)previous restart:(BOOL)restart {
    NSDictionary *status = [self status];
    if (FLReleaseMajor(version) != FL_PROTOCOL_MAJOR) return @"此版本与当前 Frida 客户端不兼容。";
    if (![status[@"version"] isEqualToString:previous]) return @"当前版本已改变，请刷新后再试。";
    if (_session || _serverPID > 0) return @"请先停止当前服务或会话。";
    NSInteger port = restart ? _port : FLProbePort();
    if (!port) return @"无法分配本机校验端口。";
    NSString *failure = [self launchServerAt:restart ? _address : FLLoopbackAddress port:port version:version];
    if (failure) {
        _serverError = nil;
        return [NSString stringWithFormat:@"无法启用 Frida %@。%@", version, failure];
    }
    if (!restart) {
        failure = [self terminateServer];
        if (failure) return failure;
    }
    failure = [self persistAddress:_address port:_port version:version];
    if (failure) {
        if (restart) [self terminateServer];
        return failure;
    }
    if (restart) {
        [self logStartedVersion:version];
    } else {
        [_console append:[NSString stringWithFormat:@"已切换到 Frida %@，服务仍处于停止状态。", version] kind:@"status"];
    }
    return nil;
}

- (NSString *)updateAddress:(NSString *)address port:(NSInteger)port {
    if (![address isEqualToString:FLLoopbackAddress] && ![address isEqualToString:FLAllInterfacesAddress]) {
        return @"监听地址必须是 127.0.0.1 或 0.0.0.0。";
    }
    if (port < 1024 || port > 65535) return @"端口必须介于 1024 和 65535 之间。";
    NSDictionary *status = [self status];
    if (port == _port && [address isEqualToString:_address]) return nil;
    NSString *version = status[@"version"];
    if (FLReleaseMajor(version) != FL_PROTOCOL_MAJOR) return @"所选版本使用另一个 Frida 客户端。";
    if (_session) return @"请先停止当前会话。";
    BOOL running = [status[@"running"] boolValue];
    if (_serverPID > 0 && !running) return @"上一个 frida-server 实例尚未退出。";
    NSString *error = nil;
    if (running) {
        error = [self terminateServer];
        if (error) return error;
        error = [self launchServerAt:address port:port version:version];
    }
    if (!error) error = [self persistAddress:address port:port version:version];
    if (!error) {
        _port = port;
        _address = [address copy];
        _serverError = nil;
        if (running) [self logStartedVersion:version];
        return nil;
    }
    if (!running) return error;
    NSString *restore = [self terminateServer] ?: [self launchServerAt:_address port:_port version:version];
    _serverError = restore;
    if (!restore) [self logStartedVersion:version];
    return restore ? [NSString stringWithFormat:@"%@ 恢复 %@:%ld 失败。%@", error, _address, (long)_port, restore]
                   : [NSString stringWithFormat:@"%@ 已恢复 %@:%ld。", error, _address, (long)_port];
}

- (NSArray *)listTargetsForSpawn:(BOOL)spawn failure:(NSString **)failure {
    [self refreshServer];
    FridaDeviceManager *localManager = _device ? NULL : frida_device_manager_new();
    __block FridaDevice *localDevice = NULL;
    __block GError *error = NULL;
    __block FridaApplicationList *applications = NULL;
    __block FridaProcessList *processes = NULL;
    FLWithDeadline(6, ^(GCancellable *cancellable) {
        FridaDevice *device = self->_device;
        if (!device) {
            localDevice = frida_device_manager_get_device_by_type_sync(localManager, FRIDA_DEVICE_TYPE_LOCAL,
                                                                       1200, cancellable, &error);
            device = localDevice;
        }
        if (!device) return;
        FridaApplicationQueryOptions *options = frida_application_query_options_new();
        frida_application_query_options_set_scope(options, FRIDA_SCOPE_METADATA);
        applications = frida_device_enumerate_applications_sync(device, options, cancellable, &error);
        g_object_unref(options);
        if (applications && !spawn) {
            processes = frida_device_enumerate_processes_sync(device, NULL, cancellable, &error);
        }
    });
    g_clear_object(&localDevice);
    if (localManager) {
        FLWithDeadline(2, ^(GCancellable *cancellable) {
            frida_device_manager_close_sync(localManager, cancellable, NULL);
        });
        g_object_unref(localManager);
    }
    if (!applications || (!spawn && !processes)) {
        g_clear_object(&applications);
        g_clear_object(&processes);
        *failure = FLFridaError(&error, @"无法读取设备上的目标列表。");
        return nil;
    }

    NSMutableArray *rows = [NSMutableArray new];
    NSMutableSet<NSString *> *thirdPartyAppPaths = [NSMutableSet new];
    NSString *jailbreakApps = FLCanonicalPath(FLPath(@"/Applications").fileSystemRepresentation);
    NSString *jailbreakAppsPrefix = [jailbreakApps isEqualToString:@"/Applications"] ? nil
        : [jailbreakApps stringByAppendingString:@"/"];
    for (gint index = 0; index < frida_application_list_size(applications); index++) {
        FridaApplication *app = frida_application_list_get(applications, index);
        NSString *bundle = FLText(frida_application_get_identifier(app));
        NSString *name = FLText(frida_application_get_name(app));
        NSString *thirdPartyPath = bundle.length ? FLThirdPartyAppPath(app, bundle, jailbreakAppsPrefix) : nil;
        g_object_unref(app);
        if (!bundle.length) continue;
        if (!spawn) {
            if (thirdPartyPath) [thirdPartyAppPaths addObject:thirdPartyPath];
            continue;
        }
        NSDictionary *row = @{ @"id": bundle, @"name": name.length ? name : bundle,
                                @"bundleID": bundle, @"thirdParty": thirdPartyPath ? @YES : @NO };
        [rows addObject:row];
    }
    g_object_unref(applications);
    if (processes) {
        for (gint index = 0; index < frida_process_list_size(processes); index++) {
            FridaProcess *process = frida_process_list_get(processes, index);
            guint pid = frida_process_get_pid(process);
            NSString *name = FLText(frida_process_get_name(process));
            g_object_unref(process);
            NSString *identifier = [NSString stringWithFormat:@"%u", pid];
            BOOL thirdParty = FLIsThirdPartyAppProcess((pid_t)pid, thirdPartyAppPaths);
            NSDictionary *row = @{ @"id": identifier, @"name": name.length ? name : identifier,
                                    @"pid": @(pid), @"thirdParty": thirdParty ? @YES : @NO };
            [rows addObject:row];
        }
        g_object_unref(processes);
    }
    return rows;
}

- (NSString *)runScript:(NSString *)source name:(NSString *)name bundle:(NSString *)bundle
                    pid:(NSInteger)requestedPID spawn:(BOOL)spawn owner:(NSUUID *)owner {
    NSDictionary *status = [self status];
    if (![status[@"running"] boolValue]) return @"请先启动 frida-server。";
    if (_session) return @"已有会话运行中。";
    NSData *sourceBytes = [source dataUsingEncoding:NSUTF8StringEncoding];
    if (sourceBytes.length == 0 || sourceBytes.length > FLMaximumScriptSize
        || memchr(sourceBytes.bytes, 0, sourceBytes.length) != NULL || name.length == 0 || name.length > 255) {
        return @"脚本名称或内容无效。";
    }
    if (requestedPID < 0 || requestedPID > INT_MAX || (spawn && requestedPID != 0)) return @"PID 无效。";
    if (spawn && !bundle.length) return @"Spawn 模式需要应用的 Bundle ID。";
    if (!spawn && requestedPID == 0 && !bundle.length) return @"Attach 模式需要 PID 或 Bundle ID。";
    __block guint pid = (guint)requestedPID;
    __block BOOL suspended = NO;
    __block NSString *failure = nil;
    FLWithDeadline(18, ^(GCancellable *cancellable) {
        GError *error = NULL;
        if (spawn) {
            pid = frida_device_spawn_sync(self->_device, bundle.UTF8String, NULL, cancellable, &error);
            if (!pid) { failure = FLFridaError(&error, @"无法启动目标应用。"); return; }
            suspended = YES;
        } else if (!pid) {
            pid = [self runningPIDForBundle:bundle cancellable:cancellable error:&error];
            if (!pid) { failure = FLFridaError(&error, @"目标尚未运行。请先打开应用，或选择 Spawn。"); return; }
        }
        self->_session = frida_device_attach_sync(self->_device, pid, NULL, cancellable, &error);
        if (!self->_session) { failure = FLFridaError(&error, @"无法连接目标进程。"); return; }
        self->_sessionName = [name copy];
        self->_owner = owner;
        self->_detachHandler = g_signal_connect_data(self->_session, "detached", G_CALLBACK(FLDetached),
            (__bridge_retained void *)self->_console, FLReleaseContext, 0);
        FridaScriptOptions *options = frida_script_options_new();
        frida_script_options_set_name(options, name.UTF8String);
        self->_script = frida_session_create_script_sync(self->_session, source.UTF8String, options, cancellable, &error);
        g_object_unref(options);
        if (!self->_script) { failure = FLFridaError(&error, @"无法创建脚本。"); return; }
        self->_messageHandler = g_signal_connect_data(self->_script, "message", G_CALLBACK(FLMessage),
            (__bridge_retained void *)self->_console, FLReleaseContext, 0);
        frida_script_load_sync(self->_script, cancellable, &error);
        if (error) { failure = FLFridaError(&error, @"无法加载脚本。"); return; }
        if (suspended) {
            frida_device_resume_sync(self->_device, pid, cancellable, &error);
            if (error) { failure = FLFridaError(&error, @"无法恢复目标进程。"); return; }
            suspended = NO;
        }
    });
    if (failure) {
        [self closeSession];
        if (suspended) {
            FLWithDeadline(3, ^(GCancellable *cancellable) {
                GError *error = NULL;
                frida_device_resume_sync(self->_device, pid, cancellable, &error);
                if (error) {
                    kill((pid_t)pid, SIGKILL);
                }
                g_clear_error(&error);
            });
        }
        [_console append:failure kind:@"error"];
        return failure;
    }
    [_console append:[NSString stringWithFormat:@"%@ 已加载（PID %u）。", name, pid] kind:@"status"];
    return nil;
}

- (guint)runningPIDForBundle:(NSString *)bundle cancellable:(GCancellable *)cancellable error:(GError **)error {
    FridaApplicationQueryOptions *options = frida_application_query_options_new();
    frida_application_query_options_select_identifier(options, bundle.UTF8String);
    FridaApplicationList *apps = frida_device_enumerate_applications_sync(_device, options, cancellable, error);
    g_object_unref(options);
    if (!apps) return 0;
    guint pid = 0;
    for (gint index = 0; index < frida_application_list_size(apps); index++) {
        FridaApplication *app = frida_application_list_get(apps, index);
        if ([bundle isEqualToString:FLText(frida_application_get_identifier(app))]) pid = frida_application_get_pid(app);
        g_object_unref(app);
    }
    g_object_unref(apps);
    return pid;
}

- (NSString *)stopSession {
    if (!_session) return nil;
    NSString *error = [self closeSession];
    if (!error) [_console append:@"会话已停止。" kind:@"status"];
    return error;
}

- (void)clientDisconnected:(NSUUID *)client {
    if ([_owner isEqual:client]) [self stopSession];
}

- (NSString *)closeSession {
    if (_session && !frida_session_is_detached(_session)) {
        if (_script) {
            FLWithDeadline(3, ^(GCancellable *cancellable) {
                frida_script_unload_sync(self->_script, cancellable, NULL);
            });
        }
        __block GError *error = NULL;
        FLWithDeadline(3, ^(GCancellable *cancellable) {
            frida_session_detach_sync(self->_session, cancellable, &error);
        });
        if (error && !frida_session_is_detached(_session)) {
            return FLFridaError(&error, @"无法断开会话。");
        }
        g_clear_error(&error);
    }
    [self releaseSession];
    return nil;
}

- (void)releaseSession {
    if (_messageHandler) g_signal_handler_disconnect(_script, _messageHandler);
    if (_detachHandler) g_signal_handler_disconnect(_session, _detachHandler);
    _messageHandler = 0;
    _detachHandler = 0;
    g_clear_object(&_script);
    g_clear_object(&_session);
    _owner = nil;
    _sessionName = nil;
}

- (void)closeConnection {
    if ([self closeSession]) [self releaseSession];
    g_clear_object(&_device);
    if (_manager) {
        FLWithDeadline(2, ^(GCancellable *cancellable) {
            frida_device_manager_close_sync(self->_manager, cancellable, NULL);
        });
        g_clear_object(&_manager);
    }
}
@end
