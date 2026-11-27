// Opt-in NEX call trace (DM_NEX_TRACE=1): follows the plaintext of a TLS stream that carries
// PRUDP-Lite over a WebSocket and prints, for each RMC message, only its direction, protocol,
// method, call ID and, for a response, success or its result code. Parameters and return
// values (tickets, tokens, names, addresses) are never printed. Any other stream (HTTPS, gRPC)
// stops at its first bytes and prints nothing.
//
// Framing, from Nextendo's PRUDP and RMC description (wiki.nextendo.network/architecture/prudp-rmc):
// PRUDP-Lite packet: u8 magic 0x80, u8 options size, u16 payload size, u8 stream types,
// u8 source port, u8 destination port, u8 fragment ID, u16 type (low 4 bits) and flags,
// u16 sequence ID; then the options, then the payload. Type 2 is DATA; flag 0x001 is ACK.
// A fragmented message's last fragment has fragment ID 0.
// RMC: u32 size, u8 protocol (bit 7: request; 0x7f escapes a u16 protocol), then a request's
// u32 call ID and u32 method, or a response's bool success and either u32 call ID and
// u32 method | 0x8000, or u32 result and u32 call ID. All little-endian.
#pragma once
#include <errno.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { DM_NEX_LIMIT = 1 << 18, DM_NEX_LINES = 1024 };
typedef enum { DM_NEX_START, DM_NEX_HEADER, DM_NEX_FRAMES, DM_NEX_OFF } dm_nex_phase;
typedef struct {
    dm_nex_phase phase;
    uint8_t head[14]; unsigned head_len;          // WebSocket frame header being read
    uint64_t frame_left; uint8_t mask[4]; unsigned mask_at; bool masked, binary;
    uint32_t window;                              // last four bytes of the HTTP header
    uint8_t *packets; size_t packets_len;         // WebSocket payload not yet split into PRUDP packets
    uint8_t *message; size_t message_len;         // DATA payload fragments of one RMC message
} dm_nex_stream;

static inline bool dm_nex_enabled(void) { const char *s = getenv("DM_NEX_TRACE"); return s && !strcmp(s, "1"); }
static inline void dm_nex_free(dm_nex_stream *s) { free(s->packets); free(s->message); memset(s, 0, sizeof *s); s->phase = DM_NEX_OFF; }
static inline uint32_t dm_nex_u32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static inline uint16_t dm_nex_u16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

static inline void dm_nex_line(uint64_t session, bool out, const char *format, ...) __attribute__((format(printf, 3, 4)));
static inline void dm_nex_line(uint64_t session, bool out, const char *format, ...) {
    static _Atomic unsigned lines;
    if (atomic_fetch_add(&lines, 1) >= DM_NEX_LINES) return;
    char text[160]; __builtin_va_list list; __builtin_va_start(list, format); vsnprintf(text, sizeof text, format, list); __builtin_va_end(list);
    int saved = errno; fprintf(stderr, "[nex-trace] session=%" PRIu64 " %s %s\n", session, out ? "send" : "recv", text); errno = saved;
}

static inline void dm_nex_rmc(uint64_t session, bool out, const uint8_t *p, size_t n) {
    if (n < 5) { dm_nex_line(session, out, "rmc short=%zu", n); return; }
    size_t at = 4; uint8_t first = p[at++]; bool request = first & 0x80; unsigned protocol = first & 0x7f;
    if (protocol == 0x7f) { if (n < at + 2) { dm_nex_line(session, out, "rmc short=%zu", n); return; } protocol = dm_nex_u16(p + at); at += 2; }
    if (request) {
        if (n < at + 8) { dm_nex_line(session, out, "rmc short=%zu", n); return; }
        dm_nex_line(session, out, "request proto=%u method=%u call=%u", protocol, dm_nex_u32(p + at + 4), dm_nex_u32(p + at));
    } else if (n >= at + 1 && p[at]) {
        if (n < at + 9) { dm_nex_line(session, out, "rmc short=%zu", n); return; }
        dm_nex_line(session, out, "response proto=%u method=%u call=%u ok", protocol, dm_nex_u32(p + at + 5) & ~0x8000u, dm_nex_u32(p + at + 1));
    } else {
        if (n < at + 9) { dm_nex_line(session, out, "rmc short=%zu", n); return; }
        dm_nex_line(session, out, "response proto=%u call=%u result=0x%08x", protocol, dm_nex_u32(p + at + 5), dm_nex_u32(p + at + 1));
    }
}

