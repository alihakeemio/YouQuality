#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>
#import <YouTubeHeader/YTSettingsPickerViewController.h>
#import <YouTubeHeader/YTSettingsViewController.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <PSHeader/Misc.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <math.h>

// ─── Keys ─────────────────────────────────────────────────────────────────────
#define TweakKey      @"YouQuality"
#define VolBoostKey   @"YouQualityVolBoost"
#define GainKey       @"YouQualityVolBoost-Gain"
#define LabelModeKey  @"YouQualityLabelMode"   // 0 = %, 1 = dB

static const NSInteger YouQualitySection = 0x596F5551;

// ─── Compilation Fixes ────────────────────────────────────────────────────────

// Fix 1: Undefine LOC before defining it to prevent macro redefinition error
#undef LOC
#define LOC(x) [YouQualityBundle() localizedStringForKey:x value:x table:nil]

// Fix 2: Declare the type property for YTSettingsGroupData
@interface YTSettingsGroupData : NSObject
@property (nonatomic, assign) NSInteger type;
@end

// ─── Bundle helper ────────────────────────────────────────────────────────────
static NSBundle *YouQualityBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"YouQuality" ofType:@"bundle"];
        bundle = [NSBundle bundleWithPath:path ?: PS_ROOT_PATH_NS(@"/Library/Application Support/YouQuality.bundle")];
    });
    return bundle;
}

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

@interface YTSettingsSectionItemManager (YouQuality)
- (void)updateYouQualitySectionWithEntry:(id)entry;
@end

// ─── Shared globals & Audio Logic ─────────────────────────────────────────────
NSString *YouQualityUpdateNotification = @"YouQualityUpdateNotification";
NSString *currentQualityLabel = @"N/A";

static BOOL isDBMode() {
    return [[NSUserDefaults standardUserDefaults] integerForKey:LabelModeKey] == 1;
}

static float currentGain = 1.0f;
static NSPointerArray *gBoostEQNodes = nil;

static float linearGainTodB(float gain) {
    if (gain <= 1.0f) return 0.0f;
    return 20.0f * log10f(gain);
}

static void updateAllEQGains() {
    float dB = linearGainTodB(currentGain);
    if (gBoostEQNodes) {
        [gBoostEQNodes compact];
        for (AVAudioUnitEQ *eq in gBoostEQNodes) {
            if (eq) eq.globalGain = dB;
        }
    }
}

static float loadGain() {
    float g = [[NSUserDefaults standardUserDefaults] floatForKey:GainKey];
    if (g < 1.0f) g = 1.0f;
    if (g > 4.0f) g = 4.0f;
    return g;
}

static void saveGain(float gain) {
    if (gain < 1.0f) gain = 1.0f;
    if (gain > 4.0f) gain = 4.0f;
    currentGain = gain;
    [[NSUserDefaults standardUserDefaults] setFloat:gain forKey:GainKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    updateAllEQGains();
}

static float nextGain(float gain) {
    static const float steps[] = {1.0f, 1.5f, 2.0f, 2.5f, 3.0f, 3.5f, 4.0f};
    for (int i = 0; i < 7; i++)
        if (gain < steps[i] - 0.01f) return steps[i];
    return 1.0f;
}

static NSString *gainLabel() {
    if (isDBMode()) {
        float dB = linearGainTodB(currentGain);
        int dBint = (int)roundf(dB);
        return dBint == 0 ? @"0dB" : [NSString stringWithFormat:@"+%ddB", dBint];
    }
    int pct = (int)roundf(currentGain * 100.f);
    return [NSString stringWithFormat:@"%d%%", pct];
}

static void setQualityButtonStyle(YTQTMButton *button) {
    button.titleLabel.numberOfLines = 3;
    [button setTitle:@"Auto" forState:UIControlStateNormal];
}

static void updateVolBoostButtonLabel(YTQTMButton *button) {
    if (!button) return;
    button.titleLabel.numberOfLines = 2;
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

// ─── AUDIO ENGINE BOOST HOOKS ────────────────────────────────────────────────

%group Audio

// Force standard rendering to bypass 1.0 volume limit
%hook YTIHamplayerColdConfig
- (BOOL)mediaEngineClientEnableIosPassthroughRendering { return NO; }
%end
%hook MLHamplayerConfig
- (BOOL)mediaEngineClientEnableIosPassthroughRendering { return NO; }
%end
%hook YTColdConfig
- (BOOL)mediaEngineClientEnableIosPassthroughRendering { return NO; }
%end

// Inject EQ node into standard rendering graph
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
        %orig(node1, eq, bus1, 0, format);
        %orig(eq, node2, 0, bus2, format);
        return;
    }
    %orig;
}
%end
%end

