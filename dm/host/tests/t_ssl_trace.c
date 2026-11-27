// Exercise the numeric writer's privacy boundary without TLS, accounts or game files.
#include "../ssl_trace.h"
#include <assert.h>
#include <pthread.h>
#include <unistd.h>

static _Atomic unsigned failures;
static void *writer(void *argument) {
    uint64_t base = (uint64_t)(uintptr_t)argument * 1000;
    for (unsigned i = 0; i < 200; ++i) {   // distinct records: each may take one of the 128
        errno = EDOM;
        dm_tls_trace(DM_TLS_HANDSHAKE, UINT64_MAX, UINT32_MAX, INT32_MIN, UINT64_MAX - base - i, 0x3f);
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
        if (disabled[i]) assert(!setenv("DM_SSL_TRACE", disabled[i], 1));
        else assert(!unsetenv("DM_SSL_TRACE"));
        errno = ERANGE; dm_tls_trace(DM_TLS_HOSTNAME, 0, 0, 0, 0, 0);
        assert(errno == ERANGE);
    }
    fflush(stderr); assert(ftell(capture) == 0);
    assert(!setenv("DM_SSL_TRACE", "1", 1));
    // A polling handshake: would-block and the empty certificate read alternate until the
    // peer answers. Each state is written once; the repeats take none of the 128.
    for (unsigned i = 0; i < 500; ++i) {
        dm_tls_trace(DM_TLS_HANDSHAKE, 2, 0x1987b, -9803, 0, 0x31);
        dm_tls_trace(DM_TLS_CERTIFICATES, 2, 0x1987b, 0, 0, 0x31);
    }
    pthread_t threads[8];
    for (uintptr_t i = 0; i < 8; ++i) assert(!pthread_create(threads + i, NULL, writer, (void *)i));
    for (unsigned i = 0; i < 8; ++i) assert(!pthread_join(threads[i], NULL));
    assert(!atomic_load(&failures));
    fflush(stderr); assert(dup2(saved, STDERR_FILENO) >= 0); assert(!close(saved));
    assert(!fseek(capture, 0, SEEK_SET)); char line[256]; unsigned lines = 0;
    const char *polling[] = {"[ssl-trace] stage=6 session=2 result=0x0001987b native=-9803 detail=0 flags=0x31\n",
                             "[ssl-trace] stage=7 session=2 result=0x0001987b native=0 detail=0 flags=0x31\n"};
    const char *prefix = "[ssl-trace] stage=6 session=18446744073709551615 result=0xffffffff native=-2147483648 detail=";
    while (fgets(line, sizeof line, capture)) {
        if (lines < 2) assert(!strcmp(line, polling[lines]));
        else assert(!strncmp(line, prefix, strlen(prefix)) && strstr(line, " flags=0x3f\n"));
        ++lines;
    }
    assert(lines == 128 && !ferror(capture)); assert(!fclose(capture));
    puts("TLS trace: disabled modes, repeated polling records, concurrent 128-event bound, numeric-only fields and errno preservation PASS");
    return 0;
}
