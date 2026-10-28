// NVN accepts repeated 1x1 tail levels; Metal accepts only the dimensioned chain.
// Exercise the production descriptor, view and both upload paths without changing guest storage/layer strides.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static void shapes(void) {
    const struct { int target; uint32_t w,h,z,levels,want,layers; } cases[] = {
        {1,128,256,1,15,9,1}, {1,1,1,1,15,1,1}, {1,128,256,1,3,3,1}, {1,8,4,1,0,1,1},
        {0,8,1,1,15,4,1}, {3,8,1024,1,15,4,1024}, {4,8,4,1024,15,4,1024},
        {2,8,4,32,15,6,1}, {8,8,8,1,15,4,6}, {9,8,8,12,15,4,12},
        {5,8,4,1,15,1,1}, {6,8,4,3,15,1,3}
    };
    for (unsigned i=0;i<sizeof cases/sizeof *cases;i++) {
        tex_t t={0}; t.d=(nvn_texdesc){.target=cases[i].target,.format=NVN_FORMAT_RGBA8,.samples=cases[i].target==5||cases[i].target==6?4:1,
            .width=cases[i].w,.height=cases[i].h,.depth=cases[i].z,.levels=cases[i].levels};
        nvn_tex_layout(&t.d,&t.L); nvn_texdesc before=t.d; nvn_texlayout layout=t.L;
        MTLTextureDescriptor *d=tex_desc(&t,0); id<MTLTexture> mt=[g_dev newTextureWithDescriptor:d];
        CHECK(mt!=nil,"Metal accepts the production texture descriptor");
        CHECK(mt.mipmapLevelCount==cases[i].want,"mip count uses spatial dimensions, excludes array layers and preserves smaller requests");
        CHECK(mt.arrayLength==cases[i].layers,"target layer count is preserved");
        CHECK(!memcmp(&t.d,&before,sizeof before)&&!memcmp(&t.L,&layout,sizeof layout),"guest count and storage are unchanged");
    }
}
static void upload(int gpu) {
    tex_t t={.magic=MAGIC('T','E','X',0),.serial=91000+(unsigned)gpu,.has_layout=1};
    t.d=(nvn_texdesc){.target=4,.format=NVN_FORMAT_RGBA8,.width=8,.height=4,.depth=2,.levels=15,.samples=1};
    nvn_tex_layout(&t.d,&t.L); nvn_texdesc short_d=t.d; short_d.levels=4; nvn_texlayout short_l; nvn_tex_layout(&short_d,&short_l);
    CHECK(t.L.layer_size>short_l.layer_size,"redundant guest tail contributes to array layer stride");
    size_t bytes=(t.L.size+getpagesize()-1)&~(size_t)(getpagesize()-1); void *mem=NULL;
    if(posix_memalign(&mem,getpagesize(),bytes))abort(); memset(mem,0,bytes); t.mem=mem;
    pool_t pool={.mem=mem,.size=bytes}; t.pool=&pool; mtl_pool_add(mem,bytes);
    for(unsigned layer=0;layer<2;layer++)for(unsigned level=0;level<15;level++) {
        unsigned w=MAX(8u>>level,1u),h=MAX(4u>>level,1u); uint8_t pixels[8*4*4];
        for(unsigned i=0;i<w*h;i++){pixels[4*i]=20+layer*100+level;pixels[4*i+1]=80+level;pixels[4*i+2]=7;pixels[4*i+3]=255;}
        CHECK(!nvn_swizzle(&t.d,level,layer,pixels,w*4,mem),"seed each guest level independently");
    }
    g_nvn_deswz_gpu=gpu;
    id<MTLTexture> mt=pkg_upload(&t,NULL,nil); CHECK(mt.mipmapLevelCount==4,"upload materializes four physical levels");
    id<MTLBuffer> out=[g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=q_cb(); id<MTLBlitCommandEncoder> enc=[cb blitCommandEncoder];
    for(unsigned layer=0;layer<2;layer++)for(unsigned level=0;level<4;level++) {
        unsigned w=MAX(8u>>level,1u),h=MAX(4u>>level,1u); NSUInteger off=(layer*4+level)*512;
        [enc copyFromTexture:mt sourceSlice:layer sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1)
            toBuffer:out destinationOffset:off destinationBytesPerRow:32 destinationBytesPerImage:32*h];
    }
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted]; CHECK(cb.status==MTLCommandBufferStatusCompleted&&!cb.error,"GPU readback succeeds");
    for(unsigned layer=0;layer<2;layer++)for(unsigned level=0;level<4;level++) {
        unsigned w=MAX(8u>>level,1u),h=MAX(4u>>level,1u); const uint8_t *p=(uint8_t *)out.contents+(layer*4+level)*512; int bad=0;
        for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++){const uint8_t *q=p+y*32+x*4;bad|=q[0]!=20+layer*100+level||q[1]!=80+level||q[2]!=7||q[3]!=255;}
        CHECK(!bad,"physical mip texels use the original 15-level guest layer stride");
    }
    // Production sampled views use the physical base's count, including requests that span the extra guest tails.
    serial_put(t.serial,mt); view_t v={.set_levels=1,.base_level=2,.nlevels=13}; mtl_reg_tex(311,&t,&v);
    id<MTLTexture> view=tex_by_id(311); CHECK(view&&view.parentRelativeLevel==2&&view.mipmapLevelCount==2,"sampled view clips to represented levels");
    CHECK(t.d.levels==15,"upload and view leave the guest level count intact");
    mtl_pool_del(mem); free(mem);
}
int main(void) { @autoreleasepool {
    mtl_init(); g_sub_thread=pthread_self(); atomic_store(&g_sub_thread_set,1); shapes(); int gpu=g_nvn_deswz_gpu; upload(0); if(gpu)upload(1); else CHECK(0,"GPU upload path is available");
    printf("mip tails: %d checks, %d failed\n",checks,failed); return failed!=0;
} }
