// Native Nextendo credentials and account requests. This bridge never mints an nx2
// proof: its HMAC is checked by Nextendo, while the host checks identity and expiry.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <TargetConditionals.h>
#if !TARGET_OS_IOS
#import <LocalAuthentication/LocalAuthentication.h>
#include "nextendo_preflight_mac.h"
#include <signal.h>
#endif
#include <CommonCrypto/CommonDigest.h>
#include "nextendo_account.h"
#include "account_trace.h"
#import "nextendo_api_apple.h"
#include "net_socket.h"
#include <stdatomic.h>
#include <pthread.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>
#include <math.h>

void dm_guest_host_wait_begin(void);
void dm_guest_host_wait_end(void);
int hle_signal_system_event_binding(uint64_t binding);

static _Atomic(dm_nextendo_credential_provider) credentialProvider;
static pthread_mutex_t accountLock = PTHREAD_MUTEX_INITIALIZER;
static NSString *explicitVersion;
static NSData *cachedFingerprint;
static NSString *cachedVersion;
static NSData *cachedToken;
static NSTimeInterval cachedExpiry;
static SecKeyRef signingKey;
static NSData *publicSigningKey;
static pthread_once_t signingOnce = PTHREAD_ONCE_INIT;
static BOOL enabled(void) { return dm_net_nextendo_enabled(); }
static _Atomic uint64_t preflightGeneration;
#if !TARGET_OS_IOS
static BOOL preflightChild;
#endif

@interface DmNextendoCredential : NSObject
@property(nonatomic) uint64_t pid;
@property(nonatomic) NSString *username;
@property(nonatomic) NSString *token;
@property(nonatomic) NSTimeInterval expiry;
@end
@implementation DmNextendoCredential
@end

