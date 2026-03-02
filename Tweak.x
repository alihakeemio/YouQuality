#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#define TweakKey      @"YouQuality"
#define VolBoostKey   @"YouQualityVolBoost"
#define GainKey       @"YouQualityVolBoost-Gain"
#define RotationKey   @"YouRotation"

static void applyGainImmediately(); // forward declaration

// ─── Gain state ───────────────────────────────────────────────────────────────
static float currentGain = 1.0f;

static float loadGain() {
    float g = [[NSUserDefaults standardUserDefaults] floatForKey:GainKey];
    if (g < 1.0f) g = 1.0f;
    if (g > 8.0f) g = 8.0f;
    return g;
}

static void saveGain(float gain) {
    if (gain < 1.0f) gain = 1.0f;
    if (gain > 8.0f) gain = 8.0f;
    currentGain = gain;
    [[NSUserDefaults standardUserDefaults] setFloat:gain forKey:GainKey];
    applyGainImmediately();
}

static float nextGain(float gain) {
    static const float steps[] = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f, 8.0f};
    for (int i = 0; i < 8; i++)
        if (gain < steps[i] - 0.01f) return steps[i];
    return 1.0f;
}

static NSString *gainLabel() {
    int pct = (int)roundf(currentGain * 100.f);
    return [NSString stringWithFormat:@"%d%%", pct];
}

// ─── Rotation state ───────────────────────────────────────────────────────────
static NSInteger currentAngleIndex = 0;
static const NSInteger kAngles[] = {0, 90, 180, 270};
static const NSInteger kAngleCount = 4;

static NSString *rotationLabel() {
    return [NSString stringWithFormat:@"%ld\u00b0", (long)kAngles[currentAngleIndex]];
}

// ─── HAMSBARAudioTrackRenderer interface ──────────────────────────────────────
@interface HAMSBARAudioTrackRenderer : NSObject
@property (nonatomic, assign) float volume;
- (void)updateGainAndRendererVolume;
@end

// ─── Forward declarations ─────────────────────────────────────────────────────
@interface YTMainAppControlsOverlayView (YouQuality)
- (void)didPressYouQuality:(id)arg;
- (void)updateYouQualityButton:(id)arg;
- (void)didPressVolBoost:(id)arg;
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr;
- (void)updateVolBoostButton;
- (void)didPressYouRotation:(id)arg;
- (void)handleYouRotationLongPress:(UILongPressGestureRecognizer *)gr;
- (void)updateYouRotationButton;
@end

@interface YTInlinePlayerBarContainerView (YouQuality)
- (void)didPressYouQuality:(id)arg;
- (void)updateYouQualityButton:(id)arg;
- (void)didPressVolBoost:(id)arg;
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr;
- (void)updateVolBoostButton;
- (void)didPressYouRotation:(id)arg;
- (void)handleYouRotationLongPress:(UILongPressGestureRecognizer *)gr;
- (void)updateYouRotationButton;
@end

// ─── Shared globals ───────────────────────────────────────────────────────────
NSString *YouQualityUpdateNotification = @"YouQualityUpdateNotification";
NSString *currentQualityLabel = @"N/A";

static void setQualityButtonStyle(YTQTMButton *button) {
    button.titleLabel.numberOfLines = 3;
    [button setTitle:@"Auto" forState:UIControlStateNormal];
}

static void updateVolBoostButtonLabel(YTQTMButton *button) {
    if (!button) return;
    button.titleLabel.numberOfLines = 1;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.7;
    [button setTitle:gainLabel() forState:UIControlStateNormal];
}

static void updateRotationButtonLabel(YTQTMButton *button) {
    if (!button) return;
    button.titleLabel.numberOfLines = 1;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.7;
    [button setTitle:rotationLabel() forState:UIControlStateNormal];
}

static void attachLongPress(YTQTMButton *button, id target, SEL action) {
    if (!button) return;
    for (UIGestureRecognizer *gr in button.gestureRecognizers)
        if ([gr isKindOfClass:[UILongPressGestureRecognizer class]])
            [button removeGestureRecognizer:gr];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:target action:action];
    lp.minimumPressDuration = 0.6;
    [button addGestureRecognizer:lp];
}

