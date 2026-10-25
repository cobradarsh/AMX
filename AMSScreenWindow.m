#import "AMSScreenWindow.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kReelSize = 96;

static UIView *AMSReelView(void) {
    UIView *v = [UIView new];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [v.widthAnchor constraintEqualToConstant:kReelSize].active = YES;
    [v.heightAnchor constraintEqualToConstant:kReelSize].active = YES;

    CGPoint c = CGPointMake(kReelSize / 2, kReelSize / 2);
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(4, 4, kReelSize - 8, kReelSize - 8)].CGPath;
    ring.fillColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    ring.strokeColor = [UIColor colorWithWhite:1 alpha:0.75].CGColor;
    ring.lineWidth = 8;
    [v.layer addSublayer:ring];

    UIBezierPath *hub = [UIBezierPath bezierPathWithArcCenter:c radius:24 startAngle:0 endAngle:2 * M_PI clockwise:YES];
    for (int i = 0; i < 6; i++) {
        double a = i * M_PI / 3;
        [hub moveToPoint:CGPointMake(c.x + 14 * cos(a), c.y + 14 * sin(a))];
        [hub addLineToPoint:CGPointMake(c.x + 24 * cos(a), c.y + 24 * sin(a))];
    }
    CAShapeLayer *hubLayer = [CAShapeLayer layer];
    hubLayer.path = hub.CGPath;
    hubLayer.fillColor = [UIColor colorWithWhite:0.3 alpha:1].CGColor;
    hubLayer.strokeColor = [UIColor colorWithWhite:0.05 alpha:1].CGColor;
    hubLayer.lineWidth = 3;
    [v.layer addSublayer:hubLayer];
    return v;
}

static UIButton *AMSRoundButton(UIColor *bg, NSString *symbol, CGFloat size) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.backgroundColor = bg;
    b.layer.cornerRadius = size / 2;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:size * 0.4 weight:UIImageSymbolWeightSemibold];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    b.tintColor = UIColor.whiteColor;
    [b.widthAnchor constraintEqualToConstant:size].active = YES;
    [b.heightAnchor constraintEqualToConstant:size].active = YES;
    return b;
}

static UILabel *AMSLabel(CGFloat size, CGFloat alpha) {
    UILabel *l = [UILabel new];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.font = [UIFont systemFontOfSize:size];
    l.textColor = [UIColor colorWithWhite:1 alpha:alpha];
    l.textAlignment = NSTextAlignmentCenter;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.6;
    return l;
}

static UIStackView *AMSCaptioned(UIView *control, UILabel *caption) {
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[ control, caption ]];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    s.axis = UILayoutConstraintAxisVertical;
    s.alignment = UIStackViewAlignmentCenter;
    s.spacing = 10;
    return s;
}

@implementation AMSScreenViewController {
    UILabel *_nameLabel;
    UILabel *_statusLabel;
    UILabel *_listenCaption;
    UIView *_leftReel;
    UIView *_rightReel;
}

