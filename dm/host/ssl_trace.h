// Opt-in, bounded TLS state metadata. Never pass names, pointers or stream data.
#pragma once
#include <errno.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
    DM_TLS_HOSTNAME, DM_TLS_SOCKET, DM_TLS_VALUE, DM_TLS_OPTION,
    DM_TLS_PREPARE, DM_TLS_VERIFY, DM_TLS_HANDSHAKE, DM_TLS_CERTIFICATES,
    DM_TLS_READ, DM_TLS_WRITE
} dm_tls_stage;

static inline void dm_tls_trace(dm_tls_stage stage, uint64_t session, uint32_t result,
                                int32_t native, uint64_t detail, unsigned flags) {
    int saved = errno;
    const char *flag = getenv("DM_SSL_TRACE");
    static _Atomic unsigned events, next;
    // A nonblocking handshake polls: the same records (would-block, then the empty
    // certificate read) repeat until the peer answers. A record equal to one of the last
    // eight is left out, so the 128 records cover each connection's distinct states.
    static _Atomic uint64_t recent[8];
    if (flag && !strcmp(flag, "1")) {
        uint64_t key = 1469598103934665603ull;
        const uint64_t field[] = {stage, session, result, (uint32_t)native, detail, flags};
        for (unsigned i = 0; i < sizeof field / sizeof *field; i++) key = (key ^ field[i]) * 1099511628211ull;
        if (!key) key = 1;   // 0 marks an empty slot
        bool seen = false;
        for (unsigned i = 0; i < 8 && !seen; i++) seen = atomic_load(&recent[i]) == key;
        unsigned used = atomic_load(&events);
        while (!seen && used < 128) {
            if (atomic_compare_exchange_weak(&events, &used, used + 1)) {
                atomic_store(&recent[atomic_fetch_add(&next, 1) % 8], key);
                fprintf(stderr, "[ssl-trace] stage=%u session=%" PRIu64 " result=0x%08" PRIx32
                        " native=%" PRId32 " detail=%" PRIu64 " flags=0x%02x\n",
                        (unsigned)stage, session, result, native, detail, flags);
                break;
            }
        }
    }
    errno = saved;
}
