#import "TerminalLog.h"

static UIColor *FLRGB(NSUInteger red, NSUInteger green, NSUInteger blue) {
    return [UIColor colorWithRed:red / 255.0 green:green / 255.0 blue:blue / 255.0 alpha:1];
}

static UIColor *FLPaletteColor(NSUInteger index) {
    static const NSUInteger palette[] = {
        0x000000, 0xCD3131, 0x059669, 0xB58900, 0x2472C8, 0xBC3FBC, 0x0D8EA5, 0xE5E5E5,
        0x666666, 0xF05252, 0x23D18B, 0xF5C542, 0x438DFF, 0xD670D6, 0x29B8DB, 0xFFFFFF,
    };
    if (index < 16) {
        NSUInteger color = palette[index];
        return FLRGB(color >> 16, (color >> 8) & 0xFF, color & 0xFF);
    }
    if (index < 232) {
        static const NSUInteger levels[] = {0, 95, 135, 175, 215, 255};
        NSUInteger cube = index - 16;
        return FLRGB(levels[cube / 36], levels[cube / 6 % 6], levels[cube % 6]);
    }
    NSUInteger gray = 8 + (index - 232) * 10;
    return FLRGB(gray, gray, gray);
}

static BOOL FLReadColorByte(NSString *text, NSUInteger *value) {
    NSInteger number = text.integerValue;
    if (!text.length || number < 0 || number > 255) return NO;
    *value = (NSUInteger)number;
    return YES;
}

static UIColor *FLExtendedColor(NSInteger mode, NSArray<NSString *> *bytes) {
    NSUInteger red, green, blue;
    if (mode == 5 && bytes.count == 1 && FLReadColorByte(bytes[0], &red)) return FLPaletteColor(red);
    if (mode == 2 && bytes.count == 3 && FLReadColorByte(bytes[0], &red)
        && FLReadColorByte(bytes[1], &green) && FLReadColorByte(bytes[2], &blue)) {
        return FLRGB(red, green, blue);
    }
    return nil;
}

static UIColor *FLReadExtendedColor(NSArray<NSString *> *parameters, NSArray<NSString *> *parts, NSUInteger *index) {
    if (parts.count > 1) {
        NSInteger mode = parts[1].integerValue;
        // The colon form may include a color-space field before the RGB components.
        NSUInteger first = (mode == 2 && parts.count == 6) ? 3 : 2;
        return FLExtendedColor(mode, [parts subarrayWithRange:NSMakeRange(first, parts.count - first)]);
    }
    if (*index + 1 >= parameters.count) return nil;
    *index += 1;
    NSInteger mode = parameters[*index].integerValue;
    NSUInteger count = mode == 5 ? 1 : (mode == 2 ? 3 : 0);
    NSUInteger available = MIN(count, parameters.count - *index - 1);
    NSArray *bytes = [parameters subarrayWithRange:NSMakeRange(*index + 1, available)];
    *index += available;
    return FLExtendedColor(mode, bytes);
}

@interface FLTerminalColors : NSObject
@property (nonatomic, strong) UIColor *foreground;
@property (nonatomic, strong) UIColor *background;
@property (nonatomic) BOOL reversed;
- (void)applyParameters:(NSString *)sgr;
@end

@implementation FLTerminalColors
- (void)applyParameters:(NSString *)sgr {
    NSArray<NSString *> *parameters = [sgr componentsSeparatedByString:@";"];
    for (NSUInteger index = 0; index < parameters.count; index++) {
        NSArray<NSString *> *parts = [parameters[index] componentsSeparatedByString:@":"];
        NSInteger code = parts.firstObject.integerValue;
        if (code == 38 || code == 48) {
            UIColor *color = FLReadExtendedColor(parameters, parts, &index);
            if (color && code == 38) self.foreground = color;
            if (color && code == 48) self.background = color;
        } else if (code == 0) {
            self.foreground = nil;
            self.background = nil;
            self.reversed = NO;
        } else if (code == 7 || code == 27) {
            self.reversed = code == 7;
        } else if (code == 39) {
            self.foreground = nil;
        } else if (code == 49) {
            self.background = nil;
        } else if (code >= 30 && code <= 37) {
            self.foreground = FLPaletteColor(code - 30);
        } else if (code >= 90 && code <= 97) {
            self.foreground = FLPaletteColor(code - 90 + 8);
        } else if (code >= 40 && code <= 47) {
            self.background = FLPaletteColor(code - 40);
        } else if (code >= 100 && code <= 107) {
            self.background = FLPaletteColor(code - 100 + 8);
        }
    }
}
@end

static void FLAppendLogRun(NSMutableAttributedString *result, NSString *text, NSRange range,
                           NSDictionary *attributes, UIColor *defaultBackground, FLTerminalColors *colors) {
    if (!range.length) return;
    NSMutableDictionary *styled = [attributes mutableCopy];
    if (colors.reversed) {
        styled[NSForegroundColorAttributeName] = colors.background ?: defaultBackground;
        styled[NSBackgroundColorAttributeName] = colors.foreground ?: attributes[NSForegroundColorAttributeName] ?: UIColor.labelColor;
    } else {
        if (colors.foreground) styled[NSForegroundColorAttributeName] = colors.foreground;
        if (colors.background) styled[NSBackgroundColorAttributeName] = colors.background;
    }
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:[text substringWithRange:range] attributes:styled]];
}

NSAttributedString *FLColorizedLog(NSString *text, NSDictionary<NSAttributedStringKey, id> *attributes,
                                 UIColor *defaultBackground) {
    static NSRegularExpression *sgrPattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sgrPattern = [NSRegularExpression regularExpressionWithPattern:@"(?:\\x{001B}\\[|\\x{009B})([0-9;:]*)m"
                                                               options:0 error:nil];
    });
    NSArray<NSTextCheckingResult *> *matches = [sgrPattern matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!matches.count) return [[NSAttributedString alloc] initWithString:text attributes:attributes];

    FLTerminalColors *colors = [FLTerminalColors new];
    NSMutableAttributedString *result = [NSMutableAttributedString new];
    NSUInteger offset = 0;
    for (NSTextCheckingResult *match in matches) {
        FLAppendLogRun(result, text, NSMakeRange(offset, match.range.location - offset), attributes, defaultBackground, colors);
        [colors applyParameters:[text substringWithRange:[match rangeAtIndex:1]]];
        offset = NSMaxRange(match.range);
    }
    FLAppendLogRun(result, text, NSMakeRange(offset, text.length - offset), attributes, defaultBackground, colors);
    return result;
}
