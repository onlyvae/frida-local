#import <UIKit/UIKit.h>
#import <notify.h>
#import <roothide.h>
#import "../Shared/LocalFridaService.h"
#import "../Shared/ScriptOverlayService.h"
#import "../Shared/TerminalLog.h"

static NSString *const FLOverlayPositionKey = @"dev.fridalocal.script-overlay.position";
static NSString *const FLOverlayHeaderPositionKey = @"dev.fridalocal.script-overlay.headerPosition";
static NSString *const FLOverlayLogModeKey = @"dev.fridalocal.script-overlay.logMode";
static const CGFloat FLHeaderHeight = 44;
static const CGFloat FLSingleLineHeight = 28;

@protocol FLIdleTimerAssertion <NSObject>
- (void)invalidate;
@end

@interface SBIdleTimerGlobalCoordinator : NSObject
+ (instancetype)sharedInstance;
- (id<FLIdleTimerAssertion>)acquireIdleTimerDisableAssertionForReason:(NSString *)reason;
@end

typedef NS_ENUM(NSInteger, FLOverlayLogMode) {
    FLOverlayLogExpanded,
    FLOverlayLogSingleLine,
    FLOverlayLogHidden,
};

@interface FLOverlayMarquee : UIView
- (void)setLine:(NSAttributedString *)line;
@end

@implementation FLOverlayMarquee {
    UILabel *_label;
    CGSize _animatedSize;
    BOOL _lineChanged;
}

- (instancetype)init {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.clipsToBounds = YES;
    self.userInteractionEnabled = NO;
    _label = [UILabel new];
    _label.lineBreakMode = NSLineBreakByClipping;
    [self addSubview:_label];
    return self;
}

- (void)setLine:(NSAttributedString *)line {
    NSMutableAttributedString *singleLine = [line mutableCopy];
    NSRange search = NSMakeRange(0, singleLine.length);
    NSCharacterSet *lineBreaks = NSCharacterSet.newlineCharacterSet;
    while (search.length) {
        NSRange newline = [singleLine.string rangeOfCharacterFromSet:lineBreaks options:0 range:search];
        if (newline.location == NSNotFound) break;
        [singleLine replaceCharactersInRange:newline withString:@" "];
        NSUInteger next = newline.location + 1;
        search = NSMakeRange(next, singleLine.length - next);
    }
    if (_label.attributedText == singleLine || [_label.attributedText isEqualToAttributedString:singleLine]) return;
    _label.attributedText = singleLine;
    _lineChanged = YES;
    [self setNeedsLayout];
}

- (void)setHidden:(BOOL)hidden {
    if (self.hidden == hidden) return;
    [super setHidden:hidden];
    if (hidden) {
        [_label.layer removeAnimationForKey:@"marquee"];
    } else {
        _lineChanged = YES;
        [self setNeedsLayout];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.hidden || CGRectIsEmpty(self.bounds)) return;
    CGSize size = self.bounds.size;
    if (!_lineChanged && CGSizeEqualToSize(size, _animatedSize)) return;
    _animatedSize = size;
    _lineChanged = NO;
    [_label.layer removeAnimationForKey:@"marquee"];

    const CGFloat padding = 8;
    CGFloat textWidth = ceil(_label.attributedText.size.width) + 1;
    _label.frame = CGRectMake(padding, 0, textWidth, CGRectGetHeight(self.bounds));
    CGFloat overflow = textWidth + 2 * padding - CGRectGetWidth(self.bounds);
    if (overflow <= 0) return;

    CFTimeInterval scrollTime = overflow / 38;
    const CFTimeInterval startPause = 0.3;
    CFTimeInterval duration = startPause + scrollTime + 0.8;
    CAKeyframeAnimation *scroll = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    scroll.values = @[@0, @0, @(-overflow), @(-overflow)];
    scroll.keyTimes = @[@0, @(startPause / duration), @((startPause + scrollTime) / duration), @1];
    scroll.duration = duration;
    scroll.repeatCount = HUGE_VALF;
    [_label.layer addAnimation:scroll forKey:@"marquee"];
}
@end

@interface FLOverlayWindow : UIWindow
@end

