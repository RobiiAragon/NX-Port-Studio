// Actual same-executable probe plus the production network gate. Only an
// unauthenticatable synthetic provider record is used; no Keychain item or
// server is read. The child must not inherit the parent's routes/diagnostics.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>
#include "../net_socket.h"
#include "../nextendo_preflight_mac.h"
#include "../hle_nextendo_apple.m"
static _Atomic unsigned providerCalls;
static unsigned checks;
static int inheritedPrivateEnvironment;
__attribute__((constructor)) static void inspectEarlyEnvironment(void) {
    const char *keys[]={"DM_NEXTENDO_ROUTES","DM_NEXTENDO_BCAT_DIR","DM_ACCOUNT_TRACE","DM_NVN_TSV","DYLD_INSERT_LIBRARIES","NX_FIXTURE_PRIVATE"};
    for (unsigned i=0;i<sizeof keys/sizeof *keys;i++) if (getenv(keys[i])) inheritedPrivateEnvironment=1;
}
void dm_guest_host_wait_begin(void) {}
void dm_guest_host_wait_end(void) {}
int hle_signal_system_event_binding(uint64_t binding) { (void)binding; abort(); }
bool dm_nextendo_api_baas_namespace(const char *kind) { (void)kind; abort(); }
uint32_t dm_nextendo_api_baas_id(uint64_t *out) { (void)out; abort(); }
static bool fixtureProvider(uint8_t *buffer,size_t capacity,size_t *size) {
    atomic_fetch_add(&providerCalls,1);
    uint64_t now=(uint64_t)NSDate.date.timeIntervalSince1970,expiry=now+3600;
    NSString *claims=[NSString stringWithFormat:@"1800000042.fixture.%llu",expiry];
    uint8_t invalidHMAC[32]={0};
    NSString *proof=[NSString stringWithFormat:@"nx2.%@.%@",base64url([claims dataUsingEncoding:NSUTF8StringEncoding]),base64url([NSData dataWithBytes:invalidHMAC length:32])];
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"schema_version":@1,@"token_kind":@"nex",@"token":proof,@"identity":@{@"pid":@1800000042ull,@"username":@"fixture"},@"scopes":@[],@"created_at":@(now-30),@"expires_at":@(expiry)} options:0 error:nil];
    if (!data || data.length>capacity) return false;
    memcpy(buffer,data.bytes,data.length);*size=data.length;return true;
}
#define CHECK(c,message) do { checks++;if (!(c)) { fprintf(stderr,"Preflight capability failure: %s\n",message);return 1;} } while(0)
int main(int argc,char **argv) { @autoreleasepool {
    if (argc==2 && !strcmp(argv[1],DM_NEXTENDO_PREFLIGHT_ARG)) {
        if (inheritedPrivateEnvironment) return 70;
        dm_nextendo_set_credential_provider(fixtureProvider);
        return dm_nextendo_account_preflight_child(DM_NEXTENDO_PREFLIGHT_FD);
    }
    unsetenv("DM_NEXTENDO_ROUTES");setenv("DM_NETWORK","auto",1);
    dm_nextendo_set_credential_provider(fixtureProvider);uint8_t available=9;
    CHECK(!dm_nextendo_account_available(&available) && !available && !atomic_load(&providerCalls),"unconfigured AUTO never queries its provider or launches a probe");
    setenv("DM_NEXTENDO_ROUTES","parent-only-profile",1);
    setenv("DM_NEXTENDO_BCAT_DIR","parent-only-calendar",1);
    setenv("DM_ACCOUNT_TRACE","1",1);setenv("DM_NVN_TSV","parent-only-diagnostic",1);
    setenv("NX_FIXTURE_PRIVATE","parent-only-value",1);
    setenv("DYLD_INSERT_LIBRARIES","/nonexistent-parent-only-fixture.dylib",1);
    dm_nextendo_set_credential_provider(NULL);available=9;
    CHECK(!dm_nextendo_account_available(&available) && available,"configured parent receives a usable result from its route-free bounded child");
    dm_nextendo_preflight_status status=dm_nextendo_preflight_last_status();
    CHECK(status.stage==DM_PREFLIGHT_DONE && status.bytes==sizeof(dm_nextendo_preflight_reply) && !status.exit_code && !status.signal,"actual child returns the complete validated protocol and exits cleanly");
    CHECK(dm_net_mode()==DM_NET_AUTO && !strcmp(getenv("DM_NEXTENDO_ROUTES"),"parent-only-profile"),"the child capability never changes the parent's mode/profile");
    CHECK(!atomic_load(&providerCalls),"parent never reads a credential in the passive probe path");
    unsetenv("DM_NEXTENDO_ROUTES");available=9;
    CHECK(!dm_nextendo_account_available(&available) && !available,"cached availability cannot bypass an absent parent AUTO profile");
    setenv("DM_NETWORK","offline",1);setenv("DM_NEXTENDO_ROUTES","parent-only-profile",1);available=9;
    CHECK(!dm_nextendo_account_available(&available) && !available,"offline remains unavailable even with a profile");
    printf("Bounded account capability: %u checks PASS; synthetic proof only, no Keychain item or network access\n",checks);return 0;
} }
