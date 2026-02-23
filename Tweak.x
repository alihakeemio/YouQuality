#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#define TweakKey            @"YouQuality"
#define VolBoostKey         @"YouQualityVolBoost"
#define GainKey             @"YouQualityVolBoost-Gain"
#define PreviewMuteKey      @"YouQualityPreviewMute"
#define BlockPreviewKey     @"YouQualityBlockPreview"

static const NSInteger YouQualitySettingsCategory = 'yqly';

static void applyGainImmediately();

// ─── Settings ─────────────────────────────────────────────────────────────────
static float currentGain        = 1.0f;
static BOOL previewMuteEnabled  = YES;
static BOOL blockPreviewEnabled = YES;

static float loadGain() {
    float g = [[NSUserDefaults standardUserDefaults] floatForKey:GainKey];
    if (g < 1.0f) g = 1.0f;
    if (g > 4.0f) g = 4.0f;
    return g;
}

static BOOL loadPreviewMute() {
    NSNumber *val = [[NSUserDefaults standardUserDefaults] objectForKey:PreviewMuteKey];
    return val ? [val boolValue] : YES;
}

static BOOL loadBlockPreview() {
    NSNumber *val = [[NSUserDefaults standardUserDefaults] objectForKey:BlockPreviewKey];
    return val ? [val boolValue] : YES;
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
- (void)setVolume:(float)volume;
@end

@interface MLHAMQueuePlayer : NSObject
- (BOOL)muted;
- (void)setMuted:(BOOL)muted;
@end

// CMTime is a 32-byte struct. On ARM64 structs > 16 bytes are passed via hidden
// pointer — we match that by declaring the parameter as a pointer (void *) so
// the compiler generates the correct calling convention, same fix as Frida.
@interface YTLocalPlaybackController : NSObject
- (BOOL)isInlinePlaybackActive;
- (void)loadWithPlayerPlayback:(id)playback;
- (void)loadWithPlayerTransition:(id)transition playbackConfig:(id)config initialTime:(void *)time;
- (void)resetWithStoppageReason:(NSInteger)reason;
@end

@interface YTSettingsCell : UITableViewCell
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

@interface YTSettingsGroupData (YouGroupSettings)
+ (NSMutableArray <NSNumber *> *)tweaks;
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

// ─── Preview state ────────────────────────────────────────────────────────────
// Keyed by MLHAMQueuePlayer pointer string.
// sAllowSound:    YES = user explicitly unmuted this preview player
// sPrevWasMute1:  YES = last setMuted: call was YES (used to detect vol button)
static NSMutableDictionary<NSString *, NSNumber *> *sAllowSound   = nil;
static NSMutableDictionary<NSString *, NSNumber *> *sPrevWasMute1 = nil;

// Mirrors MutePreview.js isPreview(): checks _stickySettings ivar directly.
// Preview players have no stickySettings (nil / null).
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

// Existing vol boost logic — unchanged
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
// HAM's _audioDelegate ivar is the owning MLHAMQueuePlayer.
// AVR is the real audio gate — HAM volume is just suppressed entirely.
- (void)setVolume:(float)volume {
    if (!previewMuteEnabled || volume <= 0.0f) { %orig; return; }
    @try {
        Ivar ivar = class_getInstanceVariable([self class], "_audioDelegate");
        if (!ivar) { %orig; return; }
        id delegate = object_getIvar(self, ivar);
        if (!delegate) { %orig; return; }
        if (!isPreviewPlayer(delegate)) { %orig; return; }
        // Preview player — block HAM volume unconditionally
        return;
    } @catch (...) { %orig; }
}

%end

// MutePreview.js setMuted: logic:
//   setMuted:YES  → system/YouTube muted → mark prevWasMute1, clear allowSound
//   setMuted:NO with prevWasMute1=YES → vol button pattern → block (don't call orig)
//   setMuted:NO with prevWasMute1=NO  → manual unmute button → set allowSound=YES
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

    // setMuted:NO
    if ([sPrevWasMute1[ptr] boolValue]) {
        // Vol button: preceded by setMuted:YES → block the unmute
        sPrevWasMute1[ptr] = @NO;
        return; // do NOT call %orig — preview stays muted
    }

    // Manual unmute button: no preceding YES → allow sound
    sAllowSound[ptr] = @YES;
    %orig;
}

%end

// MutePreview.js AVR setVolume: — block if no preview player has allowSound=YES
%hook AVSampleBufferAudioRenderer

- (void)setVolume:(float)volume {
    if (volume <= 0.0f) { %orig; return; }
    if (!previewMuteEnabled && !blockPreviewEnabled) { %orig; return; }

    __block BOOL anyAllowed = NO;
    [sAllowSound enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSNumber *v, BOOL *stop) {
        if ([v boolValue]) { anyAllowed = YES; *stop = YES; }
    }];
    if (!anyAllowed) return; // block
    %orig;
}

%end

%end // Audio

