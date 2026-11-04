// COMPRESSIBLE is a storage hint, not an encoding of CPU-published texels.
// Literal RGBA8 and FP32 texels must survive first use and a later flushed write.
#include "game_profile.h"
// Exercise both publication policies with the same synthetic data, without
// changing a game's profile or relying on its choice of optional tracking.
#ifdef DM_TEST_TEX_FLUSH_UPLOAD
#undef DM_GAME_TEX_FLUSH_UPLOAD
#define DM_GAME_TEX_FLUSH_UPLOAD DM_TEST_TEX_FLUSH_UPLOAD
#undef DM_GAME_TEX_DIRTY_UPLOAD
#define DM_GAME_TEX_DIRTY_UPLOAD 0
#endif
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static void finish(void) {
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "GPU submission completed");
    CHECK(!mtl_last_commit_error(), "GPU submission has no error");
}
static void fill(tex_t *t, uint8_t *linear, unsigned variant) {
    for (unsigned y = 0; y < t->d.height; y++) for (unsigned x = 0; x < t->d.width; x++) {
        unsigned pixel = y * t->d.width + x;
        if (t->d.format == NVN_FORMAT_RGBA32F) {
            // Preserve finite HDR values, negative values and NaN payload bits;
            // a general upload must not sanitize or clamp the caller's bytes.
            uint32_t words[] = {0x40000000u + variant, 0xbf800000u + x, 0x7fc00005u + y, 0x3f800000u};
            memcpy(linear + pixel * 16, words, sizeof words);
        } else {
            uint8_t bytes[] = {(uint8_t)(x + 1 + variant), (uint8_t)(y * 7 + variant), (uint8_t)(pixel + 3), 255};
            memcpy(linear + pixel * 4, bytes, sizeof bytes);
        }
    }
    CHECK(!nvn_swizzle(&t->d, 0, 0, linear, t->d.width * t->L.bpb, (void *)t->mem), "literal input swizzled");
}
static void expect_bytes(id<MTLTexture> image, tex_t *t, const uint8_t *want, const char *label) {
    size_t row = (size_t)t->d.width * t->L.bpb;
    id<MTLBuffer> out = [g_dev newBufferWithLength:row * t->d.height options:MTLResourceStorageModeShared];
    if (!out) abort();
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> en = [cb blitCommandEncoder];
    [en copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
        sourceSize:MTLSizeMake(t->d.width, t->d.height, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * t->d.height];
    [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK(cb.status == MTLCommandBufferStatusCompleted, "literal GPU readback completed");
    CHECK(!memcmp(out.contents, want, row * t->d.height), label);
}
static void run(int format, uint32_t pool_flags, uint32_t texture_flags) {
    enum { POOL_SIZE = 65536, OFFSET = 16384 };
    void *mem = NULL; if (posix_memalign(&mem, getpagesize(), POOL_SIZE)) abort(); memset(mem, 0, POOL_SIZE);
    pool_t pool; pool_builder_t pb = {.mem = mem, .size = POOL_SIZE, .flags = pool_flags};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&pool, (NVNmemoryPoolBuilder *)&pb), "pool initialized");
    NVNtextureBuilder builder; NVNtexture object;
    h_nvnTextureBuilderSetDefaults(&builder); h_nvnTextureBuilderSetSize2D(&builder, 16, 8);
    h_nvnTextureBuilderSetFormat(&builder, format); h_nvnTextureBuilderSetFlags(&builder, texture_flags);
    h_nvnTextureBuilderSetStorage(&builder, (NVNmemoryPool *)&pool, OFFSET);
    tex_t layout = {.mem = (uint8_t *)mem + OFFSET}; layout.d = ((tex_builder_t *)&builder)->d; nvn_tex_layout(&layout.d, &layout.L);
    uint8_t linear[16 * 8 * 16]; memset(linear, 0, sizeof linear); fill(&layout, linear, 0);
    h_nvnMemoryPoolFlushMappedRange((NVNmemoryPool *)&pool, OFFSET, layout.L.size);
    CHECK(h_nvnTextureInitialize(&object, &builder), "texture initialized");
    tex_t *t = (tex_t *)&object;
    int excluded = (pool_flags & NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS) && (texture_flags & NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    CHECK(nvn_ft_tracked(t->serial) == (!excluded && DM_GAME_TEX_FLUSH_UPLOAD), "CPU-visible compressible texture follows flush tracking");
    mtl_sub_begin(); id<MTLTexture> image = tex_mtl(t); CHECK(image != nil, "texture resolves"); finish();
    uint8_t zero[sizeof linear] = {0};
    if (image) expect_bytes(image, t, excluded ? zero : linear, "first-use texels match CPU publication or excluded GPU storage");
    if (!excluded && DM_GAME_TEX_FLUSH_UPLOAD) {
        dm_guest_write_prepare(layout.mem, layout.L.size); fill(&layout, linear, 11);
        h_nvnMemoryPoolFlushMappedRange((NVNmemoryPool *)&pool, OFFSET, layout.L.size);
        mtl_sub_begin(); image = tex_mtl(t); CHECK(image != nil, "updated texture resolves"); finish();
        if (image) expect_bytes(image, t, linear, "later flushed CPU write reaches the existing texture");
    }
    h_nvnTextureFinalize(&object); h_nvnMemoryPoolFinalize((NVNmemoryPool *)&pool); mtl_drain(); free(mem);
}
int main(void) { @autoreleasepool {
    mtl_init();
    const uint32_t cached = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED;
    const uint32_t uncached = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED;
    run(NVN_FORMAT_RGBA8, cached, 0);
    run(NVN_FORMAT_RGBA8, cached, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    run(NVN_FORMAT_RGBA8, uncached, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    run(NVN_FORMAT_RGBA32F, cached, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    run(NVN_FORMAT_RGBA8, NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    printf("t_compressible_content (flush=%d): %d checks, %d failed\n", DM_GAME_TEX_FLUSH_UPLOAD, checks, failed); return failed != 0;
} }
