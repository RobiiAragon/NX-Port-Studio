#include "display_mode.h"

// Preferences are scoped to the game and exact build. Edits affect next launch.
static NSString *display_preference_key(NSString *name) {
    return [NSString stringWithFormat:@"Display.v1.%s.%s.%@", DM_GAME_ID, dm_main_build(), name];
}
static NSUserDefaults *display_preferences(void) { return [[NSUserDefaults alloc] initWithSuiteName:@"org.nxnative.display"]; }
static BOOL display_saved(NSUserDefaults *preferences, NSString *name) {
    id value = [preferences objectForKey:display_preference_key(name)];
    return [value isKindOfClass:NSNumber.class] && [value isEqual:@YES];
}
static BOOL display_explicit_on(const char *name) { const char *v = getenv(name); return v && !strcmp(v, "1"); }
static void display_load(NSUserDefaults *preferences) {
    if (!getenv("DM_FULLSCREEN")) setenv("DM_FULLSCREEN", display_saved(preferences, @"fullscreen") ? "1" : "0", 0);
    if (!getenv("DM_DISPLAY_WIDE") && dm_display_aspect_qualified())
        setenv("DM_DISPLAY_WIDE", display_saved(preferences, @"wide") ? "1" : "0", 0);
}

@interface DmDisplaySettings : NSObject
- (void)showDisplay:(id)sender;
@end
@implementation DmDisplaySettings
- (void)showDisplay:(id)sender {
    (void)sender;
    NSUserDefaults *preferences = display_preferences();
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Display — " DM_GAME_NAME;
    alert.informativeText = @"Changes apply the next time this game starts. Fullscreen uses the display’s pixel resolution and preserves the picture’s proportions with borders. Internal rendering resolution is controlled separately by the game.\n\nExpand game view needs a verified camera/projection and HUD mod for this exact game build. It is currently unavailable.\n\n120 FPS needs a verified game-timing mod and a display capable of at least 120 Hz. No game build has been qualified for this option; a higher display refresh rate alone is insufficient.";
    [alert addButtonWithTitle:@"Save"]; [alert addButtonWithTitle:@"Cancel"];
    NSButton *full = [NSButton checkboxWithTitle:@"Start full screen" target:nil action:nil];
    full.state = display_saved(preferences, @"fullscreen") ? NSControlStateValueOn : NSControlStateValueOff;
    NSButton *wide = [NSButton checkboxWithTitle:@"Expand game view to display aspect" target:nil action:nil];
    wide.enabled = dm_display_aspect_qualified();
    wide.state = wide.enabled && display_saved(preferences, @"wide") ? NSControlStateValueOn : NSControlStateValueOff;
    NSButton *fps = [NSButton checkboxWithTitle:@"120 FPS — game timing mod unavailable" target:nil action:nil];
    fps.enabled = NO; fps.state = NSControlStateValueOff;
    NSTextField *status = [NSTextField wrappingLabelWithString:[NSString stringWithFormat:@"Current drawable: %.0f × %.0f pixels · Screen: %ld Hz maximum\nBuild: %s", g_layer.drawableSize.width, g_layer.drawableSize.height, (long)g_win.screen.maximumFramesPerSecond, dm_main_build()]];
    NSStackView *fields = [NSStackView stackViewWithViews:@[full, wide, fps, status]];
    fields.orientation = NSUserInterfaceLayoutOrientationVertical;
    fields.alignment = NSLayoutAttributeLeading; fields.spacing = 12;
    fields.frame = NSMakeRect(0, 0, 480, 130);
    [status.widthAnchor constraintEqualToConstant:480].active = YES;
    alert.accessoryView = fields;
    alert.window.initialFirstResponder = full;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [preferences setBool:full.state == NSControlStateValueOn forKey:display_preference_key(@"fullscreen")];
    if (wide.enabled) [preferences setBool:wide.state == NSControlStateValueOn forKey:display_preference_key(@"wide")];
}
@end
static DmDisplaySettings *g_display_settings;
static void display_add_menu(NSMenu *app) {
    g_display_settings = [DmDisplaySettings new];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Display…" action:@selector(showDisplay:) keyEquivalent:@""];
    item.target = g_display_settings;
    NSInteger index = app.numberOfItems;
    if (app.itemArray.lastObject.isSeparatorItem) index--;
    [app insertItem:item atIndex:index];
}