static NSString *base64url(NSData *data) {
    NSString *value = [[data base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    return [[value stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"=" withString:@""];
}
static NSData *decode_base64url(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length) return nil;
    for (NSUInteger i = 0; i < value.length; i++) { unichar c = [value characterAtIndex:i]; if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_')) return nil; }
    NSString *normal = [[value stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    normal = [normal stringByPaddingToLength:(normal.length + 3) & ~(NSUInteger)3 withString:@"=" startingAtIndex:0];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:normal options:0]; return data && [base64url(data) isEqualToString:value] ? data : nil;
}
static BOOL unsigned_decimal(NSString *text, uint64_t *out) {
    if (![text isKindOfClass:NSString.class] || !text.length || text.length > 20) return NO;
    uint64_t value = 0;
    for (NSUInteger i = 0; i < text.length; i++) { unichar c = [text characterAtIndex:i]; if (c < '0' || c > '9' || value > (UINT64_MAX - (c - '0')) / 10) return NO; value = value * 10 + c - '0'; }
    if (!value) return NO; *out = value; return YES;
}
static BOOL number(id value) { return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID(); }
static NSData *read_credentials(BOOL allowInteraction, BOOL guestWait) {
    (void)guestWait;
    if (allowInteraction) atomic_fetch_add(&preflightGeneration, 1);
    dm_nextendo_credential_provider provider = atomic_load(&credentialProvider);
    if (provider) { NSMutableData *data = [NSMutableData dataWithLength:65536]; size_t size = 0; if (!data || !provider(data.mutableBytes, data.length, &size) || !size || size > data.length) return nil; data.length = size; return data; }
#if TARGET_OS_IOS
    (void)allowInteraction; // The existing provider/document path is unchanged.
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [documents stringByAppendingPathComponent:@"nextendo-account.json"]; if (!path) return nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW); if (fd < 0) return nil;
    struct stat st; if (fstat(fd, &st) || !S_ISREG(st.st_mode) || (st.st_mode & 0777) != 0600 || st.st_uid != geteuid() || st.st_size <= 0 || st.st_size > 65536) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size]; size_t done = 0;
    while (done < data.length) { ssize_t n = read(fd, (char *)data.mutableBytes + done, data.length - done); if (n <= 0) { close(fd); return nil; } done += (size_t)n; }
    close(fd); return data;
#else
    NSMutableDictionary *query = [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"org.nxnative.nextendo.account", (__bridge id)kSecAttrAccount:@"active",
        (__bridge id)kSecAttrSynchronizable:@NO, (__bridge id)kSecReturnData:@YES, (__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitOne} mutableCopy];
    if (!query) return nil;
    if (!allowInteraction) {
        // Availability is queried before the game menu. Do not stop local boot
        // for a protected Keychain authorization; explicit access stays intact.
        LAContext *context = [LAContext new]; if (!context) return nil;
        context.interactionNotAllowed = YES;
        query[(__bridge id)kSecUseAuthenticationContext] = context;
    }
    CFTypeRef result = NULL;
    // The probe has no guest scheduler/TLS: it runs before host preload.
    if (guestWait) dm_guest_host_wait_begin();
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (guestWait) dm_guest_host_wait_end();
    if (status || !result) { if (result) CFRelease(result); return nil; }
    id data = CFBridgingRelease(result); return [data isKindOfClass:NSData.class] && [data length] <= 65536 ? data : nil;
#endif
}
static DmNextendoCredential *decode_credential(NSData *data) {
    if (!data.length || data.length > 65536) return nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]; if (![decoded isKindOfClass:NSDictionary.class]) return nil; NSDictionary *json = decoded;
    if (!number(json[@"schema_version"]) || [json[@"schema_version"] doubleValue] != 1 || ![json[@"token_kind"] isEqual:@"nex"]) return nil;
    NSString *token = json[@"token"]; if (![token isKindOfClass:NSString.class] || !token.length || [token lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 16384) return nil;
    for (NSUInteger i = 0; i < token.length; i++) { unichar c = [token characterAtIndex:i]; if (c <= 32 || c >= 127) return nil; }
    NSArray *parts = [token componentsSeparatedByString:@"."]; if (parts.count != 3 || ![parts[0] isEqual:@"nx2"]) return nil;
    NSData *payload = decode_base64url(parts[1]), *signature = decode_base64url(parts[2]); if (!payload || signature.length != 32) return nil;
    NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding]; NSArray *claims = [text componentsSeparatedByString:@"."]; if (claims.count < 3) return nil;
    uint64_t pid, expiry; if (!unsigned_decimal(claims.firstObject, &pid) || !unsigned_decimal(claims.lastObject, &expiry) || expiry > INT64_MAX) return nil;
    NSString *username = [[claims subarrayWithRange:NSMakeRange(1, claims.count - 2)] componentsJoinedByString:@"."]; if (!username.length || username.length > 128) return nil;
    id identity = json[@"identity"]; if (![identity isKindOfClass:NSDictionary.class] || !number(identity[@"pid"])) return nil;
    uint64_t storedPid; if (!unsigned_decimal([identity[@"pid"] stringValue], &storedPid) || storedPid != pid || ![identity[@"username"] isEqual:username]) return nil;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!number(json[@"created_at"]) || !number(json[@"expires_at"])) return nil;
    double created = [json[@"created_at"] doubleValue], until = [json[@"expires_at"] doubleValue];
    if (!isfinite(created) || !isfinite(until) || created <= 0 || created > now + 60 || until <= now || until <= created || until > (double)expiry) return nil;
    id scopes = json[@"scopes"]; if (![scopes isKindOfClass:NSArray.class] || [scopes count] > 128) return nil; for (id scope in scopes) if (![scope isKindOfClass:NSString.class] || [scope length] > 256) return nil;
    DmNextendoCredential *c = [DmNextendoCredential new]; c.pid = pid; c.username = username; c.token = token; c.expiry = until; return c;
}
static DmNextendoCredential *credential_with_interaction(BOOL allowInteraction) {
    BOOL guestWait=YES;
#if !TARGET_OS_IOS
    guestWait=!preflightChild;
#endif
    return enabled() ? decode_credential(read_credentials(allowInteraction,guestWait)) : nil;
}
static DmNextendoCredential *credential(void) { DmNextendoCredential *c = credential_with_interaction(YES); atomic_fetch_add(&preflightGeneration, 1); return c; }
uint32_t dm_nextendo_account_authorize_local(void) { @autoreleasepool {
    DmNextendoCredential *c=decode_credential(read_credentials(YES,NO));
    atomic_fetch_add(&preflightGeneration,1); return c ? 0 : DM_ACCOUNT_FAIL;
} }
void dm_nextendo_set_credential_provider(dm_nextendo_credential_provider provider) {
    atomic_fetch_add(&preflightGeneration, 1);
    atomic_store(&credentialProvider, provider); pthread_mutex_lock(&accountLock); cachedFingerprint = nil; cachedToken = nil; cachedVersion = nil; cachedExpiry = 0; pthread_mutex_unlock(&accountLock);
}
void dm_nextendo_set_game_version(const char *version) {
    NSString *value = version ? [NSString stringWithUTF8String:version] : nil;
    pthread_mutex_lock(&accountLock); explicitVersion = value; cachedToken = nil; cachedVersion = nil; pthread_mutex_unlock(&accountLock);
}
#if !TARGET_OS_IOS
// The legacy SecItem shim ignores LAContext for password decryption. Its public
// UI switch applies to every Keychain call in a process, so use it only in this
// short-lived instance of the identical executable, before AppKit or guest boot.
int dm_nextendo_account_preflight_child(int fd) { @autoreleasepool {
    struct stat st; if (fd < 3 || fstat(fd, &st) || !S_ISFIFO(st.st_mode)) return 64;
    preflightChild = YES;
    // Also bound this child if the renderer exits before it can cancel us.
    struct sigaction action = {.sa_handler=SIG_DFL}; sigemptyset(&action.sa_mask);
    sigset_t unblock; sigemptyset(&unblock); sigaddset(&unblock, SIGALRM);
    if (sigaction(SIGALRM, &action, NULL) || pthread_sigmask(SIG_UNBLOCK, &unblock, NULL)) return 68;
    alarm(5);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    Boolean previous = true;
    if (SecKeychainGetUserInteractionAllowed(&previous) || SecKeychainSetUserInteractionAllowed(false)) return 65;
    DmNextendoCredential *c = credential_with_interaction(NO);
    OSStatus restored = SecKeychainSetUserInteractionAllowed(previous);
#pragma clang diagnostic pop
    if (restored) return 66;
    BOOL representable = c && c.expiry < (double)UINT64_MAX / 1000;
    dm_nextendo_preflight_reply reply = {.magic=DM_NEXTENDO_PREFLIGHT_MAGIC, .version=1, .pid=(uint32_t)getpid(),
        .available=representable, .expires_ms=representable ? (uint64_t)floor(c.expiry * 1000) : 0};
    size_t done = 0; const uint8_t *bytes = (const uint8_t *)&reply;
    while (done < sizeof reply) { ssize_t n = write(fd, bytes + done, sizeof reply - done); if (n < 0 && errno == EINTR) continue; if (n <= 0) return 67; done += (size_t)n; }
    return 0;
} }
static BOOL preflight_available(dm_account_trace_provider_state *trace) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static uint64_t generation; static NSTimeInterval checkedUntil, expiresAt; static BOOL available;
    dm_guest_host_wait_begin(); pthread_mutex_lock(&lock);
    uint64_t before = atomic_load(&preflightGeneration);
    NSTimeInterval now = NSDate.date.timeIntervalSince1970, uptime = NSProcessInfo.processInfo.systemUptime;
    if (generation != before || uptime >= checkedUntil || (available && now >= expiresAt)) {
        trace->cached = 0;
        dm_nextendo_preflight_reply reply; int valid = dm_nextendo_preflight_query(&reply, 3000);
        dm_nextendo_preflight_status status=dm_nextendo_preflight_last_status();
        trace->stage=status.stage; trace->error=status.error; trace->bytes=status.bytes;
        trace->exit_code=status.exit_code; trace->signal=status.signal;
        now = NSDate.date.timeIntervalSince1970;
        expiresAt = valid ? (double)reply.expires_ms / 1000 : 0;
        available = valid && reply.available && expiresAt > now;
        trace->query_valid = valid;
        trace->child_available = valid ? (int)reply.available : -1;
        trace->expiry_valid = valid && reply.available ? expiresAt > now : -1;
        generation = before; checkedUntil = NSProcessInfo.processInfo.systemUptime + MIN(1, available ? expiresAt - now : 1);
        // Explicit reads/provider changes can happen concurrently. Do not
        // publish an older observation over that change, even for one second.
        trace->generation_changed = atomic_load(&preflightGeneration) != before;
        if (trace->generation_changed) { checkedUntil = 0; available = NO; }
    } else { trace->cached = 1; trace->expiry_valid = available ? now < expiresAt : -1; }
    BOOL result = available;
    pthread_mutex_unlock(&lock); dm_guest_host_wait_end(); return result;
}
#endif
uint32_t dm_nextendo_account_available(uint8_t *out) { @autoreleasepool {
    if (!out) return DM_ACCOUNT_FAIL; *out = 0;
    dm_account_trace_provider_state trace = {enabled(),-1,-1,-1,-1,-1,-1,-1,0,-1,-1,0};
    if (!trace.enabled) { dm_account_trace_provider(0,trace); return 0; }
#if TARGET_OS_IOS
    trace.provider = 1;
    *out = credential_with_interaction(NO) != nil;
#else
    trace.provider = atomic_load(&credentialProvider) != NULL;
    *out = trace.provider ? credential_with_interaction(NO) != nil : preflight_available(&trace);
#endif
    dm_account_trace_provider(*out != 0,trace);
    return 0;
} }
uint32_t dm_nextendo_account_id(uint64_t *out) { @autoreleasepool {
    if (!out) return DM_ACCOUNT_FAIL; *out = 0; DmNextendoCredential *c = credential(); if (!c) return DM_ACCOUNT_FAIL;
    if (dm_nextendo_api_baas_namespace("account")) return dm_nextendo_api_baas_id(out);
    *out = c.pid; return 0;
} }
uint32_t dm_nextendo_account_ensure(void) { @autoreleasepool { return credential() ? 0 : DM_ACCOUNT_FAIL; } }
// Host-only API authorization. Never serialized into a game bundle or HLE output.
NSString *dm_nextendo_api_bearer(void) { return credential().token; }
NSData *dm_nextendo_api_identity(void) {
    DmNextendoCredential *c = credential(); if (!c) return nil;
    NSData *bytes = [c.token dataUsingEncoding:NSUTF8StringEncoding]; uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest); return [NSData dataWithBytes:digest length:sizeof digest];
}

