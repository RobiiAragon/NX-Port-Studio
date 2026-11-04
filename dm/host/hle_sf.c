// Services whose client a game links into its own main (nn::sf::hipc): Animal Crossing: New Horizons 3.0.3 carries the clients of olsc:u (cloud save data backup settings,
// main+0x404bc6c) and npns (push notifications). The SDK's client code connects through sm (an abort in sm::Initialize under InitializeHipcServiceResolution, from main+0x5b8198) and talks
// HIPC through svcSendSyncRequest; the host has neither. It hands out sessions of its own instead and answers each request in the message buffer, for the services listed in sf_served:
// success, the output data zeroed, no objects or handles. For olsc that reads as "backup off for every user", so the game leaves the settings alone (main+0x2809c8c asks per user and
// switches backup off where it is on). Any other service name is refused with a red line, as sm refuses a service that is not registered.
// The typed friend:u bridge in sf_friends.inc owns real domain objects and kernel
// completion events, and calls the existing friends backend. It never enters the
// zero-output fallback. Only metadata is logged for those requests.
// The SDK's own client functions are taken over where they reach the kernel (their calls inside sdk go through its PLT): the session manager's CreateNewSession runs natively on
// DuplicateSession, and ConvertToDomainImpl on QueryPointerBufferSize and ConvertSessionToDomain. DM_SF_TRACE=1 dumps legacy requests only.
// Message layout (Atmosphère / libnx): HIPC header {u16 type, counts of X / A / B / W descriptors; u32 data words, receive list, special header flag}, the special header and descriptors,
// then the data words, whose CMIF part starts 16-byte aligned to the buffer: in a domain session the domain header {u8 type, u8 objects, u16 size, u32 object, u32, u32 token} first,
// then {"SFCI", version, command, token} and the arguments. The response is the same with {u32 objects, 3 × u32} and {"SFCO", version, result, token}
#include "hle.h"
#include <pthread.h>
#include "sf_friends.inc"

#define SF_H0 0xd0000u   // session handles: outside the kernel handle table (0x1000 + slot, 4096 slots, hle_thread.c)
#define SF_MAX 64
static struct { char name[16]; int used, domain; unsigned seen; sf_friend_domain *friends; } g_sf[SF_MAX];
static pthread_mutex_t g_sf_mu = PTHREAD_MUTEX_INITIALIZER;
static const char *const sf_served[] = {"olsc:u"};

static int sf_slot(uint32_t h) {
    unsigned i = h - SF_H0;
    return i < SF_MAX && g_sf[i].used ? (int)i : -1;
}
static uint32_t sf_new(const char *name, int domain, sf_friend_domain *friends) {
    pthread_mutex_lock(&g_sf_mu);
    unsigned i = 0; while (i < SF_MAX && g_sf[i].used) i++;
    if (i == SF_MAX) { pthread_mutex_unlock(&g_sf_mu); return 0; }
    strlcpy(g_sf[i].name, name, sizeof g_sf[i].name); g_sf[i].used = 1; g_sf[i].domain = domain; g_sf[i].seen = 0;
    g_sf[i].friends=friends;sf_friend_domain_retain(friends);
    pthread_mutex_unlock(&g_sf_mu);
    return SF_H0 + i;
}