// ─── In-app YouTube Settings ──────────────────────────────────────────────────
%group Settings

%hook YTSettingsGroupData
- (NSArray <NSNumber *> *)orderedCategories {
    if (self.type != 1 || class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks)))
        return %orig;
    NSMutableArray *cats = %orig.mutableCopy;
    [cats insertObject:@(YouQualitySection) atIndex:0];
    return cats.copy;
}
%end

%hook YTAppSettingsPresentationData
+ (NSArray <NSNumber *> *)settingsCategoryOrder {
    NSArray *order = %orig;
    NSUInteger idx = [order indexOfObject:@(1)]; // 1 = General
    if (idx == NSNotFound) return order;
    NSMutableArray *mutable = order.mutableCopy;
    [mutable insertObject:@(YouQualitySection) atIndex:idx + 1];
    return mutable.copy;
}
%end

%hook YTSettingsSectionItemManager
%new(v@:@)
- (void)updateYouQualitySectionWithEntry:(id)entry {
    NSMutableArray *items = [NSMutableArray array];
    Class Item = %c(YTSettingsSectionItem);
    YTSettingsViewController *vc = [self valueForKey:@"_settingsViewControllerDelegate"];

    YTSettingsSectionItem *modePicker = [Item
        itemWithTitle:LOC(@"VOL_BOOST_LABEL_MODE")
        accessibilityIdentifier:nil
        detailTextBlock:^NSString *() {
            return [[NSUserDefaults standardUserDefaults] integerForKey:LabelModeKey] == 1 ? LOC(@"MODE_DB") : LOC(@"MODE_PCT");
        }
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
            NSInteger sel = [[NSUserDefaults standardUserDefaults] integerForKey:LabelModeKey];
            NSArray *rows = @[
                [Item checkmarkItemWithTitle:LOC(@"MODE_PCT")
                    titleDescription:LOC(@"MODE_PCT_DESC")
                    selectBlock:^BOOL (YTSettingsCell *c, NSUInteger a) {
                        [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:LabelModeKey];
                        [vc reloadData];
                        return YES;
                    }],
                [Item checkmarkItemWithTitle:LOC(@"MODE_DB")
                    titleDescription:LOC(@"MODE_DB_DESC")
                    selectBlock:^BOOL (YTSettingsCell *c, NSUInteger a) {
                        [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:LabelModeKey];
                        [vc reloadData];
                        return YES;
                    }]
            ];
            YTSettingsPickerViewController *picker = [[%c(YTSettingsPickerViewController) alloc]
                initWithNavTitle:LOC(@"VOL_BOOST_LABEL_MODE")
                pickerSectionTitle:nil
                rows:rows
                selectedItemIndex:sel
                parentResponder:[self parentResponder]];
            [vc pushViewController:picker];
            return YES;
        }];
    [items addObject:modePicker];

    if ([vc respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)])
        [vc setSectionItems:items forCategory:YouQualitySection title:@"YouQuality" icon:nil titleDescription:nil headerHidden:NO];
    else
        [vc setSectionItems:items forCategory:YouQualitySection title:@"YouQuality" titleDescription:nil headerHidden:NO];
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == (NSUInteger)YouQualitySection) {
        [self updateYouQualitySectionWithEntry:entry];
        return;
    }
    %orig;
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

    %init(Audio);
    %init(Video);
    %init(Settings);
    %init(Top);
    %init(Bottom);
}