// ─── Rotation engine ──────────────────────────────────────────────────────────
static UIView *findRenderingView() {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows)
        if (w.isKeyWindow) { keyWindow = w; break; }
    if (!keyWindow) return nil;

    NSMutableArray *stack = [NSMutableArray arrayWithObject:keyWindow];
    while (stack.count) {
        UIView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        NSString *cls = NSStringFromClass(v.class);
        if ([cls containsString:@"MLHAMSBDLSampleBufferRenderingView"] ||
            [cls containsString:@"HAMSBDLSampleBufferRenderingView"])
            return v;
        for (UIView *sub in v.subviews)
            [stack addObject:sub];
    }
    return nil;
}

static UIView *findParentResponding(UIView *view, SEL sel) {
    UIView *v = view.superview;
    for (int i = 0; i < 15 && v; i++, v = v.superview)
        if ([v respondsToSelector:sel]) return v;
    return nil;
}

static void resetZoom(UIView *renderingView) {
    SEL frameSel = @selector(setRenderingViewCustomFrame:animated:duration:);
    UIView *ytpv = findParentResponding(renderingView, frameSel);
    if (!ytpv) return;
    // CGRect HFA -> d0-d3, BOOL -> x2, double -> d4  (confirmed via Frida spy8)
    typedef void (*SetFrameFn)(id, SEL, double, double, double, double, int, double);
    ((SetFrameFn)objc_msgSend)(ytpv, frameSel, INFINITY, INFINITY, 0.0, 0.0, 1, 0.133);
    SEL updateSel = @selector(updateRenderingViewCustomFrame);
    if ([ytpv respondsToSelector:updateSel])
        ((void (*)(id, SEL))objc_msgSend)(ytpv, updateSel);
}

static void resetZoomButton() {
    // Simulate tapping the zoom label: calls didPressFreeZoomScaleButton: on
    // YTMainAppControlsOverlayView (confirmed via Frida sendAction spy).
    SEL sel = @selector(didPressFreeZoomScaleButton:);
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows)
        if (w.isKeyWindow) { keyWindow = w; break; }
    if (!keyWindow) return;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:keyWindow];
    while (stack.count) {
        UIView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if ([v respondsToSelector:sel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(v, sel, nil);
            return;
        }
        for (UIView *sub in v.subviews)
            [stack addObject:sub];
    }
}

static void performRotation(NSInteger degrees) {
    UIView *view = findRenderingView();
    if (!view) return;

    resetZoom(view);
    resetZoomButton();

    CGFloat radians = degrees * M_PI / 180.0;
    BOOL isRotated = (degrees == 90 || degrees == 270);
    CGFloat fitScale = 1.0;
    if (isRotated) {
        CGFloat w = [[view.layer valueForKeyPath:@"bounds.size.width"] doubleValue];
        CGFloat h = [[view.layer valueForKeyPath:@"bounds.size.height"] doubleValue];
        if (w > 0 && h > 0)
            fitScale = MIN(w / h, h / w);
    }

    [CATransaction begin];
    [CATransaction setAnimationDuration:0.35];
    [view.layer setValue:@(radians) forKeyPath:@"transform.rotation.z"];
    [view.layer setValue:@(fitScale) forKeyPath:@"transform.scale"];
    [CATransaction commit];
}

// ─── Audio engine state ───────────────────────────────────────────────────────
static __weak HAMSBARAudioTrackRenderer *sActiveRenderer = nil;
static float sBaseVolume = 1.0f;

static void applyGainImmediately() {
    HAMSBARAudioTrackRenderer *renderer = sActiveRenderer;
    if (!renderer) return;
    [renderer updateGainAndRendererVolume];
}

%group Audio

%hook HAMSBARAudioTrackRenderer

