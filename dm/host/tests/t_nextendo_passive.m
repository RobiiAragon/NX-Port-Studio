// Real account decoder/snapshot, API boundary and social publisher with an
// invalid-HMAC synthetic proof. No real Keychain access or HTTP request occurs.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#include <pthread.h>
#include <stdatomic.h>
#include "../net_socket.h"
static unsigned checks,failures,keychainReads,providerReads,httpRequests;
static _Atomic unsigned waitsBegun,waitsEnded;
static dm_net_mode_t mode=DM_NET_AUTO;
static NSData *fixture;
static pthread_mutex_t fixtureLock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t fixtureCondition=PTHREAD_COND_INITIALIZER;
static bool holdProvider,providerEntered,releaseProvider;
static bool invalidateDuringRequest,failRequest;
static unsigned httpStatus=200;
static OSStatus fixtureCopy(CFDictionaryRef query,CFTypeRef *out) {
    (void)query; keychainReads++; if(out)*out=NULL; return errSecInteractionNotAllowed;
}
#define SecItemCopyMatching fixtureCopy
#include "../hle_nextendo_apple.m"
#undef SecItemCopyMatching
#include "../nextendo_social.h"
#define CHECK(x) do { checks++; if(!(x)){failures++;fprintf(stderr,"Passive social check failed at %d\n",__LINE__);} } while(0)
dm_net_mode_t dm_net_mode(void){return mode;}
void dm_guest_host_wait_begin(void){atomic_fetch_add(&waitsBegun,1);}
void dm_guest_host_wait_end(void){atomic_fetch_add(&waitsEnded,1);}
int hle_signal_system_event_binding(uint64_t binding){(void)binding;abort();}
int dm_nextendo_preflight_query(dm_nextendo_preflight_reply *reply,unsigned timeout){(void)reply;(void)timeout;abort();}
dm_nextendo_preflight_status dm_nextendo_preflight_last_status(void){abort();}
static NSData *record(NSString *name) {
    uint64_t now=(uint64_t)NSDate.date.timeIntervalSince1970,expiry=now+3600;
    uint8_t invalidHmac[32]={0};
    NSString *claims=[NSString stringWithFormat:@"1800000042.%@.%llu",name,expiry];
    NSString *proof=[NSString stringWithFormat:@"nx2.%@.%@",base64url([claims dataUsingEncoding:NSUTF8StringEncoding]),base64url([NSData dataWithBytes:invalidHmac length:sizeof invalidHmac])];
    return [NSJSONSerialization dataWithJSONObject:@{@"schema_version":@1,@"token_kind":@"nex",@"token":proof,
        @"identity":@{@"pid":@1800000042ull,@"username":name},@"scopes":@[],@"created_at":@(now-60),@"expires_at":@(expiry),
        @"renewal":@{@"client_id":@"synthetic-client",@"access_token":@"synthetic-own-oauth-access",@"refresh_token":@"synthetic-refresh-unused",
            @"expires_at":@(now+1800),@"scopes":@[@"identity",@"friends",@"presence"]}} options:0 error:nil];
}
static bool provider(uint8_t *buffer,size_t capacity,size_t *size) {
    pthread_mutex_lock(&fixtureLock); providerReads++; NSData *data=fixture;
    providerEntered=true;pthread_cond_broadcast(&fixtureCondition);
    while(holdProvider&&!releaseProvider)pthread_cond_wait(&fixtureCondition,&fixtureLock);
    bool valid=data&&data.length<=capacity;
    if(valid){memcpy(buffer,data.bytes,data.length);*size=data.length;}
    pthread_mutex_unlock(&fixtureLock);return valid;
}
static bool otherProvider(uint8_t *buffer,size_t capacity,size_t *size){return provider(buffer,capacity,size);}
static void setRecord(NSData *data){pthread_mutex_lock(&fixtureLock);fixture=data;pthread_mutex_unlock(&fixtureLock);}
static bool transport(const char *url,const char *method,const char *authorization,const uint8_t *body,size_t bodySize,
    uint8_t *output,size_t capacity,size_t *size,unsigned *status) {
    httpRequests++;
    bool presence=!strcmp(url,"https://nextendo.network/api/presence");
    CHECK(presence||!strcmp(url,"https://nextendo.network/api/friends")||!strcmp(url,"https://nextendo.network/api/me"));
    CHECK(authorization&&!strcmp(authorization,"Bearer synthetic-own-oauth-access"));
    CHECK(presence?(!strcmp(method,"POST")&&body&&bodySize):(!strcmp(method,"GET")&&!bodySize));
    if(invalidateDuringRequest)dm_nextendo_account_invalidate_social();
    const char *response=presence?"{}":strstr(url,"/friends")?"{\"friends\":[{\"pid\":501,\"name\":\"SyntheticFriend\"}]}":"{\"nsa\":\"abcdef0000001234\"}";
    size_t length=strlen(response);CHECK(capacity>=length);if(capacity<length)return false;
    memcpy(output,response,length);*size=length;*status=httpStatus;return !failRequest;
}
static NSString *passive(uint64_t *generation){return dm_nextendo_api_passive_bearer(generation);}
static void expectNoReads(unsigned providers,unsigned keychain){CHECK(providerReads==providers&&keychainReads==keychain);}
static NSData *withGrant(NSData *data,id grant) {
    NSMutableDictionary *object=[[NSJSONSerialization JSONObjectWithData:data options:0 error:nil] mutableCopy];
    if(grant)object[@"renewal"]=grant;else[object removeObjectForKey:@"renewal"];
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
}
static void grantGuards(void) {
    NSData *valid=record(@"synthetic_scope_guards");
    NSDictionary *object=[NSJSONSerialization JSONObjectWithData:valid options:0 error:nil],*grant=object[@"renewal"];
    NSArray *invalid=@[NSNull.null,@{},@{@"scopes":@[]},@{@"scopes":@[@"identity",@"friends"]},
        @{@"scopes":@"presence"},@{@"scopes":@[@"presence.write"]},@{@"scopes":@[@"presence",@"presence"]},
        @{@"expires_at":@1},@{@"expires_at":@YES},@{@"access_token":object[@"token"]},@{@"access_token":@"bad access"},
        @{@"access_token":@YES},@{@"refresh_token":@""},@{@"client_id":@"nextendo-emulator"}];
    for(id changes in invalid) {
        id next=changes;
        if([changes isKindOfClass:NSDictionary.class]&&[changes count]) {NSMutableDictionary *copy=grant.mutableCopy;[copy addEntriesFromDictionary:changes];next=copy;}
        setRecord(withGrant(valid,next));CHECK(!dm_nextendo_account_authorize_local());
        uint64_t generation=99;unsigned reads=providerReads,kc=keychainReads,http=httpRequests;
        CHECK(!passive(&generation)&&!generation);
        CHECK(dm_nextendo_social_publish(1,NULL,0)!=0&&httpRequests==http);expectNoReads(reads,kc);
        uint8_t available=0;CHECK(!dm_nextendo_account_available(&available)&&available);
        uint64_t pid=0;CHECK(!dm_nextendo_account_id(&pid)&&pid==1800000042ull);
    }
    setRecord(withGrant(valid,nil));CHECK(!dm_nextendo_account_authorize_local());
    uint64_t generation=99;CHECK(!passive(&generation)&&!generation);
    setRecord(valid);CHECK(!dm_nextendo_account_authorize_local());CHECK(passive(&generation)!=nil);
}
static void resourcePermissions(void) {
    NSData *valid=record(@"synthetic_resource_guards");
    NSDictionary *object=[NSJSONSerialization JSONObjectWithData:valid options:0 error:nil],*grant=object[@"renewal"];
    const struct {const char *resource;const char *scope;} cases[]={{"me","identity"},{"friends","friends"},{"presence","presence"}};
    for(unsigned i=0;i<3;i++) {
        NSMutableDictionary *only=grant.mutableCopy;only[@"scopes"]=@[[NSString stringWithUTF8String:cases[i].scope]];
        setRecord(withGrant(valid,only));
        for(unsigned j=0;j<3;j++) {
            CHECK((dm_nextendo_api_bearer(cases[j].resource)!=nil)==(i==j));
            CHECK((dm_nextendo_api_identity(cases[j].resource)!=nil)==(i==j));
            uint8_t bytes[256];size_t count=99;unsigned http=httpRequests;
            uint32_t result=dm_nextendo_api_request(cases[j].resource,j==2?(const uint8_t *)"{}":NULL,j==2?2:0,bytes,sizeof bytes,&count);
            CHECK((result==0)==(i==j)&&httpRequests==http+(i==j));
        }
    }
    unsigned reads=providerReads,kc=keychainReads;
    CHECK(!dm_nextendo_api_bearer(NULL)&&!dm_nextendo_api_bearer("../friends")&&!dm_nextendo_api_identity("https://untrusted.invalid"));
    expectNoReads(reads,kc);
    setRecord(valid);CHECK(!dm_nextendo_account_authorize_local());
    uint64_t generation=0;NSString *proof=passive(&generation);CHECK(proof&&generation);
    uint8_t bytes[256];size_t count=99;unsigned http=httpRequests;reads=providerReads;
    CHECK(dm_nextendo_api_request_passive("friends",NULL,0,bytes,sizeof bytes,&count,proof,generation)!=0&&!count&&httpRequests==http);
    CHECK(dm_nextendo_api_request_passive("me",NULL,0,bytes,sizeof bytes,&count,proof,generation)!=0&&!count&&httpRequests==http);
    expectNoReads(reads,kc);
    NSData *identity=dm_nextendo_api_identity("friends");CHECK(identity.length==32);
    NSMutableDictionary *rotated=grant.mutableCopy;rotated[@"access_token"]=@"synthetic-own-oauth-rotated";
    setRecord(withGrant(valid,rotated));CHECK(![identity isEqual:dm_nextendo_api_identity("friends")]);
    setRecord(valid);
    dm_social_friend *friends=NULL;size_t number=0;http=httpRequests;
    CHECK(!dm_nextendo_social_friends(&friends,&number)&&number==1&&httpRequests==http+1);free(friends);
    http=httpRequests;CHECK(!dm_nextendo_social_friends(&friends,&number)&&number==1&&httpRequests==http);free(friends);
    NSMutableDictionary *expired=grant.mutableCopy;expired[@"expires_at"]=@1;setRecord(withGrant(valid,expired));
    CHECK(dm_nextendo_social_friends(&friends,&number)!=0&&!friends&&!number&&httpRequests==http);
    NSMutableDictionary *noFriends=grant.mutableCopy;noFriends[@"scopes"]=@[@"identity"];setRecord(withGrant(valid,noFriends));
    CHECK(dm_nextendo_social_friends(&friends,&number)!=0&&!friends&&!number&&httpRequests==http);
    setRecord(valid);CHECK(!dm_nextendo_account_authorize_local());proof=passive(&generation);CHECK(proof!=nil);
    social_lock();socialCredential.oauthExpiry=NSDate.date.timeIntervalSince1970-1;pthread_mutex_unlock(&socialCredentialLock);
    reads=providerReads;CHECK(!dm_nextendo_api_passive_valid(proof,generation)&&!passive(&generation));
    CHECK(dm_nextendo_social_publish(1,NULL,0)!=0&&httpRequests==http);expectNoReads(reads,kc);
    // The API expiry does not discard the still-valid NEX/nickname snapshot.
    social_lock();CHECK(socialCredential.token!=nil&&socialCredential.expiry>NSDate.date.timeIntervalSince1970);pthread_mutex_unlock(&socialCredentialLock);
    setRecord(valid);CHECK(!dm_nextendo_account_authorize_local());
    uint64_t size=0;char gameToken[16384];dm_nextendo_set_game_version("11.3.0");
    CHECK(!dm_nextendo_account_load_token(&size,gameToken,sizeof gameToken)&&size>0);
    NSString *jwt=[[NSString alloc]initWithBytes:gameToken length:(NSUInteger)size encoding:NSUTF8StringEncoding];
    NSArray *parts=[jwt componentsSeparatedByString:@"."];CHECK(parts.count==3);
    NSDictionary *claims=parts.count==3?[NSJSONSerialization JSONObjectWithData:decode_base64url(parts[1]) options:0 error:nil]:nil;
    CHECK([claims[@"nnex"]isEqual:object[@"token"]]&&claims[@"renewal"]==nil&&claims[@"access_token"]==nil);
}
static void coldAndRetry(void) {
    uint64_t generation=99;unsigned reads=providerReads,kc=keychainReads,http=httpRequests;
    CHECK(!dm_nextendo_api_passive_bearer(NULL));
    CHECK(!dm_nextendo_api_passive_valid(nil,1)&&!dm_nextendo_api_passive_valid(@"synthetic-unknown",0));
    CHECK(!passive(&generation)&&!generation);
    dm_nextendo_set_credential_provider(NULL);
    CHECK(dm_nextendo_social_publish(1,NULL,0)!=0);expectNoReads(reads,kc);
    dm_nextendo_set_credential_provider(provider);
    CHECK(dm_nextendo_social_publish(1,NULL,0)!=0&&httpRequests==http);expectNoReads(reads,kc);
    // Metadata-only availability does not authorize passive social publication.
    uint8_t available=0;CHECK(!dm_nextendo_account_available(&available)&&available);reads=providerReads;
    CHECK(!passive(&generation)&&dm_nextendo_social_publish(1,NULL,0)!=0&&httpRequests==http);expectNoReads(reads,kc);
    CHECK(!dm_nextendo_account_authorize_local());reads=providerReads;
    NSString *proof=passive(&generation);CHECK(proof&&generation&&dm_nextendo_api_passive_valid(proof,generation));
    CHECK(!dm_nextendo_api_passive_valid(@"synthetic-unknown",generation)&&!dm_nextendo_api_passive_valid(proof,generation+1));
    CHECK(!dm_nextendo_social_publish(1,NULL,0)&&httpRequests==http+1);expectNoReads(reads,kc);
    // Old snapshots cannot survive provider replacement or host sign-out.
    dm_nextendo_set_credential_provider(otherProvider);
    CHECK(!dm_nextendo_api_passive_valid(proof,generation)&&!passive(&generation));expectNoReads(reads,kc);
    CHECK(dm_nextendo_social_publish(1,NULL,0)!=0&&httpRequests==http+1);
    CHECK(!dm_nextendo_account_ensure());reads=providerReads;CHECK(!dm_nextendo_social_publish(1,NULL,0));expectNoReads(reads,kc);
    dm_nextendo_account_invalidate_social();CHECK(!passive(&generation)&&dm_nextendo_social_publish(1,NULL,0)!=0);expectNoReads(reads,kc);
    // A new explicit authorization permits retry in this same running process.
    CHECK(!dm_nextendo_account_authorize_local());CHECK(!dm_nextendo_social_publish(2,NULL,0));
}
static void expiryAndFailures(void) {
    unsigned kc=keychainReads;uint64_t generation=0;NSString *proof=passive(&generation);CHECK(proof&&generation);
    // Change only the synthetic retained instance: exercise the actual expiry
    // predicate without changing a system clock or sleeping until expiry.
    social_lock();socialCredential.expiry=NSDate.date.timeIntervalSince1970-1;pthread_mutex_unlock(&socialCredentialLock);
    unsigned reads=providerReads,http=httpRequests;
    CHECK(!dm_nextendo_api_passive_valid(proof,generation));CHECK(!passive(&generation)&&!generation);
    CHECK(dm_nextendo_social_publish(1,NULL,0)!=0&&httpRequests==http);expectNoReads(reads,kc);
    CHECK(!dm_nextendo_account_authorize_local());proof=passive(&generation);CHECK(proof&&generation);
    setRecord(nil);CHECK(dm_nextendo_account_ensure()!=0);reads=providerReads;
    CHECK(!dm_nextendo_api_passive_valid(proof,generation)&&!passive(&generation));expectNoReads(reads,kc);
    // Invalid/OAuth metadata never seeds the snapshot through explicit access.
    setRecord([@"{\"schema_version\":1,\"token_kind\":\"oauth\"}" dataUsingEncoding:NSUTF8StringEncoding]);
    CHECK(dm_nextendo_account_authorize_local()!=0&&!passive(&generation));
    setRecord(record(@"synthetic_retry"));CHECK(!dm_nextendo_account_authorize_local());reads=providerReads;
    failRequest=true;CHECK(dm_nextendo_social_publish(1,NULL,0)!=0);failRequest=false;
    httpStatus=403;CHECK(dm_nextendo_social_publish(1,NULL,0)!=0);httpStatus=200;
    invalidateDuringRequest=true;CHECK(dm_nextendo_social_publish(1,NULL,0)!=0);invalidateDuringRequest=false;
    CHECK(!passive(&generation));expectNoReads(reads,kc);
    CHECK(!dm_nextendo_account_authorize_local());CHECK(!dm_nextendo_social_publish(1,NULL,0));
    mode=DM_NET_OFFLINE;reads=providerReads;http=httpRequests;
    CHECK(!passive(&generation)&&dm_nextendo_social_publish(1,NULL,0)!=0&&httpRequests==http);expectNoReads(reads,kc);
    // Explicit local authorization remains valid offline, without enabling any
    // in-game network service. It only warms the in-memory snapshot.
    CHECK(!dm_nextendo_account_authorize_local());CHECK(!passive(&generation)&&mode==DM_NET_OFFLINE);
    mode=DM_NET_AUTO;CHECK(!dm_nextendo_social_publish(1,NULL,0));
}
static void *authorizeWorker(void *result){*(uint32_t*)result=dm_nextendo_account_authorize_local();return NULL;}
static void staleCompletion(void) {
    uint64_t generation=0;CHECK(passive(&generation)!=nil);
    pthread_mutex_lock(&fixtureLock);holdProvider=true;releaseProvider=false;providerEntered=false;pthread_mutex_unlock(&fixtureLock);
    pthread_t worker;uint32_t result=0xface;
    int created=pthread_create(&worker,NULL,authorizeWorker,&result);CHECK(!created);if(created)return;
    pthread_mutex_lock(&fixtureLock);while(!providerEntered)pthread_cond_wait(&fixtureCondition,&fixtureLock);pthread_mutex_unlock(&fixtureLock);
    // Revocation wins over a still-running successful explicit read.
    dm_nextendo_account_invalidate_social();CHECK(!passive(&generation));
    pthread_mutex_lock(&fixtureLock);releaseProvider=true;pthread_cond_broadcast(&fixtureCondition);pthread_mutex_unlock(&fixtureLock);
    CHECK(!pthread_join(worker,NULL)&&!result);CHECK(!passive(&generation));
    pthread_mutex_lock(&fixtureLock);holdProvider=false;pthread_mutex_unlock(&fixtureLock);
    CHECK(!dm_nextendo_account_authorize_local());CHECK(!dm_nextendo_social_publish(1,NULL,0));
}
int main(void){@autoreleasepool{
    setenv("DM_NEXTENDO_ROUTES","synthetic-passive-social-profile",1);
    setRecord(record(@"synthetic_initial"));dm_nextendo_set_credential_provider(provider);dm_nextendo_api_test_transport(transport);
    coldAndRetry();expiryAndFailures();staleCompletion();grantGuards();resourcePermissions();
    CHECK(!keychainReads&&atomic_load(&waitsBegun)==atomic_load(&waitsEnded));
    printf("Nextendo passive social: %u checks, %u failures; synthetic credentials/HTTP only, zero real Keychain calls\n",checks,failures);
    return failures?1:0;
}}
