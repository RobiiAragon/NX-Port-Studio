// Local Horizon event counters. The counter, descriptor ownership and readiness
// transitions share g_net_lock. Native pipes carry level notifications only:
// nobody reads a count from a pipe, so semaphore/overflow semantics stay uint64.
// Semantics: eventfd(2); Horizon flag encodings differ from Linux's constants.
#define NET_EVENT_MAX (UINT64_MAX - 1)
struct net_event {
    uint64_t value;
    unsigned refs;
    int semaphore, nonblock, closed;
    int notify[2][2], signaled[2]; // readable and writable, each a nonblocking pipe
    pthread_cond_t changed;
};
static void net_event_level(net_event *e, int side, int on) {
    if (e->signaled[side] == on) return;
    char byte = 1; ssize_t result;
    do { result = on ? write(e->notify[side][1], &byte, 1) : read(e->notify[side][0], &byte, 1); } while (result < 0 && errno == EINTR);
    // A single byte is toggled under the lock; readers/pollers never consume it.
    if (result == 1) e->signaled[side] = on;
}
static void net_event_changed(net_event *e) {
    net_event_level(e, 0, e->closed || e->value != 0);
    net_event_level(e, 1, e->closed || e->value < NET_EVENT_MAX);
    pthread_cond_broadcast(&e->changed);
}
static void net_event_release_locked(net_event *e) {
    if (--e->refs) return;
    for (int k = 0; k < 2; k++) for (int j = 0; j < 2; j++) close(e->notify[k][j]);
    pthread_cond_destroy(&e->changed); free(e);
}
static net_event *net_event_acquire(int guest) {
    pthread_mutex_lock(&g_net_lock);
    net_event *e = guest >= 0 && guest < NET_MAX && g_sockets[guest].used ? g_sockets[guest].event : NULL;
    if (e) e->refs++;
    pthread_mutex_unlock(&g_net_lock); return e;
}
int dm_net_eventfd(uint64_t value, int flags) {
    // SDK20 passes flags 6 unchanged to IPC31; public ABI definitions identify
    // semaphore=1 and nonblocking=4. Bit 2 is accepted without attributing an
    // unverified guest effect. Host notification FDs are always CLOEXEC.
    if (value == UINT64_MAX || ((unsigned)flags & ~7u)) return net_error(22);
    net_event *e = calloc(1, sizeof *e); if (!e) return net_error(12);
    for (int k = 0; k < 2; k++) for (int j = 0; j < 2; j++) e->notify[k][j] = -1;
    int error = pthread_cond_init(&e->changed, NULL);
    if (error) { free(e); return net_error(net_errno(error)); }
    for (int k = 0; k < 2; k++) {
        if (pipe(e->notify[k])) { error = errno; goto fail; }
        for (int j = 0; j < 2; j++) if (fcntl(e->notify[k][j], F_SETFL, O_NONBLOCK) < 0 || fcntl(e->notify[k][j], F_SETFD, FD_CLOEXEC) < 0) { error = errno; goto fail; }
    }
    e->value = value; e->semaphore = !!(flags & 1); e->nonblock = !!(flags & 4); e->refs = 1;
    pthread_mutex_lock(&g_net_lock);
    int fd; for (fd = 0; fd < NET_MAX && g_sockets[fd].used; fd++) {}
    if (fd < NET_MAX) {
        uint64_t generation = g_sockets[fd].generation + 1;
        g_sockets[fd] = (net_slot){-1, 1, 0, 0, generation, -1, -1, e};
        net_event_changed(e);
    }
    pthread_mutex_unlock(&g_net_lock);
    if (fd < NET_MAX) return fd;
    error = EMFILE;
fail:
    for (int k = 0; k < 2; k++) for (int j = 0; j < 2; j++) if (e->notify[k][j] >= 0) close(e->notify[k][j]);
    pthread_cond_destroy(&e->changed); free(e); return net_error(net_errno(error));
}
// Kernel copies reject unmapped/read-only/PROT_NONE guest spans instead of
// faulting in the host. Preparing copyout first preserves graphics dirty tracking.
static int net_guest_copyin(void *target, const void *source, size_t size) {
    vm_size_t copied = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)(uintptr_t)source, size,
                             (vm_address_t)(uintptr_t)target, &copied) == KERN_SUCCESS && copied == size ? 0 : net_error(14);
}
static int net_guest_copyout(void *target, const void *source, size_t size) {
    dm_guest_write_prepare(target, size);
    return vm_write(mach_task_self(), (vm_address_t)(uintptr_t)target, (vm_offset_t)(uintptr_t)source,
                    (mach_msg_type_number_t)size) == KERN_SUCCESS ? 0 : net_error(14);
}
// Entered/returned with g_net_lock held. Recheck after publishing the wait so a
// write/close between unlocking and cond_wait cannot be lost. The bounded wait
// also permits guest pause/resume; it never turns into a guest-visible timeout.
static void net_event_wait(net_event *e, int writing, uint64_t value) {
    pthread_mutex_unlock(&g_net_lock); dm_guest_host_wait_begin(); pthread_mutex_lock(&g_net_lock);
    int blocked = writing ? value > NET_EVENT_MAX - e->value : !e->value;
    if (!e->closed && !e->nonblock && blocked) {
        struct timespec deadline = {0, NET_SLICE_MS * 1000000};
        pthread_cond_timedwait_relative_np(&e->changed, &g_net_lock, &deadline);
    }
    pthread_mutex_unlock(&g_net_lock); dm_guest_host_wait_end(); pthread_mutex_lock(&g_net_lock);
}
static long net_event_read(net_event *e, void *buffer, unsigned long size) {
    pthread_mutex_lock(&g_net_lock); long result;
    if (size < sizeof(uint64_t)) { result = net_error(22); goto done; }
    for (;;) {
        if (e->closed) { result = net_error(9); break; }
        if (e->value) {
            uint64_t value = e->semaphore ? 1 : e->value;
            if (net_guest_copyout(buffer, &value, sizeof value)) { result = -1; break; }
            e->value -= value; net_event_changed(e); result = sizeof value; break;
        }
        if (e->nonblock) { result = net_error(11); break; }
        net_event_wait(e, 0, 0);
    }
done:
    net_event_release_locked(e); pthread_mutex_unlock(&g_net_lock); return result;
}
static long net_event_write(net_event *e, const void *buffer, unsigned long size) {
    uint64_t value = 0; long result;
    // Copy once before any wait: an interrupted writer never rereads mutable
    // caller memory, and EFAULT/invalid increments leave the counter untouched.
    int error = size < sizeof value ? net_error(22) : net_guest_copyin(&value, buffer, sizeof value);
    pthread_mutex_lock(&g_net_lock);
    if (error) { result = -1; goto done; }
    if (value == UINT64_MAX) { result = net_error(22); goto done; }
    for (;;) {
        if (e->closed) { result = net_error(9); break; }
        if (value <= NET_EVENT_MAX - e->value) { e->value += value; net_event_changed(e); result = sizeof value; break; }
        if (e->nonblock) { result = net_error(11); break; }
        net_event_wait(e, 1, value);
    }
done:
    net_event_release_locked(e); pthread_mutex_unlock(&g_net_lock); return result;
}
long dm_net_read(int fd, void *buffer, unsigned long size) {
    net_event *e = net_event_acquire(fd);
    return e ? net_event_read(e, buffer, size) : dm_net_recv(fd, buffer, size, 0, NULL, NULL);
}
long dm_net_write(int fd, const void *buffer, unsigned long size) {
    net_event *e = net_event_acquire(fd);
    return e ? net_event_write(e, buffer, size) : dm_net_send(fd, buffer, size, 0, NULL, 0);
}
int dm_net_eventfd_read(int fd, uint64_t *value) { return dm_net_read(fd, value, sizeof *value) == sizeof *value ? 0 : -1; }
int dm_net_eventfd_write(int fd, uint64_t value) { return dm_net_write(fd, &value, sizeof value) == sizeof value ? 0 : -1; }
#undef NET_EVENT_MAX
