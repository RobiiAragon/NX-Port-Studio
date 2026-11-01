#include "save_supervisor.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;

int dm_mac_save_supervisor_start(const char *helper, const char *save, const char *title) {
    const char *cloud = getenv("DM_SAVE_SYNC");
    if (!cloud || !*cloud || !strcmp(cloud, "0")) return 1;
    int pair[2]; if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) return 0;
    if (fcntl(pair[0], F_SETFD, FD_CLOEXEC) || fcntl(pair[1], F_SETFD, FD_CLOEXEC)) { close(pair[0]); close(pair[1]); return 0; }
    char parent[32]; snprintf(parent, sizeof parent, "%d", getpid());
    char *args[] = {(char *)helper, "--parent", parent, "--ready-fd", "3", "--save", (char *)save, "--title", (char *)title, NULL};
    posix_spawn_file_actions_t actions; int error = posix_spawn_file_actions_init(&actions);
    if (error) { close(pair[0]); close(pair[1]); return 0; }
    error = posix_spawn_file_actions_addclose(&actions, pair[0]);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, pair[1], 3);
    if (!error && pair[1] != 3) error = posix_spawn_file_actions_addclose(&actions, pair[1]);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDOUT_FILENO);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO);
    if (error) { posix_spawn_file_actions_destroy(&actions); close(pair[0]); close(pair[1]); return 0; }
    posix_spawnattr_t attr; error = posix_spawnattr_init(&attr);
    if (error) { posix_spawn_file_actions_destroy(&actions); close(pair[0]); close(pair[1]); return 0; }
    // Its own process group survives a terminal signal sent to the game group.
    error = posix_spawnattr_setpgroup(&attr, 0);
    if (!error) error = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
    pid_t child = -1;
    if (!error) error = posix_spawn(&child, helper, &actions, &attr, args, environ);
    posix_spawnattr_destroy(&attr); posix_spawn_file_actions_destroy(&actions); close(pair[1]);
    if (error) { close(pair[0]); fprintf(stderr, "[RED] launcher: save supervisor could not start: %s\n", strerror(error)); return 0; }
    struct pollfd ready = {.fd=pair[0], .events=POLLIN}; int polled;
    do { polled = poll(&ready, 1, 5000); } while (polled < 0 && errno == EINTR);
    char ack = 0; ssize_t count = polled > 0 ? read(pair[0], &ack, 1) : -1; close(pair[0]);
    if (count != 1 || ack != 'R') {
        // This is only cancellation before readiness/guest boot. A broken
        // helper may ignore SIGTERM; it must not trap the app in waitpid.
        kill(child, SIGKILL); while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        fputs("[RED] launcher: save supervisor did not arm; the game was not started\n", stderr); return 0;
    }
    fprintf(stderr, "launcher: cloud save supervisor %d monitors primary host %d\n", child, getpid());
    return 1;
}