// ─── BlockPreview group ───────────────────────────────────────────────────────
// BlockPreview.js logic:
//   loadWithPlayerPlayback: → if isInlinePlaybackActive → drop call (block preview)
//   loadWithPlayerTransition:playbackConfig:initialTime: → same guard
//   resetWithStoppageReason: → clean up sAllowSound/sPrevWasMute1 for this player
//
// initialTime (CMTime, 32 bytes) is declared as void * to match ARM64 ABI
// (large structs passed via hidden pointer — same root cause as the Frida crash).
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

// Fires when a preview stops naturally (user scrolls away).
// Clean up state so stale entries don't accumulate.
// Note: keyed by YTLocalPlaybackController ptr here — this controller owns
// the MLHAMQueuePlayer but we can't cheaply get its ptr, so we clean both
// dicts with a prefix scan to remove any ptr that matches this controller.
- (void)resetWithStoppageReason:(NSInteger)reason {
    NSString *selfPtr = [NSString stringWithFormat:@"%p", self];
    // Best-effort cleanup: remove the entry matching this controller's address.
    // In practice YTLocalPlaybackController and its MLHAMQueuePlayer often share
    // the same address region — if not, entries will be cleaned by the next mute cycle.
    [sAllowSound   removeObjectForKey:selfPtr];
    [sPrevWasMute1 removeObjectForKey:selfPtr];
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

// ─── Settings group ───────────────────────────────────────────────────────────
%group Settings

%hook YTSettingsViewController

- (void)setSectionItems:(NSMutableArray *)sectionItems
            forCategory:(NSInteger)category
                  title:(NSString *)title
                   icon:(id)icon
       titleDescription:(NSString *)titleDescription
           headerHidden:(BOOL)headerHidden {
    %orig;
    if (category != YouQualitySettingsCategory) return;

    NSMutableArray *items = [NSMutableArray array];

    YTSettingsSectionItem *blockItem = [%c(YTSettingsSectionItem)
        switchItemWithTitle:@"Block Scroll Previews"
        titleDescription:@"Prevent videos from auto-playing while scrolling the feed"
        accessibilityIdentifier:nil
        switchOn:blockPreviewEnabled
        switchBlock:^BOOL(YTSettingsCell *cell, BOOL newValue) {
            blockPreviewEnabled = newValue;
            [[NSUserDefaults standardUserDefaults] setBool:newValue forKey:BlockPreviewKey];
            return YES;
        }
        settingItemId:0];
    [items addObject:blockItem];

    YTSettingsSectionItem *muteItem = [%c(YTSettingsSectionItem)
        switchItemWithTitle:@"Mute Scroll Previews"
        titleDescription:@"Keep preview audio muted (vol buttons won't unmute them)"
        accessibilityIdentifier:nil
        switchOn:previewMuteEnabled
        switchBlock:^BOOL(YTSettingsCell *cell, BOOL newValue) {
            previewMuteEnabled = newValue;
            [[NSUserDefaults standardUserDefaults] setBool:newValue forKey:PreviewMuteKey];
            return YES;
        }
        settingItemId:0];
    [items addObject:muteItem];

    [self setSectionItems:items
             forCategory:category
                   title:@"YouQuality"
                    icon:nil
        titleDescription:nil
            headerHidden:NO];
}

%end

// Register our category with YouGroupSettings so it appears in the Tweaks group
%hook YTSettingsGroupData

+ (NSMutableArray <NSNumber *> *)tweaks {
    NSMutableArray *tweaks = %orig;
    if (tweaks && ![tweaks containsObject:@(YouQualitySettingsCategory)])
        [tweaks addObject:@(YouQualitySettingsCategory)];
    return tweaks;
}

%end

// Fallback: if YouGroupSettings is absent, inject a standalone section
%hook YTAppSettingsGroupPresentationData

+ (NSArray *)orderedGroups {
    NSArray *groups = %orig;
    if ([%c(YTSettingsGroupData) respondsToSelector:@selector(tweaks)]) return groups;
    @try {
        NSMutableArray *mutable = [groups mutableCopy];
        id group = [[%c(YTSettingsGroupData) alloc] initWithGroupType:YouQualitySettingsCategory];
        [mutable insertObject:group atIndex:0];
        return mutable;
    } @catch (...) {}
    return groups;
}

%end

// Populate the section when the settings screen opens
%hook YTSettingsSectionItemManager

- (void)updateSectionForCategory:(NSInteger)category withEntry:(id)entry {
    if (category != YouQualitySettingsCategory) { %orig; return; }
    YTSettingsViewController *vc = [self valueForKey:@"_settingsViewControllerDelegate"];
    if (vc) {
        [vc setSectionItems:[NSMutableArray array]
                forCategory:category
                      title:@"YouQuality"
                       icon:nil
           titleDescription:nil
               headerHidden:NO];
    }
}

%end

%end // Settings

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
    %init(Settings);
    %init(Top);
    %init(Bottom);
}
