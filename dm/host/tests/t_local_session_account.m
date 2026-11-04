// Actual Apple account provider and socket policy, with synthetic callbacks.
// Neither Security nor a preflight process is allowed to query a real account.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "../net_socket.h"
#include <sys/wait.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <dns_sd.h>
static unsigned checks, providerReads, securityReads, preflightReads, dnsReads, osDnsReads;
static int fixtureAddrInfo(const char *host,const char *service,const struct addrinfo *hints,struct addrinfo **result) {
    (void)host;(void)service;(void)hints;osDnsReads++;*result=NULL;return EAI_NONAME;
}
static DNSServiceErrorType fixtureDNS(DNSServiceRef *service,DNSServiceFlags flags,uint32_t interface,DNSServiceProtocol protocol,const char *name,DNSServiceGetAddrInfoReply callback,void *context) {
    (void)service;(void)flags;(void)interface;(void)protocol;(void)name;(void)callback;(void)context;osDnsReads++;return kDNSServiceErr_NoSuchName;
}
#define getaddrinfo fixtureAddrInfo
#define DNSServiceGetAddrInfo fixtureDNS
#include "../hle_net_backend.c"
#undef DNSServiceGetAddrInfo
#undef getaddrinfo
static OSStatus fixtureCopy(CFDictionaryRef query, CFTypeRef *out) {
    (void)query; securityReads++; if(out)*out=NULL; return errSecInteractionNotAllowed;
}
#define SecItemCopyMatching fixtureCopy
#include "../hle_nextendo_apple.m"
#undef SecItemCopyMatching
void dm_guest_host_wait_begin(void){} void dm_guest_host_wait_end(void){}
int hle_signal_system_event_binding(uint64_t binding){(void)binding;abort();}
bool dm_nextendo_api_baas_namespace(const char *kind){(void)kind;abort();}
uint32_t dm_nextendo_api_baas_id(uint64_t *out){(void)out;abort();}
int dm_nextendo_preflight_query(dm_nextendo_preflight_reply *reply,unsigned timeout){(void)reply;(void)timeout;preflightReads++;return -1;}
dm_nextendo_preflight_status dm_nextendo_preflight_last_status(void){return (dm_nextendo_preflight_status){.stage=DM_PREFLIGHT_PROTOCOL};}
static bool provider(uint8_t *bytes,size_t capacity,size_t *size){(void)bytes;(void)capacity;(void)size;providerReads++;return false;}
static int dns(const char *name,char *output,size_t capacity){(void)name;(void)output;(void)capacity;dnsReads++;return -1;}
#define CHECK(c) do{checks++;if(!(c)){fprintf(stderr,"Local-session account line %d: %s\n",__LINE__,#c);_exit(1);}}while(0)
static void automatic(void) {
    uint8_t available=9;uint64_t pid=9;
    CHECK(!dm_nextendo_account_available(&available) && !available);
    CHECK(dm_nextendo_account_id(&pid)!=0 && !pid);
    CHECK(dm_nextendo_account_ensure()!=0);
    void *answer=(void *)(uintptr_t)1;
    CHECK(dm_net_getaddrinfo("external.invalid","443",NULL,&answer)!=0 && !answer);
    CHECK(!dm_net_gethostbyname_cancel("external.invalid",1));
    CHECK(!providerReads && !securityReads && !preflightReads && !dnsReads && !osDnsReads);
}
static uint32_t endpoint(const char *name) {
    struct ifaddrs *list=NULL;CHECK(!getifaddrs(&list));uint32_t address=0;unsigned count=0;
    for(struct ifaddrs *entry=list;entry;entry=entry->ifa_next) {
        if(entry->ifa_addr && entry->ifa_addr->sa_family==AF_INET && (entry->ifa_flags&IFF_UP) && !strcmp(entry->ifa_name,name)) {
            address=((struct sockaddr_in *)entry->ifa_addr)->sin_addr.s_addr;count++;
        }
    }
    freeifaddrs(list);CHECK(count==1 && address);return address;
}
int main(int argc,char **argv) {
    pid_t control=fork();CHECK(control>=0);
    if(!control){@autoreleasepool{
        setenv("DM_NETWORK","lan",1);setenv("DM_NEXTENDO_ROUTES","synthetic-policy-fixture",1);
        void *answer=(void *)(uintptr_t)1;
        CHECK(dm_net_getaddrinfo("external.invalid","443",NULL,&answer)!=0 && !answer && osDnsReads==1);
        CHECK(!dm_net_gethostbyname_cancel("external.invalid",1) && osDnsReads==2);
        setenv("DM_NETWORK","auto",1);uint8_t available=9;
        CHECK(!dm_nextendo_account_available(&available) && !available && preflightReads==1);
        dm_nextendo_set_credential_provider(provider);CHECK(!dm_nextendo_account_available(&available) && !available && providerReads==1);
        dm_nextendo_set_credential_provider(NULL);CHECK(dm_nextendo_account_authorize_local()!=0 && securityReads==1);
        _exit(0);
    }}
    int control_status;CHECK(waitpid(control,&control_status,0)==control && WIFEXITED(control_status) && !WEXITSTATUS(control_status));
    const char *modes[]={"nextendo","auto","offline","ldn"};
    // Fork before Foundation/provider state exists. Every attempt is a fresh
    // immutable session; a rejection cannot inherit a prior credential cache.
    for(unsigned i=0;i<sizeof modes/sizeof *modes;i++) {
        pid_t child=fork();CHECK(child>=0);
        if(!child){@autoreleasepool{
            setenv("DM_NETWORK",modes[i],1);setenv("DM_NEXTENDO_ROUTES","synthetic-policy-fixture",1);
            CHECK(dm_net_local_session_install(htonl(INADDR_LOOPBACK),htonl(INADDR_LOOPBACK))<0);
            dm_net_set_dns_provider(dns);
            // With and without a provider, availability must reject before
            // either in-process reads or the Mac preflight helper can start.
            automatic();dm_nextendo_set_credential_provider(provider);automatic();
            CHECK(dm_nextendo_account_authorize_local()!=0 && providerReads==1 && !securityReads && !preflightReads);
            // Explicit local Authorize keeps its existing user-action policy;
            // it does not enable network mode or allow external guest routes.
            CHECK(!dm_net_nextendo_enabled() && !dm_net_enabled());
            _exit(0);
        }}
        int status;CHECK(waitpid(child,&status,0)==child && WIFEXITED(status) && !WEXITSTATUS(status));
    }
    if(argc!=1 && argc!=3){fprintf(stderr,"usage: t_local_session_account [first-up-IPv4-interface second-up-IPv4-interface]\n");return 2;}
    if(argc==3) {
        uint32_t own=endpoint(argv[1]),peer=endpoint(argv[2]);
        const char *local[]={"lan","ldn"};
        for(unsigned i=0;i<2;i++) {
            pid_t child=fork();CHECK(child>=0);
            if(!child){@autoreleasepool{
                setenv("DM_NETWORK",local[i],1);setenv("DM_NEXTENDO_ROUTES","synthetic-policy-fixture",1);
                CHECK(!dm_net_local_session_install(own,peer) && dm_net_enabled() && !dm_net_nextendo_enabled());
                dm_net_set_dns_provider(dns);automatic();dm_nextendo_set_credential_provider(provider);automatic();
                CHECK(dm_nextendo_account_authorize_local()!=0 && providerReads==1 && !securityReads && !preflightReads);
                CHECK(dm_net_enabled() && !dm_net_nextendo_enabled());_exit(0);
            }}
            int status;CHECK(waitpid(child,&status,0)==child && WIFEXITED(status) && !WEXITSTATUS(status));
        }
    }
    printf("Local-session automatic account isolation: %u parent checks, %s fresh cases, restricted cases have zero automatic provider/Security/preflight/DNS queries; positive controls are synthetic\n",checks,argc==3?"seven":"five");
    return 0;
}
