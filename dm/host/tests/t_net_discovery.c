// Real UDP discovery/reply traffic through the production socket translator.
// The adapter fixture is confined to 127/8. No LAN is scanned or broadcast sent.
#include "../net_socket.h"
#include <assert.h>
#include <errno.h>
#include <net/if.h>
#include <poll.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static unsigned checks;
#define CHECK(c) do { ++checks; if (!(c)) { fprintf(stderr,"FAIL %d: %s (guest errno %d)\n",__LINE__,#c,dm_net_errno()); abort(); } } while (0)
void dm_guest_host_wait_begin(void) {}
void dm_guest_host_wait_end(void) {}
void dm_guest_sleep_ns(int64_t ns) { struct timespec t={ns/1000000000,ns%1000000000}; nanosleep(&t,NULL); }
static uint64_t ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000+t.tv_nsec/1000000; }
static _Atomic unsigned injected_calls;
static int injected_error;
static long first_unreachable(int fd,const void *bytes,size_t size,int flags,uint32_t ip,uint16_t port) {
    unsigned call=atomic_fetch_add(&injected_calls,1);
    if(!call) { CHECK(ip==htonl(INADDR_LOOPBACK));errno=injected_error;return -1; }
    // Darwin has only 127.0.0.1 assigned: map the next logical neighbor to it.
    // Actual UDP delivery, original fd/source port and bytes remain real.
    struct sockaddr_in to={.sin_len=sizeof to,.sin_family=AF_INET,.sin_port=port,.sin_addr={htonl(INADDR_LOOPBACK)}};
    return sendto(fd,bytes,size,flags,(struct sockaddr *)&to,sizeof to);
}
typedef struct { uint8_t len,family; uint16_t port; uint32_t ip; uint8_t zero[8]; } address;
static address endpoint(uint32_t ip,unsigned port) { return (address){16,2,htons(port),htonl(ip),{0}}; }
static dm_net_test_interface adapter(uint32_t mask) { return (dm_net_test_interface){htonl(0x7f000002),htonl(mask),if_nametoindex("lo0"),IFF_UP|IFF_BROADCAST,1}; }
static int receiver(unsigned *port) {
    int fd=socket(AF_INET,SOCK_DGRAM,0); CHECK(fd>=0);
    struct sockaddr_in a={.sin_len=sizeof a,.sin_family=AF_INET,.sin_addr={htonl(INADDR_LOOPBACK)}};
    CHECK(!bind(fd,(struct sockaddr *)&a,sizeof a)); socklen_t n=sizeof a; CHECK(!getsockname(fd,(struct sockaddr *)&a,&n)); *port=ntohs(a.sin_port); return fd;
}
static ssize_t read_packet(int fd,void *bytes,size_t size,struct sockaddr_in *from) {
    struct pollfd p={fd,POLLIN,0}; if(poll(&p,1,1000)!=1)return -1;
    socklen_t n=sizeof *from; return recvfrom(fd,bytes,size,0,(struct sockaddr *)from,&n);
}
static void ranges(void) {
    dm_net_discovery_plan p; uint32_t ip;
    CHECK(!dm_net_discovery_subnet(&p,htonl(0xc0a80819),htonl(0xffffff00)) && p.count==253);
    unsigned n=0; while(dm_net_discovery_next(&p,&ip)) { CHECK(ntohl(ip)>0xc0a80800 && ntohl(ip)<0xc0a808ff && ntohl(ip)!=0xc0a80819); ++n; } CHECK(n==253);
    CHECK(!dm_net_discovery_subnet(&p,htonl(0xac101911),htonl(0xfffff000)) && p.count==4093 && dm_net_discovery_duration(&p)==1024);
    n=0; while(dm_net_discovery_next(&p,&ip)) { CHECK(ntohl(ip)>0xac101000 && ntohl(ip)<0xac101fff && ntohl(ip)!=0xac101911); ++n; } CHECK(n==4093);
    const uint32_t masks[]={0,0xffff0000,0xffff00ff,0xfffffffe,0xffffffff};
    for(unsigned i=0;i<sizeof masks/sizeof masks[0];++i) CHECK(dm_net_discovery_subnet(&p,htonl(0xc0a80819),htonl(masks[i]))<0);
    CHECK(dm_net_discovery_subnet(&p,htonl(0xc0a80800),htonl(0xffffff00))<0);
    CHECK(dm_net_discovery_subnet(&p,htonl(0xc0a808ff),htonl(0xffffff00))<0);
}
static void traffic(void) {
    dm_net_test_interface a=adapter(0xfffffffc); CHECK(a.index); dm_net_test_set_interface(&a);
    unsigned port; int native=receiver(&port),guest=dm_net_socket(2,2,0); CHECK(guest>=0);
    address own=endpoint(INADDR_LOOPBACK,0); CHECK(!dm_net_bind(guest,&own,sizeof own)); unsigned n=sizeof own; CHECK(!dm_net_name(guest,&own,&n,0));
    CHECK(!dm_net_fcntl(guest,4,0x800)); // nonblocking guest SendTo stays nonblocking
    address destination=endpoint(UINT32_MAX,port);
    const unsigned char query[]={0x80,0x34,0,0xff,'L','A','N',0,1,2,3};
    uint64_t start=ms(); CHECK(dm_net_send(guest,query,sizeof query,0,&destination,sizeof destination)==sizeof query); CHECK(ms()-start<100);
    unsigned char bytes[64]; struct sockaddr_in from;
    CHECK(read_packet(native,bytes,sizeof bytes,&from)==sizeof query && !memcmp(bytes,query,sizeof query));
    CHECK(from.sin_port==own.port && ntohl(from.sin_addr.s_addr)==INADDR_LOOPBACK);
    CHECK(sendto(native,"answer",6,0,(struct sockaddr *)&from,sizeof from)==6);
    dm_net_pollfd ready={guest,1,0}; CHECK(dm_net_poll(&ready,1,1000)==1);
    address peer; n=sizeof peer; CHECK(dm_net_recv(guest,bytes,sizeof bytes,0,&peer,&n)==6 && !memcmp(bytes,"answer",6));
    CHECK(peer.ip==htonl(INADDR_LOOPBACK) && peer.port==htons(port));
    // Directed subnet broadcast enters exactly the same unicast route.
    destination.ip=htonl(0x7f000003);
    CHECK(dm_net_send(guest,query,sizeof query,0,&destination,sizeof destination)==sizeof query);
    CHECK(read_packet(native,bytes,sizeof bytes,&from)==sizeof query && !memcmp(bytes,query,sizeof query));
    // A broken optional override cannot interfere with ordinary peer traffic.
    setenv("DM_NET_DISCOVERY_PEER","invalid",1); destination.ip=htonl(INADDR_LOOPBACK);
    CHECK(dm_net_send(guest,"ordinary",8,0,&destination,sizeof destination)==8);
    CHECK(read_packet(native,bytes,sizeof bytes,&from)==8 && !memcmp(bytes,"ordinary",8));
    destination.ip=htonl(UINT32_MAX); CHECK(dm_net_send(guest,query,sizeof query,0,&destination,sizeof destination)<0 && dm_net_errno()==22);
    unsetenv("DM_NET_DISCOVERY_PEER"); CHECK(!dm_net_close(guest)); close(native);
}
static void bounds_and_lifetime(void) {
    dm_net_test_interface a=adapter(0xfffff000); dm_net_test_set_interface(&a);
    unsigned port; int native=receiver(&port),guest=dm_net_socket(2,2,0); CHECK(guest>=0);
    address destination=endpoint(UINT32_MAX,port);
    uint64_t start=ms();
    CHECK(dm_net_send(guest,"nonce1",6,0,&destination,sizeof destination)==6);
    for(unsigned i=0;i<100;++i) CHECK(dm_net_send(guest,"nonce1",6,0,&destination,sizeof destination)==6);
    CHECK(ms()-start<100 && dm_net_test_discovery_pending()==1);
    usleep(20000); CHECK(dm_net_test_discovery_pending()==1); // the /20 sweep is paced, not one burst
    CHECK(dm_net_send(guest,"nonce2",6,0,&destination,sizeof destination)==6);
    CHECK(dm_net_send(guest,"nonce3",6,0,&destination,sizeof destination)<0 && dm_net_errno()==105);
    CHECK(dm_net_test_discovery_pending()==2);
    unsigned char bytes[16]; struct sockaddr_in from;
    CHECK(read_packet(native,bytes,sizeof bytes,&from)==6 && !memcmp(bytes,"nonce1",6));
    CHECK(read_packet(native,bytes,sizeof bytes,&from)==6 && !memcmp(bytes,"nonce2",6));
    CHECK(!dm_net_close(guest) && !dm_net_test_discovery_pending());
    int reused=dm_net_socket(2,2,0); CHECK(reused==guest); destination.ip=htonl(INADDR_LOOPBACK);
    CHECK(dm_net_send(reused,"reused",6,0,&destination,sizeof destination)==6);
    CHECK(read_packet(native,bytes,sizeof bytes,&from)==6 && !memcmp(bytes,"reused",6));
    CHECK(!dm_net_close(reused)); close(native);
    // The global queue has a real bound even across distinct guest sockets.
    native=receiver(&port); destination=endpoint(UINT32_MAX,port); int sockets[17];
    for(unsigned i=0;i<17;++i) {
        sockets[i]=dm_net_socket(2,2,0); CHECK(sockets[i]>=0);
        long result=dm_net_send(sockets[i],"bounded",7,0,&destination,sizeof destination);
        CHECK(i<16 ? result==7 : result<0 && dm_net_errno()==105);
    }
    CHECK(dm_net_test_discovery_pending()==16);
    for(unsigned i=0;i<17;++i) CHECK(!dm_net_close(sockets[i]));
    CHECK(!dm_net_test_discovery_pending()); close(native);
    dm_net_discovery_plan plan;
    a=adapter(0xffff0000); dm_net_test_set_interface(&a); CHECK(dm_net_discovery_prepare(htonl(UINT32_MAX),&plan)<0 && dm_net_errno()==95);
    const unsigned flags[]={IFF_UP,IFF_BROADCAST,IFF_UP|IFF_BROADCAST|IFF_POINTOPOINT,IFF_UP|IFF_BROADCAST|IFF_LOOPBACK};
    for(unsigned i=0;i<sizeof flags/sizeof flags[0];++i) { a=adapter(0xffffff00); a.flags=flags[i]; dm_net_test_set_interface(&a); CHECK(dm_net_discovery_prepare(htonl(UINT32_MAX),&plan)<0 && dm_net_errno()==99); }
    a=adapter(0xffffff00); a.index=0; dm_net_test_set_interface(&a); CHECK(dm_net_discovery_prepare(htonl(UINT32_MAX),&plan)<0 && dm_net_errno()==99);
    setenv("DM_NET_DISCOVERY_PEER","127.0.0.1",1); CHECK(!dm_net_discovery_prepare(htonl(UINT32_MAX),&plan) && !plan.automatic && plan.target==htonl(INADDR_LOOPBACK)); unsetenv("DM_NET_DISCOVERY_PEER");
    a=adapter(0xfffff000); dm_net_test_set_interface(&a); guest=dm_net_socket(2,2,0); destination=endpoint(UINT32_MAX,9);
    CHECK(dm_net_send(guest,"close",5,0,&destination,sizeof destination)==5); setenv("DM_NETWORK","offline",1); dm_net_finalize(); CHECK(!dm_net_test_discovery_pending());
}
static void unreachable_neighbor(void) {
    dm_net_test_interface a=adapter(0xfffffff8);dm_net_test_set_interface(&a);
    unsigned port;int native=receiver(&port);address destination=endpoint(UINT32_MAX,port);
    const int errors[]={EHOSTUNREACH,ENETUNREACH,EACCES,ENETDOWN};
    for(unsigned i=0;i<4;++i) {
        int guest=dm_net_socket(2,2,0);CHECK(guest>=0);CHECK(!dm_net_fcntl(guest,4,0x800));
        injected_error=errors[i];atomic_store(&injected_calls,0);dm_net_test_set_discovery_sender(first_unreachable);
        uint64_t start=ms();long result=dm_net_send(guest,"later neighbor",14,0,&destination,sizeof destination);
        if(i<2) {
            CHECK(result==14 && ms()-start<100 && atomic_load(&injected_calls)>=2);
            char bytes[32];struct sockaddr_in from;CHECK(read_packet(native,bytes,sizeof bytes,&from)==14 && !memcmp(bytes,"later neighbor",14));
        } else CHECK(result<0 && dm_net_errno()==(i==2?13:100) && atomic_load(&injected_calls)==1);
        CHECK(!dm_net_close(guest));dm_net_test_set_discovery_sender(NULL);
        struct pollfd ready={native,POLLIN,0};char drain[32];while(poll(&ready,1,0)>0)recv(native,drain,sizeof drain,0);
    }
    close(native);
}
int main(void) {
    setenv("DM_NETWORK","lan",1); unsetenv("DM_NET_DISCOVERY_PEER"); dm_net_set_multicast_allowed(0);
    ranges(); traffic(); unreachable_neighbor(); bounds_and_lifetime(); dm_net_test_set_interface(NULL);
    printf("automatic discovery: %u checks passed (real UDP reply, ranges, bounded queue, close/reuse).\n",checks); return 0;
}
