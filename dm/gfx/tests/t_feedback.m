// Feedback snapshots and their per-draw argument substitution include separate texture slots; a snapshot is reused until the game's next barrier,
// and a draw that only samples an attachment nothing in its pass has written reads it directly.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

static id<MTLTexture> target(tex_t *t, uint64_t serial) {
    *t = (tex_t){.magic=MAGIC('T','E','X',0), .serial=serial};
    t->d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8,
        .width=4, .height=4, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [g_dev newTextureWithDescriptor:d];
    CHECK(texture != nil, "render target created");
    res_add(texture); mtl_tex_init(t); serial_put(serial, texture);
    return texture;
}
static void clear(MTLClearColor color) {
    R.clear_c[0] = 1; R.cc[0] = color;
    CHECK(rp_begin() != nil, "production render pass opens");
}
static void sample(NvShader *fs, id<MTLRenderPipelineState> pipeline) {
    clear(MTLClearColorMake(0, 0, 0, 1));
    enc_r_pso(g_enc, pipeline);
    enc_r_viewport(g_enc, (MTLViewport){0, 0, 4, 4, 0, 1});
    CHECK(encode_args((id<MTLCommandEncoder>)g_enc, fs, 1, 0), "production fragment arguments encoded");
    enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3);
    rp_end();
}
static void readback(id<MTLTexture> t, id<MTLBuffer> b, unsigned offset) {
    enc_b_copy_texture_buffer(blit(), t, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(4, 4, 1), b, offset, 256, 1024);
}
static void pixels(id<MTLBuffer> b, unsigned offset, const uint8_t want[4], const char *label) {
    int valid = 1;
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++)
        valid &= !memcmp((const uint8_t *)b.contents + offset + y * 256 + x * 4, want, 4);
    CHECK(valid, label);
}
static void slot_case(NvProg *pr, id<MTLRenderPipelineState> pipeline, int slot, int index) {
    int before = failed, tid = 600 + index;
    NvShader *fs = pr->sh[1]; fs->rf.b[0].reg = slot;
    int array = fs->rf.b[0].dtt == MTLTextureType2DArray;
    tex_t source, output;
    id<MTLTexture> original = target(&source, 99700 + index * 2);
    id<MTLTexture> destination = target(&output, 99701 + index * 2);
    mtl_reg_tex(tid, &source, NULL);
    id<MTLBuffer> result = [g_dev newBufferWithLength:2048 options:MTLResourceStorageModeShared]; res_add(result);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &source; S.tex[1][slot] = tid;
    clear(MTLClearColorMake(1, 0, 0, 1));
    fb_prepare(pr);
    CHECK(!g_enc, "snapshot closes the preceding render pass");
    CHECK(g_fb_n == 1, "feedback attachment receives a snapshot");
    CHECK(g_fb_n == 1 && g_fb_src[0] == original && g_fb_use[0] != original,
          "snapshot substitutes a distinct texture for the registered source");
    rp_end();
    // Overwrite the attachment after the snapshot, then render the sampled value
    // into a distinct target. This makes a missing snapshot fail deterministically
    // even on GPUs that happen to tolerate sampling an attached render target.
    clear(MTLClearColorMake(0, 1, 0, 1)); rp_end();
    R.rt.color[0] = &output;
    sample(fs, pipeline);
    uint64_t bound = *(uint64_t *)((uint8_t *)fs->ab_buf.contents + fs->ab_off);
    id<MTLTexture> adapted = array ? (__bridge id<MTLTexture>)g_treg[tid].alt : nil;
    if (array) CHECK(adapted.textureType == MTLTextureType2DArray && adapted.arrayLength == 1 &&
                     g_treg[tid].alt_of == (__bridge void *)g_fb_use[0], "snapshot is adapted to one array slice");
    CHECK(g_fb_n == 1 && bound == (array ? adapted.gpuResourceID._impl : g_fb_rid[0]) && bound != original.gpuResourceID._impl,
          "production argument buffer contains the snapshot resource ID");
    readback(destination, result, 0);
    // With a different attachment the following draw restores the original binding.
    fb_prepare(pr);
    CHECK(g_fb_n == 0, "following draw needs no snapshot");
    sample(fs, pipeline);
    bound = *(uint64_t *)((uint8_t *)fs->ab_buf.contents + fs->ab_off);
    adapted = array ? (__bridge id<MTLTexture>)g_treg[tid].alt : nil;
    CHECK(bound == (array ? adapted.gpuResourceID._impl : original.gpuResourceID._impl) &&
          (!array || g_treg[tid].alt_of == (__bridge void *)original), "following draw restores the original resource ID");
    readback(destination, result, 1024);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "GPU submission completed");
    CHECK(!mtl_last_commit_error(), "GPU submission has no error");
    pixels(result, 0, (const uint8_t[]){255, 0, 0, 255}, "first draw reads the red pre-overwrite snapshot");
    pixels(result, 1024, (const uint8_t[]){0, 255, 0, 255}, "following draw reads the green original attachment");
    printf("feedback %s slot %d: %s\n", array ? "2D-to-array" : "2D", slot, before == failed ? "PASS" : "FAIL");
    mtl_tex_release(&source); mtl_tex_release(&output);
}
// The rule without a listed shader: copy once, reuse until a barrier, end the pass when an earlier draw of it read the attachment directly.
static void reuse_case(NvProg *pr) {
    int before = failed, tid = 650; NvShader *fs = pr->sh[1]; fs->rf.b[0].reg = 0;
    tex_t source; target(&source, 99790);
    mtl_reg_tex(tid, &source, NULL); // NOLINT(clang-analyzer-osx.cocoa.RetainCount) - target's CF retain is owned by the serial hash table until mtl_tex_release below.
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &source; S.tex[1][0] = tid;
    S.chmask.mask = 0; clear(MTLClearColorMake(1, 0, 0, 1));
    uint64_t copies = g_fb_count;
    fb_prepare(pr);
    CHECK(g_fb_n == 0 && g_enc, "a draw that writes nothing reads an unwritten attachment directly");
    S.chmask.mask = 0xffffffffu;
    fb_prepare(pr);
    CHECK(g_fb_n == 1 && !g_enc && g_fb_count == copies + 1, "a writing draw takes a snapshot");
    id<MTLTexture> first = g_fb_use[0];
    clear(MTLClearColorMake(0, 1, 0, 1));
    fb_prepare(pr);
    CHECK(g_fb_n == 1 && g_enc && g_fb_count == copies + 1 && g_fb_use[0] == first, "the next writing draw reuses the snapshot without ending the pass");
    S.chmask.mask = 0; rp_end(); clear(MTLClearColorMake(0, 1, 0, 1));
    fb_prepare(pr);
    CHECK(g_fb_n == 0 && g_enc, "a reading draw first in a pass reads directly");
    S.chmask.mask = 0xffffffffu;
    fb_prepare(pr);
    CHECK(g_fb_n == 1 && !g_enc && g_fb_count == copies + 1, "a writing draw after a direct read ends the pass and reuses the snapshot");
    g_fb_bar++;
    clear(MTLClearColorMake(0, 0, 1, 1));
    fb_prepare(pr);
    CHECK(g_fb_n == 1 && !g_enc && g_fb_count == copies + 2, "a game barrier makes the next writing draw take a fresh snapshot");
    rp_end();
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "GPU submission completed");
    CHECK(!mtl_last_commit_error(), "GPU submission has no error");
    printf("feedback reuse: %s\n", before == failed ? "PASS" : "FAIL");
    mtl_tex_release(&source);
}
// Array-declared shaders may adapt one 2D snapshot, but the existing restrictions
// on sampled subresources and unsupported backing remain in force.
static void guard_cases(NvProg *pr) {
    NvShader *fs = pr->sh[1]; fs->rf.b[0].reg = 2;
    const char *labels[] = {"mip-chain view is not snapshotted", "multiple array layers are not snapshotted",
                            "multisample texture is not snapshotted", "nested parent view is not snapshotted"};
    for (int i = 0; i < 4; i++) {
        tex_t source = {.magic=MAGIC('T','E','X',0), .serial=99800 + i};
        source.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8,
            .width=4, .height=4, .depth=1, .levels=1, .samples=1};
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:i == 0];
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
        if (i == 0) source.d.levels = 3;
        if (i == 1) { d.textureType = MTLTextureType2DArray; d.arrayLength = 2; source.d.target = NVN_TEXTURE_TARGET_2D_ARRAY; source.d.depth = 2; }
        if (i == 2) { d.textureType = MTLTextureType2DMultisample; d.sampleCount = 4; source.d.target = NVN_TEXTURE_TARGET_2D_MULTISAMPLE; source.d.samples = 4; }
        id<MTLTexture> base = [g_dev newTextureWithDescriptor:d];
        CHECK(base != nil, "guard texture created"); res_add(base);
        id<MTLTexture> sampled = base;
        if (i == 3) {
            id<MTLTexture> parent = [base newTextureViewWithPixelFormat:base.pixelFormat];
            sampled = [parent newTextureViewWithPixelFormat:base.pixelFormat];
            CHECK(sampled.parentTexture.parentTexture != nil, "guard case has a real nested Metal parent");
        }
        mtl_tex_init(&source); serial_put(source.serial, sampled);
        mtl_reg_tex(680 + i, &source, NULL); // NOLINT(clang-analyzer-osx.cocoa.RetainCount) - serial_put's CF retain is owned by the serial hash table until mtl_tex_release below.
        state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
        R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &source; S.tex[1][2] = 680 + i; S.chmask.mask = 0xffffffffu;
        uint64_t before = g_fb_count; fb_prepare(pr);
        CHECK(g_fb_n == 0 && g_fb_count == before, labels[i]);
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "guard submission completed");
        mtl_tex_release(&source);
    }
}
int main(void) { @autoreleasepool {
    setenv("DM_NVN_TBDR", "0", 1);
    mtl_init(); NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); }\n"
        "struct A {texture2d<float, access::read> source[[id(0)]];};\n"
        "fragment float4 f(float4 p[[position]], constant A&a[[buffer(0)]]) {return a.source.read(uint2(p.xy));}\n"
        "struct AA {texture2d_array<float, access::read> source[[id(0)]];};\n"
        "fragment float4 fa(float4 p[[position]], constant AA&a[[buffer(0)]]) {return a.source.read(uint2(p.xy),0);}\n"
        options:nil error:&error];
    CHECK(lib != nil, "synthetic shader compiles");
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    NvProg *pr = [NvProg new]; NvShader *fs = [NvShader new]; pr->sh[1] = fs;
    fs->stage = 1; strcpy(fs->key, "0123456789abcdef"); fs->fn = [lib newFunctionWithName:@"f"];
    fs->ae = [fs->fn newArgumentEncoderWithBufferIndex:0]; fs->arg_len = fs->ae.encodedLength;
    fs->rf.nb = 1; fs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEX, .aid=0, .dtt=MTLTextureType2D};
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"v"]; d.fragmentFunction = fs->fn;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pipeline = [g_dev newRenderPipelineStateWithDescriptor:d error:&error];
    CHECK(pipeline != nil, "synthetic render pipeline compiles");
    if (!pipeline) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    const int slots[] = {0, 128, 255};
    for (int i = 0; i < 3; i++) slot_case(pr, pipeline, slots[i], i);
    reuse_case(pr);
    NvProg *array_pr = [NvProg new]; NvShader *array_fs = [NvShader new]; array_pr->sh[1] = array_fs;
    array_fs->stage = 1; strcpy(array_fs->key, "fedcba9876543210"); array_fs->fn = [lib newFunctionWithName:@"fa"];
    array_fs->ae = [array_fs->fn newArgumentEncoderWithBufferIndex:0]; array_fs->arg_len = array_fs->ae.encodedLength;
    array_fs->rf.nb = 1; array_fs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEX, .aid=0, .dtt=MTLTextureType2DArray};
    d.fragmentFunction = array_fs->fn;
    id<MTLRenderPipelineState> array_pipeline = [g_dev newRenderPipelineStateWithDescriptor:d error:&error];
    CHECK(array_pipeline != nil, "synthetic array pipeline compiles");
    if (!array_pipeline) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    for (int i = 0; i < 3; i++) slot_case(array_pr, array_pipeline, slots[i], i + 10);
    guard_cases(array_pr);
    printf("feedback snapshot: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
