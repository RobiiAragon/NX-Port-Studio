// Native preferences and launch policy only: no game, NSApplication, window, socket or installed app.
// clang -Wall -Werror -Wno-unused-function -fobjc-arc t_network_mac.m -framework Cocoa -o /tmp/t_network_mac
#import <Cocoa/Cocoa.h>
#include <stdlib.h>
#include <string.h>
#define DM_GAME_ID "test-network"
#define DM_GAME_NAME "Network Test"
#include "../network_mac.inc"
static int checks, failures;
#define CHECK(c, message) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL: %s (line %d)\n", message, __LINE__); } } while (0)
int main(void) { @autoreleasepool {
    const char *inherited = getenv("DM_NETWORK");
    char *original = inherited ? strdup(inherited) : NULL;
    NSString *suite = [@"org.nxnative.network.test." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:suite];
    CHECK([network_preference_key() isEqualToString:@"Network.v1.test-network"], "preference is scoped by game ID");
    CHECK([network_saved_mode(preferences) isEqualToString:@"offline"], "new game defaults offline");
    [preferences setObject:@"lan" forKey:@"Network.v1.another-game"];
    CHECK([network_saved_mode(preferences) isEqualToString:@"offline"], "another game does not enable LAN");
    for (id invalid in @[@42, @[], @{}, @"online", @"LAN"]) {
        [preferences setObject:invalid forKey:network_preference_key()];
        CHECK([network_saved_mode(preferences) isEqualToString:@"offline"], "malformed or unsupported choice stays offline");
    }
    network_save_mode(preferences, @"lan");
    NSUserDefaults *reopened = [[NSUserDefaults alloc] initWithSuiteName:suite];
    CHECK([network_saved_mode(reopened) isEqualToString:@"lan"], "saved choice survives reopening preferences");
    unsetenv("DM_NETWORK"); network_load(preferences);
    CHECK(!strcmp(getenv("DM_NETWORK"), "lan"), "saved LAN applies before guest startup");
    CHECK(!g_network_environment_override && [g_network_session_mode isEqualToString:@"lan"], "session records preference source");
    network_save_mode(preferences, @"offline");
    CHECK(!strcmp(getenv("DM_NETWORK"), "lan") && [g_network_session_mode isEqualToString:@"lan"], "saving does not change running session");
    unsetenv("DM_NETWORK"); network_load(preferences);
    CHECK(!strcmp(getenv("DM_NETWORK"), "offline"), "saved offline applies on next launch");
    network_save_mode(preferences, @"lan");
    for (const char **value = (const char *[]){"offline", "custom", "", NULL}; *value; value++) {
        setenv("DM_NETWORK", *value, 1); network_load(preferences);
        CHECK(!strcmp(getenv("DM_NETWORK"), *value), "explicit environment is preserved byte for byte");
        CHECK(g_network_environment_override && [g_network_session_mode isEqualToString:@"offline"], "unsupported environment remains offline and reports override");
    }
    network_save_mode(preferences, @"offline");
    setenv("DM_NETWORK", "lan", 1); network_load(preferences);
    CHECK(!strcmp(getenv("DM_NETWORK"), "lan") && g_network_environment_override, "explicit LAN wins over saved offline");
    CHECK([g_network_session_mode isEqualToString:@"lan"], "explicit LAN is reflected in current-session label");
    for (NSString *mode in @[@"ldn", @"nextendo"]) {
        network_save_mode(preferences, mode); unsetenv("DM_NETWORK"); network_load(preferences);
        CHECK([network_saved_mode(preferences) isEqualToString:mode] && [g_network_session_mode isEqualToString:mode],
              "distinct experimental modes persist without being mislabeled as LAN");
    }
    CHECK(network_valid_peer(@"") && network_valid_peer(@"192.168.1.20") && !network_valid_peer(@"224.0.0.1") &&
          !network_valid_peer(@"255.255.255.255") && !network_valid_peer(@"0.0.0.0") && !network_valid_peer(@"console.local"),
          "discovery peer accepts only empty or explicit unicast IPv4");
    unsetenv("DM_NET_DISCOVERY_PEER");
    [preferences setObject:@"192.168.1.20" forKey:network_peer_key()]; network_load(preferences);
    CHECK(!strcmp(getenv("DM_NET_DISCOVERY_PEER"), "192.168.1.20"), "per-game discovery peer applies before startup");
    setenv("DM_NET_DISCOVERY_PEER", "192.168.1.21", 1); network_load(preferences);
    CHECK(!strcmp(getenv("DM_NET_DISCOVERY_PEER"), "192.168.1.21"), "explicit discovery environment keeps precedence");
    unsetenv("DM_NET_DISCOVERY_PEER");
    [preferences removePersistentDomainForName:suite];
    if (original) { setenv("DM_NETWORK", original, 1); free(original); } else unsetenv("DM_NETWORK");
    printf("Mac network settings: %d checks, %d failed\n", checks, failures);
    return failures != 0;
} }
