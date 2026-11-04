// Own 8x8x8 R11G11B10F data with the passive metadata trace off/on:
// eight simultaneous MRT slice views and a consumer using ordinary TEX binding.
// Uniform updates are recorded before the indexed draws; every texel is sampled
// on the GPU. This checks the contract, without any original shader or payload.
#define NVN_RESOURCE_TRACE_TEST 1
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
static int checks,failed;
#define CHECK(c,s) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL: %s\n",s); } } while (0)
static prog_t programs[2];
static int own_texu;
static id<MTLLibrary> shaders;

static void programs_init(void) {
    NSError *error=nil;
    shaders=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Args{constant float4 *value [[id(0)]];};\n"
        "float4 pos(uint n){return float4(n==1?3.0:-1.0,n==2?3.0:-1.0,0,1);}\n"
        "vertex float4 v(uint n [[vertex_id]]){return pos(n);}\n"
        "struct O{float4 c0 [[color(0)]];float4 c1 [[color(1)]];float4 c2 [[color(2)]];float4 c3 [[color(3)]];float4 c4 [[color(4)]];float4 c5 [[color(5)]];float4 c6 [[color(6)]];float4 c7 [[color(7)]];};\n"
        "fragment O fm(constant Args&a [[buffer(0)]]){float4 c=*a.value;return {c,c+float4(.125,0,0,0),c+float4(.25,0,0,0),c+float4(.375,0,0,0),c+float4(.5,0,0,0),c+float4(.625,0,0,0),c+float4(.75,0,0,0),c+float4(.875,0,0,0)};}\n"
        "struct TArgs{texture3d<float,access::read> lut [[id(0)]];};\n"
        "fragment float4 ft(float4 p [[position]],constant TArgs&a [[buffer(0)]]){uint2 xy=uint2(p.xy);return a.lut.read(uint3(xy.x,xy.y%8,xy.y/8));}\n"
        "kernel void read_output(texture2d<float,access::read> t [[texture(0)]],device float4 *out [[buffer(0)]],uint2 p [[thread_position_in_grid]]){out[p.y*8+p.x]=t.read(p); }\n"
        "kernel void read_lut(texture3d<float,access::read> t [[texture(0)]],device float4 *out [[buffer(0)]],uint3 p [[thread_position_in_grid]]){out[(p.z*8+p.y)*8+p.x]=t.read(p);}\n"
        options:nil error:&error];
    CHECK(shaders!=nil,"own LUT shaders compile");
    if (!shaders) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return; }
    for (int mode=0;mode<2;mode++) { // NOLINT(clang-analyzer-osx.cocoa.RetainCount): serial_put retains each fixture program in g_by_serial through GPU replay.
        NvProg *p=[NvProg new]; p->sh[0]=[NvShader new];
        p->sh[0]->fn=[shaders newFunctionWithName:@"v"];
        p->sh[0]->rf.pos_attr=-1;
        NvShader *f=[NvShader new]; p->sh[1]=f; f->stage=1;
        f->fn=[shaders newFunctionWithName:mode?@"ft":@"fm"];
        f->rf.color_known=1; f->rf.color_mask=mode?1:255; f->rf.nb=1;
        f->rf.b[0]=(nvn_rbind){.kind=NVN_RB_CBUF,.aid=0,.reg=0}; f->cb_ext[0]=16;
        if (!mode) snprintf(f->key,sizeof f->key,"0123456789abcdef_b");
        if (mode) { snprintf(f->key,sizeof f->key,"fedcba9876543210_b"); f->rf.b[0]=(nvn_rbind){.kind=own_texu?NVN_RB_TEXU:NVN_RB_TEX,.aid=0,.reg=0,.dtt=MTLTextureType3D,.dpf=NVN_DPF_FLOAT}; }
        f->ae=[f->fn newArgumentEncoderWithBufferIndex:0]; f->arg_len=f->ae.encodedLength;
        programs[mode].serial=nvn_new_serial(); serial_put(programs[mode].serial,p);
    }
}
static void check_volume(const tex_t *texture,int phase,int output) {
    NSError *error=nil;
    id<MTLComputePipelineState> ps=[g_dev newComputePipelineStateWithFunction:[shaders newFunctionWithName:output?@"read_output":@"read_lut"] error:&error];
    id<MTLBuffer> result=[g_dev newBufferWithLength:8*8*8*16 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue=[g_dev newCommandQueue];
    CHECK(ps && result && queue,"own volume read resources initialize"); if (!ps || !result || !queue) return;
    id<MTLCommandBuffer> cb=[queue commandBuffer]; id<MTLComputeCommandEncoder> ce=[cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setTexture:tex_mtl(texture) atIndex:0]; [ce setBuffer:result offset:0 atIndex:0];
    [ce dispatchThreadgroups:(output?MTLSizeMake(8,64,1):MTLSizeMake(8,8,8)) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK(cb.status==MTLCommandBufferStatusCompleted,"own volume read completes");
    const float *p=result.contents;
    for (int z=0;z<8;z++) {
        int good=1; float expected[3]={.125f*(z+1),phase?.5f:.25f,phase?.25f:.5f};
        for (int i=0;i<64;i++) for (int c=0;c<3;c++) good &= fabsf(p[(z*64+i)*4+c]-expected[c])<.0001f;
        char label[100]; snprintf(label,sizeof label,"depth plane %d: all 64 texels retain that draw's literal uniform value",z); CHECK(good,label);
    }
}
static void run(void) {
    enum { SIZE=262144, TEX=65536, UBO=131072, INDEX=147456, OUTPUT=196608, HANDLE=163840 };
    uint8_t *mem=mmap(NULL,SIZE,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0); if (mem==MAP_FAILED) abort();
    pool_t pool={0}; pool_builder_t pb={.mem=mem,.size=SIZE,.flags=NVN_MEMORY_POOL_FLAGS_CPU_CACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&pool,(const NVNmemoryPoolBuilder *)&pb),"own pool initializes");
    uint16_t indices[]={0,1,2}; memcpy(mem+INDEX,indices,sizeof indices);
    uint64_t own_handle=701; memcpy(mem+HANDLE,&own_handle,sizeof own_handle);
    NVNtexture texture={0}; NVNtextureBuilder builder;
    h_nvnTextureBuilderSetDefaults(&builder); h_nvnTextureBuilderSetTarget(&builder,NVN_TEXTURE_TARGET_3D);
    h_nvnTextureBuilderSetSize3D(&builder,8,8,8); h_nvnTextureBuilderSetFormat(&builder,NVN_FORMAT_R11G11B10F);
    h_nvnTextureBuilderSetStorage(&builder,(NVNmemoryPool *)&pool,TEX);
    CHECK(h_nvnTextureInitialize(&texture,&builder),"exact 8x8x8 single-level flag-free 3D LUT initializes");
    NVNtexture output={0}; h_nvnTextureBuilderSetDefaults(&builder);
    h_nvnTextureBuilderSetSize2D(&builder,8,64); h_nvnTextureBuilderSetFormat(&builder,NVN_FORMAT_RGBA32F);
    h_nvnTextureBuilderSetStorage(&builder,(NVNmemoryPool *)&pool,OUTPUT);
    CHECK(h_nvnTextureInitialize(&output,&builder),"own consumer output initializes");
    view_t sampled_view={.set_levels=1,.base_level=0,.nlevels=1};
    mtl_reg_tex(701,(const tex_t *)&texture,&sampled_view);
    for (int phase=0;phase<2;phase++) {
        mtl_set_frame((uint64_t)phase+1);
        NVNcommandBuffer cmd; CHECK(h_nvnCommandBufferInitialize(&cmd,NULL),"own command buffer initializes");
        h_nvnCommandBufferAddCommandMemory(&cmd,(const NVNmemoryPool *)&pool,0,65536); h_nvnCommandBufferBeginRecording(&cmd);
        h_nvnCommandBufferSetViewport(&cmd,0,0,8,8); h_nvnCommandBufferSetScissor(&cmd,0,0,8,8);
        h_nvnCommandBufferBindProgram(&cmd,(const NVNprogram *)&programs[0],3);
        h_nvnCommandBufferBindUniformBuffer(&cmd,NVN_SHADER_STAGE_FRAGMENT,0,(uint64_t)(mem+UBO),16);
        const NVNtexture *targets[8]; const NVNtextureView *views[8]; NVNtextureView view[8];
        for (int i=0;i<8;i++) {
            h_nvnTextureViewSetDefaults(&view[i]); h_nvnTextureViewSetLevels(&view[i],0,1);
            h_nvnTextureViewSetLayers(&view[i],i,1); h_nvnTextureViewSetTarget(&view[i],NVN_TEXTURE_TARGET_2D);
            targets[i]=&texture; views[i]=&view[i];
        }
        h_nvnCommandBufferSetRenderTargets(&cmd,8,targets,views,NULL,NULL);
        float value[]={.125f,phase?.5f:.25f,phase?.25f:.5f,1};
        h_nvnCommandBufferUpdateUniformBuffer(&cmd,(uint64_t)(mem+UBO),16,0,sizeof value,value);
        h_nvnCommandBufferDrawElements(&cmd,NVN_DRAW_PRIMITIVE_TRIANGLES,NVN_INDEX_TYPE_UNSIGNED_SHORT,3,(uint64_t)(mem+INDEX));
        // Mutating the caller's data and views must not change the recorded commands.
        memset(value,0,sizeof value); for (int i=0;i<8;i++) h_nvnTextureViewSetLayers(&view[i],0,1);
        const NVNtexture *out_target=&output;
        h_nvnCommandBufferSetRenderTargets(&cmd,1,&out_target,NULL,NULL,NULL);
        h_nvnCommandBufferSetViewport(&cmd,0,0,8,64); h_nvnCommandBufferSetScissor(&cmd,0,0,8,64);
        h_nvnCommandBufferBindProgram(&cmd,(const NVNprogram *)&programs[1],3);
        h_nvnCommandBufferBindTexture(&cmd,NVN_SHADER_STAGE_FRAGMENT,0,701);
        if (own_texu) h_nvnCommandBufferBindUniformBuffer(&cmd,NVN_SHADER_STAGE_FRAGMENT,0,(uint64_t)(mem+HANDLE),16);
        h_nvnCommandBufferDrawElements(&cmd,NVN_DRAW_PRIMITIVE_TRIANGLES,NVN_INDEX_TYPE_UNSIGNED_SHORT,3,(uint64_t)(mem+INDEX));
        NVNcommandHandle handle=h_nvnCommandBufferEndRecording(&cmd);
        state_reset(); memset(&R,0,sizeof R); mtl_sub_begin(); mtl_exec((const uint8_t *)handle);
        CHECK(mtl_wait(mtl_sub_commit(),5000000000ull),"production draw submission completes");
        CHECK(!mtl_last_commit_error(),"production draw has no GPU error");
        check_volume((const tex_t *)&texture,phase,0);
        check_volume((const tex_t *)&output,phase,1); h_nvnCommandBufferFinalize(&cmd);
    }
    mtl_reg_tex(701,NULL,NULL); h_nvnTextureFinalize(&output);
    h_nvnTextureFinalize(&texture); h_nvnMemoryPoolFinalize((NVNmemoryPool *)&pool); mtl_drain(); munmap(mem,SIZE);
}
int main(int argc,const char **argv) { @autoreleasepool {
    own_texu=argc==2 && !strcmp(argv[1],"texu");
    const char *env=getenv("DM_NVN_RESOURCE_TRACE_KEYS"); char *late=env?strdup(env):NULL;
    unsetenv("DM_NVN_RESOURCE_TRACE_KEYS"); mtl_init();
    CHECK(!g_resource_trace_initialized,"initialization before bundle environment does not lock trace off");
    if (late) { setenv("DM_NVN_RESOURCE_TRACE_KEYS",late,1); free(late); }
    programs_init(); if (!shaders) return 1;
    run();
    nvn_resource_trace frozen=g_resource_trace;
    setenv("DM_NVN_RESOURCE_TRACE_KEYS","1111111111111111",1); (void)resource_trace_on();
    CHECK(!memcmp(&frozen,&g_resource_trace,sizeof frozen),"later environment changes cannot reconfigure or rearm the process budget");
    printf("RESOURCE_METADATA %d checks, %d failed\n",checks,failed);
    printf("PATH_COUNTS tex_mtl=%llu tex_id=%llu fast=%llu fit=%llu views=%llu passes=%llu draws=%llu copies=%u dispatches=%u\n",
        (unsigned long long)g_resource_test_tex_mtl,(unsigned long long)g_resource_test_tex_id,(unsigned long long)g_resource_test_fast,
        (unsigned long long)g_resource_test_fit,(unsigned long long)g_resource_test_views,(unsigned long long)g_stat_pass,(unsigned long long)g_stat_draw,g_gp_copies,g_gp_disp);
    return failed!=0;
} }