// Token construction is deliberately separate from credential validation. The nx2
// proof is never substituted with a local signature or an OAuth access token.
static void initialize_signing_key(void) {
    NSDictionary *attributes = @{(__bridge id)kSecAttrKeyType:(__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeySizeInBits:@2048, (__bridge id)kSecPrivateKeyAttrs:@{(__bridge id)kSecAttrIsPermanent:@NO}};
    CFErrorRef error = NULL; dm_guest_host_wait_begin(); signingKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attributes, &error); dm_guest_host_wait_end(); if (error) CFRelease(error);
    if (!signingKey) return; SecKeyRef publicKey = SecKeyCopyPublicKey(signingKey);
    if (publicKey) { publicSigningKey = CFBridgingRelease(SecKeyCopyExternalRepresentation(publicKey, NULL)); CFRelease(publicKey); }
}
uint32_t dm_nextendo_copy_public_signing_key(void *buffer, uint64_t capacity, uint64_t *size) { @autoreleasepool {
    if (!size) return DM_ACCOUNT_FAIL; *size = 0; pthread_once(&signingOnce, initialize_signing_key);
    if (!publicSigningKey) return DM_ACCOUNT_FAIL; *size = publicSigningKey.length; if (!buffer || capacity < publicSigningKey.length) return DM_ACCOUNT_FAIL;
    memcpy(buffer, publicSigningKey.bytes, publicSigningKey.length); return 0;
} }
static NSData *id_token(DmNextendoCredential *c) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970; NSData *proof = [c.token dataUsingEncoding:NSASCIIStringEncoding]; unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(proof.bytes, (CC_LONG)proof.length, hash);
    NSData *fingerprint = [NSData dataWithBytes:hash length:sizeof hash]; pthread_mutex_lock(&accountLock);
    NSString *version = explicitVersion ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![version isKindOfClass:NSString.class] || !version.length || version.length > 64 || ![version canBeConvertedToEncoding:NSASCIIStringEncoding]) { pthread_mutex_unlock(&accountLock); return nil; }
    if (cachedToken && [cachedFingerprint isEqual:fingerprint] && [cachedVersion isEqual:version] && cachedExpiry > now && cachedExpiry <= c.expiry) { NSData *token = cachedToken; pthread_mutex_unlock(&accountLock); return token; }
    pthread_once(&signingOnce, initialize_signing_key); if (!signingKey || !publicSigningKey) { pthread_mutex_unlock(&accountLock); return nil; }
    uint64_t expiry = (uint64_t)floor(MIN(c.expiry, now + 3600)); if ((double)expiry <= now) { pthread_mutex_unlock(&accountLock); return nil; }
    unsigned char keyHash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(publicSigningKey.bytes, (CC_LONG)publicSigningKey.length, keyHash);
    NSString *kid = [@"nx-port-studio-" stringByAppendingString:base64url([NSData dataWithBytes:keyHash length:16])];
    NSDictionary *header = @{@"alg":@"RS256", @"typ":@"JWT", @"kid":kid};
    NSDictionary *claims = @{@"iss":@"nx-port-studio", @"sub":[NSString stringWithFormat:@"%llu", c.pid], @"iat":@((uint64_t)floor(now)), @"exp":@(expiry), @"nnex":c.token, @"tv":version};
    NSData *headerData = [NSJSONSerialization dataWithJSONObject:header options:NSJSONWritingSortedKeys error:nil], *claimData = [NSJSONSerialization dataWithJSONObject:claims options:NSJSONWritingSortedKeys error:nil];
    if (!headerData || !claimData) { pthread_mutex_unlock(&accountLock); return nil; }
    NSString *message = [NSString stringWithFormat:@"%@.%@", base64url(headerData), base64url(claimData)]; NSData *bytes = [message dataUsingEncoding:NSASCIIStringEncoding];
    CFErrorRef error = NULL; dm_guest_host_wait_begin(); NSData *signature = CFBridgingRelease(SecKeyCreateSignature(signingKey, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, (__bridge CFDataRef)bytes, &error)); dm_guest_host_wait_end(); if (error) CFRelease(error);
    if (!signature) { pthread_mutex_unlock(&accountLock); return nil; }
    NSData *token = [[NSString stringWithFormat:@"%@.%@", message, base64url(signature)] dataUsingEncoding:NSASCIIStringEncoding];
    cachedFingerprint = fingerprint; cachedVersion = version; cachedToken = token; cachedExpiry = (NSTimeInterval)expiry; pthread_mutex_unlock(&accountLock); return token;
}
uint32_t dm_nextendo_account_load_token(uint64_t *size, char *buffer, uint64_t capacity) { @autoreleasepool {
    if (!size) return DM_ACCOUNT_FAIL; *size = 0; if (!buffer && capacity) return DM_ACCOUNT_FAIL;
    DmNextendoCredential *c = credential(); if (!c) return DM_ACCOUNT_FAIL; NSData *token = id_token(c); if (!token) return DM_ACCOUNT_FAIL;
    *size = token.length; if (!buffer || capacity <= token.length) return DM_ACCOUNT_FAIL; memcpy(buffer, token.bytes, token.length); buffer[token.length] = 0; return 0;
} }

