// Shared-font ownership and LoadFont forwarding through the real forced registration; no game module or font file is needed.
#include "../hle_sdk16.c"
#include <mach-o/getsect.h>
#include <sys/wait.h>
#include <sys/resource.h>

static int checks, fails, calls, lookups, missing;
static void *seen_self;
static char *seen_name;
static const void *seen_data;
static unsigned seen_index, seen_capacity;
static uint32_t status;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s\n", msg); } } while (0)
static uint32_t original(void *self, char *name, const void *data, unsigned index, unsigned capacity) {
    calls++; seen_self = self; seen_name = name; seen_data = data;
    seen_index = index; seen_capacity = capacity;
    return status;
}
void *guest_sym(const char *name) {
    lookups++;
    CHECK(!strcmp(name, "_ZN2nn6fontll18ScalableFontEngine8LoadFontEPcPKvjj"), "original symbol lookup");
    return missing ? NULL : original;
}
module_t g_mod[MAX_MOD];
int g_nmod;
uint64_t g_t0_ns;
uint64_t now_ns(void) { return 0; }
int dm_sdk_major(void) { return 20; }
int dm_main_imports(const char *prefix) { (void)prefix; return 1; }
module_t *module_of(const void *p) { (void)p; return NULL; }
void dm_backtrace(uint64_t fp) { (void)fp; }
void hle_bind_system_event(void *ev, int autoclear) { (void)ev; (void)autoclear; }
void hle_signal_system_event(void *ev) { (void)ev; }
uint64_t hle_system_event_binding(void *ev) { (void)ev; return 1; }
int hle_signal_system_event_binding(uint64_t binding) { (void)binding; return 1; }
uint32_t hle_hid_connected_npad(void) { return 0; }
void dm_host_helper_qos(qos_class_t q) { (void)q; }
extern const struct mach_header_64 _mh_execute_header;
int main(void) {
    unsigned long bytes = 0;
    const hle_force_ent *e = (const hle_force_ent *)getsectiondata(&_mh_execute_header, "__DATA", "swforce", &bytes);
    uint32_t (*load)(void *, char *, const void *, unsigned, unsigned) = NULL;
    unsigned count = 0;
    for (size_t i = 0; e && i < bytes / sizeof *e; i++) {
        if (strcmp(e[i].name, "_ZN2nn6fontll18ScalableFontEngine8LoadFontEPcPKvjj")) continue;
        load = e[i].fn; count++;
        CHECK(e[i].why && e[i].why[0], "takeover has a reason");
    }
    CHECK(count == 1 && load, "exact LoadFont forced registration exists once");
    if (!load) return 1;
    // A missing SDK implementation must fail loudly rather than fabricate a successful font load.
    pid_t child = fork();
    CHECK(child >= 0, "missing-original child starts");
    if (!child) { struct rlimit r = {0, 0}; setrlimit(RLIMIT_CORE, &r); missing = 1; load(NULL, NULL, NULL, 0, 0); _exit(1); }
    if (child > 0) { int s; waitpid(child, &s, 0); CHECK(WIFSIGNALED(s) && WTERMSIG(s) == SIGABRT, "missing original aborts"); }
    uint8_t standard[64] = {0}, extension[64] = {0}, unrelated[64] = {0};
    uint32_t marker = 0x18029a7fu;
    memcpy(standard, &marker, 4); memcpy(extension, &marker, 4); memcpy(unrelated, &marker, 4);
    char name[50] = {0}; int self;
    const void *before[] = {NULL, unrelated, standard, extension};
    for (unsigned i = 0; i < sizeof before / sizeof *before; i++) {
        status = 403; int n = calls;
        CHECK(load(&self, name, before[i], 17, sizeof name) == status, "uninitialized fonts preserve result");
        CHECK(calls == n + 1 && seen_data == before[i], "uninitialized fonts leave all data unchanged");
    }
    std_f = (font_t){standard, sizeof standard}; ext_f = (font_t){extension, sizeof extension};
    const void *input[] = {standard, extension, standard + 8, extension + 8, standard + 1, extension + 9, unrelated, NULL};
    const void *expect[] = {standard + 8, extension + 8, standard + 8, extension + 8, standard + 1, extension + 9, unrelated, NULL};
    const uint32_t results[] = {0, 403, 301, 0x80000001u, ~0u};
    for (unsigned r = 0; r < sizeof results / sizeof *results; r++) for (unsigned i = 0; i < sizeof input / sizeof *input; i++) {
        int n = calls; status = results[r];
        CHECK(load(&self, name, input[i], ~0u, sizeof name) == status, "SDK status preserved");
        CHECK(calls == n + 1 && seen_data == expect[i], "only exact host bases skip the header, once");
        CHECK(seen_self == &self && seen_name == name && seen_index == ~0u && seen_capacity == sizeof name, "all other arguments preserved");
    }
    ext_f = std_f;
    CHECK(load(&self, name, standard, 0, 0) == status && seen_data == standard + 8, "extension fallback to standard");
    CHECK(seen_index == 0 && seen_capacity == 0, "zero unsigned arguments preserved");
    CHECK(lookups == 1, "original resolved once");
    CHECK(!memcmp(standard, unrelated, sizeof standard) && !memcmp(extension, unrelated, sizeof extension), "input bytes unchanged");
    // Hand-encoded BFTTF data verifies the decoder independently of any user's
    // firmware. Length, marker and payload corruption must be rejected.
    char fixture[] = "/private/tmp/dm-font-XXXXXX"; int fd = mkstemp(fixture);
    uint32_t encoded[4] = {0x18029a7fu ^ 0x06186249u, __builtin_bswap32(8u) ^ 0x06186249u,
                           0x00000100u ^ 0x06186249u, 0x12345678u ^ 0x06186249u};
    CHECK(fd >= 0 && write(fd, encoded, sizeof encoded) == sizeof encoded, "write hand-encoded BFTTF fixture");
    close(fd); font_t decoded = font_bfttf_map(fixture);
    CHECK(decoded.p && decoded.n == sizeof encoded, "BFTTF decodes into a private allocation");
    if (decoded.p) {
        uint32_t word; memcpy(&word, decoded.p + 12, 4);
        CHECK(!memcmp(decoded.p + 8, "\0\1\0\0", 4) && word == 0x12345678u, "payload XOR and byte order are correct");
        system_f[3] = decoded;
        CHECK(font_payload(decoded.p) == decoded.p + 8 && font_payload(decoded.p + 8) == decoded.p + 8, "firmware allocation skips the SDK header exactly once");
        system_f[3] = (font_t){0}; munmap(decoded.p, decoded.n);
    }
    uint32_t original_bytes[4] = {0}; fd = open(fixture, O_RDONLY); read(fd, original_bytes, sizeof original_bytes); close(fd);
    CHECK(!memcmp(encoded, original_bytes, sizeof encoded), "BFTTF source bytes remain unchanged");
    encoded[1] ^= 1; fd = open(fixture, O_WRONLY | O_TRUNC); write(fd, encoded, sizeof encoded); close(fd);
    CHECK(!font_bfttf_map(fixture).p, "incorrect declared font length is rejected");
    encoded[1] ^= 1; encoded[2] ^= 1; fd = open(fixture, O_WRONLY | O_TRUNC); write(fd, encoded, sizeof encoded); close(fd);
    CHECK(!font_bfttf_map(fixture).p, "non-SFNT payload is rejected");
    unlink(fixture);
    const char *real = getenv("DM_TEST_REAL_SYSTEM_DATA");
    if (real && *real) {
        setenv("DM_SYSTEM_DATA_DIR", real, 1);
        for (int type = 0; type < 6; type++) {
            font_t f = font_archive(type);
            CHECK(f.p && f.n > 1000, "real imported firmware shared font decodes");
            if (f.p) munmap(f.p, f.n);
        }
    }
    printf("shared font: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
