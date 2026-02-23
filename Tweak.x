#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#define TweakKey            @"YouQuality"
#define VolBoostKey         @"YouQualityVolBoost"
#define GainKey             @"YouQualityVolBoost-Gain"
#define PreviewMuteKey      @"YouQualityVolBoost-PreviewMute"
#define BlockPreviewKey     @"YouQualityBlockPreview"

static void applyGainImmediately();

// ─── Settings ─────────────────────────────────────────────────────────────────
static float currentGain        = 1.0f;
static BOOL previewMuteEnabled  = NO;   // default OFF
static BOOL blockPreviewEnabled = YES;  // default ON

static float loadGain() {
    float g = [[NSUserDefaults standardUserDefaults] floatForKey:GainKey];
    if (g < 1.0f) g = 1.0f;
    if (g > 4.0f) g = 4.0f;
    return g;
}

static BOOL loadPreviewMute() {
    NSNumber *val = [[NSUserDefaults standardUserDefaults] objectForKey:PreviewMuteKey];
    return val ? [val boolValue] : NO; // default OFF
}

static BOOL loadBlockPreview() {
    NSNumber *val = [[NSUserDefaults standardUserDefaults] objectForKey:BlockPreviewKey];
    return val ? [val boolValue] : YES; // default ON
}

static void saveGain(float gain) {
    if (gain < 1.0f) gain = 1.0f;
    if (gain > 4.0f) gain = 4.0f;
    currentGain = gain;
    [[NSUserDefaults standardUserDefaults] setFloat:gain forKey:GainKey];
    applyGainImmediately();
}

static float nextGain(float gain) {
    static const float steps[] = {1.0f, 1.5f, 2.0f, 2.5f, 3.0f, 3.5f, 4.0f};
    for (int i = 0; i < 7; i++)
        if (gain < steps[i] - 0.01f) return steps[i];
    return 1.0f;
}

static NSString *gainLabel() {
    int pct = (int)roundf(currentGain * 100.f);
    return [NSString stringWithFormat:@"%d%%", pct];
}

// ─── Interfaces ───────────────────────────────────────────────────────────────
@interface HAMSBARAudioTrackRenderer : NSObject
@property (nonatomic, assign) float volume;
- (void)updateGainAndRendererVolume;
@end

@interface MLHAMQueuePlayer : NSObject
- (BOOL)muted;
- (void)setMuted:(BOOL)muted;
@end

@interface YTLocalPlaybackController : NSObject
- (BOOL)isInlinePlaybackActive;
- (void)loadWithPlayerPlayback:(id)playback;
// CMTime (32 bytes) passed via hidden pointer on ARM64 — declared as void *
- (void)loadWithPlayerTransition:(id)transition playbackConfig:(id)config initialTime:(void *)time;
@end

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
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.7;
    [button setTitle:gainLabel() forState:UIControlStateNormal];
}

static void attachLongPress(YTQTMButton *button, id target) {
    if (!button) return;
    for (UIGestureRecognizer *gr in button.gestureRecognizers)
        if ([gr isKindOfClass:[UILongPressGestureRecognizer class]])
            [button removeGestureRecognizer:gr];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:target action:@selector(handleVolBoostLongPress:)];
    lp.minimumPressDuration = 0.6;
    [button addGestureRecognizer:lp];
}

// ─── Audio engine ─────────────────────────────────────────────────────────────
static __weak HAMSBARAudioTrackRenderer *sActiveRenderer = nil;
static float sBaseVolume = 1.0f;

static void applyGainImmediately() {
    HAMSBARAudioTrackRenderer *renderer = sActiveRenderer;
    if (!renderer) return;
    [renderer updateGainAndRendererVolume];
}

// ─── Preview mute state ───────────────────────────────────────────────────────
// MutePreview: track per-player allow/mute state.
// sAllowSound keyed by MLHAMQueuePlayer ptr — YES means user manually unmuted.
// sPrevWasMute1 — YES means last setMuted: call was YES (detects vol button pattern).
static NSMutableDictionary<NSString *, NSNumber *> *sAllowSound   = nil;
static NSMutableDictionary<NSString *, NSNumber *> *sPrevWasMute1 = nil;

