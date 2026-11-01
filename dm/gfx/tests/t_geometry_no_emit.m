// A GS can declare a nonzero bound and emit nothing; keep its compute effects.
#define main geometry_fixture_main
#include "t_geometry.m"
#undef main

static NSDictionary *no_output_metadata(void) {
    return @{@"route":@"B", @"chain":@DMSH_CHAIN, @"stage":@"gs", @"msl_entry_kind":@"kernel",
        @"geometry":@{@"vertices":@1,@"invocations":@1,@"stride":@5,@"index_stride":@2},
        @"bindings":@[
            @{@"kind":@"geometry",@"reg":@2,@"arg_id":@0},
            @{@"kind":@"geometry",@"reg":@3,@"arg_id":@1},
            @{@"kind":@"sbuf",@"reg":@0,@"arg_id":@2,@"msl_name":@"gp_s0",@"msl_type":@"device atomic_uint*",@"rw":@YES}]};
}
static void metadata_guards(void) {
    NSDictionary *j=no_output_metadata();nvn_refl rf;char error[160]={0};
    EXPECT("complete reflection parses",0,nvn_refl_from_json(j,&rf,error,sizeof error));
    EXPECT("positive stride without output binding proves no emission",1,geo_no_vertex_output(j,j[@"geometry"],&rf));
    for(NSString *field in @[@"stride",@"vertices",@"invocations",@"index_stride"]) {
        for(id value in @[@0,@(-1),@0.5,@4294967296,@"5",NSNull.null,@YES,@NO]) {
            NSMutableDictionary *candidate=[j mutableCopy],*geo=[j[@"geometry"] mutableCopy];geo[field]=value;candidate[@"geometry"]=geo;
            EXPECT("invalid geometry bound retains raster policy",0,geo_no_vertex_output(candidate,candidate[@"geometry"],&rf));
        }
        NSMutableDictionary *candidate=[j mutableCopy],*geo=[j[@"geometry"] mutableCopy];[geo removeObjectForKey:field];candidate[@"geometry"]=geo;
        EXPECT("missing geometry bound retains raster policy",0,geo_no_vertex_output(candidate,candidate[@"geometry"],&rf));
    }
    for(NSString *field in @[@"chain",@"stage",@"msl_entry_kind",@"geometry"]) {
        NSMutableDictionary *candidate=[j mutableCopy];[candidate removeObjectForKey:field];
        EXPECT("incomplete metadata retains raster policy",0,geo_no_vertex_output(candidate,candidate[@"geometry"],&rf));
    }
    NSMutableDictionary *candidate=[j mutableCopy],*geo=[j[@"geometry"] mutableCopy];geo[@"lean"]=@YES;candidate[@"geometry"]=geo;
    EXPECT("lean passthrough is not classified from absence",0,geo_no_vertex_output(candidate,candidate[@"geometry"],&rf));
    rf.b[rf.nb++]=(nvn_rbind){.kind=NVN_RB_GEOMETRY,.reg=1};
    EXPECT("default-position EmitVertex output retains raster policy",0,geo_no_vertex_output(j,j[@"geometry"],&rf));rf.nb--;
    rf.b[0].reg=0;EXPECT("missing index helper is ambiguous",0,geo_no_vertex_output(j,j[@"geometry"],&rf));rf.b[0].reg=2;
    rf.b[1].reg=4;EXPECT("missing info helper is ambiguous",0,geo_no_vertex_output(j,j[@"geometry"],&rf));rf.b[1].reg=3;
    rf.route_b=0;EXPECT("unvalidated reflection is ambiguous",0,geo_no_vertex_output(j,j[@"geometry"],&rf));
}
static void replay_no_emission(void) {
    id<MTLLibrary> l=library(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct C{device float*p;uint4 info;};vertex void capture(uint v[[vertex_id]],constant C&c[[buffer(13)]]){c.p[(v-c.info.x)*144]=float(v);}\n"
        "vertex float4 unused(){return float4(0,0,0,1);}\n"
        "struct G{device uint*ix[[id(0)]];constant uint4*info[[id(1)]];device atomic_uint*counter[[id(2)]];};\n"
        "kernel void geometry(constant G&g[[buffer(0)]],uint3 t[[thread_position_in_grid]]){if(t.x>=g.info[1].x||t.y>=g.info[0].y)return;uint k=t.y*g.info[1].x+t.x;g.ix[k*2]=0xffffffffu;g.ix[k*2+1]=0xffffffffu;atomic_fetch_add_explicit(g.counter,1u,memory_order_relaxed);}\n"
        "vertex float4 reader(){return float4(0,0,0,1);}\n"
        "struct F{float4 data[[user(locn0)]];};fragment float4 red(F f[[stage_in]]){return f.data;}\n");
    NvProg *pr=[NvProg new];pr->sh[0]=shader(l,@"unused",0,NULL,0);pr->sh[0]->geo_fn=[l newFunctionWithName:@"capture"];
    pr->sh[1]=shader(l,@"red",1,NULL,0);NvShader *gs=shader(l,@"geometry",2,NULL,0);pr->sh[2]=gs;
    NSDictionary *j=no_output_metadata();char error[160]={0};EXPECT("replay reflection parses",0,nvn_refl_from_json(j,&gs->rf,error,sizeof error));
    gs->ae=[gs->fn newArgumentEncoderWithBufferIndex:0];gs->arg_len=gs->ae.encodedLength;
    gs->geo_vertices=gs->geo_invocations=1;gs->geo_stride=5;gs->geo_output=7;gs->geo_index_stride=2;
    gs->geo_no_output=(uint8_t)geo_no_vertex_output(j,j[@"geometry"],&gs->rf);strcpy(gs->key,"123456789abcde00_b");
    g_shcache=[NSMutableDictionary dictionary];g_shcache[@"123456789abcde00_bg0"]=gs;g_shcache[@"123456789abcde00_bgv"]=shader(l,@"reader",0,NULL,0);
    static prog_t cp={.serial=19400};serial_put(cp.serial,pr);
    tex_t target={.magic=MAGIC('T','E','X',0),.serial=19401};target.d.width=target.d.height=32;target.d.depth=target.d.samples=target.d.levels=1;target.d.target=NVN_TEXTURE_TARGET_2D;target.d.format=NVN_FORMAT_RGBA8;
    uint8_t *commands;if(posix_memalign((void**)&commands,getpagesize(),65536))abort();memset(commands,0,65536);mtl_pool_add(commands,65536);
    uint32_t *counter=(uint32_t*)(commands+24576);counter[0]=counter[2]=0xa1b2c3d4;
    size_t used=0;
    #define EMIT(OP,X) do{size_t z=(8+sizeof(X)+7)&~7ull;op_hdr h={OP,(uint32_t)z};memcpy(commands+used,&h,8);memcpy(commands+used+8,&(X),sizeof(X));used+=z;}while(0)
    p_set_rt rt={.n=1};rt.color[0]=&target;EMIT(OP_SET_RT,rt);p_viewports vp={.n=1};vp.v[0][2]=vp.v[0][3]=32;EMIT(OP_VIEWPORTS,vp);p_scissor sc={0,0,32,32};EMIT(OP_SCISSOR,sc);
    p_clear_color cl={.index=0,.mask=15,.rgba={0,0,0,1}};EMIT(OP_CLEAR_COLOR,cl);p_bind_program bp={&cp,7};EMIT(OP_BIND_PROGRAM,bp);
    p_bind_buf storage={.stage=2,.index=0,.addr=(uint64_t)(counter+1),.size=4};EMIT(OP_BIND_SSBO,storage);
    p_draw d={.prim=0,.count=3,.instances=2};EMIT(OP_DRAW,d);op_hdr end={OP_END,8};memcpy(commands+used,&end,8);
    #undef EMIT
    state_reset();memset(&R,0,sizeof R);uint32_t failures=g_pso_fail.n;
    mtl_sub_begin();uint64_t h=(uint64_t)commands;mtl_sub_index(&h,1);mtl_exec(commands);
    const geo_job *job=&g_geo_run[0];id<MTLBuffer> scratch=nil;uint32_t *indices=NULL,*output=NULL,*args=NULL;
    for(NvArena *arena in g_sub_arenas)if(job->raw>=arena->gpu&&job->raw+52<=arena->gpu+arena->buf.length) {
        scratch=arena->buf;indices=(uint32_t*)((char*)scratch.contents+job->raw-arena->gpu);
        output=(uint32_t*)((char*)scratch.contents+job->output-arena->gpu);args=(uint32_t*)((char*)scratch.contents+job->args-arena->gpu);
    }
    EXPECT("geometry scratch retained",1,scratch!=nil);
    if(indices){indices[-1]=0x1234abcd;indices[12]=0x5678ef01;memset(output,0xcc,120);}
    id<MTLBuffer> pixels=[g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    if(!pixels)abort();
    [blit() copyFromTexture:tex_mtl(&target) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(32,32,1) toBuffer:pixels destinationOffset:0 destinationBytesPerRow:128 destinationBytesPerImage:4096];finish();
    EXPECT("no invalid reader/fragment pipeline attempted",failures,g_pso_fail.n);
    EXPECT("all six geometry compute invocations retain storage writes",6,counter[1]);
    EXPECT("storage prefix canary",0xa1b2c3d4,counter[0]);EXPECT("storage suffix canary",0xa1b2c3d4,counter[2]);
    EXPECT("raw index stride retained",2,job->gs->geo_index_stride);EXPECT("SPH bound retained",1,job->emits);
    if(indices){
        for(int i=0;i<12;i++)EXPECT("per-invocation index sentinel retained",UINT32_MAX,indices[i]);
        EXPECT("raw-index prefix canary",0x1234abcd,indices[-1]);EXPECT("raw-index suffix canary",0x5678ef01,indices[12]);
        for(int i=0;i<30;i++)EXPECT("no vertex-output stores",0xcccccccc,output[i]);
        EXPECT("GPU compaction produces zero raster indices",0,args[0]);
    }
    uint8_t *px=pixels.contents;int red=0;for(int i=0;i<1024;i++)red+=px[i*4]!=0;
    EXPECT("no vertices rasterized",0,red);EXPECT("raster program never substituted",1,pr->geo_raster==nil);
    mtl_tex_release(&target);mtl_pool_del(commands);mtl_drain();free(commands);
}
int main(void){@autoreleasepool{setvbuf(stdout,NULL,_IONBF,0);metadata_guards();mtl_init();replay_no_emission();printf("t_geometry_no_emit: %d checks, %d failed\n",checks,failed);return failed!=0;}}