HLE_FORCE("_ZN2nn2sf4hipc31InitializeHipcServiceResolutionEv", "service name resolution (connects to sm); the host resolves the names it serves itself", Result, h_sf_InitRes, void) { return RES_OK; }
HLE_FORCE("_ZN2nn2sf4hipc29FinalizeHipcServiceResolutionEv", "service name resolution (sm)", void, h_sf_FinRes, void) {}
HLE_FORCE("_ZN2nn2sf4hipc20ConnectToHipcServiceEPNS_3svc6HandleEPKc", "connect to a service through sm → a host session for the services the host serves", Result, h_sf_Connect,
          uint32_t *out, const char *name) {
    if (!out || !name) return RES_FAIL;
    if (!strncmp(name,"friend:u",8)) {
        sf_friend_domain *friends=sf_friend_domain_new();if(!friends)return RES_FAIL;
        uint32_t handle=sf_new("friend:u",0,friends);sf_friend_domain_release(friends);
        if(!handle)return RES_FAIL;*out=handle;LOG("sf: friend:u → native friends service");return 0;
    }
    for (size_t k = 0; k < sizeof sf_served / sizeof *sf_served; k++)
        if (!strncmp(name, sf_served[k], 8)) { uint32_t handle=sf_new(sf_served[k],0,NULL);if(!handle)return RES_FAIL;*out=handle; LOG("sf: %s → host session %#x (every request succeeds with zeroed output)", sf_served[k], *out); return RES_OK; }
    LOG("[RED] sf: the game connects to service %.8s itself, which the host does not serve", name);
    return 0xe15u;   // sm ResultNotRegistered
}
HLE_FORCE("_ZN2nn2sf4hipc24CloseClientSessionHandleENS_3svc6HandleE", "close a session (kernel handle) → the host session", void, h_sf_Close, uint32_t h) {
    pthread_mutex_lock(&g_sf_mu);int i = sf_slot(h);
    if (i < 0) { pthread_mutex_unlock(&g_sf_mu);LOG("[RED] sf: CloseClientSessionHandle on %#x, not a host session", h); return; }
    sf_friend_domain *friends=g_sf[i].friends;g_sf[i].friends=NULL;g_sf[i].used=0;pthread_mutex_unlock(&g_sf_mu);
    sf_friend_domain_release(friends);
}
// Control requests: the pointer buffer is the server's receive buffer for X descriptors (none: the host reads them in place), the domain conversion makes the session's object 1, a duplicate
// is a new session to the same object
HLE_FORCE("_ZN2nn2sf4hipc6client22QueryPointerBufferSizeEPtNS_3svc6HandleE", "control request: pointer buffer size of a session → 0 for a host session", Result, h_sf_PtrBuf, uint16_t *out, uint32_t h) {
    pthread_mutex_lock(&g_sf_mu);int valid=out&&sf_slot(h)>=0;pthread_mutex_unlock(&g_sf_mu);
    if (!valid) { LOG("[RED] sf: QueryPointerBufferSize on %#x, not a host session", h); return RES_FAIL; }
    *out = 0; return RES_OK;
}
HLE_FORCE("_ZN2nn2sf4hipc6client22ConvertSessionToDomainEPNS0_4cmif18CmifDomainObjectIdENS_3svc6HandleE", "control request: convert a session to a domain → the host session's object 1", Result, h_sf_ToDomain,
          uint32_t *out, uint32_t h) {
    pthread_mutex_lock(&g_sf_mu);int i = sf_slot(h);
    if (i < 0 || !out) { pthread_mutex_unlock(&g_sf_mu);LOG("[RED] sf: ConvertSessionToDomain on %#x, not a host session", h); return RES_FAIL; }
    g_sf[i].domain = 1; *out = 1;pthread_mutex_unlock(&g_sf_mu);return RES_OK;
}
HLE_FORCE("_ZN2nn2sf4hipc6client16DuplicateSessionEPNS_3svc6HandleES4_", "control request: clone a session → a new host session to the same service", Result, h_sf_Dup, uint32_t *out, uint32_t h) {
    pthread_mutex_lock(&g_sf_mu);int i = sf_slot(h);
    if (i < 0 || !out) { pthread_mutex_unlock(&g_sf_mu);LOG("[RED] sf: DuplicateSession on %#x, not a host session", h); return RES_FAIL; }
    char name[16];memcpy(name,g_sf[i].name,sizeof name);int domain=g_sf[i].domain;
    sf_friend_domain *friends=g_sf[i].friends;sf_friend_domain_retain(friends);pthread_mutex_unlock(&g_sf_mu);
    uint32_t handle=sf_new(name,domain,friends);sf_friend_domain_release(friends);
    if(!handle)return RES_FAIL;*out=handle;return RES_OK;
}
HLE_FORCE("_ZN2nn2sf4hipc6client18DuplicateSessionExEPNS_3svc6HandleES4_j", "control request: clone a session (with a tag) → a new host session to the same service", Result, h_sf_DupEx,
          uint32_t *out, uint32_t h, unsigned tag) { (void)tag; return h_sf_Dup(out, h); }