- (void)updateGainAndRendererVolume {
    %orig;
    Ivar ivar = class_getInstanceVariable([self class], "_renderer");
    if (!ivar) return;
    id rendererObj = object_getIvar(self, ivar);
    if (!rendererObj) return;
    AVSampleBufferAudioRenderer *r = rendererObj;
    sActiveRenderer = self;
    sBaseVolume = r.volume;
    if (currentGain > 1.0f)
        r.volume = sBaseVolume * currentGain;
}

%end

%end

// ─── Video group ──────────────────────────────────────────────────────────────
%group Video

NSString *getCompactQualityLabel(MLFormat *format) {
    NSString *qualityLabel = [format qualityLabel];
    BOOL shouldShowFPS = [format FPS] > 30;
    if ([qualityLabel hasPrefix:@"2160p"])
        qualityLabel = [qualityLabel stringByReplacingOccurrencesOfString:@"2160p" withString:shouldShowFPS ? @"4K\n" : @"4K"];
    else if ([qualityLabel hasPrefix:@"1440p"])
        qualityLabel = [qualityLabel stringByReplacingOccurrencesOfString:@"1440p" withString:shouldShowFPS ? @"2K\n" : @"2K"];
    else if ([qualityLabel hasPrefix:@"1080p"])
        qualityLabel = [qualityLabel stringByReplacingOccurrencesOfString:@"1080p" withString:shouldShowFPS ? @"HD\n" : @"HD"];
    else if (shouldShowFPS)
        qualityLabel = [qualityLabel stringByReplacingOccurrencesOfString:@"p" withString:@"p\n"];
    if ([qualityLabel hasSuffix:@" HDR"])
        qualityLabel = [qualityLabel stringByReplacingOccurrencesOfString:@" HDR" withString:@"\nHDR"];
    return qualityLabel;
}

%hook YTVideoQualitySwitchOriginalController
- (void)singleVideo:(id)singleVideo didSelectVideoFormat:(MLFormat *)format {
    currentQualityLabel = getCompactQualityLabel(format);
    [[NSNotificationCenter defaultCenter] postNotificationName:YouQualityUpdateNotification object:nil];
    %orig;
}
%end

%hook YTVideoQualitySwitchRedesignedController
- (void)singleVideo:(id)singleVideo didSelectVideoFormat:(MLFormat *)format {
    currentQualityLabel = getCompactQualityLabel(format);
    [[NSNotificationCenter defaultCenter] postNotificationName:YouQualityUpdateNotification object:nil];
    %orig;
}
%end

%end

// ─── Top overlay ──────────────────────────────────────────────────────────────
%group Top

%hook YTMainAppControlsOverlayView

- (id)initWithDelegate:(id)delegate {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setQualityButtonStyle(self.overlayButtons[TweakKey]);
    updateVolBoostButtonLabel(self.overlayButtons[VolBoostKey]);
    updateRotationButtonLabel(self.overlayButtons[RotationKey]);
    attachLongPress(self.overlayButtons[VolBoostKey], self, @selector(handleVolBoostLongPress:));
    attachLongPress(self.overlayButtons[RotationKey], self, @selector(handleYouRotationLongPress:));
    return self;
}

- (id)initWithDelegate:(id)delegate autoplaySwitchEnabled:(BOOL)autoplaySwitchEnabled {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setQualityButtonStyle(self.overlayButtons[TweakKey]);
    updateVolBoostButtonLabel(self.overlayButtons[VolBoostKey]);
    updateRotationButtonLabel(self.overlayButtons[RotationKey]);
    attachLongPress(self.overlayButtons[VolBoostKey], self, @selector(handleVolBoostLongPress:));
    attachLongPress(self.overlayButtons[RotationKey], self, @selector(handleYouRotationLongPress:));
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:YouQualityUpdateNotification object:nil];
    %orig;
}

%new(v@:@)
- (void)updateYouQualityButton:(id)arg {
    [self.overlayButtons[TweakKey] setTitle:currentQualityLabel forState:UIControlStateNormal];
}

%new(v@:@)
- (void)didPressYouQuality:(id)arg {
    YTMainAppVideoPlayerOverlayViewController *c = [self valueForKey:@"_eventsDelegate"];
    [c didPressVideoQuality:arg];
    [self updateYouQualityButton:nil];
}

