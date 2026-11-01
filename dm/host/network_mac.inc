#include <arpa/inet.h>

// Per-game native network settings. Apply once before the guest starts; edits affect the next launch only.
static NSString *network_preference_key(void) { return @"Network.v1." DM_GAME_ID; }
static NSString *network_peer_key(void) { return [network_preference_key() stringByAppendingString:@".discoveryPeer"]; }
static NSArray<NSString *> *network_modes(void) { return @[@"auto", @"offline", @"lan", @"ldn", @"nextendo"]; }
static NSString *network_valid_mode(id value) { return [value isKindOfClass:NSString.class] && [network_modes() containsObject:value] ? value : @"offline"; }
static BOOL network_valid_peer(NSString *peer) {
    struct in_addr ip;
    return !peer.length || (inet_pton(AF_INET, peer.UTF8String, &ip) == 1 && ip.s_addr && ntohl(ip.s_addr) < 0xe0000000u);
}
static NSUserDefaults *network_preferences(void) { return [[NSUserDefaults alloc] initWithSuiteName:@"org.nxnative.network"]; }
static NSString *network_saved_mode(NSUserDefaults *preferences) {
    NSString *versionKey = [network_preference_key() stringByAppendingString:@".selectionVersion"];
    id saved = [preferences objectForKey:network_preference_key()];
    if ([preferences integerForKey:versionKey] < 2) {
        if ([saved isKindOfClass:NSString.class] && [@[@"lan", @"ldn", @"nextendo"] containsObject:saved]) {
            saved = @"auto"; [preferences setObject:saved forKey:network_preference_key()];
        }
        [preferences setInteger:2 forKey:versionKey];
    }
    return saved ? network_valid_mode(saved) : @"auto";
}
static void network_save_mode(NSUserDefaults *preferences, NSString *mode) {
    [preferences setObject:network_valid_mode(mode) forKey:network_preference_key()];
}
static BOOL g_network_environment_override;
static NSString *g_network_session_mode;
static void network_load(NSUserDefaults *preferences) {
    const char *explicit_mode = getenv("DM_NETWORK");
    g_network_environment_override = explicit_mode != NULL;
    if (!explicit_mode) setenv("DM_NETWORK", network_saved_mode(preferences).UTF8String, 0);
    const char *mode = getenv("DM_NETWORK");
    g_network_session_mode = network_valid_mode(mode ? [NSString stringWithUTF8String:mode] : nil);
    if (!getenv("DM_NET_DISCOVERY_PEER")) {
        id peer = [preferences objectForKey:network_peer_key()];
        if ([peer isKindOfClass:NSString.class] && [peer length] && network_valid_peer(peer))
            setenv("DM_NET_DISCOVERY_PEER", [peer UTF8String], 0);
    }
}
static NSString *network_mode_name(NSString *mode) {
    if ([mode isEqualToString:@"auto"]) return @"Automatic connection";
    if ([mode isEqualToString:@"lan"]) return @"Local network (LAN)";
    if ([mode isEqualToString:@"ldn"]) return @"Local wireless bridge (LDN) — experimental";
    if ([mode isEqualToString:@"nextendo"]) return @"Nextendo — integration in development";
    return @"Offline";
}

@interface DmNetworkSettings : NSObject
- (void)showNetwork:(id)sender;
- (void)presentAlert:(NSAlert *)alert disabled:(NSButton *)disabled peer:(NSTextField *)peer owner:(NSWindow *)owner;
@end
@implementation DmNetworkSettings
- (void)presentAlert:(NSAlert *)alert disabled:(NSButton *)disabled peer:(NSTextField *)peer owner:(NSWindow *)owner {
    // Attach settings to the game window. A floating application-modal alert can
    // remain behind a reactivated game window, leaving its menus disabled and
    // sending keyboard input to the game instead of the invisible dialog.
    [alert beginSheetModalForWindow:owner completionHandler:^(NSModalResponse response) {
        if (response!=NSAlertFirstButtonReturn) return;
        NSString *value=[peer.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!network_valid_peer(value)) {
            NSAlert *invalid=[NSAlert new]; invalid.messageText=@"Enter a valid unicast IPv4 address";
            invalid.informativeText=@"Leave the field empty to use normal local discovery on this Mac.";
            [invalid beginSheetModalForWindow:owner completionHandler:^(NSModalResponse result) {
                (void)result; [self presentAlert:alert disabled:disabled peer:peer owner:owner];
            }]; return;
        }
        NSUserDefaults *preferences=network_preferences();
        network_save_mode(preferences,disabled.state == NSControlStateValueOn ? @"offline" : @"auto");
        [preferences setObject:value forKey:network_peer_key()];
    }];
}
- (void)showNetwork:(id)sender {
    (void)sender;
    NSWindow *owner=NSApp.mainWindow; if (!owner || owner.attachedSheet) return;
    NSUserDefaults *preferences = network_preferences();
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Network — " DM_GAME_NAME;
    NSString *details = [NSString stringWithFormat:@"Current session: %@. Choose Online, Local wireless or LAN inside the game; there is no separate protocol to select here.\n\nOnline uses Nextendo with its verified service profile, private game credential and supported game version. LAN uses the game's native LAN protocol and can include unmodified consoles. Local wireless uses the LDN bridge, which requires compatible ldn_mitm on a modified Switch.\n\nDiscovery is automatic. An optional peer address is an advanced override. Changes here apply on the next launch.", network_mode_name(g_network_session_mode)];
    if (g_network_environment_override)
        details = [details stringByAppendingString:@"\n\nDM_NETWORK is set explicitly for this launch and takes priority over the saved choice."];
    alert.informativeText = details;
    [alert addButtonWithTitle:@"Save"]; [alert addButtonWithTitle:@"Cancel"];
    NSButton *disabled = [NSButton checkboxWithTitle:@"Disable network services" target:nil action:nil];
    disabled.state = [network_saved_mode(preferences) isEqualToString:@"offline"] ? NSControlStateValueOn : NSControlStateValueOff;
    NSTextField *peer = [NSTextField textFieldWithString:@""];
    id savedPeer = [preferences objectForKey:network_peer_key()];
    if ([savedPeer isKindOfClass:NSString.class] && network_valid_peer(savedPeer)) peer.stringValue = savedPeer;
    peer.placeholderString = @"Optional console IPv4 address";
    [peer setAccessibilityLabel:@"Discovery peer IPv4 address"];
    NSStackView *fields = [NSStackView stackViewWithViews:@[disabled, [NSTextField labelWithString:@"Advanced: discovery peer (optional)"], peer]];
    fields.orientation = NSUserInterfaceLayoutOrientationVertical;
    fields.alignment = NSLayoutAttributeLeading;
    fields.spacing = 8;
    fields.frame = NSMakeRect(0, 0, 420, 90);
    [disabled.widthAnchor constraintEqualToConstant:420].active = YES;
    [peer.widthAnchor constraintEqualToConstant:420].active = YES;
    alert.accessoryView = fields;
    alert.window.initialFirstResponder = disabled;
    [self presentAlert:alert disabled:disabled peer:peer owner:owner];
}
@end
static DmNetworkSettings *g_network_settings;
static void network_add_menu(NSMenu *app) {
    g_network_settings = [DmNetworkSettings new];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Network…" action:@selector(showNetwork:) keyEquivalent:@""];
    item.target = g_network_settings;
    // Controls adds the separator before Quit; keep both settings above it.
    NSInteger index = app.numberOfItems;
    if (app.itemArray.lastObject.isSeparatorItem) index--;
    [app insertItem:item atIndex:index];
}
