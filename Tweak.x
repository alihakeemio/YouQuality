#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#define TweakKey          @"YouQuality"
#define VolBoostKey       @"YouQualityVolBoost"
#define GainKey           @"YouQualityVolBoost-Gain"
#define PreviewMuteKey    @"YouQualityVolBoost-PreviewMute"
#define BlockPreviewKey   @"YouQualityVolBoost-BlockPreview"

static void applyGainImmediately();

// ─── Settings ─────────────────────────────────────────────────────────────────
static float currentGain         = 1.0f;
static BOOL  previewMuteEnabled  = NO;
static BOOL  blockPreviewEnabled = YES;

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
// Frida-confirmed detection logic:
//   isPreview  = MLHAMQueuePlayer._stickySettings == nil
//   Vol button = setMuted:0 with _muted=YES, then setMuted:0 with _muted=NO
//   Manual btn = single setMuted:0 with _muted=NO (no prior _muted=YES call)
//
// sAllowSound[ptr]: toggled by manual unmute/mute — persists across vol presses
// HAM setVolume:>0 always blocked for preview players unless sAllowSound==YES

static NSMutableDictionary *sAllowSound = nil; // ptr string -> @YES/@NO
static NSMutableDictionary *sPrevMuted  = nil; // ptr string -> @YES / NSNull

static BOOL isPreviewPlayer(MLHAMQueuePlayer *player) {
    Ivar ivar = class_getInstanceVariable([player class], "_stickySettings");
    if (!ivar) return YES;
    id s = object_getIvar(player, ivar);
    return (s == nil);
}

// ─── Audio group ──────────────────────────────────────────────────────────────
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

- (void)setVolume:(float)volume {
    if (volume == 0 || !previewMuteEnabled) { %orig; return; }
    Ivar ivar = class_getInstanceVariable([self class], "_audioDelegate");
    if (ivar) {
        id delegate = object_getIvar(self, ivar);
        if (delegate) {
            Class cls = NSClassFromString(@"MLHAMQueuePlayer");
            if (cls && [delegate isKindOfClass:cls]) {
                MLHAMQueuePlayer *player = (MLHAMQueuePlayer *)delegate;
                if (isPreviewPlayer(player)) {
                    NSString *ptr = [NSString stringWithFormat:@"%p", (__bridge void *)player];
                    if (![sAllowSound[ptr] boolValue]) return;
                }
            }
        }
    }
    %orig;
}

%end

%hook MLHAMQueuePlayer

- (void)setMuted:(BOOL)muted {
    if (!previewMuteEnabled) { %orig; return; }

    NSString *ptr = [NSString stringWithFormat:@"%p", (__bridge void *)self];

    if (!isPreviewPlayer(self)) {
        // Real video — clear state, pass through
        sAllowSound[ptr] = @NO;
        sPrevMuted[ptr]  = [NSNull null];
        %orig;
        return;
    }

    if (muted) {
        // Explicit mute — reset prev tracking
        sPrevMuted[ptr] = [NSNull null];
        %orig;
        return;
    }

    // setMuted:0 on a preview player
    BOOL playerMuted = [self muted]; // current _muted before the call
    id   prev        = sPrevMuted[ptr];
    BOOL prevWasTrue = (prev && ![prev isEqual:[NSNull null]] && [prev boolValue]);

    if (playerMuted && !prevWasTrue) {
        // _muted=YES first call — could be start of vol-button sequence, track it
        sPrevMuted[ptr] = @YES;
        %orig;
    } else if (!playerMuted && prevWasTrue) {
        // _muted=NO after _muted=YES = vol button second call — BLOCK
        sPrevMuted[ptr] = [NSNull null];
        return;
    } else if (!playerMuted) {
        // _muted=NO with no prior = manual mute/unmute toggle
        sPrevMuted[ptr] = [NSNull null];
        sAllowSound[ptr] = [sAllowSound[ptr] boolValue] ? @NO : @YES;
        %orig;
    } else {
        sPrevMuted[ptr] = [NSNull null];
        %orig;
    }
}

%end

%end // Audio

// ─── BlockPreview group ───────────────────────────────────────────────────────
// Hooks YTLocalPlaybackController at the earliest inline-playback entry points.
// Frida confirmed playerViewLayout fires first with isInlinePlaybackActive=YES,
// blocking it (and the chain below it) prevents any black screen or dot.

%group BlockPreview

%hook YTLocalPlaybackController

- (void)playerViewLayout {
    if (blockPreviewEnabled && [self isInlinePlaybackActive]) return;
    %orig;
}

- (void)fetchPlayerDataAndResolveVideo {
    if (blockPreviewEnabled && [self isInlinePlaybackActive]) return;
    %orig;
}

- (void)recordUserIntentToPlayAtTime:(id)time withPlaybackData:(id)data {
    if (blockPreviewEnabled && [self isInlinePlaybackActive]) return;
    %orig;
}

- (void)loadOrActivateContentSequence {
    if (blockPreviewEnabled && [self isInlinePlaybackActive]) return;
    %orig;
}

- (void)prepareToLoadWithPlayerTransition:(id)transition expectedLayout:(id)layout {
    if (blockPreviewEnabled && [self isInlinePlaybackActive]) return;
    %orig;
}

- (void)loadWithPlayerPlayback:(id)playback {
    if (blockPreviewEnabled && [self isInlinePlaybackActive]) return;
    %orig;
}

- (void)loadWithPlayerTransition:(id)transition playbackConfig:(id)config initialTime:(id)time {
    if (blockPreviewEnabled && [self isInlinePlaybackActive]) return;
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

%end

// ─── Top overlay ──────────────────────────────────────────────────────────────
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

// ─── Settings change observer ─────────────────────────────────────────────────
static void settingsChanged(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object,
                            CFDictionaryRef userInfo) {
    [[NSUserDefaults standardUserDefaults] synchronize];
    previewMuteEnabled  = loadPreviewMute();
    blockPreviewEnabled = loadBlockPreview();
}

// ─── Constructor ──────────────────────────────────────────────────────────────
%ctor {
    sAllowSound = [NSMutableDictionary new];
    sPrevMuted  = [NSMutableDictionary new];

    currentGain         = loadGain();
    previewMuteEnabled  = loadPreviewMute();
    blockPreviewEnabled = loadBlockPreview();

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, settingsChanged,
        CFSTR("com.ps.youqualityvolboost/settingschanged"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately
    );

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
