// Exercise the production AppKit capability classifier without a window/game.
#import <AppKit/AppKit.h>
#include <stdatomic.h>
#include <stdio.h>
@interface RefreshFixture : NSObject
@property NSInteger maximumFramesPerSecond;
@property NSTimeInterval minimumRefreshInterval, maximumRefreshInterval;
@end
@implementation RefreshFixture
@end
#include "../../host/mac_screen_refresh.inc"
static int checks, failed;
#define CHECK(name, ok) do { checks++; if (!(ok)) { failed++; printf("FAIL: %s\n", name); } } while (0)
int main(void) { @autoreleasepool {
    RefreshFixture *screen = [RefreshFixture new];
    const struct { NSInteger fps; double min, max; int variable; } cases[] = {
        {120, 1.0/120, 1.0/24, 1}, {120, 1.0/120, 1.0/120, 0},
        {60, 1.0/60, 1.0/60, 0}, {0, 0, 0, 0},
        {120, 0, 1.0/24, 0}, {120, 1.0/24, 1.0/120, 0}
    };
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        screen.maximumFramesPerSecond = cases[i].fps;
        screen.minimumRefreshInterval = cases[i].min; screen.maximumRefreshInterval = cases[i].max;
        screen_refresh((NSScreen *)(id)screen);
        CHECK("production classifier uses the refresh interval range", front_screen_variable_refresh() == cases[i].variable);
        CHECK("production screen snapshot updates its maximum rate", front_screen_max_fps() == cases[i].fps);
    }
    int fps = front_screen_max_fps(), variable = front_screen_variable_refresh();
    screen_refresh(nil);
    CHECK("a missing screen preserves the last usable snapshot", front_screen_max_fps() == fps && front_screen_variable_refresh() == variable);
    printf("Mac screen refresh: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
