// Exercise the same metadata writer without sockets, accounts or game data.
#include "../poll_trace.h"
#include <assert.h>
#include <pthread.h>
#include <unistd.h>

static _Atomic unsigned failures;
static void *writer(void *unused) {
    (void)unused;
    for (unsigned i = 0; i < 200; ++i) {
        errno = EDOM;
        dm_poll_trace(DM_POLL_HOST, UINT64_MAX, -1, -1, 22, 0x1ff);
        if (errno != EDOM) atomic_fetch_add(&failures, 1);
    }
    return NULL;
}
int main(void) {
    FILE *capture = tmpfile(); assert(capture);
    fflush(stderr); int saved = dup(STDERR_FILENO); assert(saved >= 0);
    assert(dup2(fileno(capture), STDERR_FILENO) >= 0);
    const char *disabled[] = {NULL, "", "0", "true", "01", "1x"};
    for (unsigned i = 0; i < sizeof disabled / sizeof *disabled; ++i) {
        if (disabled[i]) assert(!setenv("DM_POLL_TRACE", disabled[i], 1));
        else assert(!unsetenv("DM_POLL_TRACE"));
        errno = ERANGE; dm_poll_trace(DM_POLL_COMPLETE, 0, 0, 0, 0, 0);
        assert(errno == ERANGE);
    }
    fflush(stderr); assert(ftell(capture) == 0);
    assert(!setenv("DM_POLL_TRACE", "1", 1));
    pthread_t threads[8];
    for (unsigned i = 0; i < 8; ++i) assert(!pthread_create(threads + i, NULL, writer, NULL));
    for (unsigned i = 0; i < 8; ++i) assert(!pthread_join(threads[i], NULL));
    assert(!atomic_load(&failures));
    fflush(stderr); assert(dup2(saved, STDERR_FILENO) >= 0); assert(!close(saved));
    assert(!fseek(capture, 0, SEEK_SET)); char line[256]; unsigned lines = 0;
    while (fgets(line, sizeof line, capture)) {
        // Exact permitted keys and full-width numeric arguments; nothing else can escape.
        assert(!strcmp(line, "[poll-trace] stage=7 count=18446744073709551615 timeout=-1 result=-1 errno=22 eventmask=0x01ff\n"));
        ++lines;
    }
    assert(lines == 128 && !ferror(capture)); assert(!fclose(capture));
    puts("Poll trace: disabled modes, concurrent 128-event bound and errno preservation PASS");
    return 0;
}
