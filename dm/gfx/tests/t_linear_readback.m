// NVN linear image storage: GPU image writes must be visible through the memory-pool CPU mapping.
// Synthetic 160x90 RGBA8_SRGB IMAGE|LINEAR textures use a valid 640-byte row pitch.
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
static int cases, failed;
#define EXPECT(n,w,v) do { int a=(w), b=(v); cases++; printf("%s expected %d -> got %d %s\n",n,a,b,a==b?"PASS":"FAIL"); failed+=a!=b; } while (0)
// CPU writes use the texture's row pitch, not Tegra block-linear addressing.
// Compare the entire pool, including a nonzero offset, untouched texels and padding.
static void write_case(int format, int flags, int width, int height, int stride, int gpu) {
    enum { POOL_SIZE = 65536, OFFSET = 16384 };
    uint8_t *mem = NULL; if (posix_memalign((void **)&mem, getpagesize(), POOL_SIZE)) abort();
    uint8_t *want = malloc(POOL_SIZE); if (!want) abort();
    memset(mem, 0xa7, POOL_SIZE); memset(want, 0xa7, POOL_SIZE);
    pool_t pool = {.magic=MAGIC('P','O','O','L'), .mem=mem, .size=POOL_SIZE, .flags=0x24}; mtl_pool_add(mem, POOL_SIZE);
    NVNtextureBuilder tb; NVNtexture tex; h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetSize2D(&tb, width, height); h_nvnTextureBuilderSetFormat(&tb, format);
    h_nvnTextureBuilderSetFlags(&tb, flags); h_nvnTextureBuilderSetStride(&tb, stride);
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&pool, OFFSET);
    EXPECT("CPU linear texture init", 1, h_nvnTextureInitialize(&tex, &tb));
    int bpp = format == NVN_FORMAT_R32F ? 4 : 1, row = width * bpp;
    uint8_t *source = malloc((size_t)row * height); if (!source) abort();
    for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
        if (bpp == 4) { float value = (float)(y * width + x) / 16.f; memcpy(source + y * row + x * bpp, &value, 4); }
        else source[y * row + x] = (uint8_t)(x + y * 17);
    }
    unsigned before = mtl_cpu_tex_count(); NVNcopyRegion region = {0, 0, 0, width, height, 1};
    h_nvnTextureWriteTexels(&tex, NULL, &region, source);
    for (int y = 0; y < height; y++) memcpy(want + OFFSET + y * stride, source + y * row, (size_t)row);
    EXPECT("whole linear write preserves pool and padding", 0, memcmp(mem, want, POOL_SIZE));
    EXPECT("linear write does not select block-linear upload", before, mtl_cpu_tex_count());

    id<MTLTexture> texture = gpu ? tex_mtl((const tex_t *)&tex) : nil;
    if (gpu) EXPECT("CPU-written linear texture keeps pool backing", 1, texture.buffer != nil);
    uint8_t patch[128]; memset(patch, 0xe3, sizeof patch);
    region = (NVNcopyRegion){3, 1, 0, 7, 2, 1};
    for (int y = 0; y < 2; y++) for (int x = 0; x < 7; x++) {
        if (bpp == 4) { float value = (float)(100 + y * 7 + x); memcpy(patch + y * 64 + x * bpp, &value, 4); }
        else patch[y * 64 + x] = (uint8_t)(100 + y * 7 + x);
    }
    h_nvnTextureWriteTexelsStrided(&tex, NULL, &region, patch, 64, 128);
    for (int y = 0; y < 2; y++) memcpy(want + OFFSET + (y + 1) * stride + 3 * bpp, patch + y * 64, (size_t)7 * bpp);
    EXPECT("strided subregion preserves surrounding storage", 0, memcmp(mem, want, POOL_SIZE));
    EXPECT("subregion does not select block-linear upload", before, mtl_cpu_tex_count());
    NVNcopyRegion invalid = {width - 1, height - 1, 0, 2, 2, 1};
    h_nvnTextureWriteTexels(&tex, NULL, &invalid, patch);
    EXPECT("out-of-bounds linear write preserves storage", 0, memcmp(mem, want, POOL_SIZE));
    h_nvnTextureWriteTexelsStrided(&tex, NULL, &region, patch, 1, 128);
    EXPECT("short source stride preserves storage", 0, memcmp(mem, want, POOL_SIZE));
    if (gpu) {
        EXPECT("subregion keeps the already resolved texture", 1, tex_mtl((const tex_t *)&tex) == texture);
        id<MTLBuffer> result = [g_dev newBufferWithLength:(NSUInteger)stride * height options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
            sourceSize:MTLSizeMake(width, height, 1) toBuffer:result destinationOffset:0 destinationBytesPerRow:stride destinationBytesPerImage:stride * height];
        [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
        EXPECT("CPU linear writes GPU readback completed", MTLCommandBufferStatusCompleted, cb.status);
        int bad = 0;
        for (int y = 0; y < height; y++) bad += memcmp((uint8_t *)result.contents + y * stride, want + OFFSET + y * stride, (size_t)row) != 0;
        EXPECT("GPU sees whole write and later strided patch", 0, bad);
    }
    h_nvnTextureFinalize(&tex); mtl_pool_del(mem); free(source); free(want); free(mem);
}
static void run_case(int format) {
    void *mem = NULL; if (posix_memalign(&mem, getpagesize(), 262144)) abort(); memset(mem, 0, 262144);
    pool_t pool = {.magic=MAGIC('P','O','O','L'), .mem=mem, .size=262144, .flags=0x24}; mtl_pool_add(mem, 262144);
    NVNtextureBuilder tb; NVNtexture tex; h_nvnTextureBuilderSetDefaults(&tb); h_nvnTextureBuilderSetWidth(&tb, 160);
    h_nvnTextureBuilderSetHeight(&tb, 90); h_nvnTextureBuilderSetFormat(&tb, format);
    h_nvnTextureBuilderSetFlags(&tb, NVN_TEXTURE_FLAGS_IMAGE | NVN_TEXTURE_FLAGS_LINEAR); h_nvnTextureBuilderSetStride(&tb, 640);
    h_nvnTextureBuilderSetStorage(&tb, (const NVNmemoryPool *)&pool, 65536); EXPECT("linear texture init", 1, h_nvnTextureInitialize(&tex, &tb));
    id<MTLTexture> t = tex_mtl((const tex_t *)&tex);
    printf("LINEAR format=%#x Metal=%lu minimumAlignment=%lu bufferBacked=%d row=640\n", format, (unsigned long)t.pixelFormat,
        (unsigned long)[g_dev minimumLinearTextureAlignmentForPixelFormat:t.pixelFormat], t.buffer != nil);
    EXPECT("host texture resolved", 1, t != nil); if (!t) return;
    // NVN image stores use the shader image format, without sRGB conversion. A uint image view writes literal packed bytes.
    mtl_reg_tex(1, (const tex_t *)&tex, NULL); uint64_t rid;
    mtl_sub_begin(); id<MTLTexture> image = img_fit(1, t, NVN_DPF_UINT, &rid);
    if (!image) { img_fit_upgrade(); t = tex_mtl((const tex_t *)&tex); image = img_fit(1, t, NVN_DPF_UINT, &rid); }
    mtl_wait(mtl_sub_commit(), 5000000000ull); EXPECT("production uint image view", 1, image != nil);
    NSError *err = nil; const char *src = "#include <metal_stdlib>\nusing namespace metal;\nkernel void fill(texture2d<uint,access::write> out [[texture(0)]], uint2 p [[thread_position_in_grid]]) { if(p.x<160&&p.y<90) out.write(uint4(0xff996633u,0,0,0),p); }\n";
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(src) options:nil error:&err]; if (!lib) { fprintf(stderr,"%s\n",err.description.UTF8String); abort(); }
    id<MTLComputePipelineState> ps = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fill"] error:&err]; if (!ps) abort();
    id<MTLCommandBuffer> cb = q_cb(); id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder]; [en setComputePipelineState:ps]; [en setTexture:image atIndex:0];
    [en dispatchThreads:MTLSizeMake(160,90,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
    EXPECT("image compute complete", MTLCommandBufferStatusCompleted, cb.status);
    h_nvnMemoryPoolInvalidateMappedRange((const NVNmemoryPool *)&pool, 65536, 640*90);
    uint8_t *map = (uint8_t *)h_nvnMemoryPoolMap((const NVNmemoryPool *)&pool) + 65536; int bad = 0;
    static const uint8_t want[] = {51,102,153,255}; for(int i=0;i<160*90;i++) bad += memcmp(map+i*4,want,4) != 0;
    EXPECT("GPU image writes -> CPU pool map, 14400 literal pixels", 0, bad);
    h_nvnTextureFinalize(&tex); mtl_pool_del(mem); mtl_alias_drop_pool(&pool); free(mem);   // as nvnMemoryPoolFinalize: the next case's pool object has the same address
}
static void compressed_write_case(void) {
    uint8_t *mem = NULL; if (posix_memalign((void **)&mem, getpagesize(), 65536)) abort(); memset(mem, 0xa7, 65536);
    pool_t pool = {.magic=MAGIC('P','O','O','L'), .mem=mem, .size=65536, .flags=0x24}; mtl_pool_add(mem, 65536);
    NVNtextureBuilder tb; NVNtexture tex; h_nvnTextureBuilderSetDefaults(&tb); h_nvnTextureBuilderSetSize2D(&tb, 64, 64);
    h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA_DXT1); h_nvnTextureBuilderSetFlags(&tb, NVN_TEXTURE_FLAGS_LINEAR);
    h_nvnTextureBuilderSetStride(&tb, 128); h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&pool, 16384);
    EXPECT("linear compressed storage init", 1, h_nvnTextureInitialize(&tex, &tb));
    unsigned before = mtl_cpu_tex_count(); uint8_t block[8] = {0}; NVNcopyRegion region = {0, 0, 0, 4, 4, 1};
    h_nvnTextureWriteTexels(&tex, NULL, &region, block);
    int changed = 0; for (int i = 0; i < 65536; i++) changed += mem[i] != 0xa7;
    EXPECT("unsupported compressed linear write keeps all canaries", 0, changed);
    EXPECT("unsupported compressed write does not select upload", before, mtl_cpu_tex_count());
    h_nvnTextureFinalize(&tex); mtl_pool_del(mem); free(mem);
}
static void render_target_stride_case(void) {
    void *mem = NULL; if (posix_memalign(&mem, getpagesize(), 65536)) abort(); memset(mem, 0, 65536);
    pool_t pool = {.magic=MAGIC('P','O','O','L'), .mem=mem, .size=65536, .flags=0x24}; mtl_pool_add(mem, 65536);
    NVNtextureBuilder tb; NVNtexture tex; h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetWidth(&tb, 16); h_nvnTextureBuilderSetHeight(&tb, 16);
    h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8);
    h_nvnTextureBuilderSetFlags(&tb, NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET);
    h_nvnTextureBuilderSetStorage(&tb, (const NVNmemoryPool *)&pool, 0);
    EXPECT("linear target inferred stride storage", 2048, h_nvnTextureBuilderGetStorageSize(&tb));
    EXPECT("linear target init", 1, h_nvnTextureInitialize(&tex, &tb));
    id<MTLTexture> t = tex_mtl((const tex_t *)&tex);
    EXPECT("linear target has buffer backing", 1, t.buffer != nil);
    EXPECT("linear target inferred row pitch", 128, t.bufferBytesPerRow);
    id<MTLCommandBuffer> cb = q_cb(); MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.colorAttachments[0].texture=t; pd.colorAttachments[0].loadAction=MTLLoadActionClear;
    pd.colorAttachments[0].storeAction=MTLStoreActionStore; pd.colorAttachments[0].clearColor=MTLClearColorMake(1,0,0,1);
    [[cb renderCommandEncoderWithDescriptor:pd] endEncoding]; [cb commit]; [cb waitUntilCompleted];
    EXPECT("linear target clear completed", MTLCommandBufferStatusCompleted, cb.status);
    static const uint8_t red[]={255,0,0,255}; int bad=0, padding=0;
    for (int y=0;y<16;y++) {
        for (int x=0;x<16;x++) bad += memcmp((uint8_t *)mem+y*128+x*4,red,4)!=0;
        for (int x=64;x<128;x++) padding += ((uint8_t *)mem)[y*128+x]!=0;
    }
    EXPECT("linear target clear uses padded rows", 0, bad); EXPECT("linear target leaves row padding alone", 0, padding);
    h_nvnTextureFinalize(&tex); mtl_pool_del(mem); free(mem);
}
static void scaled_copy_case(void) {
    void *mem = NULL; if (posix_memalign(&mem, getpagesize(), 262144)) abort(); memset(mem, 0, 262144);
    pool_t pool = {.magic=MAGIC('P','O','O','L'), .mem=mem, .size=262144, .flags=0x24}; mtl_pool_add(mem, 262144);
    NVNtextureBuilder tb; NVNtexture dst; h_nvnTextureBuilderSetDefaults(&tb); h_nvnTextureBuilderSetWidth(&tb, 160);
    h_nvnTextureBuilderSetHeight(&tb, 90); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8_SRGB);
    h_nvnTextureBuilderSetFlags(&tb, NVN_TEXTURE_FLAGS_IMAGE | NVN_TEXTURE_FLAGS_LINEAR); h_nvnTextureBuilderSetStride(&tb, 640);
    h_nvnTextureBuilderSetStorage(&tb, (const NVNmemoryPool *)&pool, 65536); EXPECT("scaled copy destination init", 1, h_nvnTextureInitialize(&dst, &tb));
    tex_t src = {.magic=MAGIC('T','E','X',0), .serial=900001}; src.d.width=320; src.d.height=180; src.d.depth=src.d.levels=src.d.samples=1;
    src.d.target=NVN_TEXTURE_TARGET_2D; src.d.format=NVN_FORMAT_RGBA8_SRGB;
    id<MTLTexture> source = tex_mtl(&src); id<MTLCommandBuffer> seed = q_cb();
    MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor]; pd.colorAttachments[0].texture=source;
    pd.colorAttachments[0].loadAction=MTLLoadActionClear; pd.colorAttachments[0].storeAction=MTLStoreActionStore; pd.colorAttachments[0].clearColor=MTLClearColorMake(1,0,0,1);
    [[seed renderCommandEncoderWithDescriptor:pd] endEncoding]; [seed commit]; [seed waitUntilCompleted];
    EXPECT("scaled copy source seeded", MTLCommandBufferStatusCompleted, seed.status);
    NVNcommandBuffer cmd; EXPECT("scaled copy command init", 1, h_nvnCommandBufferInitialize(&cmd, NULL));
    h_nvnCommandBufferAddCommandMemory(&cmd, (const NVNmemoryPool *)&pool, 0, 65536); h_nvnCommandBufferBeginRecording(&cmd);
    NVNcopyRegion sr={0,0,0,320,180,1}, dr={0,0,0,160,90,1};
    h_nvnCommandBufferCopyTextureToTexture(&cmd, (const NVNtexture *)&src, NULL, &sr, &dst, NULL, &dr, NVN_COPY_FLAGS_LINEAR_FILTER_BIT);
    NVNcommandHandle h=h_nvnCommandBufferEndRecording(&cmd); state_reset(); memset(&R,0,sizeof R); mtl_sub_begin(); mtl_exec((const uint8_t *)h);
    EXPECT("scaled copy committed", 1, mtl_wait(mtl_sub_commit(),5000000000ull)); EXPECT("scaled copy GPU error",0,mtl_last_commit_error());
    h_nvnMemoryPoolInvalidateMappedRange((const NVNmemoryPool *)&pool,65536,640*90); uint8_t *map=(uint8_t *)h_nvnMemoryPoolMap((const NVNmemoryPool *)&pool)+65536;
    static const uint8_t want[]={255,0,0,255}; int bad=0; for(int i=0;i<160*90;i++)bad+=memcmp(map+i*4,want,4)!=0;
    EXPECT("scaled render copy -> CPU pool map, 14400 literal red pixels",0,bad);
    EXPECT("scaled destination keeps pool backing",1,tex_mtl((const tex_t *)&dst).buffer!=nil);
    h_nvnTextureFinalize(&dst); mtl_tex_release(&src); mtl_pool_del(mem); free(mem);
}
int main(void) { @autoreleasepool { mtl_init(); run_case(NVN_FORMAT_RGBA8); run_case(NVN_FORMAT_RGBA8_SRGB);
    write_case(NVN_FORMAT_R8, NVN_TEXTURE_FLAGS_LINEAR, 13, 5, 32, 0);
    write_case(NVN_FORMAT_R32F, NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET, 256, 4, 1024, 1);
    compressed_write_case();
    render_target_stride_case();
    scaled_copy_case();
    printf("LINEAR_READBACK cases=%d failed=%d\n",cases,failed); return failed != 0;
} }
