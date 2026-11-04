// Two NVN textures over the same storage that differ only by the formats of an sRGB / linear pair share their bytes: what is written through one reads back through the other
// (Mario Kart World's Grand Prix movie: an RGBA8 render target sampled through an RGBA8_SRGB texture).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
// Exercise both creation orders, every layer/mip, and storage identity. The
// descriptors deliberately have no CPU storage: all content is written by GPU
// copies, so this checks shared GPU bytes rather than two independent uploads.
static void coherence(int reverse, int array) {
    pool_t pool = {.magic=MAGIC('P','O','O','L')}, separate = {.magic=MAGIC('P','O','O','L')};
    tex_t a = {.magic=MAGIC('T','E','X',0), .serial=nvn_new_serial(), .pool=&pool};
    a.d = (nvn_texdesc){.target=array ? NVN_TEXTURE_TARGET_2D_ARRAY : NVN_TEXTURE_TARGET_2D,
        .format=reverse ? NVN_FORMAT_RGBA8_SRGB : NVN_FORMAT_RGBA8,
        .width=4, .height=4, .depth=array ? 2 : 1, .levels=3, .samples=1};
    nvn_tex_layout(&a.d,&a.L);
    tex_t b=a; b.serial=nvn_new_serial(); b.d.format=reverse ? NVN_FORMAT_RGBA8 : NVN_FORMAT_RGBA8_SRGB;
    tex_t offset=b; offset.serial=nvn_new_serial(); offset.off=65536;
    tex_t other_pool=b; other_pool.serial=nvn_new_serial(); other_pool.pool=&separate;
    mtl_tex_init(&a); mtl_tex_init(&b); mtl_tex_init(&offset); mtl_tex_init(&other_pool);
    mtl_sub_begin();
    id<MTLTexture> source=tex_mtl(&a), twin=tex_mtl(&b);
    id<MTLTexture> away=tex_mtl(&offset), elsewhere=tex_mtl(&other_pool);
    CHECK(source && twin && twin.parentTexture==source, "both format creation orders share the first texture");
    CHECK(twin.pixelFormat!=(source.pixelFormat) && twin.mipmapLevelCount==3 && twin.arrayLength==(array ? 2 : 1), "view preserves its format, mip levels and layers");
    CHECK(away && away.parentTexture!=source && elsewhere && elsewhere.parentTexture!=source, "another offset or pool retains independent storage");
    mtl_sub_commit(); mtl_drain();
    for (NSUInteger layer=0; layer<(array ? 2u : 1u); layer++) for (NSUInteger level=0; level<3; level++) {
        NSUInteger w=4u>>level, bytes=w*w*4;
        uint32_t pixels[16]; for (int i=0;i<16;i++) pixels[i]=0x40808080u+(uint32_t)(i+layer*16+level*32);
        id<MTLBuffer> src=[g_dev newBufferWithBytes:pixels length:bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> dst=[g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        res_add(src); res_add(dst); mtl_sub_begin();
        enc_b_copy_buffer_texture(blit(),src,0,w*4,bytes,MTLSizeMake(w,w,1),source,layer,level,MTLOriginMake(0,0,0));
        enc_b_copy_texture_buffer(blit(),twin,layer,level,MTLOriginMake(0,0,0),MTLSizeMake(w,w,1),dst,0,w*4,bytes);
        mtl_sub_commit(); mtl_drain();
        CHECK(!mtl_last_commit_error() && !memcmp(dst.contents,pixels,bytes), "all mip/layer bytes written through one format are visible through its twin");
        res_remove(src); res_remove(dst);
    }
    // Do not mistake "same pool object address" for the same pool lifetime.
    mtl_tex_release(&a); mtl_tex_release(&b); mtl_tex_release(&offset); mtl_tex_release(&other_pool);
    mtl_alias_drop_pool(&pool); mtl_alias_drop_pool(&separate); mtl_drain();
    a.serial=nvn_new_serial(); b.serial=nvn_new_serial(); mtl_tex_init(&a); mtl_tex_init(&b);
    mtl_sub_begin(); id<MTLTexture> fresh=tex_mtl(&a), fresh_view=tex_mtl(&b);
    CHECK(fresh!=source && fresh_view.parentTexture==fresh, "a reused pool descriptor gets fresh shared storage");
    mtl_sub_commit(); mtl_drain();
    mtl_tex_release(&a); mtl_tex_release(&b); mtl_alias_drop_pool(&pool); mtl_drain();
}

int main(void) { @autoreleasepool {
    mtl_init(); mtl_sub_begin();
    tex_t lin = {.magic=MAGIC('T','E','X',0), .serial=99501};
    lin.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8, .width=4, .height=4, .depth=1, .levels=1, .samples=1};
    nvn_tex_layout(&lin.d, &lin.L);
    tex_t srgb = lin; srgb.serial++; srgb.d.format = NVN_FORMAT_RGBA8_SRGB;
    tex_t other = lin; other.serial += 2; other.d.format = NVN_FORMAT_R32F;   // not an sRGB / linear pair: storage of its own
    mtl_tex_init(&lin); mtl_tex_init(&srgb); mtl_tex_init(&other);
    id<MTLTexture> base = tex_mtl(&lin), view = tex_mtl(&srgb);
    CHECK(base && view && view.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB, "the sRGB texture has its own format");
    CHECK(view.parentTexture == base, "the sRGB texture is a view of the linear texture's storage");
    CHECK(tex_mtl(&other) != base && tex_mtl(&other).parentTexture == nil, "another format family keeps its own texture");
    uint32_t pixels[16]; for (int i = 0; i < 16; i++) pixels[i] = 0x44332211u + (uint32_t)i;
    id<MTLBuffer> src = [g_dev newBufferWithBytes:pixels length:sizeof pixels options:MTLResourceStorageModeShared]; res_add(src);
    id<MTLBuffer> dst = [g_dev newBufferWithLength:sizeof pixels options:MTLResourceStorageModeShared]; res_add(dst);
    id<MTL4ComputeCommandEncoder> encoder = blit();
    enc_b_copy_buffer_texture(encoder, src, 0, 16, sizeof pixels, MTLSizeMake(4,4,1), base, 0, 0, MTLOriginMake(0,0,0));
    encoder = blit(); enc_b_copy_texture_buffer(encoder, view, 0, 0, MTLOriginMake(0,0,0), MTLSizeMake(4,4,1), dst, 0, 16, sizeof pixels);
    mtl_sub_commit(); mtl_drain();
    CHECK(!memcmp(dst.contents, pixels, sizeof pixels), "pixels written through the linear texture read back through the sRGB one");
    // The linear texture upgraded after the view was made (image writes): the view follows the upgraded storage
    id<MTLTexture> up = tex_upgrade(&lin, base, MTLTextureUsageShaderWrite, base.pixelFormat), view2 = tex_mtl(&srgb);
    CHECK(up != base && tex_mtl(&lin) == up, "the linear texture is upgraded");
    CHECK(view2.parentTexture == up && view2.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB, "the sRGB texture is a view of the upgraded storage");
    for (int i = 0; i < 16; i++) ((uint32_t *)src.contents)[i] = 0x88776655u + (uint32_t)i;
    mtl_sub_begin(); encoder = blit();
    enc_b_copy_buffer_texture(encoder, src, 0, 16, sizeof pixels, MTLSizeMake(4,4,1), up, 0, 0, MTLOriginMake(0,0,0));
    encoder = blit(); enc_b_copy_texture_buffer(encoder, view2, 0, 0, MTLOriginMake(0,0,0), MTLSizeMake(4,4,1), dst, 0, 16, sizeof pixels);
    mtl_sub_commit(); mtl_drain();
    CHECK(!memcmp(dst.contents, src.contents, sizeof pixels), "pixels written through the upgraded linear texture read back through the sRGB view");
    // An upgrade asked through the view upgrades the parent; the view is made again on it
    id<MTLTexture> up2 = tex_upgrade(&srgb, view2, MTLTextureUsageRenderTarget, view2.pixelFormat);
    CHECK(up2.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB && up2.parentTexture == tex_mtl(&lin) && tex_mtl(&lin) != up && tex_mtl(&srgb) == up2, "an upgrade through the view upgrades the parent and keeps the pair sharing");
    mtl_drain();
    for (int reverse=0;reverse<2;reverse++) for (int array=0;array<2;array++) coherence(reverse,array);
    printf("sRGB / linear aliases: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
