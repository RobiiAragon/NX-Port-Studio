// Terminal Poll metadata only. This internal header is used by the transport and its fixture.
#pragma once
#include <errno.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
    DM_POLL_COMPLETE, DM_POLL_MODE, DM_POLL_COUNT, DM_POLL_BUFFER,
    DM_POLL_ALLOC, DM_POLL_EVENTS, DM_POLL_BORROW, DM_POLL_HOST
} dm_poll_stage;

static inline void dm_poll_trace(dm_poll_stage stage, uint64_t count, int timeout,
                                 int result, int error, unsigned eventmask) {
    int saved = errno;
    const char *flag = getenv("DM_POLL_TRACE");
    static _Atomic unsigned events;
    if (flag && !strcmp(flag, "1")) {
        unsigned used = atomic_load(&events);
        while (used < 128) {
            if (atomic_compare_exchange_weak(&events, &used, used + 1)) {
                fprintf(stderr, "[poll-trace] stage=%u count=%" PRIu64 " timeout=%d result=%d errno=%d eventmask=0x%04x\n",
                        (unsigned)stage, count, timeout, result, error, eventmask);
                break;
            }
        }
    }
    errno = saved;
}