// isPreview: mirrors MutePreview.js isPreview() — checks _stickySettings ivar.
// Preview players have nil stickySettings; real players have it set.
static BOOL isPreviewPlayer(id player) {
    @try {
        Ivar ivar = class_getInstanceVariable([player class], "_stickySettings");
        if (!ivar) return YES;
        id sticky = object_getIvar(player, ivar);
        return !sticky || (NSNull *)sticky == [NSNull null];
    } @catch (...) { return YES; }
}

// ─── Audio group ──────────────────────────────────────────────────────────────
%group Audio

%hook HAMSBARAudioTrackRenderer

// Existing vol boost — unchanged
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

// MutePreview.js: always block HAM setVolume for preview players.
// _audioDelegate ivar points to the owning MLHAMQueuePlayer.
- (void)setVolume:(float)volume {
    if (!previewMuteEnabled || volume <= 0.0f) { %orig; return; }
    @try {
        Ivar ivar = class_getInstanceVariable([self class], "_audioDelegate");
        if (!ivar) { %orig; return; }
        id delegate = object_getIvar(self, ivar);
        if (!delegate) { %orig; return; }
        if (!isPreviewPlayer(delegate)) { %orig; return; }
        return; // block HAM volume for previews — AVR is the real gate
    } @catch (...) { %orig; }
}

%end

// MutePreview.js setMuted: pattern:
//   YES  → system muted → mark prevWasMute1=YES, allowSound=NO
//   NO after YES → vol button → block (don't call %orig)
//   NO with no prior YES → manual unmute button → allowSound=YES
%hook MLHAMQueuePlayer

- (void)setMuted:(BOOL)muted {
    if (!previewMuteEnabled || !isPreviewPlayer(self)) { %orig; return; }

    NSString *ptr = [NSString stringWithFormat:@"%p", self];

    if (muted) {
        sPrevWasMute1[ptr] = @YES;
        sAllowSound[ptr]   = @NO;
        %orig;
        return;
    }

    if ([sPrevWasMute1[ptr] boolValue]) {
        sPrevWasMute1[ptr] = @NO;
        return; // vol button — block unmute, preview stays muted
    }

    // Manual unmute button
    sAllowSound[ptr] = @YES;
    %orig;
}

%end

// MutePreview.js AVR: block volume if no preview player has allowSound=YES
%hook AVSampleBufferAudioRenderer

- (void)setVolume:(float)volume {
    if (volume <= 0.0f) { %orig; return; }
    if (!previewMuteEnabled && !blockPreviewEnabled) { %orig; return; }
    __block BOOL anyAllowed = NO;
    [sAllowSound enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSNumber *v, BOOL *stop) {
        if ([v boolValue]) { anyAllowed = YES; *stop = YES; }
    }];
    if (!anyAllowed) return;
    %orig;
}

%end

%end // Audio

// ─── BlockPreview group ───────────────────────────────────────────────────────
// BlockPreview.js: drop loadWithPlayerPlayback/Transition if isInlinePlaybackActive
%group BlockPreview

%hook YTLocalPlaybackController

- (void)loadWithPlayerPlayback:(id)playback {
    if (!blockPreviewEnabled) { %orig; return; }
    if ([self isInlinePlaybackActive]) return;
    %orig;
}

- (void)loadWithPlayerTransition:(id)transition playbackConfig:(id)config initialTime:(void *)time {
    if (!blockPreviewEnabled) { %orig; return; }
    if ([self isInlinePlaybackActive]) return;
    %orig;
}

%end

%end // BlockPreview

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

%end // Video

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

%end // Top

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

%end // Bottom

// ─── Constructor ─────────────────────────────────────────────────────────────
%ctor {
    sAllowSound   = [NSMutableDictionary new];
    sPrevWasMute1 = [NSMutableDictionary new];

    currentGain         = loadGain();
    previewMuteEnabled  = loadPreviewMute();
    blockPreviewEnabled = loadBlockPreview();

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
    %init(BlockPreview);
    %init(Video);
    %init(Top);
    %init(Bottom);
}
