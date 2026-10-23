#import <UIKit/UIKit.h>

@protocol AMSScreenDelegate <NSObject>
- (void)screenDidTapListen:(UIButton *)button;
- (void)screenDidTapHangUp;
- (void)screenDidTapTalk;
- (void)screenDidTapHide;
@end

// Full-screen call-screening UI, modelled on AnsweringMachine's original screen.
@interface AMSScreenViewController : UIViewController
@property (nonatomic, weak) id<AMSScreenDelegate> delegate;
@property (nonatomic, readonly) UIButton *listenButton;
- (void)setCallerName:(NSString *)name;
- (void)setStatus:(NSString *)status;
- (void)setListening:(BOOL)listening;
- (void)startReels;
@end

// Secure, scene-attached window so it shows in SpringBoard on iOS 16, including over the lock screen.
@interface AMSScreenWindow : UIWindow
@property (nonatomic, readonly) AMSScreenViewController *screenController;
+ (instancetype)makeWindow;
@end
