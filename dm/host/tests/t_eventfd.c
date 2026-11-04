// Exercise local counters through production HLE entries, plus socket regressions.
#define main socket_regression_main
#include "t_net.c"
#undef main
#include <libproc.h>

typedef int (*event_create)(unsigned long, int);
typedef int (*event_read)(int, unsigned long *);
typedef int (*event_write)(int, unsigned long);
typedef long (*file_read)(int, void *, unsigned long);
typedef long (*file_write)(int, const void *, unsigned long);
#define EVENT GET(event_create, "_ZN2nn6socket7EventFdEmNS0_12EventFdFlagsE")
#define EREAD GET(event_read, "_ZN2nn6socket11EventFdReadEiPm")
#define EWRITE GET(event_write, "_ZN2nn6socket12EventFdWriteEim")
#define READ GET(file_read, "_ZN2nn6socket4ReadEiPvm")
#define WRITE GET(file_write, "_ZN2nn6socket5WriteEiPKvm")
#define MAX_COUNTER (UINT64_MAX - 1)
static void basic(void) {
    unsetenv("DM_NETWORK");
    int probe = EVENT(0, 0);
    if (probe < 0) { fprintf(stderr, "FAIL: gRPC EventFd(0,0) availability probe, errno=%d\n", dm_net_errno()); exit(1); }
    CHECK(CLOSE(probe) == 0, "close gRPC probe offline");
    setenv("DM_NETWORK", "auto", 1); probe = EVENT(0, 0);
    CHECK(probe >= 0 && CLOSE(probe) == 0, "same availability probe succeeds in automatic mode");
    unsetenv("DM_NETWORK");
    for (int flags = 0; flags < 8; flags++) {
        unsigned long initial = 0; int counter = EVENT(2, flags);
        CHECK(counter >= 0 && EREAD(counter, &initial) == 0 && initial == (flags & 1 ? 1ul : 2ul), "all accepted creation flags preserve counter/semaphore semantics");
        CHECK(FCNTL(counter, 3, 0) == (flags & 4 ? 0x800 : 0) && CLOSE(counter) == 0, "creation nonblock uses Horizon bit4 independently of accepted bit2");
    }
    int fd = EVENT(0, 6); unsigned long value = 77;
    CHECK(fd >= 0 && !dm_net_enabled(), "gRPC EventFd(0,6) creates a local counter offline");
    CHECK(EREAD(fd, &value) == -1 && dm_net_errno() == 11 && value == 77, "nonblocking empty read leaves output unchanged");
    CHECK(EWRITE(fd, 3) == 0 && EWRITE(fd, 5) == 0, "writes add to counter");
    CHECK(EREAD(fd, &value) == 0 && value == 8, "typed read returns zero and consumes total");
    CHECK(EREAD(fd, &value) == -1 && dm_net_errno() == 11, "ordinary read cleared counter");
    CHECK(EWRITE(fd, 0) == 0 && EREAD(fd, &value) == -1 && dm_net_errno() == 11, "zero write does not create readability");
    CHECK(EVENT(UINT64_MAX, 0) == -1 && dm_net_errno() == 22, "reject all-ones initial count");
    CHECK(EVENT(0, 8) == -1 && dm_net_errno() == 22 && EVENT(0, -1) == -1 && dm_net_errno() == 22, "reject unknown flag bits");
    CHECK(EWRITE(fd, MAX_COUNTER) == 0, "retain full 64-bit counter up to maximum minus one");
    CHECK(EWRITE(fd, 1) == -1 && dm_net_errno() == 11, "full counter rejects increment before wrap");
    CHECK(EWRITE(fd, UINT64_MAX) == -1 && dm_net_errno() == 22, "all-ones increment is invalid");
    CHECK(EREAD(fd, &value) == 0 && value == MAX_COUNTER, "failed increments preserve full counter");
    CHECK(EWRITE(fd, UINT32_MAX - 1ull) == 0, "32-bit boundary is below full counter");
    dm_net_pollfd boundary = {fd, 4, 0};
    CHECK(POLL(&boundary, 1, 0) == 1 && boundary.revents == 4, "32-bit boundary remains writable");
    CHECK(EWRITE(fd, 2) == 0 && EREAD(fd, &value) == 0 && value == UINT32_MAX + 1ull, "counter crosses 32-bit maximum without truncation");
    uint64_t amount = 0x100000005ull; uint8_t bytes[16]; memset(bytes, 0xa5, sizeof bytes);
    CHECK(WRITE(fd, &amount, 7) == -1 && dm_net_errno() == 22, "short generic writes fail");
    CHECK(WRITE(fd, &amount, 8) == 8, "generic write reports eight bytes");
    CHECK(READ(fd, bytes, 7) == -1 && dm_net_errno() == 22, "short generic reads do not consume");
    CHECK(READ(fd, bytes, sizeof bytes) == 8 && !memcmp(bytes, &amount, 8) && bytes[8] == 0xa5 && bytes[15] == 0xa5, "long buffers transfer exactly eight bytes without touching tail");
    CHECK(FCNTL(fd, 3, 0) == 0x800 && FCNTL(fd, 4, 2) == 0 && FCNTL(fd, 3, 0) == 0, "Fcntl translates guest nonblock and ignores access-mode bits");
    CHECK(FCNTL(fd, 4, 0x802) == 0 && FCNTL(fd, 3, 0) == 0x800, "Fcntl toggles nonblock");
    CHECK(FCNTL(fd, 4, 0x1000) == -1 && dm_net_errno() == 22 && FCNTL(fd, 3, 0) == 0x800, "unsupported Fcntl flags preserve state");
    CHECK(FCNTL(fd, 9, 0) == -1 && dm_net_errno() == 95, "unsupported Fcntl command fails explicitly");
    CHECK(CLOSE(fd) == 0, "close counter offline");
    fd = EVENT(3, 5);
    CHECK(fd >= 0, "create semaphore");
    for (int i = 0; i < 3; i++) CHECK(EREAD(fd, &value) == 0 && value == 1, "semaphore read decrements exactly one");
    CHECK(EREAD(fd, &value) == -1 && dm_net_errno() == 11 && CLOSE(fd) == 0, "semaphore empties after exact count");
    CHECK(SOCKET(2, 2, 17) == -1 && dm_net_errno() == 100, "eventfd never enables networking");
}
static void buffers_and_readiness(void) {
    int fd = EVENT(9, 4); unsigned long value = 0;
    size_t page = (size_t)getpagesize();
    void *ro = mmap(NULL, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    CHECK(ro != MAP_FAILED && !mprotect(ro, page, PROT_READ) && !mprotect((char *)ro + page, page, PROT_NONE), "prepare invalid output mappings");
    CHECK(EREAD(fd, NULL) == -1 && dm_net_errno() == 14, "null read output returns EFAULT");
    CHECK(EREAD(fd, (void *)1) == -1 && dm_net_errno() == 14, "unmapped output returns EFAULT without a host signal");
    CHECK(EREAD(fd, ro) == -1 && dm_net_errno() == 14, "read-only output rejected");
    CHECK(EREAD(fd, (void *)((char *)ro + page)) == -1 && dm_net_errno() == 14, "PROT_NONE output rejected");
    CHECK(EREAD(fd, &value) == 0 && value == 9, "failed copyouts do not consume counter");
    CHECK(WRITE(fd, (void *)1, 8) == -1 && dm_net_errno() == 14, "unmapped input returns EFAULT");
    CHECK(WRITE(fd, (char *)ro + page, 8) == -1 && dm_net_errno() == 14, "PROT_NONE input returns EFAULT");
    CHECK(EREAD(fd, &value) == -1 && dm_net_errno() == 11, "failed copyins do not increment");
    dm_net_pollfd p = {fd, 1 | 4 | 64, 99};
    CHECK(POLL(&p, 1, 0) == 1 && p.revents == 4, "empty counter is writable only");
    CHECK(EWRITE(fd, 1) == 0 && POLL(&p, 1, 0) == 1 && p.revents == (1 | 4 | 64), "nonempty counter is readable and writable");
    CHECK(EREAD(fd, &value) == 0 && EWRITE(fd, MAX_COUNTER) == 0 && POLL(&p, 1, 0) == 1 && p.revents == (1 | 64), "full counter is not writable");
    uint64_t r[16] = {0}, w[16] = {0}; int64_t timeout[2] = {0}; r[fd / 64] = w[fd / 64] = 1ull << (fd % 64);
    CHECK(SELECT(fd + 1, r, w, NULL, timeout) == 1 && r[fd / 64] && !w[fd / 64], "Select reflects full counter readiness");
    CHECK(EREAD(fd, &value) == 0, "drain full counter");
    r[fd / 64] = w[fd / 64] = 1ull << (fd % 64);
    CHECK(SELECT(fd + 1, r, w, NULL, timeout) == 1 && !r[fd / 64] && w[fd / 64], "Select reflects empty counter readiness");
    CHECK(POLL((void *)1, 1, 0) == -1 && dm_net_errno() == 14, "Poll validates guest input");
    dm_net_pollfd *protected = (dm_net_pollfd *)ro;
    CHECK(!mprotect(ro, page, PROT_READ | PROT_WRITE), "unprotect poll input"); *protected = p;
    CHECK(!mprotect(ro, page, PROT_READ) && POLL(protected, 1, 0) == -1 && dm_net_errno() == 14, "Poll rejects read-only output without host fault");
    CHECK(SELECT(fd + 1, (void *)1, NULL, NULL, timeout) == -1 && dm_net_errno() == 14, "Select validates guest sets");
    CHECK(SELECT(fd + 1, NULL, NULL, NULL, (void *)1) == -1 && dm_net_errno() == 14, "Select validates timeval");
    CHECK(!munmap(ro, page * 2) && CLOSE(fd) == 0, "release buffer fixture");
}
struct event_job { int fd, kind, result, error; unsigned long value; _Atomic int done; };
static void *event_worker(void *input) {
    struct event_job *j = input;
    if (j->kind == 0) j->result = EREAD(j->fd, &j->value);
    else if (j->kind == 1) j->result = EWRITE(j->fd, j->value);
    else if (j->kind == 2 || j->kind == 4) { dm_net_pollfd p = {j->fd, j->kind == 4 ? 0 : 1, 0}; j->result = POLL(&p, 1, -1); j->value = (unsigned short)p.revents; }
    else { uint64_t r[16] = {0}; r[j->fd / 64] = 1ull << (j->fd % 64); j->result = SELECT(j->fd + 1, r, NULL, NULL, NULL); }
    j->error = dm_net_errno(); atomic_store(&j->done, 1); return NULL;
}
static void await_wait(unsigned before) {
    uint64_t start = now_ns();
    while ((unsigned)atomic_load(&waits) == before && now_ns() - start < 2000000000ull) usleep(1000);
    CHECK((unsigned)atomic_load(&waits) > before, "worker actually entered a pausable host wait");
}
static pthread_t start_job(struct event_job *job) {
    pthread_t thread; unsigned before = atomic_load(&waits);
    CHECK(!pthread_create(&thread, NULL, event_worker, job), "start blocking worker"); await_wait(before); return thread;
}
static void blocking_and_lifetime(void) {
    unsigned long value = 0; int fd = EVENT(0, 0);
    struct event_job j = {.fd=fd}; pthread_t thread = start_job(&j);
    CHECK(!atomic_load(&j.done) && EWRITE(fd, 123) == 0, "empty read blocks until actual write");
    CHECK(!pthread_join(thread, NULL) && j.result == 0 && j.value == 123, "blocking read wakes with real counter");
    CHECK(EWRITE(fd, MAX_COUNTER - 2) == 0, "fill counter except two slots");
    j = (struct event_job){.fd=fd,.kind=1,.value=4}; thread = start_job(&j);
    dm_net_pollfd p = {fd, 4, 0};
    CHECK(!atomic_load(&j.done) && POLL(&p, 1, 0) == 1 && p.revents == 4, "large blocked write does not confuse one-unit writable readiness");
    CHECK(EREAD(fd, &value) == 0 && value == MAX_COUNTER - 2, "read frees capacity for blocked writer");
    CHECK(!pthread_join(thread, NULL) && j.result == 0 && EREAD(fd, &value) == 0 && value == 4, "writer rechecks whole addition after wakeup");
    CHECK(CLOSE(fd) == 0, "release blocking counter");
    for (int kind = 0; kind < 5; kind++) {
        fd = EVENT(kind == 1 ? MAX_COUNTER : 0, 0);
        j = (struct event_job){.fd=fd,.kind=kind,.value=1}; thread = start_job(&j);
        CHECK(!atomic_load(&j.done) && CLOSE(fd) == 0, "close wakes an actual blocked operation");
        int replacement = EVENT(7, 4); CHECK(replacement == fd, "reuse closed guest descriptor immediately");
        CHECK(!pthread_join(thread, NULL), "closed operation returns instead of hanging");
        CHECK((kind == 2 || kind == 4) ? j.result == 1 && j.value == 32 : j.result == -1 && j.error == 9, "old wait reports invalid descriptor, never replacement readiness");
        CHECK(EREAD(replacement, &value) == 0 && value == 7 && CLOSE(replacement) == 0, "replacement counter is untouched by old wait");
    }
    fd = EVENT(0, 0); j = (struct event_job){.fd=fd}; thread = start_job(&j);
    CHECK(FCNTL(fd, 4, 0x800) == 0 && !pthread_join(thread, NULL) && j.result == -1 && j.error == 11, "Fcntl nonblock wakes blocked reader");
    CHECK(CLOSE(fd) == 0, "close Fcntl fixture");
    fd = EVENT(MAX_COUNTER, 0); j = (struct event_job){.fd=fd,.kind=1,.value=1}; thread = start_job(&j);
    CHECK(FCNTL(fd, 4, 0x800) == 0 && !pthread_join(thread, NULL) && j.result == -1 && j.error == 11, "Fcntl nonblock wakes blocked writer");
    CHECK(CLOSE(fd) == 0, "close writer Fcntl fixture");
}
struct stress_job { int fd, writing; unsigned iterations; unsigned long total; };
static void *stress_worker(void *input) {
    struct stress_job *job = input;
    for (unsigned i = 0; i < job->iterations; i++) {
        unsigned long value = 0;
        int result = job->writing ? EWRITE(job->fd, 1) : EREAD(job->fd, &value);
        if (result || (!job->writing && value != 1)) abort();
        job->total += job->writing ? 1 : value;
    }
    return NULL;
}
static unsigned open_descriptors(void) {
    int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0); assert(bytes > 0);
    void *buffer = malloc((size_t)bytes * 2); assert(buffer);
    int filled = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer, bytes * 2); assert(filled > 0);
    free(buffer); return (unsigned)filled / sizeof(struct proc_fdinfo);
}
static void mixed_and_concurrent(void) {
    int fd = EVENT(0, 1); pthread_t threads[8]; struct stress_job jobs[8];
    for (int i = 0; i < 8; i++) { jobs[i] = (struct stress_job){fd, i < 4, 2000, 0}; CHECK(!pthread_create(&threads[i], NULL, stress_worker, &jobs[i]), "start concurrent semaphore worker"); }
    unsigned long sent = 0, received = 0;
    for (int i = 0; i < 8; i++) { CHECK(!pthread_join(threads[i], NULL), "join concurrent counter worker"); if (i < 4) sent += jobs[i].total; else received += jobs[i].total; }
    CHECK(sent == 8000 && received == sent && FCNTL(fd, 4, 0x800) == 0, "concurrent semaphore traffic loses no increments");
    unsigned long value = 0; CHECK(EREAD(fd, &value) == -1 && dm_net_errno() == 11, "all concurrent increments consumed exactly once");
    setenv("DM_NETWORK", "lan", 1); int sock = SOCKET(2, 2, 17);
    CHECK(sock >= 0 && sock != fd, "socket and counter share collision-free guest namespace");
    dm_net_pollfd p[2] = {{fd, 1, 0}, {sock, 4, 0}};
    CHECK(POLL(p, 2, 0) == 1 && p[0].revents == 0 && p[1].revents == 4, "mixed poll retains native socket readiness");
    CHECK(EWRITE(fd, 1) == 0 && POLL(p, 2, 0) == 2 && p[0].revents == 1 && p[1].revents == 4, "mixed poll returns both kinds of readiness");
    CHECK(dm_net_dup_native(fd) == -1 && dm_net_errno() == 88, "TLS native socket API rejects event counters");
    CHECK(dm_net_listen(fd, 1) == -1 && dm_net_errno() == 88, "socket operations reject local counter type");
    CHECK(CLOSE(sock) == 0 && CLOSE(fd) == 0, "release mixed descriptors");
    unsetenv("DM_NETWORK");
    unsigned before = open_descriptors();
    for (int i = 0; i < 2000; i++) { int transient = EVENT(i, 6); CHECK(transient >= 0 && CLOSE(transient) == 0, "repeated create/close does not exhaust native descriptors"); }
    CHECK(open_descriptors() == before, "create/close cycles leak no native descriptors");
    fd = EVENT(0, 0); struct event_job job = {.fd=fd}; pthread_t thread = start_job(&job);
    dm_net_finalize(); CHECK(!pthread_join(thread, NULL) && job.result == -1 && job.error == 9, "Finalize closes local counters and wakes borrowers");
}
int main(void) {
    basic(); buffers_and_readiness(); blocking_and_lifetime(); mixed_and_concurrent();
    CHECK(!atomic_load(&wait_balance) && !atomic_load(&invalid_contexts) && atomic_load(&contexts_entered) == atomic_load(&contexts_left), "all blocking HLE contexts and host waits balance");
    printf("eventfd: %d checks passed\n", checks); return 0;
}
