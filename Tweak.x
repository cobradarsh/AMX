// AMScreen: brings back AnsweringMachine XS's call-screening screen on iOS 16.
//
// AnsweringMachine still auto-answers, plays the greeting and records. Its own
// AMCallWindow never appears on iOS 16 because it isn't attached to a UIWindowScene.
// We show our own window when AM auto-answers and route the buttons back to AM's
// controller (AMCenter), so AM's audio hooks keep handling mute/listen/record.
//
// Neither AM nor our locked-screen fallback may auto-answer a second (waiting)
// call while you're already on a call: that would drop the call you're on.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import "AMSScreenWindow.h"

#define AM_NOTIFY(name) "net.limneos.answeringmachine." name

// Published by SpringBoard, read by every process AM's auto-answer may run in.
static const char *const kCallWaitingNotify = "com.personal.amscreen.callwaiting";

@interface AMCenter : NSObject
+ (instancetype)sharedInstance;
- (void)autoAnswerCall;
- (BOOL)callAutoAnswered;
- (NSString *)callerName;
- (NSString *)statusString;
- (UIButton *)sneakButton;
- (void)listenToCaller:(id)sender;
- (void)takeOverCurrentCall;
- (void)declineCurrentCall;
@end

@interface TUHandle : NSObject
@property (nonatomic, readonly, copy) NSString *value;
@end

@interface TUCall : NSObject
@property (nonatomic, readonly) int status;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, getter=isOutgoing) BOOL outgoing;
@property (nonatomic, readonly) TUHandle *handle;
@property (nonatomic, readonly, copy) NSString *contactIdentifier;
@end

@interface TUCallCenter : NSObject
+ (instancetype)sharedInstance;
- (NSArray<TUCall *> *)currentCalls;
- (void)disconnectCall:(TUCall *)call;
@end

// TUCallStatus values.
enum { kCallActive = 1, kCallHeld = 2, kCallSending = 3, kCallRinging = 4, kCallDisconnecting = 5, kCallDisconnected = 6 };

static NSString *const kLogPath = @"/var/mobile/Library/Logs/AMScreen.log";

static void AMSLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void AMSLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[AMScreen] %@", msg);

    NSString *line = [NSString stringWithFormat:@"%@ [%s] %@\n", [NSDate date], getprogname(), msg];
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

// --- Call waiting ------------------------------------------------------------
// An incoming call is ringing while another call is already up (talking, on hold
// or dialing). Auto-answering then would drop the call in progress.
static BOOL AMSCallWaiting(void) {
    BOOL ringing = NO, established = NO;
    for (TUCall *call in AMSCallCenter().currentCalls) {
        int status = call.status;
        if (status == kCallRinging && !call.isOutgoing) ringing = YES;
        else if (status == kCallActive || status == kCallHeld || status == kCallSending) established = YES;
    }
    return ringing && established;
}

static void AMSPublishCallWaiting(void) {
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID && notify_register_check(kCallWaitingNotify, &token) != NOTIFY_STATUS_OK) return;
    uint64_t waiting = AMSCallWaiting(), previous = 0;
    notify_get_state(token, &previous);
    if (waiting == previous) return;
    notify_set_state(token, waiting);
    notify_post(kCallWaitingNotify);
    AMSLog(@"call waiting: %d", (int)waiting);
}

static BOOL AMSPublishedCallWaiting(void) {
    int token;
    uint64_t waiting = 0;
    if (notify_register_check(kCallWaitingNotify, &token) != NOTIFY_STATUS_OK) return NO;
    notify_get_state(token, &waiting);
    notify_cancel(token);
    return waiting != 0;
}

// --- Screen-off / locked auto-answer -----------------------------------------
// On iOS 16, AnsweringMachine often doesn't auto-answer while the device is
// locked (screen off). We detect a ringing call while locked and, if AM hasn't
// picked up within a short delay, trigger its auto-answer ourselves.
@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end

static NSString *AMSStatusName(int s) {
    switch (s) { case 1: return @"active"; case 4: return @"ringing"; case 5: return @"disconnecting"; case 6: return @"ended"; default: return [NSString stringWithFormat:@"%d", s]; }
}
static BOOL AMSLocked(void) {
    Class c = NSClassFromString(@"SBLockScreenManager");
    id m = [c respondsToSelector:@selector(sharedInstance)] ? [c sharedInstance] : nil;
    return [m respondsToSelector:@selector(isUILocked)] ? [m isUILocked] : NO;
}
static TUCall *AMSRingingCall(void) {
    for (TUCall *c in AMSCallCenter().currentCalls)
        if (!c.isOutgoing && c.status == kCallRinging) return c;
    return nil;
}

