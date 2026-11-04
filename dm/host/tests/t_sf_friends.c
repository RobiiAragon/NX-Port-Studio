// Original synthetic CMIF messages through the production SF dispatcher and
// kernel event table. No game files, credential provider or HTTP is used.
#include "../hle_thread.c"
#include "../hle.h"
#undef HLE_FORCE
#undef HLE_FORCE_WAIT
#define HLE_FORCE(name, why, ret, cname, ...) static ret cname(__VA_ARGS__)
#define HLE_FORCE_WAIT HLE_FORCE
static _Atomic int mute_sf_logs;
#undef LOG
#define LOG(...) do { if(!atomic_load(&mute_sf_logs)){flockfile(stderr);fprintf(stderr,"[dm] " __VA_ARGS__);fputc('\n',stderr);funlockfile(stderr);} } while(0)
#include "../hle_sf.c"
#include <stdio.h>
#include <unistd.h>
struct dm_flags g_flag;
module_t *g_mod;int g_nmod;
uint64_t g_t0_ns;
__thread _Atomic int dm_host_work;
pthread_key_t g_key18;
void crash_thread_init(void) {} void guest_thread_init(void) {}
void guest_thread_set_id(uint64_t id) {(void)id;} void guest_gate_stack(int own) {(void)own;}
void dm_thread_enter(uint64_t entry,uint64_t arg,uint64_t sp) {(void)entry;(void)arg;(void)sp;abort();}
uint64_t now_ns(void) { return 0; } uint64_t guest_ns(void) {return 0;}
int dm_detclock_enabled(void) {return 0;} int dm_sdk_major(void) {return 20;}
module_t *module_of(const void *p) {(void)p;return NULL;}
void dm_backtrace(uint64_t fp) {(void)fp;}
void *guest_sym(const char *name) {(void)name;return NULL;}
static uint32_t backend_result;static unsigned backend_calls;
static pthread_mutex_t backend_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t backend_cv=PTHREAD_COND_INITIALIZER;
static int backend_hold,backend_entered;
uint32_t dm_nextendo_friends_available(uint8_t *available,const void *uid) {
    backend_calls++;if(((const uint8_t *)uid)[0]!=0x31)return RES_FAIL;
    *available=backend_result?0:1;return backend_result;
}
uint32_t dm_nextendo_friends_ensure(const void *uid) {
    backend_calls++;if(((const uint8_t *)uid)[0]!=0x31)return RES_FAIL;
    pthread_mutex_lock(&backend_lock);backend_entered=1;pthread_cond_broadcast(&backend_cv);
    while(backend_hold)pthread_cond_wait(&backend_cv,&backend_lock);
    pthread_mutex_unlock(&backend_lock);return backend_result;
}
static int checks, failures;
#define CHECK(expr) do { checks++; if (!(expr)) { failures++; fprintf(stderr,"SF friends fixture failed line %d\n",__LINE__); } } while(0)
static void request(uint32_t message[64], uint32_t object,uint32_t command,const void *input,size_t size) {
    // The original SDK reserves eight trailing padding bytes: 12 data words
    // for a no-argument domain request, and 16 for a UID request.
    memset(message,0,64*sizeof *message);message[0]=6;message[1]=(48+size-8+3)/4+2;
    message[4]=1|((16u+(unsigned)size)<<16);message[5]=object;
    message[8]=0x49434653;message[9]=1;message[10]=command;
    if(size)memcpy(message+12,input,size);
}
static uint32_t result(const uint32_t *message) {CHECK(message[8]==0x4f434653);return message[10];}
static int signaled(uint32_t handle) {
    pthread_mutex_lock(&G);event_t *event=h_peek(handle,O_EVENT_R);int value=event?event->signaled:-1;pthread_mutex_unlock(&G);return value;
}
static void close_handle(uint32_t handle) {uint64_t r[32]={handle};CHECK(svc_thread(0x16,r)&&!r[0]);}
static uint32_t create_service(uint32_t session) {
    uint32_t message[64];request(message,1,0,NULL,0);CHECK(!h_sf_Send(session,message,sizeof message)&&!result(message));
    CHECK(message[4]==1&&message[12]>1);return message[12];
}
static uint32_t completion(uint32_t session,uint32_t object) {
    uint32_t message[64];request(message,object,0,NULL,0);CHECK(!h_sf_Send(session,message,sizeof message)&&!result(message));
    CHECK(message[2]==2);return message[3];
}
static void close_object(uint32_t session,uint32_t object) {
    uint32_t message[64];request(message,object,0,NULL,0);message[4]=2;message[1]=6;
    CHECK(!h_sf_Send(session,message,sizeof message));
}
typedef struct {uint32_t session,object,transport,result;} worker;
static void *ensure_worker(void *argument) {
    worker *work=argument;uint32_t message[64];uint8_t uid[16]={0x31};
    request(message,work->object,10121,uid,16);work->transport=h_sf_Send(work->session,message,sizeof message);
    work->result=message[10];return NULL;
}
static pthread_t start_held(worker *work) {
    pthread_mutex_lock(&backend_lock);backend_hold=1;backend_entered=0;pthread_mutex_unlock(&backend_lock);
    pthread_t thread;CHECK(!pthread_create(&thread,NULL,ensure_worker,work));
    pthread_mutex_lock(&backend_lock);while(!backend_entered)pthread_cond_wait(&backend_cv,&backend_lock);pthread_mutex_unlock(&backend_lock);
    return thread;
}
static void release_held(pthread_t thread) {
    pthread_mutex_lock(&backend_lock);backend_hold=0;pthread_cond_broadcast(&backend_cv);pthread_mutex_unlock(&backend_lock);
    CHECK(!pthread_join(thread,NULL));
}
static void cancellation(uint32_t session) {
    backend_result=0;uint32_t object=create_service(session),event=completion(session,object),message[64];
    request(message,object,1,NULL,0);CHECK(!h_sf_Send(session,message,sizeof message)&&!result(message)&&!signaled(event));
    worker work={session,object,99,99};pthread_t thread=start_held(&work);CHECK(!signaled(event));
    request(message,object,1,NULL,0);CHECK(!h_sf_Send(session,message,sizeof message)&&!result(message)&&signaled(event)==1);
    release_held(thread);CHECK(!work.transport&&work.result!=0);
    uint8_t uid[16]={0x31};request(message,object,10121,uid,16);CHECK(!h_sf_Send(session,message,sizeof message)&&!result(message)&&signaled(event)==1);
    close_object(session,object);close_handle(event);
    object=create_service(session);event=completion(session,object);work=(worker){session,object,99,99};thread=start_held(&work);
    close_object(session,object);CHECK(signaled(event)==1);
    request(message,object,0,NULL,0);CHECK(!h_sf_Send(session,message,sizeof message)&&result(message)!=0);
    release_held(thread);CHECK(!work.transport&&work.result!=0);close_handle(event);
}
static void malformed(uint32_t session,uint32_t object) {
    uint32_t message[64],before[64];uint8_t uid[16]={0x31};unsigned calls=backend_calls;
    for(unsigned size=0;size<64;size++) {
        request(message,object,10121,uid,16);memcpy(before,message,sizeof before);
        CHECK(h_sf_Send(session,message,size)!=0&&!memcmp(message,before,sizeof message));
    }
    const struct {unsigned word;uint32_t value;} fields[]={
        {0,0},{0,7},{1,0x3ff},{1,0},{4,0x000f0001},{4,0x7fff0001},{4,0x00200101},
        {8,0xdeadbeef},{9,2},{0,0xfff00006},{1,0x80000000}
    };
    for(unsigned i=0;i<sizeof fields/sizeof *fields;i++) {
        request(message,object,10121,uid,16);message[fields[i].word]=fields[i].value;
        uint32_t status=h_sf_Send(session,message,sizeof message);
        CHECK(status||result(message)!=0);
    }
    CHECK(backend_calls==calls);
    // Exercise every truncated-header alignment with arbitrary non-pointer
    // bytes. The production parser must never read beyond the supplied span.
    uint8_t *bytes=malloc(4096);CHECK(bytes!=NULL);if(!bytes)return;
    uint32_t seed=0x5827;
    for(unsigned trial=0;trial<2000;trial++) {
        for(unsigned i=0;i<4096;i++){seed=seed*1664525+1013904223;bytes[i]=(uint8_t)(seed>>24);}
        sf_friend_request parsed;size_t size=trial%4097;
        CHECK(!sf_friend_parse(bytes,size,1,&parsed));
    }
    free(bytes);CHECK(backend_calls==calls);
}
static void server_event_lifetimes(void) {
    uint64_t binding=0;uint32_t read=0,other=0;
    CHECK(hle_service_event_create(NULL)!=0);
    CHECK(!hle_service_event_create(&binding)&&binding);
    CHECK(!hle_service_event_copy(binding,&read)&&!hle_service_event_copy(binding,&other)&&read!=other);
    CHECK(!signaled(read)&&!signaled(other));CHECK(hle_signal_system_event_binding(binding)&&signaled(read)==1);
    CHECK(hle_service_event_clear(binding)&&!signaled(other));close_handle(read);
    CHECK(hle_signal_system_event_binding(binding)&&signaled(other)==1);
    hle_service_event_close(binding);CHECK(!hle_signal_system_event_binding(binding));
    uint32_t untouched=0xface;CHECK(hle_service_event_copy(binding,&untouched)!=0&&untouched==0xface);
    uint64_t replacement=0;CHECK(!hle_service_event_create(&replacement)&&replacement!=binding);
    uint32_t next=0;CHECK(!hle_service_event_copy(replacement,&next)&&!signaled(next));
    CHECK(!hle_signal_system_event_binding(binding)&&!signaled(next));
    CHECK(signaled(other)==1);close_handle(other);close_handle(next);hle_service_event_close(replacement);hle_service_event_close(binding);
    CHECK(g_nse==0);
}
static void capacity_limits(void) {
    uint32_t session=0,root=0,message[64];CHECK(!h_sf_Connect(&session,"friend:u")&&!h_sf_ToDomain(&root,session));
    for(unsigned i=0;i<64;i++)(void)create_service(session);
    CHECK(g_nse==64);request(message,root,0,NULL,0);
    CHECK(!h_sf_Send(session,message,sizeof message)&&result(message)!=0&&!message[4]);
    CHECK(g_nse==64);h_sf_Close(session);CHECK(g_nse==0);
    uint32_t sessions[64];for(unsigned i=0;i<64;i++)CHECK(!h_sf_Connect(&sessions[i],"friend:u"));
    uint32_t untouched=0xface;CHECK(h_sf_Connect(&untouched,"friend:u")!=0&&untouched==0xface);
    for(unsigned i=0;i<64;i++)h_sf_Close(sessions[i]);CHECK(g_nse==0);
}
static _Atomic uint32_t legacy_handle;
static _Atomic unsigned legacy_errors;
static pthread_mutex_t legacy_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t legacy_cv=PTHREAD_COND_INITIALIZER;
static unsigned legacy_waiting;static int legacy_go;
static void legacy_gate(void) {
    pthread_mutex_lock(&legacy_lock);legacy_waiting++;pthread_cond_broadcast(&legacy_cv);
    while(!legacy_go)pthread_cond_wait(&legacy_cv,&legacy_lock);pthread_mutex_unlock(&legacy_lock);
}
static void legacy_request(uint32_t session,unsigned domain,unsigned command) {
    uint32_t message[64];request(message,1,command,NULL,0);
    if(!domain){memcpy(message+4,message+8,16);memset(message+8,0,16);message[1]=8;}
    uint32_t status=h_sf_Send(session,message,sizeof message);
    // A concurrently closed handle or changed domain may reject this request.
    // A successful legacy response must still be one complete, zero-result
    // CMIF reply for the domain state held during this dispatch.
    if(!status&&!(message[4]==0x4f434653&&!message[6])&&!(message[8]==0x4f434653&&!message[10]))atomic_fetch_add(&legacy_errors,1);
}
static void *legacy_sender(void *unused) {
    (void)unused;legacy_gate();
    for(unsigned i=0;i<4000;i++)legacy_request(atomic_load(&legacy_handle),i&1,i&3);
    return NULL;
}
static void *legacy_reuser(void *unused) {
    (void)unused;legacy_gate();
    for(unsigned i=0;i<2000;i++) {
        h_sf_Close(atomic_load(&legacy_handle));uint32_t next=0;
        if(h_sf_Connect(&next,"olsc:u"))atomic_fetch_add(&legacy_errors,1);
        else atomic_store(&legacy_handle,next);
    }
    return NULL;
}
static void *legacy_cloner(void *unused) {
    (void)unused;legacy_gate();
    for(unsigned i=0;i<2000;i++) {
        uint32_t clone=0,object=0;
        if(!h_sf_Dup(&clone,atomic_load(&legacy_handle))) {
            if(i&1)(void)h_sf_ToDomain(&object,clone);
            legacy_request(clone,i&1,i&3);h_sf_Close(clone);
        }
        if(i&1)(void)h_sf_ToDomain(&object,atomic_load(&legacy_handle));
    }
    return NULL;
}
static void legacy_concurrency(void) {
    uint32_t session=0;CHECK(!h_sf_Connect(&session,"olsc:u"));atomic_store(&legacy_handle,session);
    atomic_store(&mute_sf_logs,1);pthread_t workers[3];
    CHECK(!pthread_create(&workers[0],NULL,legacy_sender,NULL));
    CHECK(!pthread_create(&workers[1],NULL,legacy_reuser,NULL));
    CHECK(!pthread_create(&workers[2],NULL,legacy_cloner,NULL));
    pthread_mutex_lock(&legacy_lock);while(legacy_waiting!=3)pthread_cond_wait(&legacy_cv,&legacy_lock);
    legacy_go=1;pthread_cond_broadcast(&legacy_cv);pthread_mutex_unlock(&legacy_lock);
    for(unsigned i=0;i<3;i++)CHECK(!pthread_join(workers[i],NULL));
    // Deliberate handle reuse can retire a concurrently duplicated handle;
    // discard every remaining fixture session after all workers have stopped.
    for(unsigned i=0;i<SF_MAX;i++)if(g_sf[i].used)h_sf_Close(SF_H0+i);
    atomic_store(&mute_sf_logs,0);CHECK(!atomic_load(&legacy_errors));CHECK(g_nse==0);
}
int main(void) {
    uint32_t session=0,root=0,message[64];
    CHECK(!h_sf_Connect(&session,"friend:u"));
    if(!session)goto finish;
    CHECK(!h_sf_ToDomain(&root,session)&&root==1);
    request(message,root,0,NULL,0);CHECK(message[1]==12);CHECK(!h_sf_Send(session,message,sizeof message));
    CHECK(!result(message)&&message[4]==1&&message[12]>1);uint32_t service=message[12];
    request(message,service,0,NULL,0);CHECK(!h_sf_Send(session,message,sizeof message)&&!result(message));
    CHECK((message[1]>>31)==1&&message[2]==2);uint32_t event=message[3];CHECK(signaled(event)==0);
    request(message,service,0,NULL,0);CHECK(!h_sf_Send(session,message,sizeof message)&&!result(message));
    uint32_t second=message[3];CHECK(second!=event&&signaled(second)==0);
    uint8_t uid[16]={0x31};
    request(message,service,10120,uid,16);CHECK(message[1]==16);CHECK(!h_sf_Send(session,message,sizeof message)&&!result(message)&&((uint8_t *)message)[48]==1);
    request(message,service,10121,uid,16);CHECK(!h_sf_Send(session,message,sizeof message)&&!result(message));
    CHECK(signaled(event)==1&&signaled(second)==1);
    backend_result=0x5a2;
    request(message,service,10121,uid,16);CHECK(!h_sf_Send(session,message,sizeof message)&&result(message)==backend_result);
    CHECK(signaled(event)==1);
    request(message,service,10120,uid,16);CHECK(!h_sf_Send(session,message,sizeof message)&&result(message)==backend_result);
    CHECK(((uint8_t *)message)[48]==0);
    unsigned calls=backend_calls;
    request(message,service,10121,uid,15);CHECK(!h_sf_Send(session,message,sizeof message)&&result(message)!=0&&backend_calls==calls);
    request(message,service,99999,NULL,0);CHECK(!h_sf_Send(session,message,sizeof message)&&result(message)!=0&&backend_calls==calls);
    uint32_t clone=0;CHECK(!h_sf_Dup(&clone,session));h_sf_Close(session);
    request(message,service,0,NULL,0);CHECK(!h_sf_Send(clone,message,sizeof message)&&!result(message));close_handle(message[3]);
    request(message,service,0,NULL,0);message[4]=2;message[1]=6;CHECK(!h_sf_Send(clone,message,sizeof message));
    request(message,service,0,NULL,0);CHECK(!h_sf_Send(clone,message,sizeof message)&&result(message)!=0);
    CHECK(signaled(event)==1&&signaled(second)==1);close_handle(event);close_handle(second);h_sf_Close(clone);
    CHECK(g_nse==0);
    CHECK(!h_sf_Connect(&session,"friend:u")&&!h_sf_ToDomain(&root,session));
    cancellation(session);service=create_service(session);malformed(session,service);h_sf_Close(session);
    CHECK(g_nse==0);server_event_lifetimes();capacity_limits();legacy_concurrency();
finish:
    printf("SF friends synthetic IPC/kernel fixture: %d checks, %d failures\n",checks,failures);
    return failures!=0;
}
