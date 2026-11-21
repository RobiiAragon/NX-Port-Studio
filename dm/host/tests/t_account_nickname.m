// Actual account HLE table plus the production validated-memory snapshot.
// Profiles are synthetic, their zero HMAC cannot authenticate, and Security is fake.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "../hle.h"
#include "t_gate_fixture.h"
#include "../net_socket.h"
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
static unsigned checks,failures;
static _Atomic unsigned providerReads,keychainReads;
static dm_net_mode_t mode=DM_NET_NEXTENDO;
static NSData *fixture;
static pthread_mutex_t fixtureLock=PTHREAD_MUTEX_INITIALIZER;
static OSStatus fakeCopy(CFDictionaryRef query,CFTypeRef *out) { (void)query;keychainReads++;if(out)*out=NULL;return errSecInteractionNotAllowed; }
#define SecItemCopyMatching fakeCopy
#include "../hle_nextendo_apple.m"
#undef SecItemCopyMatching
dm_net_mode_t dm_net_mode(void){return mode;}
void dm_guest_host_wait_begin(void){} void dm_guest_host_wait_end(void){}
void thr_svc_enter(uint64_t *registers,uint64_t pc){(void)registers;(void)pc;}
void thr_svc_leave(void){}
int dm_guest_as_contains(uintptr_t address){(void)address;return 0;}
uint64_t gate_dispatch(uint64_t result,uint64_t *registers){(void)result;(void)registers;abort();}
uint64_t unimpl_c(unsigned index,uint64_t *registers){(void)index;(void)registers;abort();}
void dm_thread_returned(void){abort();}
void *guest_sym(const char *name){(void)name;return NULL;}
void hle_bind_system_event(void *event,int clear){(void)event;(void)clear;abort();}
uint64_t hle_system_event_binding(void *event){(void)event;abort();}
int hle_signal_system_event_binding(uint64_t binding){(void)binding;abort();}
void hle_signal_system_event(void *event){(void)event;abort();}
bool dm_nextendo_api_baas_namespace(const char *kind){(void)kind;abort();}
uint32_t dm_nextendo_api_baas_id(uint64_t *output){(void)output;abort();}
int dm_nextendo_preflight_query(dm_nextendo_preflight_reply *reply,unsigned timeout){(void)reply;(void)timeout;abort();}
dm_nextendo_preflight_status dm_nextendo_preflight_last_status(void){abort();}
#define CHECK(c,label) do{checks++;if(!(c)){failures++;fprintf(stderr,"FAIL %d: %s\n",__LINE__,label);}}while(0)
static bool provider(uint8_t *buffer,size_t capacity,size_t *size) {
    providerReads++;pthread_mutex_lock(&fixtureLock);NSData *data=fixture;pthread_mutex_unlock(&fixtureLock);
    if(!data || data.length>capacity)return false;
    memcpy(buffer,data.bytes,data.length);*size=data.length;return true;
}
static void setProfile(NSData *data){pthread_mutex_lock(&fixtureLock);fixture=data;pthread_mutex_unlock(&fixtureLock);}
static NSData *profile(NSString *name) {
    uint64_t now=(uint64_t)NSDate.date.timeIntervalSince1970,expiry=now+600;uint8_t zero[32]={0};
    NSString *claims=[NSString stringWithFormat:@"1800000042.%@.%llu",name,expiry];
    NSString *proof=[NSString stringWithFormat:@"nx2.%@.%@",base64url([claims dataUsingEncoding:NSUTF8StringEncoding]),base64url([NSData dataWithBytes:zero length:32])];
    return [NSJSONSerialization dataWithJSONObject:@{@"schema_version":@1,@"token_kind":@"nex",@"token":proof,@"identity":@{@"pid":@1800000042ull,@"username":name},@"scopes":@[],@"created_at":@(now-30),@"expires_at":@(expiry)} options:0 error:nil];
}
static void *hook(const char *name) {
    fixture_gate_prepare();unsigned long bytes=0;
    const hle_force_ent *table=(const hle_force_ent *)getsectiondata(&_mh_execute_header,"__DATA","swforce",&bytes);
    for(unsigned long i=0;table && i<bytes/sizeof *table;i++)if(!strcmp(table[i].name,name))return table[i].fn;
    abort();
}
typedef uint32_t (*GetNickname)(char *,const void *);
static GetNickname nickname;
static uint64_t uid[2],other[2];
static void expect(const void *who,const char *wanted,uint32_t result,const char *label) {
    uint8_t bytes[35];memset(bytes,0xa5,sizeof bytes);char *out=(char *)bytes+1;
    unsigned before=providerReads,kc=keychainReads;
    CHECK(nickname(out,who)==result,label);
    CHECK(!memcmp(out,wanted,strlen(wanted)+1),label);
    CHECK(bytes[0]==0xa5 && bytes[34]==0xa5 && out[32]==0,"the 33-byte Nickname ABI preserves both neighboring canaries");
    CHECK(strnlen(out,33)<=32 && [[NSString alloc] initWithBytes:out length:strnlen(out,33) encoding:NSUTF8StringEncoding]!=nil,"every returned prefix is valid UTF-8 within 32 bytes");
    CHECK(providerReads==before && keychainReads==kc,"GetNickname never reads a credential/provider or initiates preflight");
}
static _Atomic bool ready,done;
static _Atomic unsigned badSnapshots;
static void *reader(void *unused){(void)unused;@autoreleasepool{
    fixture_gate_prepare();atomic_store(&ready,true);unsigned count=0;
    while(!atomic_load(&done) || count<500) {
        char value[33];uint32_t result=nickname(value,uid);
        if(result || (strcmp(value,"Player") && strcmp(value,"first_fixture") && strcmp(value,"second_fixture")))atomic_fetch_add(&badSnapshots,1);
        count++;
    }
    return NULL;
}}
int main(void){@autoreleasepool{
    unsetenv("DM_NICK");unsetenv("DM_ACCOUNT_TRACE");
    nickname=(GetNickname)hook("_ZN2nn7account11GetNicknameEPNS0_8NicknameERKNS0_3UidE");
    typedef uint32_t (*GetUID)(void *);
    CHECK(!((GetUID)hook("_ZN2nn7account17GetLastOpenedUserEPNS0_3UidE"))(uid),"actual HLE issues the local UID");
    memcpy(other,uid,sizeof other);other[0]^=1;
    setProfile(profile(@"linked_fixture"));dm_nextendo_set_credential_provider(provider);
    expect(uid,"Player",0,"cold process keeps its local fallback without warming the cache");
    uint8_t available=0;CHECK(!dm_nextendo_account_available(&available) && available,"synthetic availability is valid");
    expect(uid,"Player",0,"availability alone does not authorize profile publication");
    CHECK(!dm_nextendo_account_authorize_local(),"explicit action validates and warms the existing snapshot");
    expect(uid,"linked_fixture",0,"an already validated cached identity supplies the local nickname");
    const dm_net_mode_t modes[]={DM_NET_OFFLINE,DM_NET_LAN,DM_NET_LDN,DM_NET_AUTO,DM_NET_NEXTENDO};
    for(unsigned i=0;i<sizeof modes/sizeof *modes;i++) {
        mode=modes[i];expect(uid,"linked_fixture",0,"a valid local presentation is independent of online service mode");
        CHECK(mode==modes[i],"reading a nickname cannot change the selected network mode");
    }
    mode=DM_NET_NEXTENDO;
    setenv("DM_NICK","chosen_fixture",1);expect(uid,"chosen_fixture",0,"explicit local nickname wins over the cached identity");
    setenv("DM_NICK","",1);expect(uid,"",0,"an explicit empty override preserves its existing priority");
    setenv("DM_NICK","local_private_fixture",1);expect(other,"",DM_ACCOUNT_FAIL,"foreign UID fails without exposing any local or cached name");unsetenv("DM_NICK");
    char bounded[40];memset(bounded,'A',31);memcpy(bounded+31,"\xc3\xa9",3);
    char expected[32];memset(expected,'A',31);expected[31]=0;
    setenv("DM_NICK",bounded,1);expect(uid,expected,0,"the 32-byte boundary cannot split a two-byte UTF-8 point");unsetenv("DM_NICK");
    char four[40];memset(four,'B',28);memcpy(four+28,"\xf0\x9f\xa6\x91",5);
    setenv("DM_NICK",four,1);expect(uid,four,0,"a complete four-byte point fits at the exact 32-byte limit");
    memset(four,'B',29);memcpy(four+29,"\xf0\x9f\xa6\x91",5);
    char clipped[30];memset(clipped,'B',29);clipped[29]=0;
    setenv("DM_NICK",four,1);expect(uid,clipped,0,"a four-byte point beyond the boundary is excluded intact");
    const char *malformed[]={"\x80","\xc0\xaf","\xed\xa0\x80","\xf4\x90\x80\x80","\xc2"};
    for(unsigned i=0;i<sizeof malformed/sizeof *malformed;i++){setenv("DM_NICK",malformed[i],1);expect(uid,"Player",0,"invalid explicit UTF-8 falls back locally instead of exposing the cached identity");}
    unsetenv("DM_NICK");
    expect(NULL,"",DM_ACCOUNT_FAIL,"a null UID fails without publishing local identity");
    unsigned before=providerReads,kc=keychainReads;
    CHECK(nickname(NULL,(const void *)(uintptr_t)1)==DM_ACCOUNT_FAIL && providerReads==before && keychainReads==kc,"a missing output is rejected before reading even an invalid UID");
    setProfile(profile(@"perfil_\u00e1\U0001f991"));CHECK(!dm_nextendo_account_authorize_local(),"a synthetic Unicode identity is independently validated");
    expect(uid,"perfil_\xc3\xa1\xf0\x9f\xa6\x91",0,"validated Unicode profile bytes remain intact");
    social_lock();socialCredential.expiry=NSDate.date.timeIntervalSince1970-1;pthread_mutex_unlock(&socialCredentialLock);
    expect(uid,"Player",0,"expired cached identity cannot publish its name or trigger a refresh");
    setProfile(profile(@"second_fixture"));CHECK(!dm_nextendo_account_authorize_local(),"fresh explicit validation can seed a later profile");
    dm_nextendo_account_invalidate_social();expect(uid,"Player",0,"revocation prevents a retained identity from leaking into the nickname");
    CHECK(!dm_nextendo_account_authorize_local(),"explicit reauthorization restores a valid snapshot");
    dm_nextendo_set_credential_provider(provider);expect(uid,"Player",0,"provider replacement retires the previous name without a new read");
    setProfile([@"{\"schema_version\":1,\"token_kind\":\"oauth\"}" dataUsingEncoding:NSUTF8StringEncoding]);
    CHECK(dm_nextendo_account_authorize_local()!=0,"OAuth alone cannot seed the native identity snapshot");
    expect(uid,"Player",0,"a rejected account proof leaves no nickname authority");
    setProfile(profile(@"first_fixture"));CHECK(!dm_nextendo_account_authorize_local(),"the concurrency fixture starts with a valid cached identity");
    pthread_t worker;int created=pthread_create(&worker,NULL,reader,NULL);CHECK(!created,"a real HLE reader starts");
    if(!created) {
        while(!atomic_load(&ready))sched_yield();before=providerReads;kc=keychainReads;
        for(unsigned i=0;i<100;i++) {
            setProfile(profile(i&1 ? @"first_fixture" : @"second_fixture"));CHECK(!dm_nextendo_account_authorize_local(),"only explicit fixture authorizations may read the provider");
            if(i%3==0)dm_nextendo_account_invalidate_social();
        }
        atomic_store(&done,true);CHECK(!pthread_join(worker,NULL),"the reader finishes after authorization/revocation races");
        CHECK(!atomic_load(&badSnapshots),"concurrent copies contain only complete authorized snapshots or the local fallback");
        CHECK(providerReads==before+100 && keychainReads==kc,"concurrent nickname reads add no provider, Keychain or transport work");
    }
    CHECK(!keychainReads,"all profiles remain fixture-only, with zero real Security queries");
    printf("Cached account nickname: %u checks, %u failures; synthetic profiles and real HLE hooks, zero real Keychain/network\n",checks,failures);
    return failures!=0;
}}
