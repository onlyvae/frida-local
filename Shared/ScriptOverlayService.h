#import <Foundation/Foundation.h>

#define FLScriptOverlayChanged "dev.fridalocal.script-overlay.changed"
#define FLScriptOverlaySettingsChanged "dev.fridalocal.script-overlay.settings-changed"
#define FLOverlayTransparencyKey @"overlayTransparency"
#define FLMaximumOverlayTransparency 0.8

NS_ASSUME_NONNULL_BEGIN

typedef void (^FLOverlayReply)(NSData * _Nullable, NSString * _Nullable);

@protocol FLScriptOverlayService
- (void)scriptOverlayAfter:(NSInteger)cursor session:(nullable NSString *)sessionID withReply:(FLOverlayReply)reply;
- (void)stopOverlaySession:(NSString *)sessionID withReply:(FLOverlayReply)reply;
@end

NS_ASSUME_NONNULL_END