@interface DmNextendoAsync : NSObject
@property(nonatomic) NSLock *lock;
@property(nonatomic) uint64_t lifetime, generation;
@property(nonatomic) BOOL started, done, destroyed;
@property(nonatomic) uint32_t result;
@property(nonatomic) NSMutableArray<NSNumber *> *events;
@end
@implementation DmNextendoAsync
@end
static NSMutableDictionary<NSValue *, DmNextendoAsync *> *requests;
static pthread_once_t requestsOnce = PTHREAD_ONCE_INIT;
static pthread_mutex_t requestsLock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t nextLifetime;
static void requests_init(void) { requests = [NSMutableDictionary new]; }
static NSValue *request_key(void *object) { return [NSValue valueWithPointer:object]; }
static DmNextendoAsync *request(void *object) { pthread_once(&requestsOnce, requests_init); pthread_mutex_lock(&requestsLock); DmNextendoAsync *state = requests[request_key(object)]; pthread_mutex_unlock(&requestsLock); return state; }
static DmNextendoAsync *new_request(void) { DmNextendoAsync *state = [DmNextendoAsync new]; state.lock = [NSLock new]; state.events = [NSMutableArray new]; state.result = DM_ACCOUNT_FAIL; return state; }
static void finish_events(NSArray<NSNumber *> *events) { for (NSNumber *binding in events) hle_signal_system_event_binding(binding.unsignedLongLongValue); }
static void destroy_request(DmNextendoAsync *state) { if (!state) return; [state.lock lock]; state.destroyed = YES; state.generation++; state.done = YES; state.result = DM_ACCOUNT_FAIL; NSArray *events = state.events.copy; [state.lock unlock]; finish_events(events); }
void dm_nextendo_async_construct(void *object) { @autoreleasepool {
    if (!object) return; DmNextendoAsync *state = new_request(); if (!state) return; pthread_once(&requestsOnce, requests_init); pthread_mutex_lock(&requestsLock);
    DmNextendoAsync *old = requests[request_key(object)]; if (requests.count < 512 || old) { state.lifetime = ++nextLifetime; requests[request_key(object)] = state; } pthread_mutex_unlock(&requestsLock); destroy_request(old);
} }
void dm_nextendo_async_destroy(void *object) { @autoreleasepool { if (!object) return; pthread_once(&requestsOnce, requests_init); pthread_mutex_lock(&requestsLock); DmNextendoAsync *state = requests[request_key(object)]; [requests removeObjectForKey:request_key(object)]; pthread_mutex_unlock(&requestsLock); destroy_request(state); } }
void *dm_nextendo_async_move(void *object, void *source) { @autoreleasepool {
    if (!object || !source || object == source) return object; pthread_once(&requestsOnce, requests_init); pthread_mutex_lock(&requestsLock);
    DmNextendoAsync *old = requests[request_key(object)], *state = requests[request_key(source)]; [requests removeObjectForKey:request_key(source)]; requests[request_key(object)] = state; pthread_mutex_unlock(&requestsLock); destroy_request(old); return object;
} }
void dm_nextendo_async_swap(void *object, void *other) { @autoreleasepool {
    if (!object || !other || object == other) return; pthread_once(&requestsOnce, requests_init); pthread_mutex_lock(&requestsLock); DmNextendoAsync *first = requests[request_key(object)], *second = requests[request_key(other)]; requests[request_key(object)] = second; requests[request_key(other)] = first; pthread_mutex_unlock(&requestsLock);
} }
bool dm_nextendo_async_valid(void *object) { @autoreleasepool { DmNextendoAsync *state = request(object); if (!state) return false; [state.lock lock]; bool valid = state.started && !state.destroyed; [state.lock unlock]; return valid; } }
uint64_t dm_nextendo_async_lifetime(void *object) { @autoreleasepool { DmNextendoAsync *state = request(object); if (!state) return 0; [state.lock lock]; uint64_t id = state.started && !state.destroyed ? state.lifetime : 0; [state.lock unlock]; return id; } }
uint32_t dm_nextendo_async_attach(void *object, uint64_t lifetime, uint64_t binding) { @autoreleasepool {
    if (!object || !lifetime || !binding) return DM_ACCOUNT_FAIL; DmNextendoAsync *state = request(object); if (!state) return DM_ACCOUNT_FAIL; [state.lock lock];
    if (state.lifetime != lifetime || state.destroyed || !state.started || state.events.count >= 64) { [state.lock unlock]; return DM_ACCOUNT_FAIL; }
    if (![state.events containsObject:@(binding)]) [state.events addObject:@(binding)]; BOOL done = state.done; [state.lock unlock]; if (done) hle_signal_system_event_binding(binding); return 0;
} }
uint32_t dm_nextendo_async_execute(void *object, dm_nextendo_async_operation operation, const void *context) { @autoreleasepool {
    if (!object || !operation || !enabled()) return DM_ACCOUNT_FAIL;
    DmNextendoAsync *state = request(object); if (!state) { dm_nextendo_async_construct(object); state = request(object); } if (!state) return DM_ACCOUNT_FAIL;
    [state.lock lock]; BOOL replacing = state.started && state.done && !state.destroyed; [state.lock unlock];
    if (replacing) {
        DmNextendoAsync *fresh = new_request(); if (!fresh) return DM_ACCOUNT_FAIL;
        pthread_mutex_lock(&requestsLock); if (requests[request_key(object)] != state) { pthread_mutex_unlock(&requestsLock); return DM_ACCOUNT_FAIL; }
        fresh.lifetime = ++nextLifetime; requests[request_key(object)] = fresh; pthread_mutex_unlock(&requestsLock); destroy_request(state); state = fresh;
    }
    [state.lock lock]; if (state.started || state.destroyed) { [state.lock unlock]; return DM_ACCOUNT_FAIL; } state.started = YES; uint64_t generation = ++state.generation; [state.lock unlock];
    uint32_t result = operation(context);
    [state.lock lock]; NSArray *events = nil; if (!state.destroyed && state.generation == generation) { state.result = result; state.done = YES; events = state.events.copy; } [state.lock unlock]; finish_events(events);
    return enabled() ? 0 : DM_ACCOUNT_FAIL;
} }
static uint32_t ensure_token_operation(const void *context) {
    (void)context; DmNextendoCredential *c = credential(); return c && id_token(c) ? 0 : DM_ACCOUNT_FAIL;
}
uint32_t dm_nextendo_async_ensure(void *object) { return dm_nextendo_async_execute(object, ensure_token_operation, NULL); }
uint32_t dm_nextendo_async_cancel(void *object) { @autoreleasepool {
    DmNextendoAsync *state = request(object); if (!state) return DM_ACCOUNT_FAIL; [state.lock lock]; if (!state.started || state.destroyed) { [state.lock unlock]; return DM_ACCOUNT_FAIL; }
    NSArray *events = nil; if (!state.done) { state.generation++; state.done = YES; state.result = DM_ACCOUNT_FAIL; events = state.events.copy; } [state.lock unlock]; finish_events(events); return 0;
} }
uint32_t dm_nextendo_async_done(void *object, uint8_t *out) { @autoreleasepool {
    if (!out) return DM_ACCOUNT_FAIL; *out = 0; DmNextendoAsync *state = request(object); if (!state) return DM_ACCOUNT_FAIL; [state.lock lock]; uint32_t result = !state.started || state.destroyed ? DM_ACCOUNT_FAIL : 0; if (!result) *out = state.done; [state.lock unlock]; return result;
} }
uint32_t dm_nextendo_async_result(void *object) { @autoreleasepool {
    DmNextendoAsync *state = request(object); if (!state) return DM_ACCOUNT_FAIL; [state.lock lock]; uint32_t result = state.started && state.done && !state.destroyed ? state.result : DM_ACCOUNT_FAIL; [state.lock unlock]; return result;
} }
