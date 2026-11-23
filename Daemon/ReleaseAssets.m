#import "ReleaseAssets.h"
#import "Runtime.h"
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <os/lock.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

NSString *const FLBundledVersion = @"17.27.4";
static NSString *const FLReleasesDirectory = @"/var/lib/fridalocal-releases";
static const NSUInteger FLMaximumArchiveSize = 128 * 1024 * 1024;

NSInteger FLReleaseMajor(NSString *version) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"^(0|[1-9][0-9]{0,2})(\\.(0|[1-9][0-9]{0,4})){2}$"
                                                            options:0 error:NULL];
    });
    if (!version) return 0;
    NSRange full = NSMakeRange(0, version.length);
    NSRange match = [pattern rangeOfFirstMatchInString:version options:NSMatchingAnchored range:full];
    if (!NSEqualRanges(full, match)) return 0;
    return version.integerValue;
}

NSString *FLReleaseExecutable(NSString *version) {
    if ([version isEqualToString:FLBundledVersion]) return @"/usr/libexec/fridalocal/sbin/frida-server";
    return [[FLReleasesDirectory stringByAppendingPathComponent:version] stringByAppendingPathComponent:@"usr/sbin/frida-server"];
}

NSArray<NSString *> *FLInstalledReleases(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableArray *versions = [NSMutableArray new];
    if ([files isExecutableFileAtPath:FLPath(FLReleaseExecutable(FLBundledVersion))]) [versions addObject:FLBundledVersion];
    for (NSString *version in [files contentsOfDirectoryAtPath:FLPath(FLReleasesDirectory) error:NULL]) {
        if (FLReleaseMajor(version) && [files isExecutableFileAtPath:FLPath(FLReleaseExecutable(version))]) {
            [versions addObject:version];
        }
    }
    return versions;
}

// The downloader blocks the runtime queue. XPC progress reads its transfer separately.
static os_unfair_lock FLTransferLock = OS_UNFAIR_LOCK_INIT;
static NSURLSessionDownloadTask *FLActiveDownload;
static NSString *FLDownloadingVersion;
static BOOL FLValidatingDownload;

static void FLTrackDownload(NSString *version, NSURLSessionDownloadTask *task) {
    os_unfair_lock_lock(&FLTransferLock);
    FLActiveDownload = task;
    FLDownloadingVersion = version;
    FLValidatingDownload = NO;
    os_unfair_lock_unlock(&FLTransferLock);
}

static void FLValidateDownload(void) {
    os_unfair_lock_lock(&FLTransferLock);
    FLValidatingDownload = YES;
    os_unfair_lock_unlock(&FLTransferLock);
}

NSDictionary *FLReleaseDownloadProgress(NSString *version) {
    os_unfair_lock_lock(&FLTransferLock);
    BOOL matches = [FLDownloadingVersion isEqualToString:version];
    NSURLSessionDownloadTask *task = matches ? FLActiveDownload : nil;
    BOOL validating = matches && FLValidatingDownload;
    os_unfair_lock_unlock(&FLTransferLock);

    return @{ @"receivedBytes": @(MAX((int64_t)0, task.countOfBytesReceived)),
              @"totalBytes": @(MAX((int64_t)0, task.countOfBytesExpectedToReceive)),
              @"validating": @(validating) };
}

@interface FLGitHubDownload : NSObject <NSURLSessionTaskDelegate>
@end

@implementation FLGitHubDownload
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
              completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    NSString *host = request.URL.host.lowercaseString;
    BOOL trusted = [host isEqualToString:@"release-assets.githubusercontent.com"] ||
                   [host isEqualToString:@"objects.githubusercontent.com"];
    completionHandler(trusted && [request.URL.scheme isEqualToString:@"https"] ? request : nil);
}
@end

static NSString *FLDownloadArchive(NSString *version, NSString *destination) {
    NSString *address = [NSString stringWithFormat:@"https://github.com/frida/frida/releases/download/%@/frida_%@_iphoneos-arm64.deb", version, version];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 30;
    configuration.timeoutIntervalForResource = 120;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:[FLGitHubDownload new] delegateQueue:nil];
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block NSString *failure = nil;
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:[NSURL URLWithString:address]
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (error || !location) {
                failure = error.localizedDescription ?: @"无法下载 GitHub 发行包。";
            } else if (http.statusCode != 200) {
                failure = [NSString stringWithFormat:@"GitHub 下载失败（HTTP %ld）。", (long)http.statusCode];
            } else {
                unsigned long long downloaded = [[NSFileManager.defaultManager attributesOfItemAtPath:location.path error:NULL] fileSize];
                if (!downloaded || downloaded > FLMaximumArchiveSize) {
                    failure = @"发行包大小无效。";
                    dispatch_semaphore_signal(finished);
                    return;
                }
                NSError *moveError = nil;
                if (![NSFileManager.defaultManager moveItemAtPath:location.path toPath:destination error:&moveError]) {
                    failure = moveError.localizedDescription;
                }
            }
            dispatch_semaphore_signal(finished);
        }];
    FLTrackDownload(version, task);
    [task resume];
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];
    return failure;
}

