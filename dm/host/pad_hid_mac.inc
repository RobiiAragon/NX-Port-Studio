// Raw IOHID input for the wired Switch controllers that macOS GameController does not list (pad_hid.h): without it a PowerA / HORI / PDP wired pad reaches no player at all,
// not even the "no gamepad inputs" log line. Included by front_mac.m after its player slots; everything runs on the main run loop, as GameController's handlers do.
// The manager matches only pad_hid.h's IDs and opens them nonexclusively; only input reports are read (a gamepad needs no Input Monitoring permission, unlike a keyboard).
// Each pad holds a player slot of its own like a GameController controller (pad_slots.h, owner: its DmHidPad, name: its HID product string), or joins player 1 with
// DM_PAD_MERGE / combine; Controls… bindings and stick settings apply to it the same way. The pads stream a report every 8 ms whether or not anything moved, so a report is
// published only when it differs from the last one, as GameController's change handlers do (DM_KEYS on player 1 is not overridden by an idle pad).
// Should GameController list the pad after all (a later macOS), the GameController controller wins and this one yields its slot, so one pad never becomes two players.
// DM_PAD_HID=0 turns the fallback off.
#import <IOKit/hid/IOHIDManager.h>
#import <GameController/GCSyntheticDeviceKeys.h>
#include "pad_hid.h"
typedef struct { IOHIDDeviceRef device; uint8_t report[64]; char name[64]; uint64_t buttons; int32_t axes[4]; int decoded, yielded; } DmHidPad;
static DmHidPad g_hid_pads[DM_PLAYERS];
static IOHIDManagerRef g_hid_manager;
static int hid_pad_live(const DmHidPad *d) { return d->device && !d->yielded; }
static void hid_pads_merge(uint64_t *m, int32_t axes[4]) {   // pad_merged: the pads' share of player 1 with DM_PAD_MERGE
    for (int i = 0; i < DM_PLAYERS; i++) {
        DmHidPad *d = &g_hid_pads[i]; if (!hid_pad_live(d) || !d->decoded) continue;
        *m |= d->buttons;
        for (int k = 0; k < 4; k++) if (abs(d->axes[k]) > abs(axes[k])) axes[k] = d->axes[k];
    }
}
static void hid_pad_publish(DmHidPad *d) {
    if (!g_input_on || !hid_pad_live(d) || !d->decoded) return;
    uint64_t m = 0; int32_t axes[4] = {0};
    if (g_merge) { pad_merged(&m, axes); pad_publish(0, m, axes); return; }
    int p = pad_slot_of(&g_slots, d); if (p < 0) return;
    memcpy(axes, d->axes, sizeof axes); pad_publish(p, d->buttons, axes);
}
static void hid_pad_report(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t id, uint8_t *r, CFIndex n) {
    (void)sender; (void)id; DmHidPad *d = ctx;
    uint64_t b; int32_t a[4];
    if (result != kIOReturnSuccess || type != kIOHIDReportTypeInput || n < 0 || !d->device || !dm_hid_pad_decode(r, (size_t)n, &b, a)) return;
    if (d->decoded && b == d->buttons && !memcmp(a, d->axes, sizeof a)) return;
    d->buttons = b; memcpy(d->axes, a, sizeof a); d->decoded = 1;
    hid_pad_publish(d);
}
static void hid_pad_leave(DmHidPad *d, const char *why) {   // its player is free and nothing it held stays pressed
    if (g_merge) { uint64_t m = 0; int32_t axes[4] = {0}; d->decoded = 0; pad_merged(&m, axes); if (g_input_on) pad_publish(0, m, axes); return; }
    int p = pad_slot_free(&g_slots, d); if (p < 0) return;
    char nb[16]; npad_name(p, nb, sizeof nb); LOG("controller '%s' %s: player %d (npad %s) is free", d->name, why, p + 1, nb);
    dm_pad_set_player(p, 0, 0, 0, 0, 0); dm_pad_players(pad_slot_mask(&g_slots));
}
// pads_changed, before GameController's controllers take slots: a pad GameController now lists (its vendorName carries the HID product name) yields to it; one it no longer
// lists comes back. gone: the GameController controller being removed, which no longer counts.
static void hid_pads_yield(GCController *gone) {
    for (int i = 0; i < DM_PLAYERS; i++) {
        DmHidPad *d = &g_hid_pads[i]; if (!d->device) continue;
        int listed = 0; NSString *name = @(d->name);
        for (GCController *c in GCController.controllers) if (c != gone && pad_supported(c) && [c.vendorName localizedCaseInsensitiveContainsString:name]) listed = 1;
        if (listed && !d->yielded) { hid_pad_leave(d, "is listed by GameController now, raw HID input off"); d->yielded = 1; }
        else if (!listed) d->yielded = 0;
    }
}
// pads_changed, after GameController's controllers: every live pad without a slot takes one (also after Controls… resets the slots)
static void hid_pads_claim(void) {
    for (int i = 0; i < DM_PLAYERS; i++) {
        DmHidPad *d = &g_hid_pads[i]; if (!hid_pad_live(d)) continue;
        if (!g_merge && pad_slot_of(&g_slots, d) < 0) {
            int p = pad_slot_take(&g_slots, d, d->name);
            if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", d->name, DM_PLAYERS); continue; }
            char nb[16]; npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s) (raw HID: GameController does not list it)", d->name, p + 1, nb);
        }
        hid_pad_publish(d);
    }
    if (!g_merge) dm_pad_players(pad_slot_mask(&g_slots));
}
static int hid_pads_any(void) { for (int i = 0; i < DM_PLAYERS; i++) if (hid_pad_live(&g_hid_pads[i])) return 1; return 0; }
static void hid_pads_release(void) {   // input_release: the pads' players let go (their reports keep updating the state, published again on input_resume)
    for (int i = 0; i < DM_PLAYERS; i++) {
        DmHidPad *d = &g_hid_pads[i]; if (!hid_pad_live(d)) continue;
        int p = g_merge ? 0 : pad_slot_of(&g_slots, d); if (p >= 0) dm_pad_set_player(p, 0, 0, 0, 0, 0);
    }
}
static void hid_pads_resume(void) { for (int i = 0; i < DM_PLAYERS; i++) hid_pad_publish(&g_hid_pads[i]); }
static void hid_pad_added(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)ctx; (void)sender;
    if (result != kIOReturnSuccess || IOHIDDeviceGetProperty(device, CFSTR(kIOHIDGCSyntheticDeviceKey)) == kCFBooleanTrue) return;
    if (IOHIDDeviceGetProperty(device, CFSTR("GameControllerSupportedHIDDevice")) == kCFBooleanTrue) return;   // gamecontrollerd drives it: GameController has it
    int vendor = [(__bridge NSNumber *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey)) intValue], product = [(__bridge NSNumber *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey)) intValue];
    if (!dm_hid_pad_known(vendor, product)) return;
    DmHidPad *d = NULL;
    for (int i = 0; i < DM_PLAYERS; i++) if (g_hid_pads[i].device == device) return;
    for (int i = 0; i < DM_PLAYERS && !d; i++) if (!g_hid_pads[i].device) d = &g_hid_pads[i];
    if (!d) { LOG("controller %04x:%04x: no room for another wired controller, not used", vendor, product); return; }
    memset(d, 0, sizeof *d); d->device = (IOHIDDeviceRef)CFRetain(device);
    NSString *name = (__bridge NSString *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    snprintf(d->name, sizeof d->name, "%s", name.length ? name.UTF8String : "Wired controller");
    IOHIDDeviceRegisterInputReportCallback(device, d->report, sizeof d->report, hid_pad_report, d);
    hid_pads_yield(nil); hid_pads_claim();
    if (g_merge && hid_pad_live(d)) LOG("controller '%s' connected (raw HID: GameController does not list it)", d->name);
}
static void hid_pad_removed(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)ctx; (void)result; (void)sender;
    for (int i = 0; i < DM_PLAYERS; i++) {
        DmHidPad *d = &g_hid_pads[i]; if (d->device != device) continue;
        // Unregister while the buffer and its context still exist; the main run loop serializes removal with report callbacks.
        IOHIDDeviceRegisterInputReportCallback(device, d->report, sizeof d->report, NULL, NULL);
        if (!d->yielded) hid_pad_leave(d, "disconnected");
        if (g_merge && !d->yielded) LOG("controller '%s' disconnected", d->name);
        CFRelease(d->device); memset(d, 0, sizeof *d);
    }
}
static void hid_pads_start(void) {
    const char *e = getenv("DM_PAD_HID"); if (g_hid_manager || (e && !atoi(e))) return;
    g_hid_manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone); if (!g_hid_manager) return;
    NSMutableArray *match = [NSMutableArray new];
    for (size_t i = 0; i < sizeof dm_hid_pad_ids / sizeof *dm_hid_pad_ids; i++)
        [match addObject:@{@kIOHIDVendorIDKey: @(dm_hid_pad_ids[i] >> 16), @kIOHIDProductIDKey: @(dm_hid_pad_ids[i] & 0xffff)}];
    IOHIDManagerSetDeviceMatchingMultiple(g_hid_manager, (__bridge CFArrayRef)match);
    IOHIDManagerRegisterDeviceMatchingCallback(g_hid_manager, hid_pad_added, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(g_hid_manager, hid_pad_removed, NULL);
    g_controls_extra_pads = ^NSArray<NSString *> *(void) {   // the Controls window lists GameController's controllers; these are not among them
        NSMutableArray *lines = [NSMutableArray new];
        for (int i = 0; i < DM_PLAYERS; i++) if (hid_pad_live(&g_hid_pads[i])) [lines addObject:[NSString stringWithFormat:@"%s — wired, no motion data", g_hid_pads[i].name]];
        return lines;
    };
    IOHIDManagerScheduleWithRunLoop(g_hid_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOReturn r = IOHIDManagerOpen(g_hid_manager, kIOHIDOptionsTypeNone);   // nonexclusive: GameController and other apps keep the device
    if (r != kIOReturnSuccess) {
        LOG("[RED] wired controllers: cannot open HID (0x%x); a pad GameController does not list stays unused", r);
        IOHIDManagerUnscheduleFromRunLoop(g_hid_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(g_hid_manager); g_hid_manager = NULL;
    }
}
