#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>
#import <AVFoundation/AVFoundation.h>

#define TweakKey  @"YouQuality"
#define PREF_FILE @"/var/mobile/Library/Preferences/com.ps.youquality.plist"

// ─── Volume booster prefs ─────────────────────────────────────────────────────
static NSDictionary *prefs() {
    return [NSDictionary dictionaryWithContentsOfFile:PREF_FILE] ?: @{};
}
static BOOL volBoostEnabled() {
    id v = prefs()[@"volBoostEnabled"];
    return v ? [v boolValue] : YES;
}
static float savedVolGain() {
    id v = prefs()[@"volGain"];
    float g = v ? [v floatValue] : 100.0f;
    if (g < 100.0f) g = 100.0f;
    if (g > 400.0f) g = 400.0f;
    return g;
}

// ─── Gain state ───────────────────────────────────────────────────────────────
static float currentGain = 1.0f; // 1.0 = 100%

static float nextGain(float gain) {
    static const int steps[] = {100, 125, 150, 175, 200, 250, 300, 350, 400};
    int pct = (int)roundf(gain * 100.f);
    for (int i = 0; i < 9; i++) if (pct < steps[i]) return steps[i] / 100.f;
    return 1.0f;
}

static void applyGain(float gain) {
    currentGain = gain;
    NSMutableDictionary *p = [prefs() mutableCopy] ?: [NSMutableDictionary new];
    p[@"volGain"] = @(gain * 100.f);
    [p writeToFile:PREF_FILE atomically:YES];
}



// ─── Forward declarations ─────────────────────────────────────────────────────
@interface YTMainAppControlsOverlayView (YouQuality)
- (void)didPressYouQuality:(id)arg;
- (void)updateYouQualityButton:(id)arg;
- (void)didPressVolBoost:(id)sender;
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr;
@end

@interface YTInlinePlayerBarContainerView (YouQuality)
- (void)didPressYouQuality:(id)arg;
- (void)updateYouQualityButton:(id)arg;
- (void)didPressVolBoost:(id)sender;
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr;
@end

// ─── Original globals ─────────────────────────────────────────────────────────
NSString *YouQualityUpdateNotification = @"YouQualityUpdateNotification";
NSString *currentQualityLabel = @"N/A";

// ─── Vol boost button helpers ─────────────────────────────────────────────────
static const NSInteger kVolBoostTag = 0xB007;

static YTQTMButton *makeVolBoostButton(id target) {
    YTQTMButton *btn = [YTQTMButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13, *)) {
        [btn setImage:[UIImage systemImageNamed:@"mic"] forState:UIControlStateNormal];
        btn.tintColor = UIColor.whiteColor;
    } else {
        btn.titleLabel.numberOfLines = 2;
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        [btn setTitle:@"MIC\n100%" forState:UIControlStateNormal];
        [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    }
    btn.accessibilityLabel = @"Volume Boost";
    [btn addTarget:target action:@selector(didPressVolBoost:) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:target action:@selector(handleVolBoostLongPress:)];
    lp.minimumPressDuration = 0.5;
    [btn addGestureRecognizer:lp];
    return btn;
}

static void refreshVolBoostBtn(YTQTMButton *btn) {
    if (!btn) return;
    int pct = (int)roundf(currentGain * 100.f);
    if (@available(iOS 13, *)) {
        [btn setImage:[UIImage systemImageNamed:pct > 100 ? @"mic.fill" : @"mic"] forState:UIControlStateNormal];
        btn.tintColor = pct > 100 ? UIColor.systemYellowColor : UIColor.whiteColor;
        btn.accessibilityValue = [NSString stringWithFormat:@"%d%%", pct];
    } else {
        [btn setTitle:[NSString stringWithFormat:@"MIC\n%d%%", pct] forState:UIControlStateNormal];
    }
}

static void insertVolBoostBtn(UIView *anchor, id target) {
    if (!volBoostEnabled() || !anchor || !anchor.superview) return;
    YTQTMButton *vb = makeVolBoostButton(target);
    vb.tag = kVolBoostTag;
    [anchor.superview insertSubview:vb aboveSubview:anchor];
    vb.frame = CGRectMake(anchor.frame.origin.x - 44, anchor.frame.origin.y, 40, 40);
}

// ─── Original button style helper ─────────────────────────────────────────────
static void setButtonStyle(YTQTMButton *button) {
    button.titleLabel.numberOfLines = 3;
    [button setTitle:@"Auto" forState:UIControlStateNormal];
}

// ─── Video group ─────────────────────────────────────────────────────────────
%group Video

// AVAudioMixerNode hook — inside a group so %init(Video) registers it.
// outputVolume accepts values above 1.0, giving true boost beyond 100%.
%hook AVAudioMixerNode

- (void)setOutputVolume:(float)volume {
    %orig(volBoostEnabled() ? volume * currentGain : volume);
}

%end

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

// ─── Top group ────────────────────────────────────────────────────────────────
%group Top

%hook YTMainAppControlsOverlayView

- (id)initWithDelegate:(id)delegate {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setButtonStyle(self.overlayButtons[TweakKey]);
    insertVolBoostBtn(self.overlayButtons[TweakKey], self);
    return self;
}

- (id)initWithDelegate:(id)delegate autoplaySwitchEnabled:(BOOL)autoplaySwitchEnabled {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setButtonStyle(self.overlayButtons[TweakKey]);
    insertVolBoostBtn(self.overlayButtons[TweakKey], self);
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
- (void)didPressVolBoost:(id)sender {
    if (!volBoostEnabled()) return;
    applyGain(nextGain(currentGain));
    refreshVolBoostBtn((YTQTMButton *)[self viewWithTag:kVolBoostTag]);
}

%new(v@:@)
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    applyGain(1.0f);
    refreshVolBoostBtn((YTQTMButton *)[self viewWithTag:kVolBoostTag]);
}

%end

%end

// ─── Bottom group ─────────────────────────────────────────────────────────────
%group Bottom

%hook YTInlinePlayerBarContainerView

- (id)init {
    self = %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateYouQualityButton:) name:YouQualityUpdateNotification object:nil];
    setButtonStyle(self.overlayButtons[TweakKey]);
    insertVolBoostBtn(self.overlayButtons[TweakKey], self);
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
- (void)didPressVolBoost:(id)sender {
    if (!volBoostEnabled()) return;
    applyGain(nextGain(currentGain));
    refreshVolBoostBtn((YTQTMButton *)[self viewWithTag:kVolBoostTag]);
}

%new(v@:@)
- (void)handleVolBoostLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    applyGain(1.0f);
    refreshVolBoostBtn((YTQTMButton *)[self viewWithTag:kVolBoostTag]);
}

%end

%end

// ─── Constructor ──────────────────────────────────────────────────────────────
%ctor {
    currentGain = savedVolGain() / 100.f;
    initYTVideoOverlay(TweakKey, @{
        AccessibilityLabelKey: @"Quality",
        SelectorKey: @"didPressYouQuality:",
        AsTextKey: @YES
    });
    %init(Video);
    %init(Top);
    %init(Bottom);
}
