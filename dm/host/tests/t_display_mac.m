// Native per-build display preferences, without opening a game or a window.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#include <assert.h>
#define DM_GAME_ID "display-test"
#define DM_GAME_NAME "Display Test"
static char build[33] = "test-build-a";
static const char *dm_main_build(void) { return build; }
static int qualified;
int dm_display_aspect_qualified(void) { return qualified; }
void dm_display_set_wide(int enabled) { (void)enabled; }
static NSWindow *g_win;
static CAMetalLayer *g_layer;
#include "../display_mac.inc"

int main(void) { @autoreleasepool {
    NSString *suite = [@"org.nxnative.display.test." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:suite];
    assert(!display_saved(preferences, @"fullscreen"));
    [preferences setBool:YES forKey:display_preference_key(@"fullscreen")];
    assert(display_saved(preferences, @"fullscreen"));
    strcpy(build, "test-build-b"); assert(!display_saved(preferences, @"fullscreen"));
    strcpy(build, "test-build-a");
    for (id malformed in @[@"1", @"true", @2, @[], @{}]) {
        [preferences setObject:malformed forKey:display_preference_key(@"fullscreen")];
        assert(!display_saved(preferences, @"fullscreen"));
    }
    [preferences setBool:YES forKey:display_preference_key(@"fullscreen")];
    [preferences setBool:YES forKey:display_preference_key(@"wide")];
    unsetenv("DM_FULLSCREEN"); unsetenv("DM_DISPLAY_WIDE");
    display_load(preferences);
    assert(display_explicit_on("DM_FULLSCREEN"));
    assert(!getenv("DM_DISPLAY_WIDE")); // unqualified mod cannot be enabled by saved prefs
    qualified = 1; display_load(preferences);
    assert(display_explicit_on("DM_DISPLAY_WIDE")); // qualified per-build preference activates the live-capable mode
    setenv("DM_DISPLAY_WIDE", "0", 1); display_load(preferences);
    assert(!display_explicit_on("DM_DISPLAY_WIDE")); // explicit developer override still wins
    setenv("DM_FULLSCREEN", "0", 1); display_load(preferences);
    assert(!display_explicit_on("DM_FULLSCREEN")); // explicit off is not fullscreen
    [preferences removePersistentDomainForName:suite];
    puts("Mac display preferences: game/build scope, strict values and unavailable-mod gate passed");
    return 0;
} }
