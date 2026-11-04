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
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"endpoint fixture line %d: %s (errno %d, guest errno %d)\n",__LINE__,#x,errno,dm_net_errno()); abort(); } } while (0)
void dm_guest_host_wait_begin(void) {}
void dm_guest_host_wait_end(void) {}
typedef struct { uint8_t len, family; uint16_t port; uint32_t ip; uint8_t reserved[8]; } guest_address;
static guest_address address(uint32_t ip, unsigned port) { return (guest_address){16,2,htons((uint16_t)port),ip,{0}}; }
static struct sockaddr_in native_address(uint32_t ip, unsigned port) {
    return (struct sockaddr_in){.sin_len=sizeof(struct sockaddr_in),.sin_family=AF_INET,.sin_port=htons((uint16_t)port),.sin_addr={ip}};
}
static dm_ldn_transport adapter(const char *name) {
    struct ifaddrs *list=NULL; CHECK(!getifaddrs(&list)); dm_ldn_transport t={0};
    for (struct ifaddrs *p=list;p;p=p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family!=AF_INET || !(p->ifa_flags&IFF_UP) || strcmp(p->ifa_name,name)) continue;
        t.address=((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr;
        if(p->ifa_netmask && p->ifa_netmask->sa_family==AF_INET) t.mask=((struct sockaddr_in *)p->ifa_netmask)->sin_addr.s_addr;
        break;
    }
    freeifaddrs(list); CHECK(t.address && t.mask); t.bind_address=t.address; t.scan_ms=250; t.connect_ms=2000; return t;
}
static void exchange(int fd, void *data, size_t size, int sending) {
    char *bytes=data; size_t at=0;
    while(at<size) {
        struct pollfd p={fd,sending?POLLOUT:POLLIN,0}; CHECK(poll(&p,1,4000)>0);
        ssize_t n=sending?write(fd,bytes+at,size-at):read(fd,bytes+at,size-at); CHECK(n>0); at+=(size_t)n;
    }
}
static int data_socket(uint32_t ip, unsigned port, guest_address *out) {
    int fd=dm_net_socket(2,2,17); CHECK(fd>=0); *out=address(ip,port); CHECK(!dm_net_bind(fd,out,sizeof *out));
    unsigned size=sizeof *out; CHECK(!dm_net_name(fd,out,&size,0) && size==sizeof *out && out->ip==ip && out->port);
    int64_t timeout[2]={2,0}; CHECK(!dm_net_sockopt(fd,0xffff,0x1006,timeout,&(unsigned){sizeof timeout},1)); return fd;
}
static int node_count(dm_ldn_context *c, unsigned count, dm_ldn_network *network) {
    for(unsigned i=0;i<400;i++) { if(!dm_ldn_get_network(c,network,NULL,0) && network->node_count==count)return 1; usleep(5000); } return 0;
}
static dm_ldn_security_config security(void) { dm_ldn_security_config s={.mode=1,.size=4};memcpy(s.passphrase,"test",4);return s; }
static dm_ldn_user user(const char *name) { dm_ldn_user u={0};snprintf(u.name,sizeof u.name,"%s",name);return u; }
static void station(dm_ldn_transport t, int input, int output) {
    dm_ldn_context *c=dm_ldn_start(&t,NULL,NULL); CHECK(c && !dm_ldn_open(c,0));
    unsigned game_port=0; exchange(output,&game_port,sizeof game_port,1);exchange(input,&game_port,sizeof game_port,0);
    dm_ldn_network rooms[24];dm_ldn_filter filter={0};int count=0;
    CHECK(!dm_ldn_scan(c,rooms,&count,24,&filter,0) && count==1);
    CHECK(rooms[0].nodes[0].ip==ntohl(t.discovery));
    dm_ldn_security_config sec=security();dm_ldn_user u=user("synthetic station");CHECK(!dm_ldn_connect(c,rooms,&sec,&u,7,0));
    dm_ldn_network network;CHECK(node_count(c,2,&network));
    CHECK(network.nodes[0].ip!=network.nodes[1].ip && memcmp(network.nodes[0].mac,network.nodes[1].mac,6));
    guest_address from,target=address(t.discovery,game_port);int data=data_socket(t.address,game_port,&from);
    CHECK(dm_net_send(data,"station",7,0,&target,sizeof target)==7);
    char reply[8]={0};unsigned size=sizeof from;
    CHECK(dm_net_recv(data,reply,sizeof reply,0,&from,&size)==4 && !memcmp(reply,"host",4) && from.ip==t.discovery && from.port==target.port);
    CHECK(!dm_ldn_disconnect(c,0));dm_ldn_stop(c);CHECK(!dm_net_close(data));dm_net_finalize();
    printf("station endpoint: %u checks passed\n",checks);fflush(stdout);
}
int main(int argc,char **argv) {
    if(argc!=3 || !*argv[1] || !*argv[2]){fprintf(stderr,"usage: t_ldn_endpoints <first-up-IPv4-interface> <second-up-IPv4-interface>\n");return 2;}
    // Selection is explicit and fixture-local. Production defaults and the
    // game's discovery path are not replaced with this unicast arrangement.
    setenv("DM_NETWORK","ldn",1);unsetenv("DM_NETWORK_INTERFACE");unsetenv("DM_NET_DISCOVERY_PEER");
    dm_ldn_transport host=adapter(argv[1]),peer=adapter(argv[2]);CHECK(host.address!=peer.address);
    int reserved=socket(AF_INET,SOCK_DGRAM,0),collision=socket(AF_INET,SOCK_DGRAM,0);CHECK(reserved>=0 && collision>=0);
    struct sockaddr_in any=native_address(INADDR_ANY,0);CHECK(!bind(reserved,(void *)&any,sizeof any));socklen_t size=sizeof any;CHECK(!getsockname(reserved,(void *)&any,&size));
    // Reproduce the wildcard-listener collision without changing SO_REUSE*
    // policy or touching the normal production port.
    CHECK(bind(collision,(void *)&any,sizeof any)<0 && errno==EADDRINUSE);close(collision);
    host.port=peer.port=host.discovery_port=peer.discovery_port=ntohs(any.sin_port);host.discovery=peer.address;peer.discovery=host.address;
    close(reserved);
    int to_child[2],from_child[2];CHECK(!pipe(to_child) && !pipe(from_child));pid_t pid=fork();CHECK(pid>=0);
    if(!pid){close(to_child[1]);close(from_child[0]);station(peer,to_child[0],from_child[1]);close(to_child[0]);close(from_child[1]);_exit(0);}
    close(to_child[0]);close(from_child[1]);
    dm_ldn_context *c=dm_ldn_start(&host,NULL,NULL);CHECK(c && !dm_ldn_open(c,1));
    dm_ldn_network_config config={.intent={.local_id=0x12345678,.scene=17},.max_nodes=8,.version=7};dm_ldn_security_config sec=security();dm_ldn_user u=user("synthetic host");
    CHECK(!dm_ldn_create(c,&config,&sec,&u,NULL,0,NULL));unsigned ready;exchange(from_child[0],&ready,sizeof ready,0);
    guest_address local,from;int data=data_socket(host.address,0,&local);unsigned game_port=ntohs(local.port);exchange(to_child[1],&game_port,sizeof game_port,1);
    dm_ldn_network network;CHECK(node_count(c,2,&network));
    CHECK(network.nodes[0].ip==ntohl(host.address) && network.nodes[1].ip==ntohl(peer.address));
    char request[8]={0};unsigned from_size=sizeof from;
    CHECK(dm_net_recv(data,request,sizeof request,0,&from,&from_size)==7 && !memcmp(request,"station",7) && from.ip==peer.address && from.port==local.port);
    CHECK(dm_net_send(data,"host",4,0,&from,sizeof from)==4);
    int status;CHECK(waitpid(pid,&status,0)==pid && WIFEXITED(status) && !WEXITSTATUS(status));CHECK(node_count(c,1,&network));
    dm_ldn_stop(c);CHECK(!dm_net_close(data));dm_net_finalize();close(to_child[1]);close(from_child[0]);
    printf("host endpoint: %u checks passed; distinct real IPv4 identities, same control/data ports, two processes, unicast discovery only\n",checks);
    return 0;
}
