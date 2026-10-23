// AMScreen: brings back AnsweringMachine XS's call-screening screen on iOS 16.
//
// AnsweringMachine still auto-answers, plays the greeting and records. Its own
// AMCallWindow never appears on iOS 16 because it isn't attached to a UIWindowScene.
// We show our own window when AM auto-answers and route the buttons back to AM's
// controller (AMCenter), so AM's audio hooks keep handling mute/listen/record.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AMSScreenWindow.h"

#define AM_NOTIFY(name) "net.limneos.answeringmachine." name

@interface AMCenter : NSObject
+ (instancetype)sharedInstance;
- (BOOL)callAutoAnswered;
- (NSString *)callerName;
- (NSString *)statusString;
- (UIButton *)sneakButton;
- (void)listenToCaller:(id)sender;
- (void)takeOverCurrentCall;
- (void)declineCurrentCall;
@end

@interface TUCall : NSObject
@property (nonatomic, readonly) int status;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, getter=isOutgoing) BOOL outgoing;
@end

@interface TUCallCenter : NSObject
+ (instancetype)sharedInstance;
- (NSArray<TUCall *> *)currentCalls;
- (void)disconnectCall:(TUCall *)call;
@end

// TUCallStatus values.
enum { kCallActive = 1, kCallRinging = 4, kCallDisconnecting = 5, kCallDisconnected = 6 };

static NSString *const kLogPath = @"/var/mobile/Library/Logs/AMScreen.log";

static void AMSLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void AMSLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[AMScreen] %@", msg);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) {
        [line writeToFile:kLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    if ([fh seekToEndOfFile] > 512 * 1024) [fh truncateFileAtOffset:0];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static AMCenter *AMSCenter(void) {
    id cls = objc_getClass("AMCenter");
    return [cls respondsToSelector:@selector(sharedInstance)] ? [cls sharedInstance] : nil;
}

static TUCallCenter *AMSCallCenter(void) {
    return [(id)objc_getClass("TUCallCenter") sharedInstance];
}

static TUCall *AMSAnsweredIncomingCall(void) {
    TUCallCenter *tu = AMSCallCenter();
    for (TUCall *call in tu.currentCalls) {
        if (call.status == kCallActive && !call.isOutgoing) return call;
    }
    return nil;
}

static BOOL AMSAnyLiveCall(void) {
    TUCallCenter *tu = AMSCallCenter();
    for (TUCall *call in tu.currentCalls) {
        if (call.status != kCallDisconnecting && call.status != kCallDisconnected) return YES;
    }
    return NO;
}

static NSString *AMSString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

@interface AMSController : NSObject <AMSScreenDelegate>
@property (nonatomic, strong) AMSScreenWindow *window;
@property (nonatomic, strong) NSTimer *ticker;
@property (nonatomic, strong) NSDate *answeredAt;
@property (nonatomic) BOOL armed;          // AM auto-answered the current call
@property (nonatomic) BOOL greetingDone;
@property (nonatomic) BOOL listening;
@property (nonatomic) BOOL hiddenByUser;   // chevron tapped; re-show via AM's status bar tap
@property (nonatomic) BOOL handedOff;      // Talk/Hang up tapped; never re-show for this call
+ (instancetype)shared;
- (void)evaluate;
@end

@implementation AMSController

+ (instancetype)shared {
    static AMSController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (void)callWasAutoAnswered {
    AMSLog(@"auto-answer detected");
    self.armed = YES;
    if (!self.answeredAt) self.answeredAt = [NSDate date];
    // Give TUCallCenter a moment to report the call as active.
    [self evaluate];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self evaluate]; });
}

