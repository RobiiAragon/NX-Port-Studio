// Original local discovery bridge. No credential, decryption, game patch or
// multicast entitlement is used. The game still verifies its opaque challenge.
#include "lan_relay.h"
#include "../host/net_discovery.h"
#include "../host/hle_ldn.h"
#include <TargetConditionals.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <time.h>
#include <unistd.h>

enum { RELAY_INTERFACES=16, RELAY_OWN=64, RELAY_PENDING=16, RELAY_PACKET=2048, RELAY_LIFETIME_MS=2000,
       RELAY_RESPONSE_MAX=16, RELAY_SEND_BYTES=2*1024*1024, RELAY_REPLY_BYTES=512*1024 };
typedef struct { uint32_t address,mask; unsigned index,flags; } relay_interface;
typedef struct {
    int fd; unsigned protocol; uint64_t id,deadline; relay_interface interface;
    struct sockaddr_in original; dm_net_discovery_plan plan;
    unsigned size,replies; uint16_t peer_port; uint8_t bytes[RELAY_PACKET],sent[512];
} relay_query;
typedef struct { double packets,bytes; uint64_t time; } relay_budget;
struct dm_lan_relay {
    pthread_mutex_t lock; pthread_t worker; int started,stopping,wake[2],listener[2];
    unsigned protocols,interface_count,cursor; uint64_t generation,next_send,next_refresh;
    char interface_name[IFNAMSIZ]; relay_interface interfaces[RELAY_INTERFACES];
    uint32_t own[RELAY_OWN];unsigned own_count;
    relay_query queries[RELAY_PENDING]; relay_budget admission,send,reply;
    dm_lan_relay_snapshot stats;
#ifdef DM_LAN_RELAY_TEST
    int fixture; uint16_t fixture_peer_port;
#endif
};
static uint64_t relay_ms(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000+t.tv_nsec/1000000; }
static struct sockaddr_in relay_endpoint(uint32_t address,unsigned port) { return (struct sockaddr_in){.sin_len=sizeof(struct sockaddr_in),.sin_family=AF_INET,.sin_port=htons((uint16_t)port),.sin_addr={address}}; }
static int relay_nonblock(int fd) { return fcntl(fd,F_SETFL,O_NONBLOCK)<0 || fcntl(fd,F_SETFD,FD_CLOEXEC)<0 ? -1 : 0; }
static unsigned relay_port(unsigned protocol) { return protocol==DM_LAN_RELAY_PIA ? 30000 : 11452; }
static uint32_t relay_be32(const uint8_t *p) { return (uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3]; }
int dm_lan_relay_packet_valid(unsigned protocol,int response,const void *bytes,size_t size) {
    if (!bytes || size>RELAY_PACKET) return 0;
    const uint8_t *p=bytes;
    if(protocol==DM_LAN_RELAY_PIA) {
        if(size<5 || size>1364 || p[0]!=(response?1:0))return 0;
        uint32_t payload=relay_be32(p+1);unsigned extra=response?0x3f:0x12f;
        if(payload>1364-extra || size!=payload+extra || p[payload+5]!=1 || p[payload+6]>1)return 0;
        unsigned nonzero=0;for(unsigned i=0;i<8;++i)nonzero|=p[payload+7+i];
        return nonzero!=0; // Host and client counters need not be equal.
    }
    if(protocol!=DM_LAN_RELAY_LDN || size<12)return 0;
    if(!response) { static const uint8_t scan[12]={0,0x14,0x45,0x11};return size==12&&!memcmp(p,scan,12); }
    dm_ldn_network network;unsigned type;
    return dm_ldn_packet_decode(p,size,&type,&network,sizeof network)==sizeof network &&
           type==DM_LDN_SCAN_RESPONSE && dm_ldn_network_valid(&network);
}
static int relay_eligible(const relay_interface *a) {
    dm_net_discovery_plan plan;
    return a->index && (a->flags&IFF_UP) && (a->flags&IFF_BROADCAST) &&
           !(a->flags&(IFF_LOOPBACK|IFF_POINTOPOINT)) && !dm_net_discovery_subnet(&plan,a->address,a->mask);
}
static void relay_interfaces(dm_lan_relay *r) {
#ifdef DM_LAN_RELAY_TEST
    if(r->fixture)return;
#endif
    r->interface_count=0;r->own_count=0;r->stats.interfaces=0;struct ifaddrs *list=NULL;
    if(getifaddrs(&list))return;
    int control=socket(AF_INET,SOCK_DGRAM,0);
    int overflow=0;
    for(struct ifaddrs *p=list;p;p=p->ifa_next) {
        if(!p->ifa_addr||p->ifa_addr->sa_family!=AF_INET)continue;
        uint32_t own=((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr;
        unsigned i;for(i=0;i<r->own_count&&r->own[i]!=own;++i){}
        if(i==r->own_count&&own) { if(i==RELAY_OWN)overflow=1;else r->own[r->own_count++]=own; }
        if(r->interface_count==RELAY_INTERFACES||!p->ifa_netmask||p->ifa_netmask->sa_family!=AF_INET)continue;
        if(r->interface_name[0]&&strcmp(p->ifa_name,r->interface_name))continue;
        relay_interface a={((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr,
                           ((struct sockaddr_in *)p->ifa_netmask)->sin_addr.s_addr,if_nametoindex(p->ifa_name),p->ifa_flags};
        if(!relay_eligible(&a))continue;
        struct ifreq request={0};strlcpy(request.ifr_name,p->ifa_name,sizeof request.ifr_name);
        if(control<0||ioctl(control,SIOCGIFFUNCTIONALTYPE,&request))continue;
        unsigned type=request.ifr_ifru.ifru_functional_type;
        if(type!=IFRTYPE_FUNCTIONAL_WIFI_INFRA&&type!=IFRTYPE_FUNCTIONAL_WIRED)continue;
        r->interfaces[r->interface_count++]=a;
    }
    if(control>=0)close(control);freeifaddrs(list);
    if(overflow)r->interface_count=0; // Never silently omit an own address from the exclusion list.
    r->stats.interfaces=r->interface_count;
}
static int relay_token(relay_budget *b,double pps,double max_packets,double bytes_per_second,
                       double max_bytes,size_t size,uint64_t now) {
    if(!b->time) { b->packets=max_packets;b->bytes=max_bytes;b->time=now; }
    double elapsed=(double)(now-b->time)/1000;b->time=now;
    b->packets+=elapsed*pps;if(b->packets>max_packets)b->packets=max_packets;
    b->bytes+=elapsed*bytes_per_second;if(b->bytes>max_bytes)b->bytes=max_bytes;
    if(b->packets<1||b->bytes<size)return 0;
    b->packets-=1;b->bytes-=size;return 1;
}
static void relay_wake(dm_lan_relay *r) { uint8_t one=1;(void)write(r->wake[1],&one,1); }
static void relay_drop(dm_lan_relay *r,unsigned i) {
    if(r->queries[i].fd>=0) { close(r->queries[i].fd);r->queries[i].fd=-1;--r->stats.active_queries; }
}
static int relay_own(dm_lan_relay *r,uint32_t address) {
    for(unsigned i=0;i<r->own_count;++i)if(r->own[i]==address)return 1;
    return 0;
}
static int relay_contains(const relay_interface *a,uint32_t address) {
    uint32_t ip=ntohl(address),local=ntohl(a->address),mask=ntohl(a->mask),network=local&mask,broadcast=local|~mask;
    return ip>network&&ip<broadcast&&(ip&mask)==network;
}
static int relay_ingest(dm_lan_relay *r,unsigned protocol,struct sockaddr_in from,uint32_t destination,
                        unsigned index,int broadcast,const void *bytes,size_t size) {
    relay_interface *a=NULL;
    if(!(r->protocols&protocol)||!broadcast||!from.sin_port||from.sin_family!=AF_INET||relay_own(r,from.sin_addr.s_addr))goto invalid;
    for(unsigned i=0;i<r->interface_count;++i) {
        relay_interface *candidate=&r->interfaces[i];
        if(candidate->index==index&&(destination==htonl(UINT32_MAX)||destination==(candidate->address|~candidate->mask))&&
           relay_contains(candidate,from.sin_addr.s_addr)) { a=candidate;break; }
    }
    if(!a||!dm_lan_relay_packet_valid(protocol,0,bytes,size))goto invalid;
    int slot=-1;
    for(unsigned i=0;i<RELAY_PENDING;++i) {
        relay_query *q=&r->queries[i];
        if(q->fd<0) { slot=(int)i;continue; }
        if(q->protocol==protocol&&q->original.sin_port==from.sin_port&&q->original.sin_addr.s_addr==from.sin_addr.s_addr&&
           q->interface.index==index&&q->size==size&&!memcmp(q->bytes,bytes,size))return 0;
    }
    uint64_t now=relay_ms();
    if(slot<0||!relay_token(&r->admission,8,4,RELAY_PACKET*8,RELAY_PACKET*4,size,now)) { ++r->stats.rate_limited;return -1; }
    relay_query *q=&r->queries[slot];int fd=socket(AF_INET,SOCK_DGRAM,0);
    if(fd<0)goto system;
    uint32_t bind_ip=a->address;
#ifdef DM_LAN_RELAY_TEST
    if(r->fixture)bind_ip=htonl(INADDR_LOOPBACK);
#endif
    struct sockaddr_in local=relay_endpoint(bind_ip,0);
    if(relay_nonblock(fd)||bind(fd,(struct sockaddr *)&local,sizeof local)) { int error=errno;close(fd);errno=error;goto system; }
#if TARGET_OS_OSX
#ifdef DM_LAN_RELAY_TEST
    if(!r->fixture)
#endif
    if(setsockopt(fd,IPPROTO_IP,IP_BOUND_IF,&a->index,sizeof a->index)) { int error=errno;close(fd);errno=error;goto system; }
#endif
    *q=(relay_query){.fd=fd,.protocol=protocol,.id=++r->generation,.deadline=now+RELAY_LIFETIME_MS,
                     .interface=*a,.original=from,.size=(unsigned)size,.peer_port=(uint16_t)relay_port(protocol)};
#ifdef DM_LAN_RELAY_TEST
    if(r->fixture)q->peer_port=r->fixture_peer_port;
#endif
    dm_net_discovery_subnet(&q->plan,a->address,a->mask);memcpy(q->bytes,bytes,size);
    ++r->stats.queries;++r->stats.active_queries;relay_wake(r);return 0;
system:
    r->stats.system_errno=(unsigned)errno;++r->stats.rejected;return -1;
invalid:
    ++r->stats.rejected;return -1;
}
static void relay_read_query(dm_lan_relay *r,unsigned which) {
    uint8_t bytes[RELAY_PACKET+1];union { struct cmsghdr alignment;uint8_t bytes[256]; } control;
    struct sockaddr_in from={0};
    struct iovec io={bytes,sizeof bytes};struct msghdr msg={.msg_name=&from,.msg_namelen=sizeof from,
        .msg_iov=&io,.msg_iovlen=1,.msg_control=control.bytes,.msg_controllen=sizeof control.bytes};
    ssize_t size=recvmsg(r->listener[which],&msg,0);if(size<0)return;
    r->stats.bytes_received+=(uint64_t)size;uint32_t destination=0;unsigned index=0;
    if(!(msg.msg_flags&(MSG_TRUNC|MSG_CTRUNC)))for(struct cmsghdr *h=CMSG_FIRSTHDR(&msg);h;h=CMSG_NXTHDR(&msg,h)) {
        if(h->cmsg_level!=IPPROTO_IP)continue;
        if(h->cmsg_type==IP_RECVDSTADDR&&h->cmsg_len>=CMSG_LEN(sizeof(uint32_t)))memcpy(&destination,CMSG_DATA(h),sizeof destination);
        if(h->cmsg_type==IP_RECVIF&&h->cmsg_len>=CMSG_LEN(offsetof(struct sockaddr_dl,sdl_index)+sizeof(uint16_t))) {
            uint16_t value;memcpy(&value,(uint8_t *)CMSG_DATA(h)+offsetof(struct sockaddr_dl,sdl_index),sizeof value);index=value;
        }
    }
    relay_ingest(r,which?DM_LAN_RELAY_LDN:DM_LAN_RELAY_PIA,from,destination,index,
                 destination!=0,bytes,(size_t)size); // kernel-supplied destination must match the actual subnet broadcast
}
static int relay_active_interface(dm_lan_relay *r,const relay_interface *a) {
    for(unsigned i=0;i<r->interface_count;++i) {
        relay_interface *b=&r->interfaces[i];
        if(a->address==b->address&&a->mask==b->mask&&a->index==b->index)return 1;
    }
    return 0;
}
static void relay_send_batch(dm_lan_relay *r,uint64_t now) {
    if(now<r->next_send)return;
    unsigned count=0;
    for(unsigned n=0;n<RELAY_PENDING;++n) {
        unsigned i=(r->cursor+n)%RELAY_PENDING;relay_query *q=&r->queries[i];
        if(q->fd<0||!q->plan.count)continue;
        for(;count<DM_DISCOVERY_BATCH;++count) {
            dm_net_discovery_plan saved=q->plan;uint32_t address;
            if(!dm_net_discovery_next(&q->plan,&address)) { q->plan.count=0;break; }
            if(address==q->original.sin_addr.s_addr||relay_own(r,address))continue;
            if(!relay_token(&r->send,4096,32,RELAY_SEND_BYTES,32768,q->size,now)) { q->plan=saved;goto done; }
            struct sockaddr_in to=relay_endpoint(address,q->peer_port);
            ssize_t size=sendto(q->fd,q->bytes,q->size,0,(struct sockaddr *)&to,sizeof to);
            if(size==(ssize_t)q->size) {
                unsigned bit=ntohl(address)-(ntohl(q->interface.address)&ntohl(q->interface.mask));
                q->sent[bit/8]|=(uint8_t)(1u<<(bit%8));++r->stats.fanout;r->stats.bytes_sent+=(uint64_t)size;
            } else if(size<0&&(errno==EAGAIN||errno==ENOBUFS||errno==EINTR)) { q->plan=saved;goto done; }
        }
        if(count>=DM_DISCOVERY_BATCH) { r->cursor=(i+1)%RELAY_PENDING;break; }
    }
done:
    r->next_send=now+DM_DISCOVERY_TICK_MS;
}
static void relay_read_response(dm_lan_relay *r,unsigned i,uint64_t id) {
    relay_query *q=&r->queries[i];if(q->fd<0||q->id!=id)return;
    uint8_t bytes[RELAY_PACKET+1];struct sockaddr_in from;socklen_t length=sizeof from;
    ssize_t size=recvfrom(q->fd,bytes,sizeof bytes,0,(struct sockaddr *)&from,&length);if(size<0)return;
    r->stats.bytes_received+=(uint64_t)size;uint64_t now=relay_ms();
    if(now>=q->deadline||from.sin_family!=AF_INET||ntohs(from.sin_port)!=q->peer_port||
       !relay_contains(&q->interface,from.sin_addr.s_addr)||relay_own(r,from.sin_addr.s_addr)||
       from.sin_addr.s_addr==q->original.sin_addr.s_addr||q->replies>=RELAY_RESPONSE_MAX||
       !dm_lan_relay_packet_valid(q->protocol,1,bytes,(size_t)size))goto rejected;
    unsigned bit=ntohl(from.sin_addr.s_addr)-(ntohl(q->interface.address)&ntohl(q->interface.mask));
    if(!(q->sent[bit/8]&(1u<<(bit%8))))goto rejected;
    if(q->protocol==DM_LAN_RELAY_LDN) {
        dm_ldn_network network;unsigned type;
        if(dm_ldn_packet_decode(bytes,(size_t)size,&type,&network,sizeof network)!=sizeof network||
           htonl(network.nodes[0].ip)!=from.sin_addr.s_addr)goto rejected;
    }
    if(!relay_token(&r->reply,256,16,RELAY_REPLY_BYTES,32768,(size_t)size,now)) { ++r->stats.rate_limited;return; }
    struct sockaddr_in to=q->original;
#ifdef DM_LAN_RELAY_TEST
    // Logical Switch addresses are mapped to the only assigned loopback IP in
    // this fixture. Validation and neighbor exclusion still use the original.
    if(r->fixture)to.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
#endif
    int listener=r->listener[q->protocol==DM_LAN_RELAY_LDN];
    union { struct cmsghdr alignment;uint8_t bytes[CMSG_SPACE(sizeof(struct in_pktinfo))]; } control={0};
    struct iovec io={bytes,(size_t)size};struct msghdr message={.msg_name=&to,.msg_namelen=sizeof to,
        .msg_iov=&io,.msg_iovlen=1,.msg_control=control.bytes,.msg_controllen=sizeof control.bytes};
    struct cmsghdr *header=CMSG_FIRSTHDR(&message);header->cmsg_level=IPPROTO_IP;header->cmsg_type=IP_PKTINFO;header->cmsg_len=CMSG_LEN(sizeof(struct in_pktinfo));
    // Keep the return path on the actual interface that received the broadcast,
    // even when a VPN/default route would otherwise choose another interface.
    struct in_pktinfo info={.ipi_ifindex=q->interface.index};memcpy(CMSG_DATA(header),&info,sizeof info);
    if(sendmsg(listener,&message,0)==size) {
        ++q->replies;++r->stats.replies;r->stats.bytes_sent+=(uint64_t)size;
    }
    return;
rejected:
    ++r->stats.rejected;
}
static void *relay_worker(void *opaque) {
    dm_lan_relay *r=opaque;
    for(;;) {
        struct pollfd fds[3+RELAY_PENDING];uint64_t ids[RELAY_PENDING];
        pthread_mutex_lock(&r->lock);if(r->stopping) { pthread_mutex_unlock(&r->lock);break; }
        uint64_t now=relay_ms();if(now>=r->next_refresh) { relay_interfaces(r);r->next_refresh=now+2000; }
        int sending=0;
        for(unsigned i=0;i<RELAY_PENDING;++i) {
            relay_query *q=&r->queries[i];
            if(q->fd>=0&&(now>=q->deadline||!relay_active_interface(r,&q->interface))) { relay_drop(r,i);++r->stats.expired; }
            sending|=q->fd>=0&&q->plan.count!=0;
            fds[3+i]=(struct pollfd){q->fd,POLLIN,0};ids[i]=q->id;
        }
        fds[0]=(struct pollfd){r->wake[0],POLLIN,0};fds[1]=(struct pollfd){r->listener[0],POLLIN,0};fds[2]=(struct pollfd){r->listener[1],POLLIN,0};
        pthread_mutex_unlock(&r->lock);int ready=poll(fds,3+RELAY_PENDING,sending?8:50);
        if(ready<0&&errno!=EINTR) { pthread_mutex_lock(&r->lock);r->stats.status=DM_LAN_RELAY_SYSTEM_ERROR;r->stats.system_errno=(unsigned)errno;r->stats.running=0;pthread_mutex_unlock(&r->lock);break; }
        pthread_mutex_lock(&r->lock);
        if(fds[0].revents&POLLIN) { uint8_t bytes[64];while(read(r->wake[0],bytes,sizeof bytes)>0){} }
        if(r->stopping) { pthread_mutex_unlock(&r->lock);break; }
        for(unsigned i=0;i<2;++i)if(fds[i+1].revents&POLLIN)relay_read_query(r,i);
        for(unsigned i=0;i<RELAY_PENDING;++i)if(fds[i+3].revents&POLLIN)relay_read_response(r,i,ids[i]);
        relay_send_batch(r,relay_ms());pthread_mutex_unlock(&r->lock);
    }
    return NULL;
}
static int relay_listener(unsigned port,int fixture) {
    int fd=socket(AF_INET,SOCK_DGRAM,0);if(fd<0)return -1;
    int yes=1;struct sockaddr_in local=relay_endpoint(fixture?htonl(INADDR_LOOPBACK):INADDR_ANY,port);
    if(relay_nonblock(fd)||bind(fd,(struct sockaddr *)&local,sizeof local)||
       setsockopt(fd,IPPROTO_IP,IP_RECVDSTADDR,&yes,sizeof yes)||setsockopt(fd,IPPROTO_IP,IP_RECVIF,&yes,sizeof yes)) {
        int error=errno;close(fd);errno=error;return -1;
    }
    return fd;
}
static dm_lan_relay *relay_allocate(unsigned protocols) {
    dm_lan_relay *r=calloc(1,sizeof *r);if(!r)return NULL;
    pthread_mutex_init(&r->lock,NULL);r->protocols=protocols;r->wake[0]=r->wake[1]=r->listener[0]=r->listener[1]=-1;
    for(unsigned i=0;i<RELAY_PENDING;++i)r->queries[i].fd=-1;
    r->stats.protocols=protocols;return r;
}
void dm_lan_relay_stop(dm_lan_relay *r) {
    if(!r)return;
    if(r->started) { pthread_mutex_lock(&r->lock);r->stopping=1;relay_wake(r);pthread_mutex_unlock(&r->lock);pthread_join(r->worker,NULL); }
    for(unsigned i=0;i<RELAY_PENDING;++i)relay_drop(r,i);
    for(unsigned i=0;i<2;++i) { if(r->listener[i]>=0)close(r->listener[i]);if(r->wake[i]>=0)close(r->wake[i]); }
    pthread_mutex_destroy(&r->lock);free(r);
}
static dm_lan_relay_status relay_launch(dm_lan_relay *r,dm_lan_relay **out,dm_lan_relay_snapshot *failure) {
    dm_lan_relay_status status=DM_LAN_RELAY_SYSTEM_ERROR;
    if(!r->interface_count) { status=DM_LAN_RELAY_NO_INTERFACE;errno=0;goto fail; }
    if(pipe(r->wake)||relay_nonblock(r->wake[0])||relay_nonblock(r->wake[1]))goto fail;
    r->stats.running=1;r->stats.interfaces=r->interface_count;
    int error=pthread_create(&r->worker,NULL,relay_worker,r);if(error) { errno=error;goto fail; }
    r->started=1;*out=r;return DM_LAN_RELAY_OK;
fail:
    if(failure) { *failure=r->stats;failure->running=0;failure->status=status;failure->system_errno=(unsigned)errno; }
    dm_lan_relay_stop(r);return status;
}
dm_lan_relay_status dm_lan_relay_start(const dm_lan_relay_config *config,dm_lan_relay **out,dm_lan_relay_snapshot *failure) {
    if(out)*out=NULL;if(failure)memset(failure,0,sizeof *failure);
    unsigned protocols=config&&config->protocols?config->protocols:DM_LAN_RELAY_ALL;
    if(!out||(protocols&~DM_LAN_RELAY_ALL)||(config&&config->interface_name&&strlen(config->interface_name)>=IFNAMSIZ)) {
        if(failure)failure->status=DM_LAN_RELAY_INVALID;return DM_LAN_RELAY_INVALID;
    }
    dm_lan_relay *r=relay_allocate(protocols);if(!r) { if(failure)failure->status=DM_LAN_RELAY_NO_MEMORY;return DM_LAN_RELAY_NO_MEMORY; }
    if(config&&config->interface_name)strlcpy(r->interface_name,config->interface_name,sizeof r->interface_name);
    relay_interfaces(r);
    if(!r->interface_count) { if(failure)failure->status=DM_LAN_RELAY_NO_INTERFACE;dm_lan_relay_stop(r);return DM_LAN_RELAY_NO_INTERFACE; }
    for(unsigned i=0;i<2;++i)if(protocols&(1u<<i)) {
        r->listener[i]=relay_listener(i?11452:30000,0);
        if(r->listener[i]<0) {
            dm_lan_relay_status status=errno==EADDRINUSE?DM_LAN_RELAY_PORT_BUSY:DM_LAN_RELAY_SYSTEM_ERROR;
            if(failure) { *failure=r->stats;failure->status=status;failure->system_errno=(unsigned)errno; }
            dm_lan_relay_stop(r);return status;
        }
    }
    return relay_launch(r,out,failure);
}
void dm_lan_relay_snapshot_get(dm_lan_relay *r,dm_lan_relay_snapshot *out) {
    if(!out)return;if(!r) { memset(out,0,sizeof *out);return; }
    pthread_mutex_lock(&r->lock);*out=r->stats;pthread_mutex_unlock(&r->lock);
}
#ifdef DM_LAN_RELAY_TEST
dm_lan_relay_status dm_lan_relay_test_start(unsigned protocol,uint16_t port,uint16_t peer_port,
                                          dm_lan_relay_test_interface interface,dm_lan_relay **out) {
    if(out)*out=NULL;if(!out||(protocol!=1&&protocol!=2)||!peer_port)return DM_LAN_RELAY_INVALID;
    dm_lan_relay *r=relay_allocate(protocol);if(!r)return DM_LAN_RELAY_NO_MEMORY;
    r->fixture=1;r->fixture_peer_port=peer_port;
    r->interfaces[0]=(relay_interface){interface.address,interface.mask,interface.index,interface.flags};
    r->own[0]=interface.address;r->own_count=1;
    r->interface_count=relay_eligible(&r->interfaces[0])?1:0;
    r->listener[protocol==DM_LAN_RELAY_LDN]=relay_listener(port,1);
    if(r->listener[protocol==DM_LAN_RELAY_LDN]<0) {
        dm_lan_relay_status status=errno==EADDRINUSE?DM_LAN_RELAY_PORT_BUSY:DM_LAN_RELAY_SYSTEM_ERROR;
        dm_lan_relay_stop(r);return status;
    }
    return relay_launch(r,out,NULL);
}
int dm_lan_relay_test_query(dm_lan_relay *r,unsigned protocol,uint32_t source,uint16_t source_port,
                          uint32_t destination,unsigned index,const void *bytes,size_t size) {
    if(!r)return -1;struct sockaddr_in from=relay_endpoint(source,source_port);
    pthread_mutex_lock(&r->lock);int result=relay_ingest(r,protocol,from,destination,index,1,bytes,size);pthread_mutex_unlock(&r->lock);return result;
}
int dm_lan_relay_test_add_own(dm_lan_relay *r,uint32_t address) {
    if(!r||!address)return -1;pthread_mutex_lock(&r->lock);
    int result=r->own_count<RELAY_OWN?0:-1;if(!result)r->own[r->own_count++]=address;
    pthread_mutex_unlock(&r->lock);return result;
}
#endif
