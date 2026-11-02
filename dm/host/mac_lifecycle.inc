// Desktop window state is not Horizon HOME/library-applet focus. Keep the
// application running by default, while releasing all host input on resign.
enum { MAC_WINDOW_RESIGN, MAC_WINDOW_KEY, MAC_WINDOW_MINIMIZE, MAC_WINDOW_RESTORE, MAC_WINDOW_VISIBILITY };
static int g_mac_minimized, g_mac_key = 1;
static int mac_background_enabled(void) {
    const char *value = getenv("DM_MAC_BACKGROUND");
    return !value || strcmp(value, "0");
}
static void mac_window_lifecycle(int event, int visible) {
    int background = mac_background_enabled();
    if (event == MAC_WINDOW_RESIGN) {
        g_mac_key = 0; input_release();
        if (!background && !g_mac_minimized) dm_focus_set(2);
    } else if (event == MAC_WINDOW_KEY) {
        g_mac_key = 1; input_resume();
        if (!background) dm_focus_set(1);
    } else if (event == MAC_WINDOW_MINIMIZE) {
        g_mac_minimized = 1; g_mac_key = 0; input_release();
        if (!background) { dm_focus_set(3); dm_audio_suspend(1); dm_gfx_suspend(1); }
    } else if (event == MAC_WINDOW_RESTORE) {
        g_mac_minimized = 0; // A preceding BecomeKey notification remains authoritative.
        if (!background) { dm_gfx_suspend(0); dm_audio_suspend(0); dm_focus_set(2); }
    }
    mtl_present_window_state(!g_mac_minimized && visible, g_mac_key);
    static int last = -1;
    int state = (!!visible) | (g_mac_key << 1) | (g_mac_minimized << 2) | (background << 3);
    if (state != last) {
        last = state;
        LOG("front end: desktop state visible %d key %d minimized %d background %d", !!visible, g_mac_key, g_mac_minimized, background);
    }
}
