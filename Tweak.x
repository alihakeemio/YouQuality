#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>

#define TweakKey    @"YouQuality"
#define VolBoostKey @"YouQualityVolBoost"

// ─── Gain state ───────────────────────────────────────────────────────────────
static float currentGain = 1.0f;

static float savedVolGain() {
    float g = (float)[[NSUserDefaults standardUserDefaults] floatForKey:@"YouQualityVolBoost-Gain"];
    if (g < 1.0f) g = 1.0f;
    if (g > 4.0f) g = 4.0f;
    return g;
}

static float nextGain(float gain) {
    static const float steps[] = {1.0f, 1.25f, 1.50f, 1.75f, 2.0f, 2.5f, 3.0f, 3.5f, 4.0f};
    for (int i = 0; i < 9; i++) if (gain < steps[i] - 0.01f) return steps[i];
    return 1.0f;
}

static void saveGain(float gain) {
    currentGain = gain;
    [[NSUserDefaults standardUserDefaults] setFloat:gain forKey:@"YouQualityVolBoost-Gain"];
}

static NSString *gainLabel() {
    int pct = (int)roundf(currentGain * 100.f);
    return [NSString stringWithFormat:@"%d%%", pct];
}

// ─── Forward declarations ─────────────────────────────────────────────────────
@interface YTMainAppControlsOverlayView (YouQuality)
- (void)didPressYouQuality:(id)arg;
- (void)updateYouQualityButton:(id)arg;
- (void)didPressVolBoost:(id)arg;
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr;
@end

@interface YTInlinePlayerBarContainerView (YouQuality)
- (void)didPressYouQuality:(id)arg;
- (void)updateYouQualityButton:(id)arg;
- (void)didPressVolBoost:(id)arg;
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr;
@end

// ─── Shared globals ───────────────────────────────────────────────────────────
NSString *YouQualityUpdateNotification = @"YouQualityUpdateNotification";
NSString *currentQualityLabel = @"N/A";

static void setButtonStyle(YTQTMButton *button) {
    button.titleLabel.numberOfLines = 3;
    [button setTitle:@"Auto" forState:UIControlStateNormal];
}

static void updateVolBoostLabel(YTQTMButton *button) {
    if (!button) return;
    button.titleLabel.numberOfLines = 3;
    [button setTitle:gainLabel() forState:UIControlStateNormal];
}

static void addLongPress(YTQTMButton *button, id target) {
    if (!button) return;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:target action:@selector(handleVolBoostLongPress:)];
    lp.minimumPressDuration = 0.6;
    [button addGestureRecognizer:lp];
}

// ─── Volume hook ──────────────────────────────────────────────────────────────
// AVSampleBufferAudioRenderer is the ObjC class YouTube's HAMPlayer uses
// internally to render decoded PCM audio. Its volume property accepts values
// above 1.0, giving true amplification without any C function hooks.
%group Audio

%hook AVSampleBufferAudioRenderer

- (void)setVolume:(float)volume {
    %orig(volume * currentGain);
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

// ─── Top overlay ──────────────────────────────────────────────────────────────
%group Top

%hook YTMainAppControlsOverlayView

- (id)initWithDelegate:(id)delegate {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setButtonStyle(self.overlayButtons[TweakKey]);
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
    addLongPress(self.overlayButtons[VolBoostKey], self);
    return self;
}

- (id)initWithDelegate:(id)delegate autoplaySwitchEnabled:(BOOL)autoplaySwitchEnabled {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setButtonStyle(self.overlayButtons[TweakKey]);
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
    addLongPress(self.overlayButtons[VolBoostKey], self);
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

%new(v@:@)
- (void)didPressVolBoost:(id)arg {
    saveGain(nextGain(currentGain));
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
}

%new(v@:@)
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    saveGain(1.0f);
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
}

%end

%end

// ─── Bottom overlay ───────────────────────────────────────────────────────────
%group Bottom

%hook YTInlinePlayerBarContainerView

- (id)init {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setButtonStyle(self.overlayButtons[TweakKey]);
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
    addLongPress(self.overlayButtons[VolBoostKey], self);
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:YouQualityUpdateNotification object:nil];
    setButtonStyle(self.overlayButtons[TweakKey]);
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

%new(v@:@)
- (void)didPressVolBoost:(id)arg {
    saveGain(nextGain(currentGain));
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
}

%new(v@:@)
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    saveGain(1.0f);
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
}

%end

%end

// ─── Constructor ──────────────────────────────────────────────────────────────
%ctor {
    currentGain = savedVolGain();
    initYTVideoOverlay(TweakKey, @{
        AccessibilityLabelKey: @"Quality",
        SelectorKey: @"didPressYouQuality:",
        AsTextKey: @YES
    });
    initYTVideoOverlay(VolBoostKey, @{
        AccessibilityLabelKey: @"Vol",
        SelectorKey: @"didPressVolBoost:",
        AsTextKey: @YES
    });
    %init(Audio);
    %init(Video);
    %init(Top);
    %init(Bottom);
}
