// Real file-based Keychain fixture, scoped exclusively to a temporary keychain.
// No account, default search-list change, network request or UI grant is used.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <poll.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include "../net_socket.h"
static SecKeychainRef fixtureKeychain;
static BOOL childProcess;
static NSString *fixtureAccount = @"explicit";
static unsigned checks;
static NSMutableDictionary *fixtureOptions;
static NSString *fixtureConfig;
static int inheritedDiagnostics;
__attribute__((constructor)) static void inspectEarlyEnvironment(void) {
    const char *keys[]={"DM_FDSTAT","DM_MEMSTAT","DM_THRCPU","DM_NVN_TSV","DM_LINK_PROBE_LOG","DM_NEXTENDO_ROUTES","DM_NEXTENDO_BCAT_DIR","DYLD_INSERT_LIBRARIES","NX_FIXTURE_STRIP_ME"};
    for (unsigned i=0;i<sizeof keys/sizeof *keys;i++) if (getenv(keys[i])) inheritedDiagnostics=1;
    const char *mode=getenv("DM_NETWORK"); if (mode && strcmp(mode,"nextendo")) inheritedDiagnostics=1;
}
static void option(NSString *key, NSString *value) {
    if (!fixtureConfig || !fixtureOptions || !key) abort();
    if (value) fixtureOptions[key]=value; else [fixtureOptions removeObjectForKey:key];
    NSData *data=[NSJSONSerialization dataWithJSONObject:fixtureOptions options:0 error:nil];
    if (!data || ![data writeToFile:fixtureConfig atomically:YES]) abort();
    chmod(fixtureConfig.fileSystemRepresentation,0600);
}
static OSStatus fixtureCopy(CFDictionaryRef query, CFTypeRef *out) {
    NSMutableDictionary *scoped = [(__bridge NSDictionary *)query mutableCopy];
    scoped[(__bridge id)kSecMatchSearchList] = @[(__bridge id)fixtureKeychain];
    NSString *account = childProcess ? fixtureOptions[@"account"] : fixtureAccount;
    scoped[(__bridge id)kSecAttrAccount] = account;
    NSString *sync = childProcess ? fixtureOptions[@"socket"] : nil;
    if (sync.length) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0); struct sockaddr_un address = {.sun_family=AF_UNIX};
        strlcpy(address.sun_path, sync.fileSystemRepresentation, sizeof address.sun_path);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        Boolean allowed = true; OSStatus status = SecKeychainGetUserInteractionAllowed(&allowed);