static NSString *FLArchiveDigest(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!data.length || data.length > FLMaximumArchiveSize) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *digest = [NSMutableString stringWithString:@"sha256:"];
    for (NSUInteger i = 0; i < sizeof(hash); i++) [digest appendFormat:@"%02x", hash[i]];
    return digest;
}

static BOOL FLExtract(NSString *command, NSArray<NSString *> *parameters, NSString *output) {
    NSString *executable = FLPath(command);
    NSUInteger count = parameters.count;
    char *arguments[8] = { (char *)executable.fileSystemRepresentation };
    if (count >= 7) return NO;
    for (NSUInteger i = 0; i < count; i++) arguments[i + 1] = (char *)parameters[i].fileSystemRepresentation;

    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0) return NO;
    int result = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.fileSystemRepresentation,
                                                 O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (!result) result = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    pid_t pid;
    if (!result) result = posix_spawn(&pid, executable.fileSystemRepresentation, &actions, NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (result) return NO;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return NO;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static BOOL FLMachOFile(NSString *file) {
    int fd = open(file.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return NO;
    uint32_t magic = 0;
    struct stat info;
    BOOL valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size >= (off_t)sizeof(struct mach_header_64)
        && read(fd, &magic, sizeof(magic)) == sizeof(magic)
        && (magic == FAT_MAGIC || magic == FAT_CIGAM || magic == MH_MAGIC_64);
    close(fd);
    return valid;
}

static NSString *FLExtractRelease(NSString *package, NSString *stage) {
    NSString *tar = [stage stringByAppendingPathComponent:@"data.tar"];
    if (!FLExtract(@"/usr/bin/dpkg-deb", @[@"--fsys-tarfile", package], tar)) return @"无法读取官方软件包。";
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *server = [stage stringByAppendingPathComponent:@"usr/sbin/frida-server"];
    if (![files createDirectoryAtPath:server.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL]
        || !FLExtract(@"/usr/bin/tar", @[@"-xOf", tar, @"./var/jb/usr/sbin/frida-server"], server)
        || !FLMachOFile(server)) return @"发行包缺少有效的 iOS frida-server。";
    if (chmod(server.fileSystemRepresentation, 0755) != 0) return @"无法设置服务端权限。";

    for (NSString *folder in @[@"frida-1.0", @"frida"]) {
        NSString *relative = [NSString stringWithFormat:@"usr/lib/%@/frida-agent.dylib", folder];
        NSString *agent = [stage stringByAppendingPathComponent:relative];
        if (![files createDirectoryAtPath:agent.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL]) {
            return @"无法创建运行时目录。";
        }
        if (FLExtract(@"/usr/bin/tar", @[@"-xOf", tar, [@"./var/jb/" stringByAppendingString:relative]], agent)
            && FLMachOFile(agent) && chmod(agent.fileSystemRepresentation, 0755) == 0) {
            [files removeItemAtPath:tar error:NULL];
            [files removeItemAtPath:package error:NULL];
            return nil;
        }
        [files removeItemAtPath:agent.stringByDeletingLastPathComponent error:NULL];
    }
    return @"发行包缺少有效的 iOS Frida Agent。";
}

NSString *FLInstallRelease(NSString *version, NSString *checksum) {
    if (!FLReleaseMajor(version)) return @"Frida 版本号无效。";
    if ([FLInstalledReleases() containsObject:version]) return nil;
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *root = FLPath(FLReleasesDirectory);
    NSError *error = nil;
    if (![files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:@{ NSFilePosixPermissions: @0755 } error:&error]) {
        return error.localizedDescription;
    }
    NSString *template = [root stringByAppendingPathComponent:@".download.XXXXXXXX"];
    char *buffer = strdup(template.fileSystemRepresentation);
    if (!buffer) return @"无法创建下载临时目录。";
    char *directory = mkdtemp(buffer);
    NSString *stage = directory ? [files stringWithFileSystemRepresentation:directory length:strlen(directory)] : nil;
    free(buffer);
    if (!stage) return @"无法创建下载临时目录。";

    NSString *package = [stage stringByAppendingPathComponent:@"release.deb"];
    NSString *failure = FLDownloadArchive(version, package);
    if (!failure) FLValidateDownload();
    NSString *expected = [version isEqualToString:@"16.7.19"]
        ? @"sha256:e6d583347af0cc8b137126fe5f5c9dbadfc51bb423261ac73d2ea89c1b3fa1db" : checksum;
    if (!failure && expected && ![FLArchiveDigest(package) isEqualToString:expected.lowercaseString]) {
        failure = @"下载的软件包与 GitHub 提供的 SHA-256 不符。";
    }
    if (!failure) failure = FLExtractRelease(package, stage);
    if (!failure && chmod(stage.fileSystemRepresentation, 0755) != 0) failure = @"无法设置发行目录权限。";
    if (!failure && ![files moveItemAtPath:stage toPath:[root stringByAppendingPathComponent:version] error:&error]) {
        failure = error.localizedDescription;
    }
    if (failure) [files removeItemAtPath:stage error:NULL];
    FLTrackDownload(nil, nil);
    return failure;
}
