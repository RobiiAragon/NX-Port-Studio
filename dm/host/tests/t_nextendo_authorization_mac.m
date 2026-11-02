// Foundation lifecycle only: no NSApplication/window, Keychain, game or network.
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <stdatomic.h>
#include "../nextendo_authorization_mac.inc"
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition=PTHREAD_COND_INITIALIZER;
static BOOL released;
static uint32_t fixtureResult;
static _Atomic unsigned calls;
static _Atomic int ranOnMain;
static unsigned checks,failures;
uint32_t dm_nextendo_account_authorize_local(void) {
    atomic_fetch_add(&calls,1); if(NSThread.isMainThread) atomic_store(&ranOnMain,1);
    pthread_mutex_lock(&lock); while(!released) pthread_cond_wait(&condition,&lock);
    uint32_t result=fixtureResult; pthread_mutex_unlock(&lock); return result;
}
static void prepare(uint32_t result) { pthread_mutex_lock(&lock); released=NO; fixtureResult=result; pthread_mutex_unlock(&lock); }
static void finish(void) { pthread_mutex_lock(&lock); released=YES; pthread_cond_broadcast(&condition); pthread_mutex_unlock(&lock); }
static BOOL until(BOOL (^predicate)(void)) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];
    while(!predicate() && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    return predicate();
}
#define CHECK(c,message) do{checks++;if(!(c)){failures++;fprintf(stderr,"FAIL %s at %d\n",message,__LINE__);}}while(0)
int main(void) { @autoreleasepool {
    DmNextendoAuthorization *authorization=[DmNextendoAuthorization new]; __block unsigned callbacks=0; __block BOOL callbackOnMain=NO; __block uint32_t result=99;
    void (^completion)(uint32_t)=^(uint32_t value){callbacks++;callbackOnMain=NSThread.isMainThread;result=value;};
    CHECK(!authorization.busy && ![authorization observePendingWithCompletion:completion],"construction/opening does not authorize");
    [authorization cancelObservation]; CHECK(!atomic_load(&calls),"closing without a request never reads");
    prepare(0x2a2); CHECK([authorization authorizeWithCompletion:completion] && authorization.busy,"explicit action starts one pending request");
    CHECK(until(^BOOL{return atomic_load(&calls)==1;}),"credential read actually starts off-main");
    CHECK(![authorization authorizeWithCompletion:completion] && atomic_load(&calls)==1,"repeated click is disabled while waiting");
    [authorization cancelObservation]; finish(); CHECK(until(^BOOL{return !authorization.busy;}) && !callbacks,"closing suppresses stale completion without retrying");
    prepare(0); CHECK([authorization authorizeWithCompletion:completion],"later explicit retry starts a fresh request");
    CHECK(until(^BOOL{return atomic_load(&calls)==2;}),"second explicit read starts");
    [authorization cancelObservation]; CHECK([authorization observePendingWithCompletion:completion] && atomic_load(&calls)==2,"reopening observes the pending operation without another read");
    finish(); CHECK(until(^BOOL{return callbacks==1;}) && !authorization.busy && result==0 && callbackOnMain,"success feedback is delivered on main exactly once");
    prepare(0x2a2); CHECK([authorization authorizeWithCompletion:completion],"access denial can be requested explicitly");
    CHECK(until(^BOOL{return atomic_load(&calls)==3;}),"denial fixture read starts"); finish();
    CHECK(until(^BOOL{return callbacks==2;}) && result==0x2a2 && !authorization.busy && atomic_load(&calls)==3,"denial is preserved and never retries itself");
    prepare(0); CHECK([authorization authorizeWithCompletion:completion],"recovery requires another explicit action");
    CHECK(until(^BOOL{return atomic_load(&calls)==4;}),"recovery read starts"); finish();
    CHECK(until(^BOOL{return callbacks==3;}) && result==0 && !atomic_load(&ranOnMain),"recovery succeeds without a main-thread credential read");
    printf("Explicit Mac authorization: %u checks, %u failures; no Keychain/UI operations\n",checks,failures); return failures?1:0;
} }
