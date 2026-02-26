#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#define TweakKey    @"YouQuality"
#define VolBoostKey @"YouQualityVolBoost"
#define GainKey     @"YouQualityVolBoost-Gain"

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

// Tap cycles: 100 -> 200 -> 300 -> 400 -> 500 -> 600 -> 700 -> 800 -> 100
static float nextGain(float gain) {
    static const float steps[] = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 7.0f, 8.0f};
    for (int i = 0; i < 8; i++)
        if (gain < steps[i] - 0.01f) return steps[i];
    return 1.0f; // wrap back to 100%
}

static NSString *gainLabel() {
    int pct = (int)roundf(currentGain * 100.f);
    return [NSString stringWithFormat:@"%d%%", pct];
}

// ─── HAMSBARAudioTrackRenderer interface ─────────────────────────────────────
// Confirmed via Frida: _renderer ivar holds AVSampleBufferAudioRenderer
// updateGainAndRendererVolume pushes final volume to _renderer after normalization
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
@end

@interface YTInlinePlayerBarContainerView (YouQuality)
- (void)didPressYouQuality:(id)arg;
- (void)updateYouQualityButton:(id)arg;
- (void)didPressVolBoost:(id)arg;
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr;
- (void)updateVolBoostButton;
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

    // Auto-fit text like "100%" → "800%"
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.7;

    [button setTitle:gainLabel()
            forState:UIControlStateNormal];
}

static void attachLongPress(YTQTMButton *button, id target) {
    if (!button) return;
    // Remove any existing long press recognizers to avoid duplicates
    for (UIGestureRecognizer *gr in button.gestureRecognizers) {
        if ([gr isKindOfClass:[UILongPressGestureRecognizer class]])
            [button removeGestureRecognizer:gr];
    }
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:target action:@selector(handleVolBoostLongPress:)];
    lp.minimumPressDuration = 0.6;
    [button addGestureRecognizer:lp];
}

// ─── Audio engine state ───────────────────────────────────────────────────────
// Confirmed via Frida: hook updateGainAndRendererVolume, after %orig read
// _renderer.volume (YouTube's normalized base), multiply by gain, set it back.
// Store active instance + base so button press applies instantly without
// needing pause/seek (mirrors the Frida script's applyGainNow logic exactly).

static __weak HAMSBARAudioTrackRenderer *sActiveRenderer = nil;
static float sBaseVolume = 1.0f;

static void applyGainImmediately() {
    HAMSBARAudioTrackRenderer *renderer = sActiveRenderer;
    if (!renderer) return;
    // Re-trigger YouTube's own normalization calculation, then our hook
    // will multiply the result by currentGain — exactly like the Frida script.
    [renderer updateGainAndRendererVolume];
}

%group Audio

%hook HAMSBARAudioTrackRenderer

- (void)updateGainAndRendererVolume {
    %orig;

    // Assign to id first — ARC allows implicit id → specific class conversion,
    // no __bridge or cast syntax needed, compiles cleanly in plain ObjC.
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

// ─── Video group ─────────────────────────────────────────────────────────────
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

// ─── Top overlay ─────────────────────────────────────────────────────────────
%group Top

%hook YTMainAppControlsOverlayView

- (id)initWithDelegate:(id)delegate {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setQualityButtonStyle(self.overlayButtons[TweakKey]);
    updateVolBoostButtonLabel(self.overlayButtons[VolBoostKey]);
    attachLongPress(self.overlayButtons[VolBoostKey], self);
    return self;
}

- (id)initWithDelegate:(id)delegate autoplaySwitchEnabled:(BOOL)autoplaySwitchEnabled {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setQualityButtonStyle(self.overlayButtons[TweakKey]);
    updateVolBoostButtonLabel(self.overlayButtons[VolBoostKey]);
    attachLongPress(self.overlayButtons[VolBoostKey], self);
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
    attachLongPress(self.overlayButtons[VolBoostKey], self);
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

%end

%end

// ─── Constructor ─────────────────────────────────────────────────────────────
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
    %init(Audio);
    %init(Video);
    %init(Top);
    %init(Bottom);
}
