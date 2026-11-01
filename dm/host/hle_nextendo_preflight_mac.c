// File-based Keychain UI policy is process-wide. Probe only in another instance
// of this same executable, before AppKit/guest startup, never in the renderer.
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include "nextendo_preflight_mac.h"
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
_Static_assert(sizeof(dm_nextendo_preflight_reply) == 32, "preflight wire size");
static uint64_t preflight_now(void) {
    struct timespec now; if (clock_gettime(CLOCK_MONOTONIC, &now)) return 0;
    return (uint64_t)now.tv_sec * 1000000000 + (uint64_t)now.tv_nsec;
}
static pid_t preflight_reap(pid_t child, int *status) { return waitpid(child, status, WNOHANG); }
static void preflight_reap_cancelled(void *context) {
    pid_t child = (pid_t)(intptr_t)context;
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
}
static void preflight_cancel(pid_t child) {
    int status; pid_t got;
    do { got = preflight_reap(child, &status); } while (got < 0 && errno == EINTR);
    // ECHILD means ownership was lost; that numeric PID may already be reused.
    if (got != 0) return;
    kill(child, SIGKILL);
    // Cancellation must not extend the caller's deadline. Only this owned,
    // unreaped child is handed to a temporary background reaper, with no UI.
    dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), (void *)(intptr_t)child, preflight_reap_cancelled);
}
int dm_nextendo_preflight_query(dm_nextendo_preflight_reply *out, unsigned timeout_ms) {
    if (!out) return 0; memset(out, 0, sizeof *out);
    if (!timeout_ms || timeout_ms > 5000) return 0;
    char raw[PATH_MAX], executable[PATH_MAX]; uint32_t size = sizeof raw;
    if (_NSGetExecutablePath(raw, &size) || !realpath(raw, executable)) return 0;
    int pair[2]; if (pipe(pair)) return 0;
    int writer = fcntl(pair[1], F_DUPFD_CLOEXEC, 8); close(pair[1]);
    if (writer < 0) { close(pair[0]); return 0; }
    if (fcntl(pair[0], F_SETFD, FD_CLOEXEC) || fcntl(pair[0], F_SETFL, O_NONBLOCK)) { close(pair[0]); close(writer); return 0; }
    int queue = kqueue(); if (queue < 0) { close(pair[0]); close(writer); return 0; }
    posix_spawn_file_actions_t actions; int error = posix_spawn_file_actions_init(&actions);
    if (error) { close(queue); close(pair[0]); close(writer); return 0; }
    error = posix_spawn_file_actions_addclose(&actions, pair[0]);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, writer, DM_NEXTENDO_PREFLIGHT_FD);
    if (!error) error = posix_spawn_file_actions_addclose(&actions, writer);
    for (int fd = 0; fd < 3 && !error; fd++) error = posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd ? O_WRONLY : O_RDONLY, 0);
    posix_spawnattr_t attributes; int initialized = !posix_spawnattr_init(&attributes);
    if (!initialized && !error) error = EINVAL;
    if (initialized && !error) error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    char *arguments[] = {executable, DM_NEXTENDO_PREFLIGHT_ARG, NULL}; pid_t child = -1;
    uint64_t now = preflight_now(), deadline = now + (uint64_t)timeout_ms * 1000000;
    if (!now && !error) error = EINVAL;
    // This is not a renderer launch. In particular, dyld must not run inherited
    // diagnostic constructors or injected libraries before the helper's main.
    char *environment[8] = {0}; size_t variables = 0;
    static const char *keys[] = {"HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES"};
    for (size_t i = 0; !error && i < sizeof keys / sizeof *keys; i++) {
        const char *value = getenv(keys[i]);
        if (value && asprintf(&environment[variables], "%s=%s", keys[i], value) < 0) error = ENOMEM;
        else if (value) variables++;
    }
    // The caller has already gated enabled account services. The child needs
    // no game settings, route files, account values or other DM_* switches.
    if (!error && !(environment[variables++] = strdup("DM_NETWORK=auto"))) error = ENOMEM;
    if (!error) error = posix_spawn(&child, executable, &actions, &attributes, arguments, environment);
    for (size_t i = 0; i < variables; i++) free(environment[i]);
    if (initialized) posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions); close(writer);
    if (error) { close(queue); close(pair[0]); return 0; }
    struct kevent change;
    EV_SET(&change, (uintptr_t)pair[0], EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, NULL);
    int registered = kevent(queue, &change, 1, NULL, 0, NULL) == 0;
    EV_SET(&change, (uintptr_t)child, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    // An already-exited child may reject registration. waitpid and pipe EOF
    // still establish completion; no PID is signalled merely for this error.
    (void)kevent(queue, &change, 1, NULL, 0, NULL);
    uint8_t bytes[sizeof *out + 1]; size_t count = 0; int status = 0, reaped = 0, owned = 1;
    while (registered) {
        ssize_t n;
        do { n = read(pair[0], bytes + count, sizeof bytes - count); if (n > 0) count += (size_t)n; } while (n > 0 && count < sizeof bytes);
        if (count == sizeof bytes || (n < 0 && errno != EAGAIN && errno != EINTR)) break;
        pid_t got = preflight_reap(child, &status);
        if (got == child) { reaped = 1; owned = 0; break; }
        if (got < 0 && errno != EINTR) { owned = errno != ECHILD; break; }
        now = preflight_now(); if (!now || now >= deadline) break;
        uint64_t left = deadline - now; struct timespec timeout = {(time_t)(left / 1000000000), (long)(left % 1000000000)};
        struct kevent events[2]; int ready = kevent(queue, NULL, 0, events, 2, &timeout);
        if (ready < 0 && errno != EINTR) break;
    }
    if (owned) preflight_cancel(child);
    // A child may exit between the first drain and waitpid; take its final
    // bytes after reaping as well, and reject truncation or trailing payload.
    if (reaped && count < sizeof bytes) {
        ssize_t n; do { n = read(pair[0], bytes + count, sizeof bytes - count); if (n > 0) count += (size_t)n; } while (n > 0 && count < sizeof bytes);
    }
    close(queue); close(pair[0]);
    if (!reaped || !WIFEXITED(status) || WEXITSTATUS(status) || count != sizeof *out) return 0;
    dm_nextendo_preflight_reply reply; memcpy(&reply, bytes, sizeof reply);
    if (reply.magic != DM_NEXTENDO_PREFLIGHT_MAGIC || reply.version != 1 || reply.pid != (uint32_t)child || reply.available > 1 || reply.reserved || (!reply.available && reply.expires_ms) || (reply.available && !reply.expires_ms)) return 0;
    *out = reply; return 1;
}
#endif
