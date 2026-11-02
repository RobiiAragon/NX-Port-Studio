// Cached AppKit screen capabilities for the renderer. AppKit properties are read
// only on the main thread; the present thread reads the atomic snapshots.
static _Atomic int g_screen_fps;
int front_screen_max_fps(void) { return g_screen_fps; }
static _Atomic int g_screen_variable_refresh;
int front_screen_variable_refresh(void) { return g_screen_variable_refresh; }
static void screen_refresh(NSScreen *screen) {
    if (!screen) return;
    g_screen_fps = (int)screen.maximumFramesPerSecond;
    g_screen_variable_refresh = screen.minimumRefreshInterval > 0 && screen.maximumRefreshInterval > screen.minimumRefreshInterval;
}
