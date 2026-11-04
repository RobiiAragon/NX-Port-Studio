// One immutable process-local endpoint contract. Publication happens before the
// first socket; invalid pre-start installation cannot fall back to ordinary WAN.
static _Atomic int g_local_session_state; // 0 absent, -1 blocked/preparing, 1 ready, 2 networking started without a pair
static dm_net_local_session g_local_session;
static dm_net_mode_t net_mode_environment(void);
static int net_error(int error);
static int net_errno(int error);
static int local_session_mode(void) {
    dm_net_mode_t mode = net_mode_environment();
    return mode == DM_NET_LAN || mode == DM_NET_LDN;
}
#if TARGET_OS_OSX
static uint64_t local_session_ms(void) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}
static int local_session_route_owned(uint32_t address, unsigned index) {
    // Exact RTM_GET also covers scoped LOCAL host routes omitted by NET_RT_DUMP.
    // This query cannot add/delete/change a route; no packet goes to the LAN.
    int fd = socket(PF_ROUTE, SOCK_RAW, 0); if (fd < 0) return 0;
    if (fcntl(fd,F_SETFD,FD_CLOEXEC) || fcntl(fd,F_SETFL,O_NONBLOCK)) { close(fd); return 0; }
    struct { struct rt_msghdr header; struct sockaddr_in destination; } request = {0};
    request.header.rtm_msglen = sizeof request; request.header.rtm_version = RTM_VERSION;
    request.header.rtm_type = RTM_GET; request.header.rtm_addrs = RTA_DST;
    request.header.rtm_pid = getpid(); request.header.rtm_seq = 1;
    request.header.rtm_flags = RTF_UP | RTF_HOST | RTF_IFSCOPE; request.header.rtm_index = (unsigned short)index;
    request.destination.sin_len = sizeof request.destination; request.destination.sin_family = AF_INET;
    request.destination.sin_addr.s_addr = address;
    if (write(fd,&request,sizeof request) != sizeof request) { close(fd); return 0; }
    int owned = 0; uint64_t deadline = local_session_ms() + 500;
    for (unsigned messages = 0; messages < 32 && local_session_ms() < deadline; messages++) {
        struct pollfd ready = {fd,POLLIN,0};
        uint64_t now=local_session_ms();if(now>=deadline)break;
        int remaining=(int)(deadline-now);
        int result = poll(&ready,1,remaining); if (result < 0 && errno == EINTR) continue;
        if (result <= 0) break;
        union { struct rt_msghdr alignment; unsigned char bytes[4096]; } reply;
        ssize_t received = read(fd,reply.bytes,sizeof reply.bytes);
        if (received < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (received < (ssize_t)sizeof(struct rt_msghdr)) break;
        struct rt_msghdr *route = (struct rt_msghdr *)reply.bytes;
        if (route->rtm_pid != getpid() || route->rtm_seq != 1 || route->rtm_type != RTM_GET) continue;
        size_t end = route->rtm_msglen, next = sizeof *route;
        if (route->rtm_version != RTM_VERSION || end < next || end > (size_t)received || route->rtm_errno ||
            (route->rtm_flags & (RTF_UP | RTF_HOST | RTF_LOCAL)) != (RTF_UP | RTF_HOST | RTF_LOCAL)) break;
        for (int slot = 0; slot < RTAX_MAX; slot++) if (route->rtm_addrs & (1 << slot)) {
            if (next + 2 > end) break;
            struct sockaddr *value = (struct sockaddr *)(reply.bytes + next);
            size_t step = value->sa_len ? (value->sa_len + sizeof(long) - 1) & ~(sizeof(long) - 1) : sizeof(long);
            if (step > end - next) break;
            if (slot == RTAX_DST && value->sa_family == AF_INET && value->sa_len >= sizeof(struct sockaddr_in) &&
                ((struct sockaddr_in *)value)->sin_addr.s_addr == address) owned = 1;
            next += step;
        }
        break;
    }
    close(fd); return owned;
}
static int local_session_assigned(uint32_t address, uint32_t *mask) {
    struct ifaddrs *list = NULL; if (getifaddrs(&list)) return 0;
    unsigned count = 0, index = 0; uint32_t found_mask = 0;
    for (struct ifaddrs *entry = list; entry; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET || !(entry->ifa_flags & IFF_UP) ||
            !entry->ifa_netmask || entry->ifa_netmask->sa_family != AF_INET) continue;
        if (((struct sockaddr_in *)entry->ifa_addr)->sin_addr.s_addr == address) {
            count++; found_mask = ((struct sockaddr_in *)entry->ifa_netmask)->sin_addr.s_addr; index = if_nametoindex(entry->ifa_name);
        }
    }
    freeifaddrs(list); if (mask) *mask = found_mask;
    return count == 1 && found_mask && index && local_session_route_owned(address,index);
}
#endif
int dm_net_local_session_install(uint32_t own, uint32_t peer) {
    int absent = 0;
    // Existing native workers cannot be retrofitted or stopped by a startup
    // request. EBUSY leaves their original transport and guest gates coherent.
    if (!atomic_compare_exchange_strong(&g_local_session_state, &absent, -1)) return net_error(16);
    if (!local_session_mode()) return net_error(13);
    if (!own || !peer || own == peer) return net_error(22);
#if TARGET_OS_OSX
    uint32_t mask = 0;
    if (!local_session_assigned(own, &mask) || !local_session_assigned(peer, NULL)) return net_error(99);
    g_local_session = (dm_net_local_session){own, peer, mask};
    atomic_store_explicit(&g_local_session_state, 1, memory_order_release);
    return 0;
#else
    return net_error(95);
#endif
}
int dm_net_local_session_get(dm_net_local_session *output) {
    if (output) *output = (dm_net_local_session){0};
    int state = atomic_load_explicit(&g_local_session_state, memory_order_acquire);
    if (!state || state == 2) return 0;
    if (state != 1 || !local_session_mode()) return -1;
    if (output) *output = g_local_session;
    return 1;
}
int dm_net_local_session_begin(void) {
    int absent=0;
    if (atomic_compare_exchange_strong(&g_local_session_state,&absent,2)) return 0;
    return absent==2 || (absent==1 && local_session_mode()) ? 0 : net_error(100);
}
int dm_net_local_session_route(uint32_t *address, int datagram, int binding) {
    dm_net_local_session session; int active = dm_net_local_session_get(&session);
    if (!active) return 0;
    if (active < 0) return net_error(100);
    if (!address) return net_error(14);
    if (binding) {
        if (!*address) *address = session.own;
        return *address == session.own ? 1 : net_error(99);
    }
    if (*address == session.own || *address == session.peer) return 1;
    uint32_t value = ntohl(*address);
    if (datagram && (value == UINT32_MAX || (value & 0xf0000000u) == 0xe0000000u ||
                     *address == (session.own | ~session.mask))) { *address = session.peer; return 1; }
    return net_error(13);
}
int dm_net_local_session_source(uint32_t address) {
    dm_net_local_session session; int active = dm_net_local_session_get(&session);
    return !active || (active > 0 && (address == session.own || address == session.peer));
}
// Implicit binds must have the same affinity as an explicit wildcard bind.
static int local_session_prepare_fd(int fd) {
    dm_net_local_session session; int active = dm_net_local_session_get(&session);
    if (!active) return 0;
    if (active < 0) return net_error(100);
    struct sockaddr_in address = {0}; socklen_t size = sizeof address;
    if (getsockname(fd, (struct sockaddr *)&address, &size)) return net_error(net_errno(errno));
    if (address.sin_addr.s_addr && address.sin_addr.s_addr != session.own) return net_error(99);
    if (!address.sin_port) {
        address.sin_len = sizeof address; address.sin_family = AF_INET; address.sin_addr.s_addr = session.own;
        if (bind(fd, (struct sockaddr *)&address, sizeof address)) return net_error(net_errno(errno));
    }
    return 0;
}

static int local_session_send_fd(int fd, int datagram, struct sockaddr_in *destination) {
    int active = dm_net_local_session_get(NULL); if (!active) return 0;
    if (active < 0) return net_error(100);
    struct sockaddr_in peer; socklen_t size = sizeof peer;
    if (!destination) {
        if (getpeername(fd, (struct sockaddr *)&peer, &size)) return net_error(datagram ? 89 : net_errno(errno));
        destination = &peer;
    }
    if (dm_net_local_session_route(&destination->sin_addr.s_addr, datagram, 0) < 0) return -1;
    return local_session_prepare_fd(fd);
}