@implementation FLOverlayWindow
- (BOOL)canBecomeKeyWindow { return NO; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *target = [super hitTest:point withEvent:event];
    return target == self || target == self.rootViewController.view ? nil : target;
}
@end

@interface FLOverlayViewController : UIViewController
- (void)setScriptName:(NSString *)name;
- (void)showElapsedSince:(NSTimeInterval)startUptime;
- (void)appendEntries:(NSArray<NSDictionary *> *)entries;
- (void)showStopError:(NSString *)error;
- (void)setTransparency:(CGFloat)transparency;
- (void)setSessionVisible:(BOOL)visible;
@property (nonatomic, copy) void (^onStop)(void);
@property (nonatomic, getter=isStopping) BOOL stopping;
@end

@implementation FLOverlayViewController {
    UIView *_panel;
    UILabel *_name;
    UILabel *_elapsed;
    UIButton *_stop;
    UIButton *_collapse;
    UIStackView *_header;
    UITextView *_output;
    FLOverlayMarquee *_singleLine;
    NSMutableAttributedString *_logText;
    NSAttributedString *_latestLine;
    FLOverlayLogMode _logMode;
    BOOL _sessionVisible;
    NSMutableArray<NSNumber *> *_entryLengths;
    UIPanGestureRecognizer *_pan;
    CGPoint _dragStart;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    _panel = [UIView new];
    _panel.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _panel.layer.cornerRadius = 13;
    _panel.clipsToBounds = YES;
    [self.view addSubview:_panel];

    _name = [UILabel new];
    _name.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _name.textColor = UIColor.whiteColor;
    _name.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_name setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    _elapsed = [UILabel new];
    _elapsed.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    _elapsed.textColor = UIColor.secondaryLabelColor;
    [_elapsed setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *dragArea = [[UIStackView alloc] initWithArrangedSubviews:@[_name, _elapsed]];
    dragArea.alignment = UIStackViewAlignmentCenter;
    dragArea.spacing = 8;
    UIImage *icon = [UIImage imageWithContentsOfFile:jbroot(@"/Applications/FridaLocal.app/AppIcon20x20@3x.png")];
    if (icon) {
        UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        iconView.layer.cornerRadius = 4;
        iconView.clipsToBounds = YES;
        [dragArea insertArrangedSubview:iconView atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [iconView.widthAnchor constraintEqualToConstant:20],
            [iconView.heightAnchor constraintEqualToConstant:20],
        ]];
    }
    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    _pan.maximumNumberOfTouches = 1;
    [dragArea addGestureRecognizer:_pan];

    _stop = [UIButton buttonWithType:UIButtonTypeSystem];
    _stop.tintColor = UIColor.systemRedColor;
    _stop.accessibilityLabel = @"停止脚本";
    [_stop setImage:[UIImage systemImageNamed:@"stop.fill"] forState:UIControlStateNormal];
    [_stop addTarget:self action:@selector(stop) forControlEvents:UIControlEventTouchUpInside];

    _collapse = [UIButton buttonWithType:UIButtonTypeSystem];
    _collapse.tintColor = UIColor.secondaryLabelColor;
    [_collapse addTarget:self action:@selector(cycleLogMode) forControlEvents:UIControlEventTouchUpInside];

    _header = [[UIStackView alloc] initWithArrangedSubviews:@[dragArea, _collapse, _stop]];
    _header.translatesAutoresizingMaskIntoConstraints = NO;
    _header.layoutMarginsRelativeArrangement = YES;
    _header.insetsLayoutMarginsFromSafeArea = NO;
    _header.layoutMargins = UIEdgeInsetsMake(0, 12, 0, 0);
    [_panel addSubview:_header];

    if (@available(iOS 16, *)) {
        _output = [UITextView textViewUsingTextLayoutManager:NO];
    } else {
        _output = [UITextView new];
    }
    _output.translatesAutoresizingMaskIntoConstraints = NO;
    _output.opaque = NO;
    _output.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    _output.editable = NO;
    _output.selectable = NO;
    _output.accessibilityLabel = @"脚本日志";
    _output.showsHorizontalScrollIndicator = NO;
    _logText = [NSMutableAttributedString new];
    _entryLengths = [NSMutableArray new];
    [_panel addSubview:_output];

    _singleLine = [FLOverlayMarquee new];
    _singleLine.translatesAutoresizingMaskIntoConstraints = NO;
    [_panel addSubview:_singleLine];
    [NSLayoutConstraint activateConstraints:@[
        [_header.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor],
        [_header.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor],
        [_header.topAnchor constraintEqualToAnchor:_panel.topAnchor],
        [_header.heightAnchor constraintEqualToConstant:FLHeaderHeight],
        [_collapse.widthAnchor constraintEqualToConstant:FLHeaderHeight],
        [_stop.widthAnchor constraintEqualToConstant:FLHeaderHeight],
        [_output.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor],
        [_output.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor],
        [_output.topAnchor constraintEqualToAnchor:_header.bottomAnchor],
        [_output.bottomAnchor constraintEqualToAnchor:_panel.bottomAnchor],
        [_singleLine.leadingAnchor constraintEqualToAnchor:_output.leadingAnchor],
        [_singleLine.trailingAnchor constraintEqualToAnchor:_output.trailingAnchor],
        [_singleLine.topAnchor constraintEqualToAnchor:_output.topAnchor],
        [_singleLine.bottomAnchor constraintEqualToAnchor:_output.bottomAnchor],
    ]];
    NSInteger savedMode = [NSUserDefaults.standardUserDefaults integerForKey:FLOverlayLogModeKey];
    _logMode = (savedMode >= FLOverlayLogExpanded && savedMode <= FLOverlayLogHidden) ? savedMode : FLOverlayLogExpanded;
    [self updateLogMode];
    [self setTransparency:0];
}

