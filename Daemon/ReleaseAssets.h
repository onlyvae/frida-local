#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const FLBundledVersion;
NSInteger FLReleaseMajor(NSString *version);
NSString *FLReleaseExecutable(NSString *version);
NSArray<NSString *> *FLInstalledReleases(void);
NSDictionary *FLReleaseDownloadProgress(NSString *version);
NSString * _Nullable FLInstallRelease(NSString *version, NSString * _Nullable checksum);

NS_ASSUME_NONNULL_END
