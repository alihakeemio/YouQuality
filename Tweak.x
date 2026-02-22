#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>

#define TweakKey    @"YouQuality"
#define VolBoostKey @"YouQualityVolBoost"

// ─── VOLUME BOOST STATE & LOGIC ──────────────────────────────────────────────

static float currentGain = 1.0f;

static float savedVolGain() {
    float g = (float)[[NSUserDefaults standardUserDefaults] floatForKey:@"YouQualityVolBoost-Gain"];
    return (g < 1.0f) ? 1.0f : g;
}

static float nextGain(float gain) {
    static const float steps[] = {1.0f, 1.25f, 1.50f, 1.75f, 2.0f, 2.5f, 3.0f, 3.5f, 4.0f};
    for (int i = 0; i < 9; i++) {
        if (gain < steps[i] - 0.01f) return steps[i];
    }
    return 1.0f;
}

static void saveGain(float gain) {
    currentGain = gain;
    [[NSUserDefaults standardUserDefaults] setFloat:gain forKey:@"YouQualityVolBoost-Gain"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static NSString *gainLabel() {
    return [NSString stringWithFormat:@"%d%%", (int)roundf(currentGain * 100.f)];
}

// ─── YOUQUALITY STATE & LOGIC ────────────────────────────────────────────────

@interface YTMainAppControlsOverlayView (YouQuality)
- (void)didPressYouQuality:(id)arg;
- (void)updateYouQualityButton:(id)arg;
@end

@interface YTInlinePlayerBarContainerView (YouQuality)
- (void)didPressYouQuality:(id)arg;
- (void)updateYouQualityButton:(id)arg;
@end

NSString *YouQualityUpdateNotification = @"YouQualityUpdateNotification";
NSString *currentQualityLabel = @"N/A";

static void setButtonStyle(YTQTMButton *button) {
    button.titleLabel.numberOfLines = 3;
    [button setTitle:@"Auto" forState:UIControlStateNormal];
}

static void updateVolBoostLabel(UIButton *btn) {
    [btn setTitle:gainLabel() forState:UIControlStateNormal];
}

// ─── CORE AUDIO HOOKS (THE FIX) ──────────────────────────────────────────────

%hook HAMAudioEngineTrackRenderer
- (void)setVolume:(float)volume {
    %orig(volume * currentGain);
}
%end

%hook HAMSBARAudioTrackRenderer
- (void)setVolume:(float)volume {
    %orig(volume * currentGain);
}
- (void)setNormalizationCompensationGain:(float)gain {
    %orig(gain * currentGain);
}
%end

// ─── QUALITY LABEL LOGIC ─────────────────────────────────────────────────────

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

// ─── OVERLAY UI HOOKS ────────────────────────────────────────────────────────

%group Top
%hook YTMainAppControlsOverlayView

- (id)initWithDelegate:(id)delegate {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setButtonStyle(self.overlayButtons[TweakKey]);
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
    return self;
}

- (id)initWithDelegate:(id)delegate autoplaySwitchEnabled:(BOOL)autoplaySwitchEnabled {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setButtonStyle(self.overlayButtons[TweakKey]);
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
    return self;
}

%new
- (void)didPressVolBoost:(id)arg {
    saveGain(nextGain(currentGain));
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
}

%new
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    saveGain(1.0f);
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
}

%new
- (void)updateYouQualityButton:(id)arg {
    [self.overlayButtons[TweakKey] setTitle:currentQualityLabel forState:UIControlStateNormal];
}

%new
- (void)didPressYouQuality:(id)arg {
    YTMainAppVideoPlayerOverlayViewController *c = [self valueForKey:@"_eventsDelegate"];
    [c didPressVideoQuality:arg];
    [self updateYouQualityButton:nil];
}
%end
%end

%group Bottom
%hook YTInlinePlayerBarContainerView

- (id)init {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setButtonStyle(self.overlayButtons[TweakKey]);
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
    return self;
}

%new
- (void)didPressVolBoost:(id)arg {
    saveGain(nextGain(currentGain));
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
}

%new
- (void)updateYouQualityButton:(id)arg {
    [self.overlayButtons[TweakKey] setTitle:currentQualityLabel forState:UIControlStateNormal];
}

%new
- (void)didPressYouQuality:(id)arg {
    YTMainAppVideoPlayerOverlayViewController *c = [self.delegate valueForKey:@"_delegate"];
    [c didPressVideoQuality:arg];
    [self updateYouQualityButton:nil];
}
%end
%end

// ─── CONSTRUCTOR ──────────────────────────────────────────────────────────────

%ctor {
    currentGain = savedVolGain();

    // Initialize both buttons via YTVideoOverlay
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

    %init(Video);
    %init(Top);
    %init(Bottom);
    %init(_ungrouped); // Initialize the Renderer hooks
}