- (void)loadView {
    UIView *root = [UIView new];
    root.backgroundColor = UIColor.clearColor;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blur.frame = root.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:blur];
    UILayoutGuide *safe = root.safeAreaLayoutGuide;

    UIButton *hide = [UIButton buttonWithType:UIButtonTypeSystem];
    hide.translatesAutoresizingMaskIntoConstraints = NO;
    [hide setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];
    hide.tintColor = [UIColor colorWithWhite:1 alpha:0.8];
    [hide addTarget:self action:@selector(hideTapped) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:hide];

    UILabel *title = AMSLabel(26, 0.85);
    title.text = @"Answering Machine";
    [root addSubview:title];

    UIView *line = [UIView new];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
    [root addSubview:line];

    _leftReel = AMSReelView();
    _rightReel = AMSReelView();
    UIStackView *reels = [[UIStackView alloc] initWithArrangedSubviews:@[ _leftReel, _rightReel ]];
    reels.translatesAutoresizingMaskIntoConstraints = NO;
    reels.spacing = 64;
    [root addSubview:reels];

    _nameLabel = AMSLabel(28, 1);
    [root addSubview:_nameLabel];
    _statusLabel = AMSLabel(17, 0.8);
    _statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightRegular];
    [root addSubview:_statusLabel];

    _listenButton = AMSRoundButton([UIColor colorWithWhite:1 alpha:0.15], @"speaker.wave.3.fill", 72);
    [_listenButton addTarget:self action:@selector(listenTapped:) forControlEvents:UIControlEventTouchUpInside];
    _listenCaption = AMSLabel(15, 0.9);
    UIStackView *listen = AMSCaptioned(_listenButton, _listenCaption);
    [root addSubview:listen];

    UIButton *hangUp = AMSRoundButton([UIColor colorWithRed:1 green:0.23 blue:0.19 alpha:1], @"phone.down.fill", 76);
    [hangUp addTarget:self action:@selector(hangUpTapped) forControlEvents:UIControlEventTouchUpInside];
    UILabel *hangUpCaption = AMSLabel(15, 0.9);
    hangUpCaption.text = @"Hang up";
    UIStackView *hangUpStack = AMSCaptioned(hangUp, hangUpCaption);

    UIButton *talk = AMSRoundButton([UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1], @"phone.fill", 76);
    [talk addTarget:self action:@selector(talkTapped) forControlEvents:UIControlEventTouchUpInside];
    UILabel *talkCaption = AMSLabel(15, 0.9);
    talkCaption.text = @"Talk";
    UIStackView *talkStack = AMSCaptioned(talk, talkCaption);

    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[ hangUpStack, talkStack ]];
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.alignment = UIStackViewAlignmentCenter;
    [root addSubview:actions];

    [NSLayoutConstraint activateConstraints:@[
        [hide.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [hide.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [hide.widthAnchor constraintEqualToConstant:44],
        [hide.heightAnchor constraintEqualToConstant:44],

        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:48],
        [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [line.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:14],
        [line.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [line.widthAnchor constraintEqualToAnchor:root.widthAnchor multiplier:0.55],
        [line.heightAnchor constraintEqualToConstant:1],

        [reels.topAnchor constraintEqualToAnchor:line.bottomAnchor constant:28],
        [reels.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],

        [_nameLabel.topAnchor constraintEqualToAnchor:reels.bottomAnchor constant:28],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [_statusLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:8],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [listen.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:48],
        [listen.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_listenCaption.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor constant:-32],

        [actions.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-36],
        [actions.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [actions.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
    ]];

    self.view = root;
    [self setListening:NO];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

- (void)setCallerName:(NSString *)name {
    [self loadViewIfNeeded];
    _nameLabel.text = name.length ? name : @"Unknown";
}

- (void)setStatus:(NSString *)status {
    [self loadViewIfNeeded];
    _statusLabel.text = status;
}

- (void)setListening:(BOOL)listening {
    [self loadViewIfNeeded];
    _listenButton.backgroundColor = listening ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.15];
    _listenButton.tintColor = listening ? UIColor.blackColor : UIColor.whiteColor;
    _listenCaption.text = listening ? @"Listening — tap to mute" : @"Listen without answering";
}

- (void)startReels {
    [self loadViewIfNeeded];
    for (UIView *reel in @[ _leftReel, _rightReel ]) {
        if ([reel.layer animationForKey:@"spin"]) continue;
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @0;
        spin.toValue = @(2 * M_PI);
        spin.duration = 4;
        spin.repeatCount = HUGE_VALF;
        spin.removedOnCompletion = NO;
        [reel.layer addAnimation:spin forKey:@"spin"];
    }
}

- (void)listenTapped:(UIButton *)sender { [self.delegate screenDidTapListen:sender]; }
- (void)hangUpTapped { [self.delegate screenDidTapHangUp]; }
- (void)talkTapped { [self.delegate screenDidTapTalk]; }
- (void)hideTapped { [self.delegate screenDidTapHide]; }

@end

@implementation AMSScreenWindow

+ (instancetype)makeWindow {
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.screen == UIScreen.mainScreen) { scene = ws; break; }
        if (!scene) scene = ws;
    }
    AMSScreenWindow *w = scene ? [[self alloc] initWithWindowScene:scene]
                               : [[self alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.frame = UIScreen.mainScreen.bounds;
    // Must sit ABOVE the lock screen (CoverSheet) AND the system's active-call
    // UI that iOS shows on the lock screen. 10000000 cleared the lock screen but
    // the native answered-call screen still layered on top, so go higher.
    w.windowLevel = (UIWindowLevel)1000000000;
    w.backgroundColor = UIColor.clearColor;
    w->_screenController = [AMSScreenViewController new];
    w.rootViewController = w->_screenController;
    return w;
}

// Secure windows stay visible while the device is locked.
+ (BOOL)_isSecure { return YES; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }

@end