static inline bool dm_nex_append(uint8_t **buffer, size_t *length, const uint8_t *data, size_t n) {
    if (*length + n > DM_NEX_LIMIT) return false;
    uint8_t *grown = realloc(*buffer, *length + n ? *length + n : 1); if (!grown) return false;
    memcpy(grown + *length, data, n); *buffer = grown; *length += n; return true;
}

// Splits whole PRUDP-Lite packets off the front of the WebSocket payload.
static inline bool dm_nex_packets(dm_nex_stream *s, uint64_t session, bool out) {
    size_t at = 0;
    while (s->packets_len - at >= 12) {
        const uint8_t *p = s->packets + at;
        if (p[0] != 0x80) return false;
        size_t options = p[1], payload = dm_nex_u16(p + 2), total = 12 + options + payload;
        if (s->packets_len - at < total) break;
        unsigned type = dm_nex_u16(p + 8) & 0xf, flags = dm_nex_u16(p + 8) >> 4, fragment = p[7];
        if (type == 2 && !(flags & 0x001) && payload) {
            if (!dm_nex_append(&s->message, &s->message_len, p + 12 + options, payload)) return false;
            if (!fragment) { dm_nex_rmc(session, out, s->message, s->message_len); s->message_len = 0; }
        } else if (type == 3) dm_nex_line(session, out, "disconnect");
        at += total;
    }
    memmove(s->packets, s->packets + at, s->packets_len - at); s->packets_len -= at; return true;
}

static inline void dm_nex_feed(dm_nex_stream *s, uint64_t session, bool out, const void *data, size_t n) {
    const uint8_t *p = data;
    for (size_t i = 0; i < n && s->phase != DM_NEX_OFF;) {
        if (s->phase == DM_NEX_START) {
            // A NEX stream opens with the WebSocket upgrade: "GET " from the client, "HTTP" back.
            static const char request[] = "GET ", reply[] = "HTTP"; const char *want = out ? request : reply;
            if (p[i] != (uint8_t)want[s->head_len]) { dm_nex_free(s); return; }
            if (++s->head_len == 4) { s->head_len = 0; s->phase = DM_NEX_HEADER; }
            i++; continue;
        }
        if (s->phase == DM_NEX_HEADER) {
            s->window = s->window << 8 | p[i++];
            if (s->window == 0x0d0a0d0a) s->phase = DM_NEX_FRAMES;
            continue;
        }
        if (s->frame_left == 0) {
            s->head[s->head_len++] = p[i++];
            if (s->head_len < 2) continue;
            unsigned size = s->head[1] & 0x7f, need = 2 + (size == 126 ? 2 : size == 127 ? 8 : 0) + (s->head[1] & 0x80 ? 4 : 0);
            if (s->head_len < need) continue;
            uint64_t length = size;
            if (size == 126) length = (uint64_t)s->head[2] << 8 | s->head[3];
            if (size == 127) { length = 0; for (unsigned k = 0; k < 8; k++) length = length << 8 | s->head[2 + k]; }
            unsigned opcode = s->head[0] & 0xf;
            s->masked = s->head[1] & 0x80; if (s->masked) memcpy(s->mask, s->head + need - 4, 4);
            if (opcode == 2) s->binary = true; else if (opcode != 0) s->binary = false;
            s->frame_left = length; s->mask_at = 0; s->head_len = 0;
            if (opcode == 8) dm_nex_line(session, out, "websocket close");
            continue;
        }
        size_t take = n - i < s->frame_left ? n - i : (size_t)s->frame_left;
        if (s->binary) {
            uint8_t chunk[512];
            for (size_t done = 0; done < take;) {
                size_t part = take - done < sizeof chunk ? take - done : sizeof chunk;
                for (size_t k = 0; k < part; k++) chunk[k] = p[i + done + k] ^ (s->masked ? s->mask[s->mask_at++ & 3] : 0);
                if (!dm_nex_append(&s->packets, &s->packets_len, chunk, part) || !dm_nex_packets(s, session, out)) {
                    dm_nex_line(session, out, "unparsed stream, trace stopped"); dm_nex_free(s); return;
                }
                done += part;
            }
        } else if (s->masked) s->mask_at += (unsigned)take;
        s->frame_left -= take; i += take;
    }
}
