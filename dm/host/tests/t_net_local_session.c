// Optional real-interface diagnostic, separate from asset-free CI. Every peer
// address belongs to this Mac; no broadcast, subnet sweep or game data is sent.
// This checks the existing transport API, not two unmodified game processes.
#include "../hle_ldn.h"
#include "../net_socket.h"
#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"endpoint fixture line %d: %s (errno %d, guest errno %d)\n",__LINE__,#x,errno,dm_net_errno()); _exit(1); } } while (0)
void dm_guest_host_wait_begin(void) {}
void dm_guest_host_wait_end(void) {}
typedef struct { uint8_t len, family; uint16_t port; uint32_t ip; uint8_t reserved[8]; } guest_address;
static guest_address address(uint32_t ip, unsigned port) { return (guest_address){16,2,htons((uint16_t)port),ip,{0}}; }
static struct sockaddr_in native_address(uint32_t ip, unsigned port) {
    return (struct sockaddr_in){.sin_len=sizeof(struct sockaddr_in),.sin_family=AF_INET,.sin_port=htons((uint16_t)port),.sin_addr={ip}};
}
static dm_ldn_transport adapter(const char *name) {
    struct ifaddrs *list=NULL; CHECK(!getifaddrs(&list)); dm_ldn_transport t={0};unsigned count=0;
    for (struct ifaddrs *p=list;p;p=p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family!=AF_INET || !(p->ifa_flags&IFF_UP) || strcmp(p->ifa_name,name)) continue;
        count++;t.address=((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr;
        if(p->ifa_netmask && p->ifa_netmask->sa_family==AF_INET) t.mask=((struct sockaddr_in *)p->ifa_netmask)->sin_addr.s_addr;
    }
    freeifaddrs(list); CHECK(count==1 && t.address && t.mask); t.bind_address=0; t.scan_ms=250; t.connect_ms=2000; return t;
}
static void exchange(int fd, void *data, size_t size, int sending) {
    char *bytes=data; size_t at=0;
    while(at<size) {
        struct pollfd p={fd,sending?POLLOUT:POLLIN,0}; CHECK(poll(&p,1,4000)>0);
        ssize_t n=sending?write(fd,bytes+at,size-at):read(fd,bytes+at,size-at); CHECK(n>0); at+=(size_t)n;
    }
}
static void timeout(int fd) {
    int64_t value[2]={2,0};unsigned size=sizeof value;
    CHECK(!dm_net_sockopt(fd,0xffff,0x1006,value,&size,1));
    CHECK(!dm_net_sockopt(fd,0xffff,0x1005,value,&size,1));
}
static void policy(dm_ldn_transport t) {
    dm_net_local_session session={0};CHECK(dm_net_local_session_get(&session)==1 && session.own==t.address && session.peer==t.discovery && session.mask==t.mask);
    CHECK(!dm_net_nextendo_enabled() && dm_net_enabled());
    uint32_t ip=0;CHECK(dm_net_local_session_route(&ip,0,1)==1 && ip==t.address);
    ip=t.discovery;CHECK(dm_net_local_session_route(&ip,0,1)<0 && dm_net_errno()==99);
    const uint32_t discovery[]={htonl(UINT32_MAX),htonl(0xe00000fb),t.address|~t.mask};
    for(unsigned i=0;i<sizeof discovery/sizeof *discovery;i++){ip=discovery[i];CHECK(dm_net_local_session_route(&ip,1,0)==1 && ip==t.discovery);}
    ip=htonl(0xc0000201);CHECK(dm_net_local_session_route(&ip,1,0)<0 && dm_net_errno()==13 && ip==htonl(0xc0000201));
    CHECK(!dm_net_local_session_source(ip) && dm_net_local_session_source(t.address) && dm_net_local_session_source(t.discovery));
    void *answer=(void *)(uintptr_t)1;CHECK(dm_net_getaddrinfo("external.invalid","443",NULL,&answer)!=0 && !answer);
    CHECK(!dm_net_gethostbyname("external.invalid"));
    int fd=dm_net_socket(2,2,17);CHECK(fd>=0);guest_address external=address(ip,9);
    CHECK(dm_net_send(fd,"x",1,0,&external,sizeof external)<0 && dm_net_errno()==13);
    dm_net_iovec v={"x",1};dm_net_msghdr m={.name=&external,.name_size=16,.vectors=&v,.count=1};
    CHECK(dm_net_sendmsg(fd,&m,0)<0 && dm_net_errno()==13);
    CHECK(dm_net_connect(fd,&external,sizeof external)<0 && dm_net_errno()==13);
    int value=1;unsigned size=sizeof value;
    CHECK(dm_net_sockopt(fd,0xffff,512,&value,&size,1)<0 && dm_net_errno()==95);
    uint32_t membership[2]={htonl(0xe00000fb),t.address};size=sizeof membership;
    CHECK(dm_net_sockopt(fd,0,12,membership,&size,1)<0 && dm_net_errno()==95);
    uint64_t old=0;int copy=dm_net_dup_native_generation(fd,&old);CHECK(copy>=0 && old);close(copy);CHECK(!dm_net_close(fd));
    int reused=dm_net_socket(2,2,17);CHECK(reused==fd);uint64_t current=0;copy=dm_net_dup_native_generation(reused,&current);CHECK(copy>=0 && current!=old);close(copy);
    CHECK(dm_net_close_generation(reused,old)<0 && dm_net_errno()==9);
    guest_address own=address(INADDR_ANY,0);CHECK(!dm_net_bind(reused,&own,sizeof own));
    unsigned own_size=sizeof own;CHECK(!dm_net_name(reused,&own,&own_size,0) && own.ip==t.address);
    CHECK(dm_net_send(reused,"fault",5,0,&own,sizeof own)==5);
    dm_net_iovec invalid={(void *)(uintptr_t)1,5};dm_net_msghdr invalid_out={.vectors=&invalid,.count=1,.flags=123},invalid_before=invalid_out;
    CHECK(dm_net_recvmsg(reused,&invalid_out,0)<0 && dm_net_errno()==14 && !memcmp(&invalid_out,&invalid_before,sizeof invalid_out));
    CHECK(dm_net_send(reused,"fault",5,0,&own,sizeof own)==5);
    CHECK(dm_net_recv(reused,(void *)(uintptr_t)1,5,0,NULL,NULL)<0 && dm_net_errno()==14);
    CHECK(dm_net_send(reused,"zero",4,0,&own,sizeof own)==4);
    CHECK(dm_net_recv(reused,NULL,0,0,NULL,NULL)==0);
    char empty='Q';CHECK(dm_net_recv(reused,&empty,1,0x80,NULL,NULL)<0 && dm_net_errno()==11 && empty=='Q');
    CHECK(!dm_net_close_generation(reused,current));
    CHECK(dm_net_local_session_install(t.discovery,t.address)<0 && dm_net_errno()==16);
    CHECK(dm_net_local_session_get(&session)==1 && session.own==t.address && session.peer==t.discovery);
}
static void station_messages(int fd,dm_ldn_transport t,unsigned port) {
    guest_address destination=address(t.address|~t.mask,port);
    dm_net_iovec v[]={{"me",2},{NULL,0},{"sh!",3}};
    dm_net_msghdr send={.name=&destination,.name_size=16,.vectors=v,.count=3,.flags=123},before=send;
    CHECK(dm_net_sendmsg(fd,&send,0)==5 && !memcmp(&send,&before,sizeof send));
    char bytes[4]={0};dm_net_iovec output={bytes,3};guest_address from;dm_net_msghdr receive={.name=&from,.name_size=16,.vectors=&output,.count=1};
    CHECK(dm_net_recvmsg(fd,&receive,0)==3 && !memcmp(bytes,"lon",3) && bytes[3]==0 && (receive.flags&0x10) && from.ip==t.discovery);
    send.count=0;send.vectors=NULL;CHECK(dm_net_sendmsg(fd,&send,0)==0);
    dm_net_msghdr empty={0};CHECK(dm_net_recvmsg(fd,&empty,0)==0 && (empty.flags&0x10));
    CHECK(dm_net_recvmsg(fd,&empty,0x80)<0 && dm_net_errno()==11);
}
static void host_messages(int fd,uint32_t peer) {
    char first[2]={0},second[4]={0};dm_net_iovec v[]={{first,2},{second,3}};guest_address from;
    dm_net_msghdr receive={.name=&from,.name_size=16,.vectors=v,.count=2,.flags=123};
    CHECK(dm_net_recvmsg(fd,&receive,0)==5 && !memcmp(first,"me",2) && !memcmp(second,"sh!",3) && second[3]==0 && from.ip==peer && receive.vectors==v && receive.count==2 && !receive.flags);
    dm_net_iovec send_vector={"longer",6};dm_net_msghdr send={.name=&from,.name_size=16,.vectors=&send_vector,.count=1};
    CHECK(dm_net_sendmsg(fd,&send,0)==6);
    char untouched='Q';dm_net_iovec empty={&untouched,0};receive.vectors=&empty;receive.count=1;receive.flags=123;
    CHECK(dm_net_recvmsg(fd,&receive,0)==0 && !receive.flags && untouched=='Q');
    CHECK(dm_net_send(fd,"x",1,0,&from,sizeof from)==1);
}
static int data_socket(uint32_t ip, unsigned port, guest_address *out) {
    int fd=dm_net_socket(2,2,17); CHECK(fd>=0); *out=address(INADDR_ANY,port); CHECK(!dm_net_bind(fd,out,sizeof *out));
    unsigned size=sizeof *out; CHECK(!dm_net_name(fd,out,&size,0) && size==sizeof *out && out->ip==ip && out->port);
    int64_t timeout[2]={2,0}; CHECK(!dm_net_sockopt(fd,0xffff,0x1006,timeout,&(unsigned){sizeof timeout},1)); return fd;
}
static int node_count(dm_ldn_context *c, unsigned count, dm_ldn_network *network) {
    for(unsigned i=0;i<400;i++) { if(!dm_ldn_get_network(c,network,NULL,0) && network->node_count==count)return 1; usleep(5000); } return 0;
}
static dm_ldn_security_config security(void) { dm_ldn_security_config s={.mode=1,.size=4};memcpy(s.passphrase,"test",4);return s; }
static dm_ldn_user user(const char *name) { dm_ldn_user u={0};snprintf(u.name,sizeof u.name,"%s",name);return u; }
static void station(dm_ldn_transport t, int input, int output) {
    CHECK(!dm_net_local_session_install(t.address,t.discovery));policy(t);
    uint32_t own=0,mask=0,gateway=1,dns1=1,dns2=1;
    CHECK(!dm_net_ipconfig(&own,&mask,&gateway,&dns1,&dns2) && own==t.address && mask==t.mask && !gateway && !dns1 && !dns2);
    dm_ldn_context *c=dm_ldn_start(&t,NULL,NULL); CHECK(c && !dm_ldn_open(c,0));
    unsigned game_port=0; exchange(output,&game_port,sizeof game_port,1);exchange(input,&game_port,sizeof game_port,0);
    dm_ldn_network rooms[24];dm_ldn_filter filter={0};int count=0;
    CHECK(!dm_ldn_scan(c,rooms,&count,24,&filter,0) && count==1);
    CHECK(rooms[0].nodes[0].ip==ntohl(t.discovery));
    dm_ldn_security_config sec=security();dm_ldn_user u=user("synthetic station");CHECK(!dm_ldn_connect(c,rooms,&sec,&u,7,0));
    dm_ldn_network network;CHECK(node_count(c,2,&network));
    CHECK(network.nodes[0].ip!=network.nodes[1].ip && memcmp(network.nodes[0].mac,network.nodes[1].mac,6));
    guest_address from,target=address(t.discovery,game_port);int data=data_socket(t.address,game_port,&from);
    target.ip=htonl(UINT32_MAX);
    CHECK(dm_net_send(data,"station",7,0,&target,sizeof target)==7);
    target.ip=t.discovery;
    char reply[8]={0};unsigned size=sizeof from;
    CHECK(dm_net_recv(data,reply,sizeof reply,0,&from,&size)==4 && !memcmp(reply,"host",4) && from.ip==t.discovery && from.port==target.port);
    station_messages(data,t,game_port);
    int tcp=dm_net_socket(2,1,6);CHECK(tcp>=0);timeout(tcp);
    guest_address remote=address(t.discovery,game_port);
    CHECK(!dm_net_connect(tcp,&remote,sizeof remote));
    guest_address named;unsigned named_size=sizeof named;
    CHECK(!dm_net_name(tcp,&named,&named_size,0) && named.ip==t.address);
    char stream[2];CHECK(dm_net_recv(tcp,stream,2,0,NULL,NULL)==2 && !memcmp(stream,"T1",2));
    CHECK(dm_net_send(tcp,"T2",2,0,NULL,0)==2);CHECK(!dm_net_shutdown(tcp,1));CHECK(!dm_net_close(tcp));
    CHECK(!dm_ldn_disconnect(c,0));dm_ldn_stop(c);c=dm_ldn_start(&t,NULL,NULL);CHECK(c);dm_ldn_stop(c);CHECK(!dm_net_close(data));dm_net_finalize();
    printf("station endpoint: %u checks passed\n",checks);fflush(stdout);
}
static void negative_policy(void) {
    const char *modes[]={"nextendo","auto","offline","ldn","ldn","ldn","ldn"};
    for(unsigned i=0;i<sizeof modes/sizeof *modes;i++) {
        pid_t pid=fork();CHECK(pid>=0);
        if(!pid) {
            setenv("DM_NETWORK",modes[i],1);setenv("DM_NEXTENDO_ROUTES","/synthetic-profile",1);
            if(i==5){int socket=dm_net_socket(2,2,17);CHECK(socket>=0 && !dm_net_close(socket));}
            if(i==6){
                int reserved=socket(AF_INET,SOCK_DGRAM,0);struct sockaddr_in local=native_address(htonl(INADDR_LOOPBACK),0);socklen_t size=sizeof local;
                CHECK(reserved>=0 && !bind(reserved,(void *)&local,sizeof local) && !getsockname(reserved,(void *)&local,&size));close(reserved);
                dm_ldn_transport transport={.address=local.sin_addr.s_addr,.bind_address=local.sin_addr.s_addr,.mask=htonl(0xff000000),.discovery=local.sin_addr.s_addr,.port=ntohs(local.sin_port),.discovery_port=ntohs(local.sin_port),.scan_ms=250,.connect_ms=2000};
                dm_ldn_context *context=dm_ldn_start(&transport,NULL,NULL);CHECK(context);dm_ldn_stop(context);
            }
            int result=dm_net_local_session_install(htonl(INADDR_LOOPBACK),htonl(i>=4?0xc0000201:INADDR_LOOPBACK));
            if(i>=5){
                CHECK(result<0 && dm_net_errno()==16 && dm_net_mode()==DM_NET_LDN && dm_net_enabled());
                dm_net_local_session out={1,2,3};CHECK(!dm_net_local_session_get(&out) && !out.own && !out.peer && !out.mask);
                uint32_t destination=htonl(0xc0000201);CHECK(!dm_net_local_session_route(&destination,1,0) && destination==htonl(0xc0000201));
                _exit(0); // EBUSY preserves prior routing; do not issue an external lookup.
            }
            CHECK(result<0 && !dm_net_nextendo_enabled() && !dm_net_enabled());
            dm_net_local_session out={1,2,3};CHECK(dm_net_local_session_get(&out)<0 && !out.own && !out.peer && !out.mask);
            void *answer=(void *)(uintptr_t)1;CHECK(dm_net_getaddrinfo("external.invalid","443",NULL,&answer)!=0 && !answer);
            _exit(0);
        }
        int status;CHECK(waitpid(pid,&status,0)==pid && WIFEXITED(status) && !WEXITSTATUS(status));
    }
}
int main(int argc,char **argv) {
    negative_policy();
    if(argc==1){printf("Local session negative policy: %u parent checks passed, seven isolated rejection cases\n",checks);return 0;}
    if(argc!=3 || !*argv[1] || !*argv[2]){fprintf(stderr,"usage: t_net_local_session <first-up-IPv4-interface> <second-up-IPv4-interface>\n");return 2;}
    // Only this explicit developer session replaces fanout with its registered
    // peer. This fixture does not qualify unchanged game processes or a match.
    setenv("DM_NETWORK","ldn",1);unsetenv("DM_NETWORK_INTERFACE");unsetenv("DM_NET_DISCOVERY_PEER");unsetenv("DM_NEXTENDO_ROUTES");dm_net_set_multicast_allowed(0);
    dm_ldn_transport host=adapter(argv[1]),peer=adapter(argv[2]);CHECK(host.address!=peer.address);
    host.mac[0]=peer.mac[0]=2;host.mac[5]=1;peer.mac[5]=2; // Authored fixture identities, never hardware/account identities.
    int reserved=socket(AF_INET,SOCK_DGRAM,0),collision=socket(AF_INET,SOCK_DGRAM,0);CHECK(reserved>=0 && collision>=0);
    struct sockaddr_in any=native_address(INADDR_ANY,0);CHECK(!bind(reserved,(void *)&any,sizeof any));socklen_t size=sizeof any;CHECK(!getsockname(reserved,(void *)&any,&size));
    // Reproduce the wildcard-listener collision without changing SO_REUSE*
    // policy or touching the normal production port.
    CHECK(bind(collision,(void *)&any,sizeof any)<0 && errno==EADDRINUSE);close(collision);
    host.port=peer.port=host.discovery_port=peer.discovery_port=ntohs(any.sin_port);host.discovery=peer.address;peer.discovery=host.address;
    int control_tcp=socket(AF_INET,SOCK_STREAM,0);CHECK(control_tcp>=0 && !bind(control_tcp,(void *)&any,sizeof any));
    close(control_tcp);close(reserved);
    int to_child[2],from_child[2];CHECK(!pipe(to_child) && !pipe(from_child));pid_t pid=fork();CHECK(pid>=0);
    if(!pid){checks=0;close(to_child[1]);close(from_child[0]);station(peer,to_child[0],from_child[1]);close(to_child[0]);close(from_child[1]);_exit(0);}
    close(to_child[0]);close(from_child[1]);
    CHECK(!dm_net_local_session_install(host.address,host.discovery));policy(host);
    dm_ldn_context *c=dm_ldn_start(&host,NULL,NULL);CHECK(c && !dm_ldn_open(c,1));
    dm_ldn_network_config config={.intent={.local_id=0x12345678,.scene=17},.max_nodes=8,.version=7};dm_ldn_security_config sec=security();dm_ldn_user u=user("synthetic host");
    CHECK(!dm_ldn_create(c,&config,&sec,&u,NULL,0,NULL));unsigned ready;exchange(from_child[0],&ready,sizeof ready,0);
    guest_address local,from;int data=data_socket(host.address,0,&local);unsigned game_port=ntohs(local.port);
    int tcp=dm_net_socket(2,1,6);CHECK(tcp>=0);timeout(tcp);guest_address game_any=address(INADDR_ANY,game_port);
    CHECK(!dm_net_bind(tcp,&game_any,sizeof game_any) && !dm_net_listen(tcp,2));
    exchange(to_child[1],&game_port,sizeof game_port,1);
    dm_ldn_network network;CHECK(node_count(c,2,&network));
    CHECK(network.nodes[0].ip==ntohl(host.address) && network.nodes[1].ip==ntohl(peer.address));
    char request[8]={0};unsigned from_size=sizeof from;
    CHECK(dm_net_recv(data,request,sizeof request,0,&from,&from_size)==7 && !memcmp(request,"station",7) && from.ip==peer.address && from.port==local.port);
    CHECK(dm_net_send(data,"host",4,0,&from,sizeof from)==4);host_messages(data,peer.address);
    guest_address remote;unsigned remote_size=sizeof remote;int accepted=dm_net_accept(tcp,&remote,&remote_size);CHECK(accepted>=0 && remote.ip==peer.address);timeout(accepted);
    CHECK(dm_net_send(accepted,"T1",2,0,NULL,0)==2);char stream[2];CHECK(dm_net_recv(accepted,stream,2,0,NULL,NULL)==2 && !memcmp(stream,"T2",2));
    CHECK(dm_net_recv(accepted,stream,2,0,NULL,NULL)==0);CHECK(!dm_net_close(accepted) && !dm_net_close(tcp));
    int status;CHECK(waitpid(pid,&status,0)==pid && WIFEXITED(status) && !WEXITSTATUS(status));CHECK(node_count(c,1,&network));
    dm_ldn_stop(c);c=dm_ldn_start(&host,NULL,NULL);CHECK(c);dm_ldn_stop(c);CHECK(!dm_net_close(data));dm_net_finalize();close(to_child[1]);close(from_child[0]);
    printf("host endpoint: %u checks passed; distinct real IPv4 identities, same control/data ports, two processes, unicast discovery only\n",checks);
    return 0;
}
