// The Python preparer's synthetic output consumed by the production route loader.
// No sockets, guest code, credentials, system trust changes or TLS bypass.
#include "../nextendo_routes.h"
#include "../net_socket.h"
#include "../ssl_backend.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static dm_net_dns_provider dns;
static dm_ssl_peer_policy_provider ca_policy, pin_policy;
static bool (*guard)(const char *);
dm_net_mode_t dm_net_mode(void) { return DM_NET_NEXTENDO; }
void dm_net_set_dns_provider(dm_net_dns_provider value) { dns = value; }
void dm_ssl_set_peer_guard(bool (*value)(const char *)) { guard = value; }
void dm_ssl_set_peer_policy(dm_ssl_peer_policy_provider value) { ca_policy = value; }
void dm_ssl_set_peer_pin_policy(dm_ssl_peer_policy_provider value) { pin_policy = value; }

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    setenv("DM_NEXTENDO_ROUTES", argv[1], 1);
    if (dm_nextendo_routes_initialize() || !dns || !guard || !ca_policy || !pin_policy) return 3;
    char address[32], logical[254], alias[254]; const uint8_t *leaf = NULL, *alias_leaf = NULL; size_t size = 0, alias_size = 0;
    if (dns(argv[2], address, sizeof address) != 1 || strcmp(address, argv[3]) || !guard(argv[2]) || !guard(argv[3])) return 4;
    if (!pin_policy(argv[2], logical, sizeof logical, &leaf, &size) || strcmp(logical, argv[2]) || !size) return 5;
    if (!pin_policy(argv[3], alias, sizeof alias, &alias_leaf, &alias_size) || strcmp(alias, logical) || size != alias_size || memcmp(leaf, alias_leaf, size)) return 6;
    if (ca_policy(argv[2], logical, sizeof logical, &leaf, &size) || ca_policy(argv[3], logical, sizeof logical, &leaf, &size)) return 7;
    if (guard("unconfigured.invalid") || guard("192.0.2.99") || pin_policy("unconfigured.invalid", logical, sizeof logical, &leaf, &size)) return 8;
    puts("Local peer profile: production loader accepted the exact service/address pair and unchanged DER identity");
    return 0;
}
