// Optional local discovery relay. It forwards no game transport or Internet traffic.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct dm_lan_relay dm_lan_relay;
enum { DM_LAN_RELAY_PIA = 1, DM_LAN_RELAY_LDN = 2, DM_LAN_RELAY_ALL = 3 };
typedef enum {
    DM_LAN_RELAY_OK, DM_LAN_RELAY_INVALID, DM_LAN_RELAY_NO_INTERFACE,
    DM_LAN_RELAY_PORT_BUSY, DM_LAN_RELAY_SYSTEM_ERROR, DM_LAN_RELAY_NO_MEMORY
} dm_lan_relay_status;
typedef struct {
    unsigned protocols; // zero selects both verified discovery protocols
    const char *interface_name; // optional BSD interface name; copied during start
} dm_lan_relay_config;
typedef struct {
    unsigned running, status, system_errno, active_queries, interfaces, protocols;
    uint64_t queries, fanout, replies, rejected, expired, rate_limited;
    uint64_t bytes_sent, bytes_received;
} dm_lan_relay_snapshot;
// Start binds 30000 (PiaLan 5.9 framing) and/or 11452 (ldn_mitm). A conflicting
// listener is an explicit PORT_BUSY error; no SO_REUSEPORT/ADDR competition.
// Failure leaves *out NULL and fills failure when supplied. No private data/logs.
dm_lan_relay_status dm_lan_relay_start(const dm_lan_relay_config *config, dm_lan_relay **out,
                                     dm_lan_relay_snapshot *failure);
// Stop may wait briefly for the bounded worker; after it returns the pointer is
// invalid. Serialize start/stop/snapshot calls in the owning actor or controller.
void dm_lan_relay_stop(dm_lan_relay *relay);
void dm_lan_relay_snapshot_get(dm_lan_relay *relay, dm_lan_relay_snapshot *out);

// Pure framing checks are also useful to fixtures and diagnostic tools. A Pia
// response has its HOST's counter, not necessarily the query's counter. The
// game verifies its own cryptographic challenge; this relay never claims to.
int dm_lan_relay_packet_valid(unsigned protocol, int response, const void *bytes, size_t size);

#ifdef DM_LAN_RELAY_TEST
typedef struct { uint32_t address, mask; unsigned index, flags; } dm_lan_relay_test_interface;
// Test-only snapshots and input injection avoid creating any LAN broadcasts.
// Datagrams still traverse the real production UDP fanout and response path.
dm_lan_relay_status dm_lan_relay_test_start(unsigned protocol, uint16_t listener_port,
                                          uint16_t peer_port, dm_lan_relay_test_interface interface,
                                          dm_lan_relay **out);
int dm_lan_relay_test_query(dm_lan_relay *, unsigned protocol, uint32_t source,
                          uint16_t source_port, uint32_t destination, unsigned index,
                          const void *bytes, size_t size);
int dm_lan_relay_test_add_own(dm_lan_relay *,uint32_t address);
#endif
#ifdef __cplusplus
}
#endif
