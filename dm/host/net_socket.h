// Horizon socket ABI, translated by hle_net_backend.c. Opt-in Apple IPv4 TCP/UDP.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include "net_discovery.h"

typedef struct { int32_t fd; int16_t events, revents; } dm_net_pollfd;
typedef struct { int32_t flags, family, type, protocol; uint32_t addrlen, pad; void *addr; char *canonname; void *next; } dm_net_addrinfo;
typedef struct { int32_t flags, family, type, protocol; uint32_t addrlen, pad; char *canonname; void *addr; void *next; } dm_net_addrinfo_legacy;
typedef enum { DM_NET_OFFLINE, DM_NET_LAN, DM_NET_LDN, DM_NET_NEXTENDO } dm_net_mode_t;
dm_net_mode_t dm_net_mode(void);
int dm_net_enabled(void);
// Startup-only DNS policy: -1 refuses resolution, 0 keeps the original name,
// 1 supplies an IPv4 literal in output. Only explicit NEXTENDO consults it.
typedef int (*dm_net_dns_provider)(const char *host, char *output, size_t capacity);
void dm_net_set_dns_provider(dm_net_dns_provider provider);
// Internal host API: caller owns the CLOEXEC, non-blocking duplicate. Closing or
// reusing the guest descriptor cannot attach the duplicate to another connection.
int dm_net_dup_native(int guest);
int dm_net_dup_native_generation(int guest, uint64_t *generation);
int dm_net_close_generation(int guest, uint64_t generation);
// Discovery uses native broadcast when permitted, an optional explicit peer, or
// a bounded unicast sweep of the actual adapter. Ordinary unicast is unchanged.
int dm_net_discovery_prepare(uint32_t destination, dm_net_discovery_plan *plan);
int dm_net_discovery_target(uint32_t broadcast, uint32_t *target);
void dm_net_set_multicast_allowed(int allowed);
int dm_net_multicast_allowed(void);
#ifdef DM_NET_TEST
// Test-only adapter snapshots let real loopback datagrams exercise the complete
// production send path without probing the user's LAN or enabling broadcast.
typedef struct { uint32_t address, mask; unsigned index, flags; int local_link; } dm_net_test_interface;
void dm_net_test_set_interface(const dm_net_test_interface *interface);
unsigned dm_net_test_discovery_pending(void);
typedef long (*dm_net_test_discovery_sender)(int fd,const void *bytes,size_t size,int flags,
                                             uint32_t address,uint16_t port);
void dm_net_test_set_discovery_sender(dm_net_test_discovery_sender sender);
#endif
int dm_net_errno(void);
void dm_net_set_errno(int e);
int dm_net_socket(int family, int type, int protocol);
int dm_net_close(int fd);
void dm_net_finalize(void);
int dm_net_bind(int fd, const void *addr, unsigned len);
int dm_net_connect(int fd, const void *addr, unsigned len);
int dm_net_listen(int fd, int backlog);
int dm_net_accept(int fd, void *addr, unsigned *len);
int dm_net_name(int fd, void *addr, unsigned *len, int peer);
int dm_net_shutdown(int fd, int how);
int dm_net_fcntl(int fd, int cmd, int flags);
int dm_net_sockopt(int fd, int level, int option, void *value, unsigned *len, int set);
long dm_net_recv(int fd, void *buf, unsigned long len, int flags, void *addr, unsigned *addrlen);
long dm_net_send(int fd, const void *buf, unsigned long len, int flags, const void *addr, unsigned addrlen);
int dm_net_poll(void *fds, uint64_t count, int timeout_ms);
int dm_net_idle(void);
int dm_net_select(int nfds, void *read, void *write, void *except, const int64_t *timeout);
int dm_net_getaddrinfo(const char *host, const char *service, const void *hints, void **result);
int dm_net_getaddrinfo_legacy(const char *host, const char *service, const void *hints, void **result);
void dm_net_freeaddrinfo(void *result);
void *dm_net_gethostbyname(const char *name);
int dm_net_ipconfig(uint32_t *address, uint32_t *mask, uint32_t *gateway, uint32_t *dns1, uint32_t *dns2);
int dm_nifm_available(void);
void dm_nifm_submit_wait(void);
