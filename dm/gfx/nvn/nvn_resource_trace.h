// Passive resource metadata only: no object pointers, addresses or payloads.
// The replay owns this fixed state; frame/pass provide context, not identity.
#ifndef NVN_RESOURCE_TRACE_H
#define NVN_RESOURCE_TRACE_H
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum { NVN_RESOURCE_TRACE_KEYS = 16, NVN_RESOURCE_TRACE_LIMIT = 32, NVN_RESOURCE_TRACE_ALL_TYPES = 0x3ff };
enum { NVN_TRACE_COLOR, NVN_TRACE_DEPTH, NVN_TRACE_STENCIL, NVN_TRACE_TEXTURE };
typedef struct {
    uint64_t key, serial;
    int32_t stage, role, slot, descriptor; // descriptor -1: none (render attachment)
    uint32_t type, format, width, height, depth, levels, layers, samples;
    uint32_t level, slice, plane, render_layers, dummy;
} nvn_resource_fact;
typedef struct {
    uint64_t keys[NVN_RESOURCE_TRACE_KEYS];
    nvn_resource_fact last[NVN_RESOURCE_TRACE_LIMIT];
    unsigned nkeys, nlast, emitted;
} nvn_resource_trace;

static int nvn_resource_key(const char *s, size_t n, uint64_t *key) {
    if (n != 16) return 0;
    uint64_t k = 0;
    for (unsigned i = 0; i < 16; i++) {
        unsigned c = (unsigned char)s[i], d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else return 0;
        k = (k << 4) | d;
    }
    *key = k; return 1;
}
// The environment accepts only comma-separated 16-hex keys. A malformed or
// oversized list fails closed as a whole. Runtime shader names may end in _b.
static int nvn_resource_trace_config(nvn_resource_trace *t, const char *s) {
    memset(t, 0, sizeof *t);
    if (!s || !*s) return 1;
    const char *p = s; unsigned tokens = 0;
    for (;;) {
        const char *end = strchr(p, ','); size_t n = end ? (size_t)(end - p) : strlen(p);
        uint64_t key;
        if (++tokens > NVN_RESOURCE_TRACE_KEYS || !nvn_resource_key(p, n, &key)) { memset(t, 0, sizeof *t); return 0; }
        unsigned i = 0; for (; i < t->nkeys && t->keys[i] != key; i++) {}
        if (i == t->nkeys) t->keys[t->nkeys++] = key;
        if (!end) return 1;
        p = end + 1;
    }
}
// Optional Metal texture type codes 0..9. Filter before change detection so
// unrelated resource shapes do not spend the same process-wide 32-change cap.
// No setting keeps all types; a malformed or overlong list fails closed.
static int nvn_resource_trace_types(const char *s, unsigned *mask) {
    *mask = NVN_RESOURCE_TRACE_ALL_TYPES;
    if (!s || !*s) return 1;
    unsigned types = 0, tokens = 0;
    const char *p = s;
    for (;;) {
        if (*p < '0' || *p > '9' || ++tokens > 10 || (p[1] && p[1] != ',')) { *mask = 0; return 0; }
        types |= 1u << (*p - '0');
        if (!p[1]) { *mask = types; return 1; }
        p += 2;
    }
}
static int nvn_resource_trace_type_watches(unsigned mask, uint32_t type) {
    return type < 10 && ((mask >> type) & 1u);
}
static int nvn_resource_trace_live(const nvn_resource_trace *t) { return t->nkeys && t->emitted < NVN_RESOURCE_TRACE_LIMIT; }
static int nvn_resource_trace_watches(const nvn_resource_trace *t, const char *s, uint64_t *key) {
    if (!nvn_resource_trace_live(t) || !s) return 0;
    size_t n = strlen(s); uint64_t k;
    if (n == 18 && s[16] == '_' && s[17] == 'b') n = 16;
    if (!nvn_resource_key(s, n, &k)) return 0;
    for (unsigned i = 0; i < t->nkeys; i++) if (t->keys[i] == k) { *key = k; return 1; }
    return 0;
}
static int nvn_resource_fact_same(const nvn_resource_fact *a, const nvn_resource_fact *b) {
    // Field comparison, rather than padding bytes or content-derived hashes.
    return a->key == b->key && a->serial == b->serial && a->stage == b->stage && a->role == b->role && a->slot == b->slot && a->descriptor == b->descriptor &&
        a->type == b->type && a->format == b->format && a->width == b->width && a->height == b->height && a->depth == b->depth && a->levels == b->levels &&
        a->layers == b->layers && a->samples == b->samples && a->level == b->level && a->slice == b->slice && a->plane == b->plane && a->render_layers == b->render_layers && a->dummy == b->dummy;
}
static int nvn_resource_trace_note(nvn_resource_trace *t, const nvn_resource_fact *f) {
    if (!nvn_resource_trace_live(t)) return 0;
    unsigned k = 0; for (; k < t->nkeys && t->keys[k] != f->key; k++) {}
    if (k == t->nkeys || f->role < NVN_TRACE_COLOR || f->role > NVN_TRACE_TEXTURE) return 0;
    unsigned i = 0;
    for (; i < t->nlast; i++) {
        const nvn_resource_fact *p = &t->last[i];
        if (p->key == f->key && p->stage == f->stage && p->role == f->role && p->slot == f->slot) break;
    }
    if (i < t->nlast && nvn_resource_fact_same(&t->last[i], f)) return 0;
    if (i == t->nlast) t->nlast++;
    t->last[i] = *f; t->emitted++; return 1;
}
static void nvn_resource_trace_print(FILE *out, const nvn_resource_fact *f, uint64_t frame, uint64_t pass) {
    static const char *const roles[] = {"color", "depth", "stencil", "texture"};
    if (f->role < NVN_TRACE_COLOR || f->role > NVN_TRACE_TEXTURE) return;
    fprintf(out, "[dm] [nvn-resource] key=%016llx frame=%llu pass=%llu stage=%d role=%s slot=%d serial=%llu descriptor=%d type=%u format=%u width=%u height=%u depth=%u levels=%u layers=%u samples=%u level=%u slice=%u plane=%u render_layers=%u dummy=%u\n",
        (unsigned long long)f->key, (unsigned long long)frame, (unsigned long long)pass, f->stage, roles[f->role], f->slot, (unsigned long long)f->serial, f->descriptor,
        f->type, f->format, f->width, f->height, f->depth, f->levels, f->layers, f->samples, f->level, f->slice, f->plane, f->render_layers, f->dummy);
}
#endif