- (void)setScriptName:(NSString *)name {
    [self loadViewIfNeeded];
    _name.text = name;
    [_logText deleteCharactersInRange:NSMakeRange(0, _logText.length)];
    _output.attributedText = nil;
    [_entryLengths removeAllObjects];
    [_output setContentOffset:CGPointZero animated:NO];
    _latestLine = nil;
    [_singleLine setLine:nil];
}

- (void)showElapsedSince:(NSTimeInterval)startUptime {
    NSInteger seconds = (NSInteger)MAX(0, NSProcessInfo.processInfo.systemUptime - startUptime);
    _elapsed.text = seconds < 3600
        ? [NSString stringWithFormat:@"%02ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)]
        : [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(seconds / 3600), (long)(seconds / 60 % 60), (long)(seconds % 60)];
    _elapsed.accessibilityLabel = [@"运行时间 " stringByAppendingString:_elapsed.text];
}

- (void)appendEntries:(NSArray<NSDictionary *> *)entries {
    if (!entries.count) return;
    [self.view layoutIfNeeded];
    BOOL follow = _logMode == FLOverlayLogExpanded
        && _output.contentOffset.y + CGRectGetHeight(_output.bounds) >= _output.contentSize.height - 16
        && !_output.dragging && !_output.decelerating;
    CGPoint previousOffset = _output.contentOffset;
    for (NSDictionary *entry in entries) {
        UIColor *color = [entry[@"kind"] isEqualToString:@"error"] ? UIColor.systemRedColor : UIColor.whiteColor;
        NSDictionary *attributes = @{
            NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular],
            NSForegroundColorAttributeName: color
        };
        NSAttributedString *line = FLColorizedLog(entry[@"text"], attributes, UIColor.blackColor);
        [_logText appendAttributedString:line];
        [_logText appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:attributes]];
        [_entryLengths addObject:@(line.length + 1)];
        if (line.length) _latestLine = line;
    }
    NSUInteger removed = 0;
    while (_entryLengths.count > 180) {
        removed += _entryLengths.firstObject.unsignedIntegerValue;
        [_entryLengths removeObjectAtIndex:0];
    }
    if (removed) [_logText deleteCharactersInRange:NSMakeRange(0, removed)];
    if (_logMode == FLOverlayLogExpanded) {
        _output.attributedText = _logText;
        if (follow) [self scrollToLatest];
        else [_output setContentOffset:previousOffset animated:NO];
    } else if (_logMode == FLOverlayLogSingleLine) {
        [_singleLine setLine:_latestLine];
    }
}

