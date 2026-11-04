// Horizon's BSD C header: switchbrew/libnx nx/external/bsd/include/sys/socket.h.
// SDK20's C and named wrappers copy the same 48-byte header; both return ssize_t.
// This implementation owns descriptor/header/vector snapshots, never guest data.
enum { NET_MESSAGE_IOV_MAX = 1024 };
_Static_assert(sizeof(long) == 8 && sizeof(dm_net_iovec) == 16, "Horizon ssize_t and iovec");
_Static_assert(sizeof(dm_net_msghdr) == 48 && offsetof(dm_net_msghdr, name_size) == 8 && offsetof(dm_net_msghdr, vectors) == 16 &&
               offsetof(dm_net_msghdr, count) == 24 && offsetof(dm_net_msghdr, control) == 32 &&
               offsetof(dm_net_msghdr, control_size) == 40 && offsetof(dm_net_msghdr, flags) == 44, "Horizon msghdr");
typedef struct { dm_net_msghdr header; struct iovec *vectors; size_t size; } net_message;
static int net_message_load(net_message *m, const void *input) {
    memset(m, 0, sizeof *m);
    if (!input || (uintptr_t)input > UINTPTR_MAX - sizeof m->header || net_guest_copyin(&m->header, input, sizeof m->header)) return net_error(14);
    if (m->header.count < 0 || m->header.count > NET_MESSAGE_IOV_MAX) return net_error(22);
    // Ancillary ABI translation is not implemented. Never silently discard
    // requested control bytes or pass native descriptors/credentials to a guest.
    if (m->header.control_size) return net_error(95);
    if (!m->header.count) return 0;
    size_t bytes = (size_t)m->header.count * sizeof(dm_net_iovec);
    if (!m->header.vectors || (uintptr_t)m->header.vectors > UINTPTR_MAX - bytes) return net_error(14);
    dm_net_iovec *snapshot = malloc(bytes);
    m->vectors = calloc((size_t)m->header.count, sizeof *m->vectors);
    if (!snapshot || !m->vectors) { free(snapshot); free(m->vectors); m->vectors = NULL; return net_error(12); }
    int result = net_guest_copyin(snapshot, m->header.vectors, bytes);
    for (int i = 0; !result && i < m->header.count; i++) {
        uint64_t size = snapshot[i].size; uintptr_t address = (uintptr_t)snapshot[i].base;
        if (size > SSIZE_MAX || size > (uint64_t)SSIZE_MAX - m->size) result = net_error(22);
        else if (size && (!address || address > UINTPTR_MAX - size)) result = net_error(14);
        else { m->vectors[i] = (struct iovec){snapshot[i].base, (size_t)size}; m->size += (size_t)size; }
    }
    free(snapshot);
    if (result) { free(m->vectors); m->vectors = NULL; }
    return result;
}
static int net_message_output(void *output, uint32_t name_size, int flags) {
    // Publish only value-result fields. The caller's pointers, vector lengths,
    // padding and control pointer are never overwritten with native/snapshot data.
    uint32_t zero = 0;
    return net_guest_copyout((char *)output + offsetof(dm_net_msghdr, name_size), &name_size, sizeof name_size) ||
           net_guest_copyout((char *)output + offsetof(dm_net_msghdr, control_size), &zero, sizeof zero) ||
           net_guest_copyout((char *)output + offsetof(dm_net_msghdr, flags), &flags, sizeof flags) ? -1 : 0;
}
static int net_message_preflight(void *output, const net_message *m) {
    // Reject a non-writable header before receiving a datagram. Writing the
    // unchanged snapshot fields does not fabricate a received result.
    return net_guest_copyout((char *)output + offsetof(dm_net_msghdr, name_size), &m->header.name_size, 4) ||
           net_guest_copyout((char *)output + offsetof(dm_net_msghdr, control_size), &m->header.control_size, 4) ||
           net_guest_copyout((char *)output + offsetof(dm_net_msghdr, flags), &m->header.flags, 4) ? -1 : 0;
}
static void net_message_advance(struct iovec **vectors, int *count, size_t size) {
    while (*count && size >= (*vectors)->iov_len) {
        size -= (*vectors)->iov_len; (*vectors)++; (*count)--;
    }
    if (size && *count) { (*vectors)->iov_base = (char *)(*vectors)->iov_base + size; (*vectors)->iov_len -= size; }
}
static int net_message_received_flags(int flags) {
    int out = 0;
    if (flags & MSG_OOB) out |= 1;
    if (flags & MSG_EOR) out |= 8;
    if (flags & MSG_TRUNC) out |= 0x10;
    if (flags & MSG_CTRUNC) out |= 0x20;
    if (flags & MSG_EOF) out |= 0x100;
    return out;
}
static long net_message_receive(int guest, void *output, int flags) {
    if (!net_gate()) return -1;
    int native_flags = net_message_flags(flags, 0); if (native_flags < 0) return -1;
    if ((flags & (2 | 0x40)) == (2 | 0x40)) return net_error(95);
    net_message m; if (net_message_load(&m, output)) return -1;
    net_ref r; if (net_borrow(guest, &r)) { free(m.vectors); return -1; }
    long result = -1; size_t total = 0; int output_flags = 0, count = m.header.count;
    struct iovec *vectors = m.vectors; uint64_t start = net_ms(); struct sockaddr_in address = {0};
    for (;;) {
        if (net_message_preflight(output, &m)) break;
        for (int i = 0; i < count; i++) dm_guest_write_prepare(vectors[i].iov_base, vectors[i].iov_len);
        // Darwin returns immediately for an entirely empty vector, without
        // dequeuing a UDP packet. Receive at most one private byte instead so
        // a zero-capacity datagram still has real arrival/consumption semantics.
        char empty_byte, control_byte; struct iovec empty = {m.size ? NULL : &empty_byte, r.type == 2 && !m.size ? 1u : 0u};
        // A null/zero Darwin control buffer suppresses even MSG_CTRUNC. One
        // private scratch byte preserves the actual truncation signal for the
        // guest's zero capacity; no native ancillary bytes/descriptors escape.
        struct msghdr native = {.msg_name = m.header.name ? &address : NULL,
            .msg_namelen = m.header.name ? sizeof address : 0, .msg_iov = m.size && count ? vectors : &empty, .msg_iovlen = m.size && count ? count : 1,
            .msg_control = &control_byte, .msg_controllen = 1};
        ssize_t got = recvmsg(r.fd, &native, native_flags); int error = errno;
        if (got < 0) {
            if (error != EAGAIN || r.nonblock || (flags & 0x80)) { if (!total) result = net_error(net_errno(error)); break; }
            if (net_wait(&r, (flags & 1) ? POLLPRI : POLLIN, r.recv_ms, start)) break;
            continue;
        }
        if (!m.size && r.type == 2 && got) { native.msg_flags |= MSG_TRUNC; got = 0; }
        total += (size_t)got; result = (long)total; output_flags |= net_message_received_flags(native.msg_flags);
        if (!got || r.type != 1 || !(flags & 0x40) || r.nonblock || (flags & 0x80) || total == m.size) break;
        net_message_advance(&vectors, &count, (size_t)got);
    }
    // A partial WAITALL read remains a real partial result on timeout/close.
    if (total && result >= 0) result = (long)total;
    if (result >= 0) {
        uint32_t name_size = m.header.name && address.sin_family ? sizeof(nx_addr) : 0;
        if (name_size && m.header.name_size) {
            nx_addr guest_address = {.len = sizeof guest_address, .family = 2, .port = address.sin_port, .address = address.sin_addr.s_addr};
            size_t bytes = m.header.name_size < sizeof guest_address ? m.header.name_size : sizeof guest_address;
            if (net_guest_copyout(m.header.name, &guest_address, bytes)) result = -1;
        }
        if (result >= 0 && net_message_output(output, name_size, output_flags)) result = -1;
    }
    close(r.fd); free(m.vectors); return result;
}
static long net_message_send(int guest, const void *input, int flags) {
    if (!net_gate()) return -1;
    // The guest's BSD MSG_NOSIGNAL is distinct from Darwin's. Translate it per
    // call even if the guest has subsequently disabled native SO_NOSIGPIPE.
    unsigned permitted_signal = 0x20000u;
    int native_flags = net_message_flags((int)((unsigned)flags & ~permitted_signal), 1); if (native_flags < 0) return -1;
    if ((unsigned)flags & permitted_signal) native_flags |= MSG_NOSIGNAL;
    net_message m; if (net_message_load(&m, input)) return -1;
    struct sockaddr_in address; int have_address = m.header.name != NULL;
    if (have_address) {
        nx_addr copied;
        if (m.header.name_size < sizeof copied) { free(m.vectors); return net_error(22); }
        if (net_guest_copyin(&copied, m.header.name, sizeof copied) || net_addr_in(&copied, sizeof copied, &address)) { free(m.vectors); return -1; }
    }
    net_ref r; if (net_borrow(guest, &r)) { free(m.vectors); return -1; }
    long result = -1; void *packet = NULL; int discovery = have_address && net_is_discovery(address.sin_addr.s_addr, r.type);
    if (discovery) {
        // Discovery queues inspect a contiguous datagram. Preserve their exact
        // policy/lifetime path instead of bypassing automatic iOS discovery.
        if (m.size > 65507) { net_error(90); goto done; }
        packet = malloc(m.size ? m.size : 1); if (!packet) { net_error(12); goto done; }
        size_t offset = 0;
        for (int i = 0; i < m.header.count; i++) {
            if (m.vectors[i].iov_len && net_guest_copyin((char *)packet + offset, m.vectors[i].iov_base, m.vectors[i].iov_len)) goto done;
            offset += m.vectors[i].iov_len;
        }
        dm_net_discovery_plan plan;
        if (dm_net_discovery_prepare(address.sin_addr.s_addr, &plan)) goto done;
        if (plan.automatic) { result = net_discovery_enqueue(&r, plan, address, packet, m.size, native_flags); goto done; }
        address.sin_addr.s_addr = plan.target;
    }
    uint64_t start = net_ms();
    for (;;) {
        struct iovec empty = {NULL,0};
        struct msghdr native = {.msg_name = have_address ? &address : NULL, .msg_namelen = have_address ? sizeof address : 0,
            .msg_iov = m.size ? m.vectors : &empty, .msg_iovlen = m.size ? m.header.count : 1};
        result = discovery ? net_discovery_packet(r.fd, packet, m.size, native_flags, &address) : sendmsg(r.fd, &native, native_flags); int error = errno;
        if (result >= 0) break;
        if (error != EAGAIN || r.nonblock || (flags & 0x80)) { result = net_error(net_errno(error)); break; }
        if (net_wait(&r, POLLOUT, r.send_ms, start)) { result = -1; break; }
    }
    if (result >= 0 && discovery && dm_discovery_query_protocol(ntohs(address.sin_port), packet, m.size)) {
        dm_net_discovery_plan extra; int saved = t_net_errno;
        if (dm_net_discovery_supplement(address.sin_addr.s_addr, &extra)) net_discovery_enqueue(&r, extra, address, packet, m.size, native_flags);
        t_net_errno = saved;
    }
done:
    free(packet); close(r.fd); free(m.vectors); return result;
}
long dm_net_recvmsg(int guest, void *message, int flags) {
    long result = net_message_receive(guest, message, flags); int saved = errno;
    net_trace("recvmsg", guest, result); errno = saved; return result;
}
long dm_net_sendmsg(int guest, const void *message, int flags) {
    long result = net_message_send(guest, message, flags); int saved = errno;
    net_trace("sendmsg", guest, result); errno = saved; return result;
}
