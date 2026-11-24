#import <UIKit/UIKit.h>
#import "../Shared/LocalFridaService.h"

@interface UIImage (FLInstalledApplicationIcon)
+ (UIImage * _Nullable)_applicationIconImageForBundleIdentifier:(NSString * _Nonnull)bundleID
                                                         format:(NSInteger)format
                                                          scale:(CGFloat)scale;
@end

NS_INLINE UIImage * _Nullable FLInstalledApplicationIcon(NSString * _Nonnull bundleID, CGFloat scale) {
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    NSInteger format = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 8 : 10;
    return [UIImage _applicationIconImageForBundleIdentifier:bundleID format:format scale:scale];
}