- (void)scrollToLatest {
    [_output.layoutManager ensureLayoutForTextContainer:_output.textContainer];
    [_output layoutIfNeeded];
    CGFloat bottom = MAX(0, _output.contentSize.height - CGRectGetHeight(_output.bounds));
    [_output setContentOffset:CGPointMake(0, bottom) animated:NO];
}

- (void)cycleLogMode {
    _logMode = _logMode == FLOverlayLogHidden ? FLOverlayLogExpanded : _logMode + 1;
    [NSUserDefaults.standardUserDefaults setInteger:_logMode forKey:FLOverlayLogModeKey];
    [self updateLogMode];
    [self.view setNeedsLayout];
    if (_logMode == FLOverlayLogExpanded) {
        _output.attributedText = _logText;
        [self.view layoutIfNeeded];
        [self scrollToLatest];
    }
}

- (void)updateLogMode {
    _output.hidden = _logMode != FLOverlayLogExpanded;
    _singleLine.hidden = !_sessionVisible || _logMode != FLOverlayLogSingleLine;
    switch (_logMode) {
        case FLOverlayLogExpanded:
            [_collapse setImage:[UIImage systemImageNamed:@"chevron.up"] forState:UIControlStateNormal];
            _collapse.accessibilityLabel = @"切换为单行日志";
            break;
        case FLOverlayLogSingleLine:
            [_singleLine setLine:_latestLine];
            [_collapse setImage:[UIImage systemImageNamed:@"minus"] forState:UIControlStateNormal];
            _collapse.accessibilityLabel = @"隐藏日志";
            break;
        case FLOverlayLogHidden:
            [_collapse setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];
            _collapse.accessibilityLabel = @"展开日志";
            break;
    }
}

- (void)setTransparency:(CGFloat)transparency {
    CGFloat opacity = 1 - transparency;
    _header.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.94 * opacity];
    UIColor *logBackground = [UIColor colorWithWhite:0.05 alpha:0.985 * opacity];
    _output.backgroundColor = logBackground;
    _singleLine.backgroundColor = logBackground;
}

- (void)setSessionVisible:(BOOL)visible {
    _sessionVisible = visible;
    _singleLine.hidden = !visible || _logMode != FLOverlayLogSingleLine;
}

- (void)stop {
    if (!_stopping && self.onStop) self.onStop();
}

- (void)setStopping:(BOOL)stopping {
    _stopping = stopping;
    _stop.enabled = !stopping;
}

- (void)showStopError:(NSString *)error {
    [self appendEntries:@[@{ @"kind": @"error", @"text": error }]];
}

- (CGRect)placementArea {
    CGRect safe = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    return CGRectInset(safe, 10, 10);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect area = [self placementArea];
    if (CGRectIsEmpty(area)) return;
    CGFloat width = MIN(320, CGRectGetWidth(area) * 0.88);
    CGFloat expanded = MIN(192, MAX(FLHeaderHeight, CGRectGetHeight(area) * 0.55));
    CGFloat height = expanded;
    if (_logMode == FLOverlayLogHidden) height = FLHeaderHeight;
    if (_logMode == FLOverlayLogSingleLine) height = FLHeaderHeight + FLSingleLineHeight;
    height = MIN(height, CGRectGetHeight(area));
    CGSize size = CGSizeMake(width, height);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray<NSNumber *> *position = [defaults arrayForKey:FLOverlayHeaderPositionKey];
    BOOL legacy = position.count != 2;
    if (legacy) position = [defaults arrayForKey:FLOverlayPositionKey];
    CGPoint center = CGPointMake(CGRectGetMidX(area), CGRectGetMinY(area) + height / 2);
    if (position.count == 2) {
        CGFloat anchorHeight = legacy ? expanded : FLHeaderHeight;
        center = CGPointMake(CGRectGetMinX(area) + position[0].doubleValue * CGRectGetWidth(area),
                             CGRectGetMinY(area) + position[1].doubleValue * CGRectGetHeight(area)
                             + (height - anchorHeight) / 2);
    }
    if (_pan.state == UIGestureRecognizerStateBegan || _pan.state == UIGestureRecognizerStateChanged) {
        CGPoint delta = [_pan translationInView:self.view];
        center = CGPointMake(_dragStart.x + delta.x, _dragStart.y + delta.y);
    }
    [self placePanelAt:center size:size inArea:area];
}

