#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString *FLPath(NSString *path);
BOOL FLProcessMatches(pid_t pid, NSString *executable);
NSInteger FLReapManagedOrphans(void);
NSInteger FLSelectedProtocolMajor(void);

@interface FLRuntime : NSObject
- (NSDictionary *)status;
- (NSDictionary *)consoleAfter:(NSInteger)cursor;
- (NSDictionary *)scriptOverlayAfter:(NSInteger)cursor session:(nullable NSString *)sessionID;
- (nullable NSString *)stopOverlaySession:(NSString *)sessionID;
- (nullable NSString *)startServer;
- (nullable NSString *)stopServer;
- (nullable NSString *)updateAddress:(NSString *)address port:(NSInteger)port;
- (nullable NSString *)updateOverlayTransparency:(double)transparency;
- (nullable NSString *)installVersion:(NSString *)version checksum:(nullable NSString *)checksum;
- (nullable NSString *)selectVersion:(NSString *)version replacing:(NSString *)previous restart:(BOOL)restart;
- (nullable NSString *)stopForVersionChange;
- (nullable NSArray *)listTargetsForSpawn:(BOOL)spawn failure:(NSString * _Nullable * _Nonnull)failure;
- (nullable NSString *)runScript:(NSString *)source name:(NSString *)name
                          bundle:(nullable NSString *)bundle pid:(NSInteger)pid spawn:(BOOL)spawn
                           owner:(NSUUID *)owner;
- (nullable NSString *)stopSession;
- (void)clientDisconnected:(NSUUID *)client;
@end

NS_ASSUME_NONNULL_END
