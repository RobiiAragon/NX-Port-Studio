// Synthetic OS interface/routing fixtures. No network scan or real peer needed.
#include "../net_socket.h"
#include <assert.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/route.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/sockio.h>
#include <sys/sysctl.h>

static struct ifaddrs interfaces[3];
static struct sockaddr_in addresses[3], masks[3];
static unsigned primary = 1, count = 3, checks;
static const char *const names[] = {"test-tunnel", "test-wifi", "test-ethernet"};
static const uint32_t ips[] = {0xc0000202, 0xc633640a, 0xcb00710a};
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); abort(); } } while (0)

static unsigned fixture_index(const char *name) {
    for (unsigned i = 0; i < 3; ++i) if (!strcmp(name, names[i])) return i + 1;
    return 0;
}
static int fixture_interfaces(struct ifaddrs **out) { *out = count ? interfaces : NULL; return 0; }
static void fixture_free_interfaces(struct ifaddrs *list) { (void)list; }
static int fixture_ioctl(int fd, unsigned long request, ...) {
    (void)fd; va_list args; va_start(args, request); struct ifreq *r = va_arg(args, struct ifreq *); va_end(args);
    assert(request == SIOCGIFFUNCTIONALTYPE);
    unsigned i = fixture_index(r->ifr_name);
    r->ifr_ifru.ifru_functional_type = i == 2 ? IFRTYPE_FUNCTIONAL_WIFI_INFRA : i == 3 ? IFRTYPE_FUNCTIONAL_WIRED : IFRTYPE_FUNCTIONAL_UNKNOWN;
    return 0;
}
static int fixture_sysctl(const int *mib, unsigned mib_count, void *out, size_t *size, const void *in, size_t input_size) {
    (void)in; (void)input_size;
    assert(mib_count == 6 && mib[0] == CTL_NET && mib[1] == PF_ROUTE);
    struct { struct rt_msghdr header; struct sockaddr_in destination, gateway; } route = {0};
    route.header.rtm_msglen = sizeof route; route.header.rtm_flags = RTF_UP | RTF_GATEWAY;
    route.header.rtm_addrs = RTA_DST | RTA_GATEWAY; route.header.rtm_index = primary;
    route.destination = (struct sockaddr_in){.sin_len = sizeof route.destination, .sin_family = AF_INET};
    route.gateway = (struct sockaddr_in){.sin_len = sizeof route.gateway, .sin_family = AF_INET, .sin_addr = {htonl(0xc0000201)}};
    if (out) memcpy(out, &route, sizeof route);
    *size = primary ? sizeof route : 0; return 0;
}
#define getifaddrs fixture_interfaces
#define freeifaddrs fixture_free_interfaces
#define if_nametoindex fixture_index
#define ioctl fixture_ioctl
#define sysctl fixture_sysctl
#include "../hle_net_backend.c"
#undef getifaddrs
#undef freeifaddrs
#undef if_nametoindex
#undef ioctl
#undef sysctl

void dm_guest_host_wait_begin(void) {}
void dm_guest_host_wait_end(void) {}
uint32_t dm_nsd_resolve(void *out, const void *name) { (void)out; (void)name; return 1; }
static void initialize(void) {
    for (unsigned i = 0; i < 3; ++i) {
        addresses[i] = (struct sockaddr_in){.sin_len = sizeof addresses[i], .sin_family = AF_INET, .sin_addr = {htonl(ips[i])}};
        masks[i] = (struct sockaddr_in){.sin_len = sizeof masks[i], .sin_family = AF_INET, .sin_addr = {htonl(0xffffff00)}};
        interfaces[i] = (struct ifaddrs){.ifa_next = i + 1 < count ? interfaces + i + 1 : NULL, .ifa_name = (char *)names[i],
            .ifa_flags = IFF_UP | (i ? IFF_BROADCAST : IFF_POINTOPOINT), .ifa_addr = (struct sockaddr *)&addresses[i], .ifa_netmask = (struct sockaddr *)&masks[i]};
    }
}
int main(void) {
    initialize(); unsetenv("DM_NETWORK_INTERFACE"); unsetenv("DM_NET_DISCOVERY_PEER");
    setenv("DM_NETWORK", "auto", 1); dm_net_set_multicast_allowed(0);
    uint32_t ip, gateway; dm_net_discovery_plan plan;
    CHECK(!dm_net_ipconfig(&ip, NULL, &gateway, NULL, NULL) && ip == htonl(ips[0]) && gateway == htonl(0xc0000201));
    CHECK(!dm_net_discovery_prepare(htonl(UINT32_MAX), &plan) && plan.local == ips[1]);
    CHECK(net_is_discovery(htonl(ips[1] | 0xff), 2));
    CHECK(!net_is_discovery(htonl(ips[0] | 0xff), 2));
    setenv("DM_NETWORK", "lan", 1); CHECK(!dm_net_ipconfig(&ip, NULL, &gateway, NULL, NULL) && ip == htonl(ips[1]) && !gateway);
    setenv("DM_NETWORK", "ldn", 1); CHECK(!dm_net_ipconfig(&ip, NULL, NULL, NULL, NULL) && ip == htonl(ips[1]));
    setenv("DM_NETWORK", "nextendo", 1); CHECK(!dm_net_ipconfig(&ip, NULL, &gateway, NULL, NULL) && ip == htonl(ips[0]) && gateway == htonl(0xc0000201));
    setenv("DM_NETWORK", "auto", 1);
    // Prefer the routed physical adapter when Ethernet and Wi-Fi both exist.
    primary = 3; CHECK(!dm_net_discovery_prepare(htonl(UINT32_MAX), &plan) && plan.local == ips[2]);
    primary = 2; interfaces[1].ifa_flags &= ~IFF_UP;
    CHECK(!dm_net_discovery_prepare(htonl(UINT32_MAX), &plan) && plan.local == ips[2]);
    interfaces[1].ifa_flags |= IFF_UP;
    primary = 0; CHECK(!dm_net_discovery_prepare(htonl(UINT32_MAX), &plan) && plan.local == ips[1]);
    primary = 1; setenv("DM_NETWORK_INTERFACE", names[2], 1);
    CHECK(!dm_net_discovery_prepare(htonl(UINT32_MAX), &plan) && plan.local == ips[2]);
    setenv("DM_NETWORK_INTERFACE", names[0], 1);
    CHECK(dm_net_discovery_prepare(htonl(UINT32_MAX), &plan) < 0 && dm_net_errno() == 99);
    unsetenv("DM_NETWORK_INTERFACE"); count = 1; initialize();
    CHECK(dm_net_discovery_prepare(htonl(UINT32_MAX), &plan) < 0 && dm_net_errno() == 99);
    CHECK(!dm_net_ipconfig(&ip, NULL, NULL, NULL, NULL) && ip == htonl(ips[0]));
    printf("local interface selection: %u checks passed (VPN, Wi-Fi, Ethernet, overrides, no local adapter).\n", checks);
    return 0;
}
