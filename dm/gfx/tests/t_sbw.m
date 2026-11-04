// Other GPU writes of a submission (sbw_note / sbw_hits): a storage buffer bound with size 0 counts as the rest of its Metal buffer, kept as an interval,
// so a uniform block in another buffer can still be read from memory (GitHub issue #534: Breath of the Wild's shrines)
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label,c) do {checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",label);}}while(0)
int main(void){@autoreleasepool{
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice();
    id<MTLBuffer> pool=[dev newBufferWithLength:0xa04000 options:MTLResourceStorageModeShared];   // BotW's particle pool: 10 MB at 0x70c5d50000
    void *mb=(__bridge void*)pool;const uint64_t base=0x70c5d50000ull,ub=0x70c38c0000ull;
    CHECK("a sized binding writes its size",sbw_len(64,mb,0x40d80)==64);
    CHECK("a size-0 binding writes the rest of its buffer",sbw_len(0,mb,0x40d80)==0xa04000-0x40d80);
    CHECK("an offset past the buffer writes nothing",sbw_len(0,mb,0xa04000)==0);
    pend_reset();
    for(int s=0;s<3;s++){uint64_t o=0x40d80+0x400*s;sbw_note(base+o,sbw_len(0,mb,o),SBW_GPU);}   // the three outputs of cs_effect var3 (9f8116baffddaf81)
    CHECK("size-0 bindings do not stop the tracking",!g_sbw_over);
    CHECK("nested wide writes merge into one interval",g_nsbw_w==1);
    CHECK("the uniform block in another buffer is not hit",!sbw_hits(ub,ub+0x100));
    CHECK("the particle outputs are hit",sbw_hits(base+0x41000,base+0x41010));
    CHECK("the rest of their buffer is hit",sbw_hits(base+0xa03ff0,base+0xa04000));
    CHECK("bytes before the first output are not hit",!sbw_hits(base,base+0x40d80));
    sbw_note(ub+0x2000,16,SBW_GPU);
    CHECK("a small write is still kept by page",sbw_hits(ub+0x2f00,ub+0x2f10)&&!sbw_hits(ub,ub+0x100));
    sbw_note(ub,0,SBW_GPU);
    CHECK("a write of no known size stops the tracking",g_sbw_over);
    pend_reset();
    CHECK("a new submission starts empty",!g_sbw_over&&!g_nsbw_w&&!sbw_hits(base+0x41000,base+0x41010));
    for(int i=0;i<SBW_WN;i++)sbw_note(base+(uint64_t)i*0x100000,0x80000,SBW_GPU);
    CHECK("disjoint wide writes each take an interval",!g_sbw_over&&g_nsbw_w==SBW_WN);
    sbw_note(base+(uint64_t)SBW_WN*0x100000,0x80000,SBW_GPU);
    CHECK("one more than the list holds stops the tracking",g_sbw_over);
    pend_reset();sbw_note(base+0x40d80,sbw_len(0,mb,0x40d80),SBW_GPU);
    uint64_t done=g_done;gw_commit(done+1000);
    CHECK("a running submission's wide write is seen by the next",gw_live(base+0x41000,base+0x41010));
    CHECK("and not elsewhere",!gw_live(ub,ub+0x100));
    // Adapted from seedds/nxnative c8521eeb: keep query and timestamp reports beyond the former fixed tables.
    // Real synthetic storage keeps the pre-fix fallback readable too, so failures are assertions rather than invalid-address crashes.
    {static uint64_t rec[2]={1,0},queries[9000][2],timestamps[300][2];uint64_t x=~0ull;
    for(int i=0;i<9000;i++){queries[i][0]=i+1;rc_note((uint64_t)&queries[i][0],2);}
    rc_note((uint64_t)&rec[0],1);
    CHECK("a timestamp after 9000 query reports counts as zero",rc_value((uint64_t)&rec[0],&x)&&x==0);
    CHECK("unreported counter still reads its synthetic storage",rc_value((uint64_t)&rec[1],&x)&&x==0);
    CHECK("early and late occlusion reports both stay unknown",!rc_value((uint64_t)&queries[0][0],&x)&&!rc_value((uint64_t)&queries[8999][0],&x));
    for(int i=0;i<300;i++){timestamps[i][0]=1;rc_note((uint64_t)&timestamps[i][0],1);}
    CHECK("early and late timestamps survive more than 256 reports",rc_value((uint64_t)&timestamps[0][0],&x)&&x==0&&rc_value((uint64_t)&timestamps[299][0],&x)&&x==0);
    rc_note((uint64_t)&timestamps[0][0],1);
    g_rc_npend=0;
    CHECK("submission reset forgets pending timestamp values",rc_value((uint64_t)&rec[0],&x)&&x==1);
    CHECK("occlusion reports remain unknown across submissions",!rc_value((uint64_t)&queries[8999][0],&x));}
    pend_reset();
    printf("t_sbw: %d checks, %d failed\n",checks,failed);return failed!=0;
}}
