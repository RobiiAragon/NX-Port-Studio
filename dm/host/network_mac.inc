#include <arpa/inet.h>

// Per-game native network settings. Apply once before the guest starts; edits affect the next launch only.
static NSString *network_preference_key(void) { return @"Network.v1." DM_GAME_ID; }
static NSString *network_peer_key(void) { return [network_preference_key() stringByAppendingString:@".discoveryPeer"]; }
static NSArray<NSString *> *network_modes(void) { return @[@"offline", @"lan", @"ldn", @"nextendo"]; }
static NSString *network_valid_mode(id value) { return [value isKindOfClass:NSString.class] && [network_modes() containsObject:value] ? value : @"offline"; }
static BOOL network_valid_peer(NSString *peer) {
    struct in_addr ip;
    return !peer.length || (inet_pton(AF_INET, peer.UTF8String, &ip) == 1 && ip.s_addr && ntohl(ip.s_addr) < 0xe0000000u);
}
static NSUserDefaults *network_preferences(void) { return [[NSUserDefaults alloc] initWithSuiteName:@"org.nxnative.network"]; }
static NSString *network_saved_mode(NSUserDefaults *preferences) {
    id saved = [preferences objectForKey:network_preference_key()];
    return network_valid_mode(saved);
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
    if ([mode isEqualToString:@"lan"]) return @"Local network (LAN)";
    if ([mode isEqualToString:@"ldn"]) return @"Local wireless bridge (LDN) — experimental";
    if ([mode isEqualToString:@"nextendo"]) return @"Nextendo — integration in development";
    return @"Offline";
}

@interface DmNetworkSettings : NSObject
- (void)showNetwork:(id)sender;
@end
@implementation DmNetworkSettings
- (void)showNetwork:(id)sender {
    (void)sender;
    NSUserDefaults *preferences = network_preferences();
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Network — " DM_GAME_NAME;
    NSString *details = [NSString stringWithFormat:@"Current session: %@. Changes are saved for this game and apply the next time it starts.\n\nLAN: use the same game version and select its built-in LAN mode; this protocol can include unmodified consoles.\n\nLDN bridge: requires a compatible, enabled ldn_mitm module on a modified Switch. Physical compatibility is still being verified.\n\nNextendo: requires a supported game version, service routing and a valid NEX game credential. Linking an OAuth account alone does not enable online play.", network_mode_name(g_network_session_mode)];
    if (g_network_environment_override)
        details = [details stringByAppendingString:@"\n\nDM_NETWORK is set explicitly for this launch and takes priority over the saved choice."];
    alert.informativeText = details;
    [alert addButtonWithTitle:@"Save"]; [alert addButtonWithTitle:@"Cancel"];
    NSPopUpButton *choice = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 300, 28) pullsDown:NO];
    [choice addItemsWithTitles:@[@"Offline", @"Local network (LAN)", @"Local wireless bridge (LDN) — experimental", @"Nextendo — integration in development"]];
    [choice selectItemAtIndex:[network_modes() indexOfObject:network_saved_mode(preferences)]];
    [choice setAccessibilityLabel:@"Network mode"];
    NSTextField *peer = [NSTextField textFieldWithString:@""];
    id savedPeer = [preferences objectForKey:network_peer_key()];
    if ([savedPeer isKindOfClass:NSString.class] && network_valid_peer(savedPeer)) peer.stringValue = savedPeer;
    peer.placeholderString = @"Optional console IPv4 address";
    [peer setAccessibilityLabel:@"Discovery peer IPv4 address"];
    NSStackView *fields = [NSStackView stackViewWithViews:@[choice, [NSTextField labelWithString:@"Discovery peer (optional)"], peer]];
    fields.orientation = NSUserInterfaceLayoutOrientationVertical;
    fields.alignment = NSLayoutAttributeLeading;
    fields.spacing = 8;
    fields.frame = NSMakeRect(0, 0, 420, 90);
    [choice.widthAnchor constraintEqualToConstant:420].active = YES;
    [peer.widthAnchor constraintEqualToConstant:420].active = YES;
    alert.accessoryView = fields;
    alert.window.initialFirstResponder = choice;
    while ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *value = [peer.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!network_valid_peer(value)) {
            NSAlert *invalid = [NSAlert new]; invalid.messageText = @"Enter a valid unicast IPv4 address";
            invalid.informativeText = @"Leave the field empty to use normal local discovery on this Mac.";
            [invalid runModal]; continue;
        }
        network_save_mode(preferences, network_modes()[choice.indexOfSelectedItem]);
        [preferences setObject:value forKey:network_peer_key()];
        break;
    }
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
