// NEX call trace: WebSocket and PRUDP-Lite framing, RMC headers only, any other stream silent.
#include "../nex_trace.h"
#include "t_trace_capture.h"
#include <assert.h>

static unsigned checks;
#define CHECK(c) do { checks++; if (!(c)) { fprintf(stdout, "FAIL line %d: %s\n", __LINE__, #c); exit(1); } } while (0)

typedef struct { uint8_t b[4096]; size_t n; } Buf;
static void put(Buf *o, const void *p, size_t n) { assert(o->n + n <= sizeof o->b); memcpy(o->b + o->n, p, n); o->n += n; }
static void u8(Buf *o, unsigned v) { uint8_t b = (uint8_t)v; put(o, &b, 1); }
static void u16(Buf *o, unsigned v) { u8(o, v & 0xff); u8(o, v >> 8); }
static void u32(Buf *o, uint32_t v) { u16(o, v & 0xffff); u16(o, v >> 16); }
// One PRUDP-Lite packet with a 4-byte option block.
static void packet(Buf *o, unsigned type, unsigned flags, unsigned fragment, const Buf *payload) {
    u8(o, 0x80); u8(o, 4); u16(o, payload ? (unsigned)payload->n : 0); u8(o, 0x11); u8(o, 1); u8(o, 1); u8(o, fragment);
    u16(o, type | flags << 4); u16(o, 7); u32(o, 0xdeadbeef);
    if (payload) put(o, payload->b, payload->n);
}
static void frame(Buf *o, const Buf *payload, bool masked, unsigned opcode) {
    static const uint8_t key[4] = {0x12, 0x34, 0x56, 0x78};
    u8(o, 0x80 | opcode);
    if (payload->n < 126) u8(o, (masked ? 0x80 : 0) | (unsigned)payload->n);
    else { u8(o, (masked ? 0x80 : 0) | 126); u8(o, (unsigned)payload->n >> 8); u8(o, payload->n & 0xff); }
    if (masked) put(o, key, 4);
    for (size_t i = 0; i < payload->n; i++) u8(o, payload->b[i] ^ (masked ? key[i & 3] : 0));
}
static void feed_bytes(dm_nex_stream *s, bool out, const Buf *b, size_t step) {
    for (size_t i = 0; i < b->n; i += step) dm_nex_feed(s, 3, out, b->b + i, b->n - i < step ? b->n - i : step);
}

