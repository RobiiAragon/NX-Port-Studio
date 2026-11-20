// Numeric credential rejection and same-executable wire fixtures. All Security
// queries/policy calls are fake; synthetic proofs have an invalid zero HMAC.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include "t_trace_capture.h"
#include "../net_socket.h"
static _Atomic unsigned reads;
static unsigned checks,failures,policySets;
static OSStatus readStatus=errSecSuccess;
static id readObject;
static Boolean policyAllowed=true;
static _Thread_local int threadStatus;
static OSStatus fakeCopy(CFDictionaryRef query,CFTypeRef *out) {
    (void)query;atomic_fetch_add(&reads,1);errno=E2BIG;
    *out=threadStatus ? NULL : readObject ? CFBridgingRetain(readObject) : NULL;
    return threadStatus ? threadStatus : readStatus;
}
static OSStatus fakeGet(Boolean *out) { *out=policyAllowed;return errSecSuccess; }
static OSStatus fakeSet(Boolean value) { policyAllowed=value;policySets++;return errSecSuccess; }
#define SecItemCopyMatching fakeCopy
#define SecKeychainGetUserInteractionAllowed fakeGet
#define SecKeychainSetUserInteractionAllowed fakeSet
#include "../hle_nextendo_apple.m"
#undef SecItemCopyMatching
#undef SecKeychainGetUserInteractionAllowed
#undef SecKeychainSetUserInteractionAllowed
dm_net_mode_t dm_net_mode(void) { return DM_NET_NEXTENDO; }
void dm_guest_host_wait_begin(void) {}
void dm_guest_host_wait_end(void) {}
int hle_signal_system_event_binding(uint64_t binding) { (void)binding;abort(); }
bool dm_nextendo_api_baas_namespace(const char *kind) { (void)kind;abort(); }
uint32_t dm_nextendo_api_baas_id(uint64_t *out) { (void)out;abort(); }
#define CHECK(c,label) do { checks++;if(!(c)){failures++;fprintf(stderr,"FAIL line %d: %s\n",__LINE__,label);} } while(0)
static NSData *json(id object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil]; }
static NSMutableDictionary *record(void) {
    uint64_t now=(uint64_t)NSDate.date.timeIntervalSince1970,expiry=now+600;
    NSString *claims=[NSString stringWithFormat:@"1800000042.DIAG_SECRET_SENTINEL.%llu",expiry];uint8_t zero[32]={0};
    NSString *proof=[NSString stringWithFormat:@"nx2.%@.%@",base64url([claims dataUsingEncoding:NSUTF8StringEncoding]),base64url([NSData dataWithBytes:zero length:32])];
    return [@{@"schema_version":@1,@"token_kind":@"nex",@"token":proof,@"identity":@{@"pid":@1800000042ull,@"username":@"DIAG_SECRET_SENTINEL"},@"scopes":@[],@"created_at":@(now-30),@"expires_at":@(expiry)} mutableCopy];
}
static NSString *configuration;
static unsigned providerMode,providerReads;
static bool fakeProvider(uint8_t *buffer,size_t capacity,size_t *size) {
    (void)buffer;providerReads++;
    if(!providerMode)return false;
    *size=providerMode==1 ? 0 : capacity+1;return true;
}
static void option(NSString *packet) {
    NSData *data=json(packet ? @{@"packet":packet} : @{});
    if(![data writeToFile:configuration atomically:YES] || chmod(configuration.fileSystemRepresentation,0600))abort();
}
static int child(BOOL diagnostic) {
    if(!configuration)return 69;
    NSData *data=[NSData dataWithContentsOfFile:configuration];if(!data)return 69;
    id decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if(![decoded isKindOfClass:NSDictionary.class])return 69;
    NSDictionary *options=decoded;
    NSString *packet=options[@"packet"];
    if(packet.length) {
        dm_nextendo_preflight_reply header={.magic=DM_NEXTENDO_PREFLIGHT_MAGIC,.version=1,.pid=(uint32_t)getpid()};
        dm_nextendo_preflight_diagnostic detail={.magic=DM_NEXTENDO_PREFLIGHT_DIAGNOSTIC_MAGIC,.version=2,.credential={DM_CRED_SECURITY_STATUS,errSecItemNotFound}};
        if([packet isEqual:@"header-magic"])header.magic++;
        if([packet isEqual:@"header-version"])header.version++;
        if([packet isEqual:@"reserved"])header.reserved=1;
        if([packet isEqual:@"magic"])detail.magic++;
        if([packet isEqual:@"version"])detail.version++;
        if([packet isEqual:@"unknown"])detail.credential.reason=DM_CRED_UNOBSERVED;
        if([packet isEqual:@"reason"])detail.credential.reason=DM_CRED_REASON_COUNT;
        if([packet isEqual:@"success"])detail.credential.reason=DM_CRED_OK;
        if([packet isEqual:@"status"])detail.credential.security_status=0;
        if([packet isEqual:@"read-status"])detail.credential.reason=DM_CRED_OAUTH;
        uint8_t bytes[sizeof header+sizeof detail+1];memcpy(bytes,&header,sizeof header);memcpy(bytes+sizeof header,&detail,sizeof detail);bytes[sizeof bytes-1]=0x7f;
        size_t size=diagnostic ? sizeof bytes-1 : sizeof header;
        if([packet isEqual:@"short"])size--;
        if([packet isEqual:@"extra"])size++;
        if([packet isEqual:@"sidecar-default"])size=sizeof bytes-1;
        return write(DM_NEXTENDO_PREFLIGHT_FD,bytes,size)==(ssize_t)size ? 0 : 70;
    }
    readStatus=errSecInteractionNotAllowed;readObject=nil;
    int result=diagnostic ? dm_nextendo_account_preflight_diagnostic_child(DM_NEXTENDO_PREFLIGHT_FD) : dm_nextendo_account_preflight_child(DM_NEXTENDO_PREFLIGHT_FD);
    return atomic_load(&reads)==1 && policySets==2 && policyAllowed ? result : 71;
}
typedef struct { int status,reason; } Thread;
static void *worker(void *raw) { @autoreleasepool {
    Thread *t=raw;threadStatus=t->status;uint32_t result=dm_nextendo_account_ensure();
    t->reason=result==DM_ACCOUNT_FAIL && credentialDiagnostic.security_status==t->status ? (int)credentialDiagnostic.reason : -1;return NULL;
} }
int main(int argc,char **argv) { @autoreleasepool {
    char executable[PATH_MAX];if(!realpath(argv[0],executable))return 72;
    configuration=[[NSString stringWithUTF8String:executable] stringByAppendingString:@".credential-fixture.json"];
    if(argc==2) {
        if(getenv("DM_ACCOUNT_TRACE"))return 73; // parent flag never enters the child
        if(!strcmp(argv[1],DM_NEXTENDO_PREFLIGHT_ARG))return child(NO);
        if(!strcmp(argv[1],DM_NEXTENDO_PREFLIGHT_DIAGNOSTIC_ARG))return child(YES);
        return 74;
    }
    unsetenv("DM_ACCOUNT_TRACE");
    NSMutableDictionary *valid=record();
    struct { OSStatus status;__unsafe_unretained id object;unsigned reason; } cases[]={
        {errSecInteractionNotAllowed,nil,DM_CRED_SECURITY_STATUS},{errSecItemNotFound,nil,DM_CRED_SECURITY_STATUS},
        {0,nil,DM_CRED_SECURITY_RESULT},{0,@"wrong-result-type",DM_CRED_SECURITY_DATA},
        {0,[NSData data],DM_CRED_EMPTY},{0,[@"broken json" dataUsingEncoding:NSUTF8StringEncoding],DM_CRED_JSON},
        {0,json(valid),DM_CRED_OK}
    };
    for(unsigned i=0;i<sizeof cases/sizeof *cases;i++) {
        readStatus=cases[i].status;readObject=cases[i].object;unsigned before=atomic_load(&reads);
        TraceCapture capture=trace_capture_begin();uint32_t result=dm_nextendo_account_ensure();char *text=trace_capture_end(capture);
        CHECK(result==(cases[i].reason==DM_CRED_OK ? 0 : DM_ACCOUNT_FAIL) && atomic_load(&reads)==before+1,"the existing read happens exactly once and keeps its result");
        CHECK(credentialDiagnostic.reason==cases[i].reason && credentialDiagnostic.security_status==cases[i].status,"read rejection and Security status are distinct call-local metadata");
        CHECK(!*text,"metadata is silent without exact opt-in");free(text);
    }
    NSArray *mutations=@[@{@"schema_version":@YES},@{@"token_kind":@"oauth"},@{@"token_kind":@"other"},@{@"token":@""},@{@"token":@"bad.format"},@{@"token":@"nx2.!.invalid"},@{@"token":[NSString stringWithFormat:@"nx2.%@.%@",base64url([@"bad" dataUsingEncoding:NSUTF8StringEncoding]),base64url([NSMutableData dataWithLength:32])]},@{@"identity":@{@"pid":@7,@"username":@"wrong"}},@{@"created_at":@"bad"},@{@"expires_at":@((uint64_t)NSDate.date.timeIntervalSince1970-1)},@{@"scopes":@"bad"}];
    unsigned reasons[]={DM_CRED_SCHEMA,DM_CRED_OAUTH,DM_CRED_TOKEN_KIND,DM_CRED_TOKEN_TEXT,DM_CRED_TOKEN_FORMAT,DM_CRED_BASE64,DM_CRED_CLAIMS,DM_CRED_IDENTITY,DM_CRED_TIME,DM_CRED_EXPIRED,DM_CRED_SCOPES};
    setenv("DM_ACCOUNT_TRACE","1",1);TraceCapture capture=trace_capture_begin();readStatus=0;
    for(unsigned i=0;i<mutations.count;i++) {
        NSMutableDictionary *value=[valid mutableCopy];[value addEntriesFromDictionary:mutations[i]];readObject=json(value);unsigned before=atomic_load(&reads);
        CHECK(dm_nextendo_account_ensure()==DM_ACCOUNT_FAIL && atomic_load(&reads)==before+1,"decoder rejection never retries Security or changes the returned failure");
        CHECK(credentialDiagnostic.reason==reasons[i] && !credentialDiagnostic.security_status,"decoder metadata resets the previous read error and identifies the evaluated guard");
    }
    char *text=trace_capture_end(capture);
    CHECK(strstr(text,"credential_reason=17 security_status=0") && strstr(text,"credential_reason=25 security_status=0"),"OAuth and expiry failures are visible as numeric reasons");
    CHECK(!strstr(text,"DIAG_SECRET_SENTINEL") && !strstr(text,"nx2.") && !strstr(text,"1800000042") && !strstr(text,"wrong-result-type"),"no credential bytes, claims, identity or object content enters the trace");free(text);
    readStatus=errSecItemNotFound;readObject=nil;errno=E2BIG;
    CHECK(dm_nextendo_account_ensure()==DM_ACCOUNT_FAIL && errno==E2BIG,"metadata preserves the Security failure's errno and actual Result");
    unsetenv("DM_ACCOUNT_TRACE");Thread a={errSecItemNotFound,0},b={errSecInteractionNotAllowed,0};pthread_t ta,tb;
    int startedA=pthread_create(&ta,NULL,worker,&a),startedB=pthread_create(&tb,NULL,worker,&b);
    CHECK(!startedA && !startedB,"two synthetic credential calls start");if(!startedA)pthread_join(ta,NULL);if(!startedB)pthread_join(tb,NULL);
    CHECK(a.reason==DM_CRED_SECURITY_STATUS && b.reason==DM_CRED_SECURITY_STATUS,"concurrent call-local Security statuses do not overwrite one another");
    dm_nextendo_set_credential_provider(fakeProvider);
    for(providerMode=0;providerMode<3;providerMode++) {
        unsigned before=providerReads,securityBefore=atomic_load(&reads);
        CHECK(dm_nextendo_account_ensure()==DM_ACCOUNT_FAIL && providerReads==before+1 && atomic_load(&reads)==securityBefore,"a provider failure is observed once without falling through to Security");
        CHECK(credentialDiagnostic.reason==(providerMode ? DM_CRED_PROVIDER_SIZE : DM_CRED_PROVIDER_FAILED) && !credentialDiagnostic.security_status,"provider bounds/failure metadata cannot retain a previous Security status");
    }
    dm_nextendo_set_credential_provider(NULL);
    option(nil);dm_nextendo_preflight_reply reply;
    const char *off[]={NULL,"0","true","01",""};
    for(unsigned i=0;i<sizeof off/sizeof *off;i++) {
        if(off[i])setenv("DM_ACCOUNT_TRACE",off[i],1);else unsetenv("DM_ACCOUNT_TRACE");
        CHECK(dm_nextendo_preflight_query(&reply,1000),"normal same-executable child returns its existing protocol");
        dm_nextendo_preflight_status status=dm_nextendo_preflight_last_status();
        CHECK(!reply.available && !reply.reserved && reply.version==1 && status.bytes==32 && status.credential.reason==DM_CRED_UNOBSERVED,"default/off flags carry exactly 32 bytes and no sidecar");
    }
    option(@"sidecar-default");unsetenv("DM_ACCOUNT_TRACE");CHECK(!dm_nextendo_preflight_query(&reply,1000),"trace-off parser rejects an unsolicited sidecar");
    option(nil);setenv("DM_ACCOUNT_TRACE","1",1);
    CHECK(dm_nextendo_preflight_query(&reply,1000),"opt-in child sends the separately versioned diagnostic");
    dm_nextendo_preflight_status status=dm_nextendo_preflight_last_status();
    CHECK(status.bytes==48 && status.stage==DM_PREFLIGHT_DONE && status.credential.reason==DM_CRED_SECURITY_STATUS && status.credential.security_status==errSecInteractionNotAllowed && !reply.available && !reply.reserved && reply.version==1,"a validated 16-byte sidecar distinguishes rejection without changing the v1 header");
    for(NSString *packet in @[@"header-magic",@"header-version",@"reserved",@"magic",@"version",@"unknown",@"reason",@"success",@"status",@"read-status",@"short",@"extra"]) {
        option(packet);memset(&reply,0xff,sizeof reply);CHECK(!dm_nextendo_preflight_query(&reply,1000),"malformed, truncated or oversized diagnostics fail closed");
        dm_nextendo_preflight_reply zero={0};status=dm_nextendo_preflight_last_status();
        CHECK(!memcmp(&reply,&zero,sizeof reply) && !status.credential.reason && !status.credential.security_status,"invalid diagnostics never publish metadata or availability");
    }
    unsetenv("DM_ACCOUNT_TRACE");[[NSFileManager defaultManager] removeItemAtPath:configuration error:nil];
    printf("Credential rejection diagnostics: %u checks, %u failures; fake Security only, no account data or network\n",checks,failures);return failures!=0;
} }