static BOOL gForceScheduled = NO;
static const double kAMSForceAnswerDelay = 8.0;   // seconds to wait before forcing

static void AMSMaybeForceAnswerWhenLocked(void) {
    if (gForceScheduled || !AMSLocked() || !AMSRingingCall()) return;
    // A second call ringing while you're on a call: leave it alone. Otherwise the
    // forced answer would make AM drop the call you're on to take this one.
    if (AMSCallWaiting()) return;
    // CallHider-hidden callers are never answered by AM, forced or otherwise.
    if (AMSCallHiddenByCallHider(AMSRingingCall())) { AMSLog(@"locked + ringing but caller is CallHider-hidden; not forcing"); return; }
    gForceScheduled = YES;
    AMSLog(@"locked + ringing: scheduling forced auto-answer in %.0fs", kAMSForceAnswerDelay);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAMSForceAnswerDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AMCenter *center = AMSCenter();
        BOOL answered = [center respondsToSelector:@selector(callAutoAnswered)] && [center callAutoAnswered];
        TUCall *still = AMSRingingCall();
        if (AMSCallWaiting()) {
            AMSLog(@"forced answer skipped: another call is in progress");
        } else if (still && !answered && [center respondsToSelector:@selector(autoAnswerCall)]) {
            AMSLog(@"forcing -[AMCenter autoAnswerCall] (locked call still ringing, AM did not answer)");
            [center autoAnswerCall];
        } else {
            AMSLog(@"forced answer skipped (answered=%d stillRinging=%d)", answered, still != nil);
        }
    });
}


static TUCall *AMSAnsweredIncomingCall(void) {
    TUCallCenter *tu = AMSCallCenter();
    for (TUCall *call in tu.currentCalls) {
        if (call.status == kCallActive && !call.isOutgoing) return call;
    }
    return nil;
}

// The call AnsweringMachine is about to / just did auto-answer: the incoming
// (ringing) or freshly active call.
static TUCall *AMSIncomingOrActiveCall(void) {
    for (TUCall *call in AMSCallCenter().currentCalls) {
        if (!call.isOutgoing && (call.status == kCallRinging || call.status == kCallActive)) return call;
    }
    return nil;
}

// --- CallHider integration -------------------------------------------------
// Read CallHider's hidden-callers list from its shared preferences and decide
// whether a caller should be left alone (NOT auto-answered). Keys mirror
// CallHider/CHPrefs.h: app id com.cobradarsh.callhider, array "hiddenContacts"
// of { id, name, numbers:[...] }.
#define kCHAppID CFSTR("com.cobradarsh.callhider")

static NSString *AMSDigits(NSString *raw) {
    if (![raw isKindOfClass:NSString.class] || raw.length == 0) return nil;
    NSMutableString *d = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) { unichar c = [raw characterAtIndex:i]; if (c >= '0' && c <= '9') [d appendFormat:@"%C", c]; }
    if (d.length == 0) return nil;
    return d.length > 10 ? [d substringFromIndex:d.length - 10] : d;
}