%new(v@:)
- (void)updateVolBoostButton {
    updateVolBoostButtonLabel(self.overlayButtons[VolBoostKey]);
}

%new(v@:@)
- (void)didPressVolBoost:(id)arg {
    saveGain(nextGain(currentGain));
    [self updateVolBoostButton];
}

%new(v@:@)
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    saveGain(1.0f);
    [self updateVolBoostButton];
}

%new(v@:)
- (void)updateYouRotationButton {
    updateRotationButtonLabel(self.overlayButtons[RotationKey]);
}

%new(v@:@)
- (void)didPressYouRotation:(id)arg {
    currentAngleIndex = (currentAngleIndex + 1) % kAngleCount;
    performRotation(kAngles[currentAngleIndex]);
    [self updateYouRotationButton];
}

%new(v@:@)
- (void)handleYouRotationLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    currentAngleIndex = 0;
    performRotation(0);
    [self updateYouRotationButton];
}

%end

%end

// ─── Bottom overlay ───────────────────────────────────────────────────────────
%group Bottom

%hook YTInlinePlayerBarContainerView

- (id)init {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setQualityButtonStyle(self.overlayButtons[TweakKey]);
    updateVolBoostButtonLabel(self.overlayButtons[VolBoostKey]);
    updateRotationButtonLabel(self.overlayButtons[RotationKey]);
    attachLongPress(self.overlayButtons[VolBoostKey], self, @selector(handleVolBoostLongPress:));
    attachLongPress(self.overlayButtons[RotationKey], self, @selector(handleYouRotationLongPress:));
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:YouQualityUpdateNotification object:nil];
    setQualityButtonStyle(self.overlayButtons[TweakKey]);
    %orig;
}

%new(v@:@)
- (void)updateYouQualityButton:(id)arg {
    [self.overlayButtons[TweakKey] setTitle:currentQualityLabel forState:UIControlStateNormal];
}

%new(v@:@)
- (void)didPressYouQuality:(id)arg {
    YTMainAppVideoPlayerOverlayViewController *c = [self.delegate valueForKey:@"_delegate"];
    [c didPressVideoQuality:arg];
    [self updateYouQualityButton:nil];
}

%new(v@:)
- (void)updateVolBoostButton {
    updateVolBoostButtonLabel(self.overlayButtons[VolBoostKey]);
}

%new(v@:@)
- (void)didPressVolBoost:(id)arg {
    saveGain(nextGain(currentGain));
    [self updateVolBoostButton];
}

%new(v@:@)
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    saveGain(1.0f);
    [self updateVolBoostButton];
}

%new(v@:)
- (void)updateYouRotationButton {
    updateRotationButtonLabel(self.overlayButtons[RotationKey]);
}

%new(v@:@)
- (void)didPressYouRotation:(id)arg {
    currentAngleIndex = (currentAngleIndex + 1) % kAngleCount;
    performRotation(kAngles[currentAngleIndex]);
    [self updateYouRotationButton];
}

%new(v@:@)
- (void)handleYouRotationLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    currentAngleIndex = 0;
    performRotation(0);
    [self updateYouRotationButton];
}

%end

%end

// ─── Constructor ──────────────────────────────────────────────────────────────
%ctor {
    currentGain = loadGain();

    initYTVideoOverlay(TweakKey, @{
        AccessibilityLabelKey: @"Quality",
        SelectorKey: @"didPressYouQuality:",
        AsTextKey: @YES
    });
    initYTVideoOverlay(VolBoostKey, @{
        AccessibilityLabelKey: @"Volume Boost",
        SelectorKey: @"didPressVolBoost:",
        AsTextKey: @YES
    });
    initYTVideoOverlay(RotationKey, @{
        AccessibilityLabelKey: @"Rotation",
        SelectorKey: @"didPressYouRotation:",
        AsTextKey: @YES
    });

    %init(Audio);
    %init(Video);
    %init(Top);
    %init(Bottom);
}
