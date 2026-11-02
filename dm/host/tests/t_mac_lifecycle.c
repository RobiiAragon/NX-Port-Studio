// Real oe notifications plus the production Mac policy; no AppKit or game.
#include "../hle_oe.c"
static int released, resumed, audio, graphics, visible, focused;
static void input_release(void) { ++released; }
static void input_resume(void) { ++resumed; }
void mtl_present_window_state(int on,int key) { visible=on; focused=key; }
void dm_audio_suspend(int on) { audio=on; }
void dm_gfx_suspend(int on) { graphics=on; }
void guest_clock_freeze_for(int reason,int on) { (void)reason; (void)on; abort(); }
void dm_thread_native_wait(int entering) { (void)entering; }
void dm_guest_host_wait_begin(void) {}
void dm_guest_host_wait_end(void) {}
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000+t.tv_nsec; }
void hle_bind_system_event(void *event,int clear) { (void)event; (void)clear; }
void hle_signal_system_event(void *event) { (void)event; }
void hle_clear_system_event(void *event) { (void)event; }
#include "../mac_lifecycle.inc"
static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x); abort(); } } while (0)
static int pop(unsigned want) { uint32_t result=0; return h_oe_TryPopMsg(&result) && result==want; }
static int empty(void) { uint32_t sentinel=1234; return !h_oe_TryPopMsg(&sentinel) && sentinel==1234; }
int main(void) {
    unsetenv("DM_MAC_BACKGROUND");
    mac_window_lifecycle(MAC_WINDOW_RESIGN,1);
    CHECK(released==1 && h_oe_GetFocus()==1 && empty() && visible && !focused);
    mac_window_lifecycle(MAC_WINDOW_VISIBILITY,0);
    CHECK(!visible && !audio && !graphics && h_oe_GetFocus()==1 && empty());
    dm_applet_enter("controller test");
    CHECK(h_oe_GetFocus()==2 && pop(15) && empty());
    mac_window_lifecycle(MAC_WINDOW_MINIMIZE,0);
    mac_window_lifecycle(MAC_WINDOW_RESIGN,0);
    CHECK(released==3 && !audio && !graphics && !visible && h_oe_GetFocus()==2 && empty());
    mac_window_lifecycle(MAC_WINDOW_RESTORE,1);
    mac_window_lifecycle(MAC_WINDOW_KEY,1);
    CHECK(resumed==1 && visible && focused && h_oe_GetFocus()==2 && empty());
    dm_applet_leave(); CHECK(h_oe_GetFocus()==1 && pop(15) && empty());
    // AppKit can deliver key-window activation before deminiaturization.
    mac_window_lifecycle(MAC_WINDOW_MINIMIZE,0);
    mac_window_lifecycle(MAC_WINDOW_KEY,1); CHECK(!visible && focused);
    mac_window_lifecycle(MAC_WINDOW_RESTORE,1);
    CHECK(visible && focused && h_oe_GetFocus()==1 && empty());
    // The policy does not replace GetFocus or force an explicit guest state.
    dm_focus_set(2); CHECK(pop(15)); mac_window_lifecycle(MAC_WINDOW_KEY,1);
    CHECK(h_oe_GetFocus()==2 && empty()); dm_focus_set(1); CHECK(pop(15));
    setenv("DM_MAC_BACKGROUND","0",1);
    mac_window_lifecycle(MAC_WINDOW_RESIGN,1); CHECK(h_oe_GetFocus()==2 && pop(15));
    mac_window_lifecycle(MAC_WINDOW_MINIMIZE,0); CHECK(h_oe_GetFocus()==3 && audio && graphics && !visible && pop(15));
    mac_window_lifecycle(MAC_WINDOW_RESTORE,1); CHECK(h_oe_GetFocus()==2 && !audio && !graphics && visible && !focused && pop(15));
    mac_window_lifecycle(MAC_WINDOW_KEY,1); CHECK(h_oe_GetFocus()==1 && focused && pop(15) && empty());
    printf("Mac window policy: %u checks PASS; library-applet focus remains real\n",checks);
    return 0;
}