#pragma clang diagnostic pop
        char state = !status && !allowed ? 'N' : 'Y', ack = 0;
        if (fd < 0 || connect(fd, (void *)&address, sizeof address) || write(fd, &state, 1) != 1 || read(fd, &ack, 1) != 1 || ack != 'R') { if (fd >= 0) close(fd); return errSecInternalError; }
        close(fd);
    }
    return SecItemCopyMatching((__bridge CFDictionaryRef)scoped, out);
}
#define SecItemCopyMatching fixtureCopy
#include "../hle_nextendo_apple.m"
#undef SecItemCopyMatching
dm_net_mode_t dm_net_mode(void) {
    // The parent supplies a controlled embedding mode. The actual child must
    // honor its serialized capability and the production header's profile gate.
    const char *mode=getenv("DM_NETWORK");
    return childProcess && mode && !strcmp(mode,"nextendo") ? DM_NET_NEXTENDO : DM_NET_AUTO;
}
void dm_guest_host_wait_begin(void) { if (childProcess) abort(); }
void dm_guest_host_wait_end(void) { if (childProcess) abort(); }
int hle_signal_system_event_binding(uint64_t binding) { (void)binding; abort(); }
bool dm_nextendo_api_baas_namespace(const char *kind) { (void)kind; abort(); }
uint32_t dm_nextendo_api_baas_id(uint64_t *out) { (void)out; abort(); }
#define CHECK(c) do { ++checks; if (!(c)) { fprintf(stderr,"Legacy preflight failed %d: %s\n",__LINE__,#c); return 1; } } while (0)
static NSData *fixtureRecord(BOOL expired) {
    uint64_t now = (uint64_t)NSDate.date.timeIntervalSince1970, expiry = expired ? now - 60 : now + 3600;
    NSString *claims = [NSString stringWithFormat:@"1800000042.fixture.%llu", expiry];
    uint8_t invalidHMAC[32] = {0};
    NSString *proof = [NSString stringWithFormat:@"nx2.%@.%@",base64url([claims dataUsingEncoding:NSUTF8StringEncoding]),base64url([NSData dataWithBytes:invalidHMAC length:32])];
    return [NSJSONSerialization dataWithJSONObject:@{@"schema_version":@1,@"token_kind":@"nex",@"token":proof,@"identity":@{@"pid":@1800000042ull,@"username":@"fixture"},@"scopes":@[],@"created_at":@(now-120),@"expires_at":@(expiry)} options:0 error:nil];
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus addFixture(NSString *account, BOOL denied, BOOL expired) {
    NSData *data = fixtureRecord(expired); if (!data || !account || !fixtureKeychain) return errSecAllocate;
    SecAccessRef access = NULL; OSStatus status = SecAccessCreate(CFSTR("NX isolated synthetic fixture"), denied ? (__bridge CFArrayRef)@[] : NULL, &access);
    if (status || !access) return status ? status : errSecAllocate;
    NSDictionary *add = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:@"org.nxnative.nextendo.account",
        (__bridge id)kSecAttrAccount:account,(__bridge id)kSecUseKeychain:(__bridge id)fixtureKeychain,(__bridge id)kSecAttrAccess:(__bridge id)access,(__bridge id)kSecValueData:data};
    status = SecItemAdd((__bridge CFDictionaryRef)add, NULL); CFRelease(access); return status;
}
#pragma clang diagnostic pop
static void *availabilityThread(void *context) { uint8_t *out = context; if (dm_nextendo_account_available(out)) *out = 9; return NULL; }
int main(int argc, char **argv) { @autoreleasepool {
    if (argc == 2 && !strcmp(argv[1], DM_NEXTENDO_PREFLIGHT_ARG)) {
        childProcess = YES;
        if (inheritedDiagnostics) return 70;
        const char *tmp=getenv("TMPDIR"); if (!tmp) return 71;
        NSString *configPath=[@(tmp) stringByAppendingPathComponent:@"fixture.json"]; if (!configPath) return 72;
        NSData *config=[NSData dataWithContentsOfFile:configPath];
        if (!config) return 72;
        fixtureOptions=[[NSJSONSerialization JSONObjectWithData:config options:NSJSONReadingMutableContainers error:nil] mutableCopy];
        if (![fixtureOptions isKindOfClass:NSDictionary.class]) return 73;
        const char *mode = [fixtureOptions[@"packet"] UTF8String];
        if (mode) {
            if (!strcmp(mode,"hang")) { for (;;) pause(); }
            dm_nextendo_preflight_reply bad = {.magic=DM_NEXTENDO_PREFLIGHT_MAGIC,.version=1,.pid=(uint32_t)getpid()};
            if (!strcmp(mode,"pid")) bad.pid++;
            if (!strcmp(mode,"version")) bad.version++;
            if (!strcmp(mode,"reserved")) bad.reserved=1;
            if (!strcmp(mode,"exit")) return 7;
            if (!strcmp(mode,"signal")) { raise(SIGTERM); return 8; }
            size_t size = !strcmp(mode,"short") ? 1 : sizeof bad;
            if (write(DM_NEXTENDO_PREFLIGHT_FD,&bad,size) != (ssize_t)size) return 9;
            if (!strcmp(mode,"extra") && write(DM_NEXTENDO_PREFLIGHT_FD,"x",1) != 1) return 10;
            return 0;
        }
        const char *path = [fixtureOptions[@"keychain"] fileSystemRepresentation]; if (!path) return 11;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (SecKeychainOpen(path,&fixtureKeychain)) return 12;
#pragma clang diagnostic pop
        return dm_nextendo_account_preflight_child(DM_NEXTENDO_PREFLIGHT_FD);
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    Boolean initial = false; CHECK(!SecKeychainGetUserInteractionAllowed(&initial) && initial);
    CFArrayRef searchBefore=NULL,searchAfter=NULL; SecKeychainRef defaultBefore=NULL,defaultAfter=NULL;
    CHECK(!SecKeychainCopySearchList(&searchBefore)); CHECK(!SecKeychainCopyDefault(&defaultBefore));
    char dir[]="/tmp/nx-keychain-test-XXXXXX"; CHECK(mkdtemp(dir)); NSString *path=[@(dir) stringByAppendingPathComponent:@"isolated.keychain"];
    uint8_t password[32]; CHECK(!SecRandomCopyBytes(kSecRandomDefault,sizeof password,password));
    CHECK(!SecKeychainCreate(path.fileSystemRepresentation,sizeof password,password,false,NULL,&fixtureKeychain));
    CHECK(!addFixture(@"active",YES,NO)); CHECK(!addFixture(@"explicit",NO,NO)); CHECK(!addFixture(@"expired",NO,YES));
    fixtureOptions=[@{@"keychain":path} mutableCopy]; fixtureConfig=[@(dir) stringByAppendingPathComponent:@"fixture.json"];
    CHECK(!setenv("TMPDIR",dir,1)); option(@"account",@"active");
    // These are set after this test's constructors ran. The child must never
    // see them, even in its own constructors, and it reads fixture state only
    // from a private test file reached through the allowed TMPDIR.
    for (NSString *key in @[@"DM_FDSTAT",@"DM_MEMSTAT",@"DM_THRCPU",@"DM_NVN_TSV",@"DM_LINK_PROBE_LOG",@"DM_NEXTENDO_ROUTES",@"DM_NEXTENDO_BCAT_DIR",@"NX_FIXTURE_STRIP_ME"]) setenv(key.UTF8String,"parent-only",1);
    setenv("DM_NETWORK","offline",1); // parent enabled() is the fixture's embedding provider
    setenv("DYLD_INSERT_LIBRARIES","/nonexistent-nx-fixture-parent-only.dylib",1);
    // Hold the child exactly while its process-wide policy is false. An
    // explicit, independently authorized read in the parent must still work.
    int server=socket(AF_UNIX,SOCK_STREAM,0); CHECK(server>=0);
    struct sockaddr_un address={.sun_family=AF_UNIX}; snprintf(address.sun_path,sizeof address.sun_path,"%s/sync",dir);
    CHECK(!bind(server,(void *)&address,sizeof address) && !listen(server,1)); option(@"socket",@(address.sun_path));
    uint8_t available=9; pthread_t thread; CHECK(!pthread_create(&thread,NULL,availabilityThread,&available));
    struct pollfd ready={.fd=server,.events=POLLIN}; CHECK(poll(&ready,1,2500)>0);
    int connection=accept(server,NULL,NULL); char state=0; CHECK(connection>=0 && read(connection,&state,1)==1 && state=='N');
    Boolean during=false; CHECK(!SecKeychainGetUserInteractionAllowed(&during) && during==initial);
    CHECK(dm_nextendo_account_ensure()==0); CHECK(!SecKeychainGetUserInteractionAllowed(&during) && during==initial);
    CHECK(write(connection,"R",1)==1); close(connection); CHECK(!pthread_join(thread,NULL) && !available);
    close(server); unlink(address.sun_path); option(@"socket",nil);
    CHECK(!SecKeychainGetUserInteractionAllowed(&during) && during==initial);
    // Attributes exist for the denied item, but cannot prove usable credentials.
    fixtureAccount=@"active"; CFTypeRef attributes=NULL;
    NSDictionary *q=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:@"org.nxnative.nextendo.account",(__bridge id)kSecAttrAccount:@"active",(__bridge id)kSecMatchSearchList:@[(__bridge id)fixtureKeychain],(__bridge id)kSecReturnAttributes:@YES};
    CHECK(!SecItemCopyMatching((__bridge CFDictionaryRef)q,&attributes) && attributes); CFRelease(attributes);
    option(@"account",@"explicit"); dm_nextendo_set_credential_provider(NULL); available=9;
    CHECK(!dm_nextendo_account_available(&available) && available);
    // The cache coalesces adjacent probes but expires even if another process
    // changes credentials without sharing this process's invalidation counter.
    option(@"account",@"expired"); available=9;
    CFAbsoluteTime cachedStart=CFAbsoluteTimeGetCurrent();
    CHECK(!dm_nextendo_account_available(&available) && available && CFAbsoluteTimeGetCurrent()-cachedStart<0.5);
    CHECK(poll(NULL,0,1100)==0); available=9;
    CHECK(!dm_nextendo_account_available(&available) && !available);
    option(@"account",@"expired"); dm_nextendo_set_credential_provider(NULL); available=9;
    CHECK(!dm_nextendo_account_available(&available) && !available);
    option(@"account",@"explicit"); CHECK(!SecKeychainLock(fixtureKeychain)); dm_nextendo_set_credential_provider(NULL); available=9;
    CHECK(!dm_nextendo_account_available(&available) && !available);
    CHECK(!SecKeychainUnlock(fixtureKeychain,sizeof password,password,true)); memset(password,0,sizeof password);
    // The transport rejects every malformed packet and a nonzero/signal exit.
    for (NSString *mode in @[@"pid",@"version",@"reserved",@"short",@"extra",@"exit",@"signal",@"hang"]) {
        option(@"packet",mode); dm_nextendo_preflight_reply reply;
        CFAbsoluteTime started=CFAbsoluteTimeGetCurrent(); CHECK(!dm_nextendo_preflight_query(&reply,120));
        CHECK(CFAbsoluteTimeGetCurrent()-started<2);
    }
    option(@"packet",nil); dm_nextendo_set_credential_provider(NULL); available=9;
    CHECK(!dm_nextendo_account_available(&available) && available);
    // A cached true cannot survive a controlled provider/credential change.
    option(@"account",@"expired"); dm_nextendo_set_credential_provider(NULL); available=9;
    CHECK(!dm_nextendo_account_available(&available) && !available);
    CHECK(!SecKeychainGetUserInteractionAllowed(&during) && during==initial);
    CHECK(!SecKeychainDelete(fixtureKeychain)); CFRelease(fixtureKeychain); unlink(path.fileSystemRepresentation); unlink(fixtureConfig.fileSystemRepresentation); rmdir(dir);
    CHECK(!SecKeychainCopySearchList(&searchAfter) && CFEqual(searchBefore,searchAfter));
    CHECK(!SecKeychainCopyDefault(&defaultAfter) && CFEqual(defaultBefore,defaultAfter));
    CFRelease(searchBefore);CFRelease(searchAfter);CFRelease(defaultBefore);CFRelease(defaultAfter);
#pragma clang diagnostic pop
    printf("Real isolated legacy Keychain preflight: %u checks passed; parent policy/search/default intact\n",checks); return 0;
} }