- (void)evaluate {
    if (!AMSAnyLiveCall()) {
        if (self.armed || self.window) AMSLog(@"no live call, resetting");
        [self reset];
        return;
    }
    AMCenter *center = AMSCenter();
    BOOL amAnswered = self.armed || ([center respondsToSelector:@selector(callAutoAnswered)] && [center callAutoAnswered]);
    if (amAnswered && !self.armed) {
        AMSLog(@"AMCenter reports callAutoAnswered");
        self.armed = YES;
        if (!self.answeredAt) self.answeredAt = [NSDate date];
    }
    if (self.armed && !self.hiddenByUser && !self.handedOff && AMSAnsweredIncomingCall()) {
        [self present];
    }
}

- (void)present {
    if (!self.window) {
        self.window = [AMSScreenWindow makeWindow];
        self.window.screenController.delegate = self;
        AMSLog(@"window created, scene=%@", self.window.windowScene);
    }
    [self hideOriginalWindow];
    [self refresh];
    if (self.window.hidden) {
        self.window.hidden = NO;
        AMSLog(@"screen shown");
    }
    [self.window.screenController startReels];
    if (!self.ticker) {
        __weak __typeof__(self) weakSelf = self;
        self.ticker = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            [weakSelf refresh];
            if (!AMSAnyLiveCall()) [weakSelf reset];
        }];
    }
}

- (void)refresh {
    if (!self.window) return;
    AMCenter *center = AMSCenter();
    NSString *name = [center respondsToSelector:@selector(callerName)] ? AMSString([center callerName]) : nil;
    if (!name) name = AMSString(AMSAnsweredIncomingCall().displayName);
    [self.window.screenController setCallerName:name];

    NSString *status = [center respondsToSelector:@selector(statusString)] ? AMSString([center statusString]) : nil;
    if (!status) {
        NSInteger secs = self.answeredAt ? (NSInteger)-[self.answeredAt timeIntervalSinceNow] : 0;
        NSString *clock = [NSString stringWithFormat:@"%02ld:%02ld", (long)(secs / 60), (long)(secs % 60)];
        status = self.greetingDone ? [@"Recording voicemail " stringByAppendingString:clock]
                                   : [@"Playing greeting " stringByAppendingString:clock];
    }
    [self.window.screenController setStatus:status];
}

// AM may still create its own (invisible or broken) window; keep it out of the way.
- (void)hideOriginalWindow {
    AMCenter *center = AMSCenter();
    if (!center) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(center), "_callWindow");
    UIWindow *orig = ivar ? object_getIvar(center, ivar) : nil;
    if ([orig isKindOfClass:UIWindow.class] && !orig.hidden) {
        AMSLog(@"hiding AM's own call window %@", orig);
        orig.hidden = YES;
    }
}

- (void)dismissWindow {
    [self.ticker invalidate];
    self.ticker = nil;
    self.window.hidden = YES;
}

- (void)reset {
    [self dismissWindow];
    self.window = nil;
    self.armed = NO;
    self.greetingDone = NO;
    self.listening = NO;
    self.hiddenByUser = NO;
    self.handedOff = NO;
    self.answeredAt = nil;
}

#pragma mark AMSScreenDelegate

- (void)screenDidTapListen:(UIButton *)button {
    AMCenter *center = AMSCenter();
    if (![center respondsToSelector:@selector(listenToCaller:)]) {
        AMSLog(@"listen: AMCenter missing listenToCaller:");
        return;
    }
    // AM's handler expects its own toggle button as the sender; fall back to ours.
    UIButton *sender = [center respondsToSelector:@selector(sneakButton)] ? [center sneakButton] : nil;
    if (![sender isKindOfClass:UIButton.class]) sender = button;
    BOOL before = sender.isSelected;
    [center listenToCaller:sender];
    BOOL after = sender.isSelected;
    self.listening = (after != before) ? after : !self.listening;
    AMSLog(@"listen tapped, sender=%@ selected %d->%d, listening=%d", sender.class, before, after, self.listening);
    [self.window.screenController setListening:self.listening];
}

- (void)screenDidTapTalk {
    AMSLog(@"talk tapped");
    self.handedOff = YES;
    [self dismissWindow];
    AMCenter *center = AMSCenter();
    if ([center respondsToSelector:@selector(takeOverCurrentCall)]) [center takeOverCurrentCall];
}

