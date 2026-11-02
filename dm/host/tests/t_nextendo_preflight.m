// Capture the real runtime query without reading, writing or authorizing any
// Keychain item. The synthetic proof has an invalid HMAC and cannot log in.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#include <objc/runtime.h>
#include "../net_socket.h"
static NSDictionary *capturedQuery;
static NSData *returnedData;
static OSStatus returnedStatus = errSecInteractionNotAllowed;
static unsigned reads, writes, begins, ends, checks;
static dm_net_mode_t mode = DM_NET_AUTO;
static OSStatus fixtureCopy(CFDictionaryRef query, CFTypeRef *out) {
    reads++; capturedQuery = [(__bridge NSDictionary *)query copy];
    *out = returnedStatus == errSecSuccess && returnedData ? CFBridgingRetain(returnedData) : NULL;
    return returnedStatus;
}
static OSStatus fixtureAdd(CFDictionaryRef query, CFTypeRef *out) { (void)query; (void)out; writes++; return errSecParam; }
static OSStatus fixtureUpdate(CFDictionaryRef query, CFDictionaryRef attributes) { (void)query; (void)attributes; writes++; return errSecParam; }
static OSStatus fixtureDelete(CFDictionaryRef query) { (void)query; writes++; return errSecParam; }
#define SecItemCopyMatching fixtureCopy
#define SecItemAdd fixtureAdd
#define SecItemUpdate fixtureUpdate
#define SecItemDelete fixtureDelete
#include "../hle_nextendo_apple.m"
#undef SecItemCopyMatching
#undef SecItemAdd
#undef SecItemUpdate
#undef SecItemDelete

dm_net_mode_t dm_net_mode(void) { return mode; }
void dm_guest_host_wait_begin(void) { begins++; }
void dm_guest_host_wait_end(void) { ends++; }
int hle_signal_system_event_binding(uint64_t binding) { (void)binding; abort(); }
bool dm_nextendo_api_baas_namespace(const char *kind) { (void)kind; abort(); }
uint32_t dm_nextendo_api_baas_id(uint64_t *out) { (void)out; abort(); }
#define CHECK(c) do { checks++; if (!(c)) { fprintf(stderr, "Preflight failed at %d: %s\n", __LINE__, #c); return 1; } } while (0)
static BOOL disallowsInteraction(void) {
    id context = capturedQuery[(__bridge id)kSecUseAuthenticationContext];
    return [context isKindOfClass:LAContext.class] && [(LAContext *)context interactionNotAllowed];
}
static id allocationFailure(id cls, SEL selector) { (void)cls; (void)selector; return nil; }
static NSData *record(void) {
    uint64_t now = (uint64_t)NSDate.date.timeIntervalSince1970, expiry = now + 3600;
    NSString *claims = [NSString stringWithFormat:@"1800000042.fixture.%llu", expiry];
    uint8_t zero[32] = {0}; NSString *proof = [NSString stringWithFormat:@"nx2.%@.%@", base64url([claims dataUsingEncoding:NSUTF8StringEncoding]), base64url([NSData dataWithBytes:zero length:32])];
    return [NSJSONSerialization dataWithJSONObject:@{@"schema_version":@1, @"token_kind":@"nex", @"token":proof,
        @"identity":@{@"pid":@1800000042ull, @"username":@"fixture"}, @"scopes":@[], @"created_at":@(now-30), @"expires_at":@(expiry)} options:0 error:nil];
}
// Query-capture coverage only. The real process-isolation/legacy semantics are
// exercised separately by t_nextendo_legacy_keychain, not by this mock.
static uint32_t capturedAvailability(uint8_t *out) { *out = credential_with_interaction(NO) != nil; return 0; }
int main(void) { @autoreleasepool {
    uint8_t available = 9;
    CHECK(capturedAvailability(&available) == 0 && !available && reads == 1);
    CHECK(disallowsInteraction());
    CHECK([capturedQuery[(__bridge id)kSecAttrService] isEqual:@"org.nxnative.nextendo.account"]);
    CHECK([capturedQuery[(__bridge id)kSecAttrAccount] isEqual:@"active"] && [capturedQuery[(__bridge id)kSecReturnData] isEqual:@YES]);
    CHECK(begins == 1 && ends == 1 && !writes);
    returnedStatus = errSecItemNotFound; available = 9;
    CHECK(capturedAvailability(&available) == 0 && !available && disallowsInteraction());
    returnedStatus = errSecSuccess; returnedData = record();
    CHECK(capturedAvailability(&available) == 0 && available && disallowsInteraction());
    mode=DM_NET_OFFLINE; unsigned explicitReads=reads, explicitWaits=begins;
    CHECK(dm_nextendo_account_authorize_local()==0 && reads==explicitReads+1 && begins==explicitWaits && !capturedQuery[(__bridge id)kSecUseAuthenticationContext]);
    available=9; CHECK(!capturedAvailability(&available) && !available && reads==explicitReads+1);
    mode=DM_NET_AUTO;
    // Existing explicit access retains its previous policy. No system API is
    // actually called: the same query capture returns fixture-only data.
    CHECK(dm_nextendo_account_ensure() == 0 && !capturedQuery[(__bridge id)kSecUseAuthenticationContext]);
    returnedStatus = errSecInteractionNotAllowed;
    CHECK(dm_nextendo_account_ensure() != 0 && !capturedQuery[(__bridge id)kSecUseAuthenticationContext]);
    // Override only this class's constructor, only in this isolated fixture.
    // An unavailable context must never fall back to a default interactive query.
    Class meta = object_getClass(LAContext.class);
    Method constructor = class_getClassMethod(LAContext.class, @selector(new));
    CHECK(meta && constructor);
    IMP original = method_getImplementation(constructor);
    CHECK(original);
    class_replaceMethod(meta, @selector(new), (IMP)allocationFailure, method_getTypeEncoding(constructor));
    unsigned allocationReads = reads; available = 9;
    uint32_t allocationResult = capturedAvailability(&available);
    class_replaceMethod(meta, @selector(new), original, method_getTypeEncoding(constructor));
    CHECK(allocationResult == 0 && !available && reads == allocationReads);
    unsigned before = reads;
    for (unsigned i=0; i<3; i++) { mode=(dm_net_mode_t)i; available=9; CHECK(capturedAvailability(&available)==0 && !available && reads==before); }
    CHECK(!writes && begins == ends);
    printf("Nextendo noninteractive preflight query: %u checks passed; no real Keychain operations\n", checks);
    return 0;
} }
