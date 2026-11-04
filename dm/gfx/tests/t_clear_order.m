// Original synthetic command streams: attachment clears and explicit texture
// clears must reach the GPU in recorded order, including before the first draw.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL: %s\n",label); } } while (0)
typedef struct { uint8_t bytes[4096]; size_t used; } commands;
static void emit(commands *c, unsigned op, const void *p, size_t n) {
    size_t size=(8+n+7)&~7ull; assert(c->used+size<=sizeof c->bytes);
    op_hdr h={op,(uint32_t)size}; memcpy(c->bytes+c->used,&h,8);
    if(n)memcpy(c->bytes+c->used+8,p,n);c->used+=size;
}
static void seed(id<MTLCommandQueue> queue,id<MTLTexture> texture) {
    id<MTLCommandBuffer> cb=[queue commandBuffer];
    for(int level=0;level<2;level++) {
        MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor renderPassDescriptor];
        p.colorAttachments[0].texture=texture;p.colorAttachments[0].level=level;
        p.colorAttachments[0].loadAction=MTLLoadActionClear;p.colorAttachments[0].storeAction=MTLStoreActionStore;
        p.colorAttachments[0].clearColor=MTLClearColorMake(0,0,1,1);
        [[cb renderCommandEncoderWithDescriptor:p] endEncoding];
    }
    [cb commit];[cb waitUntilCompleted];CHECK(cb.status==MTLCommandBufferStatusCompleted,"literal blue seed reaches both mips");
}
static int read_pixels(id<MTLCommandQueue> queue,id<MTLTexture> texture,int level,uint8_t *out) {
    unsigned size=8>>level;
    id<MTLBuffer> b=[g_dev newBufferWithLength:256*size options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    [e copyFromTexture:texture sourceSlice:0 sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(size,size,1)
              toBuffer:b destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256*size];
    [e endEncoding];[cb commit];[cb waitUntilCompleted];
    if(cb.status!=MTLCommandBufferStatusCompleted)return 0;
    for(unsigned y=0;y<size;y++)memcpy(out+y*size*4,(uint8_t *)b.contents+y*256,size*4);
    return 1;
}
int main(void) { @autoreleasepool {
    mtl_init();NSError *error=nil;
    id<MTLLibrary> library=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[i],.5,1); }\n"
        "fragment float4 f() { return float4(1); }\n" options:nil error:&error];
    CHECK(library!=nil,"authored draw shaders compile");if(!library)return 1;
    static prog_t pg={.serial=99801};NvProg *program=[NvProg new];
    program->sh[0]=[NvShader new];program->sh[0]->fn=[library newFunctionWithName:@"v"];
    program->sh[1]=[NvShader new];program->sh[1]->fn=[library newFunctionWithName:@"f"];
    program->sh[1]->stage=1;program->sh[1]->rf.color_mask=1;serial_put(pg.serial,program);
    tex_t t[2]={0};id<MTLTexture> texture[2];id<MTLCommandQueue> queue=[g_dev newCommandQueue];
    for(int k=0;k<2;k++) {
        t[k].magic=MAGIC('T','E','X',0);t[k].serial=99802+k;
        t[k].d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=8,.depth=1,.levels=2,.samples=1};
        texture[k]=[g_dev newTextureWithDescriptor:tex_desc(&t[k],0)];
        CHECK(texture[k]!=nil,"resident fixture texture allocates");if(!texture[k])return 1;
        res_add(texture[k]);mtl_tex_init(&t[k]);serial_put(t[k].serial,texture[k]);
    }
    struct { int reverse,partial,other,level,no_draw;const char *label; } cases[]={
        {0,0,0,0,0,"attachment clear then whole texture clear before draw"},
        {1,0,0,0,0,"reverse order preserves the newer attachment clear"},
        {0,1,0,0,0,"partial texture clear preserves preceding RGB and outside pixels"},
        {0,0,1,0,0,"clearing another texture preserves both results"},
        {0,0,0,1,0,"another mip keeps its independent clear"},
        {0,0,0,0,1,"clear-only submission preserves recorded order"},
    };
    for(unsigned k=0;k<sizeof cases/sizeof *cases;k++) {
        seed(queue,texture[0]);seed(queue,texture[1]);state_reset();memset(&R,0,sizeof R);
        commands c={0};p_set_rt rt={.n=1};rt.color[0]=&t[0];emit(&c,OP_SET_RT,&rt,sizeof rt);
        p_clear_color a={.index=0,.mask=15,.rgba={1,0,0,1}};
        int size=8>>cases[k].level;
        p_clear_tex b={.tex=&t[cases[k].other],.mask=cases[k].partial?8:15,.has_view=cases[k].level!=0,
            .view={.set_levels=1,.base_level=cases[k].level},.r={0,0,0,size,size,1}};
        b.c.f[1]=1;b.c.f[3]=cases[k].partial?0:1;
        if(cases[k].partial)b.r=(NVNcopyRegion){2,1,0,3,2,1};
        if(cases[k].reverse)emit(&c,OP_CLEAR_TEX,&b,sizeof b);
        emit(&c,OP_CLEAR_COLOR,&a,sizeof a);
        if(!cases[k].reverse)emit(&c,OP_CLEAR_TEX,&b,sizeof b);
        // A real draw opens the attachment load action while a zero channel
        // write mask leaves the ordered clears visible for literal readback.
        if(!cases[k].no_draw) {
            p_bind_program bind={.prog=&pg,.stages=3};emit(&c,OP_BIND_PROGRAM,&bind,sizeof bind);
            p_bind_state state={.kind=2};chmask_st mask={.mask=0};memcpy(state.bytes,&mask,sizeof mask);emit(&c,OP_BIND_STATE,&state,sizeof state);
            p_draw draw={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1};emit(&c,OP_DRAW,&draw,sizeof draw);
        }
        emit(&c,OP_END,NULL,0);uint64_t draws=g_stat_draw;mtl_sub_begin();mtl_exec(c.bytes);mtl_sub_commit();mtl_drain();
        CHECK(!mtl_last_commit_error(),"ordered production command stream completes without GPU error");
        CHECK(g_stat_draw-draws==(cases[k].no_draw?0:1),"the requested draw really replays");
        int good=1;
        for(int tex=0;tex<2;tex++)for(int level=0;level<2;level++) {
            uint8_t pixels[8*8*4];CHECK(read_pixels(queue,texture[tex],level,pixels),"GPU readback completes");
            unsigned size=8>>level;
            for(unsigned y=0;y<size;y++)for(unsigned x=0;x<size;x++) {
                uint8_t want[4]={0,0,255,255};
                if(tex==0&&level==0){want[0]=255;want[2]=0;}
                if(tex==cases[k].other&&level==cases[k].level&&(!cases[k].reverse||tex!=0||level!=0)) {
                    if(!cases[k].partial){want[0]=0;want[1]=255;want[2]=0;}
                    else if(x>=2&&x<5&&y>=1&&y<3)want[3]=0;
                }
                good&=!memcmp(pixels+4*(y*size+x),want,4);
            }
        }
        CHECK(good,cases[k].label);printf("%s: %s\n",cases[k].label,good?"PASS":"FAIL");
    }
    for(int k=0;k<2;k++)mtl_tex_release(&t[k]);serial_del(pg.serial);
    printf("texture clear ordering: %d checks, %d failed\n",checks,failed);return failed!=0;
} }