- (void)placePanelAt:(CGPoint)center size:(CGSize)size inArea:(CGRect)area {
    CGFloat x = MIN(MAX(center.x - size.width / 2, CGRectGetMinX(area)), CGRectGetMaxX(area) - size.width);
    CGFloat y = MIN(MAX(center.y - size.height / 2, CGRectGetMinY(area)), CGRectGetMaxY(area) - size.height);
    _panel.frame = CGRectMake(x, y, size.width, size.height);
}

- (void)drag:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) _dragStart = _panel.center;
    CGRect area = [self placementArea];
    if (pan.state == UIGestureRecognizerStateEnded && !CGRectIsEmpty(area)) {
        CGPoint delta = [pan translationInView:self.view];
        [self placePanelAt:CGPointMake(_dragStart.x + delta.x, _dragStart.y + delta.y) size:_panel.bounds.size inArea:area];
        CGPoint center = _panel.center;
        [NSUserDefaults.standardUserDefaults setObject:@[
            @((center.x - CGRectGetMinX(area)) / CGRectGetWidth(area)),
            @((CGRectGetMinY(_panel.frame) + FLHeaderHeight / 2 - CGRectGetMinY(area)) / CGRectGetHeight(area))
        ] forKey:FLOverlayHeaderPositionKey];
    }
    [self.view setNeedsLayout];
}
@end

@interface FLScriptOverlay : NSObject
- (void)start;
@end

@implementation FLScriptOverlay {
    NSMutableDictionary<NSNumber *, NSXPCConnection *> *_connections;
    FLOverlayWindow *_window;
    FLOverlayViewController *_controller;
    NSTimer *_timer;
    NSNumber *_major;
    NSString *_sessionID;
    id<FLIdleTimerAssertion> _idleTimerAssertion;
    NSTimeInterval _startUptime;
    NSInteger _cursor;
    BOOL _fetching;
    BOOL _needsDiscovery;
    BOOL _stopping;
    int _changeToken;
    int _settingsChangeToken;
}

- (void)start {
    _connections = [NSMutableDictionary new];
    notify_register_dispatch(FLScriptOverlayChanged, &_changeToken, dispatch_get_main_queue(), ^(int token) {
        [self discoverSession];
    });
    notify_register_dispatch(FLScriptOverlaySettingsChanged, &_settingsChangeToken, dispatch_get_main_queue(), ^(int token) {
        if (self->_sessionID) [self refresh];
    });
    [self discoverSession];
}

- (id<FLScriptOverlayService>)proxyForMajor:(NSNumber *)major reply:(FLOverlayReply)reply {
    NSXPCConnection *connection = _connections[major];
    if (!connection) {
        connection = FLCreateServiceConnection(major.integerValue);
        if (!connection) {
            reply(nil, @"无法连接 Frida Local 服务。");
            return nil;
        }
        connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(FLScriptOverlayService)];
        __weak NSXPCConnection *weakConnection = connection;
        connection.invalidationHandler = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_connections[major] == weakConnection) [self->_connections removeObjectForKey:major];
            });
        };
        _connections[major] = connection;
        [connection resume];
    }
    return [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        reply(nil, error.localizedDescription);
    }];
}

- (void)discoverSession {
    _needsDiscovery = YES;
    [self refresh];
}

- (void)refresh {
    if (_sessionID && _window && !_window.hidden) [_controller showElapsedSince:_startUptime];
    if (_fetching || _stopping) return;
    BOOL discovering = _needsDiscovery || !_major;
    _needsDiscovery = NO;
    _fetching = YES;
    NSArray<NSNumber *> *majors = discovering ? @[@17, @16] : @[_major];
    dispatch_group_t pending = dispatch_group_create();
    __block NSDictionary *snapshot;
    __block NSNumber *activeMajor;
    for (NSNumber *major in majors) {
        BOOL sameService = [_major isEqual:major];
        dispatch_group_enter(pending);
        FLOverlayReply reply = ^(NSData *data, NSString *error) {
            NSDictionary *update = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (update[@"sessionID"]) {
                    snapshot = update;
                    activeMajor = major;
                }
                dispatch_group_leave(pending);
            });
        };
        id<FLScriptOverlayService> proxy = [self proxyForMajor:major reply:reply];
        [proxy scriptOverlayAfter:(sameService ? _cursor : 0) session:(sameService ? _sessionID : nil) withReply:reply];
    }
    dispatch_group_notify(pending, dispatch_get_main_queue(), ^{
        self->_fetching = NO;
        if (!self->_stopping) [self displaySnapshot:snapshot major:activeMajor];
        if (self->_needsDiscovery) [self refresh];
    });
}

