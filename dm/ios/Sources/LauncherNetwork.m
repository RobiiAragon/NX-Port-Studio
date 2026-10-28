// Metadata-only launcher preflight. No token, PID, username or signing material
// crosses into SwiftUI. The selected mode is applied before this call.
#include <stdint.h>
#include "net_socket.h"
#include "nextendo_account.h"
#include "nextendo_routes.h"

uint32_t dm_launcher_nextendo_preflight(void) {
    if (dm_net_mode() != DM_NET_NEXTENDO) return DM_NEXTENDO_ROUTES_MISSING;
    int routes = dm_nextendo_routes_initialize();
    if (routes == DM_NEXTENDO_ROUTES_READY && !dm_nextendo_routes_count()) routes = DM_NEXTENDO_ROUTES_MISSING;
    uint8_t credential = 0;
    if (dm_nextendo_account_available(&credential) != DM_ACCOUNT_OK) credential = 0;
    return (uint32_t)routes | (credential ? 1u << 8 : 0);
}