static BOOL AMSCallHiddenByCallHider(TUCall *call) {
    if (!call) return NO;
    CFPreferencesAppSynchronize(kCHAppID);
    id en = (__bridge_transfer id)CFPreferencesCopyValue(CFSTR("enabled"), kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (en != nil && ![en boolValue]) return NO;                 // CallHider disabled
    NSArray *hidden = (__bridge_transfer NSArray *)CFPreferencesCopyValue(CFSTR("hiddenContacts"), kCHAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (![hidden isKindOfClass:NSArray.class] || hidden.count == 0) return NO;

    NSString *cid = nil, *num = nil;
    @try { cid = call.contactIdentifier; num = AMSDigits(call.handle.value); } @catch (__unused NSException *e) { return NO; }
    for (NSDictionary *e in hidden) {
        if (![e isKindOfClass:NSDictionary.class]) continue;
        id eid = e[@"id"];
        if (cid.length && [eid isKindOfClass:NSString.class] && [eid isEqualToString:cid]) return YES;
        if (num.length) for (NSString *n in e[@"numbers"])
            if ([n isKindOfClass:NSString.class] && n.length && ([num hasSuffix:n] || [n hasSuffix:num])) return YES;
    }
    return NO;
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
    if (AMSCallWaiting()) {
        AMSLog(@"auto-answer signal ignored: already on another call");
        return;
    }
    // Belt-and-suspenders: never raise the screen for a CallHider-hidden caller,
    // even if AnsweringMachine answered via a path we didn't intercept.
    if (AMSCallHiddenByCallHider(AMSIncomingOrActiveCall())) {
        AMSLog(@"ignoring auto-answer screen for CallHider-hidden caller");
        return;
    }
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
    if (AMSCallWaiting() && !self.armed) return;
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
    // CallHider: never show the screen for a hidden caller (AM still records).
    if (AMSCallHiddenByCallHider(AMSIncomingOrActiveCall())) {
        AMSLog(@"not presenting screen: CallHider-hidden caller (AM still records)");
        return;
    }
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

#pragma mark Hooks into AnsweringMachine's controller

static BOOL gIsSpringBoard;

// Every process AnsweringMachineUI.dylib loads into: whichever one runs AM's
// greeting-delay timer, a waiting call must not be auto-answered there.
%group AMGuard

%hook AMCenter

- (void)autoAnswerCall {
    if (AMSPublishedCallWaiting() || AMSCallWaiting()) {
        AMSLog(@"-[AMCenter autoAnswerCall] blocked: already on another call");
        return;
    }
    // CallHider: AnsweringMachine is DISABLED for hidden callers — never pick up.
    TUCall *candidate = AMSRingingCall();
    if (AMSCallHiddenByCallHider(candidate)) {
        AMSLog(@"-[AMCenter autoAnswerCall] skipped: caller is CallHider-hidden (%@)", candidate.displayName ?: @"?");
        return;                         // no %orig -> AM does not answer or record
    }
    AMSLog(@"-[AMCenter autoAnswerCall] (locked=%d)", AMSLocked());
    %orig;
    if (gIsSpringBoard) [[AMSController shared] callWasAutoAnswered];
}

%end

%end

// SpringBoard only: drives the screening screen.
%group AMHooks

%hook AMCenter

- (void)requestRemoteViewService {
    AMSLog(@"-[AMCenter requestRemoteViewService]");
    %orig;
    [[AMSController shared] evaluate];
}

- (void)handleCallStatusChangedWithCall:(id)call {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        AMSPublishCallWaiting();
        if (!AMSAnyLiveCall()) gForceScheduled = NO;
        AMSMaybeForceAnswerWhenLocked();
        [[AMSController shared] evaluate];
    });
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
    dispatch_async(dispatch_get_main_queue(), ^{
        AMSPublishCallWaiting();
        [[AMSController shared] evaluate];
    });
}

static void AMSObserve(const char *name, CFNotificationCallback cb) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, cb,
        (__bridge CFStringRef)@(name), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

%ctor {
    gIsSpringBoard = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];

    if (gIsSpringBoard) {
        AMSLog(@"loaded into SpringBoard");

        AMSObserve(AM_NOTIFY("callAutoAnswered"), AMSOnAutoAnswered);
        AMSObserve(AM_NOTIFY("greetingFinished"), AMSOnGreetingFinished);
        AMSObserve(AM_NOTIFY("doubleHeightStatusBarTapped"), AMSOnStatusBarTapped);
        AMSObserve(AM_NOTIFY("callStatusChanged"), AMSOnStatusChanged);
        AMSObserve(AM_NOTIFY("stopAnsweringMachine"), AMSOnStatusChanged);

        [[NSNotificationCenter defaultCenter] addObserverForName:@"TUCallCenterCallStatusChangedNotification"
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            for (TUCall *c in AMSCallCenter().currentCalls)
                if (!c.isOutgoing) AMSLog(@"call status=%@ locked=%d", AMSStatusName(c.status), AMSLocked());
            AMSPublishCallWaiting();
            if (!AMSAnyLiveCall()) gForceScheduled = NO;
            AMSMaybeForceAnswerWhenLocked();
            [[AMSController shared] evaluate];
        }];
    }

    // Tweaks load alphabetically, so AnsweringMachineUI.dylib may not be loaded yet.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!objc_getClass("AMCenter")) {
            if (gIsSpringBoard) AMSLog(@"AMCenter not found - is AnsweringMachine XS installed and enabled?");
            return;
        }
        %init(AMGuard);
        if (gIsSpringBoard) {
            %init(AMHooks);
            AMSPublishCallWaiting();
        }
        AMSLog(@"hooked AMCenter");
    });
}