- (void)displaySnapshot:(NSDictionary *)snapshot major:(NSNumber *)major {
    NSString *sessionID = snapshot[@"sessionID"];
    if (!sessionID) {
        [_idleTimerAssertion invalidate];
        _idleTimerAssertion = nil;
        [_timer invalidate];
        _timer = nil;
        _window.hidden = YES;
        [_controller setSessionVisible:NO];
        _sessionID = nil;
        _major = nil;
        _cursor = 0;
        return;
    }

    if (!_idleTimerAssertion) {
        Class coordinatorClass = NSClassFromString(@"SBIdleTimerGlobalCoordinator");
        if ([coordinatorClass respondsToSelector:@selector(sharedInstance)]) {
            SBIdleTimerGlobalCoordinator *coordinator = [coordinatorClass sharedInstance];
            if ([coordinator respondsToSelector:@selector(acquireIdleTimerDisableAssertionForReason:)]) {
                _idleTimerAssertion = [coordinator acquireIdleTimerDisableAssertionForReason:@"Frida Local session"];
            }
        }
    }

    if (![_sessionID isEqualToString:sessionID]) {
        _cursor = 0;
        [_controller setScriptName:snapshot[@"name"]];
    }
    _sessionID = sessionID;
    _major = major;
    _startUptime = [snapshot[@"startUptime"] doubleValue];

    if (!_timer) {
        _timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { [self refresh]; }];
        _timer.tolerance = 0.05;
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    }

    NSNumber *enabled = snapshot[FLOverlayEnabledKey];
    if (enabled && !enabled.boolValue) {
        _window.hidden = YES;
        [_controller setSessionVisible:NO];
        return;
    }

    if (!_controller) {
        _controller = [FLOverlayViewController new];
        __weak typeof(self) weakSelf = self;
        _controller.onStop = ^{ [weakSelf stopSession]; };
        [_controller setScriptName:snapshot[@"name"]];
    }

    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class] || ((UIWindowScene *)candidate).screen != UIScreen.mainScreen) continue;
        if (!scene || candidate.activationState == UISceneActivationStateForegroundActive) scene = (UIWindowScene *)candidate;
        if (candidate.activationState == UISceneActivationStateForegroundActive) break;
    }
    if (!_window) {
        _window = scene ? [[FLOverlayWindow alloc] initWithWindowScene:scene]
                        : [[FLOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        _window.windowLevel = UIWindowLevelAlert + 9998;
        _window.backgroundColor = UIColor.clearColor;
        _window.rootViewController = _controller;
    } else if (scene && _window.windowScene != scene) {
        _window.windowScene = scene;
    }
    _window.hidden = NO;
    [_controller setSessionVisible:YES];
    NSNumber *transparency = snapshot[FLOverlayTransparencyKey] ?: snapshot[@"transparency"];
    [_controller setTransparency:transparency.doubleValue];
    [_controller showElapsedSince:_startUptime];
    NSArray *entries = snapshot[@"entries"];
    [_controller appendEntries:entries];
    if (entries.count) _cursor = [entries.lastObject[@"id"] integerValue];
}

- (void)stopSession {
    if (_stopping || !_sessionID) return;
    _stopping = YES;
    _controller.stopping = YES;
    FLOverlayReply reply = ^(NSData *data, NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_stopping = NO;
            self->_controller.stopping = NO;
            if (error) [self->_controller showStopError:error];
            [self refresh];
        });
    };
    id<FLScriptOverlayService> proxy = [self proxyForMajor:_major reply:reply];
    [proxy stopOverlaySession:_sessionID withReply:reply];
}
@end

__attribute__((constructor))
static void FLStartScriptOverlay(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[FLScriptOverlay new] start];
    });
}
