// Optional developer-only IPv4 endpoint affinity, installed before networking.
// This is an explicitly registered host-local pair, not an online credential,
// console radio transport or automatic discovery of another physical device.
// It does not virtualize loopback addresses or instance-private local services.
#pragma once
#include <stdint.h>
typedef struct { uint32_t own, peer, mask; } dm_net_local_session;
// Addresses use native in_addr order. Both must already be assigned, UP and
// host-local. Only explicit LAN/LDN mode is accepted. Validation failure before
// networking disables ordinary fallback until process exit. A late request
// returns EBUSY without changing the prior transport; it cannot retrofit or stop
// existing native workers. An established pair cannot be replaced.
int dm_net_local_session_install(uint32_t own, uint32_t peer);
// 0: absent, 1: active, -1: requested but unavailable. Zeroes output on failure.
int dm_net_local_session_get(dm_net_local_session *output);
// Shared first-network-start latch; prevents late installation even after a
// native LDN context or guest descriptor has been closed. No profile switching.
int dm_net_local_session_begin(void);
// Shared by guest sockets and the LDN control transport. Only this optional
// session translates UDP broadcast/multicast to its single registered peer.
int dm_net_local_session_route(uint32_t *address, int datagram, int binding);
int dm_net_local_session_source(uint32_t address);
