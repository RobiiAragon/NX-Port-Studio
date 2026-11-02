// Production present lifecycle with a silent display link, deterministic pacing
// inputs and a real monotonic wait. No Metal device, drawable, game or window.
#import <QuartzCore/CAMetalDisplayLink.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <time.h>
static pthread_mutex_t observed_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t observed_changed=PTHREAD_COND_INITIALIZER;
static int observed;
static unsigned timed_waits;
static int observe_timedwait(pthread_cond_t *cond,pthread_mutex_t *lock,const struct timespec *limit) {
    ++timed_waits; return pthread_cond_timedwait(cond,lock,limit);
}
static int observe_wait(pthread_cond_t *cond,pthread_mutex_t *lock) {
    pthread_mutex_lock(&observed_lock); observed=1; pthread_cond_broadcast(&observed_changed); pthread_mutex_unlock(&observed_lock);
    return pthread_cond_wait(cond,lock);
}
@interface BackgroundLink : NSObject
@property CAFrameRateRange preferredFrameRateRange;
@property float preferredFrameLatency;
@property (weak) id<CAMetalDisplayLinkDelegate> delegate;
@property BOOL paused;
@property BOOL invalidated;
- (instancetype)initWithMetalLayer:(CAMetalLayer *)layer;
- (void)addToRunLoop:(NSRunLoop *)loop forMode:(NSRunLoopMode)mode;
- (void)invalidate;
@end
@implementation BackgroundLink
- (instancetype)initWithMetalLayer:(CAMetalLayer *)layer { (void)layer; return [super init]; }
- (void)addToRunLoop:(NSRunLoop *)loop forMode:(NSRunLoopMode)mode { (void)loop; (void)mode; }
- (void)invalidate { self.invalidated=YES; }
@end
#define CAMetalDisplayLink BackgroundLink
#define pthread_cond_timedwait observe_timedwait
#define pthread_cond_wait observe_wait
#include "../nvn/nvn_mtl.m"
#undef pthread_cond_timedwait
#undef pthread_cond_wait
#undef CAMetalDisplayLink
#include "../nvn/nvn_pace.h"
module_t *g_mod; int g_nmod;
module_t *module_of(const void *p) { (void)p; return NULL; }
void svc_thread_dump(void) {}
void *front_metal_layer(void) { abort(); } // Any hidden drawable path is a failure.
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000+t.tv_nsec; }
static unsigned checks;
#define CHECK(c) do { ++checks; if (!(c)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#c); abort(); } } while (0)
static void sleep_to(uint64_t target) {
    for (;;) { uint64_t now=now_ns(); if (now>=target) return;
        uint64_t left=target-now; struct timespec t={(time_t)(left/1000000000),(long)(left%1000000000)};
        if (!nanosleep(&t,NULL) || errno!=EINTR) return;
    }
}
static void *ticket_wait(void *unused) { (void)unused; mtl_present_wait(3); return NULL; }
// The fixture drives delivered ticks explicitly: VM scheduling is not a display
// callback contract. A late CPU frame is a separate input, not a wider timeout.
static void cadence(unsigned hz,int fallback,int late) {
    const unsigned frames=hz*3/10; const uint64_t period=1000000000/hz,start=1000000000;
    nvn_pacer pacer={start}; unsigned link_waits=0,clock_waits=0,late_frames=0,before_waits=timed_waits;
    for (unsigned i=0;i<frames;++i) {
        uint64_t frame_start=pacer.target;
        if (late && i==frames/2) frame_start+=3*period;
        uint64_t wait=nvn_pace(&pacer,frame_start,period);
        if (late && i==frames/2) {
            CHECK(!wait && pacer.target==frame_start); ++late_frames; // No catch-up burst.
        } else CHECK(wait==period && pacer.target==frame_start+period);
        if (!fallback) {
            pthread_mutex_lock(&g_link_mu); g_link_tick_n+=60/hz; pthread_mutex_unlock(&g_link_mu);
        }
        if (mtl_link_active() && mtl_link_wait_tick((int)(60/hz),2*period)) ++link_waits;
        else if (wait) ++clock_waits;
    }
    CHECK(timed_waits==before_waits); // Hidden/non-key paths must not await a silent link.
    CHECK(pacer.target-start==(frames+2*late_frames)*period);
    CHECK(fallback ? !link_waits && clock_waits==frames-late_frames : link_waits==frames && !clock_waits);
    printf("%u Hz %s%s: %u deadlines PASS\n",hz,fallback?"background monotonic":"key visible link",late?" after CPU deschedule":"",frames);
}
static void real_monotonic_wait(unsigned hz) {
    uint64_t start=now_ns(),period=1000000000/hz; nvn_pacer pacer={start};
    CHECK(!mtl_link_active() && nvn_pace(&pacer,start,period)==period);
    sleep_to(pacer.target);
    CHECK(now_ns()>=pacer.target); // No VM-dependent upper wall-time requirement.
}
int main(void) { @autoreleasepool {
    mtl_present_window_state(1,1); uint64_t before=atomic_load(&g_present_epoch);
    g_dm_present_link=1; g_link=[BackgroundLink new]; CHECK(mtl_link_active());
    pthread_mutex_lock(&g_pq_mu); g_pq_in=3; g_pq_read=1; g_pq_done=0; g_pq_inflight=1; pthread_mutex_unlock(&g_pq_mu);
    mtl_present_window_state(0,0);
    CHECK(!mtl_link_active() && g_pq_read==3 && g_pq_done==0);
    void *poison=mmap(NULL,4096,PROT_NONE,MAP_ANON|MAP_PRIVATE,-1,0); CHECK(poison!=MAP_FAILED);
    CHECK(present_enqueue(poison,1.0/60,NULL,0)==0); // Must not resolve a texture or get a drawable.
    unsigned begin_waits=timed_waits; uint64_t seen=0;
    CHECK(!mtl_link_wait_ticks(1,1000000000) && !mtl_link_wait_vsync(&seen,1000000000));
    CHECK(timed_waits==begin_waits);
    pthread_t waiter; CHECK(!pthread_create(&waiter,NULL,ticket_wait,NULL));
    pthread_mutex_lock(&observed_lock);
    while (!observed) pthread_cond_wait(&observed_changed,&observed_lock);
    pthread_mutex_unlock(&observed_lock);
    mtl_present_window_state(1,1); CHECK(g_pq_done==0); // Restore does not release the GPU reader early.
    pthread_mutex_lock(&g_pq_mu); present_unsubmitted_locked(3,before); pthread_mutex_unlock(&g_pq_mu);
    CHECK(g_pq_done==0); // Nor does an obsolete CPU presenter finishing early.
    pthread_mutex_lock(&g_pq_mu); g_pq_inflight=0; present_hidden_drop_locked(); pthread_mutex_unlock(&g_pq_mu);
    CHECK(!pthread_join(waiter,NULL) && g_pq_done==3);
    CHECK(!present_now(poison,1.0/60,0,1,NULL,0,nil,0,before)); // Stale epoch cannot publish after restore.
    CHECK(!munmap(poison,4096));
    // A non-key but visible window remains presentable. The actual run-loop
    // handoff must invalidate the old link before releasing nextDrawable.
    BackgroundLink *old_link=g_link; g_link_started=1; g_link_owns_layer=1;
    g_link_rl=CFRunLoopGetCurrent(); link_sync(); CHECK(mtl_link_active());
    uint64_t key_epoch=atomic_load(&g_present_epoch);
    pthread_mutex_lock(&g_pq_mu); g_pq_in=6; g_pq_read=3; pthread_mutex_unlock(&g_pq_mu);
    mtl_present_window_state(1,0);
    CHECK(!mtl_link_active() && !g_present_hidden && g_pq_read==6 && g_pq_done==6);
    CHECK(present_epoch_valid(atomic_load(&g_present_epoch)) && !present_epoch_valid(key_epoch));
    link_sync(); CHECK(g_link_owns_layer && !old_link.invalidated && g_dm_present_link==1);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
    CHECK(old_link.invalidated && !g_link_owns_layer && !g_link);
    g_link_started=0; g_link=[BackgroundLink new]; mtl_present_window_state(1,1);
    for (unsigned hz=30;hz<=60;hz+=30) {
        cadence(hz,0,0); cadence(hz,0,1);
        mtl_present_window_state(1,0); // Visible behind another app, link silent.
        CHECK(present_epoch_valid(atomic_load(&g_present_epoch))); cadence(hz,1,0); cadence(hz,1,1); real_monotonic_wait(hz);
        mtl_present_window_state(0,0); // Covered / minimized / another Space.
        CHECK(!present_epoch_valid(atomic_load(&g_present_epoch))); cadence(hz,1,0); cadence(hz,1,1); real_monotonic_wait(hz);
        mtl_present_window_state(1,1); cadence(hz,0,0); cadence(hz,0,1);
    }
    g_link=nil;
    printf("background presentation: %u checks PASS\n",checks); return 0;
} }
