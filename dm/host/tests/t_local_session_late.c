// Live native workers must keep their original transport when a startup-only
// affinity request is rejected as late. All peers/bytes here are fixture-owned.
#include "../hle_ldn.h"
#include "../net_socket.h"
#include <arpa/inet.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static unsigned checks;
#define CHECK(c) do{checks++;if(!(c)){fprintf(stderr,"Late-session line %d: %s (guest errno %d)\n",__LINE__,#c,dm_net_errno());_exit(1);}}while(0)
void dm_guest_host_wait_begin(void){} void dm_guest_host_wait_end(void){}
typedef struct{uint8_t len,family;uint16_t port;uint32_t ip;uint8_t reserved[8];} guest_address;
static int native_udp(struct sockaddr_in *address){
    int fd=socket(AF_INET,SOCK_DGRAM,0);*address=(struct sockaddr_in){.sin_len=sizeof *address,.sin_family=AF_INET,.sin_addr={htonl(INADDR_LOOPBACK)}};
    socklen_t size=sizeof *address;CHECK(fd>=0 && !bind(fd,(void *)address,sizeof *address) && !getsockname(fd,(void *)address,&size));return fd;
}
static unsigned control_port(void){
    struct sockaddr_in address;int fd=native_udp(&address),tcp=socket(AF_INET,SOCK_STREAM,0);
    CHECK(tcp>=0 && !bind(tcp,(void *)&address,sizeof address));close(tcp);close(fd);return ntohs(address.sin_port);
}
static dm_ldn_transport transport(unsigned port,unsigned host,unsigned identity){
    dm_ldn_transport t={.address=htonl(INADDR_LOOPBACK),.mask=htonl(0xff000000),.discovery=htonl(INADDR_LOOPBACK),.bind_address=htonl(INADDR_LOOPBACK),.port=(uint16_t)port,.discovery_port=(uint16_t)host,.scan_ms=150,.connect_ms=1000};
    t.mac[0]=2;t.mac[5]=(uint8_t)identity;return t;
}
static int synchronized(dm_ldn_context *station,char value){
    for(unsigned i=0;i<400;i++){
        dm_ldn_network n;
        if(!dm_ldn_get_network(station,&n,NULL,0) && n.node_count==2 && n.advertise_size==1 && n.advertise[0]==(uint8_t)value)return 1;
        usleep(5000);
    }
    return 0;
}
static int guest_packet(int guest,int native,const guest_address *destination,char value){
    if(dm_net_send(guest,&value,1,0,destination,sizeof *destination)!=1)return 0;
    struct pollfd ready={native,POLLIN,0};char result=0;
    return poll(&ready,1,1000)>0 && recv(native,&result,1,0)==1 && result==value;
}
int main(void){
    setenv("DM_NETWORK","ldn",1);setenv("DM_NET_DISCOVERY_PEER","127.0.0.1",1);unsetenv("DM_NEXTENDO_ROUTES");dm_net_set_multicast_allowed(0);
    unsigned host_port=control_port(),station_port=control_port();CHECK(host_port!=station_port);
    dm_ldn_transport h=transport(host_port,host_port,1),s=transport(station_port,host_port,2);
    dm_ldn_context *host=dm_ldn_start(&h,NULL,NULL),*station=dm_ldn_start(&s,NULL,NULL);CHECK(host && station);
    CHECK(!dm_ldn_open(host,1) && !dm_ldn_open(station,0));
    dm_ldn_network_config config={.intent={.local_id=0x12345678,.scene=17},.max_nodes=8,.version=7};
    dm_ldn_security_config security={.mode=1,.size=4};memcpy(security.passphrase,"test",4);
    dm_ldn_user user={0};memcpy(user.name,"synthetic host",15);CHECK(!dm_ldn_create(host,&config,&security,&user,NULL,0,NULL));
    dm_ldn_network rooms[24];dm_ldn_filter filter={0};int count=0;
    CHECK(!dm_ldn_scan(station,rooms,&count,24,&filter,0) && count==1);
    memcpy(user.name,"synthetic station",18);CHECK(!dm_ldn_connect(station,rooms,&security,&user,7,0));
    CHECK(!dm_ldn_advertise(host,"A",1) && synchronized(station,'A'));
    struct sockaddr_in peer;int native=native_udp(&peer),guest=dm_net_socket(2,2,17);CHECK(guest>=0);
    guest_address destination={16,2,peer.sin_port,peer.sin_addr.s_addr,{0}};
    CHECK(guest_packet(guest,native,&destination,'A'));
    CHECK(dm_net_local_session_install(h.address,htonl(0xc0000201))<0 && dm_net_errno()==16);
    CHECK(!dm_ldn_advertise(host,"B",1));int raw_after=synchronized(station,'B');
    int guest_after=guest_packet(guest,native,&destination,'B');
    dm_net_local_session pair={1,2,3};int session=dm_net_local_session_get(&pair),mode=(int)dm_net_mode();
    printf("Late startup request: native TCP before=1 after=%d; guest UDP before=1 after=%d; installed=%d; mode-preserved=%d\n",raw_after,guest_after,session,mode==DM_NET_LDN);fflush(stdout);
    CHECK(raw_after && guest_after && session==0 && !pair.own && !pair.peer && !pair.mask && mode==DM_NET_LDN);
    // A subsequent scan also exercises the original native UDP request/reply
    // path after the busy result, separately from the existing TCP connection.
    CHECK(!dm_ldn_disconnect(station,0));count=0;CHECK(!dm_ldn_scan(station,rooms,&count,24,&filter,0) && count==1);
    CHECK(!dm_net_close(guest));close(native);dm_ldn_stop(station);dm_ldn_stop(host);dm_net_finalize();
    CHECK(dm_net_local_session_install(h.address,s.address)<0 && dm_net_errno()==16);
    CHECK(dm_net_local_session_get(&pair)==0 && dm_net_mode()==DM_NET_LDN);
    printf("Late-session transport preservation: %u checks passed; live native TCP/UDP and guest UDP, then closed-context rejection\n",checks);return 0;
}
