// No AppKit, launch event loop or rendering: wait on this app's primary PID,
// then send its whole committed save with the existing crash-safe sync code.
#include "save_sync.h"
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 9 || strcmp(argv[1], "--parent") || strcmp(argv[3], "--ready-fd") ||
        strcmp(argv[5], "--save") || strcmp(argv[7], "--title")) return 2;
    char *end; errno = 0; long parent = strtol(argv[2], &end, 10);
    if (errno || *end || parent <= 1 || parent > INT_MAX) return 2;
    errno = 0; long ready = strtol(argv[4], &end, 10);
    if (errno || *end || ready < 3 || ready > INT_MAX || !*argv[6] || strlen(argv[8]) != 16 ||
        strspn(argv[8], "0123456789abcdefABCDEF") != 16) return 2;
    // A failed acknowledgement after the app has already exited must not kill
    // this helper before it can send the committed save.
    signal(SIGPIPE, SIG_IGN);
    int queue = kqueue(); if (queue < 0) return 3;
    struct kevent change, event;
    EV_SET(&change, (uintptr_t)parent, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(queue, &change, 1, NULL, 0, NULL)) {
        if (errno != ESRCH || getppid() == parent) { close(queue); return 3; }
        // The monitored app exited between spawn and registration.
    } else {
        (void)write((int)ready, "R", 1); close((int)ready);
        int count;
        do { count = kevent(queue, NULL, 0, &event, 1, NULL); } while (count < 0 && errno == EINTR);
        if (count != 1 || event.ident != (uintptr_t)parent || event.filter != EVFILT_PROC || !(event.fflags & NOTE_EXIT)) { close(queue); return 4; }
    }
    close(queue);
    fprintf(stderr, "save supervisor: primary host %ld exited; synchronizing committed save\n", parent);
    int synced = save_sync_after_exit(argv[6], argv[8]);
    if (!synced) fputs("launcher: the save did not reach the cloud; it goes at the next start\n", stderr);
    return synced ? 0 : 1;
}