HLE_FORCE_WAIT("_ZN2nn2sf4hipc15SendSyncRequestENS_3svc6HandleEPvm", "native service dispatch; a real friends provider request can block", Result, h_sf_Send,
          uint32_t h, uint32_t *m, uint64_t size) {
    pthread_mutex_lock(&g_sf_mu);int i = sf_slot(h);
    sf_friend_domain *friends=i<0?NULL:g_sf[i].friends;int converted=i>=0&&g_sf[i].domain;
    sf_friend_domain_retain(friends);pthread_mutex_unlock(&g_sf_mu);
    if (i < 0 || !m || size < 0x40) { sf_friend_domain_release(friends);LOG("[RED] sf: SendSyncRequest on %#x (%llu bytes), not a host session", h, (unsigned long long)size); return 0xe401u; }   // kernel ResultInvalidHandle
    if(friends){uint32_t result=sf_friend_send(friends,converted,(uint8_t *)m,(size_t)size);sf_friend_domain_release(friends);return result;}
    uint8_t *base = (uint8_t *)m;
    unsigned type = m[0] & 0xffff, nx = m[0] >> 16 & 15, nabw = (m[0] >> 20 & 15) + (m[0] >> 24 & 15) + (m[0] >> 28 & 15), ndw = m[1] & 0x3ff;
    uint32_t *p = m + 2;
    if (m[1] >> 31) { uint32_t sh = *p++; p += (sh & 1 ? 2 : 0) + (sh >> 1 & 15) + (sh >> 5 & 15); }   // special header: process ID, copy and move handles
    p += nx * 2 + nabw * 3;
    size_t data = (size_t)((uint8_t *)p - base), cm = (data + 15) & ~(size_t)15;
    int dom = g_sf[i].domain && (type == 4 || type == 6);
    unsigned dtype = dom ? base[cm] : 1, obj = dom ? *(uint32_t *)(base + cm + 4) : 0;
    size_t hin = cm + (dom ? 16 : 0);
    if (hin + 16 > size || data + ndw * 4 > size) { LOG("[RED] sf: %s: request of %u data words does not fit %llu bytes", g_sf[i].name, ndw, (unsigned long long)size); return 0xe401u; }
    uint32_t magic = *(uint32_t *)(base + hin), ver = *(uint32_t *)(base + hin + 4), cmd = *(uint32_t *)(base + hin + 8);
    static int trace = -1; if (trace < 0) trace = getenv("DM_SF_TRACE") && atoi(getenv("DM_SF_TRACE"));
    if (trace) { char hx[3 * 0x80 + 1] = ""; for (unsigned k = 0; k < 0x80 && k < size; k++) snprintf(hx + 3 * k, 4, "%02x ", base[k]); LOG("sf: %s request: %s", g_sf[i].name, hx); }
    if (type != 4 && type != 6) { LOG("[RED] sf: %s: HIPC message type %u not served", g_sf[i].name, type); return 0xe401u; }
    if (dtype == 2) { memset(base, 0, 16); return RES_OK; }   // a domain object closed: nothing to answer
    if (magic != 0x49434653) { LOG("[RED] sf: %s: request without SFCI (%#x)", g_sf[i].name, magic); return 0xe401u; }
    unsigned key = (obj & 0xff) << 16 | (cmd & 0xffff);   // log each object / command once
    pthread_mutex_lock(&g_sf_mu); int first = g_sf[i].seen != key; g_sf[i].seen = key; pthread_mutex_unlock(&g_sf_mu);
    if (first || trace) LOG("sf: %s object %u command %u (%u data words in): success, zeroed output", g_sf[i].name, obj, cmd, ndw);
    // The response: no special header and no descriptors, so the data words start at +8 and the CMIF part at +0x10; everything after the headers up to the buffer's end reads as zero
    size_t end = size < 0x1000 ? size : 0x1000;
    memset(base, 0, end);
    m[1] = (uint32_t)((end - 8) / 4 < 0x3ff ? (end - 8) / 4 : 0x3ff);
    size_t out = 0x10 + (dom ? 16 : 0);
    uint32_t *o = (uint32_t *)(base + out); o[0] = 0x4f434653; o[1] = ver; o[2] = RES_OK; o[3] = 0;   // "SFCO"; a domain's out-object count before it stays 0
    return RES_OK;
}