int main(void) {
    // Disabled unless exactly "1".
    const char *off[] = {NULL, "", "0", "true", "11"};
    for (unsigned i = 0; i < 5; i++) { if (off[i]) setenv("DM_NEX_TRACE", off[i], 1); else unsetenv("DM_NEX_TRACE"); CHECK(!dm_nex_enabled()); }
    setenv("DM_NEX_TRACE", "1", 1); CHECK(dm_nex_enabled());

    // Client: upgrade request, then a masked frame holding an ACK and a request of protocol 109
    // (escaped) carrying a secret-looking parameter that must not be printed.
    Buf client = {0}, request = {0}, inner = {0};
    const char *get = "GET /prudp HTTP/1.1\r\nUpgrade: websocket\r\n\r\n"; put(&client, get, strlen(get));
    u32(&request, 0); u8(&request, 0x80 | 0x7f); u16(&request, 109); u32(&request, 42); u32(&request, 38); put(&request, "SECRET-TICKET", 13);
    packet(&inner, 2, 0x001, 0, NULL); packet(&inner, 2, 0x006, 0, &request);
    frame(&client, &inner, true, 2);
    // Server: 101 reply; an unmasked frame with an error response split over two fragments,
    // a success response in a 16-bit-length frame, then a PING and a DISCONNECT.
    Buf server = {0}, error = {0}, part1 = {0}, part2 = {0}, frames = {0}, ok = {0}, big = {0};
    const char *reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n"; put(&server, reply, strlen(reply));
    u32(&error, 0); u8(&error, 0x7f); u16(&error, 109); u8(&error, 0); u32(&error, 0x80030065); u32(&error, 42);
    put(&part1, error.b, 6); put(&part2, error.b + 6, error.n - 6);
    packet(&frames, 2, 0x002, 1, &part1); packet(&frames, 2, 0x002, 0, &part2);
    frame(&server, &frames, false, 2);
    u32(&ok, 0); u8(&ok, 10); u8(&ok, 1); u32(&ok, 43); u32(&ok, 2 | 0x8000); for (unsigned i = 0; i < 200; i++) u8(&ok, 'Z');
    packet(&big, 2, 0x002, 0, &ok); packet(&big, 4, 0, 0, NULL); packet(&big, 3, 0, 0, NULL);
    frame(&server, &big, false, 2);

    for (size_t step = 1; step <= 4096; step = step * 7 + 1) {
        dm_nex_stream up = {0}, down = {0};
        TraceCapture capture = trace_capture_begin();
        feed_bytes(&up, true, &client, step); feed_bytes(&down, false, &server, step);
        char *text = trace_capture_end(capture);
        CHECK(strstr(text, "[nex-trace] session=3 send request proto=109 method=38 call=42\n"));
        CHECK(strstr(text, "[nex-trace] session=3 recv response proto=109 call=42 result=0x80030065\n"));
        CHECK(strstr(text, "[nex-trace] session=3 recv response proto=10 method=2 call=43 ok\n"));
        CHECK(strstr(text, "[nex-trace] session=3 recv disconnect\n"));
        CHECK(!strstr(text, "SECRET") && !strstr(text, "ZZ") && !strstr(text, "unparsed"));
        unsigned lines = 0; for (char *c = text; *c; c++) lines += *c == '\n'; CHECK(lines == 4);
        free(text); dm_nex_free(&up); dm_nex_free(&down);
    }

    // HTTPS and HTTP/2 streams, and a WebSocket carrying something that is not PRUDP: no RMC lines.
    const char *others[] = {"POST /v1/token HTTP/1.1\r\n\r\n{\"token\":\"SECRET\"}", "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\nSECRET", "\x16\x03\x01SECRET"};
    for (unsigned i = 0; i < 3; i++) {
        dm_nex_stream s = {0}; TraceCapture capture = trace_capture_begin();
        dm_nex_feed(&s, 4, true, others[i], strlen(others[i])); dm_nex_feed(&s, 4, true, "more SECRET", 11);
        char *text = trace_capture_end(capture); CHECK(!*text && s.phase == DM_NEX_OFF); free(text); dm_nex_free(&s);
    }
    {
        Buf junk = {0}, payload = {0}; put(&junk, get, strlen(get)); put(&payload, "SECRET-not-prudp", 16); frame(&junk, &payload, true, 2);
        dm_nex_stream s = {0}; TraceCapture capture = trace_capture_begin(); feed_bytes(&s, true, &junk, 5);
        char *text = trace_capture_end(capture);
        CHECK(strstr(text, "unparsed stream, trace stopped") && !strstr(text, "SECRET") && s.phase == DM_NEX_OFF); free(text); dm_nex_free(&s);
    }
    // A truncated RMC header reports its size only.
    {
        Buf c = {0}, inner2 = {0}, tiny = {0}; put(&c, get, strlen(get)); u32(&tiny, 0); u8(&tiny, 0x8a); u16(&tiny, 1);
        packet(&inner2, 2, 0, 0, &tiny); frame(&c, &inner2, true, 2);
        dm_nex_stream s = {0}; TraceCapture capture = trace_capture_begin(); feed_bytes(&s, true, &c, 3);
        char *text = trace_capture_end(capture); CHECK(strstr(text, "send rmc short=7\n")); free(text); dm_nex_free(&s);
    }
    printf("nex trace: %u checks passed (WebSocket and PRUDP-Lite framing, fragments, RMC headers only)\n", checks);
    return 0;
}
