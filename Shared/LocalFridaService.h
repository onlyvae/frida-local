#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol LocalFridaService
- (void)statusWithReply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
    NS_SWIFT_NAME(status(reply:));
- (void)startServerWithReply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
    NS_SWIFT_NAME(startServer(reply:));
- (void)stopServerWithReply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
    NS_SWIFT_NAME(stopServer(reply:));
- (void)updateAddress:(NSString *)address port:(NSInteger)port withReply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
    NS_SWIFT_NAME(updateAddress(_:port:reply:));
- (void)installVersion:(NSString *)version checksum:(NSString * _Nullable)checksum
             withReply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
    NS_SWIFT_NAME(installVersion(_:checksum:reply:));
- (void)downloadProgressForVersion:(NSString *)version withReply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
    NS_SWIFT_NAME(downloadProgress(for:reply:));
- (void)selectVersion:(NSString *)version replacing:(NSString *)previous restart:(BOOL)restart
             withReply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
    NS_SWIFT_NAME(selectVersion(_:replacing:restart:reply:));
- (void)stopForVersionChangeWithReply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
    NS_SWIFT_NAME(stopForVersionChange(reply:));
- (void)listTargetsForSpawn:(BOOL)spawn withReply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
    NS_SWIFT_NAME(listTargets(spawn:reply:));
- (void)runScript:(NSString *)source name:(NSString *)name bundle:(NSString * _Nullable)bundle pid:(NSInteger)pid
    spawn:(BOOL)spawn withReply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
    NS_SWIFT_NAME(runScript(_:name:bundle:pid:spawn:reply:));
- (void)stopSessionWithReply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
    NS_SWIFT_NAME(stopSession(reply:));
- (void)consoleAfter:(NSInteger)cursor withReply:(void (^)(NSData * _Nullable, NSString * _Nullable))reply
    NS_SWIFT_NAME(console(after:reply:));
@end

NS_ASSUME_NONNULL_END

NSXPCConnection * _Nullable FLCreateServiceConnection(NSInteger major);
NSXPCListener * _Nullable FLCreateServiceListener(NSInteger major);
