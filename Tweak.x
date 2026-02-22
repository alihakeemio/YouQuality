#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>

#define TweakKey    @"YouQuality"
#define VolBoostKey @"YouQualityVolBoost"

// ─── VOLUME BOOST STATE & EQ LOGIC ───────────────────────────────────────────

static float currentGain = 1.0f;

// Use a weak pointer array to prevent memory leaks when engines are destroyed
static NSPointerArray *gBoostEQNodes = nil;

static float linearGainTodB(float gain) {
    if (gain <= 1.0f) return 0.0f;
    return 20.0f * log10f(gain);
}

static void updateAllEQGains() {
    float dB = linearGainTodB(currentGain);
    if (gBoostEQNodes) {
        [gBoostEQNodes compact]; // Clean up deallocated nodes
        for (AVAudioUnitEQ *eq in gBoostEQNodes) {
            if (eq) eq.globalGain = dB;
        }
    }
}

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

static void saveGainAndUpdateEQ(float gain) {
    currentGain = gain;
    [[NSUserDefaults standardUserDefaults] setFloat:gain forKey:@"YouQualityVolBoost-Gain"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    updateAllEQGains();
}

static NSString *gainLabel() {
    return [NSString stringWithFormat:@"%d%%", (int)roundf(currentGain * 100.f)];
}

// ─── YOUQUALITY STATE & LOGIC ────────────────────────────────────────────────

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


// ─── AUDIO ENGINE & SBAR DISABLER (THE REAL FIX) ──────────────────────────────

%group Audio

// 1. Nuke Passthrough Rendering to force YouTube to use AVAudioEngine
%hook YTIHamplayerColdConfig
- (BOOL)mediaEngineClientEnableIosPassthroughRendering { return NO; }
%end

%hook MLHamplayerConfig
- (BOOL)mediaEngineClientEnableIosPassthroughRendering { return NO; }
%end

%hook YTColdConfig
- (BOOL)mediaEngineClientEnableIosPassthroughRendering { return NO; }
%end


// 2. Secretly intercept ANY node trying to connect to the Output Hardware
%hook AVAudioEngine

- (void)connect:(AVAudioNode *)node1 to:(AVAudioNode *)node2 format:(AVAudioFormat *)format {
    if (node2 == self.outputNode) {
        if (!gBoostEQNodes) gBoostEQNodes = [NSPointerArray weakObjectsPointerArray];
        
        AVAudioUnitEQ *eq = nil;
        for (AVAudioUnitEQ *e in gBoostEQNodes) {
            if (e.engine == self) { eq = e; break; }
        }
        
        if (!eq) {
            eq = [[AVAudioUnitEQ alloc] initWithNumberOfBands:0];
            eq.globalGain = linearGainTodB(currentGain);
            [self attachNode:eq];
            [gBoostEQNodes addPointer:(__bridge void *)eq];
        }
        
        // Rewire: Source Node -> Our EQ -> Hardware Output
        %orig(node1, eq, format);
        %orig(eq, node2, format);
        return;
    }
    %orig;
}

- (void)connect:(AVAudioNode *)node1 to:(AVAudioNode *)node2 fromBus:(AVAudioNodeBus)bus1 toBus:(AVAudioNodeBus)bus2 format:(AVAudioFormat *)format {
    if (node2 == self.outputNode) {
        if (!gBoostEQNodes) gBoostEQNodes = [NSPointerArray weakObjectsPointerArray];
        
        AVAudioUnitEQ *eq = nil;
        for (AVAudioUnitEQ *e in gBoostEQNodes) {
            if (e.engine == self) { eq = e; break; }
        }
        
        if (!eq) {
            eq = [[AVAudioUnitEQ alloc] initWithNumberOfBands:0];
            eq.globalGain = linearGainTodB(currentGain);
            [self attachNode:eq];
            [gBoostEQNodes addPointer:(__bridge void *)eq];
        }
        
        // Rewire explicitly via buses
        %orig(node1, eq, bus1, 0, format);
        %orig(eq, node2, 0, bus2, format);
        return;
    }
    %orig;
}
%end
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

// ─── CONSTRUCTOR ──────────────────────────────────────────────────────────────

%ctor {
    currentGain = savedVolGain();

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