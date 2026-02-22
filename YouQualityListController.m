// YouQualityListController.m
// Preferences pane controller — validates custom gain field

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

#define PREF_FILE @"/var/mobile/Library/Preferences/com.ps.youquality.plist"

@interface YouQualityRootListController : PSListController
@end

@implementation YouQualityRootListController

- (NSArray *)specifiers {
    if (!_specifiers)
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.properties[@"key"];

    if ([key isEqualToString:@"volGainCustom"]) {
        float g = [value floatValue];
        if (g < 100.f || g > 400.f) {
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"Invalid Value"
                message:@"Custom gain must be between 100% and 400%."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        [super setPreferenceValue:@(g) specifier:specifier];
        NSMutableDictionary *prefs =
            [[NSDictionary dictionaryWithContentsOfFile:PREF_FILE] mutableCopy]
            ?: [NSMutableDictionary new];
        prefs[@"volGain"] = @(g);
        [prefs writeToFile:PREF_FILE atomically:YES];
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (CFStringRef)@"com.ps.youquality/reload",
            NULL, NULL, YES);
        return;
    }

    [super setPreferenceValue:value specifier:specifier];
}

@end