- (void)screenDidTapHangUp {
    AMSLog(@"hang up tapped");
    self.handedOff = YES;
    [self dismissWindow];
    AMCenter *center = AMSCenter();
    if ([center respondsToSelector:@selector(declineCurrentCall)]) [center declineCurrentCall];
    // If AM didn't end it, end it ourselves.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TUCall *call = AMSAnsweredIncomingCall();
        if (call) {
            AMSLog(@"call still active after decline, disconnecting directly");
            [AMSCallCenter() disconnectCall:call];
        }
    });
}

- (void)screenDidTapHide {
    AMSLog(@"hide tapped");
    self.hiddenByUser = YES;
    [self dismissWindow];
}

@end

#pragma mark Hooks into AnsweringMachine's controller (SpringBoard side)

%group AMHooks

%hook AMCenter

- (void)autoAnswerCall {
    AMSLog(@"-[AMCenter autoAnswerCall]");
    %orig;
    [[AMSController shared] callWasAutoAnswered];
}

- (void)requestRemoteViewService {
    AMSLog(@"-[AMCenter requestRemoteViewService]");
    %orig;
    [[AMSController shared] evaluate];
}

- (void)handleCallStatusChangedWithCall:(id)call {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ [[AMSController shared] evaluate]; });
}

- (void)listenToCaller:(id)sender {
    AMSLog(@"-[AMCenter listenToCaller:%@]", sender);
    %orig;
}

- (void)takeOverCurrentCall {
    AMSLog(@"-[AMCenter takeOverCurrentCall]");
    %orig;
}

- (void)declineCurrentCall {
    AMSLog(@"-[AMCenter declineCurrentCall]");
    %orig;
}

%end

%end

#pragma mark Darwin notifications posted by AnsweringMachine (any process)

static void AMSOnAutoAnswered(CFNotificationCenterRef c, void *o, CFStringRef name, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ [[AMSController shared] callWasAutoAnswered]; });
}

static void AMSOnGreetingFinished(CFNotificationCenterRef c, void *o, CFStringRef name, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AMSLog(@"greeting finished");
        [AMSController shared].greetingDone = YES;
    });
}

static void AMSOnStatusBarTapped(CFNotificationCenterRef c, void *o, CFStringRef name, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AMSLog(@"AM status bar tapped, re-showing");
        [AMSController shared].hiddenByUser = NO;
        [[AMSController shared] evaluate];
    });
}

static void AMSOnStatusChanged(CFNotificationCenterRef c, void *o, CFStringRef name, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ [[AMSController shared] evaluate]; });
}

static void AMSObserve(const char *name, CFNotificationCallback cb) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, cb,
        (__bridge CFStringRef)@(name), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    AMSLog(@"loaded into SpringBoard");

    AMSObserve(AM_NOTIFY("callAutoAnswered"), AMSOnAutoAnswered);
    AMSObserve(AM_NOTIFY("greetingFinished"), AMSOnGreetingFinished);
    AMSObserve(AM_NOTIFY("doubleHeightStatusBarTapped"), AMSOnStatusBarTapped);
    AMSObserve(AM_NOTIFY("callStatusChanged"), AMSOnStatusChanged);
    AMSObserve(AM_NOTIFY("stopAnsweringMachine"), AMSOnStatusChanged);

    [[NSNotificationCenter defaultCenter] addObserverForName:@"TUCallCenterCallStatusChangedNotification"
                                                      object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) { [[AMSController shared] evaluate]; }];

    // Tweaks load alphabetically, so AnsweringMachineUI.dylib may not be loaded yet.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (objc_getClass("AMCenter")) {
            %init(AMHooks);
            AMSLog(@"hooked AMCenter");
        } else {
            AMSLog(@"AMCenter not found - is AnsweringMachine XS installed and enabled?");
        }
    });
}
