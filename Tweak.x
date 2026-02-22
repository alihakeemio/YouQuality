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

@interface HAMSBARAudioTrackRenderer : NSObject
@property(nonatomic) float normalizationCompensationGain;
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

// ─── Audio boost — definitive implementation ──────────────────────────────────
// Confirmed by Apple developer forums: the ONLY working way to boost volume
// in AVAudioEngine above 1.0 is AVAudioUnitEQ.globalGain (-96 to +24 dB).
// AVAudioPlayerNode.volume has no effect. AVAudioMixerNode volume crashes.
//
// Strategy: hook AVAudioEngine.startAndReturnError: — before the engine starts,
// inject an AVAudioUnitEQ node between mainMixerNode and outputNode.
// globalGain = 20 * log10(linearGain) converts our multiplier to dB.
// Store all injected EQ nodes so gain changes update them immediately.
//
// This covers the AVAudioEngine path (HAMAudioEngineTrackRenderer).
// For the SBAR path (HAMSBARAudioTrackRenderer), also hook
// setNormalizationCompensationGain: — if normalization is active this
// multiplier is applied before writing to the renderer, so we get some boost
// even though AVSampleBufferAudioRenderer itself clamps to 1.0.

#import <AVFoundation/AVFoundation.h>
#import <math.h>

// All EQ nodes we've injected, so gain changes propagate instantly
static NSMutableArray *gBoostEQNodes = nil;

static float linearGainTodB(float gain) {
    if (gain <= 1.0f) return 0.0f;
    return 20.0f * log10f(gain);
}

static void updateAllEQGains() {
    float dB = linearGainTodB(currentGain);
    for (AVAudioUnitEQ *eq in gBoostEQNodes) {
        eq.globalGain = dB;
    }
}

// Override saveGain to also update EQ nodes
static void saveGainAndUpdateEQ(float gain) {
    currentGain = gain;
    [[NSUserDefaults standardUserDefaults] setFloat:gain forKey:@\"YouQualityVolBoost-Gain\"];
    updateAllEQGains();
}

%group Audio

%hook AVAudioEngine

- (BOOL)startAndReturnError:(NSError **)error {
    if (!gBoostEQNodes) gBoostEQNodes = [NSMutableArray new];

    // Check if we already injected an EQ into this engine instance
    BOOL alreadyInjected = NO;
    for (AVAudioUnitEQ *eq in gBoostEQNodes) {
        if (eq.engine == self) { alreadyInjected = YES; break; }
    }

    if (!alreadyInjected) {
        AVAudioUnitEQ *eq = [[AVAudioUnitEQ alloc] initWithNumberOfBands:0];
        eq.globalGain = linearGainTodB(currentGain);
        eq.bypass = NO;

        AVAudioMixerNode *mixer = self.mainMixerNode;
        AVAudioOutputNode *output = self.outputNode;

        // Rewire: mixer -> EQ -> output
        [self attachNode:eq];
        [self disconnectNodeOutput:mixer];
        [self connect:mixer to:eq format:nil];
        [self connect:eq to:output format:nil];

        [gBoostEQNodes addObject:eq];
    }

    return %orig;
}

%end

// SBAR path fallback — normalizationCompensationGain is a float multiplier
// applied before writing to AVSampleBufferAudioRenderer. Partial boost only.
%hook HAMSBARAudioTrackRenderer

- (void)setNormalizationCompensationGain:(float)gain {
    %orig(gain * currentGain);
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
    saveGainAndUpdateEQ(nextGain(currentGain));
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
}

%new(v@:@)
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    saveGainAndUpdateEQ(1.0f);
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
    saveGainAndUpdateEQ(nextGain(currentGain));
    updateVolBoostLabel(self.overlayButtons[VolBoostKey]);
}

%new(v@:@)
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    saveGainAndUpdateEQ(1.0f);